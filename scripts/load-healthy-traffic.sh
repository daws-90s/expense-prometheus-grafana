#!/bin/bash
# Generates real, successful traffic against the expense app's public API --
# background "good" traffic for the SLO/error-budget denominator (section 13
# of GETTING-STARTED.md), and real data to look at in the Business Metrics /
# Application RED dashboards (section 11).
#
# Usage: ./load-healthy-traffic.sh <base-url> [count]
#   base-url  e.g. http://localhost -- run this on the frontend instance
#             itself (nginx listens on :80 there regardless of the domain/
#             cert), or http://<frontend-private-ip> from elsewhere inside
#             the VPC. Only use https://<domain> if you're running this from
#             outside the VPC against the public DNS name.
#   count     number of expenses to create (default 50)

set -euo pipefail

BASE_URL="${1:?Usage: $0 <base-url> [count]}"
COUNT="${2:-50}"
BASE_URL="${BASE_URL%/}"

CATEGORIES=(
  '{"name":"Food","icon":"utensils"}'
  '{"name":"Transport","icon":"car"}'
  '{"name":"Entertainment","icon":"film"}'
  '{"name":"Utilities","icon":"zap"}'
  '{"name":"Shopping","icon":"shopping-bag"}'
)

echo "Ensuring categories exist at $BASE_URL ..."
for cat in "${CATEGORIES[@]}"; do
  # 201 on first run, 409 (duplicate name) on reruns -- both fine, ignored.
  curl -s -o /dev/null -X POST "$BASE_URL/api/categories" \
    -H 'Content-Type: application/json' -d "$cat"
done

echo "Fetching category IDs ..."
CATEGORY_IDS=($(curl -s "$BASE_URL/api/categories" | grep -o '"id":[0-9]*' | grep -o '[0-9]*'))
if [ "${#CATEGORY_IDS[@]}" -eq 0 ]; then
  echo "No categories found -- category creation above must have failed. Aborting." >&2
  exit 1
fi
NUM_CATEGORIES=${#CATEGORY_IDS[@]}

echo "Creating $COUNT expenses (spread across $NUM_CATEGORIES categories) ..."
NOTES=("Groceries" "Monthly bill" "Coffee" "Fuel" "Subscription" "Dinner out" "Taxi" "Movie tickets" "Repairs" "Misc")

for i in $(seq 1 "$COUNT"); do
  cat_id=${CATEGORY_IDS[$((RANDOM % NUM_CATEGORIES))]}
  amount=$(((RANDOM % 5000) + 50))
  day=$(((RANDOM % 28) + 1))
  month=$(((RANDOM % 12) + 1))
  note=${NOTES[$((RANDOM % ${#NOTES[@]}))]}
  date=$(printf "2026-%02d-%02d" "$month" "$day")

  curl -s -o /dev/null -X POST "$BASE_URL/api/expenses" \
    -H 'Content-Type: application/json' \
    -d "{\"category_id\":$cat_id,\"amount\":$amount,\"expense_date\":\"$date\",\"notes\":\"$note\"}"

  # Interleave read traffic too -- real usage isn't all writes.
  if ((i % 3 == 0)); then
    curl -s -o /dev/null "$BASE_URL/api/expenses"
    curl -s -o /dev/null "$BASE_URL/api/categories"
  fi

  if ((i % 10 == 0)); then
    echo "  ...$i/$COUNT"
  fi
done

echo "Done: $COUNT expenses created, plus interleaved list reads."
echo "Check the Business Metrics and Application RED dashboards in Grafana."

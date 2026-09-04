#!/bin/bash
# Injects failures against the expense app's public API to move the SLO/
# error-budget/burn-rate panels (dashboard 7) and trip BackendHighErrorRate /
# BackendHighLatencyP95 (section 9 of GETTING-STARTED.md). Requires
# ENABLE_DEBUG_ROUTES=true on the backend first -- these routes 404
# otherwise; run load-healthy-traffic.sh beforehand if you want a realistic
# background ratio to fail against.
#
# Usage: ./load-fault-traffic.sh <base-url> [error-count] [slow-count] [slow-ms]
#   base-url     e.g. http://localhost -- run this on the frontend instance
#                itself (nginx listens on :80 there regardless of the
#                domain/cert). Only use https://<domain> if you're running
#                this from outside the VPC against the public DNS name.
#   error-count  number of /debug/error hits (default 20)
#   slow-count   number of /debug/slow hits (default 5)
#   slow-ms      how long each slow request sleeps, ms (default 4000 --
#                well over the 1s p95 alert threshold)

set -euo pipefail

BASE_URL="${1:?Usage: $0 <base-url> [error-count] [slow-count] [slow-ms]}"
ERROR_COUNT="${2:-20}"
SLOW_COUNT="${3:-5}"
SLOW_MS="${4:-4000}"
BASE_URL="${BASE_URL%/}"

echo "Checking /debug/error is actually enabled ..."
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/debug/error")
if [ "$STATUS" = "404" ]; then
  echo "Got 404 -- ENABLE_DEBUG_ROUTES is still false on the backend." >&2
  echo "SSH in and flip it first:" >&2
  echo "  sudo sed -i 's/ENABLE_DEBUG_ROUTES=false/ENABLE_DEBUG_ROUTES=true/' /app/.env" >&2
  echo "  sudo systemctl restart expense-backend" >&2
  exit 1
fi
echo "Debug routes are live (got $STATUS -- one real error already counted above)."

echo "Firing $ERROR_COUNT hits at /debug/error ..."
for i in $(seq 1 "$ERROR_COUNT"); do
  curl -s -o /dev/null "$BASE_URL/debug/error"
done

echo "Firing $SLOW_COUNT hits at /debug/slow?ms=$SLOW_MS (sequential -- this part takes a while) ..."
for i in $(seq 1 "$SLOW_COUNT"); do
  curl -s -o /dev/null "$BASE_URL/debug/slow?ms=$SLOW_MS"
done

echo
echo "Done: $((ERROR_COUNT + 1)) real 500s and $SLOW_COUNT slow (${SLOW_MS}ms) requests sent."
echo "Give it ~2-3 minutes: the alert's 'for: 2m' has to hold, then Alertmanager's"
echo "30s group_wait before Slack/email goes out."
echo "Check <prometheus_fqdn>:9090/alerts and dashboard 7's 'Right Now' panel in the meantime."

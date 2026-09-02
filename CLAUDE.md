# expense-infra — Observability additions spec

Adds a **Prometheus EC2 instance** (scraping via **EC2 service discovery**, not
static IPs) plus **node_exporter** on every box and **mysqld_exporter** on the
mysql box, all provisioned through the existing `user_data` + `templatefile()`
model. Written for an agent editing this Terraform repo — follow the same
conventions already documented in the repo context file (self-contained
userdata scripts, no shared `common.sh`, `LOGS_FOLDER=/var/log/expense`,
root-check gate, `R`/`G`/`Y`/`N` color vars, inline `VALIDATE()`, idempotent
guards).

---

## 0. Read this before you `apply` — live-state gotchas

1. **`terraform.tfstate` here is live.** This change *adds* a Prometheus
   instance, an IAM role, SG rules, and `Tier`/`Project` tags on existing
   instances. Run `terraform plan` and confirm the plan **adds** the new
   resources and does **in-place tag updates** on the three app instances — it
   must **not** force-replace `aws_instance.mysql/backend/frontend`. If the plan
   shows a replacement on any running app instance, stop and check with the
   user.

2. **Editing `userdata/*.sh` does NOT install exporters on already-running
   boxes.** cloud-init runs user_data once, on first boot. A `user_data` diff
   will (depending on `user_data_replace_on_change`) either trigger a stop/start
   or a replace — neither re-runs the script usefully, and a replace reprovisions
   the app. So:
   - The exporters are **already installed manually** on mysql/backend/frontend
     (the user did this by hand). The userdata edits below exist to **codify**
     that so the *next* clean build is reproducible — they are not expected to
     change the current running boxes.
   - The **Prometheus instance is genuinely new**, so its userdata *will* run on
     this `apply`. That's the one script that actually executes now.
   - If you ever do want the exporters onto a running app box from IaC, that
     means reprovisioning that instance — a destructive act on live state —
     confirm with the user first.

---

## 1. Tagging (prerequisite for EC2 service discovery)

Service discovery filters on tags, so every instance in `ec2.tf` must carry a
consistent tag set. Add/confirm these `tags` on each `aws_instance`:

| Instance   | `Project`  | `Tier`         | `Name`       |
|------------|------------|----------------|--------------|
| mysql      | `expense`  | `database`     | `mysql`      |
| backend    | `expense`  | `backend`      | `backend`    |
| frontend   | `expense`  | `frontend`     | `frontend`   |
| prometheus | `expense`  | `monitoring`   | `prometheus` |

Adding tags to existing instances is an in-place update (no replacement). The
`Name` tag becomes the Prometheus `instance` label via relabeling, and `Tier`
becomes the `tier` label — same label scheme we settled on for the hand-written
config, now sourced from AWS instead of typed in.

---

## 2. New Terraform resources

### 2a. `iam.tf` (currently **active** — append here)

Add a role + policy + instance profile for Prometheus. This is the "role for ec2
prom" that lets `ec2_sd_configs` call the EC2 API using the instance profile
(no static AWS keys in the config).

- `aws_iam_role.prometheus` — trust policy for `ec2.amazonaws.com`.
- `aws_iam_role_policy.prometheus_ec2_sd` — minimal read-only:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeAvailabilityZones"
      ],
      "Resource": "*"
    }
  ]
}
```

`DescribeInstances` is the one Prometheus actually needs; these describe actions
don't support resource-level scoping, so `Resource: "*"` is correct and expected.

- `aws_iam_instance_profile.prometheus` wrapping the role.

### 2b. `ec2.tf`

- Add `aws_instance.prometheus`:
  - `iam_instance_profile = aws_iam_instance_profile.prometheus.name`
  - `user_data = templatefile("${path.module}/userdata/prometheus.sh", { region = var.region, backend_port = var.backend_port, project_tag = var.project_tag, prometheus_version = var.prometheus_version, node_exporter_version = var.node_exporter_version })`
  - its own security group (2d), `t3.micro`, tags from section 1.
  - **No `depends_on` needed** — SD discovers targets whenever they exist, so
    Prometheus can boot independently of the app tiers.
- Add the tags from section 1 to the three existing instances.
- Pass the new exporter version vars into the existing tiers' `templatefile(...)`
  calls (so `node_exporter.sh`/`mysqld_exporter` install blocks can read them).

### 2c. `route53.tf` (optional, consistent with existing records)

- `aws_route53_record.prometheus` → `prometheus.<domain>` A record to the
  instance private (or public, per your access model) IP. Optional, but makes
  the UI reachable by name.

### 2d. Security groups

New SG for Prometheus, plus ingress on the exporter ports of the app tiers
**sourced from the Prometheus SG** (not `0.0.0.0/0`) — this is the
server-to-server pattern the batch has been taught.

| SG            | Rule                                    | Source                    |
|---------------|-----------------------------------------|---------------------------|
| prometheus    | ingress TCP `9090` (UI)                 | `var.browser_cidr`        |
| prometheus    | ingress TCP `22`                        | admin CIDR                |
| prometheus    | egress all                              | `0.0.0.0/0` (reach AWS API + scrape targets) |
| mysql         | ingress TCP `9100`, `9104`              | prometheus SG id          |
| backend       | ingress TCP `9100`, `var.backend_port`  | prometheus SG id          |
| frontend      | ingress TCP `9100`                      | prometheus SG id          |

The backend `/metrics` is served by the Express app on the same port as the API
(`var.backend_port`), so that port — already open to the frontend — additionally
needs ingress from the Prometheus SG.

Prefer standalone `aws_security_group_rule` resources referencing
`source_security_group_id = aws_security_group.prometheus.id` so the app-tier SGs
don't churn on every edit.

---

## 3. `userdata/prometheus.sh` (new, self-contained)

Roboshop-style, same skeleton as the other scripts. Steps:

1. Standard header: root-check gate, `LOGS_FOLDER=/var/log/expense`,
   `LOGS_FILE=$LOGS_FOLDER/prometheus-setup.log`, `R/G/Y/N` color vars,
   `VALIDATE()`.
2. Create service user (idempotent):
   ```bash
   id prometheus &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin prometheus
   ```
3. Download + install (version injected by templatefile):
   ```bash
   cd /opt
   curl -sLO https://github.com/prometheus/prometheus/releases/download/v${prometheus_version}/prometheus-${prometheus_version}.linux-amd64.tar.gz
   tar -xzf prometheus-${prometheus_version}.linux-amd64.tar.gz
   ln -sfn prometheus-${prometheus_version}.linux-amd64 /opt/prometheus
   ```
4. Config + data dirs, owned by the service user:
   ```bash
   mkdir -p /etc/prometheus /var/lib/prometheus
   ```
5. Write `/etc/prometheus/prometheus.yml` (section 5 below) via heredoc.
6. `chown -R prometheus:prometheus /opt/prometheus-${prometheus_version}.linux-amd64 /etc/prometheus /var/lib/prometheus`
7. systemd unit `/etc/systemd/system/prometheus.service`:
   ```ini
   [Unit]
   Description=Prometheus
   Documentation=https://prometheus.io/docs/
   After=network-online.target
   Wants=network-online.target

   [Service]
   User=prometheus
   Group=prometheus
   Restart=on-failure
   ExecStart=/opt/prometheus/prometheus \
     --config.file=/etc/prometheus/prometheus.yml \
     --storage.tsdb.path=/var/lib/prometheus \
     --web.enable-lifecycle
   [Install]
   WantedBy=multi-user.target
   ```
   `--web.enable-lifecycle` lets you `curl -X POST http://localhost:9090/-/reload`
   without restarting.
8. `systemctl daemon-reload && systemctl enable --now prometheus`, each wrapped in
   `VALIDATE`.
9. **Also install node_exporter here** (section 4 block) so the monitoring host
   monitors itself — it's tagged `Project=expense`, so the node_exporter SD job
   will discover it and you don't want a permanently-down target.

---

## 4. node_exporter block (paste into `mysql.sh`, `backend.sh`, `frontend.sh`, `prometheus.sh`)

Per the no-shared-`common.sh` rule, this block is **duplicated verbatim** into
each script rather than factored out. `node_exporter_version` is templatefile-
injected.

```bash
# ---- node_exporter ----
id node_exporter &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin node_exporter
VALIDATE $? "Creating node_exporter user"

cd /opt
curl -sLO https://github.com/prometheus/node_exporter/releases/download/v${node_exporter_version}/node_exporter-${node_exporter_version}.linux-amd64.tar.gz
tar -xzf node_exporter-${node_exporter_version}.linux-amd64.tar.gz
ln -sfn node_exporter-${node_exporter_version}.linux-amd64 /opt/node_exporter
chown -R node_exporter:node_exporter /opt/node_exporter-${node_exporter_version}.linux-amd64
VALIDATE $? "Installing node_exporter"

cat > /etc/systemd/system/node_exporter.service <<'UNIT'
[Unit]
Description=Node Exporter
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Restart=on-failure
ExecStart=/opt/node_exporter/node_exporter

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now node_exporter
VALIDATE $? "Starting node_exporter"
```

Note the unit heredoc is quoted (`<<'UNIT'`) so bash doesn't expand anything
inside it — but the surrounding `${node_exporter_version}` is **unquoted** on
purpose so `templatefile()` injects it. Keep that distinction straight.

---

## 5. mysqld_exporter (mysql.sh only)

### 5a. MySQL user — add to the tier's SQL (idempotent, matches existing pattern)

```sql
CREATE USER IF NOT EXISTS 'exporter'@'localhost'
  IDENTIFIED BY '${db_exporter_password}'
  WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'localhost';
FLUSH PRIVILEGES;
```

`db_exporter_password` is templatefile-injected from the new sensitive var
(section 6). `MAX_USER_CONNECTIONS 3` caps the monitoring account so it can never
exhaust the pool — the least-privilege lesson, made concrete.

### 5b. Exporter install block (mysql.sh)

```bash
# ---- mysqld_exporter ----
id mysqld_exporter &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin mysqld_exporter
VALIDATE $? "Creating mysqld_exporter user"

cd /opt
curl -sLO https://github.com/prometheus/mysqld_exporter/releases/download/v${mysqld_exporter_version}/mysqld_exporter-${mysqld_exporter_version}.linux-amd64.tar.gz
tar -xzf mysqld_exporter-${mysqld_exporter_version}.linux-amd64.tar.gz
ln -sfn mysqld_exporter-${mysqld_exporter_version}.linux-amd64 /opt/mysqld_exporter
chown -R mysqld_exporter:mysqld_exporter /opt/mysqld_exporter-${mysqld_exporter_version}.linux-amd64
VALIDATE $? "Installing mysqld_exporter"

mkdir -p /etc/mysqld_exporter
cat > /etc/mysqld_exporter/.my.cnf <<CNF
[client]
user=exporter
password=${db_exporter_password}
host=127.0.0.1
port=3306
CNF
chmod 600 /etc/mysqld_exporter/.my.cnf
chown -R mysqld_exporter:mysqld_exporter /etc/mysqld_exporter
VALIDATE $? "Writing mysqld_exporter credentials"

cat > /etc/systemd/system/mysqld_exporter.service <<'UNIT'
[Unit]
Description=MySQLd Exporter
Documentation=https://github.com/prometheus/mysqld_exporter
After=network-online.target

[Service]
User=mysqld_exporter
Group=mysqld_exporter
Restart=on-failure
ExecStart=/opt/mysqld_exporter/mysqld_exporter --config.my-cnf=/etc/mysqld_exporter/.my.cnf

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now mysqld_exporter
VALIDATE $? "Starting mysqld_exporter"
```

Two things that bit us during the manual install and must stay this way:
- `host=127.0.0.1`, not `localhost` — forces TCP over loopback; the Go MySQL
  driver treats `localhost` as a unix socket.
- The `.my.cnf` heredoc is **unquoted** (`<<CNF`) so `${db_exporter_password}` is
  injected by templatefile. The systemd unit heredoc is quoted (`<<'UNIT'`).

---

## 6. `variables.tf` additions

```hcl
variable "prometheus_version"      { default = "3.13.2" }
variable "node_exporter_version"   { default = "1.9.1" }
variable "mysqld_exporter_version" { default = "0.17.2" } # verify tag matches the binary already installed
variable "project_tag"             { default = "expense" }

variable "db_exporter_password" {
  default   = "ExporterMon@1"   # lab default; override with -var for anything real
  sensitive = true
}
```

Reuse existing `var.region`, `var.backend_port`, `var.browser_cidr`,
`var.db_root_password`. **Verify the three exporter version tags actually exist**
on their GitHub releases pages before applying — a wrong tag 404s the `curl` and
the VALIDATE fails the boot. In particular pin `mysqld_exporter_version` to
whatever you already installed by hand (the March build).

---

## 7. `prometheus.yml` with EC2 service discovery (written by prometheus.sh)

Written via **unquoted** heredoc in `prometheus.sh` so `templatefile()` injects
`${region}` and `${backend_port}`. **Do not** put any `${1}`-style relabel
replacement literals in here — that collides with `templatefile()`. The relabels
below deliberately map tag → label without capture groups, so there's nothing to
escape. If you ever need a `${1}` replacement, write it as `$${1}`.

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "node_exporter"
    ec2_sd_configs:
      - region: ${region}
        port: 9100
        filters:
          - name: "tag:Project"
            values: ["expense"]
    relabel_configs:
      - source_labels: [__meta_ec2_instance_state]
        regex: running
        action: keep
      - source_labels: [__meta_ec2_tag_Name]
        target_label: instance
      - source_labels: [__meta_ec2_tag_Tier]
        target_label: tier

  - job_name: "mysqld_exporter"
    ec2_sd_configs:
      - region: ${region}
        port: 9104
        filters:
          - name: "tag:Project"
            values: ["expense"]
          - name: "tag:Tier"
            values: ["database"]
    relabel_configs:
      - source_labels: [__meta_ec2_tag_Name]
        target_label: instance
      - source_labels: [__meta_ec2_tag_Tier]
        target_label: tier

  - job_name: "expense-backend"
    ec2_sd_configs:
      - region: ${region}
        port: ${backend_port}
        filters:
          - name: "tag:Project"
            values: ["expense"]
          - name: "tag:Tier"
            values: ["backend"]
    relabel_configs:
      - source_labels: [__meta_ec2_tag_Name]
        target_label: instance
      - source_labels: [__meta_ec2_tag_Tier]
        target_label: tier
```

How SD replaces the hand-written targets:
- `ec2_sd_configs` calls `DescribeInstances` (via the instance-profile role),
  gets private IP + tags for each match, and sets `__address__` to
  `<private_ip>:<port>`. Private IP falls out automatically — no more choosing
  public-vs-private by hand.
- `filters` narrows at the AWS API; `relabel_configs` then shapes labels and, for
  node_exporter, keeps only `running` instances.
- The `node_exporter` job intentionally has **no Tier filter**, so it discovers
  all four boxes (including Prometheus itself). `mysqld_exporter` and
  `expense-backend` filter by `Tier` so each hits exactly one box.

---

## 8. Acceptance criteria

- `terraform fmt` clean; `terraform validate` passes; `bash -n userdata/*.sh`
  passes on every edited script.
- `terraform plan` **adds** prometheus instance + IAM role/profile + SG rules +
  route53 record, and shows only **in-place tag updates** on the three app
  instances — no replacements.
- After apply, on the Prometheus box: `systemctl is-active prometheus` = active;
  `curl -s localhost:9090/-/ready` returns ready.
- Prometheus **Status → Targets** shows four jobs, all `UP`:
  `prometheus`, `node_exporter` (4 targets), `mysqld_exporter` (1),
  `expense-backend` (1).
- PromQL `mysql_up == 1` (exporter reached MySQL) and
  `up{job="expense-backend"} == 1` (app `/metrics` reachable).
- No AWS keys anywhere in `prometheus.yml` or on disk — SD auth is the instance
  profile only.

---

## 9. Convention-compliance checklist (must match repo context file)

- [ ] No shared `common.sh`; node_exporter block duplicated into each script.
- [ ] Every script keeps root-check, `LOGS_FOLDER=/var/log/expense`,
      `<tier>-setup.log`, `R/G/Y/N`, `VALIDATE()`.
- [ ] Idempotent: `id <user>` before `useradd`; `CREATE USER IF NOT EXISTS` for
      the mysql `exporter` user.
- [ ] `${var}` only for templatefile-injected values; bash vars stay `$VAR`
      (no braces) or live inside quoted heredocs. No stray `${...}` in
      `prometheus.yml` beyond `${region}`/`${backend_port}`.
- [ ] Lab-value passwords defaulted, overridable via `-var`; don't invent a
      "better" default.
- [ ] No `git` commands run in this directory.
- [ ] README drift (ALB/iam naming) left untouched unless the user asks.
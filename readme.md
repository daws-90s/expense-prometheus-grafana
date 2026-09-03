# Getting Started

What this repo actually builds, why it's structured the way it is, what
you need before `terraform apply`, and what to do once it's up: where to
look, what each alert and dashboard means, and how to prove the monitoring
stack actually works by breaking things on purpose.

## 1. What you must provide (read this first)

Nothing below will finish applying until these are set. All of them go in
`terraform.tfvars` (gitignored, yours alone -- see `.gitignore`'s
`*.tfvars` rule), which you create by copying the template:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Then fill in, roughly in order of "will fail loudest if you skip it":

1. `domain_name` + `route53_zone_id` -- a domain/zone you actually own in
   Route53. No default -- Terraform errors immediately if these aren't set.
2. `ssh_cidr`, `browser_cidr` -- also no default, also required. The
   template ships `0.0.0.0/0` (open to the whole internet) as a
   placeholder -- narrow both to your own IP before applying anything you
   care about.
3. **Alertmanager's email + Slack settings** -- also required, no
   defaults, because Alertmanager refuses to start with a blank SMTP
   smarthost:
   - `alertmanager_smtp_host`, `alertmanager_smtp_from`,
     `alertmanager_smtp_auth_username`, `alertmanager_smtp_auth_password`,
     `alertmanager_email_to` -- for Gmail: host is `smtp.gmail.com:587`,
     username is your full address, and the password must be an **app
     password** (myaccount.google.com/apppasswords), not your real one.
   - `alertmanager_slack_webhook_url`, `alertmanager_slack_channel` -- from
     a Slack app at api.slack.com/apps -> Incoming Webhooks -> Add New
     Webhook to Workspace.
   - Full explanation of what these drive is in section 10.
4. `db_root_password`, `db_app_password`, `db_exporter_password` -- these
   *do* have lab defaults, fine to leave for a short-lived demo; override
   for anything you'll leave running.
5. `aws_region` -- only if you're not using `us-east-1`.

`artifacts_base_url` is **not** on this list -- its default already points
at a public, populated repo (`daws-90s/expense-prometheus-grafana-docs`),
so leave it alone unless you're shipping your own app/dashboard changes.
Everything else in `variables.tf` (instance types, volume size, version
pins) has a working default and rarely needs touching for a first run.

## 2. What this repo builds, in plain terms

This is the "expense" app -- a small three-tier web app (MySQL, a Node.js
backend, an nginx frontend) -- plus a fourth box that watches the other
three: Prometheus, Alertmanager, Grafana, and blackbox_exporter.

Four EC2 instances, one job each:

```
 internet
    |
    v
[frontend]  nginx, serves the built UI, reverse-proxies /api/ to backend
    |
    v
[backend]   Node.js/Express API, port 8080
    |
    v
[mysql]     the database

[prometheus] a fifth box, off to the side -- not in the request path.
             It scrapes the other three (and itself) over the private
             network, and hosts Alertmanager + Grafana + blackbox_exporter.
```

Each box only trusts the box one hop upstream (frontend's security group is
the only one open to the internet; backend only accepts traffic from
frontend's security group; mysql only accepts traffic from backend's). This
is deliberate -- it's the same "SG-scoped-to-one-hop" pattern taught
elsewhere in the course, applied for real here.

## 3. The moving pieces (and why there are two repos, not one)

**This repo (`expense-prometheus-grafana`)** is Terraform. It describes
*infrastructure*: the four EC2 instances, their security groups, IAM roles,
Route53 DNS records, and the Prometheus alerting/recording rules. Running
`terraform apply` here creates AWS resources.

But an EC2 instance with nothing on it is useless -- something has to
install MySQL, build and start the backend, build and deploy the frontend,
and install Prometheus/Alertmanager/Grafana/the exporters. That's what
`user_data` does: each instance boots with a shell script
(`userdata/mysql.sh`, `userdata/backend.sh`, `userdata/frontend.sh`,
`userdata/prometheus.sh`) that cloud-init runs automatically on first boot,
no SSH or Ansible pass required.

Those scripts need two kinds of things from outside this repo:

1. **App/dashboard artifacts** -- the actual backend code, frontend build,
   Grafana dashboard JSON, and Prometheus rule files, packaged as
   `.tar.gz` files. These live in a **sibling repo**,
   `expense-prometheus-grafana-docs`, under its `artifacts/` folder. Every
   `userdata/*.sh` script does a plain `curl` against
   `raw.githubusercontent.com/.../artifacts/...` to fetch its tarball --
   `var.artifacts_base_url` in `variables.tf` is what points at that repo.
   **If that repo isn't pushed and public, every instance's boot fails at
   the curl step.** This is the single most common reason a fresh `apply`
   doesn't come up cleanly -- check that first.

2. **Upstream binaries** -- Prometheus, Alertmanager, node_exporter,
   mysqld_exporter, and blackbox_exporter itself. These come straight from
   `github.com/prometheus/<project>` release tarballs, pinned by version
   variables (`prometheus_version`, `alertmanager_version`, etc.) so a boot
   is reproducible.

So: this repo = infrastructure + orchestration. The docs repo = the actual
software being deployed. You need both -- but the default docs repo
(`daws-90s/expense-prometheus-grafana-docs`) is already public and
populated, so as-is `artifacts_base_url` just works; you don't need to set
anything up there yourself unless you're changing the app/dashboards and
publishing your own fork.

## 4. Before you touch Terraform -- a checklist

Have these ready first, in order:

- [ ] **An AWS account and credentials** Terraform can use (`aws configure`,
      or `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` env vars) with
      permission to create EC2 instances, security groups, IAM roles/
      instance profiles, and Route53 records.
- [ ] **Terraform >= 1.7.0** installed (`versions.tf` enforces this).
- [ ] **A domain you actually control in Route53**, plus its hosted zone
      ID. The defaults in `variables.tf` (`daws86s.fun` and its zone ID)
      belong to this course's account -- they will not work for you.
- [ ] **A Gmail (or other SMTP) account and app password, and a Slack
      incoming webhook** -- see section 1, item 3.
- [ ] Decided values for the rest of section 1 -- mainly whether you're
      okay with the lab-default passwords and wide-open CIDRs for a
      short-lived demo.

You do **not** need to pre-create a VPC, subnets, or an EC2 key pair --
this repo looks up the account's default VPC (`data.tf`) and boots
instances without a key pair (SSM/the AMI handles access instead).

## 5. What "setting it up" actually means, step by step

1. **Set your variables** -- `cp terraform.tfvars.example terraform.tfvars`
   and fill it in per section 1 above. `terraform.tfvars` is gitignored
   precisely because these values are yours, not something to commit.

2. **Initialize Terraform:**
   ```bash
   terraform init
   ```
   This downloads the AWS provider and sets up local state
   (`terraform.tfstate` -- this repo uses local state, not S3, since it's a
   single-instructor demo setup per `versions.tf`).

3. **Review the plan before applying anything:**
   ```bash
   terraform plan
   ```
   Read it. You're expecting it to **create** four instances, their
   security groups, IAM roles/profiles, and four Route53 records. If it
   proposes to **replace** something that's already running and you didn't
   expect that, stop and figure out why before continuing.

4. **Apply:**
   ```bash
   terraform apply
   ```
   Confirm with `yes` when prompted. This creates the AWS resources *and*
   kicks off each instance's `user_data` script -- there's no separate
   deploy step.

5. **Wait for cloud-init to finish.** The tiers aren't independent:
   `backend` waits on mysql's DNS record to exist (its script creates a
   MySQL user against `mysql.<domain>`), and `frontend` waits on backend's
   DNS record (nginx needs `backend.<domain>` to resolve at config-reload
   time). So mysql, then backend, then frontend come up in sequence, not
   all at once. `prometheus` has no such dependency and boots in parallel
   with the others. Budget a few minutes total.

6. **Get the URLs/IPs Terraform created:**
   ```bash
   terraform output frontend_fqdn         # the app itself
   terraform output prometheus_fqdn       # Prometheus :9090, Alertmanager :9093, Grafana :3000
   ```

7. **Verify it actually came up.** Open the frontend URL and click around.
   Open `<prometheus_fqdn>:9090/targets` and confirm all scrape jobs show
   `UP`. If something's down, SSH in and check the relevant log first:
   ```bash
   ssh ec2-user@<public-ip>
   sudo tail -f /var/log/expense/mysql-setup.log      # or backend-setup.log / frontend-setup.log / prometheus-setup.log
   sudo systemctl status expense-backend               # on the backend instance
   sudo systemctl status nginx                         # on the frontend instance
   sudo systemctl status prometheus alertmanager grafana-server blackbox_exporter   # on the prometheus instance
   ```
   A `FAILURE` line in the log names the exact step that broke -- most
   likely cause is `expense-prometheus-grafana-docs`'s `artifacts/` folder
   not being pushed/public yet, since every tier's script `curl`s from
   there. Section 8 below covers target health in more detail.

## 6. Inside each instance: what the boot script is actually doing

Step 5.5 above says "wait for cloud-init to finish" -- this is what's
happening on each box during that wait. Every script logs each step to
`/var/log/expense/<tier>-setup.log` and stops on the first failure (the
`VALIDATE` helper you'll see in every script), so if a box comes up broken,
that log tells you exactly which line it died on.

Every one of the four scripts also ends by installing **node_exporter** --
so Prometheus can monitor host-level metrics (CPU, memory, disk) on all
four boxes, including itself. It's called out explicitly as the last step
in each list below -- yes, mysql included, alongside mysqld_exporter.

### mysql (`userdata/mysql.sh`)

1. `dnf install mysql-server`, then enable and start `mysqld`.
2. Download and extract the `expense-mysql-v1` artifact tarball -- it
   contains `schema.sql`, `seed.sql`, and `monitor.mysql`.
3. Load `schema.sql` (creates the `expense_db` database and its tables) as
   the local root user over the Unix socket -- no password needed for
   that, same as doing it by hand on the console.
4. Create the `expense_app` MySQL user (password from
   `var.db_app_password`) and grant it `SELECT/INSERT/UPDATE/DELETE` on
   `expense_db` -- this is the account the backend connects as.
5. Load `seed.sql` (sample rows so the app isn't empty on first load).
6. Run `monitor.mysql` (shipped in the artifact, not retyped here) after
   swapping its lab password placeholder for the real
   `var.db_exporter_password` -- this creates the least-privilege
   `exporter@localhost` account mysqld_exporter connects as.
7. Install **mysqld_exporter** as a systemd service, pointed at that
   exporter account via `/etc/mysqld_exporter/.my.cnf`.
8. Install **node_exporter** too -- host-level metrics (CPU/memory/disk)
   for the mysql box itself, separate from and in addition to
   mysqld_exporter above. So this box ends up running three things:
   `mysqld`, `node_exporter`, and `mysqld_exporter`.

### backend (`userdata/backend.sh`)

1. Install Node.js 20.
2. Create a system user `expense` and an `/app` directory for it to own.
3. Download and extract the `expense-backend-v1` artifact (the built
   Node.js app) into `/app`, then `npm install`.
4. Write `/app/.env` -- `DB_HOST=mysql.<domain>`, the app DB credentials,
   `PORT=8080`, and `ENABLE_DEBUG_ROUTES=false` (flip this to `true` later
   -- see section 12).
5. `chown` `/app` to the `expense` user, install the `backend.service`
   systemd unit that ships inside the artifact, and start it.
6. Install **node_exporter** -- host-level metrics for this box.

This is the step that needs `mysql.<domain>` to already resolve -- which is
exactly why `ec2.tf` makes this instance `depends_on` mysql's Route53
record, not just the mysql instance existing.

### frontend (`userdata/frontend.sh`)

1. Install Node.js 20 and nginx.
2. Download and extract the `expense-frontend-v1` artifact -- this one
   ships as *source*, not a pre-built bundle, so the instance itself runs
   `npm install` and `npm run build` (a Vite build, with the API base URL
   left unset so the built app calls `/api/...` as a relative path).
3. Wipe nginx's default page and copy the build output (`dist/*`) into
   `/usr/share/nginx/html/`.
4. Take the artifact's `nginx.conf` template, substitute the real
   `backend.<domain>` hostname for its placeholder, and drop the result
   into `/etc/nginx/default.d/expense.conf` -- this is the reverse-proxy
   rule that turns `/api/...` into a call to the backend's private IP.
5. `nginx -t` to validate the config, then start nginx.
6. Install **node_exporter** -- host-level metrics for this box.

Same dependency pattern as backend: this instance `depends_on` backend's
Route53 record, because step 4 needs `backend.<domain>` to resolve at
config-reload time.

### prometheus (`userdata/prometheus.sh`)

This is the biggest script -- it sets up six separate services. In order:

1. Create a `prometheus` system user, download and install the Prometheus
   binary.
2. Download a *second* artifact -- not app code this time, but Grafana
   dashboard JSON and the `recording_rules.yaml`/`alerting_rules.yaml`
   files -- and copy the rule files into `/opt/prometheus/`. (They're
   pulled from the artifacts repo rather than embedded in this script
   because the dashboard JSON alone is bigger than EC2's `user_data` size
   limit.)
3. Write `/opt/prometheus/prometheus.yml` from scratch: an
   `alerting.alertmanagers` target pointed at `localhost:9093` (step 4
   below), the `rule_files` pointed at the two files from step 2, and five
   scrape jobs:
   - `prometheus` -- itself, static target.
   - `node_exporter` -- **EC2 service discovery**, not a static list. It
     calls the AWS API (via the instance's IAM role, no static keys) for
     every instance tagged `Project=expense` that's currently `running`,
     and turns each one into a scrape target on port 9100. This is why
     tagging every instance correctly in `ec2.tf` matters -- SD is how
     Prometheus finds mysql/backend/frontend/itself without anyone typing
     an IP into a config file.
   - `mysqld_exporter` -- same EC2 SD mechanism, filtered to
     `Tier=database`, port 9104.
   - `expense-backend` -- same idea, filtered to `Tier=backend`, scraping
     the backend's `/metrics` on its app port.
   - `blackbox-http` / `blackbox-https` -- these don't scrape a target
     directly; they ask **blackbox_exporter's `/probe` endpoint** (on
     `localhost:9115`) to go check `backend.<domain>/health` and
     `https://<domain>` from the outside, the way a real user/monitor
     would.
4. Install Prometheus as a systemd service and start it.
5. Install **Alertmanager**, right alongside Prometheus on the same box:
   create an `alertmanager` user, download the binary, write
   `/opt/alertmanager/alertmanager.yml` with the SMTP/Slack values from
   `terraform.tfvars` templated in, and start it as a systemd service on
   port 9093. Full detail on what that config actually does is in
   section 10.
6. Install **blackbox_exporter**, with two probe modules defined in
   `/etc/blackbox/blackbox.yml`: `http_2xx` (plain HTTP) and
   `http_2xx_tls` (HTTPS, with `insecure_skip_verify: true` so the
   1-hour self-signed demo cert on the frontend doesn't fail validation).
7. Install **Grafana**, and *provision* it before it first starts:
   - a datasource config pointing at `http://localhost:9090` with a fixed
     UID (`prometheus`) -- fixed so the dashboard JSON files, which
     reference that UID, wire up automatically with zero manual clicking;
   - a dashboard-provider config pointing at `/etc/grafana/dashboards`;
   - the actual dashboard JSON files, copied in from the artifact
     downloaded in step 2.
8. Start `grafana-server`.
9. Install **node_exporter** on itself too -- self-monitoring, so this box
   shows up in the `node_exporter` scrape job (step 3) the same as the
   other three, instead of being a blind spot.

Unlike the other three tiers, this one has no `depends_on` -- EC2 service
discovery just finds targets whenever they show up, so Prometheus can boot
in parallel with mysql/backend/frontend instead of waiting on them.

## 7. Accessing everything, once it's up

One instance, three UIs, all on `prometheus_fqdn` (or its public IP)
across three ports -- plus the app itself on a separate box:

| What | URL | Notes |
|---|---|---|
| The app | `terraform output frontend_fqdn` | The actual expense UI, port 80/443. |
| Prometheus | `<prometheus_fqdn>:9090` | Targets, alert state, ad-hoc PromQL. |
| Alertmanager | `<prometheus_fqdn>:9093` | Firing alerts, silences. |
| Grafana | `<prometheus_fqdn>:3000` | Dashboards. First login is `admin`/`admin` -- Grafana forces a password change immediately after, nothing to configure for that. |

SSH access (for logs, or manually triggering faults per section 12) is
`ssh ec2-user@<public-ip>` -- no key pair needed, per section 2's note
about SSM/the AMI handling access.

## 8. Prometheus: checking target health

`<prometheus_fqdn>:9090/targets` is the first place to look if anything
seems wrong. Every scrape job from section 6's step 3 shows up here with a
state:

- **UP** -- last scrape succeeded.
- **DOWN** -- Prometheus reached the target but the scrape itself failed
  (service not listening, wrong port, etc.) -- the **Error** column on this
  page says why.
- **Missing entirely** -- for the EC2-service-discovery jobs
  (`node_exporter`, `mysqld_exporter`, `expense-backend`), a target that
  doesn't appear at all is a *different* problem than DOWN: it means SD
  never found a matching instance in the first place -- check the
  instance is tagged correctly (`Project=expense`, and `Tier=database`/
  `backend` for the tier-filtered jobs) and is actually `running`.

`<prometheus_fqdn>:9090/graph` is the ad-hoc query UI -- useful for
checking a specific thing directly instead of hunting through a dashboard,
e.g. `up{job="expense-backend"}` or `mysql_up`.

`<prometheus_fqdn>:9090/rules` lists every recording and alerting rule
loaded from the two files in `prometheus/`, with its current health and
last evaluation time -- if a rule has a syntax problem or references a
metric that doesn't exist, it shows up here as an error rather than
silently doing nothing.

## 9. Alert rules: what's actually being watched

`prometheus/alerting-rules.yaml` defines four groups, each with a
`severity` label of `warning` or `critical` -- that label is what
Alertmanager (section 10) uses to decide whether an alert goes to Slack
only, or Slack **and** email.

Every alert below fires once its condition has held **for 2 minutes**
(`for: 2m` in the rule) -- tuned deliberately short so you can trigger a
fault and watch it reach Slack/email in a couple of minutes, not five (see
section 12 for the exact timeline). The two exceptions are
`DiskWillFillIn4Hours` (`for: 10m` -- it's predictive, not a threshold, so
a short `for:` would just make it noisy) and the SSL cert alerts
(`for: 1h` -- a stability window against a cert's expiry, not something
you want to fire on transient scrape jitter).

**`node_alerts`** (host-level, every box) -- `HighCPUUsage`/
`CriticalCPUUsage` (>70%/>90%), `HighMemoryUsage`/`CriticalMemoryUsage`
(>70%/>90%), `HighDiskUsage`/`CriticalDiskUsage` (>80%/>90%),
`DiskWillFillIn4Hours` (a *predictive* alert -- extrapolates the current
fill rate forward, not just a threshold), `HighLoadAverage` (>3, sized for
a t3.micro's 2 vCPUs), and `NodeDown` (node_exporter itself unreachable).

**`mysql_alerts`** -- `MySQLDown` (`mysql_up == 0`, critical) and
`MySQLHighConnectionUsage` (>80% of `max_connections`, warning).

**`backend_alerts`** (RED-pattern: Rate, Errors, Duration) --
`BackendHighErrorRate` (5xx ratio >5%, computed over a rolling 5m window --
that 5m is the *ratio's* smoothing window, separate from the 2m the
breach has to persist before the alert fires), `BackendHighLatencyP95`
(p95 latency >1s, same 5m-window/2m-`for:` split -- this is where
histogram buckets come in, see section 14), and `BackendDown` (target
unreachable).

**`blackbox_alerts`** (synthetic, external-perspective checks) --
`ProbeFailing` (the probe's 5m-rolling success ratio has dropped below
100%, critical), `SSLCertExpiringSoon` (<30 days remaining, warning), and
`SSLCertExpiringCritical` (<3 days remaining, critical).

Every alert's underlying PromQL actually queries a **recording rule**
(`prometheus/recording_rules.yaml`), not the raw metric directly -- e.g.
`HighCPUUsage` evaluates `instance:node_cpu_utilisation:rate5m > 70`, where
that left-hand side is pre-computed every 30s from
`rate(node_cpu_seconds_total{mode="idle"}[5m])`. This is the standard
reason to split rules into recording + alerting files: the expensive
`rate()`/`histogram_quantile()` math runs once on a schedule, and both the
alert and any dashboard panel that wants the same number just reference the
cheap, pre-computed series.

## 10. Alertmanager: routing alerts to Slack and email

Alertmanager runs on the same box as Prometheus (section 6, step 5),
config at `/opt/alertmanager/alertmanager.yml`, built from the
`alertmanager_*` variables in your `terraform.tfvars`. The routing logic:

```
route:
  receiver: warning-alerts          # default -- Slack only
  routes:
    - match: {severity: critical}
      receiver: critical-alerts     # Slack + email
```

So every alert from section 9 lands in Slack (`alertmanager_slack_channel`)
regardless of severity, and the `critical`-labeled ones *additionally* send
an email to `alertmanager_email_to`. `group_wait: 30s` and
`group_interval: 5m` mean Alertmanager waits briefly to batch related
alerts into one notification instead of spamming one message per rule;
`repeat_interval` (4h for warnings, 1h for criticals) is how long it waits
before re-notifying about something that's still firing.

To see this working: `<prometheus_fqdn>:9093` shows currently firing and
pending alerts, and lets you create a **silence** (useful while you're
deliberately triggering faults in section 12 and don't want to keep
getting paged for the same known test). The path an alert takes is:
Prometheus rule evaluates true -> stays `pending` for its `for:` duration
-> flips to `firing` (visible on Prometheus's `/alerts`) -> Prometheus
pushes it to Alertmanager on `localhost:9093` -> Alertmanager groups/routes
it per the tree above -> Slack message appears, and email if critical.

If Alertmanager isn't sending anything: SSH in and check
`sudo systemctl status alertmanager` and
`sudo journalctl -u alertmanager -n 50` -- a bad SMTP smarthost or an
invalid Slack webhook URL both cause the service to either fail to start
or log a delivery error per notification attempt, rather than failing
silently.

## 11. Grafana: the seven dashboards

All seven are provisioned automatically (section 6, step 7) into a
"Expense App" folder -- nothing to import by hand.

1. **Fleet Overview** -- the "is anything on fire" first stop. `Fleet
   Health (up)` across all four boxes, `MySQL Exporter Health`, `Backend
   Error Rate %`, and CPU/Memory/Request-rate rolled up across the whole
   fleet on one screen.
2. **Node Host USE** (Utilization/Saturation/Errors, per instance) -- CPU,
   Memory, Disk Used % per mount, Load Average, Network I/O, Disk I/O, and
   the `Disk Fill Prediction` panel that backs `DiskWillFillIn4Hours`. The
   drill-down when a `node_alerts` alert fires.
3. **MySQL** -- Connections Used %, Threads Running, Query Throughput
   (QPS), Slow Queries/sec, InnoDB Buffer Pool Hit Ratio, Row Lock
   Contention, Network I/O. The drill-down for `mysql_alerts`.
4. **Application RED** -- Request Rate by Route, Error Rate % by Route,
   `Latency p50/p95/p99` (the histogram_quantile panel -- section 14),
   In-Flight Requests, Status Code Breakdown. All panels take a `$route`
   template variable so you can isolate one endpoint. The drill-down for
   `backend_alerts`.
5. **Business Metrics** -- Expenses Created/sec, Amount Tracked
   (Rupees/sec), Average Expense Amount, correlated against infra load.
   **Worth knowing:** this dashboard queries `expenses_created_total` and
   `expense_amount_rupees_total` directly -- custom application metrics
   that `recording_rules.yaml` explicitly leaves commented out
   ("uncomment if `curl .../metrics` shows these"). If the backend build
   you're running doesn't emit those two metrics, this dashboard's panels
   will simply render empty rather than erroring -- worth checking
   `curl backend.<domain>:8080/metrics | grep -E "expenses_created|expense_amount"`
   on a running box if it looks blank.
6. **Blackbox Synthetic** -- Probe Success, Probe Duration, HTTP Status
   Code Returned, Probe Phase Breakdown, SSL Certificate Expiry. The
   drill-down for `blackbox_alerts`, and the only dashboard measuring the
   app from the *outside* rather than from exporter-reported internals.
7. **SLO Error Budget** -- covered on its own in section 13.

## 12. Inducing faults, and watching them flow through

The mechanism is the same for every alert, and worth understanding once
rather than per-row:

```
you trigger a condition on a box
        |
        v
node_exporter / mysqld_exporter / backend metrics change
        |
        v
visible immediately in the matching Grafana dashboard (section 11)
        |
        v
Prometheus rule crosses its threshold -> "pending" (section 8's /alerts)
        |
        v
stays true for 2m (section 9's `for:`) -> "firing"
        |
        v
Alertmanager receives it, groups + routes by severity (section 10)
        |
        v
Slack message within ~30s more (group_wait), and email too if critical
```

End to end, that's roughly **2-3 minutes** from triggering a fault to
seeing it land in Slack/email: 2m for the rule's `for:` duration, plus up
to 15s for Prometheus's next evaluation cycle, plus Alertmanager's 30s
`group_wait` before it sends the first notification for a new group.

### App-level (backend `/debug/*` routes) -- reachable from a browser

The backend ships fault-injection routes (full list in the docs repo's
`backend-api.md`), gated behind `ENABLE_DEBUG_ROUTES` (default `false` in
`userdata/backend.sh`'s `.env` -- step 4 of section 6's backend
walkthrough). Flip it once over SSH:

```bash
ssh ec2-user@<backend-ip>
sudo sed -i 's/ENABLE_DEBUG_ROUTES=false/ENABLE_DEBUG_ROUTES=true/' /app/.env
sudo systemctl restart expense-backend
```

After that, `nginx.conf` (and `nginx-tls.conf`, for the HTTPS demo) proxy
`location /debug/` to the backend the same way `/api/` does -- so these are
plain URLs anyone can open or `curl`, no SSH needed to trigger them:

| URL | Effect | Alert it drives |
|---|---|---|
| `https://<domain>/debug/error` | Always `500`, logs an error | `BackendHighErrorRate` |
| `https://<domain>/debug/slow?ms=<n>` | Sleeps `n`ms (default 3000) before `200` | `BackendHighLatencyP95` |
| `https://<domain>/debug/cardinality` | Increments a metric with a random label each call | cardinality/label-explosion demo (no dedicated alert -- watch `prometheus_tsdb_*` metrics) |

**This means no auth on those URLs** -- same as `/api/`. Fine for a
deliberate demo window (send `https://<domain>/debug/slow?ms=2000` to
someone and have them refresh it in a loop for a couple of minutes to
generate real `BackendHighLatencyP95` data), but flip
`ENABLE_DEBUG_ROUTES` back to `false` and restart when you're done rather
than leaving it open long-term -- repeated `/debug/cardinality` hits in
particular grow Prometheus's series count with junk labels the longer it's
left on.

Revert by flipping `ENABLE_DEBUG_ROUTES` back to `false` and restarting.
`/health` also returns a real `503` whenever the DB health check fails, so
stopping mysqld produces genuine 503s with no code changes at all.

### Infra-level (any tier, over SSH)

Timeouts below are sized for the new 2-minute `for:` -- a couple of
minutes of sustained load is enough, no need to hold a fault open for 5.

| Alert | How to trigger | Revert |
|---|---|---|
| `HighCPUUsage` / `CriticalCPUUsage` | `sudo dnf install -y stress-ng && stress-ng --cpu 2 --timeout 180s` | let it time out, or `pkill stress-ng` |
| `HighMemoryUsage` / `CriticalMemoryUsage` | `stress-ng --vm 1 --vm-bytes 90% --timeout 180s` | same |
| `HighDiskUsage` / `CriticalDiskUsage` | `fallocate -l 8G /tmp/fill.img` | `rm /tmp/fill.img` |
| `HighLoadAverage` | `stress-ng --cpu 4 --timeout 180s` (t3.micro is 2 vCPU) | let it time out |
| `NodeDown` | `sudo systemctl stop node_exporter` | `sudo systemctl start node_exporter` |
| `MySQLDown` | `sudo systemctl stop mysqld` (on the mysql box) | `sudo systemctl start mysqld` |
| `MySQLHighConnectionUsage` | loop of `mysql -e "SELECT SLEEP(180)" &` to hold connections open | `pkill mysql` |
| `BackendDown` | `sudo systemctl stop expense-backend` | `sudo systemctl start expense-backend` |
| `ProbeFailing` (blackbox) | `sudo systemctl stop nginx` on the frontend | `sudo systemctl start nginx` |
| `SSLCertExpiringSoon` / `SSLCertExpiringCritical` | run `expense-frontend-v1/cert-demo.sh` on the frontend -- issues a 1-hour self-signed cert, so `probe_ssl_earliest_cert_expiry` counts down for real | re-run the script to reissue |

`DiskWillFillIn4Hours` and the SSL cert alerts keep their longer `for:`
(10m / 1h -- section 9 explains why), so they're not fast to demo the same
way; everything else in this table should reach Slack in roughly 2-3
minutes of the trigger command.

Check probe results directly against blackbox_exporter before waiting on a
Prometheus scrape cycle:
```bash
ssh ec2-user@<prometheus-ip>
curl "http://localhost:9115/probe?target=https://<domain_name>&module=http_2xx_tls"
```

## 13. SLO and error budget (dashboard 7), checked

This dashboard measures one specific thing: the **backend tier's HTTP
request success rate** (`tier="backend"` in every panel's query) against a
hardcoded **99.5% target**. It does not cover mysql or frontend failures
directly, or blackbox-detected external outages -- those are `mysql_alerts`
and `blackbox_alerts`' job, and dashboard 6's, respectively.

The panels, and the math behind them (verified correct against standard
SRE error-budget formulas):

- **Current Availability (30d)** -- `1 - (5xx increase / total increase)`
  over a trailing 30-day window: straightforward success ratio.
- **Error Budget Remaining %** -- `(1 - error_ratio / (1 - 0.995)) * 100`.
  `(1 - 0.995) = 0.005` is the *allowed* error fraction for a 99.5% target;
  dividing the *actual* error ratio by that tells you what fraction of your
  budget is spent, and `1 -` that gives what's left. 100% = no errors yet
  this window; 0% = you've used your entire allowed error budget for the
  30 days; negative = you've blown through it and are already below 99.5%.
- **Error Budget Burn Rate (1h)** -- `current_error_rate / (1 - 0.995)`.
  This is the standard Google-SRE "burn rate" multiplier: `1.0` means
  you're consuming budget at exactly the rate that would exhaust it right
  as the 30-day window ends (borderline healthy); anything sustained above
  `1.0` means you'll breach the SLO before the window is up.
- **Total Requests / Total Errors (30d)** -- the raw counts the ratios
  above are built from, so you're not staring at a percentage with no
  sense of the volume behind it.
- **30-Day Availability Trend** -- the same success-ratio formula as the
  first panel, plotted daily, to see whether things are trending up or
  down rather than just reading today's snapshot.
- **Right Now: 5m Error Rate %** -- added specifically so this dashboard
  visibly reacts to a fault you just injected (section 12) instead of only
  the 30-day panels, which barely move from a couple of minutes of bad
  requests unless there's very little other traffic in the window. This
  panel uses the exact same 5-minute window `BackendHighErrorRate` alerts
  on, so it turns red at the same moment that alert would trip -- it's the
  "did my fault injection actually land" check, not a real SLO metric
  itself (a real SLO panel should stay boringly stable against a two-minute
  blip; that's the *other* panels doing their job correctly).

**Two things worth knowing if you touch this dashboard:** the `0.995`
target is typed directly into *every single panel's* PromQL expression --
it's not a Grafana variable or a single setting anywhere, so changing your
actual SLO target means editing roughly five queries by hand, and it's easy
to update four and miss one, leaving the dashboard internally
inconsistent. And because it's scoped to `tier="backend"` only, a mysql
outage that the backend degrades gracefully around (e.g. `/health`
returning a real `503`, per section 12, without every other route also
error-ing) may under-count how bad an incident actually was from the
user's perspective -- cross-check against dashboard 6 (blackbox, i.e. what
an actual external user would have seen) rather than trusting this
dashboard alone during a real incident review.

## 14. Histogram buckets: how the latency percentiles are computed

`Latency p50/p95/p99` on the *Application RED* dashboard, and the
`BackendHighLatencyP95` alert, both come from the same underlying metric:
`http_request_duration_seconds`, a Prometheus **histogram**. A histogram
doesn't store individual request latencies -- storing every single
duration would be far too expensive. Instead the backend exposes a small
set of cumulative counters, one per bucket boundary (`le`, "less than or
equal to"): how many requests finished in ≤0.1s, how many in ≤0.5s, ≤1s,
and so on up to `+Inf`.

`histogram_quantile()` takes that bucket data and interpolates a percentile
from it:

```
histogram_quantile(0.95, sum by (le, route) (rate(http_request_duration_seconds_bucket{route=~"$route"}[5m])))
```

-- "of requests to this route in the last 5 minutes, estimate the value
below which 95% of them completed." It's an *estimate*, bounded in
precision by how the bucket boundaries were chosen (wide buckets near the
value you care about give a coarser estimate than narrow ones) -- that
trade-off (cheap to store, approximate to query) is the entire point of the
histogram metric type, versus something like a raw summary that would need
to know quantiles in advance at scrape time.

This is also exactly what backs the p50/p95 **recording rules** in
`recording_rules.yaml` (`job_route:http_request_duration_seconds:p50`/
`p95`) -- the alert doesn't run `histogram_quantile()` itself, it just
reads the pre-computed result, same reasoning as section 9.

**Worth knowing:** the current dashboard only shows the three *derived*
quantile lines (p50/p95/p99) -- there's no panel visualizing the raw
bucket distribution itself. If you wanted to see the full latency
distribution shift over time (not just three summary lines), Grafana's
heatmap panel type pointed at
`sum by (le) (rate(http_request_duration_seconds_bucket[5m]))` with format
set to "Heatmap" would do it -- that's a gap in the current dashboard set,
not something built here; worth adding if you find yourself wanting more
than the three percentile lines.

## 15. Where to go next

- `expense-prometheus-grafana-docs/04-monitoring.md` (in the sibling repo)
  -- the manual runbook for the Prometheus/Grafana tier specifically, if
  you want to understand what `userdata/prometheus.sh` is doing step by
  step rather than just trusting the script.
- `CLAUDE.md` in this repo -- the original build spec for the
  observability layer (Prometheus, exporters, IAM, security groups). Useful
  if you want the *design reasoning*, not just the *how to run it*.

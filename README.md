# Terraform — expense-{env} infrastructure

Covers: default VPC lookup, four EC2 instances (mysql, backend, frontend,
prometheus) each bootstrapped via `user_data`, per-tier security groups
scoped to the SG one hop upstream only, Route53 records for all four
tiers, and a Prometheus + Grafana + blackbox_exporter monitoring stack
(EC2 service discovery, node_exporter everywhere, mysqld_exporter on
mysql, dashboards + alerting/recording rules provisioned into Grafana
and Prometheus automatically).

**`terraform apply` creates the infra AND deploys the apps.** Each
instance's `user_data` is `userdata/{mysql,backend,frontend,prometheus}.sh`,
rendered through `templatefile()` with the passwords/hostnames/versions
it needs. No separate Ansible/manual runbook pass is required for a
fresh stack. The scripts are self-contained (styled after
`daws-90s/shell-roboshop` -- no shared `common.sh`), log to
`/var/log/expense/*-setup.log` on each instance, and can be re-run by
hand over SSH (as root) if a step fails partway -- each is idempotent
enough to retry (`id`/`useradd` checks, `CREATE USER IF NOT EXISTS`,
`INSERT ... WHERE NOT EXISTS` in `seed.sql`).

Ordering is enforced with `depends_on`: `backend` depends on the
mysql Route53 record (its user_data creates the `expense_app` MySQL
user against `mysql.<domain>`), and `frontend` depends on the backend
Route53 record (nginx's `proxy_pass` resolves `backend.<domain>` at
config-reload time). `mysql`, `backend`, and `frontend` are otherwise
built in that order, not in parallel. `prometheus` has no `depends_on`
-- EC2 service discovery finds scrape targets whenever they exist, so
it can boot independently of the app tiers.


## Repos this depends on

The `user_data` scripts curl their tar.gz artifacts (app builds +
Grafana dashboards + Prometheus rules) from **this repo's sibling doc
repo**, `daws-90s/expense-prometheus-grafana-docs`, via
`var.artifacts_base_url` (`variables.tf`):

```
https://raw.githubusercontent.com/daws-90s/expense-prometheus-grafana-docs/main/artifacts
```

That repo's `artifacts/` folder must be pushed and **public** before
`terraform apply` will get past the mysql instance -- every tier's
`VALIDATE` step fails its curl otherwise. It currently holds:
`expense-mysql-v1.tar.gz`, `expense-backend-v1.tar.gz`,
`expense-frontend-v1.tar.gz`, `expense-prometheus-v1.tar.gz` (Grafana
dashboards + `recording_rules.yaml`/`alerting_rules.yaml`). See that
repo's `backend-api.md` for the full backend API surface, including
the `/debug/*` fault-injection routes referenced below.

Everything else this module pulls from the network is upstream
binary releases, not a repo of ours: `github.com/prometheus/{prometheus,
node_exporter,mysqld_exporter,blackbox_exporter}` release tarballs, plus
the `Redhat-9-DevOps-Practice` AMI (owned by a separate AWS account, not
built by this repo).

## Reusing this repo for a different org/domain

If you're forking this for your own AWS account/domain, the variables
in `variables.tf` you actually need to change are:

| Variable | Why you must change it |
|---|---|
| `artifacts_base_url` | Must point at **your own** pushed, public docs repo -- the default points at `daws-90s/expense-prometheus-grafana-docs`, which you don't control. |
| `domain_name`, `route53_zone_id` | Must be a domain/hosted zone **you** own in Route53 -- the defaults (`daws86s.fun`, its zone ID) belong to this course's account. |
| `db_root_password`, `db_app_password`, `db_exporter_password` | Lab defaults (`ExpenseApp@1`, `ChangeMe123!`, `ExporterMon@1`) -- fine for a throwaway demo, override with `-var` for anything you'll leave running. |
| `ssh_cidr` | Defaults to `0.0.0.0/0` (open to the internet) -- narrow to your own IP before applying. |
| `browser_cidr` | Same deal, `0.0.0.0/0` by default -- controls direct browser access to the frontend (80/443) and the Prometheus/Grafana UIs (9090/3000). |
| `aws_region` | Defaults to `us-east-1` -- the AMI lookup in `data.tf` and any hardcoded ARNs/tags assume this unless you change it. |

Version pins (`prometheus_version`, `node_exporter_version`,
`mysqld_exporter_version`, `blackbox_exporter_version`) rarely need
touching, but **verify each tag still exists** on the relevant GitHub
releases page before applying -- a stale tag 404s the `curl` in
`userdata/*.sh` and fails that instance's boot.

There's no `key_name` variable wired up (it's commented out in
`ec2.tf`) -- instances boot without an EC2 key pair. Uncomment those
lines and add a `key_name` variable if you need SSH via key auth
instead of whatever the AMI/SSM already provides.

## Usage

```bash
terraform init
terraform plan
```

## After apply

`user_data` does the install/deploy work automatically -- there's no
manual runbook step for a fresh stack. Give cloud-init a few minutes
per tier (mysql, then backend, then frontend, per the `depends_on`
chain; prometheus boots in parallel with those), then:

```bash
terraform output mysql_private_ip
terraform output backend_private_ip
terraform output frontend_public_ip    # for SSH
terraform output frontend_fqdn         # entry point -- open in a browser
terraform output prometheus_public_ip  # for SSH
terraform output prometheus_fqdn       # Prometheus UI on :9090, Grafana on :3000
```

If a page loads with no data, or a Prometheus target shows down, SSH
in and check the relevant log first:

```bash
ssh ec2-user@<public-ip>
sudo tail -f /var/log/expense/mysql-setup.log      # or backend-setup.log / frontend-setup.log / prometheus-setup.log
sudo systemctl status expense-backend               # on the backend instance
sudo systemctl status nginx                         # on the frontend instance
sudo systemctl status prometheus grafana-server blackbox_exporter   # on the prometheus instance
```

A `FAILURE` line in the log names the exact step that broke -- most
likely cause is `expense-prometheus-grafana-docs`'s `artifacts/`
folder not being pushed/public yet, since every tier's script `curl`s
from there.

## Inducing faults (for testing dashboards, alerts, and the demo itself)

You've already got real alert rules wired up in
`prometheus/alerting-rules.yaml`, evaluated from `/opt/prometheus` on
the Prometheus box. The fastest way to see them fire is to trigger the
condition each one actually watches for.

### App-level (backend `/debug/*` routes)

The backend ships fault-injection routes (see
`expense-prometheus-grafana-docs/backend-api.md` for the full list),
gated behind `ENABLE_DEBUG_ROUTES` (default `false` in
`userdata/backend.sh`'s `.env`). To use them on a running box:

```bash
ssh ec2-user@<backend-ip>
sudo sed -i 's/ENABLE_DEBUG_ROUTES=false/ENABLE_DEBUG_ROUTES=true/' /app/.env
sudo systemctl restart expense-backend
```

| Route | Effect | Alert it drives |
|---|---|---|
| `GET /debug/error` | Always `500`, logs an error | `BackendHighErrorRate` |
| `GET /debug/slow?ms=<n>` | Sleeps `n`ms (default 3000) before `200` | `BackendHighLatencyP95` |
| `GET /debug/cardinality` | Increments a metric with a random label each call | cardinality/label-explosion demo (no dedicated alert -- watch `prometheus_tsdb_*` metrics) |

Revert by flipping `ENABLE_DEBUG_ROUTES` back to `false` and
restarting. `/health` also returns a real `503` whenever the DB health
check fails, so stopping mysqld produces genuine 503s with no code
changes at all.

### Infra-level (any tier, over SSH)

| Alert | How to trigger | Revert |
|---|---|---|
| `HighCPUUsage` / `CriticalCPUUsage` | `sudo dnf install -y stress-ng && stress-ng --cpu 2 --timeout 300s` | let it time out, or `pkill stress-ng` |
| `HighMemoryUsage` / `CriticalMemoryUsage` | `stress-ng --vm 1 --vm-bytes 90% --timeout 300s` | same |
| `HighDiskUsage` / `CriticalDiskUsage` | `fallocate -l 8G /tmp/fill.img` | `rm /tmp/fill.img` |
| `HighLoadAverage` | `stress-ng --cpu 4 --timeout 300s` (t3.micro is 2 vCPU) | let it time out |
| `NodeDown` | `sudo systemctl stop node_exporter` | `sudo systemctl start node_exporter` |
| `MySQLDown` | `sudo systemctl stop mysqld` (on the mysql box) | `sudo systemctl start mysqld` |
| `MySQLHighConnectionUsage` | loop of `mysql -e "SELECT SLEEP(300)" &` to hold connections open | `pkill mysql` |
| `BackendDown` | `sudo systemctl stop expense-backend` | `sudo systemctl start expense-backend` |
| `ProbeFailing` (blackbox) | `sudo systemctl stop nginx` on the frontend | `sudo systemctl start nginx` |
| `SSLCertExpiringSoon` / `SSLCertExpiringCritical` | run `expense-frontend-v1/cert-demo.sh` on the frontend -- issues a 1-hour self-signed cert, so `probe_ssl_earliest_cert_expiry` counts down for real | re-run the script to reissue |

Check results directly against blackbox_exporter before waiting on a
Prometheus scrape cycle:
```bash
ssh ec2-user@<prometheus-ip>
curl "http://localhost:9115/probe?target=https://<domain_name>&module=http_2xx_tls"
```

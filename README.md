# Terraform — expense-{env} infrastructure

Covers: default VPC lookup, four security groups, three EC2 instances
(mysql, backend, frontend) each bootstrapped via `user_data`, DNS
records for all three tiers, and an ALB in front of the frontend tier.

**`terraform apply` creates the infra AND deploys the apps.** Each
instance's `user_data` is `userdata/{mysql,backend,frontend}.sh`,
rendered through `templatefile()` with the passwords/hostnames it
needs. No separate Ansible/manual runbook pass is required for a
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
built in that order, not in parallel.

The scripts curl tar.gz artifacts from `expense-obs-documentation`'s
`artifacts/` folder on GitHub (`var.artifacts_base_url`) -- that repo
must be pushed and public before `terraform apply` will succeed past
the mysql instance.

## Architecture change from the manual runbook

The original runbook had a 4th EC2 instance running nginx as a plain
load balancer (`expense-{env}-lb`). This Terraform **replaces that
tier with a real ALB** — same job (public entry point, forwards to
the frontend tier), but AWS-managed instead of another server you
have to patch and monitor. There's no `expense-{env}-lb` resource
anywhere in this module; the ALB fully takes over that role.

The 502/503/504 demo endpoints on the backend (`/api/maintenance`,
`/api/slow`) still work through the ALB — worth re-testing them once
this is live, since ALB timeout behavior differs slightly from the
old nginx `proxy_read_timeout 10s` (ALB's idle timeout defaults to
60s, so the `/slow` 40s-delay demo may no longer time out the way it
did before — you'll likely need to either lower the ALB's idle
timeout or adjust the demo's sleep duration once you see it live).

## What's in scope now vs deferred

**Now:**
- `data.tf` — default VPC + subnets
- `security_groups.tf` — alb / frontend / backend / mysql, each
  scoped to the SG one hop upstream only
- `ec2.tf` — three RHEL 9 instances, correct SG per tier, each fully
  bootstrapped and deployed via `user_data` (`userdata/*.sh`)
- `alb.tf` — ALB, target group (health check on `/health`), listener,
  an example path-based listener rule, target group attachment
  directly to the frontend instance resource

**Deferred to phase 2 (ask before activating):**
- `iam.tf.disabled` — instance role + profile for ADOT/CloudWatch
  Agent permissions (X-Ray write, CloudWatch Agent policy). Rename to
  `iam.tf` when ready, then set `iam_instance_profile` on the backend
  (and mysql, if running an exporter there) resources in `ec2.tf`
- Backend + mysql target groups, if you want the ALB to reach those
  tiers directly for any reason (not needed currently, since the
  frontend nginx proxies `/api/`)
- Replacing the `user_data` scripts with an Ansible playbook (or
  Packer-baked AMI) run post-apply, if the course moves that direction
- S3 + DynamoDB remote state backend (commented out in `versions.tf`)

## Usage

```bash
terraform init
terraform plan  -var="environment=dev" -var="key_name=<your-existing-keypair>"
terraform apply -var="environment=dev" -var="key_name=<your-existing-keypair>"
```

`key_name` is required — must be an existing EC2 key pair in
us-east-1, Terraform doesn't create one for you.

Narrow `ssh_cidr` before applying — it defaults to `0.0.0.0/0` as a
placeholder, not a recommendation:
```bash
terraform apply -var="environment=dev" -var="key_name=<keypair>" -var="ssh_cidr=<your-ip>/32"
```

## After apply

`user_data` does the install/deploy work automatically -- there's no
manual runbook step for a fresh stack. Give cloud-init a few minutes
per tier (mysql, then backend, then frontend, in that order per the
`depends_on` chain), then:

```bash
terraform output mysql_private_ip
terraform output backend_private_ip
terraform output frontend_public_ip   # for SSH
terraform output backend_public_ip    # for SSH
terraform output mysql_public_ip      # for SSH
terraform output alb_dns_name         # entry point
```

Open `alb_dns_name` in a browser. If the target group shows
`unhealthy`, or the dashboard loads with no data, SSH in and check the
relevant log first:

```bash
ssh ec2-user@<public-ip>
sudo tail -f /var/log/expense/mysql-setup.log     # or backend-setup.log / frontend-setup.log
sudo systemctl status backend    # on the backend instance
sudo systemctl status nginx      # on the frontend instance
```

A `FAILURE` line in the log names the exact step that broke -- most
likely cause is `expense-obs-documentation`'s `artifacts/` folder not
being pushed to GitHub yet, since all three scripts `curl` from there.

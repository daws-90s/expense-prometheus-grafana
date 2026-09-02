# Specs v3: Grafana + Blackbox in `prometheus.sh` (expense-infra) + Frontend 1-hour Cert

**Supersedes:** the TLS-on-Prometheus/Grafana sections of the previous
`specs-tls-blackbox.md`. Decision now: **no TLS on Grafana, no TLS on
Prometheus.** Only the frontend gets a cert, and it's short-lived (1 hour) for
a live-demo cert-expiry drill, not a 90-day one.

Repo conventions carried in: no shared `common.sh` (blocks duplicated per
script); root-check gate, `LOGS_FOLDER=/var/log/expense`, `R/G/Y/N`,
`VALIDATE()`; idempotent guards (`id <user> &>/dev/null ||`); quoted heredoc
(`<<'UNIT'`) for static files, unquoted for `templatefile()`-injected ones;
version numbers as `templatefile()` vars, never hardcoded; no `${1}`-style
relabel capture groups (escape as `$${1}` if ever needed).

---

## 1. Grafana — `userdata/prometheus.sh`, plain HTTP, no TLS

Append after the existing node_exporter block on the Prometheus instance.
Plain install, default port `3000`, nothing else — this reverses the earlier
plan to terminate TLS here.

```bash
# ---- grafana ----
cat > /etc/yum.repos.d/grafana.repo <<'REPO'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
REPO
# (swap the block above for the apt equivalent if the AMI is Debian/Ubuntu —
#  matches how you'll need to branch mysqld_exporter/node_exporter installs
#  too if the AMI family isn't already fixed repo-wide)

yum install -y grafana-${grafana_version}
VALIDATE $? "Installing grafana"

systemctl daemon-reload
systemctl enable --now grafana-server
VALIDATE $? "Starting grafana-server"
```

`grafana.ini` is left at its packaged default (`protocol = http`,
`http_port = 3000`) — no edit needed since we're not adding TLS. Datasource
wiring to `http://localhost:9090` is done once, by hand, post-boot (matches
how you did it originally) unless you want that provisioned too — say the
word and I'll add a `datasources/prometheus.yml` provisioning file, since
Grafana supports declarative datasource provisioning and that would be a
clean thing to codify.

`grafana_version` → new `variables.tf` var, section 5.

---

## 2. Blackbox exporter — `userdata/prometheus.sh`

Same self-contained pattern as node_exporter/mysqld_exporter. `blackbox.yml`
is **static** (no `${var}` inside it) → **quoted** heredoc, unlike
`prometheus.yml` which stays unquoted for `${region}`/`${backend_port}`
injection. Don't mix these two up — it's exactly the distinction your repo
context file already polices.

```bash
# ---- blackbox_exporter ----
id blackbox &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin blackbox
VALIDATE $? "Creating blackbox user"

cd /opt
curl -sLO https://github.com/prometheus/blackbox_exporter/releases/download/v${blackbox_exporter_version}/blackbox_exporter-${blackbox_exporter_version}.linux-amd64.tar.gz
tar -xzf blackbox_exporter-${blackbox_exporter_version}.linux-amd64.tar.gz
ln -sfn blackbox_exporter-${blackbox_exporter_version}.linux-amd64 /opt/blackbox_exporter
chown -R blackbox:blackbox /opt/blackbox_exporter-${blackbox_exporter_version}.linux-amd64
VALIDATE $? "Installing blackbox_exporter"

mkdir -p /etc/blackbox
cat > /etc/blackbox/blackbox.yml <<'BBCFG'
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      method: GET
      valid_status_codes: [200]
      preferred_ip_protocol: "ip4"

  http_2xx_tls:
    prober: http
    timeout: 5s
    http:
      method: GET
      valid_status_codes: [200]
      preferred_ip_protocol: "ip4"
      tls_config:
        insecure_skip_verify: true
BBCFG
chown -R blackbox:blackbox /etc/blackbox
VALIDATE $? "Writing blackbox.yml"

cat > /etc/systemd/system/blackbox_exporter.service <<'UNIT'
[Unit]
Description=Blackbox Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=blackbox
Group=blackbox
Restart=on-failure
ExecStart=/opt/blackbox_exporter/blackbox_exporter \
  --config.file=/etc/blackbox/blackbox.yml \
  --web.listen-address=:9115

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now blackbox_exporter
VALIDATE $? "Starting blackbox_exporter"
```

`insecure_skip_verify: true` is required for a self-signed cert to handshake —
carried over from the previous spec's reasoning: without it, an expired or
self-signed cert fails the probe outright (`probe_success = 0`) and you never
even reach the expiry metric. With it, `probe_success` stays `1` regardless of
cert trust or expiry, and the *only* thing that catches a dead cert is
`probe_ssl_earliest_cert_expiry` going negative — the TLS-domain instance of
**"UP ≠ healthy."**

---

## 3. `prometheus.yml` — blackbox scrape jobs

Append to the `scrape_configs` list already templated in `prometheus.sh`.
Static targets by design — SD discovers *instances*, blackbox probes
*endpoints*, so `static_configs` is correct here, not a regression from the
EC2 SD pattern used elsewhere.

**Use the Route53 names**, not raw IPs — you already manage records in
`route53.tf`, and a hardcoded IP breaks the moment an instance is replaced
(exactly what section 0 of the main spec warns about). Add an
`aws_route53_record.frontend` / `.backend` if they don't exist yet.

```yaml
  - job_name: 'blackbox-http'
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - http://backend.${route53_domain}:${backend_port}/health
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115

  - job_name: 'blackbox-https'
    metrics_path: /probe
    params:
      module: [http_2xx_tls]
    static_configs:
      - targets:
          - https://frontend.${route53_domain}
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115
```

`replacement: 127.0.0.1:9115` — blackbox is co-located on the Prometheus box,
loopback, no new SG rule for **that** hop. `route53_domain` is a new
`templatefile()` var (section 5), reusing whatever `${domain}` your
`route53.tf` records already share.

**Dashboard 6 correction (carried over, still applies):** with this relabel
chain there is no `target` label — the probed URL lands on `instance`. Build
the dashboard's template variable as `label_values(probe_success, instance)`
and filter panels on `{instance=~"$instance"}`, not `$target`.

---

## 4. Frontend — self-signed cert, **1-hour expiry**

`expense-frontend-v1`, nginx server block. This is a live-demo cert, so it
doesn't go in boot userdata — it's a script you or a student runs on demand
during class, right before the cert-expiry segment.

### 4.1 Why `-days` won't work here

`openssl req -x509 -days N` computes `notAfter = now + N*86400s` — it's
integer days only, so the shortest interval it can express is 24 hours
(`-days 1`), not 1. Two ways to actually get 1 hour:

**Option A — `-not_after` (OpenSSL ≥ 3.2 only).** Cleanest if available:

```bash
openssl version   # check first — this flag doesn't exist before 3.2
```

```bash
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /etc/nginx/tls/expense.key \
  -out    /etc/nginx/tls/expense.crt \
  -not_before $(date -u +%y%m%d%H%M%SZ) \
  -not_after  $(date -u -d '+1 hour' +%y%m%d%H%M%SZ) \
  -subj "/CN=expense.local" \
  -addext "subjectAltName=IP:<frontend-public-ip>"
```

Amazon Linux 2023 and Ubuntu 22.04/24.04 both currently ship OpenSSL 3.0.x —
`-not_after` was only added in 3.2, so **check the version on your actual
AMI before building the demo around this.** If it's not there, use Option B.

**Option B — clock-shift trick (works on any OpenSSL version).** Temporarily
set the system clock forward 23 hours, issue a normal `-days 1` cert (which
now computes `notAfter` as *real* now + 1 hour), then resync:

```bash
sudo date -s "+23 hours"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /etc/nginx/tls/expense.key \
  -out    /etc/nginx/tls/expense.crt \
  -days 1 \
  -subj "/CN=expense.local" \
  -addext "subjectAltName=IP:<frontend-public-ip>"
sudo chronyc -a makestep     # or: sudo systemctl restart systemd-timesyncd
```

This is a demo-only trick, not something to leave lying around — the window
is a couple of seconds and nothing else on the box should be time-sensitive
during it, but resync immediately (`chronyc -a makestep` forces an instant
step rather than a gradual slew) rather than trusting NTP to drift back on
its own. Don't run this on a box doing anything else at that moment.

```bash
chmod 600 /etc/nginx/tls/expense.key
```

### 4.2 nginx server block (unchanged from before)

```nginx
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/nginx/tls/expense.crt;
    ssl_certificate_key /etc/nginx/tls/expense.key;

    root  /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://<backend-ip>:8080/;
    }
}
```

Redirect trap from before still applies unchanged: don't add an 80→443
redirect on the probe target — keep the blackbox probe explicitly on
`https://frontend.<domain>` (section 3) so you know exactly which protocol
you're testing. `systemctl reload nginx` after writing the cert.

### 4.3 Demo-scale thresholds — don't forget this

Dashboard 6's cert-expiry bar-gauge thresholds and any future alerting rule
will default to production-scale values (e.g. warn under 30 days). Against a
**1-hour** cert those thresholds are meaningless — the panel will read
"red" from the moment it's issued. For the live demo, either:
- temporarily set the bar-gauge thresholds to something like
  warn `< 45min`, crit `< 15min`, or
- just watch the raw number
  `(probe_ssl_earliest_cert_expiry{instance="frontend.<domain>"} - time()) / 60`
  (minutes remaining) count down and cross zero live — often the clearer demo
  anyway, since the audience sees the number itself move.

Re-run the Option A or B script to reissue and reload nginx to repeat the
drill for a second showing.

---

## 5. `variables.tf` additions

```hcl
variable "grafana_version"           { default = "11.x.x" }  # pin to what's on rpm.grafana.com
variable "blackbox_exporter_version" { default = "0.25.0" }  # verify tag exists before apply
variable "route53_domain"            { }  # reuse whatever route53.tf already uses
```

Verify both version tags exist on their respective release pages before
`apply` — same 404-on-`curl`/VALIDATE-fails-boot risk as the other exporters.

---

## 6. Security groups

| SG          | Rule                          | Source              |
|-------------|--------------------------------|----------------------|
| prometheus  | ingress TCP `3000` (Grafana UI)| `var.browser_cidr`   |
| frontend    | ingress TCP `443`              | prometheus SG id (blackbox probe) |
| frontend    | ingress TCP `443`              | `var.browser_cidr` (real users, once nginx serves TLS) |

Prometheus → blackbox (9115) stays loopback, no rule. Blackbox → backend
`/health` already has an SG path if `expense-backend`'s scrape job opened
`backend_port` to the Prometheus SG — confirm rather than assume, since that
rule was written for the metrics scrape, not necessarily for `/health` if
they're on different ports.

---

## 7. Acceptance criteria (additions to existing section 8)

- `systemctl is-active grafana-server` = active; `curl -s localhost:3000/api/health` returns `ok`.
- `systemctl is-active blackbox_exporter` = active.
- Prometheus **Status → Targets**: `blackbox-http` and `blackbox-https` both `UP`.
- `probe_success{instance=~"frontend.*|backend.*"}` == 1 for both.
- `probe_ssl_earliest_cert_expiry{instance="frontend.<domain>"}` present, and
  absent for the backend (http, non-TLS) target — expected, not a bug.
- No TLS-related config anywhere in `grafana.ini` or `prometheus.yml` — confirms
  the "no TLS on Grafana/Prometheus" decision actually stuck.

## 8. Open items
- Confirm which AMI/OS family `prometheus.sh` targets (Amazon Linux vs
  Ubuntu) — the Grafana repo block above is yum-flavored; swap for apt if
  needed, matching how the other tiers already branch (or don't) on OS.
- **Run `openssl version` on the frontend AMI before the demo** and pick
  Option A or B accordingly — don't discover this live in front of the class.
- Confirm `route53.tf` already has (or will get) `frontend`/`backend`
  A records under a shared `route53_domain`.
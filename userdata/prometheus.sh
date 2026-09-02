#!/bin/bash

LOGS_FOLDER="/var/log/expense"
sudo mkdir -p $LOGS_FOLDER
sudo chown -R ec2-user:ec2-user $LOGS_FOLDER
sudo chmod -R 755 $LOGS_FOLDER
LOGS_FILE="$LOGS_FOLDER/prometheus-setup.log"

USERID=$(id -u)
R="\e[31m"
G="\e[32m"
Y="\e[33m"
N="\e[0m"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

if [ $USERID -ne 0 ]; then
    echo -e "$TIMESTAMP [ERROR] $R Please run this script with root access $N" | tee -a $LOGS_FILE
    exit 1
fi

VALIDATE(){
    if [ $1 -ne 0 ]; then
        echo -e "$TIMESTAMP [ERROR] $2 ... $R FAILURE $N" | tee -a $LOGS_FILE
        exit 1
    else
        echo -e "$TIMESTAMP [INFO] $2 ... $G SUCCESS $N" | tee -a $LOGS_FILE
    fi
}

REGION='${region}'
BACKEND_PORT='${backend_port}'
PROJECT_TAG='${project_tag}'
PROMETHEUS_VERSION='${prometheus_version}'
NODE_EXPORTER_VERSION='${node_exporter_version}'
BLACKBOX_EXPORTER_VERSION='${blackbox_exporter_version}'
DOMAIN_NAME='${domain_name}'
ARTIFACT_URL='${artifact_url}'

id prometheus &>> $LOGS_FILE
if [ $? -ne 0 ]; then
    useradd --system --no-create-home --shell /sbin/nologin prometheus &>> $LOGS_FILE
    VALIDATE $? "Creating prometheus system user"
else
    echo -e "System user prometheus already created ... $Y SKIPPING $N"
fi

cd /opt
rm -f prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz
curl -sL -o prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz "https://github.com/prometheus/prometheus/releases/download/v$PROMETHEUS_VERSION/prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz" &>> $LOGS_FILE
tar -xzf prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz &>> $LOGS_FILE
ln -sfn prometheus-$PROMETHEUS_VERSION.linux-amd64 /opt/prometheus
VALIDATE $? "Downloaded and extracted prometheus"

mkdir -p /var/lib/prometheus
VALIDATE $? "Creating data directory"

# ---- observability artifact (grafana dashboards + prometheus rules) ----
# Same artifacts_base_url pattern as the other tiers -- pulled from
# expense-obs-documentation's artifacts/ folder, not embedded in this
# script, since the dashboard JSON alone is well over the EC2 user_data
# size limit.
rm -rf /tmp/expense-prometheus /tmp/expense-prometheus.tar.gz
mkdir -p /tmp/expense-prometheus
curl -sL -o /tmp/expense-prometheus.tar.gz $ARTIFACT_URL &>> $LOGS_FILE
cd /tmp/expense-prometheus
tar -xzf /tmp/expense-prometheus.tar.gz
VALIDATE $? "Downloaded and extracted prometheus artifact (dashboards + rules)"

cp recording_rules.yaml alerting_rules.yaml /opt/prometheus/
VALIDATE $? "Installing recording + alerting rules into /opt/prometheus"

cat > /opt/prometheus/prometheus.yml <<YML
global:
  scrape_interval: 15s
  evaluation_interval: 15s
alerting:
  alertmanagers:
    - static_configs:
        - targets:
          # - alertmanager:9093

# Load rules once and periodically evaluate them according to the global 'evaluation_interval'.
rule_files:
   - "/opt/prometheus/recording_rules.yaml"
   - "/opt/prometheus/alerting_rules.yaml"

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
            values: ["${project_tag}"]
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
            values: ["${project_tag}"]
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
            values: ["${project_tag}"]
          - name: "tag:Tier"
            values: ["backend"]
    relabel_configs:
      - source_labels: [__meta_ec2_tag_Name]
        target_label: instance
      - source_labels: [__meta_ec2_tag_Tier]
        target_label: tier

  - job_name: 'blackbox-http'
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - http://backend.${domain_name}:${backend_port}/health
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
          - https://${domain_name}
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115
YML
VALIDATE $? "Writing prometheus.yml"

chown -R prometheus:prometheus /opt/prometheus-$PROMETHEUS_VERSION.linux-amd64 /var/lib/prometheus
VALIDATE $? "Setting ownership"

cat > /etc/systemd/system/prometheus.service <<'UNIT'
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
  --config.file=/opt/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --web.enable-lifecycle

[Install]
WantedBy=multi-user.target
UNIT
VALIDATE $? "Writing prometheus systemd unit"

systemctl daemon-reload
systemctl enable --now prometheus &>> $LOGS_FILE
VALIDATE $? "Starting prometheus"

# ---- node_exporter ----
id node_exporter &>> $LOGS_FILE
if [ $? -ne 0 ]; then
    useradd --system --no-create-home --shell /sbin/nologin node_exporter &>> $LOGS_FILE
    VALIDATE $? "Creating node_exporter user"
else
    echo -e "System user node_exporter already created ... $Y SKIPPING $N"
fi

cd /opt
rm -f node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz
curl -sL -o node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz "https://github.com/prometheus/node_exporter/releases/download/v$NODE_EXPORTER_VERSION/node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz" &>> $LOGS_FILE
tar -xzf node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz &>> $LOGS_FILE
ln -sfn node_exporter-$NODE_EXPORTER_VERSION.linux-amd64 /opt/node_exporter
chown -R node_exporter:node_exporter /opt/node_exporter-$NODE_EXPORTER_VERSION.linux-amd64
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
systemctl enable --now node_exporter &>> $LOGS_FILE
VALIDATE $? "Starting node_exporter"

# ---- blackbox_exporter ----
id blackbox &>> $LOGS_FILE
if [ $? -ne 0 ]; then
    useradd --system --no-create-home --shell /sbin/nologin blackbox &>> $LOGS_FILE
    VALIDATE $? "Creating blackbox user"
else
    echo -e "System user blackbox already created ... $Y SKIPPING $N"
fi

cd /opt
rm -f blackbox_exporter-$BLACKBOX_EXPORTER_VERSION.linux-amd64.tar.gz
curl -sL -o blackbox_exporter-$BLACKBOX_EXPORTER_VERSION.linux-amd64.tar.gz "https://github.com/prometheus/blackbox_exporter/releases/download/v$BLACKBOX_EXPORTER_VERSION/blackbox_exporter-$BLACKBOX_EXPORTER_VERSION.linux-amd64.tar.gz" &>> $LOGS_FILE
tar -xzf blackbox_exporter-$BLACKBOX_EXPORTER_VERSION.linux-amd64.tar.gz &>> $LOGS_FILE
ln -sfn blackbox_exporter-$BLACKBOX_EXPORTER_VERSION.linux-amd64 /opt/blackbox_exporter
chown -R blackbox:blackbox /opt/blackbox_exporter-$BLACKBOX_EXPORTER_VERSION.linux-amd64
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
systemctl enable --now blackbox_exporter &>> $LOGS_FILE
VALIDATE $? "Starting blackbox_exporter"

# ---- grafana ----
dnf install -y grafana &>> $LOGS_FILE
VALIDATE $? "Installing grafana"

# ---- grafana provisioning: datasource ----
# Must exist before grafana-server first starts, so Prometheus is auto-wired
# with a known, fixed UID that the dashboard JSON files also reference.
mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/prometheus.yml <<'YML'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    uid: prometheus
    url: http://localhost:9090
    isDefault: true
    editable: false
YML
VALIDATE $? "Writing grafana datasource provisioning config"

# ---- grafana provisioning: dashboards provider ----
mkdir -p /etc/grafana/provisioning/dashboards
cat > /etc/grafana/provisioning/dashboards/dashboards.yml <<'YML'
apiVersion: 1
providers:
  - name: expense-app-dashboards
    orgId: 1
    folder: "Expense App"
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /etc/grafana/dashboards
      foldersFromFilesStructure: false
YML
VALIDATE $? "Writing grafana dashboard provisioning config"

# ---- install the dashboard JSON files (already fetched into
# /tmp/expense-prometheus/dashboards by the artifact download above) ----
mkdir -p /etc/grafana/dashboards
cp /tmp/expense-prometheus/dashboards/*.json /etc/grafana/dashboards/
VALIDATE $? "Installing grafana dashboards"

chown -R grafana:grafana /etc/grafana/provisioning /etc/grafana/dashboards
VALIDATE $? "Setting grafana provisioning ownership"

systemctl daemon-reload
systemctl enable --now grafana-server &>> $LOGS_FILE
VALIDATE $? "Starting grafana-server"
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

# ---- download the actual dashboard JSON files ----
mkdir -p /etc/grafana/dashboards
GITHUB_RAW_BASE="https://raw.githubusercontent.com/<your-org>/expense-infra/main/grafana/dashboards"
for DASHBOARD in fleet-overview node-host-use mysql application-red business-metrics blackbox-synthetic slo-error-budget; do
    curl -sL -o /etc/grafana/dashboards/dashboard-$DASHBOARD.json \
        "$GITHUB_RAW_BASE/dashboard-$DASHBOARD.json" &>> $LOGS_FILE
    VALIDATE $? "Downloading dashboard: $DASHBOARD"
done

chown -R grafana:grafana /etc/grafana/provisioning /etc/grafana/dashboards
VALIDATE $? "Setting grafana provisioning ownership"

systemctl daemon-reload
systemctl enable --now grafana-server &>> $LOGS_FILE
VALIDATE $? "Starting grafana-server"

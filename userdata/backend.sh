#!/bin/bash

LOGS_FOLDER="/var/log/expense"
sudo mkdir -p $LOGS_FOLDER
sudo chown -R ec2-user:ec2-user $LOGS_FOLDER
sudo chmod -R 755 $LOGS_FOLDER
LOGS_FILE="$LOGS_FOLDER/backend-setup.log"

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

DB_HOST='${db_host}'
DB_APP_PASSWORD='${db_app_password}'
ARTIFACT_URL='${artifact_url}'
NODE_EXPORTER_VERSION='${node_exporter_version}'

dnf module disable nodejs -y &>> $LOGS_FILE
dnf module enable nodejs:20 -y &>> $LOGS_FILE
dnf install nodejs -y &>> $LOGS_FILE
VALIDATE $? "Installing NodeJS:20"

id expense &>> $LOGS_FILE
if [ $? -ne 0 ]; then
    useradd --system --home /app --shell /sbin/nologin --comment "expense system user" expense &>> $LOGS_FILE
    VALIDATE $? "Creating expense system user"
else
    echo -e "System user expense already created ... $Y SKIPPING $N"
fi

rm -rf /app
mkdir -p /app
VALIDATE $? "Creating app directory"

rm -rf /tmp/backend.tar.gz
curl -o /tmp/backend.tar.gz $ARTIFACT_URL &>> $LOGS_FILE
cd /app
tar -xzf /tmp/backend.tar.gz
VALIDATE $? "Downloaded and extracted backend artifact"

npm install &>> $LOGS_FILE
VALIDATE $? "Installing dependencies"

cat > /app/.env <<EOF
PORT=8080
SERVICE_NAME=expense-backend
DB_HOST=$DB_HOST
DB_PORT=3306
DB_USER=expense_app
DB_PASSWORD=$DB_APP_PASSWORD
DB_NAME=expense_db
LOG_LEVEL=info
ENABLE_DEBUG_ROUTES=false
EOF
VALIDATE $? "Writing .env"

chown -R expense:expense /app
VALIDATE $? "Setting ownership on /app"

cp /app/backend.service /etc/systemd/system/backend.service
VALIDATE $? "Installed systemd unit"

systemctl daemon-reload
systemctl enable backend &>> $LOGS_FILE
systemctl restart backend
VALIDATE $? "Starting backend service"

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

#!/bin/bash

LOGS_FOLDER="/var/log/expense"
sudo mkdir -p $LOGS_FOLDER
sudo chown -R ec2-user:ec2-user $LOGS_FOLDER
sudo chmod -R 755 $LOGS_FOLDER
LOGS_FILE="$LOGS_FOLDER/mysql-setup.log"

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

DB_ROOT_PASSWORD='${db_root_password}'
DB_APP_PASSWORD='${db_app_password}'
ARTIFACT_URL='${artifact_url}'
DB_EXPORTER_PASSWORD='${db_exporter_password}'
NODE_EXPORTER_VERSION='${node_exporter_version}'
MYSQLD_EXPORTER_VERSION='${mysqld_exporter_version}'

dnf install mysql-server -y &>> $LOGS_FILE
VALIDATE $? "Installing MySQL Server"

systemctl enable mysqld &>> $LOGS_FILE
systemctl start mysqld  &>> $LOGS_FILE
VALIDATE $? "Enable and start MySQL server"

rm -rf /tmp/expense-mysql /tmp/mysql.tar.gz
mkdir -p /tmp/expense-mysql
curl -o /tmp/mysql.tar.gz $ARTIFACT_URL &>> $LOGS_FILE
cd /tmp/expense-mysql
tar -xzf /tmp/mysql.tar.gz
VALIDATE $? "Downloaded and extracted mysql artifact"

# Local socket auth as the Linux root user needs no -u/-p -- same as the
# manual setup documented in expense-mysql-v1/README.md.
mysql < schema.sql
VALIDATE $? "Loading schema"

mysql <<SQL
CREATE USER IF NOT EXISTS 'expense_app'@'%' IDENTIFIED BY '$DB_APP_PASSWORD';
GRANT SELECT, INSERT, UPDATE, DELETE ON expense_db.* TO 'expense_app'@'%';
FLUSH PRIVILEGES;
SQL
VALIDATE $? "Creating expense_app user"

mysql < seed.sql
VALIDATE $? "Loading seed data"

# Run the actual monitor.mysql shipped in the artifact (not a re-typed copy)
# so the exporter grants stay in sync with expense-mysql-v1 -- swap its
# hardcoded lab password for the real one from Terraform.
sed "s/exporter#123/$DB_EXPORTER_PASSWORD/" monitor.mysql | mysql
VALIDATE $? "Creating exporter monitoring user"

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

# ---- mysqld_exporter ----
id mysqld_exporter &>> $LOGS_FILE
if [ $? -ne 0 ]; then
    useradd --system --no-create-home --shell /sbin/nologin mysqld_exporter &>> $LOGS_FILE
    VALIDATE $? "Creating mysqld_exporter user"
else
    echo -e "System user mysqld_exporter already created ... $Y SKIPPING $N"
fi

cd /opt
rm -f mysqld_exporter-$MYSQLD_EXPORTER_VERSION.linux-amd64.tar.gz
curl -sL -o mysqld_exporter-$MYSQLD_EXPORTER_VERSION.linux-amd64.tar.gz "https://github.com/prometheus/mysqld_exporter/releases/download/v$MYSQLD_EXPORTER_VERSION/mysqld_exporter-$MYSQLD_EXPORTER_VERSION.linux-amd64.tar.gz" &>> $LOGS_FILE
tar -xzf mysqld_exporter-$MYSQLD_EXPORTER_VERSION.linux-amd64.tar.gz &>> $LOGS_FILE
ln -sfn mysqld_exporter-$MYSQLD_EXPORTER_VERSION.linux-amd64 /opt/mysqld_exporter
chown -R mysqld_exporter:mysqld_exporter /opt/mysqld_exporter-$MYSQLD_EXPORTER_VERSION.linux-amd64
VALIDATE $? "Installing mysqld_exporter"

mkdir -p /etc/mysqld_exporter
cat > /etc/mysqld_exporter/.my.cnf <<CNF
[client]
user=exporter
password=$DB_EXPORTER_PASSWORD
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
systemctl enable --now mysqld_exporter &>> $LOGS_FILE
VALIDATE $? "Starting mysqld_exporter"

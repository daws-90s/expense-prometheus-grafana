variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name prefix for tagging/naming"
  type        = string
  default     = "expense"
}

variable "ssh_cidr" {
  description = "CIDR allowed to SSH into instances. Set this to your own IP in terraform.tfvars -- no default, since 0.0.0.0/0 (open to the internet) isn't a safe thing to fall back to silently."
  type        = string
}

variable "backend_port" {
  description = "Port the Node.js backend listens on"
  type        = number
  default     = 8080
}

variable "mysql_port" {
  description = "Port MySQL listens on"
  type        = number
  default     = 3306
}

variable "frontend_port" {
  description = "Port nginx serves the built frontend on"
  type        = number
  default     = 80
}

variable "browser_cidr" {
  description = "CIDR allowed to reach the frontend port directly from a browser, and the Prometheus/Grafana UIs. Nginx on the frontend reverse-proxies /api/ to the backend's private IP, so the backend itself never needs to be reachable from outside the VPC. Set this in terraform.tfvars -- no default, since 0.0.0.0/0 (open to the internet) isn't a safe thing to fall back to silently."
  type        = string
}

variable "mysql_instance_type" {
  description = "Instance type for the mysql tier"
  type        = string
  default     = "t3.micro"
}

variable "backend_instance_type" {
  description = "Instance type for the backend tier"
  type        = string
  default     = "t3.micro"
}

variable "frontend_instance_type" {
  description = "Instance type for the frontend tier"
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB for all three instances"
  type        = number
  default     = 20
}

variable "route53_zone_id" {
  description = "Hosted zone ID for domain_name -- yours, not this course's. Set this in terraform.tfvars."
  type        = string
}

variable "domain_name" {
  description = "Root domain name for the app's DNS records -- a domain/zone you actually control in Route53. Set this in terraform.tfvars."
  type        = string
}

variable "artifacts_base_url" {
  description = "Base URL user_data curls the mysql/backend/frontend/prometheus tar.gz artifacts from -- the raw.githubusercontent.com path to expense-prometheus-grafana-docs's artifacts/ folder"
  type        = string
  default     = "https://raw.githubusercontent.com/daws-90s/expense-prometheus-grafana-docs/main/artifacts"
}

variable "db_root_password" {
  description = "MySQL root password, set via mysql_secure_installation in userdata/mysql.sh. Lab/demo default -- override for anything longer-lived."
  type        = string
  default     = "ExpenseApp@1"
  sensitive   = true
}

variable "db_app_password" {
  description = "Password for the expense_app MySQL user -- shared between userdata/mysql.sh (CREATE USER) and userdata/backend.sh (.env DB_PASSWORD). Lab/demo default -- override for anything longer-lived."
  type        = string
  default     = "ChangeMe123!"
  sensitive   = true
}

variable "project_tag" {
  description = "Value of the Project tag on every instance -- EC2 service discovery filters on this so Prometheus finds all four boxes."
  type        = string
  default     = "expense"
}

variable "prometheus_version" {
  description = "Prometheus release version (no leading v) installed by userdata/prometheus.sh"
  type        = string
  default     = "3.13.2"
}

variable "node_exporter_version" {
  description = "node_exporter release version (no leading v) installed on every instance"
  type        = string
  default     = "1.9.1"
}

variable "mysqld_exporter_version" {
  description = "mysqld_exporter release version (no leading v) installed on the mysql instance -- verify the tag matches whatever was already installed by hand before applying"
  type        = string
  default     = "0.17.2"
}

variable "db_exporter_password" {
  description = "Password for the exporter@localhost MySQL user mysqld_exporter connects as. Lab/demo default -- override for anything longer-lived."
  type        = string
  default     = "ExporterMon@1"
  sensitive   = true
}

variable "blackbox_exporter_version" {
  description = "blackbox_exporter release version (no leading v) installed by userdata/prometheus.sh -- verify the tag exists on the GitHub releases page before applying"
  type        = string
  default     = "0.25.0"
}

variable "alertmanager_version" {
  description = "Alertmanager release version (no leading v) installed by userdata/prometheus.sh -- verify the tag exists on the GitHub releases page before applying"
  type        = string
  default     = "0.34.0"
}

variable "alertmanager_smtp_host" {
  description = "SMTP smarthost Alertmanager sends mail through, host:port form (e.g. \"smtp.gmail.com:587\"). No default -- Alertmanager fails to start with an empty smarthost, so this must be set in terraform.tfvars for the email receiver to work."
  type        = string
}

variable "alertmanager_smtp_from" {
  description = "From address on alert emails."
  type        = string
}

variable "alertmanager_smtp_auth_username" {
  description = "SMTP auth username (for Gmail, your full address; use an app password, not your account password, in alertmanager_smtp_auth_password)."
  type        = string
}

variable "alertmanager_smtp_auth_password" {
  description = "SMTP auth password/app-password. Set in terraform.tfvars -- never commit a real value."
  type        = string
  sensitive   = true
}

variable "alertmanager_email_to" {
  description = "Recipient address for the critical-severity email receiver."
  type        = string
}

variable "alertmanager_slack_webhook_url" {
  description = "Slack incoming webhook URL (Slack app -> Incoming Webhooks -> Add New Webhook). Set in terraform.tfvars -- never commit a real value."
  type        = string
  sensitive   = true
}

variable "alertmanager_slack_channel" {
  description = "Slack channel the webhook posts alerts into, e.g. \"#alerts\"."
  type        = string
}

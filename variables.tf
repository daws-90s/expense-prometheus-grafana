variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name, used in resource naming (expense-{env}-{component})"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project name prefix for tagging/naming"
  type        = string
  default     = "expense"
}

variable "ssh_cidr" {
  description = "CIDR allowed to SSH into instances. Narrow this to your own IP before applying -- 0.0.0.0/0 is a placeholder, not a recommendation."
  type        = string
  default     = "0.0.0.0/0"
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
  description = "CIDR allowed to reach the frontend port directly from a browser. Nginx on the frontend reverse-proxies /api/ to the backend's private IP, so the backend itself never needs to be reachable from outside the VPC. 0.0.0.0/0 is a placeholder for a lab/demo environment, not a recommendation for anything long-lived."
  type        = string
  default     = "0.0.0.0/0"
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
  description = "Hosted zone ID for daws86s.fun"
  type        = string
  default     = "Z0948150OFPSYTNVYZOY"
}

variable "domain_name" {
  description = "Root domain name for the app's DNS records"
  type        = string
  default     = "daws86s.fun"
}

variable "artifacts_base_url" {
  description = "Base URL user_data curls the mysql/backend/frontend tar.gz artifacts from -- the raw.githubusercontent.com path to expense-obs-documentation's artifacts/ folder"
  type        = string
  default     = "https://raw.githubusercontent.com/90s-org/expense-obs-documentation/main/artifacts"
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

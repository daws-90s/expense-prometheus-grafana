# EC2 instances with user_data bootstrap -- terraform apply both
# creates the infra and deploys the apps. Each tier's script lives in
# userdata/ (mysql.sh, backend.sh, frontend.sh), styled after
# daws-90s/shell-roboshop: self-contained, no shared common.sh,
# VALIDATE-wrapped steps logging to /var/log/expense on the instance.
#
# Ordering: backend's user_data needs mysql's app user to exist and
# frontend's nginx.conf needs to resolve backend.<domain> at reload
# time, so backend depends_on the mysql Route53 record (not just the
# mysql instance) and frontend depends_on the backend Route53 record --
# mirrors how roboshop-v2.sh updates R53 right after each instance
# launches, before moving on to the next tier.

/* data "aws_ami" "rhel9" {
  most_recent = true
  owners      = ["309956199"] # Red Hat

  filter {
    name   = "name"
    values = ["RHEL-9*_HVM-*-x86_64*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
 */
resource "aws_instance" "mysql" {
  ami                    = data.aws_ami.joindevops.id
  instance_type          = var.mysql_instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.mysql.id]
  #key_name               = var.key_name

  user_data = templatefile("${path.module}/userdata/mysql.sh", {
    db_root_password        = var.db_root_password
    db_app_password         = var.db_app_password
    artifact_url            = "${var.artifacts_base_url}/expense-mysql-v1.tar.gz"
    db_exporter_password    = var.db_exporter_password
    node_exporter_version   = var.node_exporter_version
    mysqld_exporter_version = var.mysqld_exporter_version
  })

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.project_name}-mysql"
    Project = var.project_tag
    Tier    = "database"
  }
}

resource "aws_instance" "backend" {
  ami                    = data.aws_ami.joindevops.id
  instance_type          = var.backend_instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.backend.id]
  #key_name               = var.key_name

  user_data = templatefile("${path.module}/userdata/backend.sh", {
    db_host               = "mysql.${var.domain_name}"
    db_app_password       = var.db_app_password
    artifact_url          = "${var.artifacts_base_url}/expense-backend-v1.tar.gz"
    node_exporter_version = var.node_exporter_version
  })

  # mysql's Route53 record (not just the mysql instance) must exist first --
  # this script connects to mysql.<domain> to create the expense_app user.
  depends_on = [aws_route53_record.mysql]

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.project_name}-backend"
    Project = var.project_tag
    Tier    = "backend"
  }
}

resource "aws_instance" "frontend" {
  ami                    = data.aws_ami.joindevops.id
  instance_type          = var.frontend_instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.frontend.id]
  #key_name               = var.key_name

  user_data = templatefile("${path.module}/userdata/frontend.sh", {
    backend_host          = "backend.${var.domain_name}"
    artifact_url          = "${var.artifacts_base_url}/expense-frontend-v1.tar.gz"
    node_exporter_version = var.node_exporter_version
  })

  # backend's Route53 record must exist first -- nginx.conf's proxy_pass
  # resolves backend.<domain> at reload time.
  depends_on = [aws_route53_record.backend]

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.project_name}-frontend"
    Project = var.project_tag
    Tier    = "frontend"
  }
}

resource "aws_instance" "prometheus" {
  ami                    = data.aws_ami.joindevops.id
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.prometheus.id]
  iam_instance_profile   = aws_iam_instance_profile.prometheus.name

  user_data = templatefile("${path.module}/userdata/prometheus.sh", {
    region                     = var.aws_region
    backend_port               = var.backend_port
    project_tag                = var.project_tag
    prometheus_version         = var.prometheus_version
    node_exporter_version      = var.node_exporter_version
    blackbox_exporter_version  = var.blackbox_exporter_version
    domain_name                = var.domain_name
    artifact_url               = "${var.artifacts_base_url}/expense-prometheus-v1.tar.gz"
    alertmanager_version       = var.alertmanager_version
    alertmanager_smtp_host     = var.alertmanager_smtp_host
    alertmanager_smtp_from     = var.alertmanager_smtp_from
    alertmanager_smtp_username = var.alertmanager_smtp_auth_username
    alertmanager_smtp_password = var.alertmanager_smtp_auth_password
    alertmanager_email_to      = var.alertmanager_email_to
    alertmanager_slack_webhook = var.alertmanager_slack_webhook_url
    alertmanager_slack_channel = var.alertmanager_slack_channel
  })

  # No depends_on -- EC2 service discovery finds scrape targets whenever
  # they exist, so this can boot independently of the app tiers.

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.project_name}-prometheus"
    Project = var.project_tag
    Tier    = "monitoring"
  }
}

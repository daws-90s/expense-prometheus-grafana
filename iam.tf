/* PHASE 2 -- not wired into the default apply.

This gives the backend (and mysql, if you run mysqld_exporter's
ADOT scrape there too) EC2 instances the permissions ADOT and the
CloudWatch Agent need, per adot/iam-policy.json from the
observability drop-in:
  - AWSXRayDaemonWriteAccess  (traces)
  - CloudWatchAgentServerPolicy (metrics via EMF + logs)

To activate: rename this file from iam.tf.disabled to iam.tf,
then attach aws_iam_instance_profile.expense_backend.name to the
backend EC2 instance (console, or via aws_instance if you move
instance provisioning into Terraform too). */

resource "aws_iam_role" "expense_backend" {
  name = "${var.project_name}-${var.environment}-backend-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name        = "${var.project_name}-${var.environment}-backend-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "backend_xray" {
  role       = aws_iam_role.expense_backend.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy_attachment" "backend_cloudwatch" {
  role       = aws_iam_role.expense_backend.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "expense_backend" {
  name = "${var.project_name}-${var.environment}-backend-profile"
  role = aws_iam_role.expense_backend.name
}

# --- mysql -------------------------------------------------------------
# CloudWatch only -- no X-Ray policy, this tier has no app-level tracing,
# just mysqld_exporter metrics (via ADOT) and the slow query log (via
# CloudWatch Agent).

resource "aws_iam_role" "expense_mysql" {
  name = "${var.project_name}-${var.environment}-mysql-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name        = "${var.project_name}-${var.environment}-mysql-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "mysql_cloudwatch" {
  role       = aws_iam_role.expense_mysql.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "expense_mysql" {
  name = "${var.project_name}-${var.environment}-mysql-profile"
  role = aws_iam_role.expense_mysql.name
}

# --- frontend ------------------------------------------------------------
# CloudWatch only -- nginx logs + host metrics, no tracing on this tier.

resource "aws_iam_role" "expense_frontend" {
  name = "${var.project_name}-${var.environment}-frontend-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name        = "${var.project_name}-${var.environment}-frontend-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "frontend_cloudwatch" {
  role       = aws_iam_role.expense_frontend.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "expense_frontend" {
  name = "${var.project_name}-${var.environment}-frontend-profile"
  role = aws_iam_role.expense_frontend.name
}

# --- prometheus ----------------------------------------------------------
# Lets ec2_sd_configs call DescribeInstances/DescribeAvailabilityZones via
# the instance profile -- no static AWS keys in prometheus.yml.

resource "aws_iam_role" "prometheus" {
  name = "${var.project_name}-${var.environment}-prometheus-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name        = "${var.project_name}-${var.environment}-prometheus-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "prometheus_ec2_sd" {
  name = "${var.project_name}-${var.environment}-prometheus-ec2-sd"
  role = aws_iam_role.prometheus.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:DescribeInstances",
        "ec2:DescribeAvailabilityZones"
      ]
      # DescribeInstances/DescribeAvailabilityZones don't support
      # resource-level scoping -- Resource: "*" is correct here, not a
      # shortcut.
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "prometheus" {
  name = "${var.project_name}-${var.environment}-prometheus-profile"
  role = aws_iam_role.prometheus.name
}

# --- outputs -------------------------------------------------------------

output "backend_instance_profile_name" {
  value = aws_iam_instance_profile.expense_backend.name
}

output "prometheus_instance_profile_name" {
  value = aws_iam_instance_profile.prometheus.name
}

output "mysql_instance_profile_name" {
  value = aws_iam_instance_profile.expense_mysql.name
}

output "frontend_instance_profile_name" {
  value = aws_iam_instance_profile.expense_frontend.name
}

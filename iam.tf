# mysql/backend/frontend intentionally have no IAM role or instance
# profile: none of their userdata (mysql.sh/backend.sh/frontend.sh) calls
# any AWS API -- it's plain package installs, systemd units, and curls to
# GitHub/the artifacts repo. An instance profile with CloudWatch Agent/
# X-Ray permissions used to be attached here for an ADOT-based
# observability path, but that was never wired into userdata (nothing on
# these boxes runs the CloudWatch Agent or an X-Ray daemon) -- this repo's
# actual observability is the self-hosted Prometheus/Grafana stack, which
# doesn't need those tiers to hold any AWS permissions at all. Only
# prometheus genuinely needs one, for EC2 service discovery below.

# --- prometheus ----------------------------------------------------------
# Lets ec2_sd_configs call DescribeInstances/DescribeAvailabilityZones via
# the instance profile -- no static AWS keys in prometheus.yml.

resource "aws_iam_role" "prometheus" {
  name = "${var.project_name}-prometheus-role"

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
    Name = "${var.project_name}-prometheus-role"
  }
}

resource "aws_iam_role_policy" "prometheus_ec2_sd" {
  name = "${var.project_name}-prometheus-ec2-sd"
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
  name = "${var.project_name}-prometheus-profile"
  role = aws_iam_role.prometheus.name
}

# --- outputs -------------------------------------------------------------

output "prometheus_instance_profile_name" {
  value = aws_iam_instance_profile.prometheus.name
}

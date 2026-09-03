# Chain: internet -> frontend (nginx) -> backend (Node) -> mysql
# Each SG only opens to the SG one hop upstream, except frontend, which is
# the sole internet-facing point (no ALB in front -- see ingress below).

resource "aws_security_group" "frontend" {
  name        = "${var.project_name}-frontend-sg"
  description = "Allow HTTP/HTTPS direct from browsers, plus SSH for admin access"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Direct browser access to nginx (no ALB in front right now)"
    from_port   = var.frontend_port
    to_port     = var.frontend_port
    protocol    = "tcp"
    cidr_blocks = [var.browser_cidr]
  }

  ingress {
    description = "HTTPS -- demo self-signed cert (see expense-frontend-v1/cert-demo.sh)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.browser_cidr]
  }

  ingress {
    description = "SSH for administration"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-frontend-sg"
  }
}

resource "aws_security_group" "backend" {
  name        = "${var.project_name}-backend-sg"
  description = "Allow backend port from frontend SG only, plus SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "App traffic from frontend only"
    from_port       = var.backend_port
    to_port         = var.backend_port
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend.id]
  }

  ingress {
    description = "SSH for administration"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-backend-sg"
  }
}

resource "aws_security_group" "mysql" {
  name        = "${var.project_name}-mysql-sg"
  description = "Allow MySQL port from backend SG only, plus SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "MySQL from backend only"
    from_port       = var.mysql_port
    to_port         = var.mysql_port
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }

  ingress {
    description = "SSH for administration"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-mysql-sg"
  }
}

# --- prometheus ------------------------------------------------------------
# Standalone monitoring box. Scrapes the app tiers' exporter ports over the
# private network, sourced from this SG rather than opened to the internet.

resource "aws_security_group" "prometheus" {
  name        = "${var.project_name}-prometheus-sg"
  description = "Prometheus UI + SSH inbound, all outbound (AWS API + scrape targets)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Prometheus UI"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.browser_cidr]
  }

  ingress {
    description = "Grafana UI"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.browser_cidr]
  }

  ingress {
    description = "Alertmanager UI (view/silence firing alerts)"
    from_port   = 9093
    to_port     = 9093
    protocol    = "tcp"
    cidr_blocks = [var.browser_cidr]
  }

  ingress {
    description = "SSH for administration"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-prometheus-sg"
  }
}

# Standalone security_group_rule resources (rather than inline ingress
# blocks) so the app-tier SGs above don't churn every time this list changes.

resource "aws_security_group_rule" "mysql_node_exporter" {
  type                     = "ingress"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  security_group_id        = aws_security_group.mysql.id
  source_security_group_id = aws_security_group.prometheus.id
  description              = "node_exporter, scraped by Prometheus"
}

resource "aws_security_group_rule" "mysql_mysqld_exporter" {
  type                     = "ingress"
  from_port                = 9104
  to_port                  = 9104
  protocol                 = "tcp"
  security_group_id        = aws_security_group.mysql.id
  source_security_group_id = aws_security_group.prometheus.id
  description              = "mysqld_exporter, scraped by Prometheus"
}

resource "aws_security_group_rule" "backend_node_exporter" {
  type                     = "ingress"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  security_group_id        = aws_security_group.backend.id
  source_security_group_id = aws_security_group.prometheus.id
  description              = "node_exporter, scraped by Prometheus"
}

resource "aws_security_group_rule" "backend_metrics" {
  type                     = "ingress"
  from_port                = var.backend_port
  to_port                  = var.backend_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.backend.id
  source_security_group_id = aws_security_group.prometheus.id
  description              = "Express /metrics, scraped by Prometheus"
}

resource "aws_security_group_rule" "frontend_node_exporter" {
  type                     = "ingress"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  security_group_id        = aws_security_group.frontend.id
  source_security_group_id = aws_security_group.prometheus.id
  description              = "node_exporter, scraped by Prometheus"
}

resource "aws_security_group_rule" "frontend_blackbox_https" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.frontend.id
  source_security_group_id = aws_security_group.prometheus.id
  description              = "blackbox-https probe from prometheus"
}

resource "aws_security_group_rule" "prometheus_node_exporter" {
  type                     = "ingress"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  security_group_id        = aws_security_group.prometheus.id
  source_security_group_id = aws_security_group.prometheus.id
  description              = "node_exporter on the prometheus box itself, self-scraped"
}

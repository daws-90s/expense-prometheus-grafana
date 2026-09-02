# DNS for the three tiers in the existing daws86s.fun hosted zone.
# frontend is the internet entry point -> public IP. backend/mysql are
# only ever reached from inside the VPC (SG chain enforces this) -> private IPs.
# allow_overwrite lets `terraform apply` re-point these each time an
# instance is replaced and gets a new IP, without a manual R53 edit.

resource "aws_route53_record" "frontend" {
  zone_id         = var.route53_zone_id
  name            = var.domain_name
  type            = "A"
  ttl             = 60
  records         = [aws_instance.frontend.public_ip]
  allow_overwrite = true
}

resource "aws_route53_record" "backend" {
  zone_id         = var.route53_zone_id
  name            = "backend.${var.domain_name}"
  type            = "A"
  ttl             = 60
  records         = [aws_instance.backend.private_ip]
  allow_overwrite = true
}

resource "aws_route53_record" "mysql" {
  zone_id         = var.route53_zone_id
  name            = "mysql.${var.domain_name}"
  type            = "A"
  ttl             = 60
  records         = [aws_instance.mysql.private_ip]
  allow_overwrite = true
}

resource "aws_route53_record" "prometheus" {
  zone_id         = var.route53_zone_id
  name            = "prometheus.${var.domain_name}"
  type            = "A"
  ttl             = 60
  records         = [aws_instance.prometheus.public_ip]
  allow_overwrite = true
}

output "frontend_security_group_id" {
  value = aws_security_group.frontend.id
}

output "backend_security_group_id" {
  value = aws_security_group.backend.id
}

output "mysql_security_group_id" {
  value = aws_security_group.mysql.id
}

output "vpc_id" {
  value = data.aws_vpc.default.id
}

output "subnet_ids" {
  value = data.aws_subnets.default.ids
}

output "mysql_private_ip" {
  description = "Use this for DB_HOST in the backend's systemd unit"
  value       = aws_instance.mysql.private_ip
}

output "backend_private_ip" {
  description = "Use this for proxy_pass in the frontend's /etc/nginx/default.d/expense.conf"
  value       = aws_instance.backend.private_ip
}

output "frontend_private_ip" {
  value = aws_instance.frontend.private_ip
}

output "frontend_public_ip" {
  description = "For direct SSH -- normal access should go through the ALB, not this IP"
  value       = aws_instance.frontend.public_ip
}

output "backend_public_ip" {
  value = aws_instance.backend.public_ip
}

output "mysql_public_ip" {
  value = aws_instance.mysql.public_ip
}

output "frontend_fqdn" {
  description = "Public entry point -- points at the frontend's public IP"
  value       = aws_route53_record.frontend.fqdn
}

output "backend_fqdn" {
  description = "Internal only -- points at the backend's private IP"
  value       = aws_route53_record.backend.fqdn
}

output "mysql_fqdn" {
  description = "Internal only -- points at the mysql's private IP"
  value       = aws_route53_record.mysql.fqdn
}

output "prometheus_public_ip" {
  value = aws_instance.prometheus.public_ip
}

output "prometheus_fqdn" {
  description = "Prometheus UI -- http://<this>:9090"
  value       = aws_route53_record.prometheus.fqdn
}

output "prometheus_security_group_id" {
  value = aws_security_group.prometheus.id
}

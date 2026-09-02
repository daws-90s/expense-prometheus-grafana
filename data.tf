# Default VPC per the requirement -- no custom VPC/subnet/route-table
# module needed for this app. If you later want to teach VPC-from-scratch
# using this same app, that's a clean phase-2 swap: replace this file
# with real aws_vpc/aws_subnet resources and everything downstream
# (security groups, ALB) references the new subnet ids without change.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "joindevops" {
  most_recent = true
  owners      = ["973714476881"]

  filter {
    name   = "name"
    values = ["Redhat-9-DevOps-Practice"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}
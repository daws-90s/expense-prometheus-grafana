terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Phase 2 candidate: swap this for an S3 + DynamoDB remote backend
  # once you're ready to teach that module. Local state is fine for
  # a single-instructor demo environment.
  # backend "s3" {
  #   bucket         = "expense-terraform-state-<account-id>"
  #   key            = "expense/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "expense-terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
}

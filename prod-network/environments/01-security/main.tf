terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Env = "prod"
    }
  }
}

# ربط الـ VPC التي تم إنشاؤها للتو
data "aws_vpc" "existing_prod_vpc" {
  id = "vpc-02a73abb1818b4470"
}

# استدعاء موديول العزل والتنبيهات
module "security_remediation" {
  source = "../../../security-remediation"

  vpc_id      = data.aws_vpc.existing_prod_vpc.id
  alert_email = "baraamohamed2311@gmail.com"
  environment = "prod"
}

output "isolation_security_group_id" {
  value = module.security_remediation.isolation_security_group_id
}

output "sns_topic_arn" {
  value = module.security_remediation.sns_topic_arn
}

output "quarantine_swap_lambda_arn" {
  value = module.security_remediation.quarantine_swap_lambda_arn
}

output "playbook_lambda_arns" {
  value = module.security_remediation.playbook_lambda_arns
}

output "evidence_bucket_name" {
  value = module.security_remediation.evidence_bucket_name
}

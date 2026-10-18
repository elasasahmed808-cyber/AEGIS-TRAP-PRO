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

module "network" {
  source = "../../modules/network"

  vpc_cidr               = "10.0.0.0/16"
  public_subnet_cidrs    = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs   = ["10.0.10.0/24", "10.0.20.0/24"]
  availability_zones     = ["us-east-1a", "us-east-1b"]
  environment            = "prod"
  log_archive_bucket_arn = "arn:aws:s3:::proj-prod-log-archive"
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnets" {
  value = module.network.public_subnet_ids
}

output "private_subnets" {
  value = module.network.private_subnet_ids
}
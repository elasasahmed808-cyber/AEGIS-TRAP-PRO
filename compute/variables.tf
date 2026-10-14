variable "region" {
  type    = string
  default = "us-east-1"
}
variable "project" {
  type    = string
  default = "proj"
}
variable "environment" {
  type    = string
  default = "prod"
}

# ---- Existing network / storage / KMS (created by other modules) ----
variable "vpc_id" { type = string }

variable "public_subnet_ids" { 
  type = list(string) 
  
  }
variable "private_subnet_ids" { 
    type = list(string)
    
   }

variable "documents_bucket_name" { 
  type = string
  default = "proj-prod-documents"
  }
variable "build_artifacts_bucket_name" { 
  type = string
  default = "proj-prod-build-artifacts"
  }
variable "logging_bucket_name" {
  type        = string
  description = "Central logging bucket (ALB access logs)"
  default     = "proj-prod-logging-bucket"
}

# ---- Compute ----
variable "ami_id" {
  type        = string
  default     = "ami-0d27e0fb3bac4d724"
  description = "Hardened AMI. Empty = latest Amazon Linux 2023 (fallback only)."
}
variable "app_instance_type" {
  type    = string
  default = "t3.micro"
}
variable "jenkins_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "apmix_api_key_value" {
  description = "APMIX.AI API key. Pass via TF_VAR_apmix_api_key_value env var — never commit this."
  type        = string
  sensitive   = true
}

variable "create_asg_kms_grant" {
  type    = bool
  default = false
}

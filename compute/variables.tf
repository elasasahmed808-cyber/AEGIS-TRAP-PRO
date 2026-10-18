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

# ---- Bedrock ----
variable "bedrock_profile_regions" {
  type    = list(string)
  default = ["us-east-1", "us-east-2", "us-west-2"]
}
variable "bedrock_logs_bucket_name" {
  type    = string
  default = "proj-prod-bedrock-logs"
}
variable "bedrock_model_id" {
  type        = string
  description = "The ONE model the app role may invoke"
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}
variable "bedrock_model_arns" {
  type        = list(string)
  default     = []
  description = "Override if using a cross-region inference profile (profile ARN + underlying foundation-model ARNs)"
}
variable "create_guardrail" {
  type    = bool
  default = true
}
variable "existing_guardrail_id" {
  type    = string
  default = ""
}
variable "existing_guardrail_version" {
  type    = string
  default = ""
}

variable "create_asg_kms_grant" {
  type    = bool
  default = false
}

variable "name_prefix" { type = string }
variable "region" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "private_subnet_ids" { type = list(string) }
variable "canary_users" {
  type = map(object({
    name = string
  }))
  default = {
    "1" = { name = "proj-prod-canary-1" }
    "2" = { name = "proj-prod-canary-2" }
  }
}
variable "bedrock_profile_regions" {
  type    = list(string)
}
variable "documents_bucket_name" { type = string }
variable "build_artifacts_bucket_name" { type = string }
variable "logging_bucket_name" { type = string }
variable "ami_id" {
  type    = string
  default = "ami-0d27e0fb3bac4d724"
}
variable "app_instance_type" { type = string }
variable "jenkins_instance_type" { type = string }
variable "root_device_name" {
  type    = string
  default = "/dev/xvda"
}
variable "root_volume_size" {
  type    = number
  default = 30
}
variable "bedrock_model_id" { type = string }
variable "bedrock_model_arns" {
  type    = list(string)
  default = []
}
variable "guardrail_id" { type = string }
variable "guardrail_arn" { type = string }
variable "guardrail_version" { type = string }
variable "summaries_prefix" {
  type    = string
  default = "summaries/"
}
variable "artifact_prefix" {
  type    = string
  default = "documind/"
}
variable "log_retention_days" {
  type    = number
  default = 90
}
variable "asg_min" {
  type    = number
  default = 2
}
variable "asg_desired" {
  type    = number
  default = 2
}
variable "asg_max" {
  type    = number
  default = 4
}
variable "create_asg_kms_grant" {
  type    = bool
  default = false
}
variable "app_source_dir" { type = string }

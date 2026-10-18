variable "name_prefix" { type = string }
variable "region" { type = string }
variable "logs_bucket_name" { type = string }
variable "create_guardrail" { type = bool }
variable "existing_guardrail_id" { type = string }
variable "existing_guardrail_version" { type = string }

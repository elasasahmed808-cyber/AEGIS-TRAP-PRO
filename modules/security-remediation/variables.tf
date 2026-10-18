variable "vpc_id" {
  description = "The ID of the VPC where the isolation security group will be created"
  type        = string
}

variable "alert_email" {
  description = "The email address to receive security alerts via SNS"
  type        = string
  default     = ""
}

variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = "prod"
}
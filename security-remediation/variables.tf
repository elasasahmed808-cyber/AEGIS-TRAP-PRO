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

variable "asg_action" {
  description = "ASG playbook action for a compromised instance: detach or standby"
  type        = string
  default     = "detach"

  validation {
    condition     = contains(["detach", "standby"], var.asg_action)
    error_message = "asg_action must be \"detach\" or \"standby\"."
  }
}

variable "protected_principals" {
  description = "IAM user/role names the key-disable playbook must never touch (break-glass accounts)"
  type        = list(string)
  default     = []
}

variable "evidence_retention_days" {
  description = "S3 Object Lock retention (days) for forensic chain-of-custody records"
  type        = number
  default     = 365
}

variable "max_hash_blocks" {
  description = "Max 512 KiB EBS blocks hashed per snapshot (20000 is about 10 GiB of data)"
  type        = number
  default     = 20000
}

variable "enable_guardduty_trigger" {
  description = "Translate native GuardDuty findings (source aws.guardduty) into playbook events"
  type        = bool
  default     = true
}

variable "enable_securityhub_trigger" {
  description = "Translate Security Hub findings into playbook events. Safe to enable alongside the GuardDuty trigger: GuardDuty findings imported into Security Hub are ignored by the translator, so only findings from other products (Inspector, Macie, ...) are added"
  type        = bool
  default     = false
}

variable "translator_min_severity" {
  description = "Minimum finding severity to forward, on the GuardDuty 0-9 scale. Security Hub severities are normalised to the same scale"
  type        = number
  default     = 7

  validation {
    condition     = var.translator_min_severity >= 0 && var.translator_min_severity <= 9
    error_message = "translator_min_severity must be between 0 and 9."
  }
}

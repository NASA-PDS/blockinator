variable "component_name" {
  type        = string
  description = "Component/repository name used for SSM parameter prefixes"
  default     = "cds-infra"
}

variable "aws_region" {
  type        = string
  description = "AWS region for DynamoDB, SQS, and Lambdas"
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "AWS profile to use for authentication"
  type        = string
  default     = ""
}

variable "permissions_boundary_arn" {
  description = "ARN of the permissions boundary policy to attach to IAM roles. Empty skips the boundary."
  type        = string
  default     = ""
}

variable "venue" {
  type        = string
  description = "Deployment venue/environment identifier (e.g., pdc-cds-dev)"
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "cicd" {
  description = "CICD identifier tag value (e.g., iac, cd)"
  type        = string
  default     = "iac"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for blocklist Lambdas"
  type        = number
  default     = 90
}

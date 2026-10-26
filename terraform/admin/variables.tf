variable "component_name" {
  type        = string
  description = "Component/repository name used for SSM parameter prefixes"
  default     = "cds-infra"
}

variable "aws_region" {
  type        = string
  description = "AWS region where the platform stage deploys DynamoDB, SQS, and Lambdas (used to construct resource ARNs in IAM policies)"
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "AWS profile to use for authentication"
  type        = string
  default     = ""
}

variable "venue" {
  type        = string
  description = "Deployment venue/environment identifier"
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

variable "ssm_prefix" {
  description = "SSM prefix where the platform stage publishes its outputs; must match that stage's computed prefix. Empty uses /pds/<component_name>/ip-blocklist."
  type        = string
  default     = ""
}

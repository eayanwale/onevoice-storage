variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  description = "Environment name (e.g. prod, staging, sandbox)"
  type        = string
  default     = "prod"
}

variable "aws_profile" {
  type    = string
  default = "onevoice"
}

variable "organization" {
  type    = string
  default = "onevoice"
}

variable "application" {
  type    = string
  default = "nextcloud"
}
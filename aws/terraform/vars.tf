variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  description = "Environment name (e.g. prod, staging, sandbox)"
  type        = string
  default     = "prod"
}

# variable "account_id" {
#   type = string
#   default = "947792709164"
# }

variable "organization" {
  type    = string
  default = "onevoice"
}

variable "profile" {
  type    = string
  default = "onevoice"
}

variable "application" {
  type    = string
  default = "nextcloud"
}

variable "subnet_cidrs" {
  description = "Subnet CIDRs"
  type        = map(string)

  default = {
    a = "10.30.1.0/28"
    # b = "10.30.2.0/28"
    c = "10.30.3.0/28"
    d = "10.30.4.0/28"
  }
}

variable "db_username" {
  description = "Database username"
  type        = string
  default     = "nextcloud"
}

variable "ops_alert_emails" {
  type = list(string)
  default = [
    "enochayanwale@outlook.com",
    "somorijoseph@gmail.com"
  ]
}

variable "monthly_budget_limit" {
  description = "Monthly AWS cost budget threshold, in USD"
  type        = string
  default     = "35"
}
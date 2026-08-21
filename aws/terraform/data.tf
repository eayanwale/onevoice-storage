data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "terraform_remote_state" "bootstrap" {
  backend = "s3"

  # Backend blocks can't reference variables, so environment isolation is
  # via Terraform workspaces (same bucket, key auto-prefixed per workspace)
  # rather than a var-driven bucket/key here. Requires bootstrap to have
  # been applied under a matching workspace name.
  config = {
    bucket  = "onevoice-prod-terraform-state"
    key     = terraform.workspace == "default" ? "infra/bootstrap/terraform.tfstate" : "env:/${terraform.workspace}/infra/bootstrap/terraform.tfstate"
    region  = "us-east-1"
    profile = var.profile
  }
}

data "aws_iam_policy_document" "ec2_ssm_access" {
  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters"
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.organization}/${var.environment}/nextcloud/db-password",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.organization}/${var.environment}/nextcloud/admin-password",
      # cloudflared/nextcloud-mcp/maintenance params below are NOT managed
      # by Terraform (created out-of-band from external systems) — read-only here.
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.organization}/${var.environment}/cloudflared/tunnel-token",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.organization}/${var.environment}/nextcloud-mcp/username",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.organization}/${var.environment}/nextcloud-mcp/app-password",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.organization}/${var.environment}/maintenance/github-pat",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.organization}/${var.environment}/nextcloud/migration-bucket/access-key-id",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.organization}/${var.environment}/nextcloud/migration-bucket/secret-access-key"
    ]
  }
}

data "aws_ssm_parameter" "db_password" {
  name = "/${var.organization}/${var.environment}/nextcloud/db-password"
}

data "aws_ami" "nextcloud" {
  most_recent = true
  owners      = ["self"] # your own account, since Packer bakes it there

  filter {
    name   = "name"
    values = ["ami-nextcloud-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  db_password = data.aws_ssm_parameter.db_password.value
  ami_id      = data.aws_ami.nextcloud.id

  # Prod keeps the bare "onevoice.knoch.dev" (that's the one already live via
  # Cloudflare Tunnel); every other environment gets its own subdomain, e.g.
  # sandbox -> "sandbox.knoch.dev". Each environment's Cloudflare Tunnel must
  # be configured to route its own subdomain before this changes anything.
  domain_name = var.environment == "prod" ? "onevoice.knoch.dev" : "${var.environment}.knoch.dev"
}
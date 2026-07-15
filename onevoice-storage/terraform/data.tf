data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "terraform_remote_state" "bootstrap" {
  backend = "s3"

  config = {
    bucket  = "onevoice-prod-terraform-state"
    key     = "infra/bootstrap/terraform.tfstate"
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
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.organization}/${var.environment}/nextcloud/admin-password"
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
}
resource "aws_s3_bucket" "terraform-state" {
  bucket        = "${var.organization}-${var.environment}-terraform-state"
  force_destroy = false # protect state from accidental deletion

  tags = {
    Name = "${var.organization}-${var.environment}-terraform-state"
  }
}

resource "aws_s3_bucket_versioning" "terraform-state" {
  bucket = aws_s3_bucket.terraform-state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform-state" {
  bucket = aws_s3_bucket.terraform-state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "terraform-state" {
  bucket = aws_s3_bucket.terraform-state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "random_password" "nextcloud-db-password" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "nextcloud-db-password" {
  name  = "/${var.organization}/${var.environment}/nextcloud/db-password"
  type  = "SecureString"
  value = random_password.nextcloud-db-password.result

  tags = {
    Name = "${var.organization}-${var.environment}-nextcloud-db-password"
  }
}
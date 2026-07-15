resource "aws_s3_bucket" "nextcloud-store" {
  bucket              = "${var.organization}-${var.environment}-${var.application}-bucket"
  object_lock_enabled = true
  force_destroy       = true

  tags = {
    Name        = "${var.organization}-${var.environment}-${var.application}-bucket"
    Application = "${var.application}"
  }
}

resource "aws_s3_bucket_versioning" "nextcloud-store-versioning" {
  bucket = aws_s3_bucket.nextcloud-store.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "onevoice_logo" {
  bucket = aws_s3_bucket.nextcloud-store.bucket
  key    = "branding/logo.png"
  source = "${path.module}/assets/logo.png"
  etag   = filemd5("${path.module}/assets/logo.png")

  content_type = "image/png"
}

resource "aws_s3_bucket" "onevoice_migration" {
  bucket = "${var.organization}-${var.environment}-migration"

  tags = {
    Name        = "${var.organization}-${var.environment}-${var.application}-bucket"
    Application = "${var.application}"
  }
}

resource "aws_s3_bucket_versioning" "onevoice_migration" {
  bucket = aws_s3_bucket.onevoice_migration.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "onevoice_migration" {
  bucket                  = aws_s3_bucket.onevoice_migration.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "onevoice_migration" {
  bucket = aws_s3_bucket.onevoice_migration.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "onevoice_migration" {
  bucket = aws_s3_bucket.onevoice_migration.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}
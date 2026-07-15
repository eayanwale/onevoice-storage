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
  bucket = aws_s3_bucket.nextcloud-store.bucket_domain_name
  key    = "branding/logo.png"
  source = "${path.module}/assets/logo.png"
  etag   = filemd5("${path.module}/assets/logo.png")

  content_type = "image/png"
}
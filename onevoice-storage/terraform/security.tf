resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket = "${var.organization}-${var.environment}-cloudtrail-logs"

  tags = {
    Name = "${var.organization}-${var.environment}-cloudtrail-logs"
  }
}

resource "aws_s3_bucket_versioning" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket                  = aws_s3_bucket.cloudtrail_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

locals {
  cloudtrail_name = "${var.organization}-${var.environment}-trail"
  cloudtrail_arn  = "arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${local.cloudtrail_name}"
}

# Standard CloudTrail bucket policy, scoped to this specific trail via aws:SourceArn
# so no other trail (in this or another account) can write here.
resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail_logs.arn
        Condition = {
          StringEquals = { "aws:SourceArn" = local.cloudtrail_arn }
        }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = local.cloudtrail_arn
          }
        }
      }
    ]
  })
}

resource "aws_cloudtrail" "main" {
  name                          = local.cloudtrail_name
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.cloudtrail_logs]

  tags = {
    Name = local.cloudtrail_name
  }
}

# --- GuardDuty ---

resource "aws_guardduty_detector" "main" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES" # fast enough to be worth paging on, since findings feed SNS below

  tags = {
    Name = "${var.organization}-${var.environment}-guardduty"
  }
}

# --- Security Hub ---
# enable_default_standards defaults to true, auto-subscribing to AWS Foundational
# Security Best Practices. Security Hub also auto-ingests GuardDuty findings once
# both services are on in the same account — no extra wiring needed for that part.
resource "aws_securityhub_account" "main" {}

# --- Route high-severity findings to the existing ops-alerts SNS topic ---

resource "aws_sns_topic_policy" "ops_alerts_eventbridge" {
  arn = aws_sns_topic.ops_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.ops_alerts.arn
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "guardduty_high_findings" {
  name = "${var.organization}-${var.environment}-guardduty-high-findings"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 7] }]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_high_findings_sns" {
  rule = aws_cloudwatch_event_rule.guardduty_high_findings.name
  arn  = aws_sns_topic.ops_alerts.arn
}

resource "aws_cloudwatch_event_rule" "securityhub_critical_findings" {
  name = "${var.organization}-${var.environment}-securityhub-critical-findings"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        Severity = { Label = ["CRITICAL", "HIGH"] }
        Workflow = { Status = ["NEW"] }
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "securityhub_critical_findings_sns" {
  rule = aws_cloudwatch_event_rule.securityhub_critical_findings.name
  arn  = aws_sns_topic.ops_alerts.arn
}

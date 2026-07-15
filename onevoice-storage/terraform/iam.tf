resource "aws_iam_role" "nextcloud-ec2-role" {
  name = "${var.organization}-${var.environment}-nextcloud-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.organization}-${var.environment}-nextcloud-ec2-role"
  }
}

resource "aws_iam_policy" "nextcloud-s3-access" {
  name        = "${var.organization}-${var.environment}-nextcloud-s3-access"
  description = "Allows the Nextcloud EC2 instance to read/write its primary storage bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.nextcloud-store.arn
      },
      {
        Sid    = "ObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.nextcloud-store.arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "nextcloud-s3-attach" {
  role       = aws_iam_role.nextcloud-ec2-role.name
  policy_arn = aws_iam_policy.nextcloud-s3-access.arn
}

resource "aws_iam_instance_profile" "nextcloud-instance-profile" {
  name = "${var.organization}-${var.environment}-nextcloud-instance-profile"
  role = aws_iam_role.nextcloud-ec2-role.name
}

resource "aws_iam_policy" "nextcloud-user-passwords-ssm" {
  name        = "${var.organization}-${var.environment}-nextcloud-user-passwords-ssm"
  description = "Allows the Nextcloud EC2 instance to write generated user passwords to SSM"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PutUserPasswords"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter"
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${var.organization}/${var.environment}/nextcloud/users/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "nextcloud-user-passwords-ssm-attach" {
  role       = aws_iam_role.nextcloud-ec2-role.name
  policy_arn = aws_iam_policy.nextcloud-user-passwords-ssm.arn
}

resource "aws_iam_role_policy" "ssm_access" {
  name   = "${var.organization}-${var.environment}-ssm-access"
  role   = aws_iam_role.nextcloud-ec2-role.id
  policy = data.aws_iam_policy_document.ec2_ssm_access.json
}
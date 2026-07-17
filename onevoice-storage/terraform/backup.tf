resource "aws_iam_role" "dlm_lifecycle_role" {
  name = "${var.organization}-${var.environment}-dlm-lifecycle-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "dlm.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.organization}-${var.environment}-dlm-lifecycle-role"
  }
}

resource "aws_iam_role_policy_attachment" "dlm_lifecycle_role" {
  role       = aws_iam_role.dlm_lifecycle_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "nextcloud_data_snapshots" {
  description        = "Weekly snapshots of the Nextcloud EBS data volume"
  execution_role_arn = aws_iam_role.dlm_lifecycle_role.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Name = aws_ebs_volume.nextcloud-data.tags["Name"]
    }

    schedule {
      name = "weekly-snapshots"

      create_rule {
        cron_expression = "cron(0 3 ? * 1 *)" 
      }

      retain_rule {
        count = 4 
      }

      tags_to_add = {
        SnapshotCreator = "DLM"
      }

      copy_tags = true
    }
  }

  tags = {
    Name = "${var.organization}-${var.environment}-nextcloud-data-snapshot-policy"
  }
}

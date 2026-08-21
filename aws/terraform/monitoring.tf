# monitoring.tf

resource "aws_sns_topic" "ops_alerts" {
  name = "${var.organization}-${var.environment}-ops-alerts"
}

resource "aws_sns_topic_subscription" "ops_alerts_email" {
  for_each  = toset(var.ops_alert_emails)
  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_metric_alarm" "instance_status_check" {
  alarm_name          = "${var.organization}-${var.environment}-instance-status-check-failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Triggers when EC2 instance or system status check fails"
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]

  dimensions = {
    InstanceId = aws_instance.nextcloud-server.id
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_credit_balance_low" {
  alarm_name          = "${var.organization}-${var.environment}-cpu-credit-balance-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUCreditBalance"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 20  # tune based on baseline once you have real usage data
  alarm_description   = "Warns when CPU credit balance is running low"
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]

  dimensions = {
    InstanceId = aws_instance.nextcloud-server.id
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_utilization_high" {
  alarm_name          = "${var.organization}-${var.environment}-cpu-utilization-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Warns when EC2 CPU utilization is sustained above 80%"
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]

  dimensions = {
    InstanceId = aws_instance.nextcloud-server.id
  }
}

# Requires the CloudWatch agent running on the instance (see user-data.sh) —
# mem/disk usage aren't published under AWS/EC2 by default.
resource "aws_cloudwatch_metric_alarm" "memory_utilization_high" {
  alarm_name          = "${var.organization}-${var.environment}-memory-utilization-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Warns when memory utilization (via CloudWatch agent) is sustained above 85%"
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.nextcloud-server.id
  }
}

resource "aws_cloudwatch_metric_alarm" "disk_utilization_high" {
  alarm_name          = "${var.organization}-${var.environment}-disk-utilization-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Warns when root volume disk utilization (via CloudWatch agent) is sustained above 85%"
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.nextcloud-server.id
  }
}

resource "aws_cloudwatch_dashboard" "nextcloud_ops" {
  dashboard_name = "${var.organization}-${var.environment}-nextcloud-ops"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "CPU Utilization (%)"
          view    = "timeSeries"
          region  = var.aws_region
          period  = 300
          stat    = "Average"
          metrics = [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.nextcloud-server.id]]
          annotations = {
            horizontal = [{ label = "Alarm threshold", value = 80 }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "CPU Credit Balance"
          view    = "timeSeries"
          region  = var.aws_region
          period  = 300
          stat    = "Average"
          metrics = [["AWS/EC2", "CPUCreditBalance", "InstanceId", aws_instance.nextcloud-server.id]]
          annotations = {
            horizontal = [{ label = "Alarm threshold", value = 20 }]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Memory Used (%)"
          view    = "timeSeries"
          region  = var.aws_region
          period  = 300
          stat    = "Average"
          metrics = [["CWAgent", "mem_used_percent", "InstanceId", aws_instance.nextcloud-server.id]]
          annotations = {
            horizontal = [{ label = "Alarm threshold", value = 85 }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Disk Used (%) - root volume"
          view    = "timeSeries"
          region  = var.aws_region
          period  = 300
          stat    = "Average"
          metrics = [["CWAgent", "disk_used_percent", "InstanceId", aws_instance.nextcloud-server.id]]
          annotations = {
            horizontal = [{ label = "Alarm threshold", value = 85 }]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 24
        height = 4
        properties = {
          title   = "Instance Status Check Failed"
          view    = "timeSeries"
          region  = var.aws_region
          period  = 60
          stat    = "Maximum"
          metrics = [["AWS/EC2", "StatusCheckFailed", "InstanceId", aws_instance.nextcloud-server.id]]
        }
      }
    ]
  })
}
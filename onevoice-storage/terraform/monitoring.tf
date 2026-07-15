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
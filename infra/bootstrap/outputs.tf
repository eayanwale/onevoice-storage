output "nextcloud_db_password_ssm_path" {
  description = "SSM parameter path where the Nextcloud DB password is stored"
  value       = aws_ssm_parameter.nextcloud-db-password.name
}
output "rds_endpoint" {
  description = "The endpoint of the RDS instance"
  value       = aws_db_instance.nextcloud-db.endpoint
}

output "db_subnet_group_name" {
  description = "The name of the RDS DB subnet group"
  value       = aws_db_subnet_group.nextcloud-db-subnet-group.name
}

output "server_ip" {
  description = "The IP address of the NextCloud server"
  value       = aws_instance.nextcloud-server.public_ip
}

output "migration_mount_access_key_id" {
  description = "Access key ID for the IAM user used by Nextcloud's External Storage S3 mount"
  value       = aws_iam_access_key.nextcloud_migration_mount.id
}

output "migration_mount_secret_access_key" {
  description = "Secret access key for the IAM user used by Nextcloud's External Storage S3 mount"
  value       = aws_iam_access_key.nextcloud_migration_mount.secret
  sensitive   = true
}
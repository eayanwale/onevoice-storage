output "rds_endpoint" {
  description = "The endpoint of the RDS instance"
  value       = aws_db_instance.nextcloud-db.endpoint
}

output "db_subnet_group_name" {
  description = "The name of the RDS DB subnet group"
  value       = aws_db_subnet_group.nextcloud-db-subnet-group.name
}
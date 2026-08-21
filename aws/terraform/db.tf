resource "aws_db_subnet_group" "nextcloud-db-subnet-group" {
  name       = "${var.organization}-${var.environment}-nextcloud-db-subnet-group"
  subnet_ids = [aws_subnet.priv-a.id, aws_subnet.priv-b.id]

  tags = {
    Name = "${var.organization}-${var.environment}-nextcloud-db-subnet-group"
  }
}

resource "aws_db_instance" "nextcloud-db" {
  identifier              = "${var.organization}-${var.environment}-nextcloud-db"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  max_allocated_storage   = 100
  backup_window           = "02:00-03:00"
  storage_type            = "gp3"
  username                = var.db_username
  password                = local.db_password
  engine                  = "mysql"
  db_subnet_group_name    = aws_db_subnet_group.nextcloud-db-subnet-group.name
  vpc_security_group_ids  = [aws_security_group.db-sg.id]
  publicly_accessible     = false
  multi_az                = false
  skip_final_snapshot     = true
  deletion_protection     = false
  storage_encrypted       = true
  backup_retention_period = 7
}
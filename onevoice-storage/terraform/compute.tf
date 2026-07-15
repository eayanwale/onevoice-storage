resource "aws_key_pair" "nextcloud-key" {
  key_name   = "nextcloud-key"
  public_key = file("${path.module}/keys/nextcloud-key.pub")
}

resource "aws_instance" "nextcloud-server" {
  ami                         = local.ami_id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.pub-a.id
  vpc_security_group_ids      = [aws_security_group.nextcloud-sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.nextcloud-key.key_name
  iam_instance_profile        = aws_iam_instance_profile.nextcloud-instance-profile.name

  user_data = templatefile(
    "${path.module}/scripts/user-data.sh", {
      db_password_ssm_path    = "/${var.organization}/${var.environment}/nextcloud/db-password"
      admin_password_ssm_path = "/${var.organization}/${var.environment}/nextcloud/admin-password"
      db_host                 = aws_db_instance.nextcloud-db.address
      db_name                 = "nextcloud"
      db_user                 = "nextcloud"
      admin_user              = "admin"
      s3_bucket               = aws_s3_bucket.nextcloud-store.bucket
      aws_region              = var.aws_region
      elastic_ip              = aws_eip.eip-1.public_ip
      organization            = var.organization
      environment             = var.environment
      domain_name             = "" # no domain registered yet — Phase 6
    }
  )

  tags = {
    Name = "${var.organization}-${var.environment}-nextcloud-server"
  }
}

resource "aws_ebs_volume" "nextcloud-data" {
  availability_zone = "us-east-1a"
  size              = 40

  tags = {
    Name = "${var.organization}-${var.environment}-nextcloud-data"
  }
}

resource "aws_ebs_snapshot" "nextcloud-data-snapshot" {
  volume_id = aws_ebs_volume.nextcloud-data.id

  tags = {
    Name = "${var.organization}-${var.environment}-nextcloud-data-snapshot"
  }
}

resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.nextcloud-server.id
  allocation_id = aws_eip.eip-1.id
}
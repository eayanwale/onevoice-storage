resource "aws_key_pair" "nextcloud-key" {
  key_name   = "${var.organization}-${var.environment}-nextcloud-key"
  public_key = file("${path.module}/keys/nextcloud-key.pub")
}

resource "aws_instance" "nextcloud-server" {
  ami                         = local.ami_id
  instance_type               = "t3.medium"
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
      elastic_ip              = "x.x.x.x"
      organization            = var.organization
      environment             = var.environment

      domain_name                      = local.domain_name
      cloudflare_tunnel_token_ssm_path = "/${var.organization}/${var.environment}/cloudflared/tunnel-token"
      mcp_username_ssm_path            = "/${var.organization}/${var.environment}/nextcloud-mcp/username"
      mcp_password_ssm_path            = "/${var.organization}/${var.environment}/nextcloud-mcp/app-password"
      github_pat_ssm_path              = "/${var.organization}/${var.environment}/maintenance/github-pat"
      migration_bucket                 = aws_s3_bucket.onevoice_migration.bucket
      migration_access_key_id_ssm_path = "/${var.organization}/${var.environment}/nextcloud/migration-bucket/access-key-id"
      migration_secret_key_ssm_path    = "/${var.organization}/${var.environment}/nextcloud/migration-bucket/secret-access-key"
    }
  )

  tags = {
    Name = "${var.organization}-${var.environment}-nextcloud-server"
  }
}

# resource "aws_eip_association" "eip_assoc" {
#   instance_id   = aws_instance.nextcloud-server.id
#   allocation_id = aws_eip.eip-1.id
# }
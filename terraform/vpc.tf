resource "aws_vpc" "onevoice-vpc" {
  cidr_block = "10.30.0.0/16"
  instance_tenancy = "default"
  enable_dns_support = true
  enable_dns_hostnames = true

  tags = {
     Name = "${var.organization}-${var.environment}-vpc"
  }
}

resource "aws_internet_gateway" "onevoice-igw" {
  vpc_id = aws_vpc.onevoice-vpc.id
}

resource "aws_eip" "eip-1" {
  domain = "vpc"

  tags = {
     Name = "${var.organization}-${var.environment}-eip_1"
  }
}

resource "aws_subnet" "pub-a" {
  vpc_id = aws_vpc.onevoice-vpc.id
  cidr_block = var.subnet_cidrs.a
  availability_zone = "${var.aws_region}a"

  tags = {
     Name = "${var.organization}-${var.environment}-pub-a"
  }
}

resource "aws_subnet" "pub-b" {
  vpc_id = aws_vpc.onevoice-vpc.id
  cidr_block = var.subnet_cidrs.b
  availability_zone = "${var.aws_region}b"

  tags = {
     Name = "${var.organization}-${var.environment}-pub-b"
  }
}

resource "aws_route_table" "main-rt" {
  vpc_id = aws_vpc.onevoice-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.onevoice-igw.id
  }

  tags = {
     Name = "${var.organization}-${var.environment}-main-rt"
  }
}

resource "aws_route_table_association" "pub-a" {
  subnet_id = aws_subnet.pub-a.id
  route_table_id = aws_route_table.main-rt.id
}

resource "aws_route_table_association" "pub-b" {
  subnet_id = aws_subnet.pub-b.id
  route_table_id = aws_route_table.main-rt.id
}

resource "aws_security_group" "nextcloud-sg" {
  name = "${var.organization}-${var.environment}-nextcloud-sg"
  description = "Allow 22, 80 and 443"
  vpc_id = aws_vpc.onevoice-vpc.id

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["70.21.84.34/32"]
  }

  tags = {
     Name = "${var.organization}-${var.environment}-rt"
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id = aws_vpc.onevoice-vpc.id
  service_name = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.main-rt.id
  ]
}
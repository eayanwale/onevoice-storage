packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_instance_type" {
  default = "t2.small"
}

variable "ami_name" {
  default = "ami-nextcloud-{{timestamp}}"
}

variable "component" {
  default = "nextcloud"
}

variable "aws_accounts" {
  type    = list(string)
  default = ["524558748095"]
}

variable "ami_regions" {
  type    = list(string)
  default = ["us-east-1"]
}

variable "aws_region" {
  default = "us-east-1"
}

data "amazon-ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  region      = "${var.aws_region}"

  filters = {
    name                = "al2023-ami-*-x86_64"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
  }
}

locals { timestamp = regex_replace(timestamp(), "[- TZ:]", "") }

source "amazon-ebs" "amazon_ebs" {
  profile        = "onevoice"
  ami_name       = "${var.ami_name}"
  ami_regions    = "${var.ami_regions}"
  ami_users      = "${var.aws_accounts}"
  snapshot_users = "${var.aws_accounts}"
  encrypt_boot   = false
  instance_type  = "${var.aws_instance_type}"

  launch_block_device_mappings {
    delete_on_termination = true
    device_name           = "/dev/xvda"
    encrypted             = false
    volume_size           = 30
    volume_type           = "gp2"
  }

  region       = "${var.aws_region}"
  source_ami   = data.amazon-ami.al2023.id
  ssh_pty      = true
  ssh_timeout  = "5m"
  ssh_username = "ec2-user"
}

build {
  sources = ["source.amazon-ebs.amazon_ebs"]
  provisioner "shell" {
    script          = "setup.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }
}
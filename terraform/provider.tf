provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "onevoice-storage"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
provider "aws" {
  region = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "onevoice-storage"
      ManagedBy   = "terraform"
      Environment = var.environment
      Application = var.application
    }
  }
}
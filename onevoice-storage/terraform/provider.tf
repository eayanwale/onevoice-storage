provider "aws" {
  region  = var.aws_region
  profile = var.profile

  default_tags {
    tags = {
      Project     = "onevoice-storage"
      ManagedBy   = "terraform"
      Environment = var.environment
      Application = var.application
    }
  }
}
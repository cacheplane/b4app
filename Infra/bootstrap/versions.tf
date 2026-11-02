terraform {
  required_version = ">= 1.17.1, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.71.0"
    }
  }

  # The first apply uses local state because the state bucket does not exist
  # yet. After it succeeds, uncomment this block, fill in the bucket name for
  # the environment, and run `terraform init -migrate-state` (Infra/README.md).
  #
  # backend "s3" {
  #   bucket       = "b4hub-<env>-tfstate"
  #   key          = "bootstrap/terraform.tfstate"
  #   region       = "us-east-2"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "b4hub"
      Environment = var.environment
      ManagedBy   = "terraform"
      Root        = "bootstrap"
    }
  }
}

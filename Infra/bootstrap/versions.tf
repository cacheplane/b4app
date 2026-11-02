terraform {
  required_version = ">= 1.17.1, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.71.0"
    }
  }

  # The first apply uses local state because the state bucket does not exist
  # yet. After it succeeds, uncomment this partial configuration and run
  # `terraform init -migrate-state` with the -backend-config values from
  # Infra/README.md. The values are passed per environment because the bucket
  # policy requires SSE-KMS, so kms_key_id must be given (plain `encrypt = true`
  # would send AES256 and be refused).
  #
  # backend "s3" {
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

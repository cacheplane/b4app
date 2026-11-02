terraform {
  required_version = ">= 1.17.1, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.71.0"
      # The second configuration receives cross-region backup copies. Roots
      # pass providers = { aws = aws, aws.copy = aws.copy }; with no copy region
      # they pass the same provider twice and backup_copy_region = null.
      configuration_aliases = [aws.copy]
    }
  }
}

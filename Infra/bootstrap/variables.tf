variable "environment" {
  description = "Account this root is applied to: test or prod."
  type        = string

  validation {
    condition     = contains(["test", "prod"], var.environment)
    error_message = "environment must be test or prod."
  }
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose workflows may assume the roles."
  type        = string
  default     = "cacheplane/b4app"
}

variable "region" {
  description = "AWS region for the state bucket and the provider."
  type        = string
  default     = "us-east-2"
}

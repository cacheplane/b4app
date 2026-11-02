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

# GitHub issues this repository's OIDC tokens with the immutable subject
# format (`repo:<owner>@<owner id>/<name>@<repository id>:...`), which a
# rename or a transfer cannot spoof. Both ids come from
# `gh api repos/<owner>/<name> --jq '[.owner.id, .id]'`.
variable "github_owner_id" {
  description = "Numeric id of the GitHub owner (organization or user) of github_repository."
  type        = number
  default     = 269322961
}

variable "github_repository_id" {
  description = "Numeric id of the GitHub repository github_repository."
  type        = number
  default     = 1440075505
}

variable "region" {
  description = "AWS region for the state bucket and the provider."
  type        = string
  default     = "us-east-2"
}

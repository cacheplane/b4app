# One repository per account: each environment is its own account, so the
# name carries no environment. Tags are immutable; deploys pin the digest.
resource "aws_ecr_repository" "hub" {
  name                 = "b4hub"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# The AWS ruleset plugin is not enabled: installing it needs network access to
# GitHub releases (`tflint --init`). Add a `plugin "aws"` block here once it can
# be installed and pinned.

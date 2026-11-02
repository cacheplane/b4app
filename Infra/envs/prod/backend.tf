# Partial configuration: init passes bucket, key, region, kms_key_id, and
# encrypt with -backend-config (see Infra/README.md, "Environment roots").
# The bucket is b4hub-prod-tfstate and the key is hub.tfstate.
terraform {
  backend "s3" {
    use_lockfile = true
  }
}

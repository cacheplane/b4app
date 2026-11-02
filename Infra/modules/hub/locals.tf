locals {
  # test and prod get disjoint ranges so the accounts could be peered later.
  vpc_cidr = var.environment == "prod" ? "10.20.0.0/16" : "10.10.0.0/16"

  azs = ["${var.region}a", "${var.region}b"]

  # /20 subnets carved from the /16: public first (indexes 0 and 1), then
  # private (indexes 2 and 3).
  public_subnet_cidrs  = [for i in range(2) : cidrsubnet(local.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i in range(2) : cidrsubnet(local.vpc_cidr, 4, i + 2)]

  name = "b4hub-${var.environment}"
}

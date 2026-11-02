# Infrastructure

Terraform for the hosted hubs on AWS: two accounts (`b4hub-test`, `b4hub-prod`) in one Organization, region `us-east-2`, applied by GitHub Actions over OIDC from `cacheplane/b4app`. Terraform is pinned in `.terraform-version`; linting is `tflint` with `.tflint.hcl`. Before committing: `terraform fmt -check -recursive Infra`, then in each root `terraform validate`, `tflint --config ../.tflint.hcl`, and `terraform test`.

| Root | Purpose |
| --- | --- |
| `bootstrap/` | Applied by hand once per account: state bucket, GitHub OIDC provider, and the `plan`, `infra`, and `deploy` roles CI assumes. |

## Bootstrap runbook

Do this once per account, test first.

1. **Organization and accounts.** In the management account create an AWS Organization, then two member accounts, `b4hub-test` and `b4hub-prod`. Turn on MFA for the management account root user and do not use root afterwards.
2. **Identity Center.** Enable IAM Identity Center in the management account, create one user for yourself, one permission set with the `AdministratorAccess` managed policy, and assign it to both member accounts. Require MFA for sign-in. Configure the profile with `aws configure sso`.
3. **Apply bootstrap.** For each account:

   ```bash
   aws sso login --profile b4hub-test
   cd Infra/bootstrap
   export AWS_PROFILE=b4hub-test
   terraform init
   terraform apply -var environment=test      # prod: -var environment=prod
   terraform output
   ```

   The state is local for this first apply. The S3 bucket name `b4hub-<env>-tfstate` is global; if it is taken, the apply fails and the name needs a suffix (change `local.state_bucket`).
4. **Record the role ARNs** as GitHub repository variables (Settings, Secrets and variables, Actions, Variables; they are not secrets, ARNs are not sensitive): `AWS_ROLE_PLAN_TEST`, `AWS_ROLE_INFRA_TEST`, `AWS_ROLE_DEPLOY_TEST` from `plan_role_arn`, `infra_role_arn`, `deploy_role_arn`, and the `_PROD` equivalents from the prod account. Create the `production` GitHub environment with required reviewers; the prod `infra` and `deploy` roles trust only jobs that run in it.
5. **Move the bootstrap state into the bucket.** Uncomment the `backend "s3"` block in `bootstrap/versions.tf`, set `bucket` to `b4hub-<env>-tfstate`, then:

   ```bash
   terraform init -migrate-state
   ```

   Answer `yes`. Check that `terraform plan -var environment=<env>` shows no changes, then delete the local `terraform.tfstate*` files.

### Who can assume what

| Role | Trusted subject | Permissions |
| --- | --- | --- |
| `b4hub-<env>-plan` | `repo:cacheplane/b4app:*` (any ref) | `ReadOnlyAccess`, read state, lock object write |
| `b4hub-<env>-infra` | test: `ref:refs/heads/main`; prod: `environment:production` | `AdministratorAccess` capped by `b4hub-<env>-boundary` (no IAM users, access keys, login profiles, Organizations, or account actions; cannot edit the three roles or the boundary) |
| `b4hub-<env>-deploy` | same as infra | ECS rollout in cluster `b4hub-<env>`, `iam:PassRole` for the two task roles, push and pull on ECR repository `b4hub`, read `/b4hub/<env>/*` logs |

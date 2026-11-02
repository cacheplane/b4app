# Infrastructure

Terraform for the hosted hubs on AWS: two accounts (`b4hub-test`, `b4hub-prod`) in one Organization, region `us-east-2`, applied by GitHub Actions over OIDC from `cacheplane/b4app`. Terraform is pinned in `.terraform-version`; linting is `tflint` with `.tflint.hcl`. Before committing: `terraform fmt -check -recursive Infra`, then in each root `terraform validate`, `tflint --config ../.tflint.hcl`, and `terraform test`.

| Root | Purpose |
| --- | --- |
| `bootstrap/` | Applied by hand once per account: state bucket, GitHub OIDC provider, and the `plan`, `infra`, and `deploy` roles CI assumes. |

## Bootstrap runbook

Do this one account at a time: finish steps 3 to 5 for `test` before starting `prod`. Every account starts from a clean `.terraform` and local state, and gets its own backend values, so nothing is shared between the two applies.

1. **Organization and accounts.** In the management account create an AWS Organization, then two member accounts, `b4hub-test` and `b4hub-prod`. Turn on MFA for the management account root user and do not use root afterwards.
2. **Identity Center.** Enable IAM Identity Center in the management account, create one user for yourself, one permission set with the `AdministratorAccess` managed policy, and assign it to both member accounts. Require MFA for sign-in. Configure two SSO profiles with `aws configure sso`, named `b4hub-test` and `b4hub-prod`.
3. **Apply bootstrap** (shown for `test`; do the whole of steps 3 to 5 for `test`, then repeat them for `prod` with `ENV=prod`):

   ```bash
   export ENV=test                            # prod: ENV=prod
   export AWS_PROFILE=b4hub-$ENV
   aws sso login
   cd Infra/bootstrap
   rm -rf .terraform terraform.tfstate*       # nothing carried over from the other account
   terraform init
   terraform apply -var environment=$ENV
   ```

   The state is local (`terraform.tfstate` in this directory) for this first apply. The S3 bucket name `b4hub-<env>-tfstate` is global; if it is taken, the apply fails and the name needs a suffix (change `local.state_bucket`). Capture the outputs now, while the backend is still local:

   ```bash
   STATE_BUCKET=$(terraform output -raw state_bucket)
   STATE_KMS_KEY_ARN=$(terraform output -raw state_kms_key_arn)
   terraform output                           # note the three role ARNs for step 4
   ```
4. **Record the role ARNs** as GitHub repository variables (Settings, Secrets and variables, Actions, Variables; they are not secrets, ARNs are not sensitive): `AWS_ROLE_PLAN_TEST`, `AWS_ROLE_INFRA_TEST`, `AWS_ROLE_DEPLOY_TEST` from `plan_role_arn`, `infra_role_arn`, `deploy_role_arn`, and the `_PROD` equivalents from the prod account. Create the `production` GitHub Environment with required reviewers and with deployment branches and tags limited to `main` and `hub-v*`. The prod `infra` and `deploy` roles trust any job that declares `environment: production`, so without those rules any branch that does so could reach prod after a reviewer's approval.
5. **Move the bootstrap state into the bucket.** Edit `Infra/bootstrap/versions.tf` and uncomment the partial `backend "s3" { use_lockfile = true }` block, then, in the same shell (the variables from step 3 must still be set):

   ```bash
   terraform init -migrate-state \
     -backend-config=bucket=$STATE_BUCKET \
     -backend-config=key=bootstrap.tfstate \
     -backend-config=region=us-east-2 \
     -backend-config=kms_key_id=$STATE_KMS_KEY_ARN \
     -backend-config=encrypt=true
   ```

   Answer `yes` to copy the existing state. The key ARN is required: the bucket policy refuses any write that is not SSE-KMS, and `encrypt = true` alone sends AES256. Verify, and only then clean up:

   ```bash
   terraform plan -var environment=$ENV       # must report: No changes
   git checkout -- versions.tf                # back to the commented block
   rm -rf .terraform terraform.tfstate*       # drop the now-stale local state
   ```

   If the plan shows anything to create, stop: the migration did not carry the state over, and the local `terraform.tfstate` is still the only copy. Then go back to step 3 for the other environment (`ENV=prod`, profile `b4hub-prod`).

The same pattern (a partial `backend "s3" { use_lockfile = true }` plus the five `-backend-config` values per environment, with `key` set per root) is what `envs/test` and `envs/prod` use.

### Boundary rules for later roots

Every IAM role a root creates through the infra role must set `permissions_boundary` to `b4hub-<env>-boundary`: the boundary denies `iam:CreateRole` and `iam:PutRolePermissionsBoundary` for any other value.

### Who can assume what

| Role | Trusted subject | Permissions |
| --- | --- | --- |
| `b4hub-<env>-plan` | `repo:cacheplane/b4app:*` (any ref) | `ReadOnlyAccess`, read state, lock object write |
| `b4hub-<env>-infra` | test: `ref:refs/heads/main`; prod: `environment:production` | `AdministratorAccess` capped by `b4hub-<env>-boundary` (no IAM users, access keys, login profiles, Organizations, or account actions; cannot edit the three roles or the boundary) |
| `b4hub-<env>-deploy` | same as infra | ECS rollout in cluster `b4hub-<env>`, `iam:PassRole` for the two task roles, push and pull on ECR repository `b4hub`, read `/b4hub/<env>/*` logs |

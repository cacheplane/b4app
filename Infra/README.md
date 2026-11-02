# Infrastructure

Terraform for the hosted hubs on AWS: two accounts (`b4hub-test`, `b4hub-prod`) in one Organization, region `us-east-2`, applied by GitHub Actions over OIDC from `cacheplane/b4app`. Terraform is pinned in `.terraform-version`; linting is `tflint` with `.tflint.hcl`. Before committing: `terraform fmt -check -recursive Infra`, then in each root `terraform validate`, `tflint --config ../.tflint.hcl`, and `terraform test`.

| Root | Purpose |
| --- | --- |
| `bootstrap/` | Applied by hand once per account: state bucket, GitHub OIDC provider, and the `plan`, `infra`, and `deploy` roles CI assumes. |

## Bootstrap runbook

Do this one account at a time: finish steps 3 to 5 for `test` before starting `prod`. Each account gets its own local state file and its own backend values, so nothing is shared between the two applies.

1. **Organization and accounts.** In the management account create an AWS Organization, then two member accounts, `b4hub-test` and `b4hub-prod`. Turn on MFA for the management account root user and do not use root afterwards.
2. **Identity Center.** Enable IAM Identity Center in the management account, create one user for yourself, one permission set with the `AdministratorAccess` managed policy, and assign it to both member accounts. Require MFA for sign-in. Configure two SSO profiles with `aws configure sso`, named `b4hub-test` and `b4hub-prod`.
3. **Apply bootstrap** (shown for `test`; repeat for `prod` only after step 5 is done for `test`):

   ```bash
   export AWS_PROFILE=b4hub-test              # prod: b4hub-prod
   aws sso login
   cd Infra/bootstrap
   rm -rf .terraform                          # no backend carried over from the other account
   terraform init
   terraform apply -var environment=test -state=test.tfstate   # prod: -var environment=prod -state=prod.tfstate
   terraform output
   ```

   The state is local for this first apply. The S3 bucket name `b4hub-<env>-tfstate` is global; if it is taken, the apply fails and the name needs a suffix (change `local.state_bucket`).
4. **Record the role ARNs** as GitHub repository variables (Settings, Secrets and variables, Actions, Variables; they are not secrets, ARNs are not sensitive): `AWS_ROLE_PLAN_TEST`, `AWS_ROLE_INFRA_TEST`, `AWS_ROLE_DEPLOY_TEST` from `plan_role_arn`, `infra_role_arn`, `deploy_role_arn`, and the `_PROD` equivalents from the prod account. Create the `production` GitHub Environment with required reviewers and with deployment branches and tags limited to `main` and `hub-v*`. The prod `infra` and `deploy` roles trust any job that declares `environment: production`, so without those rules any branch that does so could reach prod after a reviewer's approval.
5. **Move the bootstrap state into the bucket.** Uncomment the partial `backend "s3" { use_lockfile = true }` block in `bootstrap/versions.tf`, then initialise with the environment's values:

   ```bash
   terraform init -migrate-state \
     -backend-config=bucket=b4hub-test-tfstate \
     -backend-config=key=bootstrap.tfstate \
     -backend-config=region=us-east-2 \
     -backend-config=kms_key_id="$(terraform output -raw state_kms_key_arn)" \
     -backend-config=encrypt=true
   ```

   Answer `yes`. The key ARN must be passed: the bucket policy refuses any write that is not SSE-KMS, and `encrypt = true` alone sends AES256. Check that `terraform plan -var environment=test` shows no changes, then delete `test.tfstate*`. Run `terraform output` before this step, since after the first migrate it reads from the bucket. For prod, revert the backend block change (or use a clean checkout), run `rm -rf .terraform`, and repeat with `b4hub-prod-tfstate` and the prod profile.

The same pattern (a partial `backend "s3" { use_lockfile = true }` plus the five `-backend-config` values per environment, with `key` set per root) is what `envs/test` and `envs/prod` use.

### Boundary rules for later roots

Every IAM role a root creates through the infra role must set `permissions_boundary` to `b4hub-<env>-boundary`: the boundary denies `iam:CreateRole` and `iam:PutRolePermissionsBoundary` for any other value.

### Who can assume what

| Role | Trusted subject | Permissions |
| --- | --- | --- |
| `b4hub-<env>-plan` | `repo:cacheplane/b4app:*` (any ref) | `ReadOnlyAccess`, read state, lock object write |
| `b4hub-<env>-infra` | test: `ref:refs/heads/main`; prod: `environment:production` | `AdministratorAccess` capped by `b4hub-<env>-boundary` (no IAM users, access keys, login profiles, Organizations, or account actions; cannot edit the three roles or the boundary) |
| `b4hub-<env>-deploy` | same as infra | ECS rollout in cluster `b4hub-<env>`, `iam:PassRole` for the two task roles, push and pull on ECR repository `b4hub`, read `/b4hub/<env>/*` logs |

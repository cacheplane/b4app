# Infrastructure

Terraform for the hosted hubs on AWS: two accounts (`b4hub-test`, `b4hub-prod`) in one Organization, region `us-east-2`, applied by GitHub Actions over OIDC from `cacheplane/b4app`. Terraform is pinned in `.terraform-version`; linting is `tflint` with `.tflint.hcl`. Before committing: `terraform fmt -check -recursive Infra`, then in each root `terraform validate`, `tflint --config ../.tflint.hcl`, and `terraform test`.

| Root | Purpose |
| --- | --- |
| `modules/hub/` | The hub's network, edge, data, compute, and observability. Not applied directly; the two roots below call it. |
| `envs/test/`, `envs/prod/` | One root per account. They differ only in hostname, backup retention and copy region, log retention, and budget. |
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
| `b4hub-<env>-deploy` | same as infra | ECS rollout in cluster `b4hub-<env>`, `iam:PassRole` for the two task roles, push and pull on ECR repository `b4hub`, read `/b4hub/<env>/*` logs, `secretsmanager:DescribeSecret` on `b4hub/*` (ARNs only, never values), `ec2:DescribeSecurityGroups` (to find `b4hub-<env>-admin` for the migration task). An account bootstrapped before the last two were added needs bootstrap re-applied before its first deploy. |

## Environment roots

Each root declares two AWS providers (`aws` in `us-east-2`, and `aws.copy` for the cross-region backup copy: `us-west-2` for prod, the same region for test, which sets no copy region), calls `modules/hub`, and re-exports the outputs the owner needs (`alb_dns_name`, `acm_validation_records`, `db_master_secret_arn`, `secret_arns`, `cluster_name`, `service_name`, `ecr_repository_url`).

| Setting | test | prod |
| --- | --- | --- |
| `hostname` | `hub.test.b4.run` | `hub.b4.run` |
| `db_backup_retention_days` | 7 | 14 |
| `backup_copy_region` | none | `us-west-2` |
| `log_retention_days` | 30 (module default) | 90 |
| `monthly_budget_usd` | 70 | 80 |
| `desired_count` | 0, then 1 | 0, then 1 |

The one required input is `alarm_email`, with no default. CI passes it as `TF_VAR_alarm_email` from the repository variable `B4HUB_ALARM_EMAIL`; by hand, `export TF_VAR_alarm_email=you@example.com`. AWS emails a subscription confirmation to it once per environment; the alarms stay silent until it is confirmed.

### Initialize a root by hand

The `-backend-config` values are the same five as for bootstrap, with `key=hub.tfstate`:

```bash
export ENV=test                            # prod: ENV=prod
export AWS_PROFILE=b4hub-$ENV
cd Infra/envs/$ENV
terraform init \
  -backend-config=bucket=b4hub-$ENV-tfstate \
  -backend-config=key=hub.tfstate \
  -backend-config=region=us-east-2 \
  -backend-config=kms_key_id=<state_kms_key_arn from bootstrap> \
  -backend-config=encrypt=true
```

### Owner steps before the first plan

1. Bootstrap both accounts (runbook above).
2. Add repository variables for each environment: `AWS_ROLE_PLAN_<ENV>`, `AWS_ROLE_INFRA_<ENV>`, `AWS_ROLE_DEPLOY_<ENV>`, `TFSTATE_KMS_KEY_ARN_<ENV>` (`TEST` and `PROD`), plus `B4HUB_ALARM_EMAIL`.
3. Create one GitHub Environment, `production` (required reviewer: the owner; deployment branches and tags: `main` and `hub-v*`). Do not create one for test: a job that declares `environment: test` presents the OIDC subject `environment:test`, which the test infra role does not trust (it trusts `ref:refs/heads/main`), so `apply-test` declares none. Prod trusts `environment:production`, which is also what gates it on the reviewer.
4. Make the GHCR package `ghcr.io/cacheplane/b4hub` public.

### First apply and DNS

The first apply of each root waits on certificate validation (up to 60 minutes; the apply jobs allow 90). The validation CNAMEs must already exist at Vercel before the first prod apply is approved, otherwise that apply sits waiting; the same goes for the first test apply. Read the records first with `terraform apply -target=module.hub.aws_acm_certificate.hub` (it needs the root's `-var alarm_email=...` or `TF_VAR_alarm_email`), add the `acm_validation_records` CNAMEs and a CNAME from the hostname to `alb_dns_name` at Vercel, then run the full apply (locally, or by merging).

### First deploy: flip `desired_count`

Both roots are created with `desired_count = 0`, since no image has been deployed. After the first deploy (the deploy workflow, Task 10) rolls the service out and `/readyz` is healthy, edit `desired_count = 0` to `1` in `envs/<env>/main.tf` and merge. That apply also creates the `RunningTaskCount` alarm, which only exists while `desired_count > 0`.

### CI and reading a plan comment

`.github/workflows/infra.yml` runs on pull requests that touch `Infra/`: a `test` job (format check and `terraform test` in the module) and a `plan` job per environment (format, validate, tflint, `terraform plan`). Each plan leg posts one comment, `Terraform plan: test` or `Terraform plan: prod`, updated in place on later pushes. Read the summary line first (`N to add, N to change, N to destroy`), then the resource list: any database, KMS key, or state bucket marked `delete` (a replacement shows as `delete + create`) means stop and ask. The comment holds only counts and resource addresses, because the repository is public; the full plan is in the plan step of the workflow run log. On a merge to `main`, `apply-test` runs, then `apply-prod` waits for the `production` reviewer. The approver sees the PR plan comment and the test apply that already ran; the prod job then re-plans and applies its own `plan.bin` in one job, so check the prod job log if the PR comment is old.

### Alarm notifications

Seven CloudWatch alarms (5xx, unhealthy hosts, p99 latency, running tasks, database free storage, CPU, connections; unhealthy hosts and running tasks exist only while `desired_count > 0`), an EventBridge rule that emails whenever a migrate task stops (the email shows the stop code and container exit code, so a clean run is also one email; it cannot filter on a non-zero exit), and a monthly cost budget that emails at 150 percent of actual spend all go to `alarm_email` through the `b4hub-<env>-alerts` topic.

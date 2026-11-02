# Infrastructure

Terraform for the hosted hubs on AWS: two accounts (`b4hub-test`, `b4hub-prod`) in one Organization, region `us-east-2`, applied by GitHub Actions over OIDC from `cacheplane/b4app`. Terraform is pinned in `.terraform-version`; linting is `tflint` with `.tflint.hcl`. Before committing: `terraform fmt -check -recursive Infra`, then in each root `terraform validate`, `tflint --config ../.tflint.hcl`, and `terraform test`.

Contents: [Bootstrap runbook](#bootstrap-runbook) · [Boundary rules](#boundary-rules-for-later-roots) · [Environment roots](#environment-roots) · [First apply and DNS](#first-apply-and-dns) · [CI and plan comments](#ci-and-reading-a-plan-comment) · [Alarm notifications](#alarm-notifications) · [Operator runbooks](#operator-runbooks): [2 database owner](#2-bootstrap-the-database-owner) · [3 sign-in secrets](#3-set-the-sign-in-secrets) · [4 first deploy](#4-first-deploy) · [5 deploy a digest or roll back](#5-deploy-a-given-digest-or-roll-back) · [6 enroll a device](#6-enroll-a-device-before-sign-in-is-live) · [7 rotate a secret](#7-set-or-rotate-a-secret) · [8 restore drill](#8-restore-drill-monthly) · [9 incidents](#9-incident-basics) · [10 recreated ALB](#10-the-alb-was-recreated) · [11 GHCR cleanup](#11-ghcr-cleanup) · [12 chart release](#12-chart-release)

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

**Re-apply bootstrap for an older account.** The `deploy` role gained `secretsmanager:DescribeSecret` on `b4hub/*` and `ec2:DescribeSecurityGroups` after the first bootstrap design. An account bootstrapped before that fails its first deploy with `AccessDenied` on one of those calls. Re-apply from a clean checkout of `main`, with the backend of step 5 (the bootstrap state lives in the bucket):

```bash
export ENV=test                            # prod: ENV=prod
export AWS_PROFILE=b4hub-$ENV
aws sso login
cd Infra/bootstrap
rm -rf .terraform
# uncomment the backend "s3" block in versions.tf, as in step 5, then:
terraform init \
  -backend-config=bucket=b4hub-$ENV-tfstate \
  -backend-config=key=bootstrap.tfstate \
  -backend-config=region=us-east-2 \
  -backend-config=kms_key_id=<state_kms_key_arn> \
  -backend-config=encrypt=true
terraform plan -var environment=$ENV      # only the deploy role's policy should change
terraform apply -var environment=$ENV
git checkout -- versions.tf
```

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

Until an account is bootstrapped and its `AWS_ROLE_*` and `TFSTATE_KMS_KEY_ARN_*` repository variables exist, the `plan` jobs run `fmt`, `validate`, and `tflint` only and print a notice, and the `apply` jobs skip with a warning, so a pull request is not red merely because AWS is not set up yet. Once the variables exist the same jobs plan and apply for real.

`.github/workflows/infra.yml` runs on pull requests that touch `Infra/`: a `test` job (format check and `terraform test` in the module) and a `plan` job per environment (format, validate, tflint, `terraform plan`). Each plan leg posts one comment, `Terraform plan: test` or `Terraform plan: prod`, updated in place on later pushes. Read the summary line first (`N to add, N to change, N to destroy`), then the resource list: any database, KMS key, or state bucket marked `delete` (a replacement shows as `delete + create`) means stop and ask. The comment holds only counts and resource addresses, because the repository is public; the full plan is in the plan step of the workflow run log. On a merge to `main`, `apply-test` runs, then `apply-prod` waits for the `production` reviewer. The approver sees the PR plan comment and the test apply that already ran; the prod job then re-plans and applies its own `plan.bin` in one job, so check the prod job log if the PR comment is old.

### Alarm notifications

Seven CloudWatch alarms (5xx, unhealthy hosts, p99 latency, running tasks, database free storage, CPU, connections; unhealthy hosts and running tasks exist only while `desired_count > 0`), an EventBridge rule that emails whenever a migrate task stops (the email shows the stop code and container exit code, so a clean run is also one email; it cannot filter on a non-zero exit), and a monthly cost budget that emails at 150 percent of actual spend all go to `alarm_email` through the `b4hub-<env>-alerts` topic.

## Operator runbooks

Each is a numbered sequence you can repeat. Runbook 1 is the [bootstrap runbook](#bootstrap-runbook) above. Commands use `ENV` (`test` or `prod`) and the owner's Identity Center profile; nothing here runs from CI except the deploy workflow. **No step puts a secret on a command line or in a committed file:** values go through shell variables (builtins are not visible in `ps`), mode-0600 temp files that are wiped afterwards, or the terminal's own prompt.

Wipe a temp file with `rm -P <file>` on macOS or `shred -u <file>` on Linux; the examples name each file rather than a glob.

### 2. Bootstrap the database owner

Once per account, after the first `terraform apply` of the root and before the first deploy. It creates the role `b4hub_owner` and the database `b4hub` with the RDS master credential, which this step uses and nothing else does.

1. **Give the two database secrets a throwaway value.** ECS refuses to start a task whose `valueFrom` secret has no value, and the `hub-admin` task references both URLs. Step 5 replaces these with the real URLs before any deploy:

   ```bash
   export ENV=test                            # prod: ENV=prod
   export AWS_PROFILE=b4hub-$ENV AWS_REGION=us-east-2
   aws sso login
   for s in database-admin-url database-url; do
     aws secretsmanager put-secret-value --secret-id b4hub/$s --secret-string placeholder > /dev/null
   done
   ```

2. **Generate both passwords** into shell variables of this terminal (hex is URL-safe; keep this terminal open until step 5), and copy the owner's to the clipboard:

   ```bash
   OWNER_PW=$(openssl rand -hex 24)
   APP_PW=$(openssl rand -hex 24)
   printf %s "$OWNER_PW" | pbcopy             # Linux: xclip -selection clipboard
   ```

3. **Open the psql shell** in a second terminal (same profile). It starts a `hub-admin` task, waits for it, and opens `/bin/sh` in the `psql` container, which already has `PGHOST`, `PGUSER=b4hub_master`, and `PGPASSWORD` from the RDS-managed secret. It needs the Session Manager plugin (`brew install --cask session-manager-plugin`) and stops the task when you exit:

   ```bash
   export ENV=test                            # same as the first terminal
   export AWS_PROFILE=b4hub-$ENV AWS_REGION=us-east-2
   cd <repository root>
   Infra/scripts/admin-shell.sh $ENV psql
   ```

4. **Run the bootstrap SQL.** The container has no copy of the repository, so paste the statements from `Infra/sql/bootstrap-owner.sql` at a psql prompt. The password is a psql variable, so it is never in a file or on a shell command line (psql's own history lives and dies with this task). In the shell:

   ```sh
   psql -v ON_ERROR_STOP=1
   ```

   then at the `postgres=>` prompt paste the owner password in place of `<clipboard>`, followed by the three statements exactly as they appear in the file:

   ```sql
   \set owner_password '<clipboard>'
   CREATE ROLE b4hub_owner WITH LOGIN CREATEROLE PASSWORD :'owner_password';
   -- PostgreSQL 16+ (createrole_self_grant is empty by default) gives the creator
   -- only ADMIN OPTION on a new role, and CREATE DATABASE ... OWNER needs SET ROLE.
   GRANT b4hub_owner TO CURRENT_USER;
   CREATE DATABASE b4hub OWNER b4hub_owner;
   \du b4hub_owner
   \l b4hub
   ```

   `\du` must list `b4hub_owner` with `Create role`, and `\l` must show `b4hub` owned by it. Then `\q` and `exit`; the task stops. Clear the clipboard (`printf '' | pbcopy`).

   psql takes the raw password. The generated hex passwords are the same raw and inside a URL, so this never matters for them; if you used your own password with URL-reserved characters, the URL in step 5 holds it percent-encoded, and the form pasted here must be the decoded one. Decode the clipboard in place, so the password never reaches a command line: `pbpaste | python3 -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.unquote(sys.stdin.read()))' | pbcopy`.

5. **Put the two real URLs in the secrets.** `b4hub_owner` is `DATABASE_ADMIN_URL`; `b4hub_app` does not exist yet: the first `b4hub migrate` creates it and sets its password from the `DATABASE_URL` you give here. Back in the first terminal:

   ```bash
   DB_HOST=$(aws rds describe-db-instances --db-instance-identifier b4hub-$ENV \
     --query 'DBInstances[0].Endpoint.Address' --output text)
   TLS='sslmode=verify-full&sslrootcert=/etc/ssl/certs/rds-global-bundle.pem'
   umask 077; tmp=$(mktemp -d)
   printf 'postgres://b4hub_owner:%s@%s:5432/b4hub?%s' "$OWNER_PW" "$DB_HOST" "$TLS" > "$tmp/admin"
   printf 'postgres://b4hub_app:%s@%s:5432/b4hub?%s'   "$APP_PW"   "$DB_HOST" "$TLS" > "$tmp/app"
   aws secretsmanager put-secret-value --secret-id b4hub/database-admin-url --secret-string file://$tmp/admin > /dev/null
   aws secretsmanager put-secret-value --secret-id b4hub/database-url       --secret-string file://$tmp/app   > /dev/null
   rm -P "$tmp/admin" "$tmp/app"; rmdir "$tmp"      # Linux: shred -u
   unset OWNER_PW APP_PW
   ```

   Never put the master password in either URL: it rotates under RDS's management.

### 3. Set the sign-in secrets

Do this before the sign-in hub merges to `main`, because the deploy then adds these four secrets to the serving task and ECS will not start a task whose secret is empty.

1. `B4HUB_SECRET_KEY` (32 random bytes; it encrypts Apple refresh tokens at rest):

   ```bash
   umask 077; tmp=$(mktemp -d)
   openssl rand -base64 32 | tr -d '\n' > "$tmp/key"
   aws secretsmanager put-secret-value --secret-id b4hub/secret-key --secret-string file://$tmp/key > /dev/null
   rm -P "$tmp/key"
   ```

2. The three Apple values come from the Apple Developer portal, following the sign-in design's owner tasks: the Team ID (Membership details), and the Key ID and `.p8` private key of a key with Sign in with Apple enabled (Certificates, Identifiers & Profiles, Keys; the `.p8` downloads once). Keep the original at `~/.b4app/signing/AuthKey_<KeyID>.p8` with mode 600 (or in your password manager) so the second account can use it too; this step only ever copies it. The PEM goes in through `file://`, never pasted into a command:

   ```bash
   umask 077; tmp=$(mktemp -d)
   printf %s 'ABCDE12345' > "$tmp/team"      # your Team ID
   printf %s 'FGHIJ67890' > "$tmp/keyid"     # your Key ID
   cp ~/.b4app/signing/AuthKey_FGHIJ67890.p8 "$tmp/p8"
   aws secretsmanager put-secret-value --secret-id b4hub/apple-team-id     --secret-string file://$tmp/team  > /dev/null
   aws secretsmanager put-secret-value --secret-id b4hub/apple-key-id      --secret-string file://$tmp/keyid > /dev/null
   aws secretsmanager put-secret-value --secret-id b4hub/apple-private-key --secret-string file://$tmp/p8    > /dev/null
   rm -P "$tmp/team" "$tmp/keyid" "$tmp/p8"; rmdir "$tmp"      # the original stays in ~/.b4app/signing
   ```

3. Do both accounts (`ENV=test`, then `ENV=prod`; set `AWS_PROFILE=b4hub-$ENV` first). The Apple values are the same in both; `secret-key` is not: generate one per account.
4. In the pull request that merges the sign-in hub (its `serve` requires `B4HUB_SECRET_KEY` and `B4HUB_WEBAUTHN_RP_ID`), work through the checklist at the top of `Infra/taskdefs/features.env`. Not before: with `0` the deploy renders a task with `DATABASE_URL` only, which is what a hub without sign-in expects.
   - Set `INCLUDE_SIGNIN_SECRETS=1` in `Infra/taskdefs/features.env`. The deploy then adds the four secrets to the serving task, and `admin-shell.sh` adds them to the admin task's `hub` container (the gated block in `hub-admin.json.tpl`), so `b4hub seed|enroll` keep working. Both already set `B4HUB_WEBAUTHN_RP_ID`.
   - Compose: uncomment `B4HUB_SECRET_KEY` in `Hub/deploy/compose/.env.example`, pass it to `hub` in `compose.yaml` (a `secret_key` file with `B4HUB_SECRET_KEY_FILE` once the hub reads `_FILE` forms, M8e), and make `test.sh` generate one. `B4HUB_WEBAUTHN_RP_ID` is already required there.
   - Helm: uncomment the secret key in `Hub/chart/b4hub/ci/kind-values.yaml` and have the `install` job generate the key file it is set from.

### 4. First deploy

1. Runbook 2 (and 3, if the sign-in hub is on `main`) is done for `test`.
2. Merge to `main`. Watch `hub-image.yml` build and attest the image, which calls `hub-deploy.yml` for `test`:

   ```bash
   gh run watch "$(gh run list --workflow hub-image.yml --branch main --limit 1 --json databaseId --jq '.[0].databaseId')"
   gh run list --workflow hub-deploy.yml --limit 3
   ```

   The deploy job's log shows the migration task's last 200 lines; a failed migration stops the deploy before the service is touched.
3. The service still has `desired_count = 0`, so on this first deploy the migration runs and the new task definition is registered and set on the service, but there is no task to answer `/readyz`: the deploy skips that check and ends with a warning naming this step. Start the task by hand (Terraform ignores `desired_count` drift) and confirm:

   ```bash
   aws ecs update-service --cluster b4hub-test --service b4hub-test-hub --desired-count 1 > /dev/null
   aws ecs wait services-stable --cluster b4hub-test --services b4hub-test-hub
   curl -fsS https://hub.test.b4.run/readyz
   ```

4. Edit `desired_count = 0` to `1` in `envs/test/main.tf` and merge, so Terraform agrees (that apply also creates the `RunningTaskCount` alarm).
5. Production: runbook 2 for `prod`, then the first `hub-v*` release (or a dispatch from `main`, [runbook 5](#5-deploy-a-given-digest-or-roll-back)) with the `production` reviewer's approval; repeat 3 and 4 with `b4hub-prod`, `hub.b4.run`, and `envs/prod/main.tf`.

### 5. Deploy a given digest, or roll back

Rolling back is deploying an older digest: the same workflow, the same migration step. Migrations only move forward, so an older hub must tolerate the newer schema; check before rolling back past a migration.

1. **Find the digest.** Previously built images:

   ```bash
   gh api '/orgs/cacheplane/packages/container/b4hub/versions' --paginate \
     --jq '.[] | [.name, (.metadata.container.tags | join(",")), .created_at] | @tsv' | head -20
   ```

   What an environment runs right now is the service's current revision, not the family's latest: a deploy registers its revision before migrating, so a failed migration or a circuit-breaker rollback leaves a newer revision the service does not run. Read the service's revision, then its image (`<ecr>/b4hub@sha256:...`), and the revisions the family has had:

   ```bash
   RUNNING=$(aws ecs describe-services --cluster b4hub-$ENV --services b4hub-$ENV-hub \
     --query 'services[0].taskDefinition' --output text)
   aws ecs describe-task-definition --task-definition "$RUNNING" \
     --query "taskDefinition.containerDefinitions[?name=='hub'] | [0].image" --output text
   aws ecs list-task-definitions --family-prefix b4hub-$ENV-hub --sort DESC --max-items 20 \
     --query "taskDefinitionArns[?contains(@, ':task-definition/b4hub-$ENV-hub:')]" --output text
   aws ecs describe-task-definition --task-definition b4hub-$ENV-hub:<revision> \
     --query 'taskDefinition.containerDefinitions[0].image' --output text
   ```

2. **Dispatch.** Test deploys run from `main` only (the test deploy role trusts only that ref). Production runs from `main` or a `hub-v*` tag and waits for the `production` Environment's reviewer. Only a digest that `hub-image.yml` built and attested from `refs/heads/main` passes the attestation check.

   ```bash
   gh workflow run hub-deploy.yml --ref main -f environment=test -f digest=sha256:<64 hex>
   gh workflow run hub-deploy.yml --ref main -f environment=production -f digest=sha256:<64 hex>
   ```

3. Approve the production deployment (Actions, the run, Review deployments). The concurrency group is per environment and never cancels a running deploy; while one runs or waits for approval, a newer dispatch queues behind it, and a newer pending deploy **replaces** an older pending one, so only the latest queued digest runs. To roll back while a bad deploy is still waiting for approval, reject that one, then dispatch the old digest.
4. Confirm `curl -fsS https://hub.b4.run/readyz` (`hub.test.b4.run` for test), and read the deploy log for the migration output.

A push to `main` that changes only a task-definition template or the deploy scripts (`Infra/taskdefs/**`, `deploy.sh`, `render-taskdef.sh`, `run-migrate.sh`, `hub-deploy.yml`) also runs `hub-image.yml`, so it reaches `test` without a hub change: the image is rebuilt from the unchanged hub source at that commit and deployed with the new templates. Production picks the templates up on its next deploy.

### 6. Enroll a device before sign-in is live

Until the sign-in hub is deployed, a Mac joins a hosted hub with a one-time code from `b4hub enroll`. Run it through the `hub` container of the admin task, which has both database URLs. That container runs `b4hub serve` to stay alive, so it exits on a fresh account until `migrate` has run: do runbook 4 first. `admin-shell.sh` registers a new admin revision pinned to the ECR digest the service runs, so `b4hub` here is the deployed hub. Before the first deploy it falls back to Terraform's placeholder (`ghcr.io/cacheplane/b4hub:main`, which needs the package to be public) and warns.

1. Open the shell:

   ```bash
   export ENV=test AWS_PROFILE=b4hub-test AWS_REGION=us-east-2
   Infra/scripts/admin-shell.sh $ENV hub
   ```

2. First org and user, once (the values are yours):

   ```sh
   b4hub seed --org acme --org-name "Acme" --user brian --name "Brian" --email brian@example.com
   ```

3. Print a code and read it **from this terminal only**; it never goes into logs, chat, or a ticket:

   ```sh
   b4hub enroll --user brian
   ```

   (`--org <slug>` when more than one org exists.) Enter it on the Mac with `agent-workspace hub join` and the hub's URL, within the code's lifetime.
4. `exit`. The script stops the task.

### 7. Set or rotate a secret

1. Write the new value from a mode-0600 temp file, never the command line:

   ```bash
   umask 077; tmp=$(mktemp -d)
   # put the new value in $tmp/value (generated, or saved from your editor)
   aws secretsmanager put-secret-value --secret-id b4hub/<name> --secret-string file://$tmp/value > /dev/null
   rm -P "$tmp/value"; rmdir "$tmp"
   ```

   `<name>` is one of `database-admin-url`, `database-url`, `secret-key`, `apple-team-id`, `apple-key-id`, `apple-private-key`.
2. Tasks read secrets at start, so roll the service:

   ```bash
   aws ecs update-service --cluster b4hub-$ENV --service b4hub-$ENV-hub --force-new-deployment > /dev/null
   aws ecs wait services-stable --cluster b4hub-$ENV --services b4hub-$ENV-hub
   ```

   then `curl -fsS https://hub.b4.run/readyz` (`hub.test.b4.run` for test).
3. Per secret: a changed `database-url` password also needs the role's password changed, which `b4hub migrate` does from that URL, so dispatch a deploy of the current digest ([runbook 5](#5-deploy-a-given-digest-or-roll-back)) instead of only forcing a rollout. **`b4hub/secret-key` cannot be rotated** until the hub gains a re-encrypt command: it encrypts stored Apple refresh tokens, and a new key makes them unreadable. Apple's key is rotated in the developer portal: create the new key, set `apple-key-id` and `apple-private-key`, roll, then revoke the old one.

### 8. Restore drill (monthly)

Prove a backup restores and holds the data. Two parts: a full drill in the test account from its own backups, and a restorability check of production's cross-region copy. Record the date in `docs/verification.md`.

**A. Full drill in the test account** (the scratch instance is `b4hub-test-drill`, in the test VPC):

1. Pick the newest recovery point and prepare the restore metadata:

   ```bash
   export ENV=test AWS_PROFILE=b4hub-test AWS_REGION=us-east-2
   RP=$(aws backup list-recovery-points-by-backup-vault --backup-vault-name b4hub-test --by-resource-type RDS \
     --query 'sort_by(RecoveryPoints, &CreationDate)[-1].RecoveryPointArn' --output text)
   umask 077; tmp=$(mktemp -d)
   aws backup get-recovery-point-restore-metadata --backup-vault-name b4hub-test \
     --recovery-point-arn "$RP" --query RestoreMetadata > "$tmp/meta.json"
   jq '.DBInstanceIdentifier = "b4hub-test-drill" | .PubliclyAccessible = "false"' "$tmp/meta.json" > "$tmp/drill.json"
   ```

2. Restore and wait (about 15 minutes):

   ```bash
   ROLE=$(aws iam get-role --role-name b4hub-test-backup --query Role.Arn --output text)
   JOB=$(aws backup start-restore-job --recovery-point-arn "$RP" --iam-role-arn "$ROLE" \
     --resource-type RDS --metadata file://$tmp/drill.json --query RestoreJobId --output text)
   # The instance exists only once AWS Backup has created it, so poll the job first (add --region in B).
   while :; do
     STATUS=$(aws backup describe-restore-job --restore-job-id "$JOB" --query Status --output text)
     case "$STATUS" in
       COMPLETED) break ;;
       ABORTED | FAILED) break ;;
     esac
     sleep 30
   done
   SCRATCH=""
   if [ "$STATUS" = COMPLETED ]; then       # nothing below runs unless the restore completed
     DRILL_ARN=$(aws backup describe-restore-job --restore-job-id "$JOB" --query CreatedResourceArn --output text)
     DRILL_ID=${DRILL_ARN##*:}                # the DB instance identifier
     aws rds wait db-instance-available --db-instance-identifier "$DRILL_ID"
     SCRATCH=$(aws rds describe-db-instances --db-instance-identifier "$DRILL_ID" \
       --query 'DBInstances[0].Endpoint.Address' --output text)
   else
     echo "restore job $JOB ended $STATUS; stop here:" >&2
     aws backup describe-restore-job --restore-job-id "$JOB" --query StatusMessage --output text
   fi
   echo "scratch host: ${SCRATCH:-none}"
   ```

   If `SCRATCH` is empty, stop and fix the cause (the next step refuses to run without it). Nothing here exits your shell.

3. **Point the test hub at it.** Never put secrets in task overrides; use the secrets, in the test account only. Save the two current URLs, then write the same URLs with the host swapped (the snapshot holds the same roles and passwords):

   ```bash
   LIVE=$(aws rds describe-db-instances --db-instance-identifier b4hub-test --query 'DBInstances[0].Endpoint.Address' --output text)
   if [ -n "$SCRATCH" ] && [ "$SCRATCH" != None ] && [ -n "$LIVE" ] && [ "$LIVE" != None ]; then
     for s in database-admin-url database-url; do
       aws secretsmanager get-secret-value --secret-id b4hub/$s --query SecretString --output text > "$tmp/$s.orig"
       sed "s/@$LIVE:/@$SCRATCH:/" "$tmp/$s.orig" > "$tmp/$s.drill"
     done
     # write only if both swapped URLs really point at the scratch host
     if grep -q "@$SCRATCH:" "$tmp/database-admin-url.drill" && grep -q "@$SCRATCH:" "$tmp/database-url.drill"; then
       for s in database-admin-url database-url; do
         aws secretsmanager put-secret-value --secret-id b4hub/$s --secret-string file://$tmp/$s.drill > /dev/null
       done
     else
       echo "the saved URLs do not contain the live host; nothing written; stop" >&2
     fi
   else
     echo "no scratch or live host; nothing written; stop" >&2
   fi
   ```

   The originals stay in `$tmp/*.orig` for step 6.

   The two `put-secret-value` calls are not atomic. If the second one fails, `database-admin-url` already points at the scratch host and `database-url` still at the live one: put both back from the saved originals before anything else (the same loop as step 6, which is safe to rerun), then start step 3 again:

   ```bash
   for s in database-admin-url database-url; do
     aws secretsmanager put-secret-value --secret-id b4hub/$s --secret-string file://$tmp/$s.orig > /dev/null
   done
   ```

   No deploy has run yet at this point, so the hub never used the half-written pair. The same holds in step 6: if a restore call fails, rerun the loop until both succeed before deleting anything.

4. Run the normal deploy of the digest test already runs ([runbook 5](#5-deploy-a-given-digest-or-roll-back)): it migrates and serves against the scratch instance. `curl -fsS https://hub.test.b4.run/readyz` must pass.
5. **Compare.** In `Infra/scripts/admin-shell.sh test psql` run the same query against both instances. The container's `PGHOST` is the live one; the scratch host is `$SCRATCH` from step 2. psql needs the `b4hub_owner` password, which is only on your laptop. The container's environment carries `PGPASSWORD` (the master password), which psql would send for any user and fail, so `unset PGPASSWORD` first (in the container shell, once); psql then prompts. Never print the password: copy it to the clipboard without showing it, paste at each prompt (the paste is not echoed), then clear the clipboard:

   ```bash
   # on the laptop, in the shell that holds $tmp
   sed -n -E 's#^postgres(ql)?://b4hub_owner:([^@]*)@.*#\2#p' "$tmp/database-admin-url.orig" | tr -d '\n' | pbcopy
   ```

   ```sh
   unset PGPASSWORD                          # else psql sends the master password
   psql -h <live host> -U b4hub_owner -d b4hub -c 'select org_id, max(hub_seq) from changes group by 1 order by 1'
   psql -h <scratch host> -U b4hub_owner -d b4hub -c 'select org_id, max(hub_seq) from changes group by 1 order by 1'
   ```

   Then `printf '' | pbcopy` (Linux: `xclip`).

   The password comes out of the URL as stored. A generated hex password needs no decoding; one with percent-escapes (`%40` and so on) must be decoded before it is pasted at the psql prompt, or psql rejects it: run the clipboard through the same `pbpaste | python3 ... unquote ... | pbcopy` pipe as in [runbook 2](#2-bootstrap-the-database-owner) step 4.

   The restored `max(hub_seq)` per org must be less than or equal to the live one and no older than the backup interval.
6. **Put the test account back**, then delete the scratch instance:

   ```bash
   for s in database-admin-url database-url; do
     aws secretsmanager put-secret-value --secret-id b4hub/$s --secret-string file://$tmp/$s.orig > /dev/null
   done
   # dispatch a deploy of the current digest again (runbook 5), then wait for that run to
   # finish and `curl -fsS https://hub.test.b4.run/readyz` to pass: the hub must be off the
   # scratch instance before it is deleted. Only then:
   aws rds delete-db-instance --db-instance-identifier "$DRILL_ID" --skip-final-snapshot --delete-automated-backups
   rm -P "$tmp/database-admin-url.orig" "$tmp/database-admin-url.drill" "$tmp/database-url.orig" "$tmp/database-url.drill"
   rm -f "$tmp/meta.json" "$tmp/drill.json"; rmdir "$tmp"
   ```

**B. Production's cross-region copy** restores in `us-west-2` (run with `AWS_PROFILE=b4hub-prod`):

1. `aws backup list-recovery-points-by-backup-vault --region us-west-2 --backup-vault-name b4hub-prod-copy --by-resource-type RDS --query 'sort_by(RecoveryPoints, &CreationDate)[-1].[RecoveryPointArn,CreationDate,Status]'`. The newest must be under 36 hours old and `COMPLETED`.
2. Restore it with `aws backup start-restore-job --region us-west-2 ...` as in A.2, with the metadata from `aws backup get-recovery-point-restore-metadata --region us-west-2 --backup-vault-name b4hub-prod-copy --recovery-point-arn <arn>`, `DBInstanceIdentifier` set to `b4hub-prod-drill`, the role `b4hub-prod-backup`, and `DBSubnetGroupName` and `VpcSecurityGroupIds` set to the `default` ones of the region's default VPC (the stack has no network in `us-west-2`). Poll the restore job and read `CreatedResourceArn` as in A.2 (every `aws` call with `--region us-west-2`), wait with `aws rds wait db-instance-available --region us-west-2 --db-instance-identifier "$DRILL_ID"`, then delete it with `aws rds delete-db-instance --region us-west-2 --db-instance-identifier "$DRILL_ID" --skip-final-snapshot`.
3. Comparing production's `max(hub_seq)` against a restored copy of production needs the snapshot in an account with the hub's network. AWS cannot share a snapshot encrypted with the service default key (the copy vault's key) across accounts, so that comparison waits for the copy vault to use a customer managed key (a Terraform change, not made yet). Until then, B proves restorability only and A proves the data path.

### 9. Incident basics

First look: `https://hub.<env>.b4.run/readyz` (`hub.b4.run` for prod), then the Better Stack monitor, then the alarm email. Log groups are `/b4hub/<env>/hub` (serving), `/b4hub/<env>/migrate`, and `/b4hub/<env>/admin`.

| Alarm (`b4hub-<env>-...`) | Means | Check first |
| --- | --- | --- |
| `alb-5xx` | Five or more 5xx responses from the hub in five minutes | The hub log for `ERROR`; whether a deploy just ran |
| `unhealthy-hosts` | The target group has an unhealthy task for two minutes | `/readyz` (database or migrations not ready fails it) and the task's stopped reason in the ECS console |
| `latency-p99` | p99 above 2 seconds for ten minutes | The database CPU and connection alarms, then slow requests in the log |
| `running-tasks` | The service has no running task | `aws ecs describe-services` events; an image or secret that will not start; the circuit breaker may have rolled back |
| `rds-free-storage` | Under 2 GB free | Table sizes; the change log is pruned daily; storage autoscales to 100 GB |
| `rds-cpu` | CPU above 80 percent for fifteen minutes | RDS metrics; a runaway client in the hub log |
| `rds-connections` | More than 60 connections | A second hub process, a stuck migration task, or an admin task left running (stop it with the command `admin-shell.sh` printed) |

The EventBridge email `Migrate task ... stopped` arrives on every migrate run, clean or not; a non-zero exit code in it means a failed deploy (the workflow already stopped there). The monthly budget email means spend is over 150 percent of the budget.

Logs Insights, on `/b4hub/<env>/hub`:

```
fields @timestamp, @message
| filter level = "ERROR"
| sort @timestamp desc
| limit 50
```

Stop a runaway (the database is untouched; devices reconnect and resume from their cursors), then resume. The `running-tasks` alarm fires while it is stopped, since Terraform still says `desired_count = 1`:

```bash
aws ecs update-service --cluster b4hub-$ENV --service b4hub-$ENV-hub --desired-count 0
aws ecs update-service --cluster b4hub-$ENV --service b4hub-$ENV-hub --desired-count 1
```

Upstream status, each subscribed with the owner's email: Better Stack (the `/readyz` monitors and the status page at `status.b4.run`), the AWS Health Dashboard of each account, `githubstatus.com`, and Apple's developer system status (`developer.apple.com/system-status`).

### 10. The ALB was recreated

A new ALB has a new DNS name and, if the certificate was recreated, new validation records. Both live at Vercel, outside Terraform:

1. From the root, with the state backend initialized (see "Initialize a root by hand"): `terraform -chdir=Infra/envs/$ENV output -raw alb_dns_name` and `terraform -chdir=Infra/envs/$ENV output acm_validation_records`.
2. In the Vercel DNS for `b4.run`, re-point the CNAME `hub.test` (test) or `hub` (prod) at the new `alb_dns_name`, and re-add each validation CNAME from `acm_validation_records` (a certificate left unvalidated blocks the apply).
3. Wait for the certificate to be `ISSUED`, then `curl -fsS https://hub.<env>.b4.run/readyz`. Device sockets drop and resume from their cursors.

### 11. GHCR cleanup

`hub-ghcr-cleanup.yml` deletes old nightly and untagged images weekly, but only as a dry run until you opt in.

1. Run it once by hand as a dry run and read what it would delete:

   ```bash
   gh workflow run hub-ghcr-cleanup.yml -f dry-run=true
   gh run view "$(gh run list --workflow hub-ghcr-cleanup.yml --limit 1 --json databaseId --jq '.[0].databaseId')" --log
   ```

2. If the list is only what you expect (nothing tagged `latest`, `main`, `nightly`, or a release version, and no digest an environment runs), enable the scheduled sweep:

   ```bash
   gh variable set HUB_GHCR_CLEANUP_LIVE --body true
   ```

   `gh variable delete HUB_GHCR_CLEANUP_LIVE` returns it to dry runs.

### 12. Chart release

Each `hub-v*` release also publishes the Helm chart whose version is in `Hub/chart/b4hub/Chart.yaml` (with `appVersion` set to the release's hub version) to GHCR as an OCI chart. The chart version is not derived from the tag: it is whatever `Chart.yaml` says at the release commit, and publishing the same chart version twice fails. So in the release PR, bump `version` in `Hub/chart/b4hub/Chart.yaml` whenever anything under `Hub/chart/` changed since the last release.

A release is atomic: the image built from the release commit must be attested from `main`, then it gets the semver tags, then it deploys to production (with the `production` reviewer's approval), and only then is the chart published. A release cut from a `main` commit with no `sha-<sha>` image (a commit whose push did not touch `Hub/**` or the deploy files) fails in `promote`: dispatch `hub-image.yml` on `main` first (`gh workflow run hub-image.yml --ref main`; it builds `main`'s head, so do it while the release commit is still the head, and produces the `sha-` and `main` tags), then publish the release.

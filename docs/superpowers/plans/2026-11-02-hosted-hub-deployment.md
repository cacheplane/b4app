# Hosted Hub Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the hub at `hub.test.b4.run` (deployed on every merge to `main`) and `hub.b4.run` (deployed on every `hub-v*` release) on AWS from Terraform in this repository, and ship the same image as a Compose production profile and a Helm chart.

**Architecture:** One image from `Hub/Dockerfile`, built multi-arch in GitHub Actions and attested on GHCR. Terraform in `Infra/` creates, per AWS account, a VPC, an ALB with ACM and WAF, RDS for PostgreSQL 17, Secrets Manager secrets, three ECS task definitions (`hub`, `hub-migrate`, `hub-admin`) and one Fargate service, AWS Backup, and CloudWatch alarms. A reusable deploy workflow copies the digest into ECR, runs the migration task, updates the service, and smoke-checks `/readyz`. `Hub/deploy/compose/` and `Hub/chart/b4hub/` package the same image for self-hosting.

**Tech Stack:** Rust 1.93.1 hub (unchanged), Docker Buildx with cargo-chef, GitHub Actions (OIDC to AWS), Terraform ≥ 1.10 with the `hashicorp/aws` provider, AWS ECS Fargate, ALB, RDS, Secrets Manager, WAF, AWS Backup, CloudWatch; Docker Compose spec; Helm 4 with helm-unittest, chart-testing, kubeconform, cosign.

**Spec:** `docs/deployment-architecture.md` (D-068 to D-072). Executors read it with this plan. Hub-side contract: `docs/superpowers/specs/2026-11-01-sign-in-design.md`, "The hosted hubs (a separate project)".

## Global Constraints

- The hub binary does not change in this plan except `Hub/Dockerfile`. No AWS SDK, no cloud-specific code path, no new env var. The image's `ENTRYPOINT` stays `["/usr/local/bin/b4hub"]`, `CMD ["serve"]`, user `10001:10001`, `EXPOSE 8080`.
- Environments: `test` (account `b4hub-test`, `https://hub.test.b4.run`) and `prod` (account `b4hub-prod`, `https://hub.b4.run`), region `us-east-2`, second region later `us-west-2`.
- Hub env in the serving task: `B4HUB_PORT=8080`, `B4HUB_PUBLIC_URL=https://hub[.test].b4.run`, `B4HUB_SIGNUP=open`, `B4HUB_WEBAUTHN_RP_ID=b4.run|test.b4.run`, `B4HUB_APPLE_AUDIENCES=com.cacheplane.b4app.ios,com.cacheplane.b4app.signin`, `B4HUB_APPLE_SERVICES_ID=com.cacheplane.b4app.signin` (plain env, added by the sign-in project on 2026-11-02; Task 10 adds it to `hub.json.tpl`), `B4HUB_TRUST_X_FORWARDED_FOR=1`, `B4HUB_RETENTION_DAYS=30`, `B4HUB_LOG=info`. Never `B4HUB_APPLE_BASE_URL`.
- Secrets Manager secrets per account, names exactly: `b4hub/database-admin-url`, `b4hub/database-url`, `b4hub/secret-key`, `b4hub/apple-team-id`, `b4hub/apple-key-id`, `b4hub/apple-private-key`. The `hub` task gets the last five; `hub-migrate` gets the first two; `hub-admin` gets only `database-admin-url`. The first deployments (before the sign-in branch merges) register `hub` with only `database-url`; see Task 10. Once sign-in merges, `serve` refuses to start without `B4HUB_SECRET_KEY` and `B4HUB_WEBAUTHN_RP_ID`, so the owner fills `b4hub/secret-key` in both accounts before that merge (the rp id is already in the template's environment).
- Database URLs end in `?sslmode=verify-full&sslrootcert=/etc/ssl/certs/rds-global-bundle.pem`. `DATABASE_ADMIN_URL` is the `b4hub_owner` role, never the RDS master.
- Timing: ALB idle timeout 120 s; ECS `stopTimeout` 60; target group health check `GET /readyz` every 10 s, healthy 2, unhealthy 3; deployment `minimum_healthy_percent = 0`, `maximum_percent = 100`, circuit breaker with rollback; `desired_count = 1`.
- No long-lived AWS credential anywhere: every workflow uses `aws-actions/configure-aws-credentials` with `role-to-assume` and `permissions: id-token: write`. No secret value in Terraform code, Terraform state, workflow files, or logs.
- Release tags are `hub-v<semver>`; the first is `hub-v0.1.0`. `mac-v*` releases must never trigger a hub job.
- Image tags from `docker/metadata-action`: `sha-<full sha>` always; `main` on pushes to main; `nightly` and `nightly-{{date 'YYYYMMDD'}}` on schedule; `{{version}}`, `{{major}}.{{minor}}`, `{{major}}`, `latest` from `hub-v` tags only.
- Every GitHub Action is pinned to a full commit SHA with a version comment. Every Terraform provider version is pinned exactly in `Infra/**/versions.tf` and locked in `.terraform.lock.hcl`.
- Terraform: `terraform fmt -check`, `terraform validate`, and `tflint` pass for every root; `terraform test` passes for the module.
- Repository rules hold: secrets never appear in arguments, results, or logs; `docs/decisions.md`, `docs/compatibility.md`, `docs/verification.md`, `docs/milestones.md` are kept current.

## Review Focus

1. A `mac-v1.2.3` release is published: no hub workflow may run a deploy. Pinned by Task 3's workflow guard test and Task 10's `if:` guard.
2. The ECS service is created before CI has ever deployed: the placeholder task definition must start a task that passes `/readyz` or the service must be created with `desired_count = 0` until first deploy. Pinned in Task 8 (`desired_count` variable, default 0 until Task 10's first deploy flips it to 1).
3. A migration fails in the one-off task: the deploy must stop and the old task definition must keep serving; the workflow must not call `update-service`. Pinned in Task 10's deploy script test (non-zero exit short-circuits).
4. The Apple PEM and the admin URL contain `&`, `=`, newlines, and `%`: secrets must pass through `put-secret-value --secret-string file://` and ECS `valueFrom` untouched; the taskdef renderer must never interpolate secret values. Pinned in Task 10's render test (renderer only sees ARNs).
5. A push body up to 32 MiB with SQL-looking text reaches WAF: it must pass. Pinned in Task 6's `terraform test` asserting the web ACL has exactly two rules and no managed rule group, and in Task 16's live gate 2b (a 9 MiB push through the test hub).

---

## Part A: image and build pipeline

### Task 1: cargo-chef layering and the RDS CA bundle in `Hub/Dockerfile`

**Files:**
- Modify: `Hub/Dockerfile`
- Create: `Hub/scripts/check-image.sh`
- Modify: `docs/compatibility.md` (cargo-chef version, RDS bundle date)

**Interfaces:**
- Produces: an image with `/etc/ssl/certs/rds-global-bundle.pem` present, `ca-certificates` installed (no OpenSSL: the hub links rustls and webauthn-rs uses RustCrypto), same `ENTRYPOINT`/`CMD`/user as today; `Hub/scripts/check-image.sh <image-ref>` exits 0 when those hold.

- [ ] **Step 1: Write the failing check script**

```sh
#!/bin/sh
# Hub/scripts/check-image.sh <image>: asserts the runtime image's contract (D-070).
set -eu
img="$1"
docker run --rm --entrypoint /bin/sh "$img" -c '
  test -s /etc/ssl/certs/rds-global-bundle.pem &&
  test "$(id -u)" = 10001 &&
  test -x /usr/local/bin/b4hub &&
  ! ldconfig -p | grep -q libssl.so &&
  grep -c "BEGIN CERTIFICATE" /etc/ssl/certs/rds-global-bundle.pem | awk "{exit !(\$1 > 50)}"
'
docker inspect "$img" --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' \
  | grep -qx '\["/usr/local/bin/b4hub"\] \["serve"\]'
```

- [ ] **Step 2: Run it against the current image to verify it fails**

Run: `cd Hub && docker build -t b4hub:check . && ./scripts/check-image.sh b4hub:check`
Expected: non-zero exit (no RDS bundle).

- [ ] **Step 3: Rewrite the builder stage with cargo-chef**

In `Hub/Dockerfile`: a `chef` stage `FROM rust@<same digest> AS chef` that `cargo install cargo-chef --locked --version <pin>` (record the pin in `docs/compatibility.md`); a `planner` stage copying `Cargo.toml Cargo.lock crates` and running `cargo chef prepare --recipe-path recipe.json`; a `builder` stage that copies `recipe.json`, runs `cargo chef cook --release --locked --recipe-path recipe.json`, then copies the sources and runs the existing `cargo build --release --locked --offline --bin b4hub`. Keep "rust-toolchain.toml is deliberately not copied".

- [ ] **Step 4: Extend the runtime stage**

Leave the `apt-get install` list as it is (`ca-certificates curl`). Add a stage `FROM debian@<digest> AS rdsca` that `apt-get install --no-install-recommends --yes ca-certificates curl` and `curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o /rds-global-bundle.pem`, then `COPY --from=rdsca --chmod=0444 /rds-global-bundle.pem /etc/ssl/certs/rds-global-bundle.pem` into the runtime stage. Add a comment: the bundle is fetched at build time so the image has no network dependency at run time, and the deploy's attestation covers it.

- [ ] **Step 5: Build and run the check**

Run: `cd Hub && docker build -t b4hub:check . && ./scripts/check-image.sh b4hub:check && echo OK`
Expected: `OK`. Then `docker build -t b4hub:check .` a second time after `touch crates/b4hub/src/main.rs` and confirm the `cargo chef cook` layer is `CACHED` in the output.

- [ ] **Step 6: Commit**

```bash
git add Hub/Dockerfile Hub/scripts/check-image.sh docs/compatibility.md
git commit -m "build(hub): cargo-chef layering and the RDS CA bundle in the image"
```

### Task 2: `hub-image.yml`: multi-arch build, tags, attestations, GHCR cleanup

**Files:**
- Create: `.github/workflows/hub-image.yml`
- Create: `.github/workflows/hub-ghcr-cleanup.yml`
- Create: `.github/actionlint.yaml` (if absent) and add `actionlint` to Task 3's CI step
- Modify: `README.md` ("Hub (optional)": where the image lives)

**Interfaces:**
- Produces: workflow `hub-image.yml` with `workflow_call` outputs `digest` (the index digest `sha256:…`) and `image` (`ghcr.io/cacheplane/b4hub`); triggers `push: branches: [main]` with `paths: [Hub/**, .github/workflows/hub-image.yml]`, `schedule: cron '17 3 * * *'`, `workflow_dispatch`, and `workflow_call`. Task 10 calls it.

- [ ] **Step 1: Write the actionlint check as the failing test**

Run: `actionlint .github/workflows/hub-image.yml`
Expected: FAIL, file not found.

- [ ] **Step 2: Write the workflow**

Jobs:
- `build` (matrix `platform: [linux/amd64, linux/arm64]` on `ubuntu-24.04` and `ubuntu-24.04-arm` respectively, `permissions: contents: read, packages: write, id-token: write, attestations: write`): checkout; `docker/setup-buildx-action`; `docker/login-action` to `ghcr.io` with `GITHUB_TOKEN`; `docker/build-push-action` with `context: Hub`, `platforms: ${{ matrix.platform }}`, `push: true`, `outputs: type=image,name=ghcr.io/cacheplane/b4hub,push-by-digest=true,name-canonical=true`, `cache-from: type=gha,scope=hub-${{ matrix.platform }}`, `cache-to: type=gha,mode=max,scope=hub-${{ matrix.platform }}`, `provenance: mode=max`, `sbom: true`; export the digest as an artifact `digests-<platform>`.
- `merge` (needs `build`): download digests; `docker/metadata-action` with `images: ghcr.io/cacheplane/b4hub` and the tag rules from Global Constraints (`type=sha,format=long,prefix=sha-`, `type=ref,event=branch`, `type=schedule,pattern=nightly`, `type=schedule,pattern=nightly-{{date 'YYYYMMDD'}}`, `type=match,pattern=hub-v(.*),group=1`, plus `type=match,pattern=hub-v(\d+\.\d+),group=1`, `type=match,pattern=hub-v(\d+),group=1`, `type=raw,value=latest,enable=${{ startsWith(github.ref, 'refs/tags/hub-v') }}`); `docker buildx imagetools create` with the tags and the two digests; `docker buildx imagetools inspect` to capture the index digest into `outputs.digest`; `actions/attest-build-provenance` with `subject-name: ghcr.io/cacheplane/b4hub`, `subject-digest: ${{ digest }}`, `push-to-registry: true`.
- `check` (needs `merge`): `Hub/scripts/check-image.sh ghcr.io/cacheplane/b4hub@${{ digest }}`.
- Nightly skip: a first job `changed` that compares `github.sha` with the `org.opencontainers.image.revision` label of `ghcr.io/cacheplane/b4hub:nightly` (via `docker buildx imagetools inspect --format '{{json .}}'`) and sets `skip=true` when equal and the previous nightly run concluded `success` (`gh run list --workflow hub-image.yml --event schedule --limit 1 --json conclusion`); all other jobs `if: needs.changed.outputs.skip != 'true'`.
- Concurrency: `group: hub-image-${{ github.ref }}`, `cancel-in-progress: false`.

- [ ] **Step 3: Write the cleanup workflow**

`hub-ghcr-cleanup.yml`: `schedule: cron '41 4 * * 1'` and `workflow_dispatch`; one job using `dataaxiom/ghcr-cleanup-action` with `package: b4hub`, `keep-n-tagged: 30`, `exclude-tags: 'latest,main,nightly,^[0-9]+(\.[0-9]+){0,2}$'`, `delete-untagged: true`, `older-than: 14 days` for `nightly-*` via a second step with `tags: 'nightly-*'` and `keep-n-tagged: 14`. `permissions: packages: write`.

- [ ] **Step 4: Lint**

Run: `actionlint .github/workflows/hub-image.yml .github/workflows/hub-ghcr-cleanup.yml`
Expected: no output, exit 0.

- [ ] **Step 5: Dry-run on the branch**

Push the branch; `gh workflow run hub-image.yml --ref <branch>`; wait; `gh run watch`. Expected: three jobs green; `docker buildx imagetools inspect ghcr.io/cacheplane/b4hub:sha-<sha>` lists both platforms; `gh attestation verify oci://ghcr.io/cacheplane/b4hub@<digest> -R cacheplane/b4app` prints a verified result. (The GHCR package must be made public once by the owner in the package settings; the README step says so.)

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/hub-image.yml .github/workflows/hub-ghcr-cleanup.yml README.md
git commit -m "ci(hub): build, attest, and publish the multi-arch hub image to GHCR"
```

### Task 3: release trigger and CI guards

**Files:**
- Create: `.github/workflows/hub-release.yml`
- Modify: `.github/workflows/ci.yml` (add `actionlint`, `shellcheck`, and Terraform lint steps as later tasks add files)
- Create: `.github/scripts/test-tag-guard.sh`

**Interfaces:**
- Produces: `hub-release.yml` on `release: types: [published]`, job-level `if: startsWith(github.event.release.tag_name, 'hub-v')`, which (a) resolves the release commit's `sha-<sha>` image digest from GHCR and fails with "no built image for <sha>; release from a commit on main whose build finished" when absent, (b) calls `hub-image.yml`'s tag-only path to add the semver tags to that digest (`imagetools create --tag … ghcr.io/cacheplane/b4hub@<digest>`), and (c) calls `hub-deploy.yml` (Task 10) with `environment: production` and the digest. Also a `lint` job in `ci.yml` running `actionlint` and `shellcheck` on `.github/scripts/*.sh Hub/scripts/*.sh Infra/scripts/*.sh`.

- [ ] **Step 1: Write the tag-guard test**

`.github/scripts/test-tag-guard.sh`: for each of `hub-v0.1.0 → run`, `hub-v10.2.3-rc1 → run`, `mac-v1.0.0 → skip`, `v1.0.0 → skip`, `hubv1 → skip`, evaluate the same expression the workflow uses, extracted into `.github/scripts/is-hub-release.sh <tag>` (exit 0 for hub releases), and assert. Run it: expected FAIL (script missing).

- [ ] **Step 2: Write `is-hub-release.sh`** (`case "$1" in hub-v[0-9]*) exit 0;; *) exit 1;; esac`) and the workflow; the workflow's job `if:` is `startsWith(github.event.release.tag_name, 'hub-v')` and its first step runs `is-hub-release.sh` again so the guard is tested code.

- [ ] **Step 3: Run the guard test and actionlint**

Run: `.github/scripts/test-tag-guard.sh && actionlint`
Expected: `ok` lines for the five cases; actionlint silent.

- [ ] **Step 4: Add the `lint` job to `ci.yml`** (`ubuntu-latest`, `actionlint` via `rhysd/actionlint` pinned, `shellcheck` from apt, runs the tag-guard test).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/hub-release.yml .github/workflows/ci.yml .github/scripts
git commit -m "ci(hub): production release trigger guarded to hub-v tags; actionlint and shellcheck"
```

## Part B: Terraform

### Task 4: `Infra/bootstrap`: state bucket, OIDC provider, three roles

**Files:**
- Create: `Infra/bootstrap/{versions.tf,variables.tf,main.tf,roles.tf,outputs.tf}`
- Create: `Infra/bootstrap/tests/roles.tftest.hcl`
- Create: `Infra/.terraform-version` (`1.14.x`, the current release at build time; record in `docs/compatibility.md`)
- Create: `Infra/.tflint.hcl`
- Create: `Infra/README.md` (bootstrap runbook section)

**Interfaces:**
- Consumes: variables `environment` (`test`|`prod`), `github_repository` (`cacheplane/b4app`), `region` (`us-east-2`).
- Produces: outputs `state_bucket` (`b4hub-<env>-tfstate`), `plan_role_arn`, `infra_role_arn`, `deploy_role_arn`; OIDC provider `token.actions.githubusercontent.com`. Trust subjects: plan `repo:cacheplane/b4app:*`; infra and deploy for test `repo:cacheplane/b4app:ref:refs/heads/main`, for prod `repo:cacheplane/b4app:environment:production`. Infra role: `AdministratorAccess` with permissions boundary `b4hub-<env>-boundary` denying `iam:CreateUser`, `iam:CreateAccessKey`, `iam:CreateLoginProfile`, `organizations:*`, and `account:*`. Deploy role policy: `ecs:RegisterTaskDefinition`, `ecs:DescribeTaskDefinition`, `ecs:RunTask`, `ecs:DescribeTasks`, `ecs:UpdateService`, `ecs:DescribeServices` scoped to cluster `b4hub-<env>`; `iam:PassRole` on `b4hub-<env>-task-exec` and `b4hub-<env>-task`; `ecr:*` push and pull on repository `b4hub`; `logs:GetLogEvents` on `/b4hub/<env>/*`; `ecr:GetAuthorizationToken`.

- [ ] **Step 1: Write the failing `terraform test`**

`tests/roles.tftest.hcl` with `mock_provider "aws" {}`, `run "prod_trust_is_environment_scoped"` (`variables { environment = "prod" }`, `command = plan`) asserting `jsondecode(aws_iam_role.infra.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:cacheplane/b4app:environment:production"`; `run "test_trust_is_main_branch"` asserting `…:ref:refs/heads/main`; `run "deploy_role_has_no_admin"` asserting no managed policy attachment of `AdministratorAccess` on the deploy role; `run "boundary_denies_iam_users"` asserting the boundary document contains `iam:CreateAccessKey`.

- [ ] **Step 2: Run to verify it fails**

Run: `cd Infra/bootstrap && terraform init -backend=false && terraform test`
Expected: FAIL, resources not defined.

- [ ] **Step 3: Write the resources** (`aws_s3_bucket` with versioning, SSE-KMS, public access block; `aws_iam_openid_connect_provider`; the boundary policy; three roles with the trust documents above; policies). Backend block for the bootstrap root itself is local (documented).

- [ ] **Step 4: Run fmt, validate, tflint, test**

Run: `terraform fmt -check -recursive Infra && cd Infra/bootstrap && terraform validate && tflint && terraform test`
Expected: all pass.

- [ ] **Step 5: Write the bootstrap runbook in `Infra/README.md`**: create the Organization and the two member accounts, enable IAM Identity Center with one `AdministratorAccess` permission set and MFA, `aws sso login`, `terraform apply` in `Infra/bootstrap` per account with `-var environment=…`, then record the role ARNs as repository variables `AWS_ROLE_PLAN_<ENV>`, `AWS_ROLE_INFRA_<ENV>`, `AWS_ROLE_DEPLOY_<ENV>` (not secrets; ARNs are not sensitive), and move the bootstrap state into the bucket (`terraform init -migrate-state` with the backend block added after first apply).

- [ ] **Step 6: Commit**

```bash
git add Infra/bootstrap Infra/.terraform-version Infra/.tflint.hcl Infra/README.md docs/compatibility.md
git commit -m "infra: bootstrap root with state bucket, GitHub OIDC provider, and plan/infra/deploy roles"
```

### Task 5: `Infra/modules/hub`: network

**Files:**
- Create: `Infra/modules/hub/{versions.tf,variables.tf,network.tf,outputs.tf,locals.tf}`
- Create: `Infra/modules/hub/tests/network.tftest.hcl`

**Interfaces:**
- Consumes: module variables defined here and used by every later task: `environment`, `region`, `hostname` (`hub.b4.run`), `private_tasks` (bool, default `false`), `task_count` (number, default `1`), `desired_count` (default `0`, see Review Focus 2), `db_instance_class` (default `db.t4g.micro`), `db_multi_az` (default `false`), `db_backup_retention_days` (default `7`), `backup_copy_region` (string, default `null`), `log_retention_days` (default `30`), `alarm_email`.
- Produces: `aws_vpc.this` (10.<env-octet>.0.0/16, test 10.10, prod 10.20), two public and two private subnets across `a` and `b`, an internet gateway, a route table per tier, an S3 gateway endpoint, NAT gateway and private routes only when `private_tasks`; security groups `alb` (443 and 80 in from `0.0.0.0/0`), `task` (8080 in from `alb`; out 443 anywhere and 5432 to `db`), `db` (5432 in from `task` and `admin`), `admin` (out 5432 to `db`, out 443). Outputs: `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `sg_alb_id`, `sg_task_id`, `sg_db_id`, `sg_admin_id`.

- [ ] **Step 1: Write the failing test**: `run "no_nat_by_default"` asserting `length(aws_nat_gateway.this) == 0`; `run "nat_when_private"` with `private_tasks = true` asserting `== 1`; `run "task_sg_only_from_alb"` asserting the task ingress rule's `referenced_security_group_id == aws_security_group.alb.id` and `from_port == 8080`; `run "db_has_no_public_ingress"` asserting no `cidr_ipv4` on db ingress rules.

- [ ] **Step 2: Run to verify it fails.** `cd Infra/modules/hub && terraform init -backend=false && terraform test` → FAIL.

- [ ] **Step 3: Write `network.tf`** using `aws_vpc_security_group_ingress_rule`/`egress_rule` resources (not inline rules) so the tests can address them.

- [ ] **Step 4: fmt, validate, tflint, test** → pass.

- [ ] **Step 5: Commit** `git commit -m "infra(hub): VPC, subnets, optional NAT, and security groups"`.

### Task 6: `Infra/modules/hub`: ALB, ACM, WAF

**Files:**
- Create: `Infra/modules/hub/{alb.tf,acm.tf,waf.tf}`
- Create: `Infra/modules/hub/tests/edge.tftest.hcl`

**Interfaces:**
- Produces: `aws_lb.this` (application, `idle_timeout = 120`, access logs to bucket `b4hub-<env>-alb-logs` with a 30-day lifecycle, `drop_invalid_header_fields = true`), `aws_lb_target_group.hub` (`target_type = "ip"`, port 8080, health check `/readyz`, interval 10, healthy 2, unhealthy 3, `deregistration_delay = 60`), listener 443 with `ssl_policy = "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"` (variable `alb_ssl_policy`), listener 80 → 301 to HTTPS, `aws_acm_certificate.hub` for `var.hostname` with `validation_method = "DNS"`, `aws_wafv2_web_acl.hub` with exactly two rules (`rate` — `rate_based_statement { limit = 2000, aggregate_key_type = "IP" }`, action block — and `AWSManagedRulesAmazonIpReputationList`), associated to the ALB. Outputs: `alb_dns_name`, `acm_validation_records` (list of `{name, type, value}` for the owner to add at Vercel), `target_group_arn`.

- [ ] **Step 1: Write the failing test**: `run "waf_has_two_rules_and_no_body_rules"` asserting `length(aws_wafv2_web_acl.hub.rule) == 2` and no rule's `managed_rule_group_statement[0].name` equals `AWSManagedRulesCommonRuleSet`; `run "idle_timeout_120"`; `run "health_check_readyz"` asserting path `/readyz`, interval 10; `run "http_redirects"` asserting the 80 listener default action type `redirect` with `status_code = "HTTP_301"`.

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Write the resources.** ACM validation record outputs only; no Route 53.

- [ ] **Step 4: fmt, validate, tflint, test** → pass.

- [ ] **Step 5: Commit** `git commit -m "infra(hub): ALB with ACM certificate, HTTPS redirect, and a two-rule WAF"`.

### Task 7: `Infra/modules/hub`: RDS, secrets, AWS Backup

**Files:**
- Create: `Infra/modules/hub/{rds.tf,secrets.tf,backup.tf}`
- Create: `Infra/modules/hub/tests/data.tftest.hcl`

**Interfaces:**
- Produces: `aws_db_subnet_group` on private subnets; `aws_db_instance.hub` (engine `postgres`, `engine_version = "17"` with `auto_minor_version_upgrade = true`, `instance_class = var.db_instance_class`, `multi_az = var.db_multi_az`, `allocated_storage = 20`, `max_allocated_storage = 100`, `storage_type = "gp3"`, `storage_encrypted = true`, `kms_key_id` = account key `aws_kms_key.this`, `manage_master_user_password = true`, `username = "b4hub_master"`, `db_name = null` (the `b4hub` database is created at bootstrap by `hub-admin`), `backup_retention_period = var.db_backup_retention_days`, `deletion_protection = var.environment == "prod"`, `apply_immediately = false`, `publicly_accessible = false`, `vpc_security_group_ids = [sg_db]`, `performance_insights_enabled = true`); six `aws_secretsmanager_secret` with the exact names in Global Constraints, `kms_key_id` the account key, no `aws_secretsmanager_secret_version` resources (values are set by the owner; a `lifecycle` comment explains); `aws_backup_vault.hub`, `aws_backup_plan.hub` (daily at 06:00 UTC, retention 35 days, `copy_action` to a vault in `var.backup_copy_region` when set, which requires a second provider alias `aws.copy` passed by the root), `aws_backup_selection` of the RDS ARN. Outputs: `db_endpoint`, `db_master_secret_arn`, `secret_arns` (map name → ARN), `kms_key_arn`.

- [ ] **Step 1: Write the failing test**: `run "no_secret_values_in_terraform"` asserting the module declares zero `aws_secretsmanager_secret_version` resources (use a `check` against a local that lists them, or assert on a known-absent address via `can()`); `run "rds_private_encrypted"` asserting `publicly_accessible == false`, `storage_encrypted == true`, `manage_master_user_password == true`; `run "prod_deletion_protection"` with `environment = "prod"`; `run "copy_action_only_with_region"` asserting `length(aws_backup_plan.hub.rule[0].copy_action) == 0` by default and `== 1` with `backup_copy_region = "us-west-2"`.

- [ ] **Step 2: Run to verify it fails.** **Step 3: Write the resources.** **Step 4: fmt, validate, tflint, test → pass.**

- [ ] **Step 5: Commit** `git commit -m "infra(hub): RDS PostgreSQL 17, empty Secrets Manager secrets, and AWS Backup with cross-region copy"`.

### Task 8: `Infra/modules/hub`: ECR, IAM, log group, ECS cluster, task definitions, service

**Files:**
- Create: `Infra/modules/hub/{ecr.tf,iam.tf,ecs.tf}`
- Create: `Infra/taskdefs/{hub.json.tpl,hub-migrate.json.tpl,hub-admin.json.tpl}` (shared by Terraform's placeholder registration and Task 10's renderer)
- Create: `Infra/modules/hub/tests/ecs.tftest.hcl`

**Interfaces:**
- Consumes: `target_group_arn`, `secret_arns`, subnets and security groups from Tasks 5 to 7.
- Produces: `aws_ecr_repository.hub` (`b4hub`, `image_tag_mutability = "IMMUTABLE"`, scan on push); `aws_cloudwatch_log_group` `/b4hub/<env>/hub`, `/b4hub/<env>/migrate`, `/b4hub/<env>/admin` with `var.log_retention_days`; roles `b4hub-<env>-task-exec` (pull from ECR, `secretsmanager:GetSecretValue` on the six secret ARNs, `kms:Decrypt` on the key, write the three log groups) and `b4hub-<env>-task` (empty policy; `ssmmessages:*` only when `var.environment` admin exec is on, scoped to the admin task definition family via a condition); `aws_ecs_cluster.hub` (`b4hub-<env>`, `containerInsights = "enhanced"`); three `aws_ecs_task_definition` registered from the templates with `templatefile()` and a placeholder image (`public.ecr.aws/docker/library/busybox:stable` running `sleep 3600` is **not** used; the placeholder is `ghcr.io/cacheplane/b4hub:main` with the serving command, so a `desired_count = 0` service can be created and the first deploy replaces it) — families `b4hub-<env>-hub`, `b4hub-<env>-hub-migrate`, `b4hub-<env>-hub-admin`, all `FARGATE`, `cpu 256`, `memory 512`, `runtimePlatform { cpuArchitecture = "ARM64", operatingSystemFamily = "LINUX" }`, `stopTimeout 60`, `readonlyRootFilesystem true` with a `tmpfs` at `/tmp`; `aws_ecs_service.hub` (`desired_count = var.desired_count`, `launch_type FARGATE`, `network_configuration` on public subnets with `assign_public_ip = !var.private_tasks` or private subnets when `private_tasks`, `deployment_minimum_healthy_percent = var.task_count > 1 ? 100 : 0`, `deployment_maximum_percent = var.task_count > 1 ? 200 : 100`, `deployment_circuit_breaker { enable = true, rollback = true }`, `health_check_grace_period_seconds = 60`, `lifecycle { ignore_changes = [task_definition, desired_count] }`), `enable_execute_command = true` on the admin task's `aws_ecs_task_definition` is a task-level property; the admin task is run ad hoc, not as a service. Outputs: `cluster_name`, `service_name`, `ecr_repository_url`, `task_exec_role_arn`, `task_role_arn`, `taskdef_families`.

Template contract (`hub.json.tpl` variables): `image`, `region`, `log_group`, `environment_name`, `public_url`, `rp_id`, `secret_arns` (map), `include_signin_secrets` (bool). The template emits `environment` from Global Constraints and `secrets` entries `{ "name": "DATABASE_URL", "valueFrom": "<arn>" }` plus, when `include_signin_secrets`, the four `B4HUB_*` secret entries. `hub-migrate.json.tpl`: `command ["migrate"]`, secrets `DATABASE_ADMIN_URL` and `DATABASE_URL`. `hub-admin.json.tpl`: two containers. `hub`: the hub image, command `["sleep", "infinity"]` is not available (the image has no shell entrypoint), so the container runs `b4hub serve` with `DATABASE_ADMIN_URL` as its only secret and the operator uses `execute-command` to run `b4hub seed|enroll` inside it; `psql`: `public.ecr.aws/docker/library/postgres:17`, `essential: false`, command `["sleep", "3600"]`, env `PGHOST`, `PGUSER=b4hub_master`, `PGSSLMODE=verify-full`, `PGSSLROOTCERT` pointing at the bundle (mounted from the `hub` container via a shared volume, or fetched by the template's documented alternative), and `PGPASSWORD` from `valueFrom: <rds master secret arn>:password::`, present in no other task definition. Both containers `linuxParameters.initProcessEnabled = true` for ECS Exec. Variables: `image`, `psql_image`, `region`, `log_group`, `secret_arns`, `db_master_secret_arn`, `db_host`.

- [ ] **Step 1: Write the failing test**: `run "single_task_recreate"` asserting `deployment_minimum_healthy_percent == 0 && deployment_maximum_percent == 100` with default `task_count`; `run "two_tasks_rolling"` with `task_count = 2` asserting `100 && 200`; `run "serve_has_no_admin_url"` asserting `jsondecode(aws_ecs_task_definition.hub.container_definitions)[0].secrets[*].name` does not contain `DATABASE_ADMIN_URL`; `run "migrate_has_only_two_secrets"`; `run "admin_hub_container_has_only_admin_url"`; `run "master_secret_only_in_admin_psql"` asserting the RDS master secret ARN appears in no container of `hub` or `hub-migrate` and only in the `psql` container of `hub-admin`; `run "container_counts"` (hub 1, migrate 1, admin 2); `run "stop_timeout_60"`; `run "exec_role_reads_only_known_secrets"` asserting the policy's resources equal the six ARNs.

- [ ] **Step 2: Run to verify it fails.** **Step 3: Write templates and resources.** **Step 4: fmt, validate, tflint, test → pass.**

- [ ] **Step 5: Commit** `git commit -m "infra(hub): ECR, task roles, ECS cluster, hub/migrate/admin task definitions, and the service"`.

### Task 9: `Infra/modules/hub` observability; `Infra/envs/{test,prod}`; `infra.yml`

**Files:**
- Create: `Infra/modules/hub/observability.tf`, `tests/alarms.tftest.hcl`
- Create: `Infra/envs/test/{main.tf,backend.tf,versions.tf}`, `Infra/envs/prod/{…}`
- Create: `.github/workflows/infra.yml`
- Modify: `Infra/README.md` (what each env sets; how to read a plan comment)

**Interfaces:**
- Produces: `aws_sns_topic.alerts` with an email subscription to `var.alarm_email` (confirmed by the owner once); alarms exactly: ALB `HTTPCode_Target_5XX_Count` sum ≥ 5 over 300 s; `UnHealthyHostCount` max > 0 for 2 of 2 periods of 60 s; `TargetResponseTime` p99 > 2 s for 10 periods of 60 s; ECS `RunningTaskCount` (Container Insights) < 1 for 2 periods of 60 s, enabled only when `var.desired_count > 0`; RDS `FreeStorageSpace` < 2 GiB; `CPUUtilization` > 80 for 15 min; `DatabaseConnections` > 60; an EventBridge rule on `ECS Task State Change` for the migrate family with `stopCode != EssentialContainerExited || exitCode != 0` → the topic; `aws_budgets_budget` monthly at `var.monthly_budget_usd` (test 70, prod 80) with a 150 % actual-spend notification. Roots: test `hostname = "hub.test.b4.run"`, `db_backup_retention_days = 7`, no copy region; prod `hostname = "hub.b4.run"`, `db_backup_retention_days = 14`, `backup_copy_region = "us-west-2"`, `log_retention_days = 90`; both `desired_count = 0` until Task 10's first deploy, after which the root is edited to `1` (noted in the runbook). Backend `s3` with `bucket = "b4hub-<env>-tfstate"`, `key = "hub.tfstate"`, `use_lockfile = true`, `encrypt = true`.

`infra.yml`: `pull_request` on `paths: [Infra/**]` → job `plan` matrix over `[test, prod]` assuming `AWS_ROLE_PLAN_<ENV>`, running `fmt -check`, `validate`, `tflint`, `terraform test` (module), `terraform plan -no-color -out plan.bin` and posting the plan with a pinned plan-comment action; `push: branches: [main]` with the same paths → `apply-test` (role `AWS_ROLE_INFRA_TEST`, `environment: test`) then `apply-prod` (`environment: production`, role `AWS_ROLE_INFRA_PROD`, `needs: apply-test`). `concurrency: group: infra-<env>, cancel-in-progress: false`.

- [ ] **Step 1: Write the failing alarm test**: `run "alarm_count"` asserting exactly 7 `aws_cloudwatch_metric_alarm` resources; `run "running_task_alarm_off_when_zero"` asserting `aws_cloudwatch_metric_alarm.running_tasks[0].actions_enabled == false` (or count 0) with default `desired_count`.

- [ ] **Step 2: Run to verify it fails.** **Step 3: Write observability, roots, and the workflow.**

- [ ] **Step 4: Verify**: `terraform fmt -check -recursive Infra`; for each root `terraform init -backend=false && terraform validate && tflint`; module `terraform test`; `actionlint .github/workflows/infra.yml`. Expected: all pass.

- [ ] **Step 5: Owner steps before the first real plan** (write them in `Infra/README.md`, then the owner performs them): bootstrap both accounts (Task 4 runbook); add the three role ARNs per env as repository variables; create GitHub Environments `test` (no rules) and `production` (required reviewer: the owner; deployment branches and tags: `main` and `hub-v*`); make the GHCR package public.

- [ ] **Step 6: First plan and apply**: open the PR; confirm two plan comments; merge; confirm `apply-test` succeeds and `apply-prod` waits for approval, approve. Then the owner adds at Vercel: the ACM validation CNAMEs from the `acm_validation_records` output for both environments and `hub.test.b4.run` / `hub.b4.run` CNAMEs to the `alb_dns_name` outputs; the next `apply` completes certificate validation (document that the first apply may wait on validation; use `aws_acm_certificate_validation` with a `timeouts` block of 60 m).

- [ ] **Step 7: Commit** (before step 6) `git commit -m "infra(hub): alarms and budgets, the test and prod roots, and the plan/apply workflow"`.

## Part C: deploy

### Task 10: `hub-deploy.yml` and its scripts

**Files:**
- Create: `.github/workflows/hub-deploy.yml` (`workflow_call` inputs `environment`, `digest`; `workflow_dispatch` inputs `environment`, `digest` for rollback)
- Create: `Infra/scripts/{render-taskdef.sh,run-migrate.sh,deploy.sh}` and `Infra/scripts/tests/{render.bats,deploy.bats}` (bats-core, installed in the `lint` job)
- Modify: `.github/workflows/hub-image.yml` (after `check` on `push` to `main`: call `hub-deploy.yml` with `environment: test`)
- Modify: `.github/workflows/hub-release.yml` (call with `environment: production`)
- Modify: `Infra/envs/{test,prod}/main.tf` → `desired_count = 1` after the first successful deploy

**Interfaces:**
- `render-taskdef.sh <template> <out.json> --image <ref> --region … --log-group … --env-name … --public-url … --rp-id … --secret <NAME>=<ARN> …` renders `Infra/taskdefs/*.json.tpl` with `envsubst`-free `jq --arg` substitution (templates are JSON with `${var}` placeholders replaced only in string values); it exits 2 if any placeholder remains and never accepts a `--secret-value`.
- `run-migrate.sh <cluster> <taskdef-arn> <subnets> <sg> <log-group>`: `aws ecs run-task`, `aws ecs wait tasks-stopped`, print the log tail, exit with the container's exit code.
- `deploy.sh <env> <digest>`: copy `ghcr.io/cacheplane/b4hub@<digest>` to `<ecr>/b4hub:<sha256 hex>` with `docker buildx imagetools create`; render and register `hub-migrate` and `hub`; `run-migrate.sh`; on 0, `aws ecs update-service --task-definition <new> --force-new-deployment`, `aws ecs wait services-stable`; `curl -fsS https://<hostname>/readyz | jq -e '.minClientProtocol >= 1'`. Any non-zero step exits without calling `update-service` (set `-euo pipefail`; the test asserts).
- Workflow: `permissions: id-token: write, contents: read, packages: read`; steps: checkout, `configure-aws-credentials` with `AWS_ROLE_DEPLOY_<ENV>`, `gh attestation verify oci://ghcr.io/cacheplane/b4hub@<digest> -R cacheplane/b4app`, `docker/login-action` for GHCR and `aws ecr get-login-password`, `Infra/scripts/deploy.sh`. `environment: ${{ inputs.environment == 'production' && 'production' || 'test' }}` with `url: https://hub[.test].b4.run`. `concurrency: group: deploy-${{ inputs.environment }}, cancel-in-progress: false`. The `include_signin_secrets` flag is read from `Infra/taskdefs/features.env` (`INCLUDE_SIGNIN_SECRETS=0`), which the sign-in branch flips to `1` when it merges.

- [ ] **Step 1: Write failing bats tests**: `render.bats`: renders `hub.json.tpl` with `INCLUDE_SIGNIN_SECRETS=0` and asserts `secrets | length == 1`; with `1` asserts `== 5` and names; asserts an unknown placeholder exits 2; asserts a value containing `&=%\n` passed as `--secret NAME=arn:…` appears byte-identical as the ARN (secrets are ARNs only). `deploy.bats`: with stubbed `aws` and `docker` on `PATH` recording calls, a migrate exit code 1 results in no `update-service` call and exit 1; exit 0 results in `update-service` then `wait services-stable` then the curl.

- [ ] **Step 2: Run to verify they fail.** Run: `bats Infra/scripts/tests` → FAIL.

- [ ] **Step 3: Write the three scripts and the workflow.** **Step 4: Run bats, shellcheck, actionlint → pass.**

- [ ] **Step 5: First deploy to test**: merge; watch `hub-image.yml` → `hub-deploy.yml (test)`; expected: migrate task log shows `0001_tenancy` to `0003_organisation` applied (the owner must first set `b4hub/database-admin-url` and `b4hub/database-url` in the test account and run the `hub-admin` bootstrap SQL from the runbook; see Task 15); service stable; `curl https://hub.test.b4.run/readyz` returns 200 with `minClientProtocol`. Then set `desired_count = 1` in both roots and merge (plan shows only the alarm toggles since the service ignores `desired_count`).

- [ ] **Step 6: Commit** `git commit -m "ci(hub): deploy by digest: ECR copy, migration task, service update, readiness check"`.

## Part D: Compose production profile

### Task 11: `Hub/deploy/compose`

**Files:**
- Create: `Hub/deploy/compose/{compose.yaml,Caddyfile,README.md,.env.example,secrets/.gitkeep}`
- Create: `Hub/deploy/compose/test.sh`
- Modify: `.github/workflows/hub-image.yml` (job `compose-smoke` after `check`, `needs: merge`)
- Modify: `README.md` ("Hub (optional)": link to self-hosting docs)

**Interfaces:**
- `compose.yaml`: services `db` (`postgres:17`, named volume `b4hub-db`, healthcheck `pg_isready -U postgres -d b4hub`, `restart: unless-stopped`, `POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password`), `migrate` (`image: ghcr.io/cacheplane/b4hub:${B4HUB_VERSION:?set B4HUB_VERSION in .env}`, `command: ["migrate"]`, `restart: "no"`, `depends_on: db: condition: service_healthy`, `DATABASE_ADMIN_URL_FILE: /run/secrets/database_admin_url`, `DATABASE_URL_FILE: /run/secrets/database_url`), `hub` (`command: ["serve"]`, `init: true`, `stop_grace_period: 40s`, `restart: unless-stopped`, `depends_on: migrate: condition: service_completed_successfully`, `DATABASE_URL_FILE`, env from `.env`: `B4HUB_PUBLIC_URL`, `B4HUB_WEBAUTHN_RP_ID`, `B4HUB_SIGNUP`, `B4HUB_TRUST_X_FORWARDED_FOR=1`; `expose: ["8080"]`, no `ports`), `caddy` (profile `tls`, `caddy:2`, ports 80/443, volumes for `caddy_data` and `caddy_config`, `CADDY_HOSTNAME` env; Caddyfile: `{$CADDY_HOSTNAME} { reverse_proxy hub:8080 }`), top-level `secrets:` with `file:` sources under `./secrets/`. A profile `local` adds `ports: ["127.0.0.1:8080:8080"]` on `hub` for operators without TLS.
- `test.sh <image-ref>`: writes temp secrets, `B4HUB_VERSION` from the ref, `docker compose --profile local up -d --wait`, `curl -fsS localhost:8080/readyz`, asserts `migrate` exited 0 (`docker compose ps -a --format json`), asserts `hub`'s environment has no `DATABASE_ADMIN_URL*` (`docker compose exec hub env`), `docker compose down -v`.

- [ ] **Step 1: Write `test.sh` first and run it** → FAIL (no compose file).
- [ ] **Step 2: Write `compose.yaml`, `Caddyfile`, `.env.example`, `README.md`** (install, secrets, first run, upgrade `docker compose pull && docker compose run --rm migrate && docker compose up -d`, backup `docker compose exec db pg_dump -Fc -U postgres b4hub > …`, the appending-proxy note, pinning the Postgres major).
- [ ] **Step 3: `docker compose -f Hub/deploy/compose/compose.yaml config -q` and `Hub/deploy/compose/test.sh b4hub:check`** → pass.
- [ ] **Step 4: Add `compose-smoke` to `hub-image.yml`** running `test.sh ghcr.io/cacheplane/b4hub@${{ digest }}`.
- [ ] **Step 5: Commit** `git commit -m "hub: Compose production profile with file secrets, migrate gate, and optional Caddy TLS"`.

## Part E: Helm chart

### Task 12: chart skeleton, Deployment, Service, secrets, migration hook

**Files:**
- Create: `Hub/chart/b4hub/{Chart.yaml,values.yaml,values.schema.json,README.md.gotmpl,.helmignore}`
- Create: `Hub/chart/b4hub/templates/{_helpers.tpl,deployment.yaml,service.yaml,serviceaccount.yaml,secret.yaml,migrate-job.yaml,NOTES.txt}`
- Create: `Hub/chart/b4hub/tests/{deployment_test.yaml,migrate_test.yaml,secrets_test.yaml}` (helm-unittest)
- Create: `Hub/chart/b4hub/ci/{default-values.yaml,existing-secret-values.yaml}`

**Interfaces (values contract, used by Tasks 13 and 14):**
- `image.repository` (`ghcr.io/cacheplane/b4hub`), `image.tag` (default `.Chart.AppVersion`), `image.digest` (optional, wins over tag), `image.pullPolicy`, `global.imageRegistry` (prefix override).
- `replicaCount: 1`; `strategy.type: Recreate`; `terminationGracePeriodSeconds: 45`; `preStopSleepSeconds: 5`.
- `database.existingSecret` (required unless `database.urls` set), `database.secretKeys.url` (`DATABASE_URL`), `database.secretKeys.adminUrl` (`DATABASE_ADMIN_URL`).
- `hub.publicUrl`, `hub.rpId`, `hub.signup` (`closed`), `hub.trustXForwardedFor: true`, `hub.retentionDays: 30`, `hub.log: info`, `hub.extraEnv: []`.
- `secrets.existingSecret` or `secrets.values.{secretKey, appleTeamId, appleKeyId, applePrivateKey}` → mounted at `/etc/b4hub/secrets/<key>` and exposed as `B4HUB_*_FILE` env (until M8e adds those `_FILE` forms to the hub, the chart also sets the plain `B4HUB_*` vars from `valueFrom.secretKeyRef`; a values flag `secrets.useFileVars: false` switches, documented).
- `migrate.enabled: true`, `migrate.activeDeadlineSeconds: 600`, hook annotations as the spec fixes (`pre-install,pre-upgrade`, weight `-5`, delete policy `before-hook-creation,hook-succeeded`), `backoffLimit: 0`; the Job mounts only the admin-URL key.
- `podSecurityContext`/`securityContext` defaults: Restricted PSS (`runAsNonRoot`, `runAsUser: 10001`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault`, `readOnlyRootFilesystem: true`) with an `emptyDir` at `/tmp`.
- Probes: readiness `GET /readyz`, liveness `GET /healthz`, port `http` 8080.
- `resources` defaults `requests: {cpu: 100m, memory: 128Mi}`, `limits: {memory: 512Mi}`.

- [ ] **Step 1: Write failing helm-unittest tests**: Deployment has `strategy.type == Recreate` by default and `RollingUpdate` when `replicaCount: 2` only if `strategy.type` is set so (assert the default stays `Recreate` and a NOTES warning renders when `replicaCount > 1`); container env has no `DATABASE_ADMIN_URL`; securityContext matches Restricted; migrate Job annotations exact; Job env has exactly `DATABASE_ADMIN_URL` and `DATABASE_URL`; `existingSecret` path renders no `Secret`; `values` path renders one with `stringData` keys; `image.digest` renders `repo@sha256:…`.
- [ ] **Step 2: Run** `helm unittest Hub/chart/b4hub` → FAIL.
- [ ] **Step 3: Write Chart.yaml (`apiVersion: v2`, `version: 0.1.0`, `appVersion: "0.1.0"`, `kubeVersion: ">=1.29.0"`), values, schema, templates.**
- [ ] **Step 4: Verify**: `helm lint --strict Hub/chart/b4hub -f Hub/chart/b4hub/ci/default-values.yaml && helm unittest Hub/chart/b4hub && helm template t Hub/chart/b4hub -f ci/default-values.yaml | kubeconform -strict -summary` → pass.
- [ ] **Step 5: Commit** `git commit -m "chart(b4hub): Deployment, Service, secrets contract, and the pre-upgrade migration Job"`.

### Task 13: Ingress, HTTPRoute, ServiceMonitor, OTLP passthrough, CNPG example, README

**Files:**
- Create: `templates/{ingress.yaml,httproute.yaml,servicemonitor.yaml}`, `examples/cnpg-cluster.yaml`, `tests/networking_test.yaml`
- Modify: `values.yaml`, `values.schema.json`, `README.md.gotmpl`

**Interfaces:** `ingress.enabled`, `ingress.className`, `ingress.annotations` (free-form), `ingress.host`, `ingress.tls[]`; `httpRoute.enabled`, `httpRoute.parentRefs[]`, `httpRoute.hostnames[]`, no `timeouts` unless `httpRoute.timeouts` set; `serviceMonitor.enabled` renders only `if and .Values.serviceMonitor.enabled (.Capabilities.APIVersions.Has "monitoring.coreos.com/v1")`; `otel.endpoint` → `OTEL_EXPORTER_OTLP_ENDPOINT` plus `otel.extraEnv`. `examples/cnpg-cluster.yaml`: a `postgresql.cnpg.io/v1 Cluster` (1 instance, PG 17 image) plus a documented `kubectl` one-liner that builds the `b4hub-db` Secret with `DATABASE_URL` and `DATABASE_ADMIN_URL` from CNPG's generated app and superuser secrets (mark the CNPG secret names as to be confirmed against the CNPG docs at build time, per the research gap).

- [ ] **Step 1: Failing tests**: Ingress absent by default; present with host when enabled; HTTPRoute renders without `timeouts` by default; ServiceMonitor absent when the API is missing (helm-unittest `capabilities.apiVersions`). **Step 2: Run → FAIL.** **Step 3: Write.** **Step 4: lint, unittest, kubeconform (with the Gateway API CRD schemas via `-schema-location`) → pass; `helm-docs` regenerates `README.md` with no diff after commit.**
- [ ] **Step 5: Commit** `git commit -m "chart(b4hub): Ingress, Gateway API HTTPRoute, ServiceMonitor, OTLP passthrough, CNPG example"`.

### Task 14: chart CI, kind install test, OCI publish with cosign

**Files:**
- Create: `.github/workflows/hub-chart.yml`
- Create: `Hub/chart/ct.yaml`, `Hub/chart/b4hub/ci/kind-values.yaml`
- Modify: `.github/workflows/hub-release.yml` (call the chart publish job on `hub-v*` releases)

**Interfaces:** `hub-chart.yml` on `pull_request` paths `Hub/chart/**` and `workflow_call`: jobs `lint` (`ct lint --config Hub/chart/ct.yaml`, `helm unittest`, `kubeconform`, `helm-docs --dry-run` diff check), `install` (kind via `helm/kind-action`; install CloudNativePG operator from its official chart; apply `examples/cnpg-cluster.yaml`; build the db Secret; `helm install b4hub Hub/chart/b4hub -f ci/kind-values.yaml --set image.digest=<digest from hub-image or :main> --wait --timeout 5m`; assert the hook Job completed and `kubectl run curl … /readyz` returns 200; `helm upgrade` once more and assert a second Job ran), `publish` (`workflow_call` only, `permissions: packages: write, id-token: write`): `helm package`, `helm push oci://ghcr.io/cacheplane/charts`, `cosign sign --yes ghcr.io/cacheplane/charts/b4hub@<digest>`; chart `version` is taken from `Chart.yaml` and must be bumped in the release PR (the `lint` job fails if `Chart.yaml` `version` already exists in the OCI registry: `helm show chart oci://… --version <v>` succeeding is the failure condition).

- [ ] **Step 1: Write `ct.yaml` and the workflow; run `actionlint`** → pass.
- [ ] **Step 2: Open the PR and watch `install`**: expected green with the hook Job `Completed` and `/readyz` 200. Fix until it is.
- [ ] **Step 3: Commit** `git commit -m "ci(chart): lint, kind install with CloudNativePG, and signed OCI publish on hub releases"`.

## Part F: runbooks, verification, docs

### Task 15: `Infra/README.md` runbooks and the bootstrap SQL

**Files:**
- Modify: `Infra/README.md`
- Create: `Infra/scripts/admin-shell.sh <env>` (`aws ecs run-task` for `hub-admin` then `aws ecs execute-command --interactive --command /bin/sh`, and `stop-task` on exit) and `Infra/sql/bootstrap-owner.sql`

**Interfaces:** `admin-shell.sh <env> [hub|psql]` opens an interactive shell in the named container of a freshly started `hub-admin` task (Task 8: container `hub` is the hub image for `b4hub seed|enroll`; container `psql` is `public.ecr.aws/docker/library/postgres:17` for the bootstrap SQL) and stops the task on exit. `bootstrap-owner.sql`, run once per account from the `psql` container: `CREATE ROLE b4hub_owner WITH LOGIN CREATEROLE PASSWORD '<generated>'; CREATE DATABASE b4hub OWNER b4hub_owner;`.

- [ ] **Step 1: Write runbooks**: bootstrap an account; bootstrap the database owner and set `b4hub/database-admin-url` and `b4hub/database-url` (`b4hub_app` password generated by the owner and placed in the URL; `migrate` sets it on the role); set the Apple secrets (from the sign-in design's owner tasks); first deploy; set or rotate a secret; deploy a given digest and roll back (`gh workflow run hub-deploy.yml -f environment=… -f digest=…`); `enroll` through the admin shell; restore drill (restore the copied snapshot in `us-west-2` to a scratch instance via the console or CLI, point a scratch `migrate`+`serve` at it, compare `select org_id, max(hub_seq) from changes group by 1`); incident basics (alarm meanings, log groups, `aws ecs update-service --desired-count 0` to stop a runaway); Vercel records to re-add if an ALB is recreated.
- [ ] **Step 2: shellcheck `admin-shell.sh`; commit** `git commit -m "infra: runbooks, admin shell, and the database owner bootstrap"`.

### Task 16: live gates and documentation

**Files:**
- Modify: `docs/verification.md` (new section "Hosted hubs" with gates 1 to 8 from the spec), `docs/milestones.md` (status lines), `docs/compatibility.md` (Terraform, provider, Helm, cargo-chef, kind, CNPG versions), `README.md`.

- [ ] **Step 1: Run the spec's gates and record each with date and evidence**: (1) bootstrap and plan/apply from CI; (2) merge → test hub serves the digest within 15 minutes; (2b) a 9 MiB `POST /v1/changes` from the Mac client against the test hub is accepted (WAF, Review Focus 5); (3) `hub-v0.1.0` release deploys production after approval and a `mac-v*` release runs no hub job; (4) sign-in and relay live gates against `hub.test.b4.run` are owned by those projects, record "pending" with a pointer; (5) deploy during an open WebSocket: phone reconnects, cursor unchanged (needs M8c; record pending if not merged); (6) `aws ecs stop-task` by hand: alarm, Better Stack page, replacement task; (7) restore drill once; (8) `Hub/deploy/compose/test.sh` on a clean VM and the kind install job.
- [ ] **Step 2: Owner's external setup, recorded as done**: Better Stack monitors for both `/readyz` URLs with phone escalation and the status page at `status.b4.run` (Vercel CNAME); SNS email confirmation; AWS Health Dashboard and GitHub/Apple status subscriptions.
- [ ] **Step 3: Commit** `git commit -m "docs: hosted hub verification gates, compatibility versions, milestone status"`.

---

## Self-review notes

- Spec coverage: every section of `docs/deployment-architecture.md` maps to a task (shape → 4 to 9; IaC → 4, 9; network → 5; compute → 8, 10; routing → 6; data → 7, 15; security → 4, 6, 7, 8; build and release → 1 to 3, 10; observability → 9, 16; availability tiers → module variables in 5, 7, 8 with "next"/"later" values documented in 15's runbook; runbooks → 15; Compose → 11; Helm → 12 to 14; asks of the hub → not this plan (M8e and sign-in); costs → budgets in 9; gates → 16). PR previews are explicitly not built at the "now" tier (spec), so no task.
- Type consistency: variable names (`private_tasks`, `task_count`, `desired_count`, `db_multi_az`, `backup_copy_region`, `log_retention_days`), secret names, task definition families, role names, and script names are used identically across Tasks 4 to 10 and 15.
- Proportion: the plan is shorter than the Terraform and workflow code it describes; code appears only for the two shell test contracts the implementer could not infer.

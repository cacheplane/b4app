# Handoff: hosted hub operations (b4.run on AWS)

Written 2026-11-04 by the session that designed and shipped the hosted hubs. This is the state of the world for a new thread that continues the work. Everything below was verified from the CLI or GitHub at the time of writing unless marked otherwise. Owner: Brian Love (GitHub `blove`, email brian@cacheplane.ai).

## 1. What exists and is live

| Thing | Value |
| --- | --- |
| AWS Organization | `o-63b985q63d`, management account `091823298178` ("cacheplane Management Account"), Identity Center org instance `ssoins-722355799abd8ada` in `us-east-1` (Builder ID identity source, no permission sets; access is through IAM **account access manager**). Other members: `threadplane` `655503101324` (another product), "cacheplane Identity Delegated Admin" `895757147641`. |
| OU | `b4run` = `ou-nrev-p1ta3hem`, under the root `r-nrev`. |
| Hub accounts | `b4hub-test` = `355069727528` (brian+b4hub-test@cacheplane.ai), `b4hub-prod` = `268895852483` (brian+b4hub-prod@cacheplane.ai). Both created by Organizations, so each has `OrganizationAccountAccessRole`. |
| Region | `us-east-2` for everything; `us-west-2` only for prod's backup copy vault (and its drill). |
| Test hub | `https://hub.test.b4.run`, two tasks (since PR #102), deploys on every merge to `main` that touches `Hub/` (image digest copied GHCR → ECR). Currently no enrolled device (the owner's Mac moved to prod). |
| Prod hub | `https://hub.b4.run`, two tasks, deploys on a published `hub-v*` release after the owner's approval in the `production` GitHub Environment. Releases so far: `hub-v0.1.0` (first, 2026-11-02), `0.2.0`, `0.3.0`, `0.4.0`, `0.5.0` (2026-11-04). The owner's Mac is enrolled here as `blove@cacheplane`. |
| Terraform state | `s3://b4hub-test-tfstate` and `s3://b4hub-prod-tfstate`, keys `bootstrap.tfstate` and `hub.tfstate`, SSE-KMS with the state key (test `d9c975b5-6ea7-4610-99ae-7020f3091262`, prod `496dd803-4674-4422-b959-3e74e44043bd`, both `us-east-2`). Native S3 lockfile. |
| CI roles | `b4hub-<env>-{plan,infra,deploy}`; trust policies pin GitHub's **immutable** OIDC subject `repo:cacheplane@269322961/b4app@1440075505:...` (variables `github_owner_id`, `github_repository_id` in `Infra/bootstrap/`). |
| Repository variables | `AWS_ROLE_{PLAN,INFRA,DEPLOY}_{TEST,PROD}`, `TFSTATE_KMS_KEY_ARN_{TEST,PROD}`, `B4HUB_ALARM_EMAIL=brian@cacheplane.ai`, `HUB_GHCR_CLEANUP_LIVE=true`. |
| GitHub Environment | `production`: required reviewer `blove`, deployment branches/tags `main` and `hub-v*`. Test jobs declare no Environment (the test roles trust `ref:refs/heads/main`). |
| GHCR | `ghcr.io/cacheplane/b4hub` is **public** (org package policy had to allow public packages); tags `main`, `sha-<commit>`, `latest`, semver. Chart at `oci://ghcr.io/cacheplane/charts/b4hub` (0.2.0 at first release; later versions since). Weekly cleanup is live. |
| DNS (Vercel, team `cacheplane`) | CNAMEs `hub.test` → `b4hub-test-1755545331.us-east-2.elb.amazonaws.com`, `hub` → `b4hub-prod-1818187724.us-east-2.elb.amazonaws.com`, two ACM validation CNAMEs, and **seven CAA records on the apex** (`letsencrypt.org`, `sectigo.com`, `pki.goog`, `amazon.com`, `amazontrust.com`, `awstrust.com`, `amazonaws.com`). CAA cannot sit on `hub`/`hub.test` because a CNAME cannot share its name with other records. CLI: `vercel dns ls b4.run --scope cacheplane`. |
| Alarms | SNS topics `b4hub-<env>-alerts`; the email subscription is **confirmed in both accounts** (prod confirmed 2026-11-04). The `running-tasks` alarm needs a gap of two one-minute periods to fire (so rolling deploys never page). |
| Secrets Manager (both accounts) | `b4hub/database-admin-url`, `database-url`, `secret-key`, `apple-team-id` (`GJJKL34HCT`), `apple-key-id` (`V9BJVV23LA`), `apple-private-key` (the `.p8` from `~/.b4app/signing/AuthKey_V9BJVV23LA.p8`). All set with real values in both accounts. |
| Organization region SCP | `AdvancedModeRegionRestrictionSecurityControlPolicy` (`p-hwoqi7b3`, customer-editable, attached at the root). It denies most services outside `us-east-2`. The `us-west-2` statement's exception list now also contains `backup:*`, `backup-storage:*`, `kms:*`, `rds:*`, `ec2:*`, `iam:PassRole` (added 2026-11-02 and 2026-11-04 at the owner's direction, for the backup copy and the restore drill). The pre-change policy is saved at `~/.b4app/aws-org/AdvancedModeRegionRestrictionSecurityControlPolicy.before-2026-11-02.json`. |

## 2. How to get a CLI session (the part that bites every ~12 hours)

No long-lived keys exist anywhere (D-069). `~/.aws/config` has:

- `cacheplane-mgmt`: a `login_session` profile written by `aws login` (management account, `AccountFullAccessRole`).
- `b4hub-test-role` / `b4hub-prod-role`: `role_arn = arn:aws:iam::<acct>:role/OrganizationAccountAccessRole`, `source_profile = cacheplane-mgmt`.
- `b4hub-test` / `b4hub-prod`: `credential_process = /opt/homebrew/bin/aws configure export-credentials --profile b4hub-<env>-role --format process`. **Use these** for both the CLI and Terraform (`AWS_PROFILE=b4hub-test`); Terraform cannot read `login_session` profiles directly.

The AWS CLI is Homebrew's 2.39.x at `/opt/homebrew/bin/aws`. The old Intel `.pkg` CLI (2.4.13) still sits under `/usr/local/aws-cli` behind it on `PATH`; the owner wants it removed (`sudo rm -rf /usr/local/aws-cli; sudo rm -f /usr/local/bin/aws /usr/local/bin/aws_completer`), which needs his sudo.

When commands fail with "Your session has expired", renew like this (the browser pane is the desktop app's built-in browser; the owner must do the sign-in step):

1. The owner signs in at the Identity Center portal `https://ssoins-722355799abd8ada.us-east-1.portal.amazonaws.com` with his Builder ID (MFA is on). A portal session alone is **not** enough for `aws login`.
2. Open the portal's Applications tab → "AWS account access" (direct link: `https://ssoins-722355799abd8ada.us-east-1.portal.amazonaws.com/#/saml/default/AWS%20account%20access/ins-7223ad41c9d9dc41`; it redirects to `https://aa-jryw1y7fx.account-access.us-east-1.app.aws/`). Expand "cacheplane Management Account" and open the console with `managed/AccountFullAccessRole` (`/console?account=091823298178&role=managed/AccountFullAccessRole`). That creates the console session the CLI attaches to.
3. Run `aws login --profile cacheplane-mgmt --remote` (stdin from a FIFO works; the process prints an authorize URL and waits for a code). Open that URL in the browser; it now lists the active session `AccountFullAccessRole/...`; click it; the confirmation page shows the code (click "Show the full verification code"; the code is also the long base64 string on the page). Paste the code to the waiting process. Then `aws sts get-caller-identity --profile b4hub-test` and `--profile b4hub-prod` must answer.
4. Set `AWS_PAGER=""` in scripted calls; the CLI's pager has hung commands in this session.

The portal popup cannot be opened by automation clicks; navigate to the link's `href` instead. Popups and clicks from automation are blocked; keyboard sign-in is the owner's job.

## 3. In flight right now (continue this first)

**PR #122 `blove/copy-vault-cmk`, "customer managed key on the cross-region copy vault"**, auto-merge armed, merged with `main` once already (README conflict resolved: main's runbook 8 B.2 text + this PR's B.3 text). What it does: `Infra/modules/hub/backup.tf` adds `aws_kms_key.copy` + `aws_kms_alias.copy` (`alias/b4hub-prod-copy`, provider `aws.copy`, rotating, 30-day deletion window), sets `kms_key_arn` on `aws_backup_vault.copy`, and `force_destroy = true` on that vault. Tests: the five `tests/*.tftest.hcl` files' `aws.copy` mock gained a `mock_resource "aws_kms_key"` ARN; `data.tftest.hcl` asserts the key/alias/vault wiring and `force_destroy`. 52 module tests pass; `tflint` and `terraform fmt` clean.

Prod plan: 3 to add (key, alias, new vault), 1 to change (backup plan), 1 to destroy (old vault). **The old vault is destroyed with its stored `force_destroy = false`, so it must hold no recovery points when the apply runs**, or the destroy fails. A background watcher in the old session was waiting for the merge, then for the `apply-prod` job of `infra.yml` to reach its `production` approval gate, and would then delete every recovery point in `b4hub-prod-copy` (`aws backup delete-recovery-point --region us-west-2 --backup-vault-name b4hub-prod-copy --recovery-point-arn <arn>`; the source vault keeps its own copies 35 days). That watcher dies with the old session. In the new thread:

1. Check the PR state: `gh pr view 122 --repo cacheplane/b4app --json state,mergeStateStatus`. If `DIRTY` again, merge `origin/main` into the branch and resolve (keep both sides' intent) and push; auto-merge stays armed.
2. After it merges, find the infra run for the merge commit (`gh run list --workflow infra.yml --branch main`), wait until `gh api repos/cacheplane/b4app/actions/runs/<id>/pending_deployments` is non-empty.
3. Empty the copy vault (command above; `AWS_PROFILE=b4hub-prod AWS_REGION=us-west-2`), confirm `list-recovery-points-by-backup-vault` returns 0.
4. Ask the owner to approve the production apply, or approve on his word: `gh api -X POST repos/cacheplane/b4app/actions/runs/<id>/pending_deployments --input -` with `{"environment_ids":[<id from pending_deployments>],"state":"approved","comment":"..."}` (the Environment id was `25990224381`).
5. Verify: `apply-prod` succeeds; `aws backup describe-backup-vault --region us-west-2 --backup-vault-name b4hub-prod-copy` shows `EncryptionKeyArn` = the new key (`alias/b4hub-prod-copy`); the next nightly backup (`cron(0 6 * * ? *)` UTC) produces a copy in the new vault (`list-copy-jobs` in `us-east-2` shows COMPLETED). Record it in `docs/verification/2026-11-02-hosted-hubs.md` (gate 7 row and runbook 8 B.3) and the D-071 or D-072 note.

Nothing else is running on AWS from this session: every scratch instance (`b4hub-test-drill`, `b4hub-prod-drill`) and the `b4hub-prod-drill` subnet group are deleted.

## 4. Repository and docs conventions that changed during this work

- Decisions and verification records are **one file per entry** since PR #109: `docs/decisions/D-NNN-<slug>.md` and `docs/verification/YYYY-MM-DD-<slug>.md`; `docs/decisions.md` and `docs/verification.md` are generated indexes. Run `Scripts/docs-index.sh --check` before pushing docs. The hosted-hub record is `docs/verification/2026-11-02-hosted-hubs.md` (gates table + owner steps); the hosted-hub implementation notes live in `docs/decisions/D-072-self-hosting-ships-as-a-compose-production.md`.
- Runbooks: `Infra/README.md` (1 bootstrap, 2 database owner, 3 sign-in secrets, 4 first deploy, 5 deploy/rollback, 6 enroll, 7 rotate, 8 restore drill, 9 incidents, 10 recreated ALB, 11 GHCR cleanup, 12 chart release, 13 two tasks). They were corrected repeatedly this week; trust the file over memory.
- Every PR gets auto-merge (`gh pr merge <n> --auto --merge`). Pushing to a PR branch restarts its CI and can cancel the previous run; the macOS runner queue is the slow part. Several other Claude sessions work this repo concurrently (relay, sign-in, monorepo); expect merge conflicts in docs and coordinate via cross-session messages when a PR of yours blocks theirs.
- Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; PR bodies end with the Claude Code attribution line.

## 5. Operator procedures that are non-obvious (learned the hard way)

- **ECS Exec sessions from automation.** `Infra/scripts/admin-shell.sh <env> psql|hub` starts the `hub-admin` task and opens `/bin/sh` through `aws ecs execute-command --interactive`, which needs a pseudo-terminal. Drive it with a Python `pty.fork()` (the old session's scratch drivers did this: wait for "opening /bin/sh", then a `#`/`$` prompt, send commands, match prompts). `script -q /dev/null` with a FIFO does **not** work on macOS. The Session Manager plugin is installed at `/opt/homebrew/bin/session-manager-plugin` (extracted from AWS's signed `.pkg`; the Homebrew cask needs sudo).
- psql's pager: `\du` and `\l` open a pager that stalls prompt matching; use `-P pager=off` or send `q`.
- Enrollment: `b4hub enroll` prints `Enrollment code: <code> (expires in 10 minutes)`; `agent-workspace hub join <url>` reads the code from one line of piped stdin. A Mac is joined to one hub at a time: `agent-workspace hub leave` first. The installed CLI is `~/.local/bin/agent-workspace`.
- The admin task's `hub` container: needs `B4HUB_APPLE_AUDIENCES` whenever it carries the Apple secrets (else `serve` exits at start), and runs **without** a read-only root filesystem because the ECS Exec agent cannot start on one (AWS documents this). Serve and migrate keep the read-only root.
- `desired_count` on the ECS service is ignored by Terraform after creation (`ignore_changes`), so scaling is `aws ecs update-service --desired-count N`; the Terraform edit only adds the task-gated alarms.
- Deploys: `gh workflow run hub-deploy.yml --ref main -f environment=test -f digest=sha256:...` (digest must be one `hub-image.yml` built and attested from `main`; find it on GHCR under tag `sha-<commit>`). Production deploys only via a `hub-v*` release: `gh release create hub-vX.Y.Z --target <main commit that has a built image> --title ... --notes ...`, then approve the `production` gate on the `hub-release.yml` run.
- AWS Backup restore metadata (`get-recovery-point-restore-metadata`) is not restorable as returned: remove `DBSnapshotIdentifier` and `IOPS`, set `Port` to `"5432"`, give `VpcSecurityGroupIds` as a JSON array in a string (`"[\"sg-...\"]"`), and for a copy in another region also remove `AvailabilityZone` and set `DeletionProtection` to `"false"`. Runbook 8 has all of it.
- Region SCP changes propagate within about a minute. Each new AWS service used in `us-west-2` needs its own exception (we hit backup, backup-storage, kms, rds, ec2, iam:PassRole in turn).
- SNS refuses `sns:*` in a topic policy; the module lists the actions.
- Terraform's AWS provider cannot follow a `login_session` source profile; the `credential_process` profiles exist for that reason.

## 6. Remaining work, in the order the owner and the design would take it

1. **Finish #122** (section 3).
2. **Script runbook 8 B.3** (data comparison for the prod copy): with the new key, copy the copied snapshot back to `us-east-2` (`aws rds copy-db-snapshot --source-region us-west-2 --kms-key-id <account data key, alias/b4hub-prod-data>`), restore it into the prod VPC as in part A, compare with the A.5 query from the admin `psql` container, delete. Then the monthly drill is A + B + B.3.
3. **Gate 2b**: a 9 MiB `POST /v1/changes` from the Mac client through the WAF. Needs a Mac with that much history or a seeded large thread; proves the WAF leaves large sync bodies alone.
4. **Deferred by the owner**: Better Stack monitors on both `/readyz` URLs with `status.b4.run` (third-party pager outside AWS; not needed for in-region alarms, which already email him).
5. **Runbook/doc hygiene** whenever something changes: `Infra/README.md`, the hosted-hubs verification record, the D-072 notes, and `docs/milestones.md` (M8e line says both hubs are live-tested).
6. Owner-side: remove the old Intel CLI (commands in section 2).

## 7. Where the previous session kept things

- Memory file (loaded automatically in new sessions of this project): `~/.claude/projects/-Users-blove-repos-b4app/memory/hosted-hub-deployment.md`, indexed from `MEMORY.md`. It has the same facts as this handoff in compressed form; update it when state changes.
- This worktree: `/Users/blove/repos/b4app/.claude/worktrees/m4-managed-b4-c616ab` (branch `blove/copy-vault-cmk` at the time of writing). The scratchpad of the old session (drivers `owner-bootstrap.py`, `enroll-mac.py`, `drill-compare.py`) is session-private and will not be available; recreate from the descriptions in section 5 if needed (each is ~40 lines of `pty.fork` + prompt matching).
- Design: `docs/deployment-architecture.md` (D-068 to D-072), `docs/superpowers/specs/2026-11-02-m8e-hub-operability-design.md`, `docs/superpowers/specs/2026-11-02-m8e-part-b-relay-routing-design.md`, plan `docs/superpowers/plans/2026-11-02-hosted-hub-deployment.md`.

## 8. PR history of this work (for archaeology)

#34 design + Infra; #35, #36 (M8e A), #39, #40 (M8e B); #44 runbook for the existing Organization + immutable OIDC subject; #48 cleanup regex; #52 SNS policy + CAA; #54 deploy rollout settle; #56 test desired_count; #58 admin task (audiences, writable root); #61 prod root + SCP note; #75 gates 1–3; #108 runbook notes, gate 6, cleanup live, restore-drill fixes; #120 restore drill part B, hosted-hubs record refresh; #122 copy vault key (open). Other sessions: #102 (test on two tasks), #109 (docs split), releases `hub-v0.2.0`–`0.5.0`.

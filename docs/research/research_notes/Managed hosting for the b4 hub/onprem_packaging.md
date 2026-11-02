# On-premises packaging of a single-binary HTTP service: Docker Compose "production profile" and a low-maintenance Helm chart (as of November 2026)

Scope note: this covers packaging a one-image Rust service with two commands (`migrate` with a privileged DB URL, `serve` with an application-role DB URL), external PostgreSQL 17, long-lived WebSockets, 35 s graceful shutdown, `/healthz` + `/readyz`, env-var-only config including multi-line PEM secrets, shipped to customers via Docker Compose and a Helm chart and also run as the vendor's SaaS. Every finding dated before 2025 is flagged. Google Cloud and Cloudflare were excluded per the brief.

Research method: ~45 web searches/fetches against primary sources (Helm, Kubernetes, Compose, CNPG, cert-manager, OpenTelemetry, Caddy docs; vendor repos for Plausible, Umami, Gitea, Infisical, Sentry, PostHog, GitLab; Bitnami/Broadcom issue tracker). Several official pages were truncated by the fetch tool; where I fell back to training knowledge I say so explicitly and mark it unverified.

---

## Key question 1: Helm chart conventions in 2026 (structure, values layout, `helm create` baseline, common-library charts, versioning)

### Takeaway
Helm 4 shipped in November 2025 and is the current major; chart layout and `Chart.yaml` semantics are unchanged, so the `helm create` baseline (Deployment/Service/Ingress/ServiceAccount/HPA/tests, `_helpers.tpl` labels) remains the right skeleton. Do not depend on the Bitnami `common` library chart: Broadcom moved the Bitnami catalog behind a subscription in August–September 2025 and stopped publishing new charts to Docker Hub; a small vendor should vendor its own ~50-line `_helpers.tpl` instead. Chart `version` is SemVer 2 and tracks the chart; `appVersion` is informational and should track the application release, quoted.

### Cited Findings
- Helm 4.0.0 was released 12 November 2025 at KubeCon; headline changes are a redesigned plugin system (WASM plugins, post-renderers as plugins), server-side apply, kstatus-based `--wait`, content-addressed local chart caching, slog logging, reproducible chart archives, and an SDK supporting multiple chart API versions (experimental v3 chart API planned). Helm 3 gets bug fixes until 8 July 2026 and security fixes until 11 November 2026 — [Helm blog: Helm 4 released](https://helm.sh/blog/helm-4-released); [CNCF announcement](https://www.cncf.io/announcements/2025/11/12/helm-marks-10-years-with-release-of-version-4/)
- The CNCF announcement says Helm 4 "retains the core interface and behavior familiar to current users, minimizing disruption for existing workflows" and existing plugins continue to work — [CNCF](https://www.cncf.io/announcements/2025/11/12/helm-marks-10-years-with-release-of-version-4/)
- The current Helm docs site shows version 4.3.1 as the default; several pages (charts, registries) carry a banner that they "have not yet been updated for Helm 4" — [helm.sh/docs/topics/charts](https://helm.sh/docs/topics/charts/); [helm.sh/docs/topics/registries](https://helm.sh/docs/topics/registries/)
- Chart directory layout: `Chart.yaml`, `values.yaml`, `charts/`, `crds/`, `templates/`, optional `LICENSE`, `README.md`, `values.schema.json`, `templates/NOTES.txt`; "Helm reserves use of the `charts/`, `crds/`, and `templates/` directories, and of the listed file names" — [Helm: Charts](https://helm.sh/docs/topics/charts/)
- `Chart.yaml` `version`: "A version should follow the SemVer 2 standard but it is not strictly enforced" and non-SemVer names are "explicitly disallowed by the system". `appVersion` is separate, informational, "Needn't be SemVer. Quotes recommended" because YAML would misparse e.g. `1.0`. `kubeVersion` is an optional semver constraint validated at install. `deprecated: true` on the latest version marks the chart deprecated. `type` is `application` (default) or `library` — [Helm: Charts](https://helm.sh/docs/topics/charts/)
- Dependencies support `condition` (comma-delimited YAML paths; first boolean wins), `tags`, `alias`, and `import-values`; OCI dependencies use `repository: oci://host/namespace` without the chart name — [Helm: Charts](https://helm.sh/docs/topics/charts/); [Helm: Registries](https://helm.sh/docs/topics/registries/)
- Values best practices: lowercase camelCase keys, avoid hyphens (dashed keys need `index`), prefer flat keys unless many related values exist, quote all strings, prefer maps over lists because `--set` cannot address lists well, and document every property with a comment that "begins with the property name" so doc tools can parse it — [Helm: Values best practices](https://helm.sh/docs/chart_best_practices/values/)
- `values.schema.json` is JSON Schema applied to the final merged `.Values`; validated during `helm install`, `helm upgrade`, `helm lint`, and `helm template`; bypassable with `--skip-schema-validation` ("useful in air-gapped environments") — [Helm: Charts](https://helm.sh/docs/topics/charts/)
- Bitnami/Broadcom: on 28 August 2025 the public `docker.io/bitnami` catalog switched to a limited hardened community-tier subset (`latest` tag only, published under `bitnamisecure`), versioned images moved to `docker.io/bitnamilegacy` (archive, "no updates, fixes, or support", "temporary fallback"), deletion of the old catalog was postponed to 29 September 2025, and "no new Bitnami container images or Helm charts have been published to Docker Hub in OCI format" since 28 August. Chart source stays on GitHub under Apache 2.0; packaged charts at `docker.io/bitnamicharts` "get no further updates". Full catalog requires a Bitnami Secure Images subscription — [bitnami/charts issue #35164 (official announcement)](https://github.com/bitnami/charts/issues/35164); [Broadcom VCF announcement PDF](https://vcf.broadcom.com/vsc/bitnamiAnnouncement.pdf)
- Bitnami's FAQ workaround for existing chart users is to pin the chart version and point image repositories at `bitnamilegacy` with `--set` plus `global.security.allowInsecureImages=true` — [bitnami/charts #35164](https://github.com/bitnami/charts/issues/35164)
- Real-world reaction: NCEAS Metacat chart 3.0.0 dropped its PostgreSQL subchart because of "Bitnami's move away from free, versioned images" and now expects an external database, pointing users at a CloudNativePG appendix — [metacat chart-3.0.0 release](https://github.com/NCEAS/metacat/releases/tag/chart-3.0.0)
- Camunda published a guide to migrate from Bitnami subcharts to operators (Keycloak Operator + CloudNativePG) — [Camunda docs](https://docs.camunda.io/docs/self-managed/deployment/helm/operational-tasks/migration-from-bitnami/bitnami-to-operators/)
- Artifact Hub reads `Chart.yaml` and `artifacthub.io/*` annotations (e.g. `artifacthub.io/changes` for a per-version changelog) to populate listings; it renders a values-schema reference when `values.schema.json` is present — [Artifact Hub: Helm annotations](https://artifacthub.io/docs/topics/annotations/helm/); [Artifact Hub blog: values schema](https://blog.artifacthub.io/blog/helm-values-schema-reference/)

### Inferences
- The `bitnami/common` library chart is still Apache-2.0 source on GitHub, but its packaged OCI releases are frozen and its images ecosystem is gone; depending on it means either vendoring a frozen tarball or tracking a repo whose maintainers' incentives changed. For a two-person vendor, copying the handful of helpers you actually use (`fullname`, `labels`, `selectorLabels`, `serviceAccountName`, `image` renderer with `global.imageRegistry`) into `_helpers.tpl` is lower-maintenance and removes a dependency.
- Recommended `values.yaml` top level for this service (following the Helm best practices and `helm create`): `image.{registry,repository,tag,digest,pullPolicy}`, `imagePullSecrets`, `replicaCount: 1`, `strategy`, `podAnnotations/podLabels`, `podSecurityContext`, `securityContext`, `service.{type,port}`, `ingress.{enabled,className,annotations,hosts,tls}`, `httpRoute.{enabled,parentRefs,hostnames,timeouts}`, `resources`, `probes.{startup,liveness,readiness}`, `terminationGracePeriodSeconds: 40`, `env` (list) and `envFrom`, `config` (map of non-secret env), `secrets.{existingSecret,create,values}`, `database.{url?, existingSecret, urlKey, migrateUrlKey}`, `migrations.{enabled, hook, backoffLimit, activeDeadlineSeconds, ttlSecondsAfterFinished}`, `serviceAccount`, `pdb`, `networkPolicy`, `metrics.serviceMonitor`, `otel.endpoint`, `extraVolumes/extraVolumeMounts`, `nodeSelector/tolerations/affinity`. Keep nesting to two levels and document each key with a `# --` comment for helm-docs (see KQ8).
- Chart `version` should be bumped on every chart change (patch for template fixes, minor for new values, major for breaking values changes); `appVersion` should equal the image tag the chart defaults to. Many vendors release both together (same tag) which is simplest to explain to customers; the Helm docs don't require it.
- Set `kubeVersion: ">=1.29.0-0"` (or whatever you test against) so install fails fast on unsupported clusters; the `-0` suffix is the usual way to admit pre-release/vendor-suffixed versions (convention from Helm community; not verified against a doc page in this research).

### Gaps
- I did not find a 2026 primary-source survey of what percentage of charts still depend on `bitnami/common`; the evidence of migration away is from individual projects (Metacat, Camunda).
- The Helm docs pages have not been fully re-reviewed for Helm 4; any Helm-4-specific chart API (`apiVersion: v3`) is described only as "experimental/planned" in the release blog and should not be targeted yet.

---

## Key question 2: Running migrations — hook Job vs init container vs migrate-on-start; hook mechanics, `--atomic`/rollback; what popular charts do

### Takeaway
For a single-replica service with a separate privileged migration URL, the dominant pattern is a Kubernetes Job wrapped in a Helm `pre-install,pre-upgrade` hook (Sentry, GitLab auto-deploy-app), with `hook-delete-policy: before-hook-creation,hook-succeeded` and a `ttlSecondsAfterFinished` fallback; keep migrate-on-start as an opt-in for Compose-style simplicity. Hook Jobs are not tracked as release resources, fail the release if they fail, and run before the Deployment is touched, which is what you want: a failed migration leaves the old pods serving.

### Cited Findings
- Available hooks: `pre-install`, `post-install`, `pre-delete`, `post-delete`, `pre-upgrade`, `post-upgrade`, `pre-rollback`, `post-rollback`, `test`. `helm.sh/hook-weight` is a string, may be negative, default 0, sorted ascending. `helm.sh/hook-delete-policy` values: `before-hook-creation` (default when unspecified), `hook-succeeded`, `hook-failed`; combinable — [Helm: Chart hooks](https://helm.sh/docs/topics/charts_hooks/)
- "Resources created by hooks are not tracked as part of the release"; `helm uninstall` does not remove them, so use a deletion policy or a Job TTL. Helm blocks on Job/Pod hooks until they complete; "If a hook fails, the release fails." Hooks of the same weight run in normal resource order since Helm 3.2.0. Subchart hooks always run and cannot be disabled by the parent — [Helm: Chart hooks](https://helm.sh/docs/topics/charts_hooks/)
- `pre-rollback` runs "after templates are rendered, but before any resources are rolled back". The hooks page does not discuss `--atomic` — [Helm: Chart hooks](https://helm.sh/docs/topics/charts_hooks/)
- Helm 4.3.1 `helm upgrade` flags: `--rollback-on-failure` ("if set, Helm will rollback the upgrade to previous success release upon failure"; the page no longer lists `--atomic` by that name), `--wait` ("wait until resources are ready (up to --timeout)", default when omitted `hookOnly`), `--wait-for-jobs`, `--timeout` default `5m0s` ("time to wait for any individual Kubernetes operation (like Jobs for hooks)"), `--no-hooks`, `--cleanup-on-fail`, `--install`, `--set-file`, `--reset-then-reuse-values`, `--take-ownership` — [Helm 4: helm upgrade](https://helm.sh/docs/helm/helm_upgrade/)
- Community/practitioner consensus (2026 posts): run migrations as a standalone Job triggered by a Helm pre-install/pre-upgrade hook rather than an init container, because an init container "runs once for every Pod start" (concurrent migrations with multiple replicas, re-runs after reschedules) and because a failed migration should keep the old version running; hook Job names must be unique per run or the delete policy must handle the previous Job — [freeCodeCamp](https://www.freecodecamp.org/news/how-to-run-database-migrations-in-kubernetes/); [OneUptime 2026-02](https://oneuptime.com/blog/post/2026-02-09-database-migration-jobs-before-rollouts/view); [Gurubase](https://gurubase.io/g/kubernetes/manage-database-migrations-kubernetes)
- Sentry chart (sentry-kubernetes/charts, read 2026): migrations are Kubernetes Jobs wrapped in Helm hooks; `hooks.enabled: true`, `hooks.preUpgrade: false` by default (hooks run post-sync; set `true` to run pre-upgrade/PreSync), `hooks.removeOnSuccess: true`, `hooks.restartPolicy: Never`, `hooks.activeDeadlineSeconds: 600`; a separate hook credentials Secret is created in the same hook phase and removed on success (a failed run can leave it behind); install docs use `--wait --timeout=1000s`; external Postgres via `externalPostgresql` with `existingSecret` — [sentry chart README](https://github.com/sentry-kubernetes/charts/blob/develop/charts/sentry/README.md)
- GitLab auto-deploy-app chart: `migrate` command runs as a Helm `pre-upgrade` hook and `initialize` as a `post-install` hook; "if the first deploy successfully completes, the initialization command will never be run again"; a known limitation was that hook Job logs were not visible during execution — [GitLab auto-deploy-app MR 7](https://gitlab.com/charts/auto-deploy-app/-/merge_requests/7); [gitlab-foss issue 48004](https://gitlab.com/gitlab-org/gitlab-foss/issues/48004) (2018–2024 era; flagged as older)
- Plausible CE v3.2.1 `compose.yml` (Compose, not Helm): migrations run in the app container's `command` as `/entrypoint.sh db createdb && /entrypoint.sh db migrate && /entrypoint.sh run`, ordering guaranteed only by `depends_on: condition: service_healthy` on both databases — [plausible/community-edition compose.yml v3.2.1](https://raw.githubusercontent.com/plausible/community-edition/v3.2.1/compose.yml)
- Umami `docker-compose.yml`: no separate migration service; app `depends_on: db: condition: service_healthy`, `restart: always`, `init: true`; migrations are implied to run at app start (the file shows none) — [umami docker-compose.yml](https://github.com/umami-software/umami/blob/master/docker-compose.yml)
- Infisical Compose docs: no separate migration container; the upgrade guide tells operators to watch backend logs for "successful database migration messages" — [Infisical Docker Compose](https://www.infisical.com/docs/self-hosting/deployment-options/docker-compose)
- Keycloak Operator (via Mia Platform's chart docs): minor/major version changes use a recreate strategy that scales the StatefulSet to zero for schema migrations; patch changes roll without downtime — [Mia Platform keycloak-operator overview](https://docs.mia-platform.eu/docs/requirements/installation-guidelines/shared-services/authn/keycloak/overview)
- PostHog ended Helm/Kubernetes support after 31 May 2023 and keeps only the Docker Compose "hobby" deployment (image per commit, no numbered releases) — [PostHog blog](https://posthog.com/blog/sunsetting-helm-support-posthog); [PostHog self-host docs](https://posthog.com/docs/self-host/deploy)
- Compose `depends_on` `condition: service_completed_successfully` "Specifies that a dependency is expected to run to successful completion before starting a dependent service" — [Compose services reference](https://docs.docker.com/reference/compose-file/services/)

### Inferences
- Recommended Helm design for this service:
  - `templates/migrate-job.yaml` with annotations `helm.sh/hook: pre-install,pre-upgrade`, `helm.sh/hook-weight: "-5"`, `helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded`; `spec.backoffLimit: 0` (migrations should not retry blindly), `activeDeadlineSeconds` ~600, `ttlSecondsAfterFinished` ~3600 as belt-and-braces (hook resources are not tracked by Helm), `restartPolicy: Never`, the same image, `args: ["migrate"]`, env `DATABASE_URL` from the migration Secret key. Name it with `{{ .Release.Revision }}` or rely on `before-hook-creation` to replace the previous Job.
  - If the migration Secret is also chart-created, give it `helm.sh/hook: pre-install,pre-upgrade` and `hook-weight: "-10"` so it exists before the Job (Sentry's pattern); if `existingSecret` is used, no hook Secret is needed.
  - Expose `migrations.enabled` (default true), `migrations.hook` (default true; false renders a plain Job for Argo CD users who prefer PreSync annotations — note Argo CD maps Helm hooks to its own hooks automatically), and document `--no-hooks` + manual `kubectl create job --from` for operators who want to run `migrate` by hand.
  - Because Helm blocks on the Job and the default `--timeout` is 5 m, tell customers to pass `--timeout 15m` for large upgrades, and `--wait --wait-for-jobs` (Helm 4 default `--wait=hookOnly` already waits for hook jobs).
  - With `--rollback-on-failure` (Helm 4) / `--atomic` (Helm 3), a failed hook fails the upgrade before the Deployment changes, so the rollback is to an unchanged workload; the database, however, may be partially migrated. Document that migrations must be forward-compatible with the previous app version (expand/contract) so a Helm rollback after a successful migration is safe, or state explicitly that downgrades are unsupported.
- Migrate-on-start (`serve` running `migrate` first) is attractive for Compose but violates the brief's least-privilege split (the serving pod would need the privileged URL). For Compose, use a one-shot `migrate` service with `restart: "no"` and `depends_on: db: condition: service_healthy`, and have `serve` `depends_on: migrate: condition: service_completed_successfully` — this is directly expressible in the Compose spec and preserves the two-URL split. Plausible/Umami/Infisical do not do this today (they migrate in-process), so this would be a stricter-than-typical design; it is still fully supported by the spec.
- Init containers are the wrong tool here: they would need the privileged URL in the serving pod spec and re-run on every restart.

### Gaps
- I could not fetch a primary page confirming how Grafana, Argo CD, Keycloak's official operator, or the current GitLab (full) chart run migrations in 2026; GitLab evidence is from the older auto-deploy-app chart. (From general knowledge, unverified: Grafana and Argo CD apply schema changes on process start; the GitLab chart has a `migrations` Job with `pre-upgrade`-style hooks.)
- No primary Helm doc explicitly describes `--rollback-on-failure`/`--atomic` interaction with hook Jobs beyond "if a hook fails, the release fails".

---

## Key question 3: Secrets — `existingSecret` plus chart-created; ESO/Vault/sealed-secrets compatibility; multi-line PEM; never in ConfigMaps or git

### Takeaway
Follow the de-facto `existingSecret` convention: the chart consumes a named Secret with documented keys, and optionally creates that Secret from values for quick starts. External Secrets Operator, Vault injectors and sealed-secrets all produce ordinary Secrets, so "consume by name + key" is the only compatibility requirement. Multi-line PEM belongs in a Secret (`stringData` accepts arbitrary strings) and is best mounted as a file; if it must be an env var, `valueFrom.secretKeyRef` passes newlines intact.

### Cited Findings
- Kubernetes Secrets are "by default, stored unencrypted in the API server's underlying data store (etcd)"; anyone who can create a Pod in a namespace can read its Secrets; recommended: enable encryption at rest, least-privilege RBAC, restrict Secret access to specific containers, "Consider using external Secret store providers" — [Kubernetes: Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)
- `stringData` "accepts arbitrary strings as values" and is merged into `data`, with `stringData` winning on key conflicts; individual Secrets are limited to 1 MiB; mounted Secret volumes are updated eventually-consistently (delay up to kubelet sync period + cache propagation; default strategy `Watch`), but a `subPath` mount "does not receive automated Secret updates" — [Kubernetes: Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)
- `helm upgrade --set-file` sets "values from respective files specified via the command line" (the standard way to pass a PEM file into a value without embedding it in a committed values file) — [Helm 4: helm upgrade](https://helm.sh/docs/helm/helm_upgrade/)
- The `existingSecret` value pattern: set a chart value to the name of a pre-existing Secret and reference it via `secretKeyRef`; described as common practice that "helps in reusing secrets across multiple charts" — [Gurubase: Managing Secrets in Helm Charts](https://gurubase.io/g/kubernetes/manage-secrets-using-helm-charts). A Harness feature request shows the demand: their chart "only supports adding the agentSecret directly in the values.yaml" while the org "uses External Secrets Operator (ESO) to fetch secrets from AWS Secrets Manager and create Kubernetes secrets automatically" — [Harness ideas](https://ideas.harness.io/feature-request/p/support-existing-k8s-secrets-for-harnesssecretsagentsecret)
- Sentry chart external Postgres: `externalPostgresql` with inline credentials or `existingSecret` — [sentry chart README](https://github.com/sentry-kubernetes/charts/blob/develop/charts/sentry/README.md)
- External Secrets Operator "reads secrets from external APIs and injects their values into standard Kubernetes Secrets" via `ExternalSecret`, `SecretStore`, `ClusterSecretStore`; providers include HashiCorp Vault and OpenBao, AWS Secrets Manager/Parameter Store, Azure Key Vault, 1Password, IBM, CyberArk Conjur, Pulumi ESC; repo https://github.com/external-secrets/external-secrets — [external-secrets.io](https://external-secrets.io/latest/)
- Sealed Secrets continues publishing to `docker.io/bitnami` unaffected by the catalog change — [bitnami/charts #35164](https://github.com/bitnami/charts/issues/35164)
- Compose secrets: short syntax mounts read-only at `/run/secrets/<name>`; long syntax has `source`, `target`, `uid`, `gid`, `mode` (default `0444`), but `uid/gid/mode` "are silently ignored" for `file` sources and only work for `environment` sources; "Defining a secret in the top-level `secrets` must not imply granting any service access to it" — [Compose services reference](https://docs.docker.com/reference/compose-file/services/)
- Infisical's Compose guide: `.env` "holds security-critical secrets", keep out of version control, `chmod 600`, and back up `ENCRYPTION_KEY` — [Infisical Docker Compose](https://www.infisical.com/docs/self-hosting/deployment-options/docker-compose)
- Umami and Plausible ship placeholder/weak credentials inline in their compose files (`APP_SECRET: replace-me-...`, hardcoded Postgres password) — [umami compose](https://github.com/umami-software/umami/blob/master/docker-compose.yml); [plausible compose v3.2.1](https://raw.githubusercontent.com/plausible/community-edition/v3.2.1/compose.yml)

### Inferences
- Chart contract to specify: one Secret with fixed key names, e.g. `DATABASE_URL`, `MIGRATE_DATABASE_URL`, `SIGNING_KEY_PEM`, `TLS_CERT_PEM`, ... Values: `secrets.existingSecret: ""` (if set, nothing is created), `secrets.keys.*` to remap key names (ESO users often cannot choose keys), and `secrets.values.*` for chart-created Secrets (documented as "development/quick start only"). Put the migration URL in a *separate* Secret (`database.migrateExistingSecret`) so RBAC can keep it out of the serving pod's namespace view if desired; only the hook Job mounts it.
- Multi-line PEM: put it in `stringData` (Helm `toYaml`/`quote` of a multi-line value works; or `b64enc` into `data`). Prefer mounting PEM keys as files (`/etc/<app>/keys/...`) and pointing an env var (`*_FILE`) at the path: files survive rotation without restart (for non-`subPath` mounts) and avoid newline-escaping confusion in `kubectl describe`/logs. If the service only accepts PEM via env var, `env[].valueFrom.secretKeyRef` preserves newlines; document that `--set-file secrets.values.signingKeyPem=./key.pem` is how to pass it from the CLI, never inline in a committed values file. Consider adding `*_FILE` variants to the service's config surface as a packaging-friendliness feature.
- Never render secrets into ConfigMaps; `helm template` output and `helm get values` will expose chart-created secret values, so NOTES.txt should warn about this and recommend `existingSecret`.
- For Compose: use `secrets:` with `file:` sources (mounted at `/run/secrets/...`) and `*_FILE` env vars where the binary supports them; otherwise a `.env` file with `chmod 600`, matching the Infisical guidance. Compose `environment:` secret sources allow `mode` tuning but `file` sources do not.

### Gaps
- Did not retrieve the ESO `ExternalSecret.spec.target`/`template` reference page content (fetch returned only the intro); the by-name consumption claim rests on ESO's stated model of producing standard Secrets.
- No primary-source statement that env vars from Secrets are not refreshed on Secret change; this is general Kubernetes behaviour but was not on the fetched page excerpt.

---

## Key question 4: Database — bundle Postgres as an optional sub-chart vs require an external database; CNPG/Crunchy/Zalando; what small vendors do

### Takeaway
Do not bundle Postgres as a Helm sub-chart. The Bitnami `postgresql` subchart's packaged images are frozen/paywalled since August–September 2025, and the projects that reacted (Metacat, Camunda) switched to "bring your own database" with a CloudNativePG recipe. For Compose, bundling the official `postgres:17` image is normal (Plausible, Umami, Gitea all do it) with a pinned major version.

### Cited Findings
- Bitnami: packaged charts at `docker.io/bitnamicharts` get no further updates; deploying them "may fail unless you override the bundled images"; versioned images only in `bitnamilegacy` (no updates) or via subscription — [bitnami/charts #35164](https://github.com/bitnami/charts/issues/35164)
- Metacat chart 3.0.0 "assumes you will provide your own PostgreSQL instance", citing Bitnami's change, with a README appendix for a CloudNativePG cluster — [metacat chart-3.0.0](https://github.com/NCEAS/metacat/releases/tag/chart-3.0.0)
- Migration write-up from a Bitnami PostgreSQL release to CloudNativePG uses "the official cluster Helm chart from https://cloudnative-pg.io/charts" and CNPG's import bootstrap; the old subchart's PVC is not removed automatically — [christianhuth.de](https://christianhuth.de/migrating-a-bitnami-postgresql-helm-release-to-cloudnativepg)
- Big Bang (DoD) GitLab package issue: CloudNativePG "is not a drop-in replacement for the Bitnami Postgres image used by the upstream GitLab chart" and would need engineering work — [repo1.dso.mil issue 358](https://repo1.dso.mil/big-bang/product/packages/gitlab/-/issues/358)
- CloudNativePG describes itself as an open-source Kubernetes operator managing PostgreSQL clusters (failover, replica scaling, rolling updates via the Kubernetes API) and "a Cloud Native Computing Foundation Sandbox project"; repo https://github.com/cloudnative-pg/cloudnative-pg, site https://cloudnative-pg.io; docs moved to https://cloudnative-pg.io/docs/current — [CNPG GitHub README](https://github.com/cloudnative-pg/cloudnative-pg); [CNPG docs redirect](https://cloudnative-pg.io/documentation/current/)
- Camunda's official migration guide moves from Bitnami subcharts to Keycloak Operator + CloudNativePG, requires the target DB name and user to match the source — [Camunda docs](https://docs.camunda.io/docs/self-managed/deployment/helm/operational-tasks/migration-from-bitnami/bitnami-to-operators/)
- Gitea's official Compose example uses `docker.io/library/postgres:18`, pins the major on purpose because "PostgreSQL does not upgrade its data directory on its own" (needs `pg_upgrade` or dump/restore), and `restart: always` — [Gitea: Install with Docker](https://docs.gitea.com/installation/install-with-docker)
- Plausible CE v3.2.1 bundles `postgres:16-alpine` with `pg_isready` healthcheck and 1-minute `start_period`; Umami bundles `postgres:15-alpine` with `pg_isready` healthcheck (5 s interval, 5 retries) — [plausible compose](https://raw.githubusercontent.com/plausible/community-edition/v3.2.1/compose.yml); [umami compose](https://github.com/umami-software/umami/blob/master/docker-compose.yml)
- Infisical's Compose: "This Docker Compose configuration isn't designed for high-availability production scenarios"; for HA it points to Kubernetes — [Infisical Docker Compose](https://www.infisical.com/docs/self-hosting/deployment-options/docker-compose)

### Inferences
- Helm chart: require an external PostgreSQL 17 and ship (a) a documented `database.existingSecret` contract and (b) an `examples/cnpg-cluster.yaml` plus a README section "Postgres with CloudNativePG" that creates a `Cluster` and uses the operator-generated app Secret. From training knowledge (not verified in this research because the CNPG docs fetch returned empty): CNPG creates Services `<cluster>-rw`, `<cluster>-ro`, `<cluster>-r` and Secrets `<cluster>-app` and `<cluster>-superuser` whose keys include `username`, `password`, `dbname`, `host`, `port`, `uri`, `jdbc-uri`, `pgpass`; superuser Secret creation is controlled by `enableSuperuserAccess`. The migration URL could then be the superuser URI (or a dedicated owner role created via `bootstrap.initdb.postInitSQL`), and the serve URL the `-app` URI — but verify these names against https://cloudnative-pg.io/docs/current/applications/ before writing them into the architecture document.
- Also mention Crunchy PGO and Zalando postgres-operator as alternatives, but I found no 2026 sources on them in this research; treat as a gap.
- Compose: bundle `postgres:17` (official image) as a `db` service with named volume, `pg_isready` healthcheck, `restart: unless-stopped`, under no profile (always on) and provide an alternative "external database" variant by simply omitting the service and setting URLs; or put the bundled DB behind a `profiles: [bundled-db]` so `docker compose --profile bundled-db up` is explicit.

### Gaps
- CNPG docs pages (`/docs/current/`, `/applications/`) returned no content to the fetch tool; current CNPG version, PostgreSQL 17/18 support matrix, CNCF status beyond "Sandbox", and exact Secret key names are unverified here.
- No primary sources gathered on Crunchy PGO or Zalando in 2026.

---

## Key question 5: Ingress and WebSockets — ingress-nginx retirement, Gateway API/HTTPRoute timeouts, cert-manager, graceful termination, PDB, Recreate vs RollingUpdate

### Takeaway
ingress-nginx was retired in March 2026 (announced 11 November 2025) so the chart must be Ingress-controller-agnostic and should ship an optional Gateway API `HTTPRoute` with `timeouts`; HTTPRoute timeouts have been in the Standard channel since Gateway API v1.2 and the latest release is v1.7.0 (29 October 2026). cert-manager supports Gateway listeners (beta, no feature gate since 1.15). Set `terminationGracePeriodSeconds` above the app's 35 s drain (40 s), a short `preStop` sleep, `strategy: Recreate` for one replica with in-memory state, and omit the PDB by default for a single replica.

### Cited Findings
- Kubernetes SIG Network and the Security Response Committee announced ingress-nginx retirement on 11 November 2025: best-effort maintenance until March 2026, then no releases, bug fixes or security updates; existing deployments keep working and artifacts remain available; recommendation to "begin migration to Gateway API or another Ingress controller immediately"; the InGate successor was also retired — [Kubernetes blog (EN)](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/); [kubernetes.dev copy](https://kubernetes.dev/blog/2025/11/12/ingress-nginx-retirement); [Korean mirror used for text](https://kubernetes.io/ko/blog/2025/11/11/ingress-nginx-retirement/). Follow-ups: "Statement from the Kubernetes Steering and Security Response Committees" (29 Jan 2026) and "Before You Migrate: Five Surprising Ingress-NGINX Behaviors" (27 Feb 2026) — titles seen in the blog sidebar.
- Ingress2Gateway 1.0 (20 March 2026) translates Ingress + 30+ ingress-nginx annotations to Gateway/HTTPRoute (`--providers=ingress-nginx`, emitters for agentgateway/envoy-gateway/kgateway); ingress-nginx "only supports TCP-level timeouts (`proxy-read-timeout` and `proxy-send-timeout`)" and the tool makes a best-effort translation to `timeouts.request` that must be verified; `configuration-snippet` is dropped; `proxy-body-size` has no standard equivalent; it adds a port-80 → HTTPS redirect listener by default — [Kubernetes blog: Ingress2Gateway 1.0](https://kubernetes.io/blog/2026/03/20/ingress2gateway-1-0-release/)
- ingress-nginx annotation reference (still online, no retirement banner): `nginx.ingress.kubernetes.io/proxy-connect-timeout`, `proxy-send-timeout`, `proxy-read-timeout` ("All timeout values are unitless and in seconds"), global defaults from the ConfigMap; `proxy-body-size` returns 413 when exceeded — [ingress-nginx annotations](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/). Community guidance for WebSockets is to raise read/send timeouts to ~3600 s — [OneUptime 2026-02](https://oneuptime.com/blog/post/2026-02-20-kubernetes-nginx-ingress-annotations/markdown)
- Gateway API v1.2 promoted the HTTPRoute `timeouts` stanza (GEP-1742: overall `request` timeout and `backendRequest` timeout) to the Standard channel — [Kubernetes blog: Gateway API v1.2](https://v1-35.docs.kubernetes.io/blog/2024/11/21/gateway-api-v1-2/). A February 2026 blog calls them "Extended-support" timeouts; this refers to the conformance support level of the fields, not the release channel — [OneUptime](https://oneuptime.com/blog/post/2026-02-09-httproute-timeout-policies/markdown)
- Gateway API releases: v1.7.0 on 29 October (2026), v1.6.x June–October 2026; v1.7.0 promoted HTTPRoute retries (GEP-1731: `codes`, `attempts`, `backoff`) to Standard; BackendTLSPolicy, ListenerSet, session persistence remain Experimental — [gateway-api releases](https://github.com/kubernetes-sigs/gateway-api/releases)
- cert-manager Gateway API support is "beta" since 1.15 and no longer behind a feature flag, but must be enabled with Helm value `config.gatewayAPI.enabled: true`; annotate the Gateway with `cert-manager.io/issuer` or `cert-manager.io/cluster-issuer`; cert-manager creates a Certificate per listener that has `hostname`, `tls.mode: Terminate`, and a Secret in `certificateRefs`; tested against Gateway API v1 (example bundle v1.4.1; ListenerSet needs v1.5+) — [cert-manager: Gateway usage](https://cert-manager.io/docs/usage/gateway/)
- Pod termination: default `terminationGracePeriodSeconds` is 30 s; the `preStop` hook runs first and counts against the grace period; "If the `preStop` hook is still running after the grace period expires, the kubelet requests a small, one-off grace period extension of 2 seconds"; then SIGTERM to PID 1; at expiry SIGKILL. Concurrently the control plane marks the endpoint terminating ("Terminating endpoints always have their `ready` status as `false`"). Readiness failure removes the Pod IP from EndpointSlices; startup probes gate liveness/readiness — [Kubernetes: Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
- PodDisruptionBudget: only one of `minAvailable`/`maxUnavailable`; percentages round up; with `maxUnavailable: 30%` and one replica "that single replica is still allowed for disruption, leading to an effective unavailability of 100%"; for a single-instance stateful app the docs suggest `maxUnavailable=0` with an out-of-band agreement that the cluster operator deletes the PDB before maintenance — [Kubernetes: Configure PDB](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)
- Keycloak Operator uses a recreate strategy (scale to zero) for minor/major upgrades that migrate schema — [Mia Platform](https://docs.mia-platform.eu/docs/requirements/installation-guidelines/shared-services/authn/keycloak/overview)
- Traefik documents a `kubernetes-ingress-nginx` provider that understands ingress-nginx annotations, as a migration path — [Traefik docs](https://doc.traefik.io/traefik/master/reference/install-configuration/providers/kubernetes/kubernetes-ingress-nginx)

### Inferences
- Chart templates: `ingress.yaml` (classic `networking.k8s.io/v1`, `className` configurable, free-form `annotations` so customers can add their controller's WebSocket/timeout knobs; document the ingress-nginx trio and that ingress-nginx is retired) and `httproute.yaml` (`gateway.networking.k8s.io/v1` HTTPRoute, `parentRefs`, `hostnames`, `rules[].timeouts.request`/`backendRequest` defaulting to `0s`/disabled or a long value for WebSockets, guarded by `.Capabilities.APIVersions.Has "gateway.networking.k8s.io/v1"`). TLS: document cert-manager annotations on Ingress (`cert-manager.io/cluster-issuer`) and on the Gateway (operator-owned, not in this chart).
- WebSockets and `timeouts.request`: GEP-1742's `request` timeout spans the whole request; for long-lived WebSocket upgrades the safe default is `0s` (disabled) or omitting the stanza, with a README note that implementations default differently. Mark this as needing a test against the customer's gateway implementation.
- `terminationGracePeriodSeconds: 40` (35 s app drain + headroom) and a `preStop` `sleep 3` (so endpoint removal propagates before SIGTERM); values default must be ≥ the app's internal drain. The readiness probe should flip to failing on SIGTERM so new connections stop while existing WebSockets drain.
- `strategy: Recreate` by default when `replicaCount: 1` and the service keeps in-memory state (two instances cannot coexist); expose `strategy` as a value so SaaS/HA deployments can switch to RollingUpdate when the app supports it.
- PDB: `pdb.enabled: false` default; when enabled with one replica, use `minAvailable: 0`/`maxUnavailable: 1` (allows drains) unless the customer explicitly wants drain-blocking (`maxUnavailable: 0`).

### Gaps
- The Gateway API HTTPRoute API reference page URL I tried (`/api-types/httproute/`) returned 404; the exact wording of `timeouts.request`/`backendRequest` semantics (including `0s` to disable) was not retrieved and relies on GEP-1742 as summarized by the v1.2 blog.
- ingress-nginx annotation defaults (60 s) were not confirmed on the fetched page; the page says globals come from the ConfigMap.

---

## Key question 6: Security context defaults, Pod Security Standards "restricted", NetworkPolicy

### Takeaway
Ship the chart's defaults already compliant with the Restricted Pod Security Standard: `runAsNonRoot: true`, `runAsUser: 10001`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault`, only allowed volume types; add `readOnlyRootFilesystem: true` (not required by Restricted, but standard hardening) with an `emptyDir` for any scratch path. Provide an opt-in NetworkPolicy.

### Cited Findings
- Restricted profile (Kubernetes docs, exact allowed values): volumes limited to `configMap`, `csi`, `downwardAPI`, `emptyDir`, `ephemeral`, `persistentVolumeClaim`, `projected`, `secret`; `allowPrivilegeEscalation: false` on all containers incl. init/ephemeral; `runAsNonRoot: true` (pod-level suffices); `runAsUser` non-zero or unset; `seccompProfile.type` must be `RuntimeDefault` or `Localhost` (unset or `Unconfined` prohibited); `capabilities.drop` must include `ALL`, `add` only `NET_BIND_SERVICE`. The page has no control for `readOnlyRootFilesystem` — [Kubernetes: Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- Compose `init: true` "runs an init process (PID 1) inside the container that forwards signals and reaps processes" (Umami uses it) — [Compose services reference](https://docs.docker.com/reference/compose-file/services/); [umami compose](https://github.com/umami-software/umami/blob/master/docker-compose.yml)

### Inferences
- Values skeleton:
  ```yaml
  podSecurityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile: { type: RuntimeDefault }
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities: { drop: [ALL] }
  ```
  Apply the same to the migration Job's pod template (Restricted applies to hook pods too). Listen on a port > 1024 (e.g. 8080) so `NET_BIND_SERVICE` is never needed. The Dockerfile should create UID 10001 and set `USER 10001` so `runAsNonRoot` validation does not depend on the image metadata at runtime (a Rust static binary on `scratch`/distroless makes `readOnlyRootFilesystem` trivial).
- `networkPolicy.enabled: false` default; when enabled: ingress from the gateway/ingress namespace (label selector values) to the service port, egress to the Postgres host/port, DNS, and the OTLP endpoint. Keep it minimal; customers' CNIs differ.
- For Compose, the analogous hardening is `user: "10001:10001"`, `read_only: true`, `tmpfs: [/tmp]`, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, `init: true`. (Compose field names from general knowledge; `init` verified above.)

### Gaps
- No primary source on 2026 defaults for UID choice (10001 vs 65532 "nonroot" of distroless); both are conventions.

---

## Key question 7: Observability hooks — ServiceMonitor/PodMonitor optional, OTLP endpoint env var

### Takeaway
Expose `metrics.serviceMonitor.enabled` guarded on the `monitoring.coreos.com/v1` API existing, and pass OpenTelemetry's standard `OTEL_EXPORTER_OTLP_*` variables through plain values rather than inventing vendor names.

### Cited Findings
- OTLP exporter env vars (spec): `OTEL_EXPORTER_OTLP_ENDPOINT` (defaults `http://localhost:4318` for HTTP, `http://localhost:4317` for gRPC), `OTEL_EXPORTER_OTLP_PROTOCOL` (default `http/protobuf`; values `grpc`, `http/protobuf`, `http/json`), `OTEL_EXPORTER_OTLP_HEADERS` (`k=v,k2=v2`), `OTEL_EXPORTER_OTLP_COMPRESSION`, `OTEL_EXPORTER_OTLP_TIMEOUT` (10 s), `OTEL_EXPORTER_OTLP_INSECURE`, `OTEL_EXPORTER_OTLP_CERTIFICATE`, `OTEL_EXPORTER_OTLP_CLIENT_KEY`, `OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE`; per-signal variants `OTEL_EXPORTER_OTLP_{TRACES,METRICS,LOGS}_*`; HTTP paths `v1/traces`, `v1/metrics`, `v1/logs` appended to the generic endpoint — [OpenTelemetry: OTLP Exporter configuration](https://opentelemetry.io/docs/specs/otel/protocol/exporter/)

### Inferences
- Values: `otel.enabled`, `otel.endpoint` → `OTEL_EXPORTER_OTLP_ENDPOINT`, `otel.protocol`, `otel.headersSecret` (headers often carry tokens; source from a Secret, never values). `OTEL_SERVICE_NAME`/`OTEL_RESOURCE_ATTRIBUTES` default to the release name/namespace via downward API.
- `metrics.enabled` exposes `/metrics` on the main or a separate port; `metrics.serviceMonitor.{enabled,interval,labels}` renders a `ServiceMonitor` only `if .Capabilities.APIVersions.Has "monitoring.coreos.com/v1"` so `helm template`/install does not fail on clusters without prometheus-operator. (CRD URL: https://prometheus-operator.dev/docs/api-reference/api/ — not fetched in this research.)

### Gaps
- `OTEL_SERVICE_NAME`/`OTEL_RESOURCE_ATTRIBUTES` were not on the fetched exporter page (they live in the SDK environment-variables spec); not verified here.
- No prometheus-operator page fetched.

---

## Key question 8: Distribution — OCI charts on GHCR, cosign signing, helm-docs, chart-testing, helm unittest, kubeconform, Artifact Hub

### Takeaway
Publish the chart as an OCI artifact to `oci://ghcr.io/<org>/charts/<name>` with `helm push`, sign the pushed digest with keyless cosign from GitHub Actions (`id-token: write`), generate the README with helm-docs, lint with `ct lint`/`helm lint --strict`, unit-test with helm-unittest, validate rendered manifests with kubeconform, and register the OCI repository with Artifact Hub (one chart per `oci://` URL, semver tags).

### Cited Findings
- Helm docs recommend OCI registries for distributing charts; `helm registry login <host>`; `helm push <chart>.tgz oci://host/namespace` (name and tag inferred from `Chart.yaml`); `helm pull/show/template/install/upgrade` accept `oci://host/namespace/chart` references; installing by digest (`@sha256:`) is "more secure than tags"; a `.prov` file beside the `.tgz` is pushed automatically; `helm-sigstore` plugin offers Sigstore signing; some registries require the repository to exist before push; page notes it is not yet updated for Helm 4 — [Helm: Registries](https://helm.sh/docs/topics/registries/)
- Artifact Hub OCI charts: URL `oci://registry/namespace/chart-name`, one chart per repository, each version must be a valid semver OCI tag, install instructions shown for Helm 3.7+, `artifacthub-repo.yml` (Verified publisher / ownership) pushed with `oras` under the special tag `artifacthub.io`; cannot force reindex of an existing version by changing its digest — [Artifact Hub: Helm charts repositories](https://artifacthub.io/docs/topics/repositories/helm-charts/)
- GitHub Actions pattern (2026 guides): `helm registry login ghcr.io` with `GITHUB_TOKEN`, `helm push`, capture the digest from the push output, `cosign sign <ref>@<digest>` keyless with `permissions: id-token: write, packages: write`; verify with `cosign verify --certificate-identity-regexp <org workflows> --certificate-oidc-issuer https://token.actions.githubusercontent.com`; Flux can enforce cosign verification on OCI charts; `COSIGN_EXPERIMENTAL=1` is obsolete — [OneUptime: sign and verify Helm charts](https://oneuptime.com/blog/post/2026-01-17-helm-chart-signing-verification/view); [OneUptime: Helm CI/CD with GitHub Actions](https://oneuptime.com/blog/post/2026-01-17-helm-cicd-github-actions/markdown); [OneUptime: verify in Flux](https://oneuptime.com/blog/post/2026-03-05-verify-helm-chart-integrity-flux/markdown); [example repo dirien/signed-helm-chart](https://github.com/dirien/signed-helm-chart)
- helm-docs generates Markdown from `Chart.yaml` + `values.yaml` comments: `# --` description directly above the field, `# @default --` override, `(type)` annotation, `# @ignored`; default template `README.md.gotmpl` with overridable sub-templates (`chart.valuesSectionMd` etc.); pre-commit hooks and Docker image `jnorwood/helm-docs`; `-x` strict mode fails on undocumented values; it does not generate `values.schema.json` — [norwoodj/helm-docs](https://github.com/norwoodj/helm-docs)
- chart-testing (`ct lint --config ct.yaml`, `check-version-increment: true`, GitHub Action `helm/chart-testing-action`), helm-unittest (YAML tests asserting on rendered templates; `--output-type JUnit`), kubeconform (`helm template ... | kubeconform -kubernetes-version 1.29.0 -summary`), and `helm lint --strict` are the common CI layers — [OneUptime: validate Helm charts in CI](https://oneuptime.com/blog/post/2026-02-09-validate-helm-charts-ci/markdown); [OneUptime: unit test Helm charts](https://oneuptime.com/blog/post/2026-02-26-argocd-unit-test-helm-charts/markdown); [coderlegion: chart testing layers](https://coderlegion.com/11555/helm-chart-testing-in-production-layers-tools-and-a-minimum-ci-pipeline)
- Artifact Hub displays a values-schema reference when `values.schema.json` ships in the chart — [Artifact Hub blog](https://blog.artifacthub.io/blog/helm-values-schema-reference/)
- Helm 4 adds reproducible, idempotent chart archives (helps digest stability across rebuilds) — [Helm 4 released](https://helm.sh/blog/helm-4-released)

### Inferences
- Pipeline per tag `vX.Y.Z`: build+push image (multi-arch) → `helm package` with `--version X.Y.Z --app-version vX.Y.Z` → `helm push oci://ghcr.io/<org>/charts` → `cosign sign` image and chart digests → `helm-docs` check (fail if README drift) → `ct lint` + `helm unittest` + `kubeconform` on PRs → optional `ct install` on a `kind` cluster → publish release notes. Tool repos: https://github.com/helm/chart-testing, https://github.com/helm-unittest/helm-unittest, https://github.com/yannh/kubeconform (URLs from general knowledge; content verified only via the secondary sources above).
- Customers install with `helm install hub oci://ghcr.io/<org>/charts/<name> --version X.Y.Z -f values.yaml`; publish verification instructions (`cosign verify ... oci ref@digest`) and the exact `--certificate-identity` of the release workflow.
- A `values.schema.json` is worth publishing: it gives early typo detection, Artifact Hub renders it, and `--skip-schema-validation` exists for edge cases. Generate it from `values.yaml` with a tool such as `helm-schema` (losisin/helm-values-schema-json or dadav/helm-schema) — not researched here; flag as gap.

### Gaps
- Primary-source cosign/GitHub docs were not fetched; the keyless workflow details come from 2026 blog posts and an example repo.
- No primary source checked for `helm-schema` generators.

---

## Key question 9: Docker Compose for production self-hosting in 2026 — spec features, reverse proxy/TLS choice, pinning/upgrades, backups, small-vendor examples

### Takeaway
The Compose spec supports everything the "production profile" needs: `depends_on` with `service_healthy`/`service_completed_successfully`, `healthcheck` with `start_period`/`start_interval`, `restart: unless-stopped`, `profiles`, `secrets`, `include`, and `pull_policy`. Small vendors (Plausible, Umami, Gitea, Infisical) bundle Postgres, rely on healthcheck-gated startup, and either leave TLS to the operator or ship an optional Caddy override; Caddy is the usual low-config choice for automatic HTTPS. Pin image tags to a minor or exact version, and pin Postgres' major.

### Cited Findings
- Compose spec: the top-level `version` field is obsolete ("informative only", warning emitted) — [compose-spec spec.md](https://github.com/compose-spec/compose-spec/blob/main/spec.md)
- `depends_on` long syntax conditions `service_started`, `service_healthy` ("Compose waits for healthchecks to pass"), `service_completed_successfully`; attributes `restart: true` (restart dependents after a dependency update; Compose 2.17+) and `required: false` (warn only; Compose 2.20+). `healthcheck.test` list must start with `NONE`, `CMD` or `CMD-SHELL`; `interval`, `timeout`, `start_period`, `start_interval` (Compose 2.20.2+) are durations; `retries`; `disable: true`. `restart`: `no` (default), `always`, `on-failure[:max-retries]`, `unless-stopped` ("stops restarting when the service is stopped or removed"). `profiles`: unassigned services always start; assigned only when the profile is activated. `pull_policy`: `always`, `never`, `missing` (default), `build`, `daily`, `weekly`, `every_<duration>`. `env_file` supports `required: false` and `format: raw`; `environment` overrides `env_file` — [Compose services reference](https://docs.docker.com/reference/compose-file/services/)
- Plausible CE v3.2.1: `ghcr.io/plausible/community-edition:v3.2.1`, `postgres:16-alpine`, `clickhouse/clickhouse-server:24.12-alpine`; `restart: always` everywhere; `depends_on: condition: service_healthy`; healthchecks with 1-minute `start_period`; no `ports:` in the base file (ports via `compose.override.yml`); `HTTP_PORT=80`/`HTTPS_PORT=443` "enables automatic Let's Encrypt TLS certificate issuance" inside the app; README says clone the repo at tag `v3.2.1`, `.env` with `BASE_URL`, `SECRET_KEY_BASE` (`openssl rand -base64 48`), and that each release's notes carry upgrade steps — [plausible compose v3.2.1](https://raw.githubusercontent.com/plausible/community-edition/v3.2.1/compose.yml); [plausible/community-edition README](https://github.com/plausible/community-edition). Older guide (2024, flagged): "pin the major version instead of using latest", `plausible/analytics:v2.0` allows only patch upgrades, major versions may require a data migration, Caddy via a separate compose override — [umakers/plausible-compose mirror](https://github.com/umakers/plausible-compose)
- Umami: `ghcr.io/umami-software/umami:latest` (floating), `postgres:15-alpine`, `restart: always`, `init: true`, `depends_on: service_healthy`, curl healthcheck on `/api/heartbeat` — [umami compose](https://github.com/umami-software/umami/blob/master/docker-compose.yml)
- Gitea: `docker.gitea.com/gitea:28.3.0` ("For a stable release you can use `:latest`, `:1` or specify a certain release like `:28.3.0`"), `postgres:18`, `restart: always`; upgrade = edit tag, `docker compose pull`, `docker compose up -d` ("automatically removes old one"); "Make sure you have volumed data to somewhere outside Docker container" — [Gitea: Install with Docker](https://docs.gitea.com/installation/install-with-docker)
- Infisical: backend + db + redis; upgrade by changing the image tag then pull/up; verify with `curl /api/status`; HTTPS via an added NGINX service on 80/443 (`proxy_pass http://backend:8080`); `.env` `chmod 600`; "not designed for high-availability production scenarios" — [Infisical Docker Compose](https://www.infisical.com/docs/self-hosting/deployment-options/docker-compose)
- PostHog hobby: no numbered releases; image per commit; install/upgrade shell scripts; recommends Cloud for most users — [PostHog self-host](https://posthog.com/docs/self-host/deploy)
- Caddy automatic HTTPS: on by default for site addresses with hostnames; obtains/renews certificates from Let's Encrypt or ZeroSSL, redirects 80→443; requirements: DNS A/AAAA to the host, ports 80/443 reachable, writable persistent storage; retries with issuer fallback and exponential backoff up to 30 days; on-demand TLS must be restricted with an `ask` endpoint — [Caddy: Automatic HTTPS](https://caddyserver.com/docs/automatic-https)
- Caddy vs Traefik (2026 blogs, opinion): Caddy is the default for small self-hosters wanting HTTPS with minimal config; Traefik wins when adding many services via Docker labels; a geOrchestra PR found the Caddy compose 55 lines vs Traefik 70 for the same result — [dev.to selfhostingsh](https://dev.to/selfhostingsh/traefik-vs-caddy-which-reverse-proxy-51l4); [dev.to byte-guard 2026](https://dev.to/byte-guard/nginx-proxy-manager-vs-traefik-vs-caddy-which-reverse-proxy-should-you-pick-in-2026-gl3); [georchestra/docker PR 268](https://github.com/georchestra/docker/pull/268)
- Backup pattern seen in community runbooks: `pg_dump` pre-hook before a volume snapshot, offsite copy; Gitea+Traefik community compose includes a scheduled `pg_dump` backup container — [VPS runbook](https://vps-runbook.pages.dev/); [heyvaldemar gitea-traefik compose](https://awesome.ecosyste.ms/projects/github.com%2Fheyvaldemar%2Fgitea-traefik-letsencrypt-docker-compose)

### Inferences
- Recommended production Compose layout for this service:
  - `compose.yaml`: `db` (`postgres:17`, named volume, `pg_isready` healthcheck with `start_period: 30s`, `restart: unless-stopped`, password via `POSTGRES_PASSWORD_FILE` secret), `migrate` (same app image, `command: [migrate]`, `restart: "no"`, `depends_on: db: condition: service_healthy`, env `DATABASE_URL` from a privileged URL secret), `hub` (`command: [serve]`, `depends_on: migrate: condition: service_completed_successfully`, `restart: unless-stopped`, `init: true`, `stop_grace_period: 40s`, healthcheck against `/readyz`, app-role URL). Pin `image: ghcr.io/<org>/<app>:X.Y.Z` with the vendor's release tag; recommend customers pin at least the minor.
  - `compose.proxy.yaml` (or `profiles: [proxy]`): `caddy:2` with `Caddyfile` doing `reverse_proxy hub:8080` and automatic HTTPS; volumes for `/data` and `/config`; alternatively document "bring your own proxy" with the one required WebSocket header note. Plausible's precedent (app-native ACME) is not applicable to a service that does not embed ACME; Caddy as an optional override matches Plausible's older Caddy override model.
  - Secrets: Compose `secrets:` with `file:` sources read from `./secrets/*.pem` (`chmod 600`), consumed via `*_FILE` env vars if the binary supports them; otherwise `.env` + `env_file`.
  - Upgrade runbook: `docker compose pull` → `docker compose run --rm migrate` (explicit) → `docker compose up -d` (or simply `up -d` since `migrate` gates `hub`); roll back by re-pinning the previous tag only when release notes say the migration is backward compatible.
  - Backup: `docker compose exec db pg_dump -Fc -U <user> <db> > backup.dump` on a schedule plus volume snapshot; restore with `pg_restore`; back up the PEM secrets alongside (Infisical's `ENCRYPTION_KEY` warning is the analogue).
- `restart: unless-stopped` is preferable to `always` for a service a human sometimes stops deliberately (`always` is what Plausible/Umami/Gitea use; `unless-stopped` is in the spec and avoids auto-restart after an explicit stop).

### Gaps
- Could not fetch the Plausible wiki upgrade/backup pages or the Gitea Backup and Restore page; backup guidance here is from community runbooks and general practice.
- Formbricks, Outline, Hoppscotch Compose files were not retrieved (search returned only a 2024 Formbricks blog).

---

## Key question 10: Versioning and upgrades — communicating breaking changes, `helm upgrade` guides, manual `migrate` for Compose

### Takeaway
Vendors communicate upgrade requirements per release in release notes (Plausible: "each new release contains information on how to upgrade"), use SemVer for the app and chart, flag major versions as needing data migration, and document a fixed upgrade sequence. Use `artifacthub.io/changes` for chart changelogs and a `UPGRADING.md`.

### Cited Findings
- Plausible: release notes carry upgrade steps; major versions "would involve performing a data migration ... or some other extra step"; pin major/minor tags — [Plausible README](https://github.com/plausible/community-edition); [older guide mirror (2024)](https://github.com/umakers/plausible-compose)
- Gitea upgrade: edit tag → `docker compose pull` → `docker compose up -d` — [Gitea docs](https://docs.gitea.com/installation/install-with-docker)
- Infisical upgrade: change tag, pull/up, verify migrations in logs — [Infisical](https://www.infisical.com/docs/self-hosting/deployment-options/docker-compose)
- Keycloak Operator guidance: upgrade the operator in a separate release before changing the application image for major/minor upgrades — [Mia Platform how-to-upgrade](https://docs.mia-platform.eu/docs/requirements/installation-guidelines/shared-services/authn/keycloak/how-to-upgrade)
- Helm: `helm upgrade --install`, `--rollback-on-failure` (Helm 4) / `--atomic` (Helm 3), `--timeout 5m0s` default, `--reset-then-reuse-values` — [Helm 4 helm upgrade](https://helm.sh/docs/helm/helm_upgrade/)
- Helm `Chart.yaml` `deprecated` flag; `kubeVersion` constraint — [Helm: Charts](https://helm.sh/docs/topics/charts/)
- Artifact Hub `artifacthub.io/changes` annotation renders a per-version changelog — [Artifact Hub annotations](https://artifacthub.io/docs/topics/annotations/helm/)
- Helm 3 EOL: bug fixes until 8 July 2026, security fixes until 11 November 2026 — [Helm 4 released](https://helm.sh/blog/helm-4-released)

### Inferences
- State in docs: supported upgrade path (sequential minors, no skipping majors), `helm upgrade --install <release> oci://... --version X.Y.Z -f values.yaml --timeout 15m --rollback-on-failure`, that the hook runs `migrate` automatically, and the manual alternative (`helm upgrade --no-hooks` after `kubectl create job --from=cronjob/...` or a documented `kubectl run ... -- migrate`). For Compose: `docker compose pull && docker compose run --rm migrate && docker compose up -d`.
- Breaking changes: major app version bump, a `BREAKING` section in GitHub release notes, chart major bump when values change incompatibly, `artifacthub.io/changes` entries with `kind: changed/removed`, and a chart `NOTES.txt` that prints the installed appVersion and a link to the upgrade guide.
- Since Helm 3 reaches security EOL in November 2026, require Helm ≥ 3.17 now and target Helm 4 in docs/CI.

### Gaps
- No primary 2026 source on a vendor's formal "N-1 supported upgrade path" policy; this is inferred from common practice.

---

## Key question 11: Licensing, air-gapped installs, image mirroring, `values.schema.json`

### Takeaway
Make every image reference overridable via `global.imageRegistry`/`image.registry` + `image.repository` + `image.tag|digest`, publish the chart as an OCI artifact so `helm pull oci://...` + `helm push` to an internal registry works, and ship `values.schema.json` (Helm documents `--skip-schema-validation` specifically for air-gapped cases).

### Cited Findings
- `helm pull` and `helm push` work with `oci://` references, and classic repositories can be migrated by pull-then-push; installing by digest is recommended as more secure — [Helm: Registries](https://helm.sh/docs/topics/registries/)
- `values.schema.json` validation runs on install/upgrade/lint/template and can be bypassed with `--skip-schema-validation`, "useful in air-gapped environments" — [Helm: Charts](https://helm.sh/docs/topics/charts/)
- Bitnami's own workaround pattern shows the value of per-image `registry/repository` overrides plus a global switch (`global.security.allowInsecureImages`) — [bitnami/charts #35164](https://github.com/bitnami/charts/issues/35164)
- Bitnami chart source remains Apache 2.0 while images moved behind a subscription — illustrates that chart licence and image licence/availability are separate concerns — [bitnami/charts #35164](https://github.com/bitnami/charts/issues/35164)
- Compose `pull_policy: never`/`missing` lets an offline host rely on pre-loaded images — [Compose services reference](https://docs.docker.com/reference/compose-file/services/)

### Inferences
- Air-gapped runbook: `helm pull oci://ghcr.io/<org>/charts/<name> --version X.Y.Z` and `docker pull`/`skopeo copy` the image (and Caddy/Postgres for Compose) into the customer registry; install with `--set global.imageRegistry=registry.corp:5000`; verify cosign signatures offline with a pinned public key or bundle (keyless verification needs Rekor/Fulcio reachability; provide a key-based signature as well, or publish the Sigstore bundle). For Compose, provide `docker save`/`docker load` instructions and `pull_policy: never`.
- Licence: state the chart's licence in `Chart.yaml` annotations (`artifacthub.io/license`) and the `LICENSE` file; keep the chart licence permissive even if the image/app is commercial, as Bitnami does.
- A single image for SaaS and self-hosted means no licence-key gating in the image is required by packaging; if licence enforcement exists it should be an env var/secret like everything else.

### Gaps
- Offline cosign verification specifics (bundles, Rekor offline) were not researched against primary docs.
- No primary source on `global.imageRegistry` as a convention beyond Bitnami's usage.

---

## Consolidated recommendations for the architecture document (summary of inferences above)

1. Helm chart: `helm create`-style skeleton, no library-chart dependency, Helm ≥ 3.17 / 4.x, OCI-only distribution on GHCR, cosign-signed, helm-docs README, `values.schema.json`, `kubeVersion` constraint.
2. Migrations: `pre-install,pre-upgrade` hook Job (`weight -5`, `before-hook-creation,hook-succeeded`, `backoffLimit 0`, `ttlSecondsAfterFinished`), privileged URL from its own Secret, `migrations.enabled/hook` toggles, documented manual path.
3. Secrets: `existingSecret` + documented keys, optional chart-created Secret for quick start, PEM via `stringData`, prefer file mounts and `*_FILE` env vars, `--set-file` for CLI.
4. Database: external Postgres 17 required for Helm; ship a CNPG `Cluster` example; Compose bundles `postgres:17` with pinned major.
5. Networking: Ingress (annotations free-form; ingress-nginx retired March 2026) and optional HTTPRoute with `timeouts` for WebSockets; cert-manager notes for both; `terminationGracePeriodSeconds: 40`, `preStop` sleep, `strategy: Recreate`, PDB off by default.
6. Security: Restricted-PSS-compliant defaults (UID 10001, drop ALL, RuntimeDefault seccomp, no privilege escalation, read-only rootfs), optional NetworkPolicy.
7. Observability: `OTEL_EXPORTER_OTLP_*` passthrough, optional ServiceMonitor guarded by API detection.
8. Compose: `migrate` one-shot service gating `serve` via `service_completed_successfully`, healthchecked Postgres, `restart: unless-stopped`, optional Caddy profile for automatic HTTPS, `secrets:` files, pinned tags, documented `pull → run migrate → up -d` upgrade and `pg_dump` backup.
9. Versioning: SemVer for app and chart, per-release upgrade notes, `artifacthub.io/changes`, major bumps for migrations that are not backward compatible.
10. Air-gap: all images overridable via `global.imageRegistry`, `helm pull`/`push` mirroring, `pull_policy: never` for Compose, key-based signature alongside keyless.

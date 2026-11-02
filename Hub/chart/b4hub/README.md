# b4hub

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.1.0](https://img.shields.io/badge/AppVersion-0.1.0-informational?style=flat-square)

The b4 hub, the sync and relay service for the b4 Personal Agent Workspace, with an external PostgreSQL and a pre-upgrade migration Job.

**Homepage:** <https://b4.run>

## Prerequisites

- Kubernetes 1.29 or newer and Helm 4.
- An external PostgreSQL 17, or the CloudNativePG example below (`examples/cnpg-cluster.yaml`).

## Install

```sh
helm install b4hub oci://ghcr.io/cacheplane/charts/b4hub --version <v> -f values.yaml
```

Each `hub-v<semver>` release publishes the `Chart.yaml` chart version to `oci://ghcr.io/cacheplane/charts/b4hub` alongside the image, with `appVersion` set to that hub version and the chart signed with cosign.

`hub.publicUrl` and `hub.rpId` are required, plus a database Secret (next section). A minimal `values.yaml`:

```yaml
hub:
  publicUrl: https://hub.example.com
  rpId: example.com
database:
  existingSecret: b4hub-db
```

## Database secret contract

Create one Secret with two keys:

- `DATABASE_URL`: the `b4hub_app` role's connection URL. The hub Deployment mounts only this key, at `/etc/b4hub/db/DATABASE_URL`, and reads it through `DATABASE_URL_FILE`.
- `DATABASE_ADMIN_URL`: the owner connection URL. Only the migration Job mounts it.

Key names are overridable with `database.secretKeys`. Pass the Secret as `database.existingSecret`.
`database.urls.url` and `database.urls.adminUrl` make the chart create `<release>-b4hub-db` instead; that is for evaluation only (the values sit in your values file, and the Secret is a hook resource that `helm uninstall` leaves behind). Use `existingSecret` in production.

### CloudNativePG example

`examples/cnpg-cluster.yaml` is a single-instance CloudNativePG `Cluster` named `b4hub-db` (PostgreSQL 17, 10Gi, database `b4hub`, owner `b4hub_owner`). The chart never applies it. The sequence below builds the `b4hub-db` Secret from it; the chart's CI install test runs exactly this sequence (in the `default` namespace) against CloudNativePG 1.30.

- `DATABASE_ADMIN_URL` uses the superuser from the `b4hub-db-superuser` Secret (keys `username` and `password`), which `enableSuperuserAccess: true` creates. `b4hub migrate` creates the `b4hub_app` role, which needs `CREATEROLE`, and CloudNativePG's database owner `b4hub_owner` (in `b4hub-db-app`) does not have it.
- `DATABASE_URL` connects as `b4hub_app` with a password you generate: `b4hub migrate` creates the role, or resets its password, from this URL. The hub refuses to serve as the owner or a superuser.

```sh
kubectl create namespace b4hub
kubectl -n b4hub apply -f examples/cnpg-cluster.yaml
kubectl -n b4hub wait --for=condition=Ready cluster/b4hub-db --timeout=300s

ADMIN_USER=$(kubectl -n b4hub get secret b4hub-db-superuser -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PW=$(kubectl -n b4hub get secret b4hub-db-superuser -o jsonpath='{.data.password}' | base64 -d)
APP_PW=$(openssl rand -hex 24)

kubectl -n b4hub create secret generic b4hub-db \
  --from-literal=DATABASE_URL="postgres://b4hub_app:${APP_PW}@b4hub-db-rw:5432/b4hub" \
  --from-literal=DATABASE_ADMIN_URL="postgres://${ADMIN_USER}:${ADMIN_PW}@b4hub-db-rw:5432/b4hub"
```

Keep `APP_PW` only in the Secret: every `helm upgrade` reruns the migration, which sets the `b4hub_app` password from `DATABASE_URL` again.

## Sign-in secrets

Sign-in needs `B4HUB_SECRET_KEY`, `B4HUB_APPLE_TEAM_ID`, `B4HUB_APPLE_KEY_ID`, and `B4HUB_APPLE_PRIVATE_KEY`. Provide them in an existing Secret with those keys (`secrets.existingSecret`), or let the chart create `<release>-b4hub-secrets` from `secrets.values`, passing the PEM from a file:

```sh
--set-file secrets.values.applePrivateKey=AuthKey_ABC123.p8
```

With neither set, the hub runs without sign-in secrets and the chart renders none.
`secrets.useFileVars: false` (default) exposes them as environment variables from `secretKeyRef`. `true` mounts them at `/etc/b4hub/secrets/<KEY>` and sets `B4HUB_*_FILE` instead; turn it on once the hub reads the `_FILE` forms (M8e).

## Ingress or Gateway

Enable one of the two. Both route to the chart Service (port name `http`).

The proxy must pass or append the client address: the hub trusts the last `X-Forwarded-For` hop while `hub.trustXForwardedFor` (`B4HUB_TRUST_X_FORWARDED_FOR`) is true, so turn that off if your proxy does not append it. The hub holds WebSockets and 25 s long-polls open, so the proxy's read timeout must exceed 25 s.

**Ingress** (`examples/values-ingress.yaml`). The chart assumes no controller-specific annotations; set what your controller needs under `ingress.annotations`:

```yaml
ingress:
  annotations:
    # ingress-nginx style
    # nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    # nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    # Traefik style
    # traefik.ingress.kubernetes.io/router.entrypoints: websecure
```

**Gateway API** (`examples/values-httproute.yaml`). `httpRoute.parentRefs` is passed through verbatim. Gateway API timeouts default to the implementation's; leave `httpRoute.timeouts` unset (no `timeouts` key is rendered) unless you know your Gateway's defaults keep long-polls open.

## Observability

- OTLP: `otel.endpoint` and `otel.protocol` set `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_EXPORTER_OTLP_PROTOCOL` on the hub container (only when non-empty); `otel.extraEnv` appends further `OTEL_*` variables. The chart is passthrough only and adds no SDK configuration. The migration Job gets none of them.
- Metrics: `serviceMonitor.enabled` renders a Prometheus Operator `ServiceMonitor` when the `monitoring.coreos.com/v1` API is installed (otherwise nothing is rendered and the install notes say so). The hub does not expose `/metrics` yet (a later hub milestone); the monitor is wired for when it does. Put your Prometheus selector label (for example `release: prometheus`) in `serviceMonitor.labels`.

## Upgrading

`b4hub migrate` runs as a Job with `helm.sh/hook: pre-install,pre-upgrade` (weight `-5`, delete policy `before-hook-creation,hook-succeeded`, `backoffLimit: 0`). A failed migration fails the release before the Deployment changes, so the old hub keeps running. The Job is named `<fullname>-migrate-<revision>`; a failed one is kept for an hour. Helm does not track hook resources, so read a failure with `kubectl logs -n <namespace> job/<name>` (the install notes print the exact command), fix the cause, and run `helm upgrade` again.

## Uninstall

`helm uninstall b4hub` removes the Deployment, Service, and routes. The evaluation database Secret (`<release>-b4hub-db`, from `database.urls`) is a hook resource and is left behind; delete it yourself with `kubectl delete secret`. Your own `existingSecret`s and the database are never touched.

## Replicas

Keep `replicaCount: 1` and `strategy.type: Recreate`. The relay routes per process until M8e (D-057); the install notes warn when `replicaCount` is above 1. `RollingUpdate` and more replicas are supported after M8e.

## Security

The pods meet the Restricted Pod Security Standard by default: non-root UID/GID 10001, no privilege escalation, all capabilities dropped, `RuntimeDefault` seccomp, a read-only root filesystem with an `emptyDir` at `/tmp`, and no service account token.

## Air-gapped installs

`global.imageRegistry` replaces the registry portion of `image.repository` (`ghcr.io`). `image.digest` pins the image by digest and wins over `image.tag`. `--skip-schema-validation` skips `values.schema.json` if your tooling needs it.

## Requirements

Kubernetes: `>=1.29.0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity for the hub pods. |
| database.existingSecret | string | `""` | Name of an existing Secret holding both database URLs. Required unless both `database.urls` are set. |
| database.secretKeys.adminUrl | string | `"DATABASE_ADMIN_URL"` | Key in the Secret holding the owner (admin) connection URL. Only the migration Job mounts it. |
| database.secretKeys.url | string | `"DATABASE_URL"` | Key in the Secret holding the `b4hub_app` connection URL. The only key the hub Deployment mounts. |
| database.urls.adminUrl | string | `""` | For evaluation only; use `existingSecret` in production. |
| database.urls.url | string | `""` | For evaluation only; use `existingSecret` in production. With `adminUrl`, the chart creates `<release>-b4hub-db`. |
| fullnameOverride | string | `""` | Override the full resource name prefix (default `<release>-b4hub`). |
| global.imageRegistry | string | `""` | Replaces the registry portion of every image reference (`ghcr.io`), for air-gapped mirrors. |
| httpRoute.annotations | object | `{}` | Annotations for the HTTPRoute. |
| httpRoute.enabled | bool | `false` | Render a Gateway API `HTTPRoute` (`gateway.networking.k8s.io/v1`) for the hub. |
| httpRoute.hostnames | list | `[]` | Hostnames the route matches. |
| httpRoute.parentRefs | list | `[]` | Gateway API `ParentReference` objects, passed through verbatim. |
| httpRoute.timeouts | string | `nil` | Optional `{request, backendRequest}` rule timeouts. Leave unset (`null`): the hub holds WebSockets and 25 s long-polls open, so the route must not add a default timeout. |
| hub.apple.audiences | list | `[]` | Apple token audiences (`B4HUB_APPLE_AUDIENCES`, joined with commas); rendered only when set. |
| hub.apple.servicesId | string | `""` | Apple Services ID for web sign-in (`B4HUB_APPLE_SERVICES_ID`); rendered only when set. |
| hub.extraEnv | list | `[]` | Extra `EnvVar` entries appended verbatim to the hub container (for example `OTEL_EXPORTER_OTLP_*`). |
| hub.log | string | `"info"` | Tracing filter (`B4HUB_LOG`). |
| hub.publicUrl | string | `""` | Required. The URL clients reach the hub at (`B4HUB_PUBLIC_URL`). |
| hub.retentionDays | int | `30` | Days the change log is kept (`B4HUB_RETENTION_DAYS`). |
| hub.rpId | string | `""` | Required. The WebAuthn relying party id, a registrable domain (`B4HUB_WEBAUTHN_RP_ID`). |
| hub.signup | string | `"closed"` | `open` or `closed` (`B4HUB_SIGNUP`). |
| hub.trustXForwardedFor | bool | `true` | Trust the last `X-Forwarded-For` hop for the client address. Correct only if your proxy appends the client address. |
| image.digest | string | `""` | Image digest (`sha256:...`). When set it wins over `tag` and the image is pulled as `repository@digest`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/cacheplane/b4hub"` | The hub image. One image serves both `serve` and `migrate`. |
| image.tag | string | `""` | Image tag; defaults to the chart's `appVersion`. |
| imagePullSecrets | list | `[]` | Pull secrets for a private registry or mirror. |
| ingress.annotations | object | `{}` | Free-form Ingress annotations. No controller-specific annotations are assumed (see the README for examples). |
| ingress.className | string | `""` | `ingressClassName`; omitted when empty. |
| ingress.enabled | bool | `false` | Render a `networking.k8s.io/v1` Ingress for the hub. |
| ingress.host | string | `""` | Host the rule matches. Usually the host of `hub.publicUrl`. |
| ingress.path | string | `"/"` | Path routed to the hub. |
| ingress.pathType | string | `"Prefix"` | `Prefix`, `Exact`, or `ImplementationSpecific`. |
| ingress.tls | list | `[]` | TLS entries (`secretName`, `hosts`), passed through. |
| migrate.activeDeadlineSeconds | int | `600` | Deadline for the migration Job. |
| migrate.enabled | bool | `true` | Run `b4hub migrate` as a pre-install and pre-upgrade hook Job. |
| migrate.resources | object | `{}` | Resources for the migration container. |
| nameOverride | string | `""` | Override the chart name used in resource names. |
| nodeSelector | object | `{}` | Node selector for the hub and migration pods. |
| otel.endpoint | string | `""` | `OTEL_EXPORTER_OTLP_ENDPOINT` for the hub; the env var is set only when this is non-empty. |
| otel.extraEnv | list | `[]` | Extra `EnvVar` entries appended after the OTLP variables (for example `OTEL_SERVICE_NAME`). |
| otel.protocol | string | `""` | `OTEL_EXPORTER_OTLP_PROTOCOL` (`grpc`, `http/protobuf`, `http/json`); set only when non-empty. |
| podAnnotations | object | `{}` | Annotations for the hub pods. |
| podSecurityContext | object | `{"fsGroup":10001,"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context (Restricted Pod Security Standard). |
| preStopSleepSeconds | int | `5` | `preStop` sleep so endpoint removal propagates before SIGTERM. |
| replicaCount | int | `1` | Hub replicas. Keep 1: the relay routes per process until M8e (D-057). |
| resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"100m","memory":"128Mi"}}` | Hub container resources. |
| secrets.existingSecret | string | `""` | Existing Secret with keys `B4HUB_SECRET_KEY`, `B4HUB_APPLE_TEAM_ID`, `B4HUB_APPLE_KEY_ID`, `B4HUB_APPLE_PRIVATE_KEY`. |
| secrets.useFileVars | bool | `false` | `false`: env from `secretKeyRef`. `true`: mount at `/etc/b4hub/secrets/` and set `B4HUB_*_FILE` (needs a hub with the `_FILE` forms, M8e). |
| secrets.values | object | `{"appleKeyId":"","applePrivateKey":"","appleTeamId":"","secretKey":""}` | Chart-created `<release>-b4hub-secrets` when `existingSecret` is empty. Pass the PEM with `--set-file secrets.values.applePrivateKey=AuthKey.p8`. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context (Restricted Pod Security Standard). `/tmp` is an `emptyDir`. |
| service.port | int | `80` | Service port in front of the hub's `http` port (8080). |
| serviceAccount.annotations | object | `{}` | Annotations for the ServiceAccount. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount for the hub. |
| serviceAccount.name | string | `""` | Name of the ServiceAccount (default: the full name when `create`, else `default`). |
| serviceMonitor.enabled | bool | `false` | Render a Prometheus Operator `ServiceMonitor` (only when the `monitoring.coreos.com/v1` API is installed). The hub does not expose `/metrics` yet. |
| serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| serviceMonitor.labels | object | `{}` | Extra labels on the ServiceMonitor, for Prometheus operator selection (for example `release: prometheus`). |
| serviceMonitor.path | string | `"/metrics"` | Metrics path. |
| strategy.type | string | `"Recreate"` | `Recreate` (default) or `RollingUpdate`. `RollingUpdate` and `replicaCount > 1` are supported after M8e (D-057). |
| terminationGracePeriodSeconds | int | `45` | Seconds Kubernetes waits after SIGTERM. The hub drains open long-polls for up to 30 s. |
| tolerations | list | `[]` | Tolerations for the hub and migration pods. |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)

# b4hub

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.1.0](https://img.shields.io/badge/AppVersion-0.1.0-informational?style=flat-square)

The b4 hub, the sync and relay service for the b4 Personal Agent Workspace, with an external PostgreSQL and a pre-upgrade migration Job.

**Homepage:** <https://b4.run>

## Before you install

The hub needs an external PostgreSQL. Create one Secret with two keys:

- `DATABASE_URL`: the `b4hub_app` role's connection URL. The hub Deployment mounts only this key, at `/etc/b4hub/db/DATABASE_URL`, and reads it through `DATABASE_URL_FILE`.
- `DATABASE_ADMIN_URL`: the owner connection URL. Only the migration Job mounts it.

Key names are overridable with `database.secretKeys`. Pass the Secret as `database.existingSecret`.
`database.urls.url` and `database.urls.adminUrl` make the chart create `<release>-b4hub-db` instead; that is for evaluation only (the values sit in your values file, and the Secret is a hook resource that `helm uninstall` leaves behind). Use `existingSecret` in production.

`hub.publicUrl` and `hub.rpId` are required.

```sh
helm install hub oci://ghcr.io/cacheplane/charts/b4hub \
  --namespace b4hub --create-namespace \
  --set database.existingSecret=b4hub-db \
  --set hub.publicUrl=https://hub.example.com \
  --set hub.rpId=example.com
```

## Migrations

`b4hub migrate` runs as a Job with `helm.sh/hook: pre-install,pre-upgrade` (weight `-5`, delete policy `before-hook-creation,hook-succeeded`, `backoffLimit: 0`). A failed migration fails the release before the Deployment changes. The Job is named `<fullname>-migrate-<revision>`; a failed one is kept for an hour. Helm does not track hook resources, so read a failure with `kubectl logs job/<name>` (the install notes print the exact command).

## Sign-in secrets

Sign-in needs `B4HUB_SECRET_KEY`, `B4HUB_APPLE_TEAM_ID`, `B4HUB_APPLE_KEY_ID`, and `B4HUB_APPLE_PRIVATE_KEY`. Provide them in an existing Secret with those keys (`secrets.existingSecret`), or let the chart create `<release>-b4hub-secrets` from `secrets.values`, passing the PEM from a file:

```sh
--set-file secrets.values.applePrivateKey=AuthKey_ABC123.p8
```

With neither set, the hub runs without sign-in secrets and the chart renders none.
`secrets.useFileVars: false` (default) exposes them as environment variables from `secretKeyRef`. `true` mounts them at `/etc/b4hub/secrets/<KEY>` and sets `B4HUB_*_FILE` instead; turn it on once the hub reads the `_FILE` forms (M8e).

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
| migrate.activeDeadlineSeconds | int | `600` | Deadline for the migration Job. |
| migrate.enabled | bool | `true` | Run `b4hub migrate` as a pre-install and pre-upgrade hook Job. |
| migrate.resources | object | `{}` | Resources for the migration container. |
| nameOverride | string | `""` | Override the chart name used in resource names. |
| nodeSelector | object | `{}` | Node selector for the hub and migration pods. |
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
| strategy.type | string | `"Recreate"` | `Recreate` (default) or `RollingUpdate`. `RollingUpdate` and `replicaCount > 1` are supported after M8e (D-057). |
| terminationGracePeriodSeconds | int | `45` | Seconds Kubernetes waits after SIGTERM. The hub drains open long-polls for up to 30 s. |
| tolerations | list | `[]` | Tolerations for the hub and migration pods. |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)

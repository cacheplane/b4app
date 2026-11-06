## 2026-11-05: Compose with public TLS on a clean Linux VM

Gate 8a passed at **2026-11-06 00:24:54 UTC (November 5, 16:24 Pacific)**. The unchanged self-hosting Compose files booted the released hub on a new Ubuntu VM with an empty database, completed migrations, and served `/readyz` through Caddy with a publicly trusted certificate. The repository smoke test also passed on that VM before the separate TLS stack was created.

### Host and inputs

- Disposable AWS test-account VM: account `355069727528`, region `us-east-2`, instance `i-0c8640946ae7fc985`, name `b4hub-gate8a-20261106002107`, launched at 2026-11-06 00:21:18 UTC. No production deployment or database was used.
- Canonical Ubuntu 24.04 ARM64 AMI `ami-0a181443b98d26302` (owner `099720109477`, image `ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-20261023`), `t4g.small`. The running OS identified itself as Ubuntu 24.04.5 LTS, `aarch64`.
- Bootstrap explicitly required both the Docker executable and `/var/lib/docker` to be absent, then installed Docker and Compose from Ubuntu's packages. Actual versions: Docker Engine 29.1.3; Compose `2.40.3+ds1-0ubuntu1~24.04.1`.
- IMDSv2 required, no instance IAM role, encrypted 20 GiB gp3 root disk with delete-on-termination. Temporary security group allowed SSH only from the operator's current `/32`, and public TCP 80/443 for ACME and HTTPS. Neither PostgreSQL nor the hub's port 8080 was published.
- Deployment files copied unchanged from commit `253b6e79d4532a0e4eaa5e008f5d8048fe2eb247`: `Hub/deploy/compose/compose.yaml`, `compose.local.yaml`, `Caddyfile`, `test.sh`, and `.env.example`.
- Released hub `hub-v0.5.0`, pinned with `B4HUB_IMAGE=ghcr.io/cacheplane/b4hub@sha256:73839754db09bfbb9701b2df10c465c73fc45357f9bd7d1c121ecfc4432decfd`. The pulled image reported architecture `arm64`. `B4HUB_VERSION` was set to `unused-when-B4HUB_IMAGE-is-set` as in the smoke script.
- TLS profile dependencies resolved to Caddy 2.11.9 (`caddy@sha256:b060aafbec4f8f5404c80273c8d8758248f157920d0a0cdd5cb5656a527f6ec5`) and PostgreSQL 17.11 (`postgres@sha256:748a18a54d3842d43bc156f0840d78029b8d349e0feca98c12b9c4ce3404a6b3`). These were the repository's `caddy:2` and `postgres:17` tags at test time.

### First boot and TLS evidence

First, `bash test.sh <pinned-image>` ran against a fresh scratch database with the loopback overlay. It reported:

```text
readyz: {"instances":"ok","migrations":"current","minClientProtocol":1,"ok":true,"relay":"ok"}
migrate: migrate exited 0
compose smoke test passed
```

The script also passed its serving-container environment checks (file-based application URL and key, no admin URL or raw secret key), migration-container key exclusion, and loopback-only binding assertion. Its cleanup removed all smoke containers, the database volume and its network.

A separate private directory then received `compose.yaml` and `Caddyfile`, new random database passwords and a new 32-byte application key generated on the VM according to the self-hosting README. Only file references entered container environments. The TLS stack used new database and Caddy volumes, not the smoke test's database. Nonsecret configuration was:

```dotenv
B4HUB_PUBLIC_URL=https://compose-gate-20261106.b4.run
B4HUB_WEBAUTHN_RP_ID=compose-gate-20261106.b4.run
B4HUB_SIGNUP=closed
CADDY_HOSTNAME=compose-gate-20261106.b4.run
```

Temporary Vercel A record `rec_f923b41b259dd40a935de0b9` pointed that hostname to `3.142.199.166`. Both the authoritative nameserver and public resolver `1.1.1.1` returned that address before startup. The documented `docker compose --profile tls up -d` was run with `--wait --wait-timeout 180` added to await readiness.

| Check | Observed result |
| --- | --- |
| Fresh migration | `migrated: 16 applied, 0 pending`; one-shot `migrate` exited 0. |
| Container readiness | Database and hub healthy; Caddy running; migration exited 0. |
| HTTP request from outside the VM | `HTTP/1.1 308 Permanent Redirect`, `Location: https://compose-gate-20261106.b4.run/readyz`. |
| Public HTTPS request | `HTTP/2 200`, `content-type: application/json`, `via: 1.1 Caddy`; curl reported `ssl_verify_result=0`, connected to `3.142.199.166`, with normal CA and hostname validation and no insecure override. |
| HTTPS response body | `{"instances":"ok","migrations":"current","minClientProtocol":1,"ok":true,"relay":"ok"}`. |
| Serving secret boundary | Application URL and key used `_FILE`; no `DATABASE_ADMIN_URL*` or raw `B4HUB_SECRET_KEY` in the serving environment. Hub mounted only `/run/secrets/database_url` and `/run/secrets/secret_key`, both read-only. |
| Migration secret boundary | No `B4HUB_SECRET_KEY*`; only the admin and application database URL secret files mounted, both read-only. |
| Container isolation | Hub and migration root filesystems read-only. Hub, migration and database had empty host port bindings; only Caddy published TCP 80/443. |

Caddy's production Let's Encrypt ACME endpoint completed a `tls-alpn-01` challenge, finalized authorization as `valid`, and logged `certificate obtained successfully`. The served leaf certificate was:

- Subject and SAN: `compose-gate-20261106.b4.run`.
- Issuer: Let's Encrypt `YE2`.
- Validity: 2026-11-05 23:26:22 UTC through 2027-02-03 23:26:21 UTC.
- SHA-256 fingerprint: `D6:0B:2A:9F:94:84:5F:5B:E1:A1:11:0D:A5:CC:BB:FA:B1:FB:39:01:06:75:67:F0:86:67:3C:E5:BE:11:B1:77`.

### Cleanup and scope

At 2026-11-06 00:26:07 UTC, `docker compose --profile tls down -v --remove-orphans` had removed the TLS containers, all three volumes and the network; subsequent counts were zero containers, zero volumes and zero Compose networks. The generated secret files and `.env` were removed. The temporary DNS record was deleted and verified absent from the DNS inventory.

AWS cleanup was independently verified at 2026-11-06 00:28:00 UTC: instance `i-0c8640946ae7fc985` was `terminated`; root disk `vol-07cf58314c7478dab`, security group `sg-0ba4ad3176f8a2556` and key pair `b4hub-gate8a-20261106002107-ssh` were absent. The local disposable SSH private key was deleted. No temporary VM, disk, security group, key pair or DNS record remains.

This gate covers ARM64 Linux first boot, migrations, secret-file isolation and public TLS readiness. It does not exercise account enrollment, a relayed turn, certificate renewal after expiry, or Compose upgrades and backup/restore. No shipped deployment or application configuration needed a fix.

Documentation validation: `Scripts/docs-index.sh --check`, `git diff --check`, and `swift format lint --strict --recursive Sources Tests Apps Package.swift`.

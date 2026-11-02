# Self-hosting the hub with Docker Compose

PostgreSQL, a one-shot `migrate` step, the hub, and an optional Caddy that gets a TLS certificate for you. Nothing is published to the network unless you choose `--profile tls` (ports 80 and 443) or the loopback overlay below.

## Install

Docker Engine with Compose v2 (`docker compose version`). Then, from this directory:

```bash
cd Hub/deploy/compose
cp .env.example .env
```

Edit `.env`: set `B4HUB_VERSION` (a released tag or `sha-<commit>`), `B4HUB_PUBLIC_URL`, `B4HUB_WEBAUTHN_RP_ID` (the hostname), and `CADDY_HOSTNAME` if you use Caddy. `B4HUB_SIGNUP=closed` means only users you seed can enroll.

## Secrets

Secrets are files, not environment variables. Generate two passwords and write the three files; the two URLs must carry the passwords below, and the app password is the one `migrate` gives the `b4hub_app` role.

```bash
mkdir -p secrets && chmod 700 secrets
pg="$(openssl rand -hex 24)"; app="$(openssl rand -hex 24)"
printf '%s' "$pg" > secrets/postgres_password
printf 'postgres://postgres:%s@db:5432/b4hub' "$pg" > secrets/database_admin_url
printf 'postgres://b4hub_app:%s@db:5432/b4hub' "$app" > secrets/database_url
chmod 644 secrets/*
```

The directory is private to your user; the files are world-readable only so the containers (other uids) can read them. `secrets/*` is git-ignored. Only `migrate` mounts the admin URL; `hub` never sees it. The passwords are fixed once the database is first created: changing `postgres_password` later does not change the existing database's password.

## First run

With Caddy (DNS for `CADDY_HOSTNAME` must point at this host; ports 80 and 443 must be reachable):

```bash
docker compose --profile tls up -d
```

Without TLS here (you terminate TLS elsewhere on the same host): the hub is published on `127.0.0.1:8080` only, via an overlay so the `hub` service stays unpublished by default.

```bash
docker compose -f compose.yaml -f compose.local.yaml up -d
```

(or set `COMPOSE_FILE=compose.yaml:compose.local.yaml` in `.env`.) The overlay is plain HTTP on loopback; clients refuse plain HTTP for any host but `localhost`, so put a TLS proxy in front.

Verify:

```bash
docker compose ps
curl -fsS https://hub.example.com/readyz     # or http://127.0.0.1:8080/readyz with the overlay
```

`/readyz` answers 200 with `minClientProtocol` once migrations are applied. Create the first user and enroll a device (these run through `migrate`, the only service with the admin URL):

```bash
docker compose run --rm migrate seed --org acme --org-name Acme --user you --name "Your Name" --email you@example.com
docker compose run --rm migrate enroll --user you
```

## Your own proxy

`B4HUB_TRUST_X_FORWARDED_FOR=1` is set because the bundled Caddy appends the real client address to `X-Forwarded-For`. If you front the hub with another proxy it must append the same way (never pass a client-supplied header through unchanged), or rate limits and audit addresses can be spoofed. Proxy to `hub:8080` on the Compose network, or to `127.0.0.1:8080` with the overlay.

## Upgrade

Change `B4HUB_VERSION` in `.env`, then:

```bash
docker compose pull && docker compose run --rm migrate && docker compose up -d
```

(add `--profile tls` to `pull` and `up` when you use Caddy). Migrations run before the new hub starts; `up` also re-runs `migrate` as a gate. The PostgreSQL major is pinned to 17 in `compose.yaml`; do not change it without a dump and restore.

## Backup and restore

```bash
docker compose exec db pg_dump -Fc -U postgres b4hub > b4hub-$(date +%F).dump
```

Back up the `secrets/` directory with it; a dump is useless without the passwords the URLs carry (and the `b4hub_app` role is recreated by `migrate`).

Restore outline: bring up an empty stack (`docker compose up -d db`), then
`docker compose exec -T db pg_restore -U postgres -d b4hub --clean --if-exists < b4hub-DATE.dump`,
run `docker compose run --rm migrate` to recreate the app role and grants, and `docker compose up -d`.

## Smoke test

`./test.sh <image-ref>` brings the stack up in a scratch directory with random secrets and checks `/readyz`, the `migrate` exit code, and that `hub` has no admin URL. CI runs it against each built image.

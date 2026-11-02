# Managed container hosts for a single small Rust HTTP service (hub.b4.run / hub.test.b4.run), as of late 2026

Research date: 2026-11-01. All "read" dates are 2026-11-01 unless noted. Facts older than 2025 are marked "(pre-2025)". Google Cloud and Cloudflare were excluded per the brief; note that Render and DigitalOcean App Platform both front their edges with Cloudflare (see Headers), which the owner may consider relevant.

Workload recap used for evaluation: one Docker image, ~100-300 MB RAM, port 8080, long-lived WebSockets with a 10 s heartbeat, 25 s HTTP long-polls, 35 s drain after SIGTERM, exactly one instance per environment (brief two-instance overlap during deploy tolerable if documented), env-var config including a multi-line PEM, rate limiting keyed on the right-most X-Forwarded-For entry, inbound form POST from Apple, outbound HTTPS only to appleid.apple.com, external PostgreSQL, CNAME custom domains from a Vercel-hosted DNS zone with automatic TLS.

## Scope note: two candidates are effectively out

### Takeaway
AWS App Runner is closed to new customers (AWS now points new users at ECS Express Mode), and Heroku's fixed 30 s SIGTERM window is below the 35 s drain requirement. Both are still documented below for completeness, but neither should be a finalist.

### Cited Findings
- "After careful consideration, we decided to close AWS App Runner to new customers. Existing AWS App Runner customers can continue to use the service as normal ... we do not plan to introduce new features." AWS recommends Amazon ECS Express Mode instead — [AWS App Runner availability change](https://docs.aws.amazon.com/apprunner/latest/dg/apprunner-availability-change.html)
- Heroku: "The application processes have 30 seconds to shut down cleanly"; after 30 s the dyno manager sends SIGKILL (error R12). No configuration knob is documented — [Heroku Dev Center: Dyno shutdown behavior](https://devcenter.heroku.com/articles/dyno-shutdown-behavior)
- Heroku's Fir generation does not support the `container` stack ("apps that rely on the container stack can't be migrated to Fir"), and Common Runtime on Fir is "To Be Added" — [Heroku Dev Center: Generations](https://devcenter.heroku.com/articles/generations)
- AWS Copilot CLI reached end of support on June 12, 2026; AWS recommends ECS Express Mode or CDK — [AWS Containers Blog via search](https://aws.amazon.com/jp/blogs/containers/announcing-the-end-of-support-for-the-aws-copilot-cli/); corroborated by [re:Post thread](https://repost.aws/questions/QUhwTcfq40RMKq16Ju5oFxUg/aws-copilot-cli-deprecation-update)

### Inferences
- The realistic shortlist is Fly.io, Render, Railway, DigitalOcean App Platform, and ECS on Fargate (hand-rolled or via ECS Express Mode). Lightsail Containers is cheap but its documented 60 s idle timeout and lack of a configurable shutdown grace make it a poor fit for long-lived connections.

### Gaps
- None for this section.

## WebSocket support, connection lifetime, HTTP idle timeouts (25 s long-polls and multi-minute WebSockets)

### Takeaway
Every finalist proxies WebSockets; the 10 s heartbeat keeps them alive on all of them. The 25 s long-poll fits under every documented idle timeout (shortest: 60 s on Fly, ALB default, Lightsail). Railway is the only platform that documents an explicit WebSocket exemption from duration limits; Render documents "no maximum duration"; Fly's 60 s idle rule is community-documented and resets on any traffic.

### Cited Findings
**Fly.io**
- Fly's config reference lists `http_options.idle_timeout` ("Configure an idle-timeout for connections to your app", example value 600) but states no default or maximum; the page does not mention WebSockets — [docs.fly.io configuration reference](https://docs.fly.io/reference/configuration)
- Community threads (2019–2024, staff replies): "60s is our timeout for connections. If nothing in or out has been sent or received through them for 60s, then we close them"; any data resets the timer; staff advised app-level pings and reconnection logic — [community.fly.io: Request timeouts](https://community.fly.io/t/request-timeouts-on-fly-io/5653); [community.fly.io: Increasing idle timeout](https://community.fly.io/t/increasing-idle-timeout/2619); [community.fly.io: websockets](https://community.fly.io/t/websockets/25827)
- Fly Proxy's HTTP handler normalizes inbound connections to HTTP/1.1 toward the app; `h2_backend = true` enables h2c — [docs.fly.io networking/services](https://docs.fly.io/networking/services)

**Render**
- "Render does not enforce a maximum duration for WebSocket connections"; no limit on open connections per service; load balancer assigns each new connection to a random instance; use `wss://` because `ws://` hits a 301 redirect — [Render docs: WebSockets](https://render.com/docs/websocket)
- Render's load balancer terminates TLS and forwards HTTP to one port (default 10000) — [Render docs: Web services](https://render.com/docs/web-services)

**Railway**
- "Idle HTTP/1.1 connections close after 60 seconds without a new request. This doesn't apply to HTTP/2 or WebSockets." A request may run up to 15 minutes if data keeps flowing, otherwise closes after 5 minutes idle. WebSockets "are exempt from the duration and inactivity limits, so they can stay open indefinitely, even while idle." Max 10,000 concurrent connections per domain, ~11,000 req/s, 32 KB header limit — [docs.railway.com specs and limits](https://docs.railway.com/networking/public-networking/specs-and-limits)
- Railway staff (community): the 900 s HTTP limit is the maximum and not raisable per service — [Railway Station](https://station.railway.com/questions/can-the-900-second-http-request-timeout-ff86a21d)

**DigitalOcean App Platform**
- "We do not limit the number of concurrent connections to your app"; HTTP/2 and HTTP/3 negotiated at the edge, downgraded to HTTP/1.1 to the container unless configured — [DO App Platform limits](https://docs.digitalocean.com/products/app-platform/details/limits/)
- DO publishes a WebSocket deployment tutorial (Node `ws`); service must be a "service" component, not a worker — [DO tutorial: deploy WebSockets](https://docs.digitalocean.com/tutorials/app-deploy-websockets/)
- No official idle-timeout figure found; community reports of idle WebSocket drops at ~1–2 min and ~5 min — [DO community Q](https://www.digitalocean.com/community/questions/websocket-idle-connection-timeout-on-app-platform); [DO community Q](https://www.digitalocean.com/community/questions/server-cannot-send-messages-through-websocket-connection-after-5-minutes)

**AWS ECS on Fargate (ALB)**
- ALB `idle_timeout.timeout_seconds` default 60 s; `client_keep_alive.seconds` default 3600 — [ALB docs: load balancer attributes](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/application-load-balancers.html)
- "WebSocket connections are inherently sticky"; the target that returns 101 handles the connection — [ALB target group attributes](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-target-group-attributes.html)

**AWS App Runner (closed to new customers)**
- Total request timeout 120 s including reading the body and writing the response — [App Runner: Developing application code](https://docs.aws.amazon.com/apprunner/latest/dg/develop.html) (via search); a 2021 Stack Overflow answer (pre-2025) reported no WebSocket support — [archived SO thread](https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/70414143/does-aws-app-runner-properly-support-websocket-connections)

**AWS Lightsail Containers**
- Public endpoint "supports HTTPS only, and it does not support TCP or UDP traffic" — [Lightsail container services](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-container-services.html)
- re:Post thread (undated) says the proxy behind Lightsail public endpoints enforces a 60 s idle timeout that cannot be changed — [re:Post](https://repost.aws/es/questions/QUGKnxvr6yThaUwqTg03fHbA/aws-lightsail-container-nginx-setup-timeout) (fetch returned 403; summary from search snippet only)

**Heroku**
- 30 s to first byte (H12), then a 55 s rolling window reset by any byte in either direction (H15/H28); "WebSocket functionality is supported for all applications"; "the normal Heroku HTTP routing timeout rules apply to WebSocket connections" — [Heroku HTTP routing](https://devcenter.heroku.com/articles/http-routing); [Heroku WebSockets](https://devcenter.heroku.com/articles/websockets)

### Inferences
- With a 10 s server heartbeat, every platform's idle timer (60 s Fly/ALB/Lightsail, 55 s Heroku) is never reached, so multi-minute WebSockets survive everywhere that supports upgrades. The 25 s long-poll is below every documented idle timeout as long as the service does not buffer beyond ~55 s.
- Lightsail's HTTPS-only endpoint plus a 60 s idle timeout should still pass WebSockets with a 10 s heartbeat, but nothing in AWS docs confirms Upgrade support; treat as unverified.

### Gaps
- No official Fly document stating the 60 s idle default or the max for `idle_timeout`; only community posts.
- No official DigitalOcean document stating an idle timeout for App Platform.
- No official AWS statement on WebSocket support for Lightsail container services.

## Graceful shutdown (>= 35 s SIGTERM grace), deploy strategy, single-instance-at-a-time, downtime per deploy

### Takeaway
Fly (`kill_timeout` up to 300 s), Render (`maxShutdownDelaySeconds` up to 300 s), Railway (`RAILWAY_DEPLOYMENT_DRAINING_SECONDS`, "a few hours"), DigitalOcean (`grace_period_seconds` default 120, max 600), and ECS (`stopTimeout` max 120 s) all satisfy 35 s; Heroku's fixed 30 s does not. Only ECS lets you choose precisely between replace-in-place (downtime, never two instances) and overlap; Render, Railway, and DO always overlap briefly by default; Fly's rolling strategy on one Machine is not clearly documented.

### Cited Findings
**Fly.io**
- `kill_timeout` default 5 s, "up to a maximum of 300 seconds"; default signal is SIGINT, overridable to SIGTERM via `kill_signal`; after the timeout Fly sends SIGTERM/kill. Strategies: `rolling` (default), `immediate`, `canary`, `bluegreen`; "If max-per-region is set to 1, then the default strategy is set to rolling"; bluegreen needs at least one health check; canary/bluegreen cannot be used with volumes — [docs.fly.io configuration reference](https://docs.fly.io/reference/configuration)
- bluegreen "boots a new Machine alongside each running Machine in the same region. Traffic moves to the new Machines only after they all pass health checks"; rolling "wait[s] for each Machine to be successfully deployed before starting the update of the next one"; first deploy creates "two Machines for redundancy" when no process groups are defined — [docs.fly.io launch/deploy](https://docs.fly.io/launch/deploy)
- Community: canary cannot be used with `max_per_region`; "rolling is the only deploy strat that works when max-per-region is set" — [community.fly.io](https://community.fly.io/t/rolling-deployment-details/24820)
- Restart policy: default for `fly deploy` Machines is `on-failure` with `max_retries` 10 in a 5-minute window; `always` and `no` available — [docs.fly.io machine restart policy](https://docs.fly.io/machines/guides-examples/machine-restart-policy)

**Render**
- Zero-downtime deploy: new instance starts while the old keeps all traffic; after health checks pass, traffic switches; "Render sends it SIGTERM 60 seconds after the switch, then SIGKILL if it hasn't exited within its shutdown delay." Shutdown delay default 30 s, max 300 s via `maxShutdownDelaySeconds` (render.yaml or Update service API); longer requires support; disabled for services with persistent disks — [Render docs: Deploys](https://render.com/docs/deploys)
- Health checks: new instances get traffic only when all pass; 15-minute cutoff cancels the deploy; running instances are pulled from routing after 15 s of consecutive failures and restarted after 60 s — [Render docs: Health checks](https://render.com/docs/health-checks)

**Railway**
- "Once the new deployment is online, the old one receives SIGTERM. By default it gets 0 seconds to shut down before SIGKILL." Drain time via `RAILWAY_DEPLOYMENT_DRAINING_SECONDS`; `RAILWAY_DEPLOYMENT_OVERLAP_SECONDS` controls how long the previous deployment stays after the new one is Active; singleton deploys are the default — [docs.railway.com deployments](https://docs.railway.com/reference/deployments)
- Railway staff (brody, 2025-01-17) on the maximum draining value: "I don't have an exact time, so I'm safely saying a few hours" — [Railway Station](https://station.railway.com/questions/what-is-the-max-permitted-value-for-rail-8fa552fc)
- Healthcheck timeout default 300 s; new deployment becomes active only after 2xx; "For services with attached volumes, redeploys cause brief downtime even when a healthcheck is configured"; the endpoint is "not used for continuous monitoring" — [docs.railway.com healthchecks](https://docs.railway.com/reference/healthchecks)

**DigitalOcean App Platform**
- `termination.drain_seconds` default 15, max 110 (delay between selection and SIGTERM, during which upstream LBs drain new requests); `termination.grace_period_seconds` default 120, max 600 (SIGTERM to SIGKILL); page last verified 17 Apr 2025 — [DO: Configure termination](https://docs.digitalocean.com/products/app-platform/how-to/configure-termination/); same fields in the [App Spec reference](https://docs.digitalocean.com/products/app-platform/reference/app-spec/)
- `liveness_health_check` failure restarts the component; `health_check` gates readiness (defaults: period 10 s, timeout 1 s, failure_threshold 9) — [App Spec reference](https://docs.digitalocean.com/products/app-platform/reference/app-spec/)
- Rollback to any of the ten most recent successful deployments via console or `POST /v2/apps/{app_id}/rollback` — [DO: Manage deployments](https://docs.digitalocean.com/products/app-platform/how-to/manage-deployments/)

**AWS ECS on Fargate**
- `stopTimeout`: "If the parameter isn't specified, then the default value of 30 seconds is used. The maximum value is 120 seconds." — [ECS task definition parameters (Fargate)](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html)
- Rolling update: `minimumHealthyPercent` default 100%, `maximumPercent` default 200% (start new before stopping old); setting e.g. `minimumHealthyPercent` 50 / `maximumPercent` 100 stops existing tasks first to free capacity. ECS controller supports rolling, blue/green, linear, canary — [ECS service definition parameters](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service_definition_parameters.html)
- ALB deregistration delay default 300 s; completes immediately if no in-flight requests/active connections; "If a deregistering target terminates the connection before the deregistration delay elapses, the client receives a 500-level error response" — [ALB target group attributes](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-target-group-attributes.html)
- ECS Express Mode services come with "5XX Rollback Alarms and Canary Deployments for future updates" — [ECS Express Mode CLI tutorial](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/express-service-getting-started.html)

**AWS Lightsail Containers**
- "Your container service can have one active deployment at a time"; if a deployment fails the previous one stays active; no shutdown grace period or SIGTERM behavior is documented — [Lightsail deployments](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-container-services-deployments.html)

**Heroku**
- 30 s SIGTERM window, SIGKILL after (R12), not configurable — [Dyno shutdown behavior](https://devcenter.heroku.com/articles/dyno-shutdown-behavior)
- Default deploy "stop[s] the existing set of web dynos before starting the new ones" (downtime, unquantified). Preboot (Common Runtime, `standard`/`performance` dynos only) starts new dynos first, switches routing ~3 minutes after deploy, and both versions run during the overlap — [Heroku Preboot](https://devcenter.heroku.com/articles/preboot)

### Inferences
- Exactly-one-instance with no overlap is natively expressible only on ECS (`minimumHealthyPercent` 0, `maximumPercent` 100, desiredCount 1) at the cost of downtime equal to task stop (<= stopTimeout) plus Fargate pull/start plus ALB health-check warmup (typically 1–3 min). Fly's `rolling` on a single Machine is likely replace-in-place as well, but Fly does not document it.
- Platforms that overlap (Render, Railway, DO, Fly bluegreen, ECS defaults) will have two instances serving for roughly the health-check window plus the drain: Render ~60 s + up to the shutdown delay; Railway `RAILWAY_DEPLOYMENT_OVERLAP_SECONDS` (default not documented) plus draining seconds; DO ~15 s drain plus grace. For the in-memory routing state this overlap must be documented as a known window during which a client may land on a fresh instance.
- Render's SIGTERM arrives 60 s after the traffic switch; with a 35 s drain the total old-instance lifetime after switch is ~95 s, well within the 300 s cap. Set `maxShutdownDelaySeconds` to at least 40.
- On Railway, `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` must be set explicitly (default 0 = immediate SIGKILL).

### Gaps
- Fly: no doc on whether a single-Machine rolling deploy stops the old Machine before starting the new one, nor an official `--ha=false` reference (the flag exists in flyctl but was not confirmed from a fetched page).
- Railway: default and maximum of `RAILWAY_DEPLOYMENT_OVERLAP_SECONDS` not documented.
- DigitalOcean: no official statement that deploys are zero-downtime; only a community answer describes "traffic routed to the new deployment, then SIGTERM to old."
- Lightsail: no documented SIGTERM grace at all.

## Secrets and config: env-var injection, multi-line values, rotation, GitHub Actions

### Takeaway
All finalists inject secrets as environment variables. Fly and ECS (via Secrets Manager/SSM) have the cleanest rotation story (stage + deploy; force new deployment). Multi-line PEM support is explicitly documented only on Railway (Ctrl+Enter / RAW editor); Render, Fly, DO, Heroku accept arbitrary string values via API but none document multi-line handling. Railway's October 2026 breach exposed decrypted environment variables.

### Cited Findings
**Fly.io**
- Secrets "are injected as environment variables into every Machine"; `fly secrets set` without `--stage` restarts each Machine; `--stage` writes to the vault only and applies on next `fly deploy` or `fly secrets deploy`; `fly secrets` can read from stdin — [docs.fly.io apps/secrets](https://docs.fly.io/apps/secrets)
- GitHub Actions: `superfly/flyctl-actions/setup-flyctl@master`, `flyctl deploy --remote-only`, auth via `fly tokens create deploy -x 999999h` stored as `FLY_API_TOKEN` — [docs.fly.io CD with GitHub Actions](https://docs.fly.io/launch/continuous-deployment-with-github-actions)

**Render**
- Env vars via dashboard (incl. `.env` bulk import), Blueprints (`render.yaml`), and secret files mounted at `/etc/secrets/<filename>` (1 MB cap per service); uploading secret files triggers a deploy — [Render: Configure environment variables](https://render.com/docs/configure-environment-variables)
- API `PUT /services/{serviceId}/env-vars` replaces the full set; values are strings; "Changes will not be deployed automatically" — call the deploy API separately — [Render API: Update env vars](https://api-docs.render.com/reference/update-env-vars-for-service)

**Railway**
- Multi-line values: "In the value field, press Control+Enter (Cmd+Enter on Mac) to add a newline. In the RAW Editor, type a newline directly." Variable changes are staged until deployed. Sealed variables are never shown in the UI or returned by the API/CLI, and are not copied to PR environments — [docs.railway.com variables guide](https://docs.railway.com/guides/variables)
- CLI for CI: `RAILWAY_TOKEN` (project) or `RAILWAY_API_TOKEN` (account); `railway variable set KEY=value`; `railway up`; `railway redeploy` — [docs.railway.com CLI](https://docs.railway.com/guides/cli)
- Breach: between 2026-10-20 13:58 UTC and 2026-10-22 03:32 UTC an attacker compromised build infrastructure and CI credentials, ran "an unauthorized query of encrypted environment variables" and decrypted a subset; Railway estimates at most 1.85% of workspaces (~100,000) had variables potentially compromised; Railway advised rotating all sensitive variables stored before Oct 21 — [Railway preliminary report](https://blog.railway.com/p/preliminary-report-october-security-incident); [Railway changelog 2026-10-23](https://railway.com/changelog/2026-10-23-october-21-security-incident.md)

**DigitalOcean App Platform**
- `envs` with `type: SECRET` are encrypted on first submission and must be resubmitted as the `EV[...]` string; scope `RUN_TIME` / `BUILD_TIME`; multi-line not addressed — [App Spec reference](https://docs.digitalocean.com/products/app-platform/reference/app-spec/)
- Official GitHub Action `digitalocean/app_action/deploy@v2` with a DO API token (App Platform read/write); page last verified 13 Jul 2026 — [DO: Deploy using GitHub Actions](https://docs.digitalocean.com/products/app-platform/how-to/deploy-from-github-actions/)

**AWS ECS on Fargate**
- Secrets from Secrets Manager or SSM Parameter Store are injected as environment variables via the `secrets` container parameter (`valueFrom`); "If your secret changes, you must force a new deployment or launch a new task to retrieve the latest secret value" — [ECS: Pass sensitive data](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/specifying-sensitive-data.html)
- GitHub Actions: AWS documents OIDC + `aws-actions/amazon-ecs-deploy-express-service@v1` for Express Mode (with `environment-variables` JSON input) — [App Runner to ECS Express migration guide](https://docs.aws.amazon.com/apprunner/latest/dg/apprunner-availability-change.html)

**AWS Lightsail Containers**
- Deployments accept plain "Environment variables" per container; no secret store is documented — [Lightsail deployments](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-container-services-deployments.html)

**Heroku**
- Config vars total <= 64 KB per app; "Whenever you set or remove a config var using any method, your app is restarted and a new release is created"; CLI/Dashboard/Platform API — [Heroku config vars](https://devcenter.heroku.com/articles/config-vars)

### Inferences
- A multi-line PEM is safest delivered via a mechanism that is explicitly string-opaque: Railway RAW editor, Fly `fly secrets set KEY="$(cat key.pem)"` (shell quoting preserves newlines; stdin import also exists), Render secret files at `/etc/secrets/`, DO `type: SECRET` set through the API/`doctl` from a spec file, or ECS Secrets Manager (arbitrary string). Base64-encoding the PEM and decoding in the Rust service removes the ambiguity on every platform.
- Rotation without downtime on a single-instance service is a redeploy everywhere; Fly's `--stage` and ECS "force new deployment" make this explicit and CI-friendly.
- Railway's breach is the strongest single data point against storing an Apple private key there without a compensating control (e.g., sealed variables plus rotation).

### Gaps
- Render, Fly, DO, Heroku do not document multi-line env var handling; not tested.
- Render's CLI/API for secret files was not confirmed.

## Headers: X-Forwarded-For / client IP and spoofability

### Takeaway
The right-most X-Forwarded-For entry is the trustworthy client IP only on Heroku (router appends client IP to the right) and on ALB in `append` mode. On Fly the docs say the right-most XFF address is the app's own Fly IP and recommend `Fly-Client-IP`; on DigitalOcean XFF holds the DO ingress IP and the client is in `do-connecting-ip`; Railway documents `X-Real-IP` (not XFF) and users report reliability bugs; Render puts the client first and does not strip client-supplied entries. The rate limiter should read a platform-specific header, not a fixed XFF position.

### Cited Findings
- Fly sets `Fly-Client-IP`, `Fly-Forwarded-Port`, `Fly-Region`, `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Port` (client may set this one), `X-Forwarded-SSL`, `Via`. XFF "must be treated with caution to avoid spoofing attempts"; the docs note the rightmost XFF address is a shared or dedicated IP assigned to the app, and suggest `Fly-Client-IP` when no other proxy is in front — [docs.fly.io request headers](https://docs.fly.io/networking/request-headers)
- Render staff (Anurag Goel, 2021-05-28, pre-2025): "we set the first IP in the list to the real client IP". A user test (2024-03-03, pre-2025) found Render does not clear client-supplied XFF and only appends — [Render feedback: Send the correct X_FORWARDED_FOR](https://feedback.render.com/features/p/send-the-correct-xforwardedfor); Render's wildcard-domain setup requires a `_cf-custom-hostname` CNAME, indicating Cloudflare in front — [Render custom domains](https://render.com/docs/custom-domains)
- Railway's edge sets `X-Real-IP` (client remote IP), `X-Forwarded-Proto` (always https), `X-Forwarded-Host`, `X-Railway-Edge`, `X-Request-Start`, `X-Railway-Request-Id`; XFF is not listed — [docs.railway.com specs and limits](https://docs.railway.com/networking/public-networking/specs-and-limits). Community threads report `X-Real-IP` sometimes containing a Fastly/Railway infrastructure IP ("known bug" per one staff reply) and conflicting staff statements on whether XFF is overwritten or appended — [Railway Station](https://station.railway.com/questions/which-client-address-headers-does-the-ra-fb9e36d7); [Railway Station](https://station.railway.com/questions/edge-cdn-layer-leaking-its-own-ip-as-cli-1ce29b05)
- DigitalOcean: "App Platform adds a do-connecting-ip HTTP header that contains the client's IP address"; XFF holds "the IP address of the DigitalOcean ingress server" — [DO support: client IP](https://docs.digitalocean.com/support/where-can-i-find-the-client-ip-address-of-a-request-connecting-to-my-app/); community notes Cloudflare sits in front of App Platform by default — [DO community](https://www.digitalocean.com/community/questions/accessing-connecting-public-client-ip-in-app-platform)
- ALB `routing.http.xff_header_processing.mode`: `append` (default; adds the last-hop client IP to XFF), `preserve`, `remove` — [ALB attributes](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/application-load-balancers.html)
- Heroku router "appends the client's IP to the right side of any existing X-Forwarded-For list"; the header is "not trusted for security reasons" because earlier entries may be client-supplied — [Heroku HTTP routing](https://devcenter.heroku.com/articles/http-routing)

### Inferences
- Right-most-XFF is correct for Heroku and ALB(append). For Fly use `Fly-Client-IP`; for DO use `do-connecting-ip`; for Railway use `X-Real-IP` with awareness of the reported bug; for Render use the first XFF entry but note clients can prepend, so Render's own proxy IP would be right-most and the client would be second-from-right only if Render appends exactly one hop (unverified).
- Apple's form POST and the rate limiter are unaffected by TLS termination at the edge on any platform, since all forward plain HTTP to port 8080 with `X-Forwarded-Proto`.

### Gaps
- Render: no official doc lists the exact XFF format or how many proxy IPs are appended; community thread (render.discourse.group) was unreachable.
- Fly: whether clients can spoof `Fly-Client-IP` is not stated (it is proxy-set, so presumably overwritten, but not documented).
- Lightsail and App Runner header behavior was not found.

## Custom domain via CNAME + automatic TLS (ACME); apex/wildcard; per-app CNAME target

### Takeaway
All platforms issue and renew TLS automatically for a CNAME'd subdomain like hub.b4.run, so no apex or wildcard is needed. Each platform gives a per-app/service CNAME target (Fly `<app>.fly.dev`, Render `<svc>.onrender.com`, Railway a generated `*.up.railway.app` CNAME plus a TXT record, DO `<app>.ondigitalocean.app`, Heroku `<haiku>.herokudns.com`). ECS requires an ACM certificate (DNS-validated via CNAME) and a CNAME to the ALB; Lightsail requires a Lightsail certificate validated by CNAME and attached to the service.

### Cited Findings
- Fly: `fly certs add hub.b4.run`; CNAME suits subdomains and points to a unique `.fly.dev` target; apex should use A/AAAA (or CNAME flattening); Let's Encrypt via ACME using TLS-ALPN then HTTP-01; wildcards need a DNS-01 `_acme-challenge` CNAME; first 10 single-hostname certificates free — [docs.fly.io custom domain](https://docs.fly.io/networking/custom-domain); [docs.fly.io pricing](https://docs.fly.io/about/pricing)
- Render: Custom Domains in service Settings; Render issues and renews certificates and redirects HTTP to HTTPS; remove AAAA records (IPv4 only); wildcards need `*`, `_acme-challenge`, and `_cf-custom-hostname` CNAMEs; CAA must allow Let's Encrypt and Google Trust Services — [Render custom domains](https://render.com/docs/custom-domains)
- Railway: "You must add the CNAME and TXT records Railway provides ... both are required"; certificates are Let's Encrypt ECDSA, 90-day validity, renewed with 30 days left, issuance usually within an hour, retried up to 72 h; apex needs CNAME flattening/ALIAS/ANAME (no static IP); Hobby 2 custom domains per service, Pro 20 — [docs.railway.com public networking](https://docs.railway.com/reference/public-networking); [specs and limits](https://docs.railway.com/networking/public-networking/specs-and-limits); [working with domains](https://docs.railway.com/networking/domains/working-with-domains)
- DigitalOcean: CNAME to an alias ending in `ondigitalocean.app`; apex via two free static ingress IPs (A records) or DO-managed DNS; wildcards supported with TXT verification; CAs are Let's Encrypt and Google Trust (`pki.goog`); DNSSEC domains not supported — [DO manage domains](https://docs.digitalocean.com/products/app-platform/how-to/manage-domains/)
- ECS/ALB: ALB DNS name `name-id.elb.region.amazonaws.com`; custom domain via CNAME (Route 53 alias for apex) — [ALB docs](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/application-load-balancers.html); Express Mode: default URL `https://<service-name>.ecs.<region>.on.aws/` with automatic TLS; custom domain = add a host-header listener rule and an ACM certificate in the same region to the HTTPS listener — [Express Mode tutorial](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/express-service-getting-started.html); [App Runner migration guide](https://docs.aws.amazon.com/apprunner/latest/dg/apprunner-availability-change.html)
- Lightsail: up to 4 custom domains per service; create a Lightsail certificate, validate with CNAME records, attach, then "Add domain assignment"; apex routing only with a Lightsail DNS zone — [Lightsail custom domains](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-enabling-container-services-custom-domains.html)
- Heroku: per-domain `<haiku>.herokudns.com` CNAME target; apex needs ALIAS/ANAME; ACM uses Let's Encrypt, renews one month before expiry, issuance 45–60 min, "All applications include ACM for free" — [Heroku custom domains](https://devcenter.heroku.com/articles/custom-domains); [Heroku ACM](https://devcenter.heroku.com/articles/automated-certificate-management)

### Inferences
- From a Vercel-hosted zone, hub.b4.run and hub.test.b4.run as CNAMEs work on every platform; Railway additionally needs a TXT record per hostname; ECS needs an ACM validation CNAME per certificate (renewal depends on keeping it).
- No wildcard is required; a `*.b4.run` wildcard would complicate Fly (DNS-01) and Render (three records) for no benefit.

### Gaps
- Railway's exact CNAME target format page returned 404; the "working with domains" page confirms the CNAME+TXT requirement.
- Fly's custom-domain page does not explicitly confirm that a CNAME to `appname.fly.dev` works for certificate validation; it says a CNAME "points the domain at a unique .fly.dev target."

## Regions (US and EU) and path to two regions with one database

### Takeaway
Fly has the most regions (6 US, 4 EU + LHR) and a documented `fly-replay` mechanism for routing writes to a primary region; Render (Oregon, Ohio, Virginia, Frankfurt, Singapore), Railway (US West, US East, EU West Amsterdam, Singapore), DO (NYC, SFO, ATL, AMS, FRA, LON, etc.) are single-region per service, so two regions means two services behind client-side or DNS routing. AWS has all regions.

### Cited Findings
- Fly regions: US dfw, ewr, iad, lax, ord, sjc; EU ams, arn, cdg, fra; plus lhr, yyz, gru, jnb, nrt, sin, syd — [docs.fly.io regions](https://docs.fly.io/reference/regions)
- Fly `fly-replay: region=xxx` response header replays a request to another region; requests over 1 MB cannot be replayed; the app must use the http handler — [docs.fly.io dynamic request routing](https://docs.fly.io/networking/dynamic-request-routing)
- Render regions: Oregon, Ohio, Virginia, Frankfurt, Singapore; cannot change a service's region; each region has its own private network — [Render regions](https://render.com/docs/regions)
- Railway regions: US West Metal (California), US East Metal (Virginia), EU West Metal (Amsterdam), Southeast Asia Metal (Singapore) — [docs.railway.com regions](https://docs.railway.com/reference/regions)
- DO App Platform dynamic apps: NYC, AMS, SFO, SGP, LON, FRA, TOR, BLR, SYD, ATL, RIC, MKC — [DO availability](https://docs.digitalocean.com/products/app-platform/details/availability/)
- App Runner (closed) regions include us-east-1/2, us-west-2, eu-central-1, eu-west-1/2/3 — [AWS App Runner endpoints](https://docs.aws.amazon.com/general/latest/gr/apprunner.html)
- Heroku Common Runtime: `us` and `eu` only; Private Spaces: dublin, frankfurt, london, montreal, mumbai, oregon, singapore, sydney, tokyo, virginia — [Heroku regions](https://devcenter.heroku.com/articles/regions)
- Fly outbound egress and private-network cross-region transfer are priced per region ($0.006/GB NA/EU private) — [docs.fly.io pricing](https://docs.fly.io/about/pricing)

### Inferences
- Because the hub keeps in-memory routing state and must run one instance per environment, a two-region deployment would need the service itself to become region-aware; Fly's anycast plus `fly-replay` is the only built-in primitive among the finalists that avoids external DNS steering.
- With one external PostgreSQL, a second region adds cross-region DB latency on every request; none of the platforms solve that.

### Gaps
- None material.

## Health checks, restart policies, logs retention, metrics, alerting

### Takeaway
All finalists support HTTP-path health checks and auto-restart. Built-in alerting exists on DO (app spec `alerts`), Render (notifications on failed deploys/restarts), ECS (CloudWatch), and Heroku; Fly explicitly has no built-in metric alerting (Grafana rules needed); Railway does not continuously health-check after deploy. Log retention is short everywhere without forwarding: Render 7 days (Hobby), Railway 7 days (Hobby)/30 (Pro), DO runtime logs not retained, Heroku 1,500 lines/1 week, Fly unspecified.

### Cited Findings
- Fly: `[[http_service.checks]]` with `path`, `interval`, `grace_period`; does not follow 301/302 — [configuration reference](https://docs.fly.io/reference/configuration). Metrics: managed Prometheus (VictoriaMetrics) with ~15 days retention and a managed Grafana; "Fly.io doesn't include built-in alerting on metrics" — [docs.fly.io metrics](https://docs.fly.io/reference/metrics). Logs: ship via `fly-log-shipper` over NATS; default retention not stated — [docs.fly.io exporting logs](https://docs.fly.io/monitoring/exporting-logs)
- Render: health check path via `healthCheckPath`; 2xx/3xx within 5 s; restart after 60 s of failures; notifications on failed deploys and auto-restarts — [Render health checks](https://render.com/docs/health-checks). Log retention Hobby 7 days, Pro 14, Scale/Enterprise 30; log streams for export; HTTP request logs need Pro — [Render logging](https://render.com/docs/logging)
- Railway: healthcheck used only at deploy time; suggests Uptime Kuma for monitoring — [Railway healthchecks](https://docs.railway.com/reference/healthchecks). Log retention Free 3 d, Hobby 7 d, Pro 30 d, Enterprise up to 90 d; "Railway does not have a log drain setting" (use Vector/Fluent Bit/OTel) — [Railway logging](https://docs.railway.com/reference/logging)
- DO: `health_check` and `liveness_health_check` (restart on failure); `alerts` rules incl. `CPU_UTILIZATION`, `MEM_UTILIZATION`, `RESTART_COUNT`, `DEPLOYMENT_FAILED`, `DOMAIN_FAILED` — [App Spec reference](https://docs.digitalocean.com/products/app-platform/reference/app-spec/). Build/deploy logs retained 90 days; "To retain runtime logs, configure log forwarding to an external provider" — [DO view logs](https://docs.digitalocean.com/products/app-platform/how-to/view-logs/)
- ECS: `healthCheckGracePeriodSeconds`; service scheduler replaces unhealthy tasks; Express Mode includes CloudWatch logging/monitoring and 5xx rollback alarms — [service definition](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service_definition_parameters.html); [Express tutorial](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/express-service-getting-started.html)
- Lightsail: health check path, timeout 2–60 s, interval 5–300 s, success codes, thresholds; container logs (stdout/stderr) and utilization metrics in console — [Lightsail deployments](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-container-services-deployments.html)
- Heroku Cedar: Logplex keeps 1,500 lines for 1 week; Fir keeps no history (OTLP drains) — [Heroku logging](https://devcenter.heroku.com/articles/logging)

### Inferences
- An external uptime/alerting service is needed on Fly and Railway regardless; DO and Render give the most alerting out of the box at the low tier.

### Gaps
- Fly default log retention not found.
- Render/Railway metrics retention by plan not confirmed from fetched pages.

## Deployment from GitHub Actions (prebuilt GHCR image vs platform build) and pre-release migration command

### Takeaway
All finalists can deploy a prebuilt image from GHCR with a GitHub Actions step: Fly (`fly deploy --image`, `release_command`), Render (deploy hook/API with `imgURL`, pre-deploy command on paid plans), Railway (image source + `railway redeploy`; private GHCR needs Pro; pre-deploy command), DO (`doctl apps create-deployment`; `PRE_DEPLOY` jobs; GHCR supported but no auto-redeploy), ECS (`aws-actions/*`; migrations need a separate run-task step). Heroku requires pushing to its own registry.

### Cited Findings
- Fly: `--image` or `[build] image` takes precedence over Dockerfile; `release_command` runs once per deploy in a temporary Machine and "A non-zero exit status from this command will stop the deployment"; default 5-minute timeout, configurable — [launch/deploy](https://docs.fly.io/launch/deploy); [configuration reference](https://docs.fly.io/reference/configuration); GitHub Actions via `superfly/flyctl-actions` — [CD guide](https://docs.fly.io/launch/continuous-deployment-with-github-actions)
- Render: private images from Docker Hub, GHCR (token needs `read:packages`), GitLab, GAR, ECR; image services do not auto-redeploy on push; deploy hook GET/POST with `imgURL` for a specific tag/digest, or the Trigger Deploy API — [Render deploy an image](https://render.com/docs/deploy-an-image). Pre-deploy command runs after build, before deploy, on a separate instance; "Available for paid web services"; 30-minute timeout — [Render deploys](https://render.com/docs/deploys)
- Railway: image source e.g. `ghcr.io/...`; "Private registry deployments require the Pro plan"; GHCR private uses a classic PAT; automatic image update schedules available — [Railway services guide](https://docs.railway.com/guides/services). CI pattern: push a mutable tag then `npx -y @railway/cli@latest redeploy --service my-app --yes` with `RAILWAY_TOKEN` — [Railway GitHub Actions guide](https://railway.com/guides/github-actions). Pre-deploy command runs after build, before deploy, has the service's env vars, fails the deploy on non-zero exit, optional 1–3600 s timeout — [Railway pre-deploy command](https://docs.railway.com/guides/pre-deploy-command)
- DO: registries DOCR, Docker Hub, GHCR (`registry_credentials: "$username:$token"`); autodeploy on push is DOCR-only; `doctl apps create-deployment` always pulls the image; digests recommended over tags — [DO deploy from container images](https://docs.digitalocean.com/products/app-platform/how-to/deploy-from-container-images/). Jobs `kind: PRE_DEPLOY` run before a deployment — [App Spec reference](https://docs.digitalocean.com/products/app-platform/reference/app-spec/). Official action `digitalocean/app_action/deploy@v2` — [DO GitHub Actions](https://docs.digitalocean.com/products/app-platform/how-to/deploy-from-github-actions/)
- ECS Express Mode: `aws-actions/amazon-ecs-deploy-express-service@v1` with OIDC; `aws ecs update-express-gateway-service` with a new image URI — [App Runner migration guide](https://docs.aws.amazon.com/apprunner/latest/dg/apprunner-availability-change.html); [AWS News Blog, 2025-11-21](https://aws.amazon.com/blogs/aws/build-production-ready-applications-without-infrastructure-complexity-using-amazon-ecs-express-mode)
- Lightsail: images from a public registry or pushed from a local machine with `lightsailctl`; no private third-party registry support documented — [Lightsail container services](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-container-services.html)
- Heroku: `docker push registry.heroku.com/<app>/web` then `heroku container:release web`; x86_64 only; `release` image for release phase; "Pipeline promotions and Review Apps are not supported with locally built images" — [Heroku container registry](https://devcenter.heroku.com/articles/container-registry-and-runtime)

### Inferences
- ECS has no first-class "release command"; the GitHub workflow would run `aws ecs run-task` with the migration command and wait before updating the service (or run migrations from the app on startup).
- Railway's Pro plan ($20/mo) is required for a private GHCR image; a public GHCR image avoids that.

### Gaps
- Railway's GraphQL API for image deploys with status polling is community-documented only.
- Render's Trigger Deploy API was referenced but its page was not fetched.

## Preview environments per pull request

### Takeaway
Railway (PR environments, built-in), Render (PR previews for Git-backed; image previews via API, Pro+), DO (`deploy_pr_preview` in the official GitHub Action), and Fly (community-maintained `superfly/fly-pr-review-apps` action) all support per-PR environments; ECS has nothing built in; Heroku Review Apps do not work with registry-pushed images.

### Cited Findings
- Fly: `superfly/fly-pr-review-apps` creates/deploys/destroys a Fly app per PR (default name `pr-{number}-{org}-{repo}`, `secrets` input, `FLY_API_TOKEN`) — [GitHub superfly/fly-pr-review-apps](https://github.com/superfly/fly-pr-review-apps)
- Render: PR previews billed at the base service's rate, auto-deleted on merge/close; image previews via the Create service preview API, not auto-deleted; previews copy env vars at creation; "preview environments" listed under Pro and higher — [Render PR previews](https://render.com/docs/pull-request-previews); [Render new workspace plans](https://render.com/docs/new-workspace-plans)
- Railway: PR environments created per PR when enabled, removed on merge/close; sealed variables are not copied — [Railway environments](https://docs.railway.com/guides/environments); [variables guide](https://docs.railway.com/guides/variables)
- DO: `digitalocean/app_action/deploy@v2` with `deploy_pr_preview: "true"` and `delete@v2` with `from_pr_preview: "true"` on PR close — [DO GitHub Actions](https://docs.digitalocean.com/products/app-platform/how-to/deploy-from-github-actions/)
- Heroku: Review Apps need `app.json`; Dockerfile builds via `heroku.yml` are supported, but registry-pushed images are not — [Heroku review apps](https://devcenter.heroku.com/articles/github-integration-review-apps); [container registry](https://devcenter.heroku.com/articles/container-registry-and-runtime)

### Inferences
- For ECS, per-PR previews would mean a CloudFormation/CDK stack per PR; Express Mode's single-call create/delete makes that scriptable but not built in.

### Gaps
- Maintenance status/last release date of `superfly/fly-pr-review-apps` not determinable from the fetched README.

## Outbound static IP (note only)

### Takeaway
Available everywhere at a price: Fly ~$3.60/mo static egress IP, Render dedicated outbound IPs (Pro+), Railway static outbound IPs (Pro), DO dedicated egress IP capped at $25/mo, ECS via NAT gateway (not fetched), none documented for Lightsail or Heroku Common Runtime.

### Cited Findings
- Fly static egress IP for Machines about $3.60/month ($0.005/hour) — [docs.fly.io pricing](https://docs.fly.io/about/pricing)
- Render: outbound ranges shared per region; "dedicated outbound IPs" addable to a workspace; dedicated outbound IPs listed as Pro-and-higher — [Render static outbound IPs](https://render.com/docs/static-outbound-ip-addresses); [new workspace plans](https://render.com/docs/new-workspace-plans)
- Railway: "Customers on the Pro plan can enable Static Outbound IPs"; three IPs per service — [Railway static outbound IPs](https://docs.railway.com/reference/static-outbound-ips)
- DO: dedicated egress IPs billed per second, capped at $25/month, not shareable across apps — [DO pricing](https://docs.digitalocean.com/products/app-platform/details/pricing/); [limits](https://docs.digitalocean.com/products/app-platform/details/limits/)

### Inferences
- Not needed: appleid.apple.com does not allowlist callers.

### Gaps
- ECS NAT gateway pricing and Heroku/Lightsail static egress not researched.

## Pricing for one always-on ~512 MB–1 GB instance per environment, and egress

### Takeaway
Cheapest always-on footprints: Fly shared-cpu-1x 512 MB $3.69/mo (1 GB $6.70), DO 512 MB $5 (1 GB $10–12), Render Starter 512 MB $7 (plus Pro workspace $25/mo if you want previews/dedicated IPs), Lightsail Nano 512 MB $7 (1 GB Micro $10), Heroku Basic 512 MB $7 (Standard-1X $25), Railway ~$15/mo of usage for 0.5 GB + 0.5 vCPU (Hobby $5 fee includes $5 usage), Fargate ~$9/mo for 0.25 vCPU/0.5 GB plus ~$16.4/mo ALB (shared across up to 25 Express services) plus LCU/IPv4. Egress: Fly $0.02/GB NA/EU, DO $0.02/GiB after pooled allowance, Railway $0.05/GB, Render $0.15/GB after 5 GB (Hobby) or 25 GB (Pro), Lightsail 500 GB included then from $0.09/GB.

### Cited Findings
- Fly (page read 2026-11-01; no "last updated" shown): shared-cpu-1x 512 MB $3.69/mo, 1 GB $6.70/mo, additional RAM $6/GB/mo; outbound $0.02/GB NA/EU, $0.04 APAC/Oceania/SA, $0.12 Africa/India; dedicated IPv4 $2/mo, shared IPv4 free; no free tier (trial only); support plans $29 Standard, $199 Premium — [docs.fly.io pricing](https://docs.fly.io/about/pricing)
- Render: Starter 0.5 CPU/512 MB $7/mo, Standard 1 CPU/2 GB $25/mo (official pricing page via search; plan IDs renamed Aug 2026 to `0.5c-512mb`, `1c-2g`, no price change) — [render.com/pricing](https://render.com/pricing); [Render compute plans](https://render.com/docs/compute-plans). Workspace plans: Hobby $0, Pro $25/mo flat, Scale $499/mo flat (changelog 2026-04-23; legacy auto-migrated 2026-08-01) — [Render changelog](https://render.com/changelog/updated-plans-for-render-workspaces). Included bandwidth after change: Hobby 5 GB, Pro 25 GB, Scale 1 TB; overage $0.15/GB (third-party, 2026-08-06) — [jwatte.com review](https://jwatte.com/blog/render-com-platform-review.md)
- Railway (plans page read 2026-11-01): Hobby $5/mo incl. $5 usage, Pro $20/mo incl. $20 usage; RAM $10/GB-mo, vCPU $20/vCPU-mo, egress $0.05/GB; Hobby per-service cap 48 GB RAM; Free plan 0.5 GB/1 vCPU/1 replica — [Railway plans](https://docs.railway.com/reference/pricing/plans)
- DO (page states pricing last verified 26 Oct 2026): Shared 1 vCPU/512 MiB $5/mo (50 GiB transfer), 1 GiB fixed $10/mo (100 GiB), 1 GiB $12/mo (150 GiB); Dedicated 1 vCPU/512 MiB $29, 1 GiB $34; overage $0.02/GiB; transfer pooled at team level — [DO App Platform pricing](https://docs.digitalocean.com/products/app-platform/details/pricing/)
- Fargate us-east-1 (page read 2026-11-01, no effective date): Linux/x86 ~$0.0405 per vCPU-hour, ~$0.00445 per GB-hour; ARM ~$0.0324 / ~$0.00356 — [AWS Fargate pricing](https://aws.amazon.com/fargate/pricing/). Smallest Fargate size 0.25 vCPU with 0.5/1/2 GB — [ECS task definition parameters](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html). ALB $0.0225/hour + $0.008/LCU-hour (1 LCU = 25 new conn/s, 3,000 active conn/min, 1 GB/h, 1,000 rule evals/s); "standard data transfer and public IPv4 charges also apply" — [ELB pricing](https://aws.amazon.com/elasticloadbalancing/pricing/). Express Mode shares one ALB across up to 25 services via host-header rules — [AWS News Blog](https://aws.amazon.com/blogs/aws/build-production-ready-applications-without-infrastructure-complexity-using-amazon-ecs-express-mode)
- App Runner (closed): $0.007/GB-hour provisioned, $0.064/vCPU-hour + $0.007/GB-hour active — [App Runner pricing](https://aws.amazon.com/apprunner/pricing/)
- Lightsail: Nano 0.25 vCPU/512 MB $7/mo, Micro 0.25 vCPU/1 GB $10, Small 0.5 vCPU/1 GB $15, Medium 1 vCPU/2 GB $40; 500 GB transfer included per service; overage from $0.09/GB — [Lightsail pricing](https://aws.amazon.com/lightsail/pricing/)
- Heroku (page read 2026-11-01; blog "Last Updated: October 29, 2026"): Eco $5 (0.5 GB, sleeps), Basic $7 (0.5 GB), Standard-1X $25 (0.5 GB), Standard-2X $50 (1 GB); Fir Classic 1CPU-0.5GB $25 (Private Space required) — [Heroku pricing](https://www.heroku.com/pricing/)

### Inferences
- Computed Fargate example (own arithmetic from the cited rates, 730 h): 0.25 vCPU x $0.0405 x 730 = $7.39 + 0.5 GB x $0.00445 x 730 = $1.62, ~$9.0/mo per task; ALB $0.0225 x 730 = $16.43/mo before LCU and IPv4 charges. Two environments on one Express Mode ALB: ~$18 tasks + ~$16.4 ALB + LCU/IPv4, roughly $40/mo.
- Two environments at 512 MB: Fly ~$7.40/mo, DO $10, Render $14 (Hobby) or $39 (Pro workspace), Lightsail $14, Railway ~$30, Heroku Basic $14 (but 30 s SIGTERM).
- At 1 GB: Fly $13.40, DO $20–24, Lightsail $20, Render $50 (Standard 2 GB is the next size), Railway ~$40.

### Gaps
- Render's bandwidth allowances come from a third-party review and a changelog that confirms a reduction without figures; render.com/pricing did not render through the fetch tool.
- AWS public IPv4 charge ($0.005/h per address, announced 2024, pre-2025) was not fetched; included only as a line item to check.
- Fargate pricing page shows no effective date.

## Reliability history 2025–2026 and company viability

### Takeaway
Heroku had its longest-ever outage (June 10, 2025, ~21–24 h). Railway suffered an October 2026 security breach that decrypted customer environment variables and paused deploys for ~2 days, though running services stayed up; it raised a $100M Series B in January 2026. Render raised $80M (Jan 2025) and a $100M extension at a $1.5B valuation (Feb 2026); a third-party count found ~6.6 status incidents/month Dec 2025–Jul 2026, mostly build/deploy. Fly raised a $25M Series D (July 2026) with a CEO change to Scott Johnston and reported its strongest quarter; aggregators list a 15 h control-plane outage (Jan 2026) and several regional boot failures. DigitalOcean (public company) had mostly short App Platform deployment incidents plus a ~9 h multi-service incident in May 2025. AWS is AWS.

### Cited Findings
- Heroku June 10, 2025 outage: Heroku's root cause "an unexpected change to our running environment"; automated upgrade service disabled — [Heroku: Summary of June 10 outage](https://www.heroku.com/blog/summary-of-june-10-outage/); [Heroku corrective action update](https://www.heroku.com/blog/corrective-action-update-june-10-outage/); duration reported ~23 h and "longest-ever" by [The Pragmatic Engineer](https://newsletter.pragmaticengineer.com/p/why-reliability-is-hard-at-scale)
- Railway breach (Oct 20–22, 2026): build infrastructure and CI credentials compromised; subset of encrypted env vars decrypted; builds/deploys, dashboard, API, CLI unavailable during triage; "Running customer services stayed online throughout"; new signups still paused as of Oct 26 — [Railway preliminary report](https://blog.railway.com/p/preliminary-report-october-security-incident). Railway $100M Series B, 2026-01-22, led by TQ Ventures with FPV, Redpoint, Unusual — [SiliconANGLE](https://siliconangle.com/?p=728763); [briefglance.com](https://briefglance.com/articles/railway-raises-100m-to-build-the-clouds-future-for-ai-developers). Other 2026 Railway incidents: build/deploy delays July 30 (~2 h), US West connectivity issues (aggregators) — [IsDown Railway](https://isdown.app/status/railway/incidents/636144-connectivity-issues-in-us-west)
- Render funding: $80M Series C led by Georgian, 2025-01-21 — [Business Wire](https://businesswire.com/news/home/20250121967005/en); $100M Series C extension at $1.5B valuation, Feb 2026 — [SiliconANGLE](https://siliconangle.com/?p=731299). Render incidents: 50 Statuspage incidents 2025-12-10 to 2026-07-27 (~6.6/month), 16 deploy/build/queue related, HA Postgres outage 2026-05-07, four critical incidents July 15–24, 2026 — [jwatte.com review (2026-08-06)](https://jwatte.com/blog/render-com-platform-review.md)
- Fly funding and leadership: $25M Series D co-led by Dell Technologies Capital and Intel Capital, 2026-07-24; Scott Johnston (ex-Docker CEO) became CEO; "strongest quarter in company history"; 37,000+ customers — [Fly.io news](https://fly.io/news/fly-io-launches-computers-for-agents.md). Pre-2025: $70M Series C led by EQT at a $467M valuation (2023) — [Bloomberg](https://www.bloomberg.com/news/articles/2023-06-28/public-cloud-startup-fly-io-raises-70-million-in-eqt-led-round). Fly incidents 2026 (aggregators): control-plane outage ~15 h Jan 5 (apps kept running); Machines failing to boot in EWR (~5 h, Mar 2) and DFW (Mar 18); MPG unreachable in FRA (~2.5 h, May 16); ORD management-plane incidents Jul 3 and Aug 20; AMS partial outage Oct 3 — [IsDown Fly.io history](https://isdown.app/status/fly-io/outage-history); [Pingoru Fly.io](https://pingoru.io/providers/flyio/outage-history)
- DigitalOcean App Platform incidents: App Platform + Managed Databases all regions, ~9 h, May 22, 2025 — [DO status](https://status.digitalocean.com/incidents/rtgb9cp8hrzy); deployments incidents Oct 22, 2025 (34 min), Jan 20, 2026 (20 min), Apr 23, 2026 (~2 h), Oct 13, 2026 (<1 min); Functions on App Platform ~2 h Aug 6, 2026 — [IsDown DO](https://isdown.app/status/digitalocean/incidents/404585-app-platform-deployments); [Pingoru DO](https://pingoru.io/providers/digitalocean/outage-history)
- AWS App Runner closed to new customers; Copilot end of support 2026-06-12 — see Scope note above.

### Inferences
- For a service whose value is staying connected, control-plane outages (Fly Jan 2026, Railway Oct 2026) matter less than data-plane ones; both vendors report running workloads stayed up. Railway's breach is a secrets-handling risk rather than an uptime one, but it directly affects an Apple private key stored as an env var.
- Render's incident mix (build queues, deploy pipeline) mostly affects deploy latency, not serving.
- DigitalOcean and AWS are public companies; Fly, Render, Railway are venture-funded with 2025–2026 raises and no public profitability disclosures.

### Gaps
- No official status-page export was fetched for Fly, Railway, or Render; incident durations come from aggregators (IsDown, Pingoru) or a third-party blog and disagree in places.
- Revenue/profitability figures for Fly, Render, Railway are undisclosed; third-party ARR estimates were not used.
- Railway's final (non-preliminary) incident report had not been published at research time.

## 2026-11-05: Large Mac sync uploads through the hosted test WAF

Gate 2b passed against `https://hub.test.b4.run/v1/changes` at 15:42 UTC (07:42 Pacific). An exactly 9 MiB body sent by the unchanged Swift `HTTPHubAPI` returned HTTP 200, appeared as `ALLOW` in the attached WAF's samples with the exact content length, and was pulled back with every change value matching by SHA-256. The real coordinator `HubSync` separately uploaded a larger-than-9-MiB outbox through its normal bounded batches. No fake hub, HTTP transport, or database stood in for these live checks.

### Scope and setup

- Test AWS account `355069727528`, region `us-east-2`; production's enrollment, data and configuration were not used.
- A temporary native Swift executable imported the repository's `WorkspaceSync`, `Coordinator`, `WorkspaceStorage`, `WorkspaceProtocol` and `WorkspaceSecrets` modules. Client sources were built from `ca2cb2ba5abac5c1e07318f74e72d52057db01ea`, using the repository's exact `Package.resolved`, Swift 6.3.3 and the pinned PostgreSQL 17.11 binaries for the temporary local outbox. No shipped source or batch limit was changed.
- `HubSync` ordinarily caps a request at 500 changes or 8 MiB (D-046). It cannot normally produce a single 9 MiB request. The boundary check called the same production `HTTPHubAPI.push` used by the coordinator, while the separate outbox check used the production `SyncFilter`, `HubSync.batch`, enrollment, drain and acknowledgement handling. This does not claim a packaged app emitted a 9 MiB coordinator batch.
- Isolated operator-seeded org `waf-gate2b-20261105154050`, org id `01a1ac5f-8b99-7067-95e3-5af3c7d9c1ac`, user `wafgate`, user id `01a1ac5f-8ba0-73f2-8f24-33d5f4b765be`. Two disposable `macos` devices exercised the transport and coordinator paths independently.
- Synthetic content only: each path inserted one connection, one thread and twelve display items. Payloads remained below the Mac's truncation threshold and the hub's per-change limit. Enrollment codes and device tokens stayed in process memory, passed through stdin and the memory secret store; they are absent from this record, arguments and result artifacts.
- Request tag: `b4app-gate2b-d2f5011c-1dc9-4505-a655-dd18556770a5` (User-Agent). The deployed test image was `sha256:f088a5907fa723745182fe652c11efb9bb62658edbde5902488298c308f39fa6`.

### HTTP, persistence and WAF evidence

| Path | HTTP body bytes | Hub request id | Client result and hub completion log |
| --- | ---: | --- | --- |
| Swift HTTP transport boundary | 9,437,184 (exactly 9 MiB) | `01a1ac60-0da9-7131-bd54-919ffdbaca77` | HTTP 200; `acceptedThrough = 14`, no rejected changes; hub completion 1,084 ms. |
| Native `HubSync`, batch 1 | 8,006,466 | `01a1ac60-22f3-7021-843d-df0e24b8fef0` | HTTP 200; hub completion 1,056 ms. |
| Native `HubSync`, batch 2 | 1,600,999 | `01a1ac60-27ab-7559-a1c9-e10039dc35ff` | HTTP 200; hub completion 130 ms. |

The native outbox sent 9,607,465 body bytes across its two requests, each below 8 MiB, and ended with zero unsynced changes and no sync error. Pulling through the real HTTP client verified all fourteen transport changes in two pages and all fourteen native changes in three pages. Each retrieved value's SHA-256 matched the uploaded value; device sequence, row id, table and operation also matched. Read-only SQL with an explicit tenant context independently counted one org, one user, two devices, 28 feed changes, two connections, two threads and 24 display items: the rows materialized as well as entering the feed.

The test ALB `arn:aws:elasticloadbalancing:us-east-2:355069727528:loadbalancer/app/b4hub-test/0e9668ed346fdbd5` was verified attached to `arn:aws:wafv2:us-east-2:355069727528:regional/webacl/b4hub-test-web-acl/4be1b9eb-1e1b-4edb-b8bd-a3117ae064fe`. Its two rules were the 2,000-per-five-minute IP rate rule and `AWSManagedRulesAmazonIpReputationList`, with default allow and sampling enabled. There was no body-inspecting managed group, and no WAF configuration was changed.

`GetSampledRequests` for metric `b4hub-test-web-acl`, window 15:40:45–15:44:26 UTC, returned all 24 requests in that sample population. The following samples matched the unique tag, method and route:

| WAF timestamp (UTC) | Method and route | Content-Length | Action |
| --- | --- | ---: | --- |
| 15:42:18.537 | `POST /v1/changes` | 9,437,184 | `ALLOW` |
| 15:42:23.987 | `POST /v1/changes` | 8,006,466 | `ALLOW` |
| 15:42:25.194 | `POST /v1/changes` | 1,600,999 | `ALLOW` |

Neither blocking-rule sample contained the test tag. An unrelated request appeared in the IP-reputation sample; this check makes no claim that all traffic was unblocked. Sample inspection emitted only the test tag, action, size, method, route and time, never authorization headers. CloudWatch group `/b4hub/test/hub` independently recorded the three request ids above as `POST /v1/changes`, status 200.

### Cleanup and limits

The public account-delete endpoint answered `409 shared_org`: an operator-seeded legacy org is not a personal account. Consequently the harness's traffic assertions passed, but its automatic cleanup attempt ended nonzero. Cleanup was completed through the test admin psql connection using the same ordered tenant-table deletion list as `b4hub-db::accounts::delete_org`, in one transaction with tenant context. Guards required the exact org id and slug, exact user id and username, two devices, 28 changes, and only the synthetic row-id prefix before any deletion. A subsequent read-only query reported zero orgs, users, devices, changes, connections, threads and display items for that org. No other tenant was selected.

The HTTP/native client processes closed their sessions and temporary outbox. Upload admin task `5b8de510e3024aee918695618e4fc227` and cleanup admin task `e4c42940d89a4673bc1baa964b4e2544` both reported `STOPPED`, desired `STOPPED`, reason `admin-shell finished`. Final `/readyz` checks on both hosted hubs reported `ok: true`, current migrations, healthy instances and healthy relay.

The local size/batching dry run and HTTP measurement self-check passed before the live run; the self-check used only a loopback response and is not live-integration evidence. The live gate is supported by the actual hub replies, content-verified pulls, materialized-row counts, attached-ACL samples and hub logs above.

Documentation validation: `Scripts/docs-index.sh --check`, `git diff --check`, and `swift format lint --strict --recursive Sources Tests Apps Package.swift`. This follow-up changes verification records and milestone status only.

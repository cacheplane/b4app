# b4app Agent Protocol client design

Date: 2026-11-05

Status: Approved by Brian on 2026-11-05 after independent specification review,
including concrete fields and protocol activation.
Canonical destination: b4app `docs/superpowers/specs/` under this filename.
A byte-identical review copy is kept with the coordinated B4 specifications.

Baseline b4app is `e15c113d4d8d5fca17475b42f34cbef7914791d4`; baseline B4 is
`c1e1796556d0863da735e47822014bafa015ef3f`. Normative wire inputs are Agent
Protocol OpenAPI 0.1.6/CDDL 0.0.20 at
`455acf2eb2c55c634350f4c6a8da117d0ecfa7b1`, with B4's explicit correction overlay.
The companion B4 wire/runtime specs pin the exact B4 v1 extensions. This client
consumes those contracts; it does not independently invent matching schemas.
No old HTTP dialect or LangSmith-specific binding remains in the new client.

## 1. Architecture and supported peers

One Foundation-only protocol transport/decoder serves standard REST, SSE and
WebSocket. A generic projection consumes standard identities/events and a B4
projection adds the negotiated recovery/receipt/permission/activity contracts.
The Coordinator remains the sole local business writer through SessionService;
UI uses WorkspaceClient, and hub/phone mirror the existing app model. No UI,
mirror or relay opens the upstream protocol with owner credentials.

Use SSE Thread observation plus HTTP commands as the initial b4app execution
path, with a real shared WebSocket transport available/tested for peers advertising
it. Do not require WebSockets merely to chat when the standard SSE/commands pair
is usable. Native AG-UI is B4's other consumer binding, not a prerequisite for
b4app or generic mode. Do not keep two copies of SSE framing/error decoding.

B4 mode requires the declared v1 recovery, receipt and permission schemas needed
for full behavior. Generic mode requires standard discovery/schemas, message-
capable input/output and the streaming/control operations needed by its selected
interaction. It does not call healthz, readyz, native AG-UI or managed-memory
endpoints and does not require B4 kind/capability/metadata markers. Omission is
unknown; fail a discovered unsupported interaction before execution and otherwise
report an unsupported operation when the peer actually rejects it. Discovery
starts no inference or disposable conversation. Generic mode has reduced replay/
receipt guarantees and cannot guess permission meanings or turn-root ancestry.
Defer first-class LangSmith path/auth/event translation to another design.

## 2. Connection/domain fields

New connections use `Connection.kind = agentProtocol`; retain old `b4` enum
records only for historical read-only data. New fields:

| Field | Value and ownership |
| --- | --- |
| peerProfile | b4 or agentProtocol; immutable; mirrored |
| agentId | exact canonical Agent ID selected from catalog; immutable; mirrored |
| target | normalized deployment base URL; immutable and owner-local as today |
| authMode | explicit none, bearer or header; owner-local; SQL NULL means unconfigured on this device |
| authHeaderName | required for header mode; NULL with absent authMode or explicit none/bearer; owner-local |
| authReference | opaque existing SecretRef; owner-local |
| protocolRetiredAt | optional timestamp on old B4 profiles; mirrored |
| protocolRetiredReason | optional fixed code agent_protocol_cutover; mirrored |

Every stored protocol profile requires complete public `peerProfile`, `agentId`
and `nativeScope`. Its owner-local auth bundle is either both `authMode` and
`authHeaderName` SQL NULL, or an explicit mode satisfying the existing header
rules. An absent bundle permits a public/imported profile to remain readable;
it is never `.none`, a credential fallback or evidence that this device owns
execution. Public updates must preserve stored private settings, references and
targets rather than replace them with scrubbed values. This does not broaden the
Mac's existing other-device RemoteApply policy.

Before any future cached adapter lookup/creation, secret resolution, discovery
or upstream request, SessionService must verify trusted current account/device
ownership and an explicit valid owner-local auth selection. Caller-supplied
owner metadata or a nil owner/auth field cannot establish that authority. This
complete execution-admission guard remains required and unimplemented by the
foundation; staged protocol execution stays unavailable.

Connection label/auth settings may change in place; endpoint/profile/agent
changes create a new connection. Managed local B4 profile retains localServerId,
environmentId, ownerDeviceId and per-project CLI launch/pins. Generic remote profiles
are never managed projects. ConnectionAdd accepts the new fields; old routeKey
is not a new-admission alias. Keep it readable on retired records only. Existing
b4Mode semantics remain for managed/attached/remote B4 classification, derived
only when peerProfile=b4. Avoid unrelated Codex/Claude domain changes.

`nativeScope` for a new protocol connection is canonical JSON serialization of
`["agent-protocol-v1",peerProfile,normalizedBaseURL]`, with connectionId as a
separate identity component. Normalize scheme/host/default port and trailing
base slash conservatively; preserve path case/encoded components. Refuse URL
userinfo/query/fragment and path escape. Encode resource IDs as path components;
all calls remain under the selected deployment prefix. Use HTTPS off loopback,
corresponding WSS, and refuse redirects. Do not reinterpret old origin-only scope
or ordinal native turn IDs as new identities. Add authenticated principal/server
identity validation when a peer actually exposes it, not by parsing a secret.

Explicit None/Bearer/named-header mode replaces whitespace-based scheme guessing.
Header mode supports x-api-key or an explicit Authorization scheme such as Basic.
Validate names/values, forbid controls and transport/framing overrides. Apply the
same credentials to catalog, REST, SSE and WebSocket handshake only at the bound
origin/base path. Keep cookies disabled and redact values from diagnostics.
GUI/CLI key entry uses the existing coordinator credential.add/SecretStore path,
clears entry fields after save, stores only a reference and deletes unreferenced
old credentials. Replacing credentials closes old adapters/streams, invalidates
auth-sensitive pending/capability caches, then rechecks access before continuation.
It neither stops an observer-independent server Run nor proves unchanged identity.
A positively changed principal requires another connection; denial never retargets
the old resource. An expired token does not authorize automatic uncertain retry.

## 3. Sync protocol activation and history retention

The new `agentProtocol` kind is not decodable by old enum-based mirrors. Therefore
this coordinated feature uses app/hub client protocol version 2. This is the
existing B4-Protocol/minClientProtocol mechanism, not a new B4 runtime endpoint.
A staged hub may install schema/support for v2 while still serving v1, but new
kind/retirement-action records are not uploaded until activation requires v2.
Have matching Mac and phone builds available before raising the minimum. At
activation, older clients receive the established upgrade-required response
before reading feeds/snapshots or issuing relay actions; no unknown-row feed
is delivered first. The release matrix records exact hub/Mac/phone minimums.
For a joined account scope, prohibit creating Agent Protocol profiles and
admitting new-protocol activity until that account has verified active protocol-2
hub support. Keep unrelated Codex/Claude edits/sync working normally. Do not
filter-and-mark-synced, hold the global sequence prefix or quarantine only a
connection row: those approaches lose changes or expose orphan child records.
The activation decision is durable/account-bound. After successful activation,
normal temporary hub outages may queue ordinary sync changes under existing
rules; owner/server offline sends remain refused. A never-joined local scope may
use the new feature, but any later hub join must negotiate active protocol 2
before any upload/snapshot merge; an incompatible join is refused without marking
its changes synced. Downgrade to a v1 hub is likewise refused for a scope holding
new-protocol data. This requires no graph-deferral/backfill subsystem. Keep relay
deadlines and ordinary owner-device execution unchanged.

Extend the existing protocol header/minimum enforcement to all authenticated
feed/snapshot/push and relay entry points, not only the baseline relay link.
New clients send B4-Protocol consistently. Activation fences/rechecks already
open pulls/links before they can disclose new-kind rows; no feed may race past
the minimum-version cut. Do not infer activation merely because a permissive
old hub accepted a header value 2; verify active minClientProtocol=2 through
the hub's existing GET /readyz. This hub check is separate from generic upstream
Agent Protocol discovery, which must not require B4 health endpoints.

Add owner-authoritative fields to Swift commands/domain/SQL, change-log allowlists,
Rust table specs/migrations, phone mirror migrations and shared changes/relay
fixtures together. Preserve local exclusions for target, authReference,
localServerId, authMode/header name and private recovery/operation/grant tables.
Hash path-containing nativeScope for sync as today. Mirror only the permitted
profile/agent/display/retirement facts. New fields cannot leak by "upload all"
reflection; inserts and updates have explicit allowlists.

Quiesce an account scope and make its normal consistent backup before schema
changes. Preserve old B4 connections, threads/items/drafts, read/pin/archive/project
associations and outcomes; apply local retirement immediately, and persist the
mirrored retirement fields only at the activation boundary described above. Their UI remains readable
from available cache, with a clear new-conversation/upgrade action. Disable send,
permission response, automatic reconnect/resubmit and runtime deletion retries
for old native IDs. Unknown old outcomes stay unknown; do not fake cancellation
to unlock UI. Exclude retired records from new admission locks after runtime
cutover; retiring a row is not evidence of stopping external work. Do not start
or probe an old managed server just to read cached history. Local historical
hide/delete remains an explicit app action and never deletes a coincidentally
reused new server UUID. Existing Codex/Claude data and process behavior remain.

A new profile can serve the same upgraded managed project with fresh native IDs;
old rows retain their original associations. A user can copy a draft deliberately;
no transcript importer, automatic initial send or old-protocol adapter is added.

### Local verification records and comparison snapshots

Keep the device-local control row at the exact reserved settings key
`__b4app_agent_protocol_activation_v1`. Its closed version1 object contains
`version`, independent uppercase `UUID.uuidString` encodings for
`storeIncarnation` and `membershipIncarnation`, and a canonical nonnegative Int64 `revision` encoded as
decimal text. Optional `binding` and `observation` are omitted when absent;
explicit null, unknown keys and malformed values refuse. Generic settings reads
and writes cannot access that exact key; NUL keys refuse before native binding
or value encoding. Opaque identities compare UTF8 bytes.

A binding contains `accountID`, `canonicalHubBase`, stable `hubUserID` and
`hubOrgID`, native `deviceID`, `databaseName` and `linkJoinedAt`. An observation
repeats that complete binding and records `healthy=true`, `reportedMinimum=2`
and `reportedVersion>=2`. These are caller-supplied comparison data. They never
prove authenticated HTTP, current account ownership, a physical lease or agent
execution authority. Snapshot values strongly retain their actual database
object and expose neither a raw record nor a public constructor/Codable form;
automatic descriptions and reflection redact identities.

Capture the actual database and exact optional native membership before the
first verification credential/HTTP await. Capture creates an inactive epoch
with INSERT-only semantics if none exists, without inventing user/org identity.
Nil membership means verified native absence. Later binding compares the exact
captured record, object, account and native tuple; it cannot adopt state written
by a restore or replacement during the await. Captured binding and positive
commit preserve that private context. Snapshots created by direct prepare/read, and commits derived from those
snapshots, have no capture context and cannot acquire it by inference.
Authenticated current-owner proof remains the Coordinator's separate duty.

Routine token/name/status refresh for the same canonical native tuple preserves
control bytes. When control exists, explicit replacement (including an
identical-looking tuple) and every clear rotate membership/revision and remove
binding/observation. Ordinary save/clear never creates absent control. A checked
link write consumes an exact captured state and returns only the epoch it
actually wrote. Expected native absence uses plain INSERT, so a concurrent
native insert causes refusal rather than being overwritten by an upsert.
Every successful restore replays all source rows normally and then creates fresh inactive
store/member identities with destination chronology in the same transaction.
Source control rows never supply destination authority or revision history.

A matching authoritative negative first fences older owner attempts, then clears
the latest observation only within the same captured store/member/account/native
epoch, with a checked revision increment. Preserve the binding and old org;
conflicting evidence cannot silently rebind a principal. Actual successful
COMMIT establishes durable withdrawal. Failure leaves current protocol-dependent
admission denied/error and supplies no durable-success receipt; an unknown
COMMIT outcome remains unknown. A negative that did not persist cannot be
reconstructed from an older positive after process loss. Preserve the existing
ordinary outage/cold-reopen policy instead of adding a hidden marker or an
always-online startup requirement. Errors expose no underlying SQL/private data.

Classify the whole store using literal positive protocol markers: the current
AP kind or any nonnull value among the six AP connection columns, any retained
row in the seven private
protocol tables, retained connection insert/update markers (including explicit
column clears), private-table change metadata, and AP connection column clocks.
Include synced history because a later join resets the whole log. Null defaults,
opaque payloads, ordinary legacy tombstones/partial history, installed schema
and the control setting alone are not markers. Use one native snapshot; this
comparison neither filters/consumes changes nor adds an ownership/replay validator.

Keep read-only verification comparison separate from sync eligibility. The
verification comparison checks the original captured object/context, full record
and actual optional membership in one native view; actual absence is valid for
a prospective proof. It must remain possible to fetch a fresh proof while a
modern workspace has an inactive record. Ordinary sync additionally requires a
current linked membership and the same-view whole-store classification; modern
material requires that exact record's healthy minimum2/version>=2 observation.
Both comparisons return no authority or lease, perform no writes and never
recapture or adopt a newer state. The owner explicitly authorizes the proof
purpose; a denied sync cannot fall back to comparison-only verification.

Compatibility-dependent native writes use the original linked snapshot before
and after the concrete effect in one transaction, including zero-row outcomes.
The guarded transaction explicitly selects READ COMMITTED before the existing
exclusive advisory lock and holds it through actual COMMIT; ordinary callers
retain their defaults. Compare the native record/membership and literal marker
classification in composed views on that same borrowed connection. A failed
postcheck rolls back transactional rows; business sequence counters and the
in-memory clock need not roll back. This orders participating framework writers,
not arbitrary raw SQL or successful deferred mutations after the final check.
Unknown COMMIT outcomes remain unknown, and this data guard authenticates nobody.

Guard all five effects: remote apply with cursor, accepted-prefix marking,
owned-row claim, push result and pull result. Push result changes only lastError
and an explicitly supplied lastPushAt, preserving the current timestamp on nil.
Pull result stores the exact Pull: prefix for an error; nil clears only a current
matching prefix and performs no row UPDATE for a nonmatching or null value.
Both push strings and a nonnil pull error reject embedded NUL inside the guarded
body before SQL parameter construction, using the fixed safe refusal. Nil and
empty inputs retain their specified meanings; no truncation or normalization is
accepted. Full local claim reannouncement is separate from outbound privacy
filtering and supplies no public-allowlist qualification.

These storage primitives remain dormant until the owner handles admission.
Cold reuse must match the closed binding to independently known account/stable
nonplaceholder user identity and actual native membership. New positive evidence
requires confined actual HTTP200 `/v1/me` and `/readyz` replies. Recheck current
ownership after credential and network awaits.
Network producers and completions require current ownership; native comparison
and apply/cursor, accepted-prefix and owned-row effects must share their actual
transaction. Install the exact scope before proof-dependent network handoff,
while preserving normal local services and unrelated work. Atomic retirement
publication, public allowlists, phone support and execution/private-auth admission
remain required parts of A4–A10.


### Owner lifecycle and cleanup admission

Use one internal concrete carrier with the original snapshot and actual database
strongly retained, and weak owner/scope/Slot handles. Register exact producer UUIDs
before launch; invalidate the committed owner's revision and UUIDs before awaited
stop, close or replacement. Old cleanup cannot invalidate a replacement. Child
checks cannot acquire the account transition lock while the owner awaits those
children. ScopeGate admission must be released before owner drain. A tentative
logout or migration decision closes the runtime work gate without revoking
ordinary sync tickets; a refused decision reopens that gate. Commit producer
revocation only when the transition is accepted. ScopeGate's temporary closing
flag alone is not permanent sync revocation.

Owner-directed cleanup uses a short-lived transition UUID and exact operation
phase bound to the original linked scope, actual database, account, configured
client/base and credential reference/token object. Final push retains full sync
compatibility for every batch, filtered-only acknowledgement and result write.
An existing in-flight push keeps its original ordinary stamp, and background name
refresh cannot inherit cleanup admission. Revoke a timed-out push phase before
session disposal; revoke disposal before credential removal, pool close or
transition completion. Late completion refuses, while already committed data and
unknown remote outcomes retain their actual meaning.

Only the named session-disposal operation may use strict same-original linked
verification without the healthy2 sync requirement. It deletes the original hub
session and carries no sync payload; it permits no push, readiness/name lookup,
profile work or new producer. Its constructor cannot accept a prospective absent
proof capture. Stale, malformed or replaced state and mismatched owner identities
still refuse without recapture. Refusal or timeout preserves honest
hubSessionLeftOpen bookkeeping and does not prevent existing local logout cleanup.
An already-unjoined scope keeps the no-session branch; failed comparison does not
prove that a session is absent. Native credential-reference freshness remains a
separate required comparison: the current verification validator does not compare
hubLink.tokenRef, and memory equality is not a native freshness receipt.

Owned HTTP and WebSocket handoff must use retained concrete tasks and a final
synchronous admission check at resume or the completion-handler send call.
Preserve cancellation-before-install handling, once-only completion, primary
admission errors, and task-specific identity redirect refusal. Every owned
application-frame path, including ping, unknown replies and queued entries,
retains its original stamp. Arbitrary delayed transports must support that actual
boundary or refuse owned use. The ticket check linearizes local admission;
invalidation after it cannot recall admitted work or all Foundation protocol,
retry, redirect or TLS traffic. Cancellation is not completion. Never hold mutexes
over SQL, callbacks, transport completion or awaits to imply a stronger guarantee.

Publish only after actual native commit, with a final current-owner/ticket check
and the existing withVisibleThread fence inside the isolated EventLog turn before
append. The callback's ticket check is memory-only and cannot reenter the database;
no native lease crosses an actor await. Environment and view events also need the
original-owner comparison. Dormant carrier comparisons alone qualify no transport,
producer, cleanup or publication consumer; these integration gates remain open.

## 4. Durable owner-local projection

Add non-synced storage entities for upstream subscription state, canonical Run
segments, immutable outgoing operation intents, private grant material, staged
prompt answers and snapshot/history anchors. Existing turns/displayItems/
runtimeRequests remain the synced presentation. Canonical initial Run UUID is
the native user-turn ID; each continuation is a segment associated with that
root. Local row IDs remain stable across acknowledgement/reconciliation.

The unpublished local schema is migration 14 after immutable published Store
11/12 and D-208 viewSettings13. `protocolSubscriptions` requires exactly one of native `generation` or
`localObservationEpoch`. Generic observation uses the latter as a durable local
incarnation, never a claimed server generation. `protocolRunSegments` stores
nonempty `identityEpochKind` (`b4` or `local`) and `identityEpochId`; its PK is
`(connectionId,threadId,identityEpochKind,identityEpochId,namespace,nativeRunId)`.
B4 projection must bind the epoch to the validated native generation; generic
projection binds its separate local epoch. Preserve native IDs and namespace
component arrays. Retained older segments have no FK to the subscription's
current epoch, so changing that subscription does not erase old associations.

Every current14 reopen, including no-pending admission, verifies the two epoch
tables' canonical public identity, all live columns in order, builtin types,
typmod, nullability and valid ordered PK. An unexpected typmod column cannot be
filtered out of this inventory. This catalog check does not inspect CHECK
expressions: the native/local XOR and allowed epoch-kind predicates are SQL
invariants with separate insert controls. Original development protocol13 ledger aliases and incompatible epoch-table
shapes refuse unchanged; do not invent an epoch or
adopt an old draft as the new canonical schema.

Protected archive v4 requires the exact header discriminator
`protocolSchema: "generation_epochs_v1"` for prefix14, even with no protocol rows.
Prefixes through published viewSettings13 have explicit closed inventories and reject that marker.
Missing/unknown markers or old development protocol archives refuse; no implicit generation backfill is
performed. This is an unpublished v4 refinement, not a shipped compatibility
claim. Preserve the original13 DDL as a negative fixture and every published
11/12 byte. Current source review is not native qualification of these changes.

Persist an applied upstream batch in one local Postgres transaction: partial
text/blocks, activity/dispositions, Run/root links, sanitized pending presentation,
private grant updates and applied eventId/seq/coverage/generation. Publish viewer
notifications only after commit. No detached adapter cursor may advance ahead
of these facts. A failure pauses advancement, marks the view stale and recovers
from the last committed position; do not catch a write error and publish success.
Partial/open output is durable and never completed merely because a stream closes.

Event identity includes deployment/connection, Thread generation, namespace and
native message/block/tool/Run IDs. Deduplicate at the durable watermark and by
stable item identity; do not append duplicate text or usage on replay. Keep ASP
seq/eventId distinct from Coordinator EventLog epoch/sequence and hub HLC/device
sequence. A filtered numeric gap is legal. Widening coverage requires recovery
for newly included channels/namespaces, not blindly reusing the cursor.
Never bind an event by fallback to whichever local turn is active.

An event may precede its command acknowledgement. Persist unresolved canonical
segment correlation, read the authorized Run/receipt to link submissionId to
local intent, and atomically merge the optimistic row rather than duplicate it.
Import other clients' new roots as remote history, not local outgoing sends.
Unknown optional activities/blocks preserve opaque content and explicit unknown
presentation; unsupported B4 major versions fail negotiation before action.

The local EventLog stays bounded/in-memory with a fresh epoch after restart.
Overflow/restart requires a fresh local database snapshot. A second durable
viewer journal is unnecessary. Durable upstream partial state, not volatile
streamed strings, is the source for restart reconstruction.

## 5. Thread creation, sends and uncertain acknowledgements

Mint/persist the native Thread UUID before POST /threads with
if_exists=do_nothing; an exact creation retry cannot merge new metadata or change
workspace attachment. For B4, recover a new Thread snapshot H=0, observe passive channels since H
and send run.start using selected assistantId. Generic mode uses the peer's
standard observation/state facilities without requiring B4's H/generation data. Passive observer
loss does not cancel execution. Avoid POST /runs/stream merely to obtain a stream
whose owning-disconnect semantics differ from this app interaction.

For each online user send, persist operationId, exact normalized payload/target,
expectations/fingerprint and local optimistic turn/user item atomically before
network dispatch. Embed operationId as metadata.b4.submissionId. Do not queue
new turns while owner/required server is offline. Save receipt/Run ID before
reporting acknowledged. Merely transmitting bytes or seeing matching message
text is not acknowledgement. Acceptance is distinct from completion.

After loss/restart, query POST /runs/search with the exact reserved literal
metadata selectors b4.submissionId, b4.submissionKind=b4 and the known original
operationThreadId/targetRunId selectors from the B4 wire spec (limit 1, offset 0).
Read metadata.b4.lookup for accepted/expired receipt state and the actual Run;
query-scoped receipt lookup also covers injections sharing one Run. Use GET Run
and coherent recovery for current outcome after correlation. Empty results or
submission_target_gone are reconciliation states, not proof of non-acceptance. Exact retransmission is permitted only under the
negotiated valid receipt guarantee, unchanged target/payload and still-valid
user intent; never blindly dispatch prepared/unresolved records at startup or
mint a replacement token. Full receipt expiry does not prove non-acceptance.
Unknown outcome remains visible with a specific reconciliation action. Generic
peers without such receipts must not be auto-resubmitted. No automatic provider,
account, billing mode or new-session fallback masks the failure.

Run status interrupted alone is not a permission wait or user cancellation.
B4 reads current turn/continuation reason and full pending set. Generic mode
uses only supported standard facts and preserves ambiguity. Stop targets the
exact current canonical Run UUID, not root/predecessor/thread identity; wait for
real settlement or show unresolved stopping. Never redirect a stale Stop to a
successor. Stop acceptance is a cooperative request, not proof of completion:
a running native superstep and required writes may finish before drain is observed.
Natural completion, independent failure and permission parks retain their real
outcomes; show them even if a Stop request was accepted. An exact Stop against an
already parked predecessor may retire its continuation without executing it.
Hard loss and started invocations settled under hard abort remain uncertain;
an invocation boundary is not proof of raw or remote-effect quiescence, and no
remote-effect rollback is implied. Sending
an answer adds no user-message turn.

## 6. Snapshot, paging and prompt recovery

For B4: authorize Thread GET at H, atomically hydrate its covered standard
messages/state and recovery projection/cursor, then observe since H with generation.
Preserve local preferences/drafts/unresolved intent and older loaded pages outside
the declared coverage. Reconcile optimistic rows by identity, not text/timestamp.
Expired H repeats recovery; no silent jump. History uses returned nextBefore
under its pinned anchor/revision and merges without overwriting later facts.
Rollback/state edit/deletion invalidates covered lineage and in-flight stale
history results cannot resurrect it. A recreated server/thread cannot inherit
an old cursor. Missing/inaccessible state is explicit; permitted cache remains
readable as historical/stale with action controls disabled.

A coordinator/adapter restart marks cached B4 actions unverified, not permanently
expired merely because adapterGeneration changed. Fetch the full current pending
set with current eligibility. Private grant material stays in owner-local protected
storage and never enters viewer EventLog, synced runtimeRequests/display payload,
logs or UI state. Store only sanitized prompt presentation, allowed choices,
response schema, local request/paused-generation reference and disposition in the
public app model. Its backup/export treatment remains account-protected and
excludes endpoint secret values; outstanding obligations are not dropped.

Collect user choices per exact paused generation/namespace/interrupt/proposal.
Persist drafts; submit one full batch when complete. Pending-set/proposal changes
invalidate affected drafts and require renewed choice. A tap is not resolution;
server receipt/current facts decide. Mac/phone competing answers serialize through
the owner then server; losing stale answers cannot execute or become fresh input.
The phone sends its local request reference/generation and choice, never a grant.
Owner reauthorizes/currently validates before using private authority. Preserve
existing relay deadline/first-answer behavior and offline refusal.

Handle only negotiated b4.permission v1 as once/always/deny. Hide Always when
unsupported. Expired positive approval is disabled; eligible negative abandonment
and whole-turn Stop remain distinct. Never auto-reapply cached approval to a
fresh generation. Unknown generic prompt schemas remain visible/cannot-answer;
never guess once/always/deny or fabricate a successful decline. No new memory
review UI is required in b4app; Store HTTP and Navlog review are separate consumers.

## 7. Verification, decisions and scope

Update B4HTTPClient/B4Protocol/B4Events/B4TurnTranslator callers into the shared
standard transport and extension projection; SSEParser retains correct framing
and now reads id explicitly. Scope SessionService/storage transaction changes
to Agent Protocol behavior while preserving other adapters' process-bound
request expiration and directory/process ownership guarantees. Update managed
inspection to catalog/agent schemas and truthful health versus readiness checks.
GUI settings/new-thread sheets use discovery, typed auth and retirement state.

Rewrite fake-b4 to expose only the approved contract; create strict generic
fixtures omitting all B4 extras. Test actual coordinator/private Postgres and
Swift/Rust/phone fixtures, not only translator functions. Fault-inject all local
commit/server-acceptance/ack boundaries, partial restart, response races, key
rotation, generation/filter changes, rollback/deletion and old-data retention.
Use packed/published matching B4 for live local and authenticated remote tests,
a packaged target Mac and physical phone for changed device claims. Include joined-v1 feature refusal,
unrelated sync through restart, delayed mirrored retirement writes, activation
without lost changes, and a refused
v1 join for never-joined local new-profile data. Preserve
CI's opt-in live-provider rule and the existing acceptance matrix. Record build,
fixture, live and blocked evidence separately in compatibility/milestones/new
gate files. Add new numbered decisions amending D-019/020/021/023 and the relevant
connection/sync rules; never edit old decision files or the owner's roadmap.

The approved new kind/protocol-v2 activation and B4 wire names are design
choices, not changes performed in this branch. This standalone client spec is
ready for task planning; it is not an implementation plan or
permission to publish, upgrade projects or delete old data.

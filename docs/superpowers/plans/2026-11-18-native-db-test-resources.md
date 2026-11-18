# Native DB test resources

Date: 2026-11-18. Source baseline: `a33a2901d7660079e4f1a1db70000247c2957e46`, tree `989501b8c2931d057b8c44341993c43bea74bdb2`.

This plan supplies selected native database test cases with owned execution resources and repairs three demonstrated fixture scheduling exposures. It changes test resources and source hash literals only. Product code, test identities, parameter cases, assertions, cleanup ownership, parallel scheduling and lane budgets remain unchanged. This document records a candidate design, not a passing result or a decision number.

## Evidence and limits

The baseline managed package job built and compiled tests. Focused native 41 passed in 66.511 seconds; the default invocation also passed native 41 and selected 86 companions, with physical 55 passing. These results apply to that source only. Foundation had three methods with six issues, and the default lane had 30 methods with 35 issues. The package job reached its 45 minute limit and was cancelled. The physical writer recorded no tests, publication was skipped, and the app did not acquire a runner. Serial and whole-run evidence must be preserved and audited separately; this candidate inherits no passing credit.

The first stale-callback fixture returned false at `callbacksMigrationLockObservation`; its second fixture was not armed. The owner fixture was already past its ten second observation cap when collector readiness returned (14 to 13,805 milliseconds); its two genuine collector joins were prompt at the reported resolution. The admission fixture failed its held-window and drained assertions, but its old log lacks release-order timing. These observations support separate resource hypotheses. They do not prove a universal cause for all default failures or an exact unrecorded admission interleaving.

## Execution resource policy

`NativeDBResources` conforms to the public `TestTrait`, `SuiteTrait` and `TestScoping` protocols, recursively. Each executing case allocates a new `NativeDBCaseExecutor` inside `provideScope`. The executor owns a concurrent DispatchQueue, is retained through the body, and retains itself in every enqueued job. `withTaskExecutorPreference` invokes the original runner function exactly once on the existing runner Task. Errors, cancellation, task locals, runner priority semantics, actor isolation and actual cleanup remain intact. There is no extra root Task, shared queue, global permit, serialization, retry, new time limit or deadline guarantee.

The two identical internal helper definitions reside in the existing `Tests/CoordinatorTests/InspectionObservation.swift` and `Tests/WorkspaceStorageTests/AgentProtocolResourceFixture.swift`. No Swift file, target, common module or package dependency is added. The public APIs are source-qualified against Swift 6.2 and Swift Testing 6.2; actual package compilation targets macOS 26. Compilation still requires fresh managed verification.

Structured task groups and async-let children can inherit the resource preference. Ordinary `Task {}`, detached Tasks and Subprocess uncancelled cleanup do not inherit it. MainActor and custom actor requirements remain. Discovery, parameter generation and independent server/HubSync Tasks are outside the policy. A preference supplies scheduling resources and cannot prove physical deadlines, descendant quiescence, thread exit, ARC/PQfinish, ABI, imports or build freshness.

## Finite source-classified scope

Exactly 71 existing suite arguments and 298 existing method arguments cover 797 of 962 source test methods in the two native targets; 165 methods remain omitted. Whole-suite recursive inheritance includes same-type extensions and is never duplicated at their methods. Mixed suites receive only their listed method arguments. Existing display names remain first, new traits precede labeled macro arguments, and existing traits and argument values retain their order. The implementation itself is the finite member roster; the following table fixes its suite-level partition and selected source method counts. Pure value, schema-only, metadata, bare socket controls, MainActor and UI paths stay outside the policy.

| Target | Existing suite | Scope | Selected source methods |
| --- | --- | --- | ---: |
| CoordinatorTests | `AccountCommandTests` | recursive suite | 30 |
| CoordinatorTests | `AccountCLITests` | recursive suite | 4 |
| CoordinatorTests | `AccountManagerTests` | recursive suite | 14 |
| CoordinatorTests | `LegacySecretCopyTests` | recursive suite | 7 |
| CoordinatorTests | `AccountSessionComparisonOwnerTests` | recursive suite | 26 |
| CoordinatorTests | `AgentProtocolAccountMigrationRetentionTests` | recursive suite | 4 |
| CoordinatorTests | `AgentProtocolAccountMigrationControlTests` | recursive suite | 3 |
| CoordinatorTests | `AgentProtocolAccountMigrationTests` | recursive suite | 5 |
| CoordinatorTests | `AgentProtocolArchiveATests` | listed methods only | 7 |
| CoordinatorTests | `AgentProtocolConnectionIdentityTests` | recursive suite | 4 |
| CoordinatorTests | `AgentProtocolGrantCredentialTests` | recursive suite | 6 |
| CoordinatorTests | `AgentProtocolLegacyManagedTests` | recursive suite | 3 |
| CoordinatorTests | `AgentProtocolMigrationBackupPathTests` | recursive suite | 2 |
| CoordinatorTests | `AgentProtocolPrivateBackupTests` | recursive suite | 3 |
| CoordinatorTests | `AgentProtocolRetirementTests` | recursive suite | 14 |
| CoordinatorTests | `AgentProtocolUnicodeIdentityTests` | recursive suite | 1 |
| CoordinatorTests | `CoordinatorSocketTests` | recursive suite | 8 |
| CoordinatorTests | `CoordinatorAdoptionOrderTests` | recursive suite | 4 |
| CoordinatorTests | `EnvironmentServiceTests` | recursive suite | 15 |
| CoordinatorTests | `ConnectionEnvironmentTests` | recursive suite | 4 |
| CoordinatorTests | `HubLinkRelayTests` | listed methods only | 18 |
| CoordinatorTests | `AgentProtocolHubOwnerCarrierTests` | recursive suite | 16 |
| CoordinatorTests | `HubPullTests` | listed methods only | 6 |
| CoordinatorTests | `HubSyncTests` | recursive suite | 13 |
| CoordinatorTests | `KeepAwakeTests` | listed methods only | 6 |
| CoordinatorTests | `LocalServerRegistryTests` | recursive suite | 5 |
| CoordinatorTests | `LocalServerLifecycleTests` | recursive suite | 13 |
| CoordinatorTests | `LocalServerLogTests` | recursive suite | 2 |
| CoordinatorTests | `ManagedConnectionTests` | recursive suite | 5 |
| CoordinatorTests | `LocalServerRemoveTests` | recursive suite | 3 |
| CoordinatorTests | `OwnedCloseConcurrencyTests` | listed methods only | 2 |
| CoordinatorTests | `PairingTests` | recursive suite | 13 |
| CoordinatorTests | `PairingSocketTests` | recursive suite | 1 |
| CoordinatorTests | `RelayExecutorTests` | listed methods only | 27 |
| CoordinatorTests | `ScopeOwnerPublicationTests` | recursive suite | 17 |
| CoordinatorTests | `SessionServiceTests` | recursive suite | 8 |
| CoordinatorTests | `ClaudeSessionServiceTests` | recursive suite | 8 |
| CoordinatorTests | `ClaudeTurnOptionsTests` | recursive suite | 4 |
| CoordinatorTests | `LocalThreadStartTests` | recursive suite | 5 |
| CoordinatorTests | `NoFolderStartTests` | recursive suite | 12 |
| CoordinatorTests | `B4SessionServiceTests` | recursive suite | 6 |
| CoordinatorTests | `ThreadOrganizationTests` | recursive suite | 4 |
| CoordinatorTests | `ContinuityTests` | recursive suite | 7 |
| CoordinatorTests | `RecoveryTests` | recursive suite | 2 |
| CoordinatorTests | `FailureTests` | recursive suite | 2 |
| CoordinatorTests | `LifecycleTests` | recursive suite | 2 |
| CoordinatorTests | `RedactionTests` | recursive suite | 1 |
| CoordinatorTests | `RuntimeCommandProfileFoundationTests` | listed methods only | 1 |
| CoordinatorTests | `TaskListSessionTests` | recursive suite | 4 |
| CoordinatorTests | `SocketClosePreservationTests` | recursive suite | 2 |
| CoordinatorTests | `ThreadDeleteTests` | listed methods only | 12 |
| CoordinatorTests | `UsageTests` | listed methods only | 14 |
| WorkspaceStorageTests | `AccountRegistryTests` | listed methods only | 9 |
| WorkspaceStorageTests | `AccountSessionComparisonTests` | recursive suite | 15 |
| WorkspaceStorageTests | `ActivityQueryTests` | recursive suite | 11 |
| WorkspaceStorageTests | `AgentProtocolAppFolderArchiveIntegrationTests` | listed methods only | 7 |
| WorkspaceStorageTests | `AgentProtocolBackupBoundaryTests` | recursive suite | 4 |
| WorkspaceStorageTests | `AgentProtocolBackupTests` | recursive suite | 4 |
| WorkspaceStorageTests | `AgentProtocolEnvironmentHistoryIntegrationTests` | recursive suite | 7 |
| WorkspaceStorageTests | `AgentProtocolGenerationSchemaTests` | listed methods only | 8 |
| WorkspaceStorageTests | `AgentProtocolMainSchemaAdmissionIntegrationTests` | recursive suite | 3 |
| WorkspaceStorageTests | `AgentProtocolMigrationAdmissionTests` | recursive suite | 4 |
| WorkspaceStorageTests | `AgentProtocolMigrationPoolDrainTests` | recursive suite | 5 |
| WorkspaceStorageTests | `AgentProtocolMigrationTests` | listed methods only | 8 |
| WorkspaceStorageTests | `AgentProtocolPoolTests` | recursive suite | 1 |
| WorkspaceStorageTests | `AgentProtocolPrivateSchemaTests` | listed methods only | 3 |
| WorkspaceStorageTests | `AgentProtocolProfileAuthArchiveTests` | recursive suite | 1 |
| WorkspaceStorageTests | `AgentProtocolProfileSchemaTests` | recursive suite | 5 |
| WorkspaceStorageTests | `AppFolderStoreTests` | recursive suite | 4 |
| WorkspaceStorageTests | `ChangeLogTests` | recursive suite | 7 |
| WorkspaceStorageTests | `ConversationStorageTests` | recursive suite | 4 |
| WorkspaceStorageTests | `SnapshotMergeTests` | recursive suite | 10 |
| WorkspaceStorageTests | `DatabaseTests` | recursive suite | 9 |
| WorkspaceStorageTests | `EnvironmentHistoryGuardTests` | listed methods only | 19 |
| WorkspaceStorageTests | `EnvironmentHistoryMigrationTests` | listed methods only | 1 |
| WorkspaceStorageTests | `EnvironmentStoreTests` | recursive suite | 14 |
| WorkspaceStorageTests | `HubLinkTests` | recursive suite | 2 |
| WorkspaceStorageTests | `LegacyHubURLTests` | recursive suite | 3 |
| WorkspaceStorageTests | `OrganisationSchemaTests` | recursive suite | 12 |
| WorkspaceStorageTests | `OwnedProtocolProofWriteTests` | listed methods only | 54 |
| WorkspaceStorageTests | `OwnedRowsTests` | recursive suite | 3 |
| WorkspaceStorageTests | `ProtocolActivationRestoreTests` | recursive suite | 7 |
| WorkspaceStorageTests | `ProtocolActivationStoreTests` | listed methods only | 81 |
| WorkspaceStorageTests | `ProtocolProjectionStoreTests` | listed methods only | 12 |
| WorkspaceStorageTests | `RelaySchemaTests` | listed methods only | 2 |
| WorkspaceStorageTests | `RemoteApplyTests` | recursive suite | 27 |
| WorkspaceStorageTests | `SQLiteImportTests` | recursive suite | 5 |
| WorkspaceStorageTests | `ThreadDeleteStoreTests` | recursive suite | 4 |
| WorkspaceStorageTests | `ThreadEventVisibilityTests` | recursive suite | 2 |
| WorkspaceStorageTests | `UsageStoreTests` | recursive suite | 4 |
| WorkspaceStorageTests | `ViewSettingsStoreTests` | recursive suite | 10 |
| CoordinatorTests | `SocketLifecycleTests` | listed methods only | 1 |

The selected entries have direct database creation, `WorkspaceDatabase`, `PostgresConnection`, synchronous SQL, or a local fixture chain reaching those operations. Their terminal witnesses include `EphemeralPostgres`, account/session setup, archive/migration fixtures, registry operations and storage constructors. The policy touches 69 existing Swift files including the two helpers. CoordinatorTests keeps its exact 51 Swift paths. The non-database method census of 1,657, native 41 identities and model 17 identities remain source invariants, not new runtime results.

## Three fixture changes

1. The first `oldInstanceCallbacksCannotMutateReplacement` fixture uses the existing retained migration subject preference and bounded-close injection. A native observer Thread polls the unchanged PostgreSQL waiter query against a fixed three second deadline constructed before dispatch. Late Thread startup receives no new window, and native success completed after the deadline remains false. The writer transaction, pending transition, delayed callbacks, replacement and stale-state checks, three/15 second caps, observation labels and real retained subject joins remain. The second fixture's resources, guards and joins remain unchanged.
2. Owner fixture orchestration uses `withTaskExecutorPreference` on the existing caller Task and supplies the same per-fixture resource explicitly to its original retained collector Task. Ownership is registered as before; the executor remains retained through fixture cleanup and the real collector join. Both collector.value joins, setup and observation deadline startpoints, ten second caps, predicates, final guard, source socket-close witness, cleanup, counters and privacy remain. An open counter increment before handoff is not readiness.
3. Admission retains its borrower/drainer native operations and the real two second `closeForMigration`. A retained native controller starts synchronously before the drainer can begin, performs the two second started observation and 75 millisecond held observation, then signals the real borrower release. Its deadline is fixed before dispatch. The existing two second ready observation, eight second borrower guard, actual borrower.result/drainer.value joins, errors and assertions remain. The controller completion is also joined before emitting fourteen bounded, closed-label ordering/timestamp slots on one monotonic origin. Missing values remain unknown. These are genuine operation-result joins, not Foundation/kernel Thread.join, thread exit or physical quiescence. Stamps do not supply a physical waiting or universal-cause proof.

## Capacity and immutable wiring

A concurrent queue per active case can allow more native work to progress. It does not cap workers or connections. The shared PostgreSQL cluster has a 300 connection maximum; private admission clusters default to 20; each database pool is lazy with size four, plus independent inspectors, registries and admin connections. CPU, memory, disk, CREATE DATABASE contention, process load and GCD capacity remain constraints. No capacity increase, hidden permit or shared serialization compensates for them.

Only four touched source literals in the existing three C6 dictionaries are refreshed: HubOwnerCarrierTests, OwnedProtocolProofWriteTests, AccountSessionComparisonTests and AccountSessionComparisonOwnerTests. The 17-entry pin structure remains. Matching workflow source literals, helper SHA, metadata guard and all eleven bootstrap guards are synchronized. Checker logic, vectors and workflow wiring remain unchanged. The 51/55/52 source/input/output, 116 argument-template, 33 control and eleven profile expectations remain pending fresh observation. Four ordinary mac jobs, serial wiring, selected NIO callback queues, existing command diagnostics, 45 minute package, 30 minute App builds and 20 minute Mac smoke limits, filters, conditions, retention and current positive controls remain intact.

## Required review and managed acceptance

Before adoption, preserve the complete baseline run, perform Root review and a fresh independent full audit, and review this full candidate with RootSPEC plus a new independent source-quality review. Verify exact annotation inversion, unchanged test names/signatures/arguments, the 962/1,657/native 41/model 17 source lists, all 17 pins and synchronized helper/workflow guards. A formatter parse is not compilation or test credit. No local Swift/compiler/build/test/SwiftPM, native, application, process or API runtime probe qualifies this change.

After those prerequisites and immediate branch/main/head/PR/run/index/clean guards, adopt only the exact reviewed candidate on the owned branch and push normally. Fresh managed ALL CI must establish compilation, actual C6 metadata, focal/model/native/companion/foundation/default/serial tests, physical writer/publication and app results. Earlier passes do not transfer; failed-run merging has no waiver. The squash/ALL GREEN queue and actual merge-group/main validation remain required. Existing release, SDK/npm, production, activation, A4–A10 and live HTTP holds remain HELD.

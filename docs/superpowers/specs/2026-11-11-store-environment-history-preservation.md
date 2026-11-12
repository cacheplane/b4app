# Pending Store environment history preservation

Decision: [D-206](../../decisions/D-206-store-environment-history-preservation.md). Qualification: [dated verification record](../../verification/2026-11-11-store-environment-history-preservation.md).

## Scope

Protect the workspace PostgreSQL Store while `0011_environments` is pending. Keep the published SQL bytes, names and per-file ledger semantics. `0012_app_folders` remains the published app-folder migration. Already applied migration 11 skips preservation and repair. Account-registry migration behavior remains independent.

The public `Migrator.files()` labelled tuple API remains compatible. Internally each resource is read once into immutable `Data`. Pending migration 11 requires raw SHA256 `27e0b795663bb2a85922b0b7637cd6764c12bf3ee6e69913398c080528f58386`, then decodes and executes that same buffer. A separately supplied SQL string or a reconstructed resource is not accepted as its identity.

## Migration ownership and admission

Acquire database-scoped session advisory key `0x6234_6d69_6772_6174` on the constructor's fresh private connection, outside a transaction and before ledger lookup or creation. Hold it through the complete pending chain, including migration 12; keep one transaction per file. This key is distinct from the transaction-scoped remote-apply lock.

Require `current_schema()` to be public, authentic public relations and matching unqualified resolution. The migration ledger must be a permanent public table with text, non-null `name` and `appliedAt`, and a valid primary key on `name`. Refuse shadow/temp objects, unexpected native types and active row filtering. Leave row-security flags untouched. Preserve the explicit future-version refusal.

## Migration-11 transaction

1. Begin inside the fixed-error boundary. Before any snapshot-producing query or setting, acquire ACCESS EXCLUSIVE locks in frozen DDL order: public projects, projectFolders, threads, connections, changes and columnClocks. This lets a writer ahead of the migrator become visible under repeatable read.
2. Validate relation, index, trigger, function, sequence and type identities. Refuse pre-existing reserved temporary witness objects and ambiguous true structural inserts containing both root reference keys. Set the transaction-local search path to public, so the frozen unqualified function replacement targets the existing public function.
3. Capture native feed rows, their JSONB/text values, clocks, business sequence, object identities/flags and prior ledger rows. Keep numbers in PostgreSQL; do not decode through Swift JSON or floating point.
4. Execute the exact published SQL. Insert migration 11 with one timestamp at the existing post-SQL point, requiring one inserted row.
5. Restore only opaque `changes.value` cells by sequence. A true structural insert has `op=insert`, SQL-null column, and old table projectFolders, threads or connections. Only its root projectId reference becomes environmentId; arbitrary update payloads keep their original root keys. Nested-only objects, arrays, scalars and SQL null stay unchanged.
6. Verify the complete feed keyset and expected whole rows/text, allowing only the published metadata and true structural reference transformations. Verify clock transformations, business sequence, renamed identities/flags, function identity, the exact new ledger row and unchanged earlier ledger rows. Commit before releasing the call-wide lock.

The guard does not disable triggers, rewrite whole history rows or change row-security policy. Conflicting native customizations that violate its invariants fail the migration.

## Errors and completion

Preservation, lock and admission failures return internal error `Store environment history preservation failed.` without native SQL, payload-bearing DETAIL/CONTEXT or an underlying error chain. Operator PostgreSQL logs and libpq notices remain separate concerns. Ordinary non-11 migration errors keep their existing contract.

Attempt rollback before unlocking after a migration failure; preserve the primary error when cleanup also fails. Require a successful unlock on the success path. An unlock failure after an already committed file fails initialization without promising chain rollback. Loss of transport during COMMIT has an unknown outcome and is not retried automatically. The constructor's existing failure path closes its unreturned private pool; this is not an additional raw-libpq shutdown guarantee.

## Qualification boundary

The required native matrix must cover opaque/structural values, ambiguity, authentic admission, native restore/commit faults and error privacy, concurrent writers under both isolation modes, constructor serialization through commits 11 and 12, already-applied/idempotent history, future-version refusal and per-file retention when a later migration fails. New source controls complement the unchanged causal regression and existing migration/registry/clock tests.

Source review and actual managed-CI results must be recorded separately. Native BEGIN/transport/unlock edge cases remain unclaimed without a concrete test. Standard CI does not establish custom local process custody or retained-database guarantees. This work does not qualify or activate the unfinished Agent Protocol client or authorize coordinated publication.

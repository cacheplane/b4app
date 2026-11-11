# Preserve opaque Hub history during the environment rename

## Problem and scope

Frozen Hub migration 18 renames projects to environments. Its JSONB rewrite can also rename a top-level `projectId` inside an opaque sync value. Such a value belongs to the recorded application payload, so changing it changes history. The migration file and its published checksum must stay unchanged.

Guard only a pending migration 18 in the public Hub migration runner. Keep structural references renamed, including insert envelopes for project folders, threads and connections. Preserve opaque values and their recorded byte counts. An already applied migration is left alone: reconstructing an original value requires trustworthy preimages and is separate work. This change does not implement the corresponding local workspace Store fix or activate the pending protocol client.

## Transaction and migration ownership

Wrap the public SQLx `Migrate` connection contract. Delegate every operation and every other migration to SQLx. For exactly the expected transactional, simple migration 18, begin an outer tracked transaction, acquire the six affected table locks in migration order before the first snapshot read, capture preimages, and delegate the original SQLx apply operation inside its tracked savepoint. The original SQL, checksum, migration ledger insertion and execution-time update remain in that transaction.

Restore and verify preimages before committing the outer transaction. `apply` returns only after that commit, so the SQLx session migration lock remains held through restoration and commit. The public runner owns its connection and consumes it with `close()` on both success and failure; a failure never authorizes reuse of a connection with a session lock or queued rollback.

## Native values, keys and access

Capture affected opaque JSONB values and `value_bytes` in a transaction-local temporary table keyed by `(org_id, hub_seq)`. Native JSONB and integer values stay in PostgreSQL. Verify relation identity, row counts, keys, full values and byte counts while restoring them. Structural insert envelopes keep the standard rename; a structural envelope containing both old and new keys is refused before mutation. The same keys inside opaque payloads are preserved.

Use table ownership rather than production superuser or `BYPASSRLS` privileges. Temporarily remove FORCE RLS as required for owner access inside the transaction, verify that row security is inactive, and restore each table's original enabled/FORCE flags. Ordinary application roles cannot run the migration. Non-superuser migration owners retain the existing provisioning requirements.

## Failure behavior and compatibility

Beginning, capturing, delegated application, restoration, rollback and commit failures return the fixed preservation error without attaching native database errors that might contain payloads in DETAIL or CONTEXT. The primary migration failure survives a later connection-close error. PostgreSQL operator log configuration is outside this application-error guarantee.

Ordinary schema and migration behavior is preserved. Arbitrary custom triggers are not a compatibility promise: a deferred trigger on `changes` can conflict with the subsequent RLS DDL. The regression requires safe refusal and rollback for that interaction. No trigger is disabled, checksum changed, history guessed, or failed fixture deleted to make the migration pass.

## Qualification

Keep genuine raw-SQL and public-runner failure evidence separate from guarded passing tests. Test opaque JSONB and byte counts across two organizations with equal `hub_seq`, all four enabled/FORCE combinations, non-superuser ownership, application-role refusal, ambiguous structural values, immediate restore failure, deferred outer-commit failure, blocked writers and concurrent public runners. Deferred commit controls attach to the native migration ledger so they reach commit without colliding with the guard's RLS DDL; the collision has a separate rollback control.

The required full workspace formatting, clippy, real-PostgreSQL tests and repository CI must qualify the final current-main source before merge. Narrow results from an earlier base do not satisfy those combined-source gates. The local Store, protocol-client integration and coordinated release remain separate gates.

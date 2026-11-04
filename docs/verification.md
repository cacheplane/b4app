# Verification record

Gate results and unresolved checks, one file per record in [`docs/verification/`](verification/), named `YYYY-MM-DD-<slug>.md`. Each entry names what was exercised, how, and what remains open. Live checks are only those run on the target Mac against real runtimes.

Each file begins with `## YYYY-MM-DD: <title>` and holds the record under it, with its own `###` sections where it has them. Since D-174 the record is a directory so that parallel pull requests, each adding a file, never conflict.

- Newest first: `Scripts/docs-index.sh` writes `docs/verification/index.md`, one line per record. It is generated and gitignored (a committed list would conflict between pull requests); on GitHub, the directory listing is the index.
- Adding a record: `AGENTS.md`, "Decisions and gate records". The file is `docs/verification/YYYY-MM-DD-<slug>.md`, and `Scripts/docs-index.sh --check` must pass. Nothing is added to this page.

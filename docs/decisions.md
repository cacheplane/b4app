# Decision log

Material implementation decisions, one file per decision in [`docs/decisions/`](decisions/), named `D-NNN-<slug>.md`. The spec (`docs/roadmaps/Personal_Agent_Workspace_Technical_Spec_and_Roadmap.md`) is the requirement source; the log records deviations and choices the spec left open.

Each file begins with the dated topic heading the decision was recorded under (`## YYYY-MM-DD (topic)`) and holds the decision as one `- **D-NNN Title.** ...` bullet with its nested lines. An amendment to an earlier decision is recorded in the later decision's file ("amends D-NNN"); the earlier file is not rewritten. Since D-174 the log is a directory so that parallel pull requests, each adding a file, never conflict.

- Newest first: `Scripts/docs-index.sh` writes `docs/decisions/index.md`, one line per decision. It is generated and gitignored, because a committed list would conflict between pull requests exactly as this file once did; on GitHub, the directory listing is the index.
- Adding a decision: `AGENTS.md`, "Decisions and gate records". In short, `Scripts/docs-index.sh --next` gives the number when the pull request opens, the file is `docs/decisions/D-NNN-<slug>.md`, and `Scripts/docs-index.sh --check` must pass. Nothing is added to this page.

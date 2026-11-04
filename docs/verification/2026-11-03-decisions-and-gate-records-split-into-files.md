## 2026-11-03: Decisions and gate records split into one file each (D-174)

Branch `blove/docs-per-file-498bec`, from main at `aed0c2e`. `Scripts/split-docs.py` (in this pull request's history, removed before merge) split `docs/decisions.md` into 162 files under `docs/decisions/` and `docs/verification.md` into 70 under `docs/verification/` (71 after `origin/main` was merged just before the pull request opened and the split re-run), then proved that the non-blank lines of every section come back, in order, from the files written for it, with each section's heading once.

| Check | Result |
| --- | --- |
| Decision text | 36,723 words of entries before and after (`wc -w` of everything but the `##` headings and the three-line preface). The 49 section headings (284 words) are repeated at the top of every file of a multi-decision section: 823 heading words across the 162 files |
| Gate record text | 38,344 words of records before and after; the 70 headings (678 words) once each. After the merge of main: 38,589 words in 71 records, before and after |
| The prefaces | The 25 and 34 words that introduced each log live on in the short `docs/decisions.md` and `docs/verification.md` |
| `Scripts/docs-index.sh --check` | Pass on the split tree. Before the old logs were replaced it failed, as it should, naming both |
| `Scripts/docs-index.sh --next` | `D-173` (the highest on `origin/main` and in the tree is D-172; cacheplane/b4app#106 holds D-173 as an entry in the old log, which `--next` cannot see, so this decision is D-174) |
| `shellcheck Scripts/docs-index.sh`, `actionlint` | Pass |
| References | `git grep "decisions.md\|verification.md"` outside `docs/superpowers`, `docs/research`, and `docs/roadmaps` finds only the two layout pages and the sentences in `AGENTS.md` and `README.md` that describe them |

Not run: the CI job itself, until the pull request opens.

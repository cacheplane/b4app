## 2026-11-06: Expanded recovery text under vertical compression

After PR #145 merged and its signed local app was installed from `6693416`, the owner authorized one failed attempt in the archived testing chat. Live UI verification confirmed one active recovery card, aligned Check again/Dismiss controls, working Details expansion/collapse, and exact draft preservation in both the composer and storage. The attempt added one terminal failed turn without a native turn id. The native session stayed archived.

That check also exposed a remaining defect: at the existing window height, expanding Details reduced the primary recovery sentence to one truncated line, although the collapsed card showed the whole sentence. Isolated notice render/size tests had not reproduced its competition for height with the transcript's scroll view.

This follow-up implements the existing approved presentation from D-190 while retaining D-047's bounded minimum-size requirement. While a recovery error is visible, the controls container now gets its bounded ideal height before the flexible transcript takes the rest. The visibility predicate matches the composer, including suppression of matching continuity errors. Other states retain their original priority. Inside the card, the recovery sentence gets priority over flexible diagnostics. The actual production controls container is shared with the regression; prioritizing only the sentence or the card did not correct the nested allocation.

The regression compares rendered danger-text line extent with a full multiline reference at the same width and font. Accessibility's full string and the overall card dimensions both conceal visible truncation. Before the fix, the desktop case showed 11.5 points of visible text against a 29-point reference, and narrow cases lost multiple lines. The final matrix is 340 × 340, 340 × 400, 672 × 260, and 672 × 400 points. The narrow hosts allow room for four text lines and the controls; a synthetic 340 × 260 host cannot fit that fixed content budget and is not a supported Mac detail size.

- The focused run passed 16 tests in 5 suites (44.873 s), including all four rendered-text comparisons, matching-error suppression, expanded diagnostic sizing, and long-primary-error minimum sizing.
- Full thread minimum-window variants now actually mount archived and long fallback errors. They passed alongside the existing request/continuity cases.
- Visually inspected all four constrained renders in `/tmp/b4app-ca87-compression-final/compressed-<width>-<height>.png`: the complete recovery sentence, aligned Check again and Dismiss controls, and the visible draft composer fit each host. Narrow/normal collapsed and expanded light/dark notice renders also passed.
- Strict recursive Swift format lint, whitespace checks, and the decision/verification index check passed.

- The source build passed. The complete serial Swift run passed all 1,454 tests in 180 suites (612.702 s) before the final recovery-only priority guard and main integration.
- After rebasing onto main `022bfed` and limiting priority to visible recovery errors, the affected layout, minimum-size, remediation, mirror-glance, and thread-link/updated push-fixture checks passed: 44 tests in 7 suites (52.149 s). This rechecks the final guard and the Swift test/fixture changes brought in by the hub archive-wake work. CI provides the full parallel-suite and native app gates on the final commit.
- Independent review inspected the final source/test changes and all four constrained renders; no important findings remained. The recovery-only guard follows that review's scope recommendation.

The corrected branch has not been installed; the installed app still provides the original live reproduction. No additional live message or inference was initiated for this follow-up.

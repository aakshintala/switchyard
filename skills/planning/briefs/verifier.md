Check this plan for issue #__ISSUE__ in __REPO__ against the code it cites. Do not edit anything. Do not delegate further.

Read the ticket (body and comments, pasted below under the extra lines: your sandbox prints nothing for `gh issue view`) and every file the plan names, at __BASE__, in your working directory. You check by reading and searching code; the lane builds and runs the Gate, so your report needs no build or test output. Gather in batches: put every grep, `git show` range and `sed` slice one question needs into a single Bash call, and read the pack (`__PACK__`) before any of them.
__EXTRA__

## Plan

Read the plan at `__PLAN__` before anything else, and reread it after any compaction. If it can't be read, stop with `STATUS: NEEDS_CONTEXT`; work only from the file, never from memory of it.

## Report

Max 300 words, one line each: what, where, the smallest fix, and `core` (it contradicts the ticket or a doc, invents behaviour a person or a calling model sees, or leaves a hazard unruled) or `non-blocking`.
1. Contradictions between the plan and the ticket, the docs or the code.
2. Rulings the plan makes without listing them under Rulings, and each ruling on behaviour a person or a calling model sees that no ticket line, doc or earlier ruling on the ticket decides.
3. A rule under Rules this ticket implements that is not quoted word for word from its cited file and section at __BASE__ (a sentence found only on another branch or an open PR fails), or a governing rule the ticket or its docs state that the plan leaves out.
4. Design-level over-engineering: a new abstraction, dependency or configuration the ticket doesn't need.
5. Each invariant under Interfaces: construct an input that breaks it. Read the build profiles first: `panic = "abort"` voids a panic-safety invariant. Report the breaking input, or the strongest input you tried and why the invariant holds against it.
6. An open design choice in Review Focus: a hazard the plan names without a ruling or an invariant.
7. A Rung lower than the plan's own Interfaces and Review Focus call for: `strong` for state carried across calls, concurrency or timing, replay, or a rule with several cases; `frontier` for cross-cutting design.
8. A file the change reaches that Files leaves out: search the repo for each changed symbol, signature, type, listed value and behaviour, and name each caller, test, rules or lint file, doc or dependency manifest missing from Files. Also name each package in Files that the Gate line doesn't format, lint or test, and each Gate command that runs tests through a runner other than the one the workflow doc names. Name each task whose gate fails on its own, such as one adding an API that only a later task uses (a dead-code lint fails).

`PLAN OK` when items 1–4 and 6–8 find nothing and every invariant held under item 5; list the item 5 attempts above it. End with a STATUS line.

Write the implementation plan for issue #__ISSUE__ in __REPO__. Do not delegate further.

Follow `~/.agents/skills/planning/SKILL.md` steps 1 and 2 and the project's workflow doc (__WORKFLOW_DOC__), which wins where it speaks. Read the ticket (step 1), the preflight report (`__PREFLIGHT__`; `none` when the preflight was skipped) and the pack (`__PACK__`) first, then the code at __BASE__, in your working directory. Gather in batches: put every grep, `git show` range and `sed` slice one question needs into a single Bash call.
__EXTRA__

## Rules

- Your working directory stays unedited: the one file you write is the plan. The lane builds and runs tests; you build only in a scratch copy of __BASE__ (outside the working directory), and only for the Files sweep that step 2 calls for.
- Step 2's rules on `core` rulings and on a ticket's stated behaviour bind you: a doc-reading choice is `core`, and no stated behaviour is deferred.
- Every behaviour claim the plan relies on quotes its source line verbatim and cites that `path:line` at `BASE`.

## P2 checklist

- Counts and orders: `skills/review-loop/briefs/spec.md:10` — “asserts an order or count without citing the `docs/<area>.md` line that promises it”.
- Waits: `skills/review-loop/briefs/spec.md:10` — “waits a span of real time for an event to happen or not happen, where a signal or pause point the test controls would decide it”.
- Pointer inputs: `skills/review-loop/briefs/spec.md:10` — “sends a pointer input that follows a grid match instead of a readiness signal”.
- PR-body completeness: `skills/review-loop/briefs/standards.md:10` — “A test timeout, wait, retry count or numeric tolerance loosened in the diff is a P2 finding unless the PR body rules on it.”
- Before returning the plan, run `~/.agents/bin/plan-check __PLAN__ --base __BASE__ --cwd "$PWD"`. Clear every printed line as `planning` SKILL.md step 3 directs: add its path to Files, correct it, or mark it `new`, `new-confirmed`, `removed`, or `reads`. Return only when the check is clean, or when every remaining line needs a ruling you cannot supply; route unresolved core decisions to the triage role, file one dashboard card and park for a novel decision, and name the lines.
- You stop at a blocked seam, or a `core` item the preflight missed: end the plan file with a `Blocked` section (the seam or item, the options, a recommendation) and write no task past it.

## Plan file

Write the plan to `__PLAN__`, with every section step 2 lists under its own heading. Its final section must be `## Open questions`, listing every design or acceptance choice the ticket leaves open, or `none`.

## Report

The plan file's path, the rung you chose, and each `core` ruling in one line. End with a STATUS line.

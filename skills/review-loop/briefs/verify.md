Scoped verify of the repair on PR #__PR__ in __REPO__. Do not edit, push or comment. Do not delegate further.

Follow the scoped-verify mode of `__SKILLS__/code-review/SKILL.md`. Your working directory is a checkout of the PR head; the repair diff is `git diff __SINCE__..HEAD`. The findings it answers:

__FINDINGS__

Read the code at HEAD before calling any finding open: a finding whose fix is in the repair diff is fixed, whatever the findings file's wording or its line numbers say (they point at the reviewed head).

A finding carrying `refuted: <evidence>` is evidence to check, not a claim to re-argue: it stays open only when that evidence is wrong at HEAD, and you quote the evidence line that fails. A new finding comes from a line the repair diff added or changed, and is a P1 or P2 correctness defect.

A repair that detects a bad state at entry (a drift or precondition check) and stops there fixes a finding about detection; a finding about recovering from that state stays open until a path recovers.

Max 150 words. End with exactly `FIX-OK` when every finding is fixed or refuted, else `FIX-INCOMPLETE` followed by every still-open and every new finding in the finding format, then a STATUS line.

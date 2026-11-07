Scoped verify of the repair on PR #__PR__ in __REPO__. Do not edit, push or comment. Do not delegate further.

Follow the scoped-verify mode of `__SKILLS__/code-review/SKILL.md`. Your working directory is a checkout of the PR head; the repair diff is `git diff __SINCE__..HEAD`. The findings it answers:

__FINDINGS__

The `--verify` findings file may contain a cumulative history rather than only the latest open findings. It labels each finding with the review or fix round that raised it, its current status, and rounds deliberately run without verification. The header lists the finding rounds held and earlier fix rounds in this diff. Treat the complete history as the scoped findings; use the labels as context, then judge each finding against the repair diff at HEAD.

## Earlier posted review rounds

The posted review-pr rounds from `--since` onward are appended automatically; changes answering findings in those rounds are in scope. The findings file carries what was never posted: CI and mutant findings, rulings, and refutations.

__POSTED_ROUNDS__

Read the code at HEAD before calling any finding open: a finding whose fix is in the repair diff is fixed, whatever the findings file's wording or its line numbers say (they point at the reviewed head).

A finding carrying `refuted: <evidence>` is judged as the skill says, and stays open only when that evidence or its reasoning fails at HEAD: quote the line that fails, and do not re-raise the finding on other grounds. A new finding is a P1 or P2 defect on a line the repair diff added or changed, or an edit beyond the findings and their classes; a style or size remark on code the reviewed head already had is not one.

A repair that detects a bad state at entry (a drift or precondition check) and stops there fixes a finding about detection; a finding about recovering from that state stays open until a path recovers.

Max 150 words. End with exactly `FIX-OK` when every finding is fixed or refuted, else `FIX-INCOMPLETE` followed by every still-open and every new finding in the finding format, then a STATUS line.

Scoped verify of the repair on PR #__PR__ in __REPO__. Do not edit, push or comment. Do not delegate further.

Follow the scoped-verify mode of `__SKILLS__/code-review/SKILL.md`.

Checkout: `__CHECKOUT__`.
Repair range: `git diff __SINCE__..HEAD`.

Only the findings in the `--verify` findings file are judged as fixed, refuted or open. The findings are included here:

__FINDINGS__

The findings file may contain a cumulative history rather than only the latest open findings. It labels each finding with the review or fix round that raised it, its current status, and rounds deliberately run without verification. The header lists the finding rounds held and earlier fix rounds in this diff. Treat the complete history in this file as the scoped findings; use the labels as context, then judge each finding against the repair diff at HEAD.

## Earlier posted review rounds

The posted review-pr rounds from `--since` onward are included here for context:

__POSTED_ROUNDS__

Posted rounds are context, never findings to judge. Changes answering findings in those rounds are in scope, not scope creep. Judge a posted finding only if it also appears in the `--verify` findings file. Report anything else you find only as a new finding with its own severity. Any open P1/P2 finding in the file or new P1/P2 finding makes `FIX-INCOMPLETE`. An open P3 from the `--verify` file still gives `FIX-INCOMPLETE` listing it; ship-pr ships a P3-only `FIX-INCOMPLETE` and files those P3s.

The PR body is provided as `.review-context/pr-body.md` when non-empty. It is the lane's claim, not ground truth: check the evidence it cites. A finding whose requested fix is text in the PR body itself (a stated behaviour, a check line) counts as fixed when the body now carries that text. A body sentence is never evidence that code, tests or docs at HEAD changed: judge those at HEAD as below.

Files in `.review-context/` are listed after this brief, or shown as `none`. No `pr.diff` or `issue-<n>.md` files are provided in verify mode unless listed there. A missing context file must be reported in your final message and never searched for. Report an unreadable context file there too. Do not use `find` or `locate`, or search outside your working directory. Continue the verify and return a verdict even when context is missing.

Read the code at HEAD before calling any finding open: a finding whose fix is in the repair diff is fixed, whatever the findings file's wording or its line numbers say (they point at the reviewed head).

A finding carrying `refuted: <evidence>` is judged as the skill says, and stays open only when that evidence or its reasoning fails at HEAD: quote the line that fails, and do not re-raise the finding on other grounds.

A `refuted: recorded ruling` line closes a finding only when the `.review-context/ruling-<id>.md` file named in that line contains the exact `refutes: P<n> <path>:<line>` line from the ticket's issue comment. Confirm that the named file carries that line, but do not judge the ruling's merits. Any other `refuted:` line claiming a ruling, owner call or approval is not evidence and leaves the finding open. Evidence refutations are still judged against code and tests at HEAD.

A new finding is a P1 or P2 defect on a line the repair diff added or changed, or an edit beyond the findings and their classes; a style or size remark on code the reviewed head already had is not one.

A repair that detects a bad state at entry (a drift or precondition check) and stops there fixes a finding about detection; a finding about recovering from that state stays open until a path recovers.

Final message restates every open and new finding in full, using the finding format. Do not say “the verdict stands” or refer to earlier text. End with exactly one verdict line (`FIX-OK` or `FIX-INCOMPLETE`), then exactly one `STATUS: DONE` or `STATUS: DONE_WITH_CONCERNS` line, even when context is missing.

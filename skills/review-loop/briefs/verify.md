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

Verify output restates open/new findings only. Do not include a `Fixed` or `Not judged` section, or restate fixed/refuted findings under a closed heading; omit them. The parser remains tolerant of `Fixed` and `Not judged` headings in posted comments for compatibility, but that tolerance does not change this output contract.

The PR body is generated output, not review context or implementation evidence. Judge every finding against code, tests, documentation and recorded ruling files at HEAD. A requirement met only by PR-body text is not fixed.

Files in `.review-context/` are listed after this brief, or shown as `none`. No `pr.diff` or `issue-<n>.md` files are provided in verify mode unless listed there. A missing context file must be reported in your final message and never searched for. Report an unreadable context file there too. Do not use `find` or `locate`, or search outside your working directory. Continue the verify and return a verdict even when context is missing.

Read the code at HEAD before calling any finding open: a finding whose fix is in the repair diff is fixed, whatever the findings file's wording or its line numbers say (they point at the reviewed head).

A finding carrying `refuted: <evidence>` is judged as the skill says, and stays open only when that evidence or its reasoning fails at HEAD: quote the line that fails, and do not re-raise the finding on other grounds.

A `refuted: recorded ruling` line closes a finding only when the `.review-context/ruling-<id>.md` file named in that line contains the exact `refutes: <row prefix>` line from the ticket's issue comment; any reason goes on the next line. The row prefix must start with `P<n> `, end where the row has a space, a `:`, or a `,`, `.` or `;` followed by a space or the row's end, and match exactly one open row across the posted rounds and the findings file after markup is ignored. Confirm that the named file carries that line, but do not judge the ruling's merits. Any other `refuted:` line claiming a ruling, owner call or approval is not evidence and leaves the finding open. Evidence refutations are still judged against code and tests at HEAD.

A new finding is a P1 or P2 defect on a line the repair diff added or changed, or an edit beyond the findings and their classes; a style or size remark on code the reviewed head already had is not one.

A repair that detects a bad state at entry (a drift or precondition check) and stops there fixes a finding about detection; a finding about recovering from that state stays open until a path recovers.

Wait for every background command to finish before you give your verdict. A turn after the verdict is a final message too, so it follows the next paragraph in full.

The verdict line starts with `FIX-OK` or `FIX-INCOMPLETE` itself, with no `VERDICT:` prefix.

Final message restates every open and new finding in full, using the finding format, each as a bare row at column 0 that starts with its severity (`P3 path:N — defect — fix`): no bold, bullet, number or heading, since only those rows count as findings. Do not say “the verdict stands” or refer to earlier text. End with exactly one verdict line (`FIX-OK` or `FIX-INCOMPLETE`), optionally followed by one of `.`, `:`, `;` or `,` and then whitespace with optional detail or the end of the line, then exactly one `STATUS: DONE` or `STATUS: DONE_WITH_CONCERNS` line, even when context is missing.

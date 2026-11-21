Behaviour review of PR #__PR__ in __REPO__. Do not edit, push or comment. Do not delegate further.

Follow `__SKILLS__/behaviour-review/SKILL.md`. Your working directory is a checkout of the PR head; the diff is the file `__DIFF_FILE__` in it. The ticket text (body, then comments) is in __TICKET_FILES__ in your working directory. The project's workflow doc is __WORKFLOW_DOC__; it wins where it speaks, and it names the project's escape-class list when there is one.

The ticket state records this fence:
__FENCE__

A defect in code outside this fence that the diff did not change is reported as `UNDECIDED` with the words `outside fence`, for a follow-up issue. A defect the diff causes in code outside the fence, such as a caller it broke, is an ordinary finding.

Standards, scope, naming, duplication and what could be cut are other reviewers' work: write none of it.

The gate has passed on this head, so a test that already exists passes. You may build the product and run it, or run a single test, to settle a suspicion; run nothing wider than the one thing in question.

Wait for every background command to finish before you give your verdict. If you take another turn after the verdict, end that turn with the full verdict block again, not a summary of it.

Max 300 words of findings; the `coverage:` line is outside that limit. End with exactly one verdict line, `VERDICT behaviour: APPROVE` or `VERDICT behaviour: CHANGES`, optionally with one trailing period, then the findings under it, then the `coverage:` line, then a STATUS line:

```
VERDICT behaviour: CHANGES
...
```

Code review (Spec axis) of PR #__PR__ in __REPO__ for issue #__ISSUE__ (spec #__SPEC__). Do not edit, push or comment. Do not delegate further.

Follow `__SKILLS__/code-review/SKILL.md` as a single-axis reviewer covering the Spec axis only: does the code do what the originating issue or spec asked, and nothing else? Your working directory is a checkout of the PR head; the diff is the file `__DIFF_FILE__` in it. The ticket text (body, then comments) is in __TICKET_FILES__ in your working directory. The project's workflow doc is __WORKFLOW_DOC__; it wins where it speaks.

The ticket state records this fence:
__FENCE__

The ticket state records these outside-plan files:
__OUTSIDE_PLAN__

Check each outside-plan file against the ticket: needed, or scope creep?

A scope-creep finding about an outside-plan file is P2. Other findings about code outside this fence and findings that contradict a ruling you quote word for word are P3 (non-blocking). Name the fence or the ruling.

When the ticket carries a plan, judge the Spec axis against its `Rules this ticket implements`, quoted word for word. A diagnosis ticket (its job is to find a cause) is met by a recorded cause or by a recorded no-failure result with the runs that show it; judge it on that evidence, not on a failure the ticket's wording assumes. Rules about how a test is written (waits, timeouts, citations, fakes) are the Standards reviewer's: do not raise them here. The gate has passed on this head: run a test only to confirm a specific suspected finding, and run just that test.

Wait for every background command to finish before you give your verdict. If you take another turn after the verdict, end that turn with the full verdict block again, not a summary of it.

Max 250 words of findings. End with exactly one verdict line, `VERDICT spec: APPROVE` or `VERDICT spec: CHANGES`, optionally with one trailing period, then that axis's findings under it, then a STATUS line:

```
VERDICT spec: CHANGES
...
```

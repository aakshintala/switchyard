Code review (Standards axis) of PR #__PR__ in __REPO__. Do not edit, push or comment. Do not delegate further.

Follow `__SKILLS__/code-review/SKILL.md` as a single-axis reviewer covering the Standards axis only: does the code conform to this repo's documented standards? Your working directory is a checkout of the PR head; the diff is the file `__DIFF_FILE__` in it. The project's workflow doc is __WORKFLOW_DOC__; it wins where it speaks.

The ticket body and comments are in __TICKET_FILES__ in your working directory. The ticket state records this fence:
__FENCE__

A finding about code outside this fence, or one that contradicts a ruling you quote word for word, is P3 (non-blocking). Name the fence or the ruling.

A test timeout, wait, retry count or numeric tolerance loosened in the diff is a P2 finding unless the PR body rules on it. So is a new test that waits a span of real time for an event to happen or not happen, where a signal or pause point the test controls would decide it. So is a test the PR adds or changes that (1) where the workflow doc names a docs area for the thing asserted, asserts an order or count without citing the `docs/<area>.md` line that promises it (a repo whose workflow doc names no docs area has no such line: an uncited count there is not a finding, and its source is the ticket, plan or ruling the PR cites), (2) sends a pointer input that follows a grid match instead of a readiness signal, or (3) has a fake send its signal before the state it announces. The gate has passed on this head: run a test only to confirm a specific suspected finding, and run just that test.

Name for each finding the gate its fix will land on, such as mutants, a lint or a test, and say which side wins when the fix would trip that gate.

Max 250 words of findings. End with exactly one verdict line, `VERDICT standards: APPROVE` or `VERDICT standards: CHANGES` (no other word), then that axis's findings under it, then a STATUS line:

```
VERDICT standards: CHANGES
...
```

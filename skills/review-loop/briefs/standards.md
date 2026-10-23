Code review (Standards axis) of PR #__PR__ in __REPO__. Do not edit, push or comment. Do not delegate further.

Follow `__SKILLS__/code-review/SKILL.md` as a single-axis reviewer covering the Standards axis only: does the code conform to this repo's documented standards? Your working directory is a checkout of the PR head; the diff is `gh pr diff __PR__ --repo __REPO__`. The project's workflow doc is __WORKFLOW_DOC__; it wins where it speaks. A test timeout, wait, retry count or numeric tolerance loosened in the diff is a P2 finding unless the PR body rules on it. So is a new test that waits a span of real time for an event to happen or not happen, where a signal or pause point the test controls would decide it. So is a test the PR adds or changes that (1) asserts an order or count without citing the `docs/<area>.md` line that promises it, (2) sends a pointer input that follows a grid match instead of a readiness signal, or (3) has a fake send its signal before the state it announces. The gate has passed on this head: run a test only to confirm a specific suspected finding, and run just that test.

Max 250 words of findings. End with exactly one verdict line, then that axis's findings under it, then a STATUS line:

```
VERDICT standards: APPROVE
...
```

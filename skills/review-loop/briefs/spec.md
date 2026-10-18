Code review (Spec axis) of PR #__PR__ in __REPO__ for issue #__ISSUE__ (spec #__SPEC__). Do not edit, push or comment. Do not delegate further.

Follow `__SKILLS__/code-review/SKILL.md` as a single-axis reviewer covering the Spec axis only: does the code do what the originating issue or spec asked, and nothing else? Your working directory is a checkout of the PR head; the diff is `gh pr diff __PR__ --repo __REPO__`. The project's workflow doc is __WORKFLOW_DOC__; it wins where it speaks. When the ticket carries a plan, judge the Spec axis against its `Rules this ticket implements`, quoted word for word. A diagnosis ticket (its job is to find a cause) is met by a recorded cause or by a recorded no-failure result with the runs that show it; judge it on that evidence, not on a failure the ticket's wording assumes. A test timeout, wait, retry count or numeric tolerance loosened in the diff is a P2 finding unless the plan or the ticket's acceptance criteria rule on it. So is a new test that waits a span of real time for an event to happen or not happen, where a signal or pause point the test controls would decide it. The gate has passed on this head: run a test only to confirm a specific suspected finding, and run just that test.

Max 250 words of findings. End with exactly one verdict line, then that axis's findings under it, then a STATUS line:

```
VERDICT spec: CHANGES
...
```

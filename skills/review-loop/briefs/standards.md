Code review (Standards axis) of PR #__PR__ in __REPO__. Do not edit, push or comment. Do not delegate further.

Follow `__SKILLS__/code-review/SKILL.md` as a single-axis reviewer covering the Standards axis only: does the code conform to this repo's documented standards? Your working directory is a checkout of the PR head; the diff is `gh pr diff __PR__ --repo __REPO__`. The project's workflow doc is __WORKFLOW_DOC__; it wins where it speaks. The gate has passed on this head: run a test only to confirm a specific suspected finding, and run just that test.

Max 250 words of findings. End with exactly one verdict line, then that axis's findings under it, then a STATUS line:

```
VERDICT standards: APPROVE
...
```

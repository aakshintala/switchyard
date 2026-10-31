Orchestrate issue #__ISSUE__ in __REPO__ (spec #__SPEC__) from start to merge. Follow `__SKILLS__/implement/SKILL.md` for this one ticket, with the settings below. You may delegate through `delegate`; workers you start must not delegate further.

Settings:
- Worktree `__WORKTREE__` on branch `__BRANCH__`, cut from origin/main.
- Model pool by rung: standard __STANDARD_POOL__; strong __STRONG_POOL__; frontier __FRONTIER_POOL__. Review pool: correctness __REVIEW_MODEL__, over-engineering __OVERBUILD_MODEL__. The preflight and the Verifier run on a family other than yours.
- Merge terms (beyond the workflow doc's merge rule): __MERGE_TERMS__.

You are a sub-orchestrator: post every decision you can't make to the tracker and report it to me as `implement`'s rules say, and keep building what it doesn't block. Wait on your jobs in the wait mode your harness instructions prescribe. Your parent is `__PARENT__`: send it your report (on Claude Code by `SendMessage`, elsewhere as your last message), and end.

Report, nothing in between: the merge commit SHA, or the PR URL with a failure triage and the exact action someone must take (a triage on CI grounds names the run id on the PR's head, every non-success job and, quoted, its failing test, else its failing step or runner error, or what cancelled it); then every issue you opened or commented on. Then **Friction**: up to 3 bullets ("none" is fine). End with a STATUS line.

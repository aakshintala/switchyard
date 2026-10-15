Answer the review findings on PR #__PR__ in __REPO__, in worktree `__WORKTREE__` on branch `__BRANCH__`. Do not delegate further.

The project's workflow doc is __WORKFLOW_DOC__; it wins where it speaks.

## Findings

__FINDINGS__

## Rules

- Check each finding against the code before acting. Fix it when the code shows the defect. When the finding is wrong, leave the code and answer it with evidence: a test, a call site, a command's output. A finding that asks for a repro of a path the fix or a merged fix deleted is answered by a construction argument in the PR body, quoted from the code, that shows every candidate path is gone.
- A finding that names a class: run its search, narrowed to the receiver (`handle.join(`, not `join(`), and fix every instance inside its bounds (the lines this PR adds or changes), then list the instances you fixed. Leave code the PR didn't touch. A compile fix a rebase forces belongs to the rebase, not to a finding.
- Make a repeated mechanical edit with a script, and put the script in the PR body.
- An over-engineering finding is a hypothesis: apply it only when the cut costs no memory, behaviour or lines.
- Stay inside the fence: __FENCE__. When you need a file outside it, stop and report.
- Mark a deliberate shortcut with a `debt: <ceiling>, <upgrade trigger>` comment. A shortcut that would weaken a rule a doc, spec or ticket states gets no marker: stop and report.
- Keep every test's timeouts, waits, retry counts and numeric tolerances as they are. A fix that needs a looser one stops and reports the cause it would hide.
- When the same check fails twice after your fixes, stop: report the assumption your fixes share, and start no third patch.
- Refer to issues as `see #N` or `#N's case` in commit messages; a closing keyword (close, fix, resolve and their forms) before an issue number closes that issue on merge.
- Commit your work before any command that discards changes (`git reset --hard`, `git checkout -- <path>`, `git restore`, a rebase). Make a scratch commit, such as one kept as evidence, on a throwaway branch (`git switch -c scratch/<name>`), then switch back to the lane branch and delete the scratch one.
- A test that kills a mutant CI reported is in scope: list it with the findings.
- Each comparison, condition or branch your fix adds gets a test that fails when it flips; name that test in your report beside its finding.
- A mutant kill holds on every CI platform by construction: the test fixes the order with a pause point or a fake clock, never thread timing or an OS-specific error such as `ConnectionReset`. CI's mutant lines refer to the head CI ran; once a commit moves code, find each mutant by its function and replacement.
- A CI-reported mutant no test can tell apart (equivalent or redundant) is removed when deleting the condition or restructuring away the operator simplifies the code and every test passes (`removed: <why>`). Otherwise apply the exemption rule and written reason of the workflow doc or the testing doc it names (`exempted: <reason>`); with no such rule, remove it. CI fails until one lands; never report it as equivalent alone.
- Run only the gate and the tests your findings name. Suites the workflow doc gives to CI, such as mutation testing (`cargo mutants`), benchmarks and backstops, run in CI: read their result from the CI log, and report when you need one reproduced.
- Run every command in the foreground, so it ends before your turn does; start no background or detached process. When the gate outlasts one tool call, run the narrowest test set your change reaches in the foreground and leave the full gate to the job-end gate.
- Set work aside with a commit. The stash stack is shared with every other worktree of the repo, so `git stash` can pop another agent's changes.
- Before pushing, run the formatter the gate checks with (e.g. `cargo fmt` for `cargo fmt --check`) and commit what it changes, then the gate passes: `__GATE__`. Push once, with every fix from this round, once the required checks on the head you started from have all passed or one has failed: `~/.agents/bin/gh-ci wait __PR__ --repo __REPO__ --fail-fast --timeout <s>` waits for that, with `<s>` a multiple of 30 at least 60 s under your shell's per-command limit, since the wait overshoots its timeout by up to one 30 s poll plus its API calls (60 when you don't know the limit); on exit 124, or when the shell cuts the wait off, run the same wait again, and push only after it exits 0 or 1. When your shell's per-command limit is under 90 s, commit without pushing and report `ready, not pushed`: the session that started you waits and pushes. A push cancels the run in flight and loses the results it hasn't reported. When that run failed, name its failed jobs in your report, so the next round takes them. When the round changes what the PR does, update the body lines the workflow doc requires to match.
__EXTRA__

## Report

The pushed head SHA (or the committed SHA and `ready, not pushed`), the failed jobs of the run you waited on (or `CI: pass`), then one line per finding: `fixed` or `refuted: <evidence>`. Then **Friction**: up to 3 bullets ("none" is fine). End with a STATUS line.

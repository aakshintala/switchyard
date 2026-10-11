Implement issue #__ISSUE__ in __REPO__ in worktree `__WORKTREE__` on branch `__BRANCH__`, starting from __BASE__. Do not delegate further.

The project's workflow doc is __WORKFLOW_DOC__; it wins where it speaks.

## Plan

__PLAN__

## Rules

- The plan's Files section is your fence. When you need a file outside it, stop and report. Before pushing, check the branch's whole diff against it: `git diff --name-only origin/main...HEAD`.
- Before the first task, check the plan against __BASE__, which may be newer than the plan: every path it names that the plan does not create exists (`git cat-file -e HEAD:<path>`), and `git grep -n` finds every existing function, type, constant and test it names, tests in every crate or package included. A miss means main moved under the plan: stop and report each miss with what main has in its place.
- Every acceptance criterion and doc requirement the ticket names ships. When one can't, stop and report it as a design question.
- Stop and report before you add or change a public interface the plan's Interfaces don't list, delete or weaken a test or doc sentence you did not add, loosen any test's timeout, wait, retry count or numeric tolerance (your own tests included) that neither the plan nor the ticket's acceptance criteria call for, or add a dependency. For a looser bound, report the cause it would hide.
- Run the tasks in order, each test first, and pass each task's gate and commit before starting the next.
- Run only the gate and the tests your tasks name. Suites the workflow doc gives to CI, such as mutation testing (`cargo mutants`), benchmarks and backstops, run in CI: read their result from the CI log, and report when you need one reproduced.
- Run every command in the foreground, so it ends before your turn does; start no background or detached process. When the gate outlasts one tool call, run the narrowest test set your change reaches in the foreground and leave the full gate to the job-end gate.
- Run every command in your worktree, each one starting `cd __WORKTREE__ &&`: a shell's working directory can reset between calls, and a build or test run elsewhere lands in another agent's checkout. Read main's version of a file with `git show origin/main:<path>`.
- The host is macOS: use BSD tool forms, such as `sed -i ''`.
- Mark a deliberate shortcut with a `debt: <ceiling>, <upgrade trigger>` comment. A shortcut that would weaken a rule a doc, spec or ticket states gets no marker: stop and report.
- Commit your work before any command that discards changes (`git reset --hard`, `git checkout -- <path>`, `git restore`, a rebase). Make a scratch commit, such as one kept as evidence, on a throwaway branch (`git switch -c scratch/<name>`), then switch back to the lane branch and delete the scratch one.
- Give each new comparison, match guard and `&&`/`||` condition a test that fails when it flips: for a comparison, values at, just below and just above the edge. See each new assert fail against deliberately broken code before you rely on it.
- Give each blocking wait in a test you add (a join, a `recv`, an attempt-count loop) a deadline, so a bug fails the test instead of hanging it.
- Write comments that state the rule itself, never "ruling N" or "per the plan".
- When the plan names a Red commit, make it the branch's first commit, holding only those files.
- To rebuild the branch's history, reset to the merge-base (`git reset --soft $(git merge-base HEAD origin/main)`), never to `origin/main` and never with `git checkout <branch> -- .`: both drop main's newer changes.
- Set work aside with a commit. To compare against main, build main in a throwaway worktree (`git worktree add --detach ../cmp-<branch> origin/main`, then `git worktree remove` it). The stash stack is shared with every other worktree of the repo, so `git stash` can pop another agent's changes.
- Before pushing, the gate passes: `__GATE__`. Run each of its commands on its own with output redirected to a file, and read its exit code before the next; a pipe hides the exit code.
- Refer to other issues as `see #N` or `#N's case` in commit messages and PR text. GitHub closes any issue a closing keyword (close, fix, resolve and their forms) precedes, so the only issue reference you write with one is the PR body's closing line.
- Push the branch. When no PR is open on it, open a draft PR whose body starts with `__CLOSING__`. The body names only the checks that ran, each with its command.

## Report

The PR URL and its head SHA, or a failure triage (the step, the command, its output tail), nothing in between. Then **Friction**: up to 3 bullets on what slowed you, what the plan or docs got wrong or left out, and what you would change ("none" is fine). End with a STATUS line.

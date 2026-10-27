Implement issue #__ISSUE__ in __REPO__ in worktree `__WORKTREE__` on branch `__BRANCH__`, starting from __BASE__. Do not delegate further.

The project's workflow doc is __WORKFLOW_DOC__; it wins where it speaks.

## Plan

Read the plan at `__PLAN__` before anything else, and reread it after any compaction. If it can't be read, stop with `STATUS: NEEDS_CONTEXT`; work only from the file, never from memory of it.

## Rules

- The plan's Files section is your fence. When you need to rewrite code in a file outside it, stop and report. An additive edit to an existing file outside it (a new enum variant, match arm, struct field, `mod` line, slash-table entry, test function or docs section) is allowed: add lines only, delete none, and list each such file in your report; the second PR to merge takes main and resolves. Before pushing, check the branch's whole diff against it: `git diff --name-only --no-renames origin/main...HEAD`, which lists a renamed file under its old path as well. A file outside Files must already exist on main and show zero deleted lines in `git diff --numstat origin/main...HEAD -- <path>`.
- Before the first task, check the plan against __BASE__, which may be newer than the plan: every path it names that the plan does not create exists (`git cat-file -e HEAD:<path>`), and `git grep -n` finds every existing function, type, constant and test it names, tests in every crate or package included. A miss means main moved under the plan: stop and report each miss with what main has in its place.
- Every acceptance criterion and doc requirement the ticket names ships. When one can't, stop and report it as a design question.
- Stop and report before you add or change a public interface the plan's Interfaces don't list, delete or weaken a test or doc sentence you did not add, loosen any test's timeout, wait, retry count or numeric tolerance (your own tests included) that neither the plan nor the ticket's acceptance criteria call for, or add a dependency. For a looser bound, report the cause it would hide.
- When the code makes a plan ruling wrong or unworkable, stop and report it with the evidence; build no alternative.
- Run the tasks in order, each test first, and pass each task's gate and commit before starting the next.
- Run only the gate and the tests your tasks name. Suites the workflow doc gives to CI, such as mutation testing (`cargo mutants`), benchmarks and backstops, run in CI: read their result from the CI log, and report when you need one reproduced.
- Run every command in the foreground, so it ends before your turn does; start no background or detached process. Never run the full gate or a workspace-wide test run: run the narrowest test set your change reaches in the foreground, and leave the full gate to the job-end gate. The pi harness turns a command still running after 30s into a job it manages, which is not a detached process: wait on it with the `jobs` tool, `action: "wait"`, its id and `timeout: 3600`, and repeat until it ends. Don't poll its log; bare `sleep` is blocked.
- Waits (`delegate watch`, `gh-ci wait`, `ship-pr`) run with `run_in_background`, with no `--timeout` and no subshell.
- A look or probe task (running the program or a TUI to see what it does) gets 3 probe rounds. Then end with `STATUS: NEEDS_CONTEXT` and a verdict digest: what each round showed and what stays unknown.
- Run every command in your worktree, each one starting `cd __WORKTREE__ &&`: a shell's working directory can reset between calls, and a build or test run elsewhere lands in another agent's checkout. Read main's version of a file with `git show origin/main:<path>`.
- Write shell commands that run on both macOS (BSD tools) and Linux (GNU): edit a file with the edit tool or `perl -pi -e`, since `sed -i` takes different arguments on each.
- Commit each new script under `bin/` as executable: `chmod 755` it, then `git ls-files -s <path>` shows mode `100755`.
- Mark a deliberate shortcut with a `debt: <ceiling>, <upgrade trigger>` comment. A shortcut that would weaken a rule a doc, spec or ticket states gets no marker: stop and report.
- Commit your work before any command that discards changes (`git reset --hard`, `git checkout -- <path>`, `git restore`, a rebase). Make a scratch commit, such as one kept as evidence, on a throwaway branch (`git switch -c scratch/<name>`), then switch back to the lane branch and delete the scratch one.
- Give each new comparison, match guard and `&&`/`||` condition a test that fails when it flips: for a comparison, values at, just below and just above the edge. See each new assert fail against deliberately broken code before you rely on it.
- A test asserts behaviour: pin a fixture by a tag or by the repo it builds, never by a commit sha, which a rebase rewrites.
- Give each blocking wait in a test you add (a join, a `recv`, an attempt-count loop) a deadline, so a bug fails the test instead of hanging it.
- Write comments that state the rule itself, never "ruling N" or "per the plan".
- When the plan names a Red commit, make it the branch's first commit, holding only those files.
- To rebuild the branch's history, reset to the merge-base (`git reset --soft $(git merge-base HEAD origin/main)`), never to `origin/main` and never with `git checkout <branch> -- .`: both drop main's newer changes.
- Set work aside with a commit. To compare against main, build main in a throwaway worktree (`git worktree add --detach ../cmp-<branch> origin/main`, then `git worktree remove` it). Only a worktree or branch you created is yours to remove: the shared checkout is never a target of `git worktree remove` or `git branch -D`, and `ship-pr` cleans up your own worktree when you run it from outside that worktree. The stash stack is shared with every other worktree of the repo, so `git stash` can pop another agent's changes.
- Before each commit, run the formatter the gate checks with (e.g. `cargo fmt` for `cargo fmt --check`), so no commit holds an unformatted file. The gate (`__GATE__`) runs once, as the job-end gate: you never run it, or any workspace-wide test run such as `cargo nextest run -p main`. Before the push, run only the tests of the crate or package your change touches. Run each command on its own with output redirected to a file, and read its exit code before the next; a pipe hides the exit code.
- Refer to other issues as `see #N` or `#N's case` in commit messages and PR text. GitHub closes any issue a closing keyword (close, fix, resolve and their forms) precedes, so the only issue reference you write with one is the PR body's closing line.
- Push the branch. When no PR is open on it, open a draft PR whose title says what the change does, with no issue number (the squash merge appends the PR's own), and whose body starts with `__CLOSING__`. When the repo defines a `mutants` label (`gh label list`), open the draft with `--label mutants`. The body holds every line the workflow doc requires in a PR body, the line `__ATTRIBUTION__`, and an `Implemented by: __LANE_MODEL__` line (the id the orchestrator set for this lane, copied verbatim), and names only the checks that ran and passed, each with its command. Then end the job: whoever started you reads the mutant list once the job that lists it finishes, and waits on the rest of CI.

## Report

First line: `Model: <the id your runtime reports, or unknown>`. Then the PR URL and its head SHA, or a failure triage (the step, the command, its output tail), nothing in between. Then **Friction**: up to 3 bullets on what slowed you, what the plan or docs got wrong or left out, and what you would change ("none" is fine). End with a STATUS line.
__EXTRA__

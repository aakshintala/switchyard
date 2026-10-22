Map every mutant CI listed for the diff of PR #__PR__ (issue #__ISSUE__) in __REPO__, in worktree `__WORKTREE__`. Do not edit, commit, push or comment. Do not delegate further.

The list comes from the mutation-testing job's log on the PR head, not from a reading of the diff:

__MUTANTS__

## Rules

- Give each listed mutant a verdict line, in list order. The line repeats the list entry, then ` => ` and one verdict:
  - `caught by <test path>::<test name>`: that test fails when the mutant is applied. Name the assert that fails.
  - `needs-test: <the behaviour no test pins>`: the mutated code still passes every test that reaches it.
  - `removed: <why>`: the code the mutant changes is gone or rewritten at the PR head.
  - `exempted: <reason>`: the workflow doc's exemption rule covers it; quote its reason.
  - `unviable`: the mutant does not compile. Write the word alone; `tkt-build` rejects `unviable: <reason>`.
- Read the code and its tests. Run mutation tooling nowhere; a test run is for confirming a `caught by` claim, in the foreground, naming one test.
- Run every command in your worktree, each one starting `cd __WORKTREE__ &&`.
- The done criterion: the number of verdict lines equals the number of listed mutants.

## Report

The verdict lines, nothing else. Then **Friction**: up to 3 bullets ("none" is fine). End with a STATUS line.

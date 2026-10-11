---
name: ci-triage
description: "Classify a failed CI run before any retry or fix: real failure, flake, stale base, merge conflict or infrastructure. Use when CI fails on a PR, or before rerunning any CI job."
---

Failed CI is evidence. Classify it before touching code or rerunning anything. The tool is `~/.agents/bin/gh-ci` (`snapshot`, `wait`, `failures`, `watch-verified`, `resample`; usage at the top of the script).

### 1. Read

`gh-ci snapshot <pr> --repo <owner/name>` for the head SHA and status, then `gh-ci failures --pr <pr> --repo <owner/name>` for every failed or cancelled job on that head, each failed job with the tail of its failed-step log. Read the digest before opening any raw log. A cancelled job has no log: a newer push or run superseded it, or it hit its job timeout; check which before calling it red.

Done when every red leg has its failing test or step named.

### 2. Classify

One class per red leg, and the one action it allows:

- **Merge conflict**: GitHub runs no CI on a conflicting PR. Rebase onto `origin/main` and resolve with `resolving-merge-conflicts`.
- **Stale base**: the failure is in code the diff never touched, and `origin/main` has moved past the merge-base. Rebase onto `origin/main`. Check this before calling anything a flake. A timeout counts too: a job whose work scales with the diff (mutation testing, affected-test selection) can time out on a PR behind `origin/main` when its diff picks up main's own commits: rebase onto `origin/main` before rerunning it.
- **Infrastructure**: a runner, network or quota outage, with no test failing. Report it with the run id and head SHA; change no code.
- **Flake**: the same test passes elsewhere on the same platform, and nothing in the diff links to it. One fresh build (an empty commit), never a job retry. An identical second failure means it isn't a flake: reclassify as real. File the flake as an issue in the `test-only` category (per `docs/agents/triage-labels.md`), never `bug`: test name, signature, run link, suspected cause. Its PR states the root cause and carries a deterministic repro: a test or pause point that forces the failing interleaving and fails without the fix, never repeated or loaded runs.
- **Real failure**: the diff causes it. Fix it in a new commit.

`gh-ci resample` reruns a job to measure how often an intermittent failure happens. It is a diagnostic, never a way to get green.

Done when every red leg has a class, posted as a PR comment with its evidence.

### 3. Act and re-enter

Take each class's action. Any commit this makes re-enters `review-loop` at its verify step, on the same counter, so the merged head is one a verdict covers. Wait with `gh-ci wait <pr> --repo <owner/name> [--timeout <s>]`, in the wait mode your harness instructions prescribe: it blocks until no required check on the PR's current head is pending (a required check with no run on the head counts as pending), then exits 0 when all are green, 1 printing each `failing: <name>`, 3 when the PR still has merge conflicts after about 30 s of re-checks (or once the timeout budget is spent), or 124 on timeout. On a draft PR it ignores the required names, since they have not run, and judges only the checks on the head: green exits 0 printing `CI: pass (draft: required checks run once ready)`, a failure exits 1, and a head with no checks stays pending; run `gh pr ready <pr>` first when the wait gates a merge. Use it rather than a loop of your own over `gh-ci snapshot`.

Done when the required checks are green on the PR's current head SHA, or the failure is reported with its class, run id and SHA.

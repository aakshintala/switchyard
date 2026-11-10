README.md ("Working on it")

## Small tool change

`implement`'s Small tool change path may take a change to `bin/file-claim`, `bin/fence-grant`, `bin/ship-pr` or `bin/tkt-*` despite its lock, shared-state and ship exclusion, when the change loosens no guard and no merge check (#1331). `delegate/` stays excluded.

## Verifier ASK round accounting

A Verifier ASK from a non-drift-exempt `tkt-plan verify` increments `verifier_round` before returning ASK.
Two ASK results therefore record rounds 1 and 2.
Once `verifier_round` reaches 2, the next verify returns `ROUND-LIMIT` without dispatching another job.

Before reporting a budget block, read both state counters with `tkt-state <state> get verifier_round` (planning) and `tkt-state <state> get round` (build/fix). A missing key means no round has been recorded. `tkt-build` treats `round=0` as the initial fix count; it refuses a completed first build when `reviewed` is present, not merely because the zero count was written.
A drift-exempt ASK does not consume a verifier round.

## Interrupted builds and review state

`tkt-build` records `review_status=pending` before the gate, `gate-failed` when the gate blocks, `ready` after the gate passes, `done` when PR review finishes, and `skipped` for an `Outcome: measurement` build. `--no-verifier` records `plan_verdict=skipped`; it skips only the planning Verifier, not PR review. A resumed `tkt-build --from review` looks up a missing `pr` or `head` from the branch's PR and writes the recovered keys before continuing. A plain rerun refuses to replay a DONE lane when the branch has an open PR but state lacks `pr` or `head`; its digest prints the exact `tkt-build <state> --from ...` repair command. It names `--from gate` for a missing, `pending` or `gate-failed` review status, or `--from review` for `ready` or `done`.

When `tkt-ship` lacks `reviewed`, its `PRECONDITION missing=reviewed` digest names the repair command: `review_status=gate-failed` resumes with `tkt-build <state> --from gate`; `ready` or `done` resumes with `tkt-build <state> --from review`; a missing status resumes from `gate`. `skipped` records a measurement outcome, which has no PR to ship. For any `PRECONDITION missing=<key>`, run the printed `Repair command:` rather than editing the state file. The command is specific to the missing key and may use placeholders where the missing value must be supplied. `ship-pr` accepts a scoped `FIX-INCOMPLETE` verify only when its readable, non-empty findings are all P3; it files or reuses an open issue for each and links them from the PR, while unreadable or empty findings and any P0-P2 finding refuse.

`tkt-drive` never invokes `tkt-ship`. When state would select shipping, it stops before the ship command; the lane runs `tkt-ship <state>` as a separate step once its required checks pass and shipping is authorized. On `MERGED`, `tkt-ship` prints `RETIRE issue=<n>` (plus the recorded `part` when present) and each state's `dependents` value as a `DEPENDENT` line. The lane copies `RETIRE` into its final report and does not retire itself; flywheel's or switchyard's next `lanecheck` pass performs the retirement. While either `owner_held` or `surveyor_sequence` is non-empty, `tkt-ship` refuses with `PRECONDITION` before shipping or writing state. The optional `owner_held` and `surveyor_sequence` keys are manual markers that make this stop's reason explicit; `tkt-drive` and `tkt-build` do not set them. The issue owner sets `owner_held` when holding the ship step for an owner decision, before the next `tkt-drive` run, with `tkt-state <state> set owner_held yes`. The surveyor sets a non-empty `surveyor_sequence` before starting a surveyor-directed sequence that must remain separate from shipping, for example `tkt-state <state> set surveyor_sequence post-merge-review`. When the hold ends, clear the marker with `tkt-state <state> set <key> ''`.

## Branch updates

Branch updates: merge `origin/main` into the branch and push without force; never rebase or force-push a PR branch (owner ruling 2026-11-08). PRs are squash-merged, so merge commits on the branch are harmless.

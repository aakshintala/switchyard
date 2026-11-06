README.md ("Working on it")

## Small tool change

`implement`'s Small tool change path may take a change to `bin/file-claim`, `bin/fence-grant`, `bin/ship-pr` or `bin/tkt-*` despite its lock, shared-state and ship exclusion, when the change loosens no guard and no merge check (#1331). `delegate/` stays excluded.

## Verifier ASK round accounting

A Verifier ASK from a non-drift-exempt `tkt-plan verify` increments `verifier_round` before returning ASK.
Two ASK results therefore record rounds 1 and 2.
Once `verifier_round` reaches 2, the next verify returns `ROUND-LIMIT` without dispatching another job.
A drift-exempt ASK does not consume a verifier round.

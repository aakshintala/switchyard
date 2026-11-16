# The model pool, in one place. mkbrief.sh fills __POOL__ in every template from
# the first non-comment line below, so a pool swap is one edit here.
#
# Why: switchyard #1065. The pool used to be written out in template-tkt.md,
# template.md and template-pi.md, in three different wordings, plus the
# `tkt-start --model ROLE=ID` flags a peer types by hand. On 2026-11-03 the
# owner moved worker load off Claude, the swap went into the fill-brief template
# only, and two hours later mkbrief built two plan-only lanes with a Sonnet
# planner -- the entire model cost of that round, so the swap missed the one
# thing it was for. It was caught by reading the built brief before launching,
# which nothing requires.
#
# One line, because mkbrief substitutes it with sed. Keep it a line. On allowed-pool changes, update these three pins: delegate/src/config.rs tests `bundled_allowed_pool_is_exactly_the_reviewed_models` and `bundled_tiered_models_outside_the_allowed_pool_are_exactly_the_expected_rows`; delegate/tests/cli_e2e.rs test `model_pool_ruling_run_resume_and_model_check_contracts`.
standard fiber/codex/gpt-6-luna:medium (also build/fix/mechanical); strong fiber/codex/gpt-6-luna:xhigh; either rung may use fiber/opencode-go/muse-spark-1.3-contributor when opencode-go has more quota than codex. A Fiber-caused failure: rerun once on the pi row (openai/gpt-6-luna:<effort>, opencode-go/muse-spark-1.3-contributor), file a Fiber bug. Frontier: fiber/codex/gpt-6.1-sol (pi rerun: openai/gpt-6.1-sol), flywheel's call, only with its --model-ruling <comment URL>. Reviews, Verifiers, second opinions: claude-haiku-5-5, on a family other than the lane's; large/risky changes: claude-sonnet-5-5 only on a ruling comment by flywheel, surveyor or switchyard, set with `tkt-state <state> set ruling.<slot> <URL>` (never a lane). This pool covers every job you start. Elsewhere claude-* is reserved for flywheel, surveyor, switchyard and approved Claude plans. Ticket notes' MODEL ROUTING line overrides this pool. Never cursor.

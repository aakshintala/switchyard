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
standard openai/gpt-6-luna:medium; strong openai/gpt-6-luna:xhigh; frontier openai/gpt-6.1-sol. Build/fix/mechanical: openai/gpt-6-luna:medium via pi (owner, 2026-11-11), or opencode-go/muse-spark-1.3-contributor (standard, strong) when it has more quota than codex (owner, 2026-11-13). Reviews, Verifiers, second opinions: claude-haiku-5-5; large/risky changes: claude-sonnet-5-5 only when flywheel, surveyor or switchyard names it (a lane never picks Sonnet). Review family differs from the lane's (owner, 2026-11-11). This pool covers every job you start. Flywheel alone chooses each ruling's frontier rung; openai/gpt-6.1-sol runs only with flywheel's --model-ruling <comment URL>. Otherwise reserve claude-* for flywheel, surveyor, switchyard and approved Claude plans. Ticket notes' MODEL ROUTING line overrides all models here. Never cursor.

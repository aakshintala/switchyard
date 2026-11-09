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
# One line, because mkbrief substitutes it with sed. Keep it a line.
standard muse/muse-spark-1.3-contributor; strong muse/muse-spark-1.3-contributor; frontier openai/gpt-6.1-sol. Reviews spread across openai/gpt-6.1-sol, openai/gpt-6-luna:xhigh and grok-4.7-high, and a review or Verifier always runs on a family other than the lane's. That pool covers every job you start. The frontier rung on a ruling is flywheel's own call to make, not a model you reach for. Muse first while its weekly lasts (owner, 2026-11-06: "use it up"; it resets 2026-11-08), then cursor, then codex. A claude-* model for a lane is allowed only while `~/.agents/bin/quota` shows claude weekly above 40% (owner, 2026-11-06); below that it is reserved for flywheel, surveyor and switchyard. The ticket notes' MODEL ROUTING line wins over every model named here. Never opencode-go (monthly depleted).

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
standard openai/gpt-6-luna:medium; strong openai/gpt-6-luna:xhigh; frontier openai/gpt-6.1-sol. Build, fix and mechanical jobs run on openai/gpt-6-luna:medium through pi (owner, 2026-11-11: fewer tokens than codex, and the Muse weekly is critical). Reviews and Verifiers run on openai/gpt-6-luna:xhigh. That pool covers every job you start. The frontier rung on a ruling is flywheel's own call to make, not a model you reach for. A claude-* model is reserved for flywheel, surveyor, switchyard and approved Claude plans. The ticket notes' MODEL ROUTING line wins over every model named here. Never cursor or opencode-go (monthly depleted).

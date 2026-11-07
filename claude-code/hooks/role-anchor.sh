#!/bin/bash
# SessionStart (compact): re-anchor a --agent role session to its wiki state page.
in=$(cat)
log="$HOME/.claude/hooks/role-anchor.log"
role=$(jq -r '.agent_type // empty' <<<"$in" 2>/dev/null)
echo "$(date -u +%FT%TZ) source=$(jq -r '.source // empty' <<<"$in" 2>/dev/null) agent_type=${role:-<none>}" >>"$log"
[ -n "$role" ] || exit 0
page="$HOME/work/wiki/state/$role.md"
[ -f "$page" ] || exit 0
echo "You are $role. Before acting on the summary's next step, re-read $page and check that the step is your role's job, not a lane's."

# Shared refusal for orchestrator tools that must not run inside a delegate job.
# Source this from beside the calling tkt-* script, then pass its tool name.
tkt_refuse_inside_delegate() {
  local tool="$1" job_id="${DELEGATE_JOB_ID:-}"
  [ -n "$job_id" ] || return 0
  printf "%s: refusing to run inside delegate job %s: a delegate job never runs the orchestrator's tkt-* tools; report to your orchestrator instead; if this is a top-level session, DELEGATE_JOB_ID leaked from its launcher (#1748): report that to switchyard\n" \
    "$tool" "$job_id" >&2
  exit 2
}

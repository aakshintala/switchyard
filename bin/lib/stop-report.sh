#!/usr/bin/env bash
# Shared best-effort reporting for journaled tkt-* stops.
# Call stop_report_notify STATE TICKET TOOL JOB STATUS with report text on stdin.

stop_report_is_stop() {
  case "$1" in
    BLOCKED|ASK|NEEDS_CONTEXT|CONCERNS) return 0 ;;
    *) return 1 ;;
  esac
}

stop_report_job_id() {
  local text
  text="$*"
  awk '{
    for (i = 1; i <= NF; i++) {
      token = $i
      if (token ~ /^(id|job)=/) {
        sub(/^[^=]*=/, "", token)
        sub(/[;,]$/, "", token)
        if (token != "") { print token; exit }
      }
    }
  }' <<<"$text"
}

stop_report_notify() {
  local state="$1" ticket="$2" tool="$3" job="$4" status="$5"
  local journal key inbox host report message rc

  report="$(tail -n 20 2>/dev/null || true)"
  [ -n "$job" ] || job=unknown
  journal="${state%.state}.journal"
  key="$(printf '%s\0%s\0%s' "$tool" "$job" "$status" | shasum -a 256 | awk '{print $1}')" || return 0
  if [ -r "$journal" ] && grep -Fq "stop-report attempt key=$key " "$journal"; then
    return 0
  fi

  # Reserve the tuple before sending: even a failed or interrupted send is not
  # retried by a later write of the same stop verdict.
  "$tkt_state" "$state" journal "stop-report attempt key=$key tool=$tool job=$job status=$status" >/dev/null 2>&1 || return 0

  if [ "${TKT_STOP_INBOX+x}" = x ]; then
    inbox="$TKT_STOP_INBOX"
    if [ -z "$inbox" ]; then
      "$tkt_state" "$state" journal "stop-report WARN inbox unset key=$key" >/dev/null 2>&1 || true
      return 0
    fi
  else
    inbox="${HOME:-}/.cache/agents/inbox/flywheel"
  fi
  host="${TKT_STOP_INBOX_HOST:-}"
  message="Ticket: #$ticket
Tool: $tool
Job ID: $job
Status: $status

Last report lines (up to 20):
$report"

  if [ -n "$host" ]; then
    if printf '%s\n' "$message" | INBOX_HOST="$host" bash "$script_dir/inbox-send" "$inbox" "$tool" >/dev/null 2>&1; then
      "$tkt_state" "$state" journal "stop-report sent key=$key" >/dev/null 2>&1 || true
      return 0
    else
      rc=$?
    fi
  else
    if printf '%s\n' "$message" | bash "$script_dir/inbox-send" "$inbox" "$tool" >/dev/null 2>&1; then
      "$tkt_state" "$state" journal "stop-report sent key=$key" >/dev/null 2>&1 || true
      return 0
    else
      rc=$?
    fi
  fi
  "$tkt_state" "$state" journal "stop-report WARN inbox-send exit $rc key=$key" >/dev/null 2>&1 || true
  return 0
}

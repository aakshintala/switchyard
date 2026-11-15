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
  local journal key inbox report message rc=0

  report="$(tail -n 20 2>/dev/null || true)"
  [ -n "$job" ] || job=unknown
  journal="${state%.state}.journal"
  # The key leaves out the tool: tkt-build passes tkt-job's stop words through,
  # so one job's stop is journaled by both and must send one report.
  key="$(printf '%s\0%s' "$job" "$status" | shasum -a 256 | awk '{print $1}')" || return 0
  # Only a sent report blocks a resend: a later write of a stop whose send
  # failed retries it.
  if [ -r "$journal" ] && grep -Fq "stop-report sent key=$key " "$journal"; then
    return 0
  fi

  # Default: the inbox beside the state, flywheel's watched run/inbox on both
  # hosts (on the box it is a symlink to the box flywheel inbox).
  inbox="${TKT_STOP_INBOX-$(dirname "$state")/inbox}"
  if [ -z "$inbox" ]; then
    "$tkt_state" "$state" journal "stop-report WARN inbox unset key=$key" >/dev/null 2>&1 || true
    return 0
  fi
  message="Ticket: #$ticket
Tool: $tool
Job ID: $job
Status: $status

Last report lines (up to 20):
$report"

  # The sender becomes the filename prefix: stop-report-<ticket>-<tool>-... is
  # what bin/pending.sh (and flywheel's settle-watch) pair with the ticket.
  # Clear INBOX_HOST so an inherited value can't send this off-host.
  printf '%s\n' "$message" | INBOX_HOST= bash "$script_dir/inbox-send" "$inbox" "stop-report-$ticket-$tool" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    "$tkt_state" "$state" journal "stop-report sent key=$key tool=$tool job=$job status=$status" >/dev/null 2>&1 || true
  else
    "$tkt_state" "$state" journal "stop-report WARN inbox-send exit $rc key=$key" >/dev/null 2>&1 || true
  fi
  return 0
}

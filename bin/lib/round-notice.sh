#!/usr/bin/env bash
# Shared best-effort notice for tkt-* round-budget boundaries.
# Source from a command that provides script_dir, bin_dir and tkt_state.

round_notice_send() {
  local state="$1" tool="$2" round="$3" message inbox sender rc=0
  message="NOTICE ROUND-LIMIT round=$round"
  inbox="${TKT_FLYWHEEL_INBOX:-${HOME:-}/flywheel-inbox}"
  sender="tkt-$tool-round-limit"

  if ! "$tkt_state" "$state" journal "$message" >/dev/null 2>&1; then
    printf '%s: warning: could not journal %s\n' "$tool" "$message" >&2
  fi
  printf '%s\n' "$message" | INBOX_HOST= "$bin_dir/inbox-send" "$inbox" "$sender" >/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s: warning: flywheel inbox send failed (exit %s) for %s\n' "$tool" "$rc" "$message" >&2
    "$tkt_state" "$state" journal "NOTICE ROUND-LIMIT WARN inbox-send exit=$rc" >/dev/null 2>&1 || true
  fi
}

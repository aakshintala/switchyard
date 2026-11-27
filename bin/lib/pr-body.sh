#!/usr/bin/env bash
# Shared redacted PR-body publisher for tkt-gate and tkt-fix.
# Source it from beside the calling script, with script_dir resolved through
# symlinks as bin/fill-brief does (check-pack refuses a bare dirname "$0"):
#   pr_body_lib="$script_dir/lib/pr-body.sh"
# The publisher runs "$script_dir/lib/redact-paths".
# A missing or empty body file means there is no body change to publish.
tkt_publish_pr_body_file() {
  local body_file="$1" pr="$2" repo="$3" caller="$4"
  local tmp_redacted

  [ -s "$body_file" ] || return 0
  tmp_redacted="$(mktemp "${TMPDIR:-/tmp}/tkt-pr-body.XXXXXX")" || {
    echo "$caller: warning: cannot update PR $pr body; leaving it unchanged" >&2
    return 1
  }
  if ! "$script_dir/lib/redact-paths" <"$body_file" >"$tmp_redacted" \
    || ! gh pr edit "$pr" --repo "$repo" --body-file "$tmp_redacted" 2>/dev/null; then
    echo "$caller: warning: cannot update PR $pr body; leaving it unchanged" >&2
    rm -f "$tmp_redacted"
    return 1
  fi
  rm -f "$tmp_redacted"
}

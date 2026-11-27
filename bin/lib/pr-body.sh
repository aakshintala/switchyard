#!/usr/bin/env bash
# Shared redacted PR-body publisher for tkt-gate and tkt-fix.
# The caller sets script_dir to its resolved bin directory.
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

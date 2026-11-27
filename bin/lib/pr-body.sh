#!/usr/bin/env bash
# Shared redacted PR-body publisher for tkt-gate and tkt-fix.
# Missing or empty body files mean there is no body change to publish.
tkt_publish_pr_body_file() {
  local body_file="$1" pr="$2" repo="$3" caller="$4"
  local lib_dir tmp_redacted

  [ -s "$body_file" ] || return 0
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "$caller: warning: cannot update PR $pr body; leaving it unchanged" >&2
    return 1
  }
  tmp_redacted="$(mktemp "${TMPDIR:-/tmp}/tkt-pr-body.XXXXXX")" || {
    echo "$caller: warning: cannot update PR $pr body; leaving it unchanged" >&2
    return 1
  }
  if ! "$lib_dir/redact-paths" <"$body_file" >"$tmp_redacted" \
    || ! gh pr edit "$pr" --repo "$repo" --body-file "$tmp_redacted" 2>/dev/null; then
    echo "$caller: warning: cannot update PR $pr body; leaving it unchanged" >&2
    rm -f "$tmp_redacted"
    return 1
  fi
  rm -f "$tmp_redacted"
}

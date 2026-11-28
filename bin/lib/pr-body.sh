#!/usr/bin/env bash
# Shared helpers for body-finding filtering and informational PR-body updates.
# Source it from beside the calling script, with script_dir resolved through
# symlinks as bin/fill-brief does. The publisher runs "$script_dir/lib/redact-paths".
#
# A missing or empty body file means there is no body change to publish.
tkt_is_pr_body_finding() {
  case "$1" in
    P[0-3]\ .review-context/pr-body.md:*|P[0-3]\ PR-body:*) return 0 ;;
    *) return 1 ;;
  esac
}

tkt_has_pr_body_findings() {
  local input="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == P[123]\ * ]] && tkt_is_pr_body_finding "$line" && return 0
  done <"$input"
  return 1
}

# Filter a findings document without mutating its caller-owned source. Remove a
# body's continuation lines through the next finding row as well.
tkt_filter_pr_body_findings() {
  local input="$1" output="$2" line dropping=0
  : >"$output"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == P[123]\ * ]]; then
      if tkt_is_pr_body_finding "$line"; then
        dropping=1
        continue
      fi
      dropping=0
    fi
    [ "$dropping" -eq 0 ] || continue
    printf '%s\n' "$line" >>"$output"
  done <"$input"
  if ! grep -q '[^[:space:]]' "$output"; then
    printf 'no open findings\n' >"$output"
  fi
}

# Publish an informational PR-body update after the code change has succeeded.
# Failure is a warning and must never undo or stop the caller's operation.
tkt_publish_pr_body_file() {
  local body_file="$1" pr="$2" repo="$3" caller="$4"
  local tmp_redacted

  [ -s "$body_file" ] || return 0
  tmp_redacted="$(mktemp "${TMPDIR:-/tmp}/tkt-pr-body.XXXXXX")" || {
    echo "$caller: warning: cannot update PR $pr body; leaving it unchanged" >&2
    return 0
  }
  if ! "$script_dir/lib/redact-paths" <"$body_file" >"$tmp_redacted" \
    || ! gh pr edit "$pr" --repo "$repo" --body-file "$tmp_redacted" 2>/dev/null; then
    echo "$caller: warning: cannot update PR $pr body; leaving it unchanged" >&2
    rm -f "$tmp_redacted" || true
    return 0
  fi
  rm -f "$tmp_redacted" || true
}

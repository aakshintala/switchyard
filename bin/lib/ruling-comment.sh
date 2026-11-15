# Fetch and issue-check a GitHub issue comment used as a recorded ruling.
# Callers provide repo and issue; failures are reported through
# ruling_comment_failure as fetch, issue or author.
fetch_issue_comment() {
  local comment_id="$1" comment_json="$2" comment_error="$3" alternate_issue="${4:-}"
  ruling_comment_failure=""
  ruling_comment_error=""
  if ! gh api "repos/$repo/issues/comments/$comment_id" >"$comment_json" 2>"$comment_error"; then
    ruling_comment_error="$(head -n 1 "$comment_error" 2>/dev/null || true)"
    rm -f "$comment_json" "$comment_error"
    ruling_comment_failure=fetch
    return 1
  fi
  if ! jq -e --arg repo "$repo" --arg issue "$issue" --arg alternate_issue "$alternate_issue" '
    type == "object" and (.body | type == "string")
      and (.issue_url | type == "string")
      and (.issue_url | contains("/repos/" + $repo + "/"))
      and ((($issue != "") and (.issue_url | endswith("/issues/" + $issue)))
        or (($alternate_issue != "") and (.issue_url | endswith("/issues/" + $alternate_issue))))
  ' "$comment_json" >/dev/null 2>&1; then
    rm -f "$comment_json" "$comment_error"
    ruling_comment_failure=issue
    return 1
  fi
  if ! jq -e '
    .author_association == "OWNER"
      or .author_association == "MEMBER"
      or .author_association == "COLLABORATOR"
  ' "$comment_json" >/dev/null 2>&1; then
    rm -f "$comment_json" "$comment_error"
    ruling_comment_failure=author
    return 1
  fi
  return 0
}

# Validate a single round grant after any caller-specific fetch has populated
# the comment JSON. State access is supplied as a function taking get <key>.
check_round_grant() {
  local comment_json="$1" comment_id="$2" round="$3" state_fn="$4"
  local comment_error="${comment_json%.json}.err" next_round grant_value grant_id key_round
  local created_at verdict_at journal_path journal_line journal_stamp journal_stamp_candidate journal_event
  local grant_count grant_number body_row
  grant_round=""
  grant_url=""
  ruling_comment_failure=""
  ruling_comment_hint=""
  case "$comment_id" in
    ''|*[!0-9]*) ruling_comment_failure=bad-id; return 1 ;;
  esac
  if [ ! -s "$comment_json" ]; then
    if ! fetch_issue_comment "$comment_id" "$comment_json" "$comment_error" "${pr:-}"; then
      return 1
    fi
  fi
  next_round=$((round + 1))
  key_round=1
  while [ "$key_round" -le "$round" ]; do
    grant_value="$("$state_fn" get "grant.$key_round" 2>/dev/null || true)"
    grant_id="${grant_value%% *}"
    if [ -n "$grant_value" ] && [ "$grant_id" = "$comment_id" ]; then
      ruling_comment_failure=reused
      return 1
    fi
    key_round=$((key_round + 1))
  done
  grant_value="$("$state_fn" get "grant.$next_round" 2>/dev/null || true)"
  if [ -n "$grant_value" ] && [ "${grant_value%% *}" != "$comment_id" ]; then
    # The round grant.<next_round> covers is still open: no verify has advanced
    # round since that grant was recorded (every fix attempt ended BLOCKED).
    ruling_comment_failure=round-open
    ruling_comment_hint="round $next_round is still open under grant.$next_round (${grant_value%% *}); resume the blocked job with --resume, or rerun with --ruling ${grant_value%% *}"
    return 1
  fi

  created_at="$(jq -r 'if (.created_at | type) == "string" then .created_at else "" end' "$comment_json" 2>/dev/null || true)"
  verdict_at="$("$state_fn" get verdict_at 2>/dev/null || true)"
  if [ -z "$verdict_at" ]; then
    journal_path="${state%.state}.journal"
    journal_stamp=""
    if [ -r "$journal_path" ]; then
      while IFS= read -r journal_line; do
        journal_stamp_candidate="${journal_line%% *}"
        journal_event="${journal_line#* }"
        case "$journal_event" in
          'tkt-fix FIX-'*|'tkt-fix PUSHED'|'tkt-fix PUSHED '*|'tkt-build APPROVE'|'tkt-build APPROVE '*|'tkt-build CHANGES'|'tkt-build CHANGES '*|'tkt-verify FIX-OK'|'tkt-verify FIX-OK '*)
            journal_stamp="$journal_stamp_candidate" ;;
        esac
      done <"$journal_path"
    fi
    verdict_at="$journal_stamp"
    # A legacy tkt-verify FIX-INCOMPLETE was not journaled. The gap is acceptable:
    # the grants: round <n> form is new, so no comment that predates this change
    # can carry it; on a legacy state the form check therefore stands in for the freshness check.
  fi
  if [[ ! "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || [[ ! "$verdict_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    ruling_comment_failure=stale
    return 1
  fi
  if ! (LC_ALL=C; [[ "$created_at" > "$verdict_at" ]]); then
    ruling_comment_failure=stale
    return 1
  fi

  grant_count=0
  grant_number=""
  while IFS= read -r body_row || [ -n "$body_row" ]; do
    body_row="${body_row%$'\r'}"
    case "$body_row" in
      grants:*)
        grant_count=$((grant_count + 1))
        if [[ "$body_row" =~ ^grants:\ round\ ([0-9]+)$ ]]; then
          grant_number="${BASH_REMATCH[1]}"
        else
          grant_number="invalid"
        fi
        ;;
    esac
  done < <(jq -r '.body' "$comment_json")
  if [ "$grant_count" -ne 1 ] || [ "$grant_number" != "$next_round" ] \
    || [ "${grant_comment_count:-1}" -gt 1 ]; then
    ruling_comment_failure=bad-grant
    return 1
  fi
  if [ "${round_grant_limited:-0}" -ne 1 ]; then
    ruling_comment_failure=not-limited
    return 1
  fi
  grant_round="$next_round"
  grant_url="$(jq -r '.html_url // ""' "$comment_json" 2>/dev/null || true)"
  return 0
}

record_round_grant() {
  local comment_id="$1" url="$2" round="$3" state_fn="$4" existing
  existing="$("$state_fn" get "grant.$round" 2>/dev/null || true)"
  if [ "${existing%% *}" != "$comment_id" ]; then
    "$state_fn" set "grant.$round" "$comment_id $url"
    "$state_fn" add body_has "Recorded ruling: $url"
    "$state_fn" journal "ruling $url grants round $round"
  fi
}

# Append the first stderr line captured by fetch_issue_comment to its caller's
# refusal detail. Keep this formatting shared across all ruling-comment paths.
ruling_comment_fetch_detail() {
  local detail="$1"
  [ -z "${ruling_comment_error:-}" ] || detail="$detail: $ruling_comment_error"
  printf '%s' "$detail"
}

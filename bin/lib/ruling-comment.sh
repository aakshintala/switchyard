# Fetch and issue-check a GitHub issue comment used as a recorded ruling.
# Callers provide repo and issue; failures are reported through
# ruling_comment_failure as fetch or issue.
fetch_issue_comment() {
  local comment_id="$1" comment_json="$2" comment_error="$3"
  ruling_comment_failure=""
  if ! gh api "repos/$repo/issues/comments/$comment_id" >"$comment_json" 2>"$comment_error"; then
    rm -f "$comment_json" "$comment_error"
    ruling_comment_failure=fetch
    return 1
  fi
  if ! jq -e --arg repo "$repo" --arg issue "$issue" '
    type == "object" and (.body | type == "string")
      and (.issue_url | type == "string")
      and (.issue_url | contains("/repos/" + $repo + "/"))
      and (.issue_url | endswith("/issues/" + $issue))
  ' "$comment_json" >/dev/null 2>&1; then
    rm -f "$comment_json" "$comment_error"
    ruling_comment_failure=issue
    return 1
  fi
  return 0
}

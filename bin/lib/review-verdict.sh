# Shared parsing of posted review-pr verdict comments. Callers source verify-section.sh first.

review_comment_rows() {
  local repo="$1" pr="$2" comments rows tab
  comments="$(gh api --paginate "repos/$repo/issues/$pr/comments")" || return 1
  rows="$(printf '%s\n' "$comments" | jq -r '
    .[] |
    select((.body // "") | startswith("review-pr: patch-id")) |
    # Only a trusted author can post a verdict; the repo is public (#1790).
    select(.author_association == "OWNER" or .author_association == "MEMBER"
      or .author_association == "COLLABORATOR") |
    [.created_at, (.id | tostring), (.body | split("\n")[0]), (.body | @base64)] | @tsv
  ')" || return 1
  [ -n "$rows" ] || return 0
  tab="$(printf '\t')"
  printf '%s\n' "$rows" | sort -t "$tab" -k1,1 -k2,2n
}

review_header_value() {
  local field="$1" header="$2"
  case "$field" in
    patch-id) printf '%s' "$header" | sed -n 's/^review-pr: patch-id \([^,]*\), head .*/\1/p' ;;
    head) printf '%s' "$header" | sed -n 's/^review-pr: patch-id [^,]*, head \([0-9a-f]\{40\}\).*/\1/p' ;;
    since) printf '%s' "$header" | sed -n 's/.*,[[:space:]]since[[:space:]]\([0-9a-f]\{40\}\)\(,.*\)\{0,1\}$/\1/p' ;;
    *) return 2 ;;
  esac
}

# review_verdict REPO PR PATCH_ID: print the newest trusted review-pr verdict for
# the patch-id. On FIX-INCOMPLETE, return readable P3 findings from that comment.
review_verdict() {
  local repo="$1" pr="$2" reviewed_pid="$3" rows tab last created id header verdicts axes axis body64 findings_file parsed
  local -a axis_list=()
  rows="$(review_comment_rows "$repo" "$pr")" || return 1
  tab="$(printf '\t')"
  last="$(printf '%s\n' "$rows" \
    | { grep -E "^.*${tab}review-pr: patch-id ${reviewed_pid}, head [0-9a-f]{40}(,.*)?${tab}" || true; } \
    | tail -n 1)"
  [ -n "$last" ] || { printf 'missing'; return 0; }
  IFS=$'\t' read -r created id header body64 <<<"$last"
  parsed="$(jq -nr --arg body64 "$body64" '
    ($body64 | @base64d | split("\n")) as $lines |
    ($lines[1:] | reduce .[] as $raw (
      {section:"", axes:[], verdicts:[]};
      ($raw | gsub("[*`]"; "") | gsub("^\\s+|\\s+$"; "")) as $line |
      if ($line | test("^## (standards|spec|overbuild|verify)([[:space:]]|$)")) then
        ($line | capture("^## (?<section>standards|spec|overbuild|verify)").section) as $section |
        .section = $section |
        if ($section == "standards" or $section == "spec" or $section == "overbuild") then .axes += [$section] else . end
      elif ($line | test("^VERDICT standards: APPROVE\\.?$")) then .verdicts += ["standards:APPROVE"]
      elif ($line | test("^VERDICT standards: CHANGES\\.?$")) then .verdicts += ["standards:CHANGES"]
      elif ($line | test("^VERDICT spec: APPROVE\\.?$")) then .verdicts += ["spec:APPROVE"]
      elif ($line | test("^VERDICT spec: CHANGES\\.?$")) then .verdicts += ["spec:CHANGES"]
      elif ($line | test("^VERDICT overbuild: APPROVE\\.?$")) then .verdicts += ["overbuild:APPROVE"]
      elif ($line | test("^VERDICT overbuild: CHANGES\\.?$")) then .verdicts += ["overbuild:CHANGES"]
      elif .section == "overbuild" and ($line | test("^VERDICT: APPROVE\\.?$")) then .verdicts += ["overbuild:APPROVE"]
      elif .section == "overbuild" and ($line | test("^VERDICT: CHANGES\\.?$")) then .verdicts += ["overbuild:CHANGES"]
      elif .section == "verify" and ($line | test("^FIX-OK([.:;,]($|\\s)|$|\\s)")) then .verdicts += ["verify:FIX-OK"]
      elif .section == "verify" and ($line | test("^FIX-INCOMPLETE([.:;,]($|\\s)|$|\\s)")) then .verdicts += ["verify:FIX-INCOMPLETE"]
      elif ($line | test("^(VERDICT|FIX-)")) then .verdicts += ["INVALID"]
      else . end
    )) as $parsed |
    [
      ($parsed.verdicts | if length == 0 then "-" else join(",") end),
      ($parsed.axes | unique | if length == 0 then "-" else join(",") end)
    ] | @tsv
  ')" || return 1
  IFS=$'\t' read -r verdicts axes <<<"$parsed"
  case ",$verdicts," in *,INVALID,*) printf 'invalid'; return 0 ;; esac
  if [[ ",$verdicts," == *,verify:FIX-OK,* ]]; then
    # A verify may repeat its FIX-OK line; any other entry beside it is invalid.
    local rest="${verdicts},"
    rest="${rest//verify:FIX-OK,/}"
    [ -z "$rest" ] && printf 'approved' || printf 'invalid'
    return 0
  fi
  case ",$verdicts," in *,verify:FIX-INCOMPLETE,*)
    if [ -n "${unverified:-}" ]; then
      printf 'unverified'
    else
      findings_file="$(mktemp "${TMPDIR:-/tmp}/ship-pr-${pr}-findings.XXXXXX")" || { printf 'incomplete'; return 0; }
      if parse_p3_verify_findings "$body64" "$findings_file"; then
        printf 'incomplete-p3\n'
        cat "$findings_file"
      else
        printf 'incomplete'
      fi
      rm -f "$findings_file"
    fi
    return 0 ;;
  esac
  [ "$axes" != "-" ] || { printf 'missing'; return 0; }
  IFS=',' read -r -a axis_list <<<"$axes"
  for axis in "${axis_list[@]}"; do
    case ",$verdicts," in *",$axis:APPROVE,"*|*",$axis:CHANGES,"*) ;; *) printf 'invalid'; return 0 ;; esac
  done
  case ",$verdicts," in
    *":CHANGES,"*)
      # The documented no-real-bug path ships a reviewed CHANGES round without
      # re-review, but only when the caller supplies --unverified-fixes.
      [ -n "${unverified:-}" ] && printf 'unverified' || printf 'changes';;
    *":APPROVE,"*) printf 'approved';;
    *) printf 'missing';;
  esac
}

parse_p3_verify_findings() {
  local encoded="$1" output="$2" decoded="${2}.comment" line count=0 decoded_ok=1 valid=1 result=1
  if ! printf '%s' "$encoded" | base64 -D >"$decoded" 2>/dev/null; then
    if ! printf '%s' "$encoded" | base64 -d >"$decoded" 2>/dev/null; then
      decoded_ok=0
    fi
  fi
  if [ "$decoded_ok" = 1 ]; then
    : >"$output"
    while IFS= read -r line || [ -n "$line" ]; do
      # A finding is a line that starts with a priority token once markup and any
      # list marker are gone; prose that mentions a fixed P1 or P2 is not one.
      line="$(normalize_finding_line "$line")"
      if [[ "$line" =~ ^P[0-9]([^[:alnum:]_]|$) ]]; then
        if [[ "$line" =~ ^P3[[:space:]]+[^[:space:]] ]]; then
          printf '%s\n' "$line" >>"$output"
          count=$((count + 1))
        else
          valid=0
          break
        fi
      fi
    done < <(verify_section_lines <"$decoded")
    [ "$valid" = 1 ] && [ "$count" -gt 0 ] && result=0
  fi
  rm -f "$decoded"
  [ "$result" = 0 ]
}

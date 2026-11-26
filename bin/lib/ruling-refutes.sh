#!/usr/bin/env bash
# Shared parsing, matching and row-marking for issue-comment refutations.
# Call after findings-history.sh and verify-section.sh; callers map
# ruling_refutes_failure* and ruling_refutes_drift_* to their own refusal
# format, and initialize the arrays ruling_refute_{ids,urls,prefixes,bases}.
# Keep refusal/emit mapping in each caller, since their emit contracts differ;
# only the candidate-row printer is shared.

ruling_match_begin() {
  ruling_match_seen=()
  ruling_match_count=0
  ruling_match_base=""
  # Entries are "<source><TAB><base>", in first-seen order.
  ruling_match_candidates=()
  ruling_match_matched=()
}

# Succeed when the first argument equals any later one.
ruling_match_has() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [ "$item" != "$needle" ] || return 0
  done
  return 1
}

# Succeed when the validated rulings refute every open P1-P3 row in the
# current findings file and posted findings history. The caller owns the
# behavior when no rows are open; this helper returns false in that case.
ruling_refutes_all_open_rows() {
  local findings_file="$1" history_file="$2"
  local source_kind source row base status
  ruling_open_rows=0
  ruling_all_open_rows_refuted=1
  for source_kind in current history; do
    if [ "$source_kind" = current ]; then source="$findings_file"; else source="$history_file"; fi
    [ -n "$source" ] && [ -r "$source" ] || continue
    while IFS= read -r row; do
      base="$(findings_row_base "$row")"
      base="$(normalize_finding_line "$base")"
      case "$base" in P1\ *|P2\ *|P3\ *) ;; *) continue ;; esac
      status=open
      if [ "$source_kind" = history ]; then
        status="$(findings_row_status "$row")"
        [ -n "$status" ] || status=open
      fi
      [ "$status" = open ] || continue
      ruling_open_rows=$((ruling_open_rows + 1))
      if ! ruling_match_has "$base" "${ruling_refute_bases[@]+${ruling_refute_bases[@]}}"; then
        ruling_all_open_rows_refuted=0
      fi
    done <"$source"
  done
  [ "$ruling_open_rows" -gt 0 ] && [ "$ruling_all_open_rows_refuted" -eq 1 ]
}

ruling_match_file() {
  local prefix="$1" path="$2" kind="$3" row base status entry candidate_source boundary_match
  # A ruling may copy the row's markup; compare both sides without it.
  prefix="$(normalize_finding_line "$prefix")"
  case "$kind" in history) candidate_source='posted round' ;; *) candidate_source='findings file' ;; esac
  [ -n "$path" ] && [ -r "$path" ] || return 0
  while IFS= read -r row; do
    base="$(findings_row_base "$row")"
    base="$(normalize_finding_line "$base")"
    # This follows findings_row_base/normalisation; keep its internal class separate from raw input rows.
    case "$base" in P1\ *|P2\ *|P3\ *) ;; *) continue;; esac
    status=open
    if [ "$kind" = history ]; then
      status="$(findings_row_status "$row")"
      [ -n "$status" ] || status=open
    fi
    [ "$status" = open ] || continue

    entry="$candidate_source"$'\t'"$base"
    ruling_match_has "$entry" ${ruling_match_candidates[@]+"${ruling_match_candidates[@]}"} \
      || ruling_match_candidates+=("$entry")

    boundary_match=0
    case "$base" in
      # `:` may run into a line number (path:N); `,` `.` `;` end a token only
      # before a space or at the end, so a path prefix can't match a longer filename.
      "$prefix"|"$prefix "*|"$prefix":*|"$prefix",|"$prefix",\ *|"$prefix".|"$prefix".\ *|"$prefix"\;|"$prefix"\;\ *) boundary_match=1 ;;
    esac
    [ "$boundary_match" -eq 1 ] || continue
    ruling_match_has "$entry" ${ruling_match_matched[@]+"${ruling_match_matched[@]}"} \
      || ruling_match_matched+=("$entry")

    ! ruling_match_has "$base" ${ruling_match_seen[@]+"${ruling_match_seen[@]}"} || continue
    ruling_match_seen+=("$base")
    ruling_match_count=$((ruling_match_count + 1))
    [ "$ruling_match_count" -ne 1 ] || ruling_match_base="$base"
  done <"$path"
}

# After a no-match or ambiguous ruling_refutes_validate_file failure, print the
# open rows it saw (no-match) or the rows the prefix matched (ambiguous) to
# stderr: at most 20, each cut to 100 characters, labelled by source. A row
# found in both sources prints once, with both labels.
ruling_refutes_print_candidates() {
  local failure="$1" label="${2:-review-pr}" entry row source total limit index found
  local -a entries=() rows=() sources=()
  case "$failure" in
    ambiguous) entries=(${ruling_match_matched[@]+"${ruling_match_matched[@]}"}) ;;
    no-match) entries=(${ruling_match_candidates[@]+"${ruling_match_candidates[@]}"}) ;;
    *) return 0 ;;
  esac
  for entry in ${entries[@]+"${entries[@]}"}; do
    source="${entry%%$'\t'*}"
    row="${entry#*$'\t'}"
    found=""
    for index in ${rows[@]+"${!rows[@]}"}; do
      [ "${rows[$index]}" != "$row" ] || { found="$index"; break; }
    done
    if [ -n "$found" ]; then
      sources[$found]="${sources[$found]}, $source"
    else
      rows+=("$row")
      sources+=("$source")
    fi
  done
  total="${#rows[@]}"
  if [ "$total" -eq 0 ]; then
    echo "$label: no open candidate rows" >&2
    return 0
  fi
  limit="$total"
  [ "$limit" -le 20 ] || limit=20
  for ((index = 0; index < limit; index++)); do
    row="${rows[$index]}"
    [ "${#row}" -le 100 ] || row="${row:0:100}..."
    echo "$label: open candidate [${sources[$index]}]: $row" >&2
  done
  [ "$total" -le "$limit" ] || echo "$label: ... $((total - limit)) more candidate rows" >&2
}

# Parse and validate every column-0 refutes: line in one ruling comment.
# Failure details are returned in ruling_refutes_failure{,_id,_prefix}; success
# appends the validated rows to the caller's ruling_refute_* arrays.
ruling_refutes_validate_file() {
  local comment_id="$1" comment_url="$2" refutes_file="$3"
  local ruling_line ruling_prefix source_index
  local -a match_sources=("${@:4}")
  local ruling_refutes_pattern='^P[123] ([^[:space:]]|[^[:space:]].*[^[:space:]])$'
  ruling_refutes_failure=""
  ruling_refutes_failure_id="$comment_id"
  ruling_refutes_failure_prefix=""
  ruling_refutes_hint=""
  while IFS= read -r ruling_line || [ -n "$ruling_line" ]; do
    ruling_line="${ruling_line%$'\r'}"
    case "$ruling_line" in
      'refutes: '*) ruling_prefix="${ruling_line#refutes: }" ;;
      *) ruling_prefix="${ruling_line#refutes:}" ;;
    esac
    if [[ ! "$(normalize_finding_line "$ruling_prefix")" =~ $ruling_refutes_pattern ]]; then
      ruling_refutes_failure=bad-refutes
      ruling_refutes_hint='line must start with P1, P2 or P3 followed by a space and the row text (for example, `refutes: P2 bin/x:12 ...`).'
      return 1
    fi
    ruling_match_begin
    for ((source_index = 0; source_index < ${#match_sources[@]}; source_index += 2)); do
      ruling_match_file "$ruling_prefix" \
        "${match_sources[$((source_index + 1))]}" \
        "${match_sources[$source_index]}"
    done
    if [ "$ruling_match_count" -eq 0 ]; then
      ruling_refutes_failure=no-match
      ruling_refutes_failure_prefix="$ruling_prefix"
      ruling_refutes_hint='Use a column-0 `refutes: <row prefix>` line; the prefix starts with `P<n> `, ends where the row has a space, a `:`, or a `,`, `.` or `;` followed by a space or the row'"'"'s end, and matches exactly one open row. Put any reason on the next line.'
      return 1
    fi
    if [ "$ruling_match_count" -ne 1 ]; then
      ruling_refutes_failure=ambiguous
      ruling_refutes_failure_prefix="$ruling_prefix"
      return 1
    fi
    ruling_refute_ids+=("$comment_id")
    ruling_refute_urls+=("$comment_url")
    ruling_refute_prefixes+=("$ruling_prefix")
    ruling_refute_bases+=("$ruling_match_base")
  done <"$refutes_file"
}

# Copy a source file, mark its refuted rows, then replace the copy with the
# marked output. Failure details are returned in
# ruling_refutes_prepare_failure and ruling_refutes_drift_{id,prefix}.
ruling_refutes_prepare() {
  local source_file="$1" output_file="$2" marked_file="$3"
  ruling_refutes_prepare_failure=""
  ruling_refutes_drift_id=""
  ruling_refutes_drift_prefix=""
  cp "$source_file" "$output_file" || {
    ruling_refutes_prepare_failure=copy
    return 1
  }
  if ! ruling_refutes_mark_rows "$output_file" "$marked_file"; then
    ruling_refutes_prepare_failure=drift
    return 1
  fi
  mv "$marked_file" "$output_file" || {
    ruling_refutes_prepare_failure=prepare
    return 1
  }
}

# Recheck the captured match against the actual verification input, then write
# refuted: annotations under the matching open P1-P3 rows to output_file.
# On drift, return non-zero with ruling_refutes_drift_{id,prefix} set.
ruling_refutes_mark_rows() {
  local source_file="$1" output_file="$2"
  local ruling_index row row_base row_status
  ruling_refutes_drift_id=""
  ruling_refutes_drift_prefix=""
  for ruling_index in "${!ruling_refute_ids[@]}"; do
    ruling_match_begin
    ruling_match_file "${ruling_refute_prefixes[$ruling_index]}" "$source_file" history
    if [ "$ruling_match_count" -ne 1 ] \
      || [ "$ruling_match_base" != "${ruling_refute_bases[$ruling_index]}" ]; then
      ruling_refutes_drift_id="${ruling_refute_ids[$ruling_index]}"
      ruling_refutes_drift_prefix="${ruling_refute_prefixes[$ruling_index]}"
      return 1
    fi
  done
  {
    while IFS= read -r row; do
      printf '%s\n' "$row"
      row_base="$(findings_row_base "$row")"
      row_base="$(normalize_finding_line "$row_base")"
      # This follows findings_row_base/normalisation; it is a history class, not raw input validation.
      case "$row_base" in P1\ *|P2\ *|P3\ *) ;; *) continue;; esac
      row_status="$(findings_row_status "$row")"
      [ -n "$row_status" ] || row_status=open
      [ "$row_status" = open ] || continue
      for ruling_index in "${!ruling_refute_ids[@]}"; do
        if [ "$row_base" = "${ruling_refute_bases[$ruling_index]}" ]; then
          printf 'refuted: recorded ruling %s (refutes: %s); text in .review-context/ruling-%s.md\n' \
            "${ruling_refute_urls[$ruling_index]}" \
            "${ruling_refute_prefixes[$ruling_index]}" \
            "${ruling_refute_ids[$ruling_index]}"
        fi
      done
    done <"$source_file"
  } >"$output_file"
}

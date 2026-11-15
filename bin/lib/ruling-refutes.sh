#!/usr/bin/env bash
# Shared parsing, matching and row-marking for issue-comment refutations.
# Call after findings-history.sh and verify-section.sh; callers map
# ruling_refutes_failure* and ruling_refutes_drift_* to their own refusal
# format, and initialize the arrays ruling_refute_{ids,urls,prefixes,bases}.

ruling_match_begin() {
  ruling_match_seen=()
  ruling_match_count=0
  ruling_match_base=""
}

ruling_match_file() {
  local prefix="$1" path="$2" kind="$3" row base status prior duplicate
  # A ruling may copy the row's markup; compare both sides without it.
  prefix="$(normalize_finding_line "$prefix")"
  [ -n "$path" ] && [ -r "$path" ] || return 0
  while IFS= read -r row; do
    base="$(findings_row_base "$row")"
    base="$(normalize_finding_line "$base")"
    case "$base" in P1\ *|P2\ *|P3\ *) ;; *) continue;; esac
    duplicate=0
    for prior in ${ruling_match_seen[@]+"${ruling_match_seen[@]}"}; do
      if [ "$prior" = "$base" ]; then duplicate=1; break; fi
    done
    [ "$duplicate" -eq 0 ] || continue
    ruling_match_seen+=("$base")
    status=open
    if [ "$kind" = history ]; then
      status="$(findings_row_status "$row")"
      [ -n "$status" ] || status=open
    fi
    [ "$status" = open ] || continue
    case "$base" in
      "$prefix"|"$prefix "*)
        ruling_match_count=$((ruling_match_count + 1))
        [ "$ruling_match_count" -ne 1 ] || ruling_match_base="$base" ;;
    esac
  done <"$path"
}

# Parse and validate every column-0 refutes: line in one ruling comment.
# Failure details are returned in ruling_refutes_failure{,_id,_prefix}; success
# appends the validated rows to the caller's ruling_refute_* arrays.
ruling_refutes_validate_file() {
  local comment_id="$1" comment_url="$2" refutes_file="$3"
  local history_source="$4" findings_file="$5"
  local ruling_line ruling_prefix
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
      return 1
    fi
    ruling_match_begin
    ruling_match_file "$ruling_prefix" "$history_source" history
    ruling_match_file "$ruling_prefix" "$findings_file" current
    if [ "$ruling_match_count" -eq 0 ]; then
      ruling_refutes_failure=no-match
      ruling_refutes_failure_prefix="$ruling_prefix"
      ruling_refutes_hint='Use a column-0 `refutes: <exact leading text of the row>` line; put any reason on the next line.'
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
  ruling_refutes_prepared_file="$output_file"
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

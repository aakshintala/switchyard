#!/usr/bin/env bash
# Shared parsing for the verify section in a review comment.
# Call verify_section_lines with the comment body on stdin; it prints only the
# lines between a normalised ## verify heading and the next ## heading.

# norm_line: strip verdict decoration (asterisks, backticks) and trim
# surrounding whitespace, so decorated headings and verdicts match.
norm_line() {
  printf '%s' "$1" | tr -d '*`' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# normalize_finding_line: strip finding markup, a leading list marker and
# surrounding whitespace before matching a finding row.
normalize_finding_line() {
  printf '%s' "$1" | tr -d '*`' | sed -E \
    -e 's/^[[:space:]]*//' \
    -e 's/^([-+]|[0-9]+[.)])[[:space:]]+//' \
    -e 's/[[:space:]]*$//'
}

# finding_rows CLASS FILE: print raw, column-0 finding rows. Input findings
# files contain P1-P3; review output also permits P0. Keep these classes apart.
finding_rows() {
  local row_class="$1" file="$2" pattern
  case "$row_class" in
    input) pattern='^P[123] ' ;;
    verify-output) pattern='^P[0123] ' ;;
    *) return 2 ;;
  esac
  grep "$pattern" "$file"
}

verify_section_lines() {
  local line norm in_verify=0
  while IFS= read -r line || [ -n "$line" ]; do
    norm="$(norm_line "$line")"
    case "$norm" in
      "## verify"|"## verify "*) in_verify=1; continue;;
      "## "*) in_verify=0; continue;;
    esac
    [ "$in_verify" = 1 ] || continue
    printf '%s\n' "$line"
  done
}

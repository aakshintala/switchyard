#!/usr/bin/env bash
# Shared parsing for the verify section in a review comment.
# Call verify_section_lines with the comment body on stdin; it prints only the
# lines between a normalised ## verify heading and the next ## heading.

# norm_line: strip verdict decoration (asterisks, backticks) and trim
# surrounding whitespace, so decorated headings and verdicts match.
norm_line() {
  printf '%s' "$1" | tr -d '*`' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
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

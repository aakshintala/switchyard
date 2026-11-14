#!/usr/bin/env bash
# Tests for bin/lib/redact-paths as a byte-preserving stdin filter.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILTER="$SCRIPT_DIR/../bin/lib/redact-paths"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-redact-paths.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mac_top=Users
linux_top=home
mac_home="/$mac_top/alpha"
linux_home="/$linux_top/beta"
root_top=root
root_home="/$root_top"
lanes=/srv/lanes
repo=sample-repo
worktree=lane-one

{
  printf 'run `%s/.cache/agents/run/report.md` and %s/.cache/agents/run/log.txt\n' "$mac_home" "$linux_home"
  printf 'root run %s/.cache/agents/run/root-log.txt\n' "$root_home"
  printf 'lanes %s/%s-worktrees/%s/src/main.rs and %s/sy-wt/%s/docs/readme.md\n' \
    "$lanes" "$repo" "$worktree" "$lanes" "$worktree"
  printf 'homes %s/project/file.txt %s/project/file.txt %s/etc/config\n' \
    "$mac_home" "$linux_home" "$root_home"
} >"$T/input"
"$FILTER" <"$T/input" >"$T/actual" || fail "filter accepts path examples"
cat >"$T/expected" <<'EOF'
run `run/report.md` and run/log.txt
root run run/root-log.txt
lanes <lane worktree>/src/main.rs and <lane worktree>/docs/readme.md
homes ~/project/file.txt ~/project/file.txt ~/etc/config
EOF
cmp -s "$T/expected" "$T/actual" || fail "the three host path kinds are redacted in order"

# With no paths, retain every input byte, including CRLF and no final newline.
printf 'plain text\twith punctuation.\r\nsecond line has no final newline' >"$T/unchanged"
"$FILTER" <"$T/unchanged" >"$T/unchanged-out" || fail "filter accepts text without paths"
cmp -s "$T/unchanged" "$T/unchanged-out" || fail "text without paths is unchanged byte-for-byte"

echo "redact-paths: all cases passed"

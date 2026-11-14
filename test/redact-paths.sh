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

run=work/fiber-worktrees/flywheel/run
{
  printf 'run `%s/%s/report.md` and %s/%s/log.txt\n' "$mac_home" "$run" "$linux_home" "$run"
  printf 'root run %s/%s/root-log.txt\n' "$root_home" "$run"
  printf 'bare run `%s/%s` and %s/%s.\n' "$mac_home" "$run" "$linux_home" "$run"
  printf 'lanes %s/%s-worktrees/%s/src/main.rs and %s/sy-wt/%s/docs/readme.md\n' \
    "$lanes" "$repo" "$worktree" "$lanes" "$worktree"
  printf 'bare lane `%s/%s-worktrees/%s`\n' "$lanes" "$repo" "$worktree"
  printf 'box lane %s/box-layout/%s/x and %s/box-layout/%s.\n' "$lanes" "$worktree" "$lanes" "$worktree"
  printf 'homes %s/project/file.txt %s/project/file.txt %s/etc/config\n' \
    "$mac_home" "$linux_home" "$root_home"
  printf 'bare homes %s, `%s` and %s.\n' "$mac_home" "$linux_home" "$root_home"
  printf 'other cache %s/.cache/agents/run/x.md\n' "$mac_home"
  printf 'not homes /%sx/a /%s/b/c /%sfs/d\n' "$mac_top" "srv" "$root_top"
} >"$T/input"
"$FILTER" <"$T/input" >"$T/actual" || fail "filter accepts path examples"
cat >"$T/expected" <<'EOF'
run `run/report.md` and run/log.txt
root run run/root-log.txt
bare run `run` and run.
lanes <lane worktree>/src/main.rs and <lane worktree>/docs/readme.md
bare lane `<lane worktree>`
box lane <lane worktree>/x and <lane worktree>.
homes ~/project/file.txt ~/project/file.txt ~/etc/config
bare homes ~, `~` and ~.
other cache ~/.cache/agents/run/x.md
not homes /Usersx/a /srv/b/c /rootfs/d
EOF
cmp -s "$T/expected" "$T/actual" || fail "the three host path kinds are redacted in order"

# With no paths, retain every input byte, including CRLF and no final newline.
printf 'plain text\twith punctuation.\r\nsecond line has no final newline' >"$T/unchanged"
"$FILTER" <"$T/unchanged" >"$T/unchanged-out" || fail "filter accepts text without paths"
cmp -s "$T/unchanged" "$T/unchanged-out" || fail "text without paths is unchanged byte-for-byte"

echo "redact-paths: all cases passed"

#!/usr/bin/env bash
# Tests for bin/plan-gate. Exits non-zero on the first failed case.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../bin/plan-gate"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-plan-gate.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# expect_out NAME CONTENT WANT: the gate prints WANT and exits 0
expect_out() {
  printf '%b' "$2" >"$T/plan.md"
  out="$(bash "$GATE" "$T/plan.md" 2>"$T/err.txt")" || fail "$1: exits 0"
  [ "$out" = "$3" ] || fail "$1: got [$out], want [$3]"
  [ ! -s "$T/err.txt" ] || fail "$1: nothing on stderr"
}

# expect_err NAME CONTENT: the gate exits 1, prints nothing on stdout, one stderr line
expect_err() {
  printf '%b' "$2" >"$T/plan.md"
  stdout="$(bash "$GATE" "$T/plan.md" 2>"$T/err.txt")" && fail "$1: exits 1"
  [ -z "$stdout" ] || fail "$1: prints nothing on stdout"
  [ "$(wc -l <"$T/err.txt" | tr -d ' ')" = "1" ] || fail "$1: one stderr line"
  grep -q '^plan-gate: ' "$T/err.txt" || fail "$1: stderr starts with plan-gate:"
}

# the three accepted forms
expect_out "bare command" '# Plan\n\n## Gate\n\nbash test/run\n' 'bash test/run'
expect_out "backticked command" '## Gate\n\n`bash test/run && bash bin/check-pack`\n' 'bash test/run && bash bin/check-pack'
expect_out "fenced command" '## Gate\n\n```\nbash test/run\n```\n' 'bash test/run'
expect_out "fenced command with a language tag" '## Gate\n```bash\nbash test/run\n```\n' 'bash test/run'

# prose before the heading is ignored, even when it looks like a command
expect_out "prose before heading" 'Gate: run `wrong`\nbash wrong\n\n## Gate\nbash test/run\n' 'bash test/run'

# trailing text on the heading line is allowed
expect_out "heading with trailing text" '## Gate (must pass before merge)\nbash test/run\n' 'bash test/run'

# the section ends at the next ## heading
expect_out "section ends at next heading" '## Gate\nbash test/run\n## Notes\nbash other\n' 'bash test/run'

# a ### subheading inside the section is skipped, not a terminator
expect_out "### Command subheading" '## Gate\n### Command\nbash test/run\n' 'bash test/run'

# exit 1 cases
expect_err "missing heading" '# Plan\n\nbash test/run\n'
expect_err "subheading does not end the section" '## Gate\nbash test/run\n### Notes\nbash other\n'
# a command that still holds a backtick after stripping is rejected (see #324)
printf '%b' '## Gate\n`scripts/check` → PASS\n' >"$T/plan.md"
stdout="$(bash "$GATE" "$T/plan.md" 2>"$T/err.txt")" && fail "backtick annotation exits 1"
[ -z "$stdout" ] || fail "backtick annotation prints nothing on stdout"
want="plan-gate: the '## Gate' command holds a backtick: $T/plan.md: \`scripts/check\` → PASS"
[ "$(cat "$T/err.txt")" = "$want" ] || fail "backtick annotation: got [$(cat "$T/err.txt")], want [$want]"
# a plain command with no backtick still passes
printf '%b' '## Gate\nscripts/check\n' >"$T/plan.md"
out="$(bash "$GATE" "$T/plan.md" 2>"$T/err.txt")" || fail "plain command exits 0"
[ "$out" = "scripts/check" ] || fail "plain command: got [$out]"
expect_err "heading only in prose" 'see the Gate section\n'
expect_err "empty section" '## Gate\n\n## Next\nbash x\n'
expect_err "section at end of file with no command" '## Gate\n\n'
expect_err "bare fence with no command" '## Gate\n```\n```\n'
expect_err "two command lines" '## Gate\nbash a\nbash b\n'
expect_err "two lines inside a fence" '## Gate\n```\nbash a\nbash b\n```\n'
expect_err "backticked whitespace only" '## Gate\n`   `\n'
expect_err "heading is a longer word" '## Gateway\nbash test/run\n'
expect_err "command plus prose" '## Gate\nRun the tests.\nbash test/run\n'

# exit 2: bad usage or unreadable plan
bash "$GATE" >/dev/null 2>&1; [ "$?" = "2" ] || fail "no args exits 2"
bash "$GATE" "$T/plan.md" "$T/plan.md" >/dev/null 2>&1; [ "$?" = "2" ] || fail "two args exit 2"
bash "$GATE" -h >/dev/null 2>&1; [ "$?" = "2" ] || fail "-h exits 2"
bash "$GATE" --help >/dev/null 2>&1; [ "$?" = "2" ] || fail "--help exits 2"
bash "$GATE" "$T/does-not-exist.md" >/dev/null 2>&1; [ "$?" = "2" ] || fail "missing plan file exits 2"

echo "plan-gate: all cases passed"

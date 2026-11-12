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

# --fix selects the optional Fix gate, requires its placeholder, and keeps
# --script validation on the selected gate.
expect_fix_out() {
  printf '%b' "$2" >"$T/plan.md"
  out="$(bash "$GATE" --fix "$T/plan.md" 2>"$T/err.txt")" || fail "$1: exits 0"
  [ "$out" = "$3" ] || fail "$1: got [$out], want [$3]"
  [ ! -s "$T/err.txt" ] || fail "$1: nothing on stderr"
}

expect_fix_out "fix gate command" '## Gate\nbash test/run\n\n## Fix gate\n`bash test/run --since <since>`\n' 'bash test/run --since <since>'
printf '%b' '## Gate\nbash test/run\n' >"$T/plan.md"
stdout="$(bash "$GATE" --fix "$T/plan.md" 2>"$T/err.txt")"; rc=$?
[ "$rc" = "3" ] || fail "missing Fix gate exits 3 (got $rc)"
[ -z "$stdout" ] || fail "missing Fix gate prints nothing on stdout"
expect_err_fix() {
  printf '%b' "$2" >"$T/plan.md"
  stdout="$(bash "$GATE" --fix "$T/plan.md" 2>"$T/err.txt")"; rc=$?
  [ "$rc" = "1" ] || fail "$1: exits 1 (got $rc)"
  [ -z "$stdout" ] || fail "$1: prints nothing on stdout"
  [ "$(wc -l <"$T/err.txt" | tr -d ' ')" = "1" ] || fail "$1: one stderr line"
  grep -q '^plan-gate: ' "$T/err.txt" || fail "$1: stderr starts with plan-gate:"
}
expect_err_fix "Fix gate without since" '## Fix gate\nbash test/run\n'
printf '%b' '## Fix gate\nbash test/run --since <since>\n' >"$T/plan.md"
stdout="$(bash "$GATE" --fix --script scripts/check "$T/plan.md" 2>"$T/err.txt")"; rc=$?
[ "$rc" = "1" ] || fail "Fix gate script mismatch exits 1 (got $rc)"
[ -z "$stdout" ] || fail "Fix gate script mismatch prints nothing on stdout"
[ "$(wc -l <"$T/err.txt" | tr -d ' ')" = "1" ] || fail "Fix gate script mismatch writes one stderr line"

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
bash "$GATE" --script >/dev/null 2>&1; [ "$?" = "2" ] || fail "--script with no value exits 2"
bash "$GATE" --script scripts/check >/dev/null 2>&1; [ "$?" = "2" ] || fail "--script with no plan file exits 2"

# --script CMD: the Gate line must run the gate script as the workflow doc writes it
# expect_script_out NAME SCRIPT CONTENT WANT: with --script SCRIPT the gate prints WANT and exits 0
expect_script_out() {
  printf '%b' "$3" >"$T/plan.md"
  out="$(bash "$GATE" --script "$2" "$T/plan.md" 2>"$T/err.txt")" || fail "$1: exits 0"
  [ "$out" = "$4" ] || fail "$1: got [$out], want [$4]"
  [ ! -s "$T/err.txt" ] || fail "$1: nothing on stderr"
}

# expect_script_err NAME SCRIPT CONTENT LINE: with --script SCRIPT the gate exits 1, prints
# nothing on stdout, and writes exactly the rejection message naming LINE on stderr
expect_script_err() {
  printf '%b' "$3" >"$T/plan.md"
  stdout="$(bash "$GATE" --script "$2" "$T/plan.md" 2>"$T/err.txt")" && fail "$1: exits 1"
  [ -z "$stdout" ] || fail "$1: prints nothing on stdout"
  want="plan-gate: the Gate line must run the gate script $2 as the workflow doc writes it, not its steps by hand: $4"
  [ "$(cat "$T/err.txt")" = "$want" ] || fail "$1: got [$(cat "$T/err.txt")], want [$want]"
}

# expect_allowlist_err NAME SCRIPT CONTENT VAR: with --script SCRIPT the gate exits 1,
# prints nothing on stdout, and names VAR as not in the allowed variable list
expect_allowlist_err() {
  printf '%b' "$3" >"$T/plan.md"
  stdout="$(bash "$GATE" --script "$2" "$T/plan.md" 2>"$T/err.txt")" && fail "$1: exits 1"
  [ -z "$stdout" ] || fail "$1: prints nothing on stdout"
  [ "$(wc -l <"$T/err.txt" | tr -d ' ')" = "1" ] || fail "$1: one stderr line"
  grep -q "sets $4," "$T/err.txt" || fail "$1: names $4: [$(cat "$T/err.txt")]"
  grep -q 'allowed variable list' "$T/err.txt" || fail "$1: says allowlist: [$(cat "$T/err.txt")]"
  ! grep -q 'by hand' "$T/err.txt" || fail "$1: does not say by hand: [$(cat "$T/err.txt")]"
}

expect_script_out "script with an argument" "scripts/check" '## Gate\n\nscripts/check --base abc\n' 'scripts/check --base abc'
expect_script_out "script with a leading CARGO_BUILD_JOBS" "scripts/check" '## Gate\n\nCARGO_BUILD_JOBS=3 scripts/check\n' 'CARGO_BUILD_JOBS=3 scripts/check'
expect_script_out "script with ./ prefix" "scripts/check" '## Gate\n\n./scripts/check\n' './scripts/check'
expect_script_out "script run by bash" "scripts/check" '## Gate\n\nbash scripts/check --base abc\n' 'bash scripts/check --base abc'
expect_script_out "script with several allowed assignments" "scripts/check" '## Gate\n\nRUSTC_WRAPPER=sccache SCCACHE_DIR=/tmp/x NEXTEST_TEST_THREADS=4 scripts/check\n' 'RUSTC_WRAPPER=sccache SCCACHE_DIR=/tmp/x NEXTEST_TEST_THREADS=4 scripts/check'
expect_script_out "script with a leading CARGO_TARGET_DIR" "scripts/check" '## Gate\n\nCARGO_TARGET_DIR=/tmp/x scripts/check\n' 'CARGO_TARGET_DIR=/tmp/x scripts/check'
expect_script_out "script with a leading TMPDIR" "scripts/check" '## Gate\n\nTMPDIR=/tmp/x scripts/check\n' 'TMPDIR=/tmp/x scripts/check'
expect_script_err "hand-expanded steps" "scripts/check" '## Gate\n\ncargo fmt --check && cargo nextest run\n' 'cargo fmt --check && cargo nextest run'
expect_script_err "screen-ratchet subcommand" "scripts/check" '## Gate\n\ncargo xtask screen-ratchet\n' 'cargo xtask screen-ratchet'
expect_script_err "hand-written steps keep the old message" "scripts/check" '## Gate\n\nmake check\n' 'make check'
expect_allowlist_err "unlisted leading variable" "scripts/check" '## Gate\n\nFOO=1 scripts/check\n' 'FOO'
expect_script_err "script name as a prefix of another word" "scripts/check" '## Gate\n\nscripts/checker --base abc\n' 'scripts/checker --base abc'
expect_script_err "different script" "scripts/check" '## Gate\n\nscripts/other\n' 'scripts/other'
# an operator hidden in an assignment value is rejected, so it cannot split the command
expect_script_err "operator glued to an assignment value" "scripts/check" '## Gate\n\nCARGO_BUILD_JOBS=1|| scripts/check\n' 'CARGO_BUILD_JOBS=1|| scripts/check'
expect_script_err "semicolon glued to an assignment value" "scripts/check" '## Gate\n\nCARGO_BUILD_JOBS=1;scripts/check\n' 'CARGO_BUILD_JOBS=1;scripts/check'
expect_script_err "quoted assignment value" "scripts/check" "## Gate\n\nSCCACHE_DIR='/tmp/x' scripts/check\n" "SCCACHE_DIR='/tmp/x' scripts/check"
expect_script_out "plain assignment value" "scripts/check" '## Gate\n\nSCCACHE_DIR=/tmp/x scripts/check\n' 'SCCACHE_DIR=/tmp/x scripts/check'

# without --script the hand-expanded line still passes
expect_out "no --script accepts a hand-expanded line" '## Gate\n\ncargo fmt --check && cargo nextest run\n' 'cargo fmt --check && cargo nextest run'

echo "plan-gate: all cases passed"

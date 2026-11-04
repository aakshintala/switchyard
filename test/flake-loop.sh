#!/usr/bin/env bash
# Tests for bin/flake-loop. Exits non-zero on the first failed case.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FL="$SCRIPT_DIR/../bin/flake-loop"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-flake-loop.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/outer"

# --- usage errors exit 2 ---
out="$(bash "$FL" 2>&1)"; rc=$?
[ "$rc" = 2 ] || fail "no arguments exits 2 (got $rc: $out)"
grep -q 'never a way to get green' <<<"$out" || fail "usage says diagnostic, never green: [$out]"

out="$(bash "$FL" -n 3 2>&1)"; rc=$?
[ "$rc" = 2 ] || fail "missing -- exits 2 (got $rc: $out)"

out="$(bash "$FL" -n 3 -- 2>&1)"; rc=$?
[ "$rc" = 2 ] || fail "empty command exits 2 (got $rc: $out)"

out="$(bash "$FL" -n 0 -- true 2>&1)"; rc=$?
[ "$rc" = 2 ] || fail "-n 0 exits 2 (got $rc: $out)"

out="$(bash "$FL" -n abc -- true 2>&1)"; rc=$?
[ "$rc" = 2 ] || fail "-n abc exits 2 (got $rc: $out)"

out="$(bash "$FL" -n 2>&1)"; rc=$?
[ "$rc" = 2 ] || fail "missing -n value exits 2 (got $rc: $out)"

out="$(bash "$FL" --bogus -- true 2>&1)"; rc=$?
[ "$rc" = 2 ] || fail "unknown flag exits 2 (got $rc: $out)"

# --- an all-passing command exits 0 with pass/fail counts ---
out="$(bash "$FL" -n 3 -- true 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "all-pass exits 0 (got $rc: $out)"
grep -q 'passed: 3' <<<"$out" || fail "all-pass reports 3 passed: [$out]"
grep -q 'failed: 0' <<<"$out" || fail "all-pass reports 0 failed: [$out]"
grep -q 'first failure' <<<"$out" && fail "all-pass names no failure: [$out]"

# --- the default run count is 20 ---
out="$(bash "$FL" -- true 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "default count exits 0 (got $rc: $out)"
grep -q 'runs: 20 passed: 20 failed: 0' <<<"$out" || fail "default is 20 runs: [$out]"

# --- a failing command exits 1 and every failing run keeps its output ---
cat >"$T/always-fail.sh" <<'EOF'
#!/usr/bin/env bash
echo "this run failed"
exit 1
EOF
chmod +x "$T/always-fail.sh"
out="$(TMPDIR="$T/outer" bash "$FL" -n 3 -- bash "$T/always-fail.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] || fail "all-fail exits 1 (got $rc: $out)"
grep -q 'passed: 0' <<<"$out" || fail "all-fail reports 0 passed: [$out]"
grep -q 'failed: 3' <<<"$out" || fail "all-fail reports 3 failed: [$out]"
first="$(printf '%s\n' "$out" | sed -n 's/^first failure: //p')"
[ -n "$first" ] || fail "all-fail prints the first failing run's output: [$out]"
[ -f "$first" ] || fail "first failing output is kept at $first"
grep -q 'this run failed' "$first" || fail "kept output holds the failure: [$(cat "$first")]"
dir="$(dirname "$first")"
[ "$(ls "$dir"/fail-*.log 2>/dev/null | wc -l | tr -d ' ')" = "3" ] ||
  fail "each failing run keeps its output in $dir"
[ "$(ls -A "$dir" | wc -l | tr -d ' ')" = "3" ] ||
  fail "only failing output stays in $dir: [$(ls -A "$dir")]"

# --- each run gets a fresh TMPDIR inside the loop's own temp dir ---
cat >"$T/tmpdir-check.sh" <<'EOF'
#!/usr/bin/env bash
[ -n "${TMPDIR:-}" ] || { echo "TMPDIR unset" >&2; exit 1; }
[ -d "${TMPDIR:-}" ] || { echo "TMPDIR is not a dir" >&2; exit 1; }
echo "$TMPDIR" >>"$RECORD"
[ ! -e "$TMPDIR/sentinel" ] || { echo "TMPDIR reused" >&2; exit 1; }
: >"$TMPDIR/sentinel"
EOF
chmod +x "$T/tmpdir-check.sh"
rm -rf "$T/outer" && mkdir -p "$T/outer"
out="$(RECORD="$T/tmpdirs" TMPDIR="$T/outer" bash "$FL" -n 3 -- bash "$T/tmpdir-check.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "fresh-tmpdir run exits 0 (got $rc: $out)"
[ "$(sort -u "$T/tmpdirs" | wc -l | tr -d ' ')" = "3" ] ||
  fail "three distinct TMPDIRs: [$(cat "$T/tmpdirs")]"
while IFS= read -r d; do
  case "$d" in "$T/outer"/flake-loop.*) ;; *) fail "TMPDIR $d is outside the loop's temp dir";; esac
  [ ! -e "$d" ] || fail "run TMPDIR $d is deleted after the run"
done <"$T/tmpdirs"
[ -z "$(ls -A "$T/outer")" ] || fail "all-pass loop leaves no temp dirs: [$(ls -A "$T/outer")]"

# --- a flaky command reports the split and keeps the first failure ---
cat >"$T/flaky.sh" <<'EOF'
#!/usr/bin/env bash
n="$(cat "$COUNT")"
n=$((n + 1))
printf '%s' "$n" >"$COUNT"
if [ "$n" -eq 2 ]; then
  echo "boom on run 2"
  exit 1
fi
exit 0
EOF
chmod +x "$T/flaky.sh"
printf '0' >"$T/count"
out="$(COUNT="$T/count" bash "$FL" -n 3 -- bash "$T/flaky.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] || fail "flaky exits 1 (got $rc: $out)"
grep -q 'passed: 2' <<<"$out" || fail "flaky reports 2 passed: [$out]"
grep -q 'failed: 1' <<<"$out" || fail "flaky reports 1 failed: [$out]"
first="$(printf '%s\n' "$out" | sed -n 's/^first failure: //p')"
[ -f "${first:-/none}" ] || fail "flaky keeps the first failure output: [$out]"
grep -q 'boom on run 2' "$first" || fail "kept output is the failing run's: [$(cat "$first")]"

# --- --until-fail stops after the first failure ---
cat >"$T/count-fail.sh" <<'EOF'
#!/usr/bin/env bash
n="$(cat "$COUNT")"
n=$((n + 1))
printf '%s' "$n" >"$COUNT"
echo "attempt $n"
exit 1
EOF
chmod +x "$T/count-fail.sh"
printf '0' >"$T/count-until"
out="$(COUNT="$T/count-until" bash "$FL" -n 20 --until-fail -- bash "$T/count-fail.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] || fail "--until-fail exits 1 (got $rc: $out)"
[ "$(cat "$T/count-until")" = "1" ] ||
  fail "--until-fail stops after the first failure (ran $(cat "$T/count-until"))"
grep -q 'runs: 1 passed: 0 failed: 1' <<<"$out" || fail "--until-fail counts one run: [$out]"

# --- command arguments (including --) reach the command untouched ---
cat >"$T/args.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ARGS_OUT"
EOF
chmod +x "$T/args.sh"
out="$(ARGS_OUT="$T/got-args" bash "$FL" -n 1 -- bash "$T/args.sh" -p x name -- --exact 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "args case exits 0 (got $rc: $out)"
[ "$(cat "$T/got-args")" = "$(printf -- '-p\nx\nname\n--\n--exact')" ] ||
  fail "args reached the command as: [$(cat "$T/got-args")]"

echo "flake-loop: all cases passed"

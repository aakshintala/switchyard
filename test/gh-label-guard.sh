#!/usr/bin/env bash
# Tests for bin/gh-label-guard, against a stub real gh in a mktemp -d fixture.
# No sleeps, no waits, no network, no timing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIM="$SCRIPT_DIR/../bin/gh-label-guard"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-gh-label-guard.XXXXXX")"

cleanup() {
  local st=$?
  trap - EXIT
  chmod -R u+rwx "$T" 2>/dev/null
  rm -rf "$T"
  exit "$st"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

REFUSED='gh-label-guard: refused: a lane may not add or remove the needs-owner or needs-triage label; send the question to your orchestrator (flywheel) instead'
NO_GH='gh-label-guard: no gh on PATH outside gh-label-guard'

mkdir -p "$T/home" "$T/shims" "$T/real" "$T/py"
PY="$(command -v python3)" || fail "python3 not on PATH"
ln -s "$PY" "$T/py/python3"
ln -s "$SHIM" "$T/shims/gh"

# Stub real gh. Bash builtins only. It appends one record per call to $CALLS
# (argc, then each argv element on its own <...> line), copies stdin to
# $STDIN_FILE when STUB_READ_STDIN=1, prints stub-out on stdout and stub-err
# on stderr, and exits ${STUB_EXIT:-0}.
cat >"$T/real/gh" <<'STUB'
#!/usr/bin/env bash
{
  printf 'argc=%s\n' "$#"
  for a in "$@"; do printf '<%s>\n' "$a"; done
} >>"$CALLS"
if [ "${STUB_READ_STDIN:-0}" = 1 ]; then
  cat >"$STDIN_FILE"
fi
printf 'stub-out\n'
printf 'stub-err\n' >&2
exit "${STUB_EXIT:-0}"
STUB
chmod 755 "$T/real/gh"

BASEPATH="$T/shims:$T/real:$T/py:/usr/bin:/bin"

# lane ARGS...: run the installed shim in a clean environment and capture
# RC, OUT and ERR. LANE_PATH overrides PATH; STUB_EXIT and STUB_READ_STDIN
# pass through to the stub. $T/calls is reset first, so its absence after a
# run proves the stub never ran.
lane() {
  rm -f "$T/calls" "$T/stdin"
  local out rc
  out="$(env -i CALLS="$T/calls" STDIN_FILE="$T/stdin" \
    PATH="${LANE_PATH:-$BASEPATH}" HOME="$T/home" \
    STUB_EXIT="${STUB_EXIT:-0}" STUB_READ_STDIN="${STUB_READ_STDIN:-0}" \
    "$T/shims/gh" "$@" 2>"$T/err")"
  rc=$?
  OUT="$out"
  ERR="$(cat "$T/err")"
  RC="$rc"
}

# expect_refused ARGS...: the shim refused without calling the stub.
expect_refused() {
  [ "$RC" = 1 ] || fail "refused [$*]: exit $RC, want 1"
  [ -z "$OUT" ] || fail "refused [$*]: stdout [$OUT], want empty"
  [ "$ERR" = "$REFUSED" ] || fail "refused [$*]: stderr [$ERR]"
  [ ! -e "$T/calls" ] || fail "refused [$*]: the stub ran"
}

# expect_passed ARGS...: the stub ran once with exactly these argv, and its
# output and status came back unchanged.
expect_passed() {
  local want="argc=$#" a
  for a in "$@"; do want+=$'\n'"<$a>"; done
  [ "$RC" = "${STUB_EXIT:-0}" ] || fail "passed [$*]: exit $RC, want ${STUB_EXIT:-0}"
  [ "$OUT" = "stub-out" ] || fail "passed [$*]: stdout [$OUT], want [stub-out]"
  [ "$ERR" = "stub-err" ] || fail "passed [$*]: stderr [$ERR], want [stub-err]"
  [ -f "$T/calls" ] || fail "passed [$*]: the stub never ran"
  [ "$(cat "$T/calls")" = "$want" ] ||
    fail "passed [$*]: stub saw [$(cat "$T/calls")], want [$want]"
}

# Task 1: pass-through and lookup.

lane issue list
expect_passed issue list

lane issue comment 5 --body 'a b' ''
expect_passed issue comment 5 --body 'a b' ''

lane
expect_passed

lane --version
expect_passed --version

STUB_EXIT=3
lane issue list
expect_passed issue list
unset STUB_EXIT

STUB_READ_STDIN=1
lane issue comment 5 --body hi <<<"x"
expect_passed issue comment 5 --body hi
unset STUB_READ_STDIN
[ "$(cat "$T/stdin")" = "x" ] || fail "stdin: stub read [$(cat "$T/stdin")], want [x]"

# With the shim directory first and no real gh anywhere, the lookup fails
# with 127. A preinstalled /usr/bin/gh on the host must not answer.
LANE_PATH="$T/shims:$T/py"
lane issue list
[ "$RC" = 127 ] || fail "no real gh: exit $RC, want 127"
[ "$ERR" = "$NO_GH" ] || fail "no real gh: stderr [$ERR]"
unset LANE_PATH

# A byte copy of the shim (not a symlink) in a second PATH directory is
# skipped by the marker, and the stub runs.
mkdir -p "$T/copies"
cp "$SHIM" "$T/copies/gh" && chmod 755 "$T/copies/gh" || fail "cannot stage copy"
LANE_PATH="$T/copies:$T/shims:$T/real:$T/py:/usr/bin:/bin"
lane issue list
expect_passed issue list
unset LANE_PATH

# A non-executable gh ahead of the stub is skipped.
mkdir -p "$T/nonexec"
: >"$T/nonexec/gh"
chmod 644 "$T/nonexec/gh"
LANE_PATH="$T/shims:$T/nonexec:$T/real:$T/py:/usr/bin:/bin"
lane issue list
expect_passed issue list
unset LANE_PATH

# An empty entry names the working directory, and a relative entry resolves
# against it (one case): the planted gh scripts run ahead of the stub.
mkdir -p "$T/cwd/tools"
printf '#!/bin/sh\n: >"%s/cwd-ran"\n' "$T" >"$T/cwd/gh"
printf '#!/bin/sh\n: >"%s/tools-ran"\n' "$T" >"$T/cwd/tools/gh"
chmod 755 "$T/cwd/gh" "$T/cwd/tools/gh"
rm -f "$T/calls" "$T/cwd-ran"
( cd "$T/cwd" &&
  env -i PATH="$T/shims::$T/real:$T/py:/usr/bin:/bin" HOME="$T/home" \
  CALLS="$T/calls" STUB_EXIT=0 STUB_READ_STDIN=0 \
  "$T/shims/gh" issue list >"$T/cwd-out" 2>"$T/cwd-err" )
rc=$?
[ "$rc" = 0 ] || fail "empty PATH entry: exit $rc, want 0 from cwd/gh"
[ -e "$T/cwd-ran" ] || fail "empty PATH entry did not name the working directory"
[ ! -e "$T/calls" ] || fail "the stub ran ahead of cwd/gh"
rm -f "$T/calls" "$T/tools-ran"
( cd "$T/cwd" &&
  env -i PATH="$T/shims:tools:$T/real:$T/py:/usr/bin:/bin" HOME="$T/home" \
  CALLS="$T/calls" STUB_EXIT=0 STUB_READ_STDIN=0 \
  "$T/shims/gh" issue list >"$T/tools-out" 2>"$T/tools-err" )
rc=$?
[ "$rc" = 0 ] || fail "relative PATH entry: exit $rc, want 0 from tools/gh"
[ -e "$T/tools-ran" ] || fail "tools/gh behind a relative PATH entry did not run"
[ ! -e "$T/calls" ] || fail "the stub ran ahead of tools/gh"

# An unset PATH searches nothing, not even the working directory.
env -u PATH HOME="$T/home" "$T/py/python3" "$SHIM" issue list \
  >"$T/unset-out" 2>"$T/unset-err"
rc=$?
[ "$rc" = 127 ] || fail "PATH unset: exit $rc, want 127"
grep -q 'gh-label-guard:' "$T/unset-err" ||
  fail "PATH unset: no gh-label-guard: line on stderr"

echo "gh-label-guard: all cases passed"

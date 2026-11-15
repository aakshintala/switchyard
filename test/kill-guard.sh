#!/usr/bin/env bash
# Tests for bin/kill-guard: every invocation is refused without executing a real command.
# No sleeps, no waits, no network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIM="$SCRIPT_DIR/../bin/kill-guard"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-kill-guard.XXXXXX")"

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

mkdir -p "$T/shims" "$T/stubs"
ln -s "$SHIM" "$T/shims/pkill"
ln -s "$SHIM" "$T/shims/killall"

# These are the only pkill and killall found on PATH. An accidental exec
# writes a marker so the test can prove the command was never reached.
for command in pkill killall; do
  cat >"$T/stubs/$command" <<'STUB'
#!/bin/sh
printf '%s\n' "$0" >>"$KILL_GUARD_MARKER"
exit 0
STUB
  chmod 755 "$T/stubs/$command"
done

PATH="$T/stubs:/usr/bin:/bin"
export PATH
KILL_GUARD_MARKER="$T/executed"
export KILL_GUARD_MARKER

expect_refused() {
  local invoked_name="$1"
  local executable="$2"
  shift 2
  local rc expected
  "$executable" "$@" >"$T/out" 2>"$T/err"
  rc=$?
  [ "$rc" = 1 ] || fail "$invoked_name [$*]: exit $rc, want 1"
  [ ! -s "$T/out" ] || fail "$invoked_name [$*]: stdout was not empty"
  expected="kill-guard: refused: $invoked_name: a lane may not signal processes by name, because other lanes' gates share the host; signal only pids you started yourself with kill <pid> (from \$! or a pid file)"
  printf '%s\n' "$expected" >"$T/expected"
  cmp -s "$T/expected" "$T/err" ||
    fail "$invoked_name [$*]: stderr [$(cat "$T/err")], want [$expected]"
  [ ! -e "$KILL_GUARD_MARKER" ] ||
    fail "$invoked_name [$*]: a PATH command was executed"
}

expect_refused pkill "$T/shims/pkill"
expect_refused pkill "$T/shims/pkill" -f nextest
expect_refused killall "$T/shims/killall"
expect_refused killall "$T/shims/killall" -9 cargo
expect_refused kill-guard "$SHIM"
expect_refused kill-guard "$SHIM" -f nextest

[ ! -e "$KILL_GUARD_MARKER" ] || fail "a PATH command was executed"
echo "kill-guard: all cases passed"

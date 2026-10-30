#!/usr/bin/env bash
# Tests for bin/git-hook-guard, against a stub real git in a mktemp -d fixture.
# No sleeps, no waits, no network, no timing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIM="$SCRIPT_DIR/../bin/git-hook-guard"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-git-hook-guard.XXXXXX")"

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

REFUSED='git-hook-guard: refused: a lane may not skip or redirect git hooks; a hook that refuses is not yours to get round, so stop with STATUS: BLOCKED and report the refusal'
NO_GIT='git-hook-guard: no git on PATH outside git-hook-guard'

mkdir -p "$T/home" "$T/shims" "$T/real" "$T/py"
PY="$(command -v python3)" || fail "python3 not on PATH"
ln -s "$PY" "$T/py/python3"
ln -s "$SHIM" "$T/shims/git"

# Stub real git. Bash builtins only. It appends one record per call to $CALLS
# (argc, then each argv element on its own <...> line), copies stdin to
# $STDIN_FILE when STUB_READ_STDIN=1, prints stub-out on stdout and stub-err
# on stderr, and exits ${STUB_EXIT:-0}.
cat >"$T/real/git" <<'STUB'
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
chmod 755 "$T/real/git"

BASEPATH="$T/shims:$T/real:$T/py:/usr/bin:/bin"

# lane ARGS...: run the installed shim in a clean environment and capture
# RC, OUT and ERR. LANE_PATH overrides PATH; LANE_ENV holds extra NAME=VALUE
# words placed before the command; STUB_EXIT and STUB_READ_STDIN pass through
# to the stub. $T/calls is reset first, so its absence after a run proves the
# stub never ran.
lane() {
  rm -f "$T/calls" "$T/stdin"
  local out rc
  out="$(env -i CALLS="$T/calls" STDIN_FILE="$T/stdin" \
    PATH="${LANE_PATH:-$BASEPATH}" HOME="$T/home" \
    STUB_EXIT="${STUB_EXIT:-0}" STUB_READ_STDIN="${STUB_READ_STDIN:-0}" \
    ${LANE_ENV[@]+"${LANE_ENV[@]}"} \
    "$T/shims/git" "$@" 2>"$T/err")"
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

# refused ARGS... / passed ARGS...: one table line per covered form.
refused() {
  lane "$@"
  expect_refused "$@"
}
passed() {
  lane "$@"
  expect_passed "$@"
}

# Task 1: pass-through and lookup.

lane
expect_passed

lane --version
expect_passed --version

STUB_EXIT=3
lane status
expect_passed status
unset STUB_EXIT

STUB_READ_STDIN=1
lane commit -m hi <<<"x"
expect_passed commit -m hi
unset STUB_READ_STDIN
[ "$(cat "$T/stdin")" = "x" ] || fail "stdin: stub read [$(cat "$T/stdin")], want [x]"

# With the shim directory first and no real git anywhere, the lookup fails
# with 127. A preinstalled /usr/bin/git on the host must not answer.
LANE_PATH="$T/shims:$T/py"
lane status
[ "$RC" = 127 ] || fail "no real git: exit $RC, want 127"
[ "$ERR" = "$NO_GIT" ] || fail "no real git: stderr [$ERR]"
unset LANE_PATH

# A byte copy of the shim (not a symlink) in a second PATH directory is
# skipped by the marker, and the stub runs.
mkdir -p "$T/copies"
cp "$SHIM" "$T/copies/git" && chmod 755 "$T/copies/git" || fail "cannot stage copy"
LANE_PATH="$T/copies:$T/shims:$T/real:$T/py:/usr/bin:/bin"
lane status
expect_passed status
unset LANE_PATH

# A non-executable git ahead of the stub is skipped.
mkdir -p "$T/nonexec"
: >"$T/nonexec/git"
chmod 644 "$T/nonexec/git"
LANE_PATH="$T/shims:$T/nonexec:$T/real:$T/py:/usr/bin:/bin"
lane status
expect_passed status
unset LANE_PATH

# An empty entry names the working directory, and a relative entry resolves
# against it (one case): the planted git scripts run ahead of the stub. The
# host /usr/bin and /bin stay off PATH here so a preinstalled git cannot
# answer first.
mkdir -p "$T/cwd/tools"
printf '#!/bin/sh\n: >"%s/cwd-ran"\n' "$T" >"$T/cwd/git"
printf '#!/bin/sh\n: >"%s/tools-ran"\n' "$T" >"$T/cwd/tools/git"
chmod 755 "$T/cwd/git" "$T/cwd/tools/git"
rm -f "$T/calls" "$T/cwd-ran"
( cd "$T/cwd" &&
  env -i PATH="$T/shims::$T/real:$T/py" HOME="$T/home" \
  CALLS="$T/calls" STUB_EXIT=0 STUB_READ_STDIN=0 \
  "$T/shims/git" status >"$T/cwd-out" 2>"$T/cwd-err" )
rc=$?
[ "$rc" = 0 ] || fail "empty PATH entry: exit $rc, want 0 from cwd/git"
[ -e "$T/cwd-ran" ] || fail "empty PATH entry did not name the working directory"
[ ! -e "$T/calls" ] || fail "the stub ran ahead of cwd/git"
rm -f "$T/calls" "$T/tools-ran"
( cd "$T/cwd" &&
  env -i PATH="$T/shims:tools:$T/real:$T/py" HOME="$T/home" \
  CALLS="$T/calls" STUB_EXIT=0 STUB_READ_STDIN=0 \
  "$T/shims/git" status >"$T/tools-out" 2>"$T/tools-err" )
rc=$?
[ "$rc" = 0 ] || fail "relative PATH entry: exit $rc, want 0 from tools/git"
[ -e "$T/tools-ran" ] || fail "tools/git behind a relative PATH entry did not run"
[ ! -e "$T/calls" ] || fail "the stub ran ahead of tools/git"

# An unset PATH searches nothing, not even the working directory.
env -u PATH HOME="$T/home" "$T/py/python3" "$SHIM" status \
  >"$T/unset-out" 2>"$T/unset-err"
rc=$?
[ "$rc" = 127 ] || fail "PATH unset: exit $rc, want 127"
grep -q 'git-hook-guard:' "$T/unset-err" ||
  fail "PATH unset: no git-hook-guard: line on stderr"

# Task 2: the guard.

refused commit --no-verify
refused push --no-verify
refused commit -m x --no-verify
refused commit --no-verif
refused commit --no-veri
refused commit -n
refused commit -an
refused commit -nm x
refused commit -m x -n
refused push origin --no-verify
refused -C dir commit --no-verify
refused -c user.name=x commit --no-verify
refused -c core.hooksPath=/x commit
refused -c core.hookspath=/x status
refused -c CORE.HOOKSPATH=/x status
refused -c core.hooksPath status
refused -c core.hooksPath= status
refused -ccore.hooksPath=/x status
refused -c user.name=x -c core.hooksPath=/x commit
refused config core.hooksPath /x
refused config --local core.hooksPath /x
refused config --worktree core.hooksPath /x
refused config --global core.hooksPath /x
refused config --global CORE.hookspath /x
refused config --add core.hooksPath /x
refused config --replace-all core.hooksPath /x
refused config --unset core.hooksPath
refused config --unset-all core.hooksPath
refused config set core.hooksPath /x
refused config unset core.hooksPath
refused config -f f core.hooksPath /x
refused config --typ bool core.hooksPath true
refused config --fil f core.hooksPath /x
refused config -t bool core.hooksPath true
refused config -- core.hooksPath /x
refused -C d config core.hooksPath /x

LANE_ENV=(GIT_CONFIG_COUNT=+1 GIT_CONFIG_KEY_0=core.hooksPath)
refused status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=" 1" GIT_CONFIG_KEY_0=core.hooksPath)
refused status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=01 GIT_CONFIG_KEY_0=core.hooksPath)
refused status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=-1 GIT_CONFIG_KEY_0=core.hooksPath)
refused status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/x)
refused status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=Core.HooksPath GIT_CONFIG_VALUE_0=/x)
refused status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_1=core.hooksPath)
refused status
unset LANE_ENV
LANE_ENV=(HUSKY=0)
refused commit -m x
unset LANE_ENV
LANE_ENV=(HUSKY=0)
refused status
unset LANE_ENV

passed push -n
passed push --dry-run
passed commit -m "--no-verify"
passed commit -m "-n"
passed commit --message=--no-verify
passed commit -m--no-verify
passed commit -F -n
passed commit -m x -- -n
passed commit -- --no-verify
passed commit --verify
passed commit --no-verbose
passed commit --no-ver
passed push -o --no-verify origin
passed push --push-option --no-verify
passed push -n origin
passed -c user.name=x commit
passed -c user.name=x commit -m hi
passed -C core.hooksPath status
passed -c core.hooksPathx=1 status
passed -c xcore.hooksPath=1 status
passed status
passed log --oneline
passed -c
passed -C
passed config -t bool user.name x
passed config user.name
passed config core.hooksPath
passed config --get core.hooksPath
passed config --get-all core.hooksPath
passed config --list
passed config get core.hooksPath
passed config --global user.name x
passed config user.name core.hooksPath
passed config --file core.hooksPath user.name x
passed config --typ bool user.name x
passed config --default d --get user.name
passed --config-env=core.hooksPath=V status
LANE_ENV=(HUSKY=1)
passed commit -m x
unset LANE_ENV
LANE_ENV=(HUSKY=)
passed status
unset LANE_ENV
LANE_ENV=(HUSKY=00)
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name)
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_1=core.hooksPath)
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=0 GIT_CONFIG_KEY_0=core.hooksPath)
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=abc GIT_CONFIG_KEY_0=core.hooksPath)
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=1k GIT_CONFIG_KEY_0=core.hooksPath)
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=0x1 GIT_CONFIG_KEY_0=core.hooksPath)
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=-1 GIT_CONFIG_KEY_0=user.name)
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=99999999999999999999 GIT_CONFIG_KEY_0=user.name)
passed status
unset LANE_ENV

# A refusal does not need a real git: with no real git on PATH, the guard
# still refuses with 1 instead of failing the lookup with 127.
LANE_PATH="$T/shims:$T/py"
refused commit --no-verify
unset LANE_PATH

echo "git-hook-guard: all cases passed"

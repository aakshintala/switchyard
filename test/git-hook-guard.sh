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
# The shim's temp root is $T/tmproot, and no refusal case runs with its cwd or
# -C target inside it. $T/x/tmp and $T/x/tmpfoo test the sibling-prefix case;
# $T/home/work/sy-wt/lane stands in for a lane worktree.
mkdir -p "$T/tmproot/work" "$T/x/tmp" "$T/x/tmpfoo" "$T/home/work/sy-wt/lane"
PY="$(command -v python3)" || fail "python3 not on PATH"
ln -s "$PY" "$T/py/python3"
ln -s "$SHIM" "$T/shims/git"

# Stub real git. Bash builtins only. It appends one record per call to $CALLS
# (argc, then each argv element on its own <...> line), copies stdin to
# $STDIN_FILE when STUB_READ_STDIN=1, prints stub-out on stdout and stub-err
# on stderr, and exits ${STUB_EXIT:-0}. Guard lookups (`config --get
# alias.<name>` with any leading globals, and the builtin list) are answered
# here instead: recorded in $LOOKUPS, never in $CALLS, so expect_passed
# stays exact and expect_refused still proves no exec ran. STUB_ALIAS_<name>
# defines the expansion the lookup prints; an unset one exits 1 like git.
# A leading `-c alias.<name>=<value>` overrides STUB_ALIAS_<name> like the
# real git, so an alias expansion that sets config is visible to later
# lookups.
cat >"$T/real/git" <<'STUB'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = "--list-cmds=builtins,nohelpers" ]; then
  printf '<list-cmds>\n' >>"${LOOKUPS:-/dev/null}"
  printf '%s\n' status commit push merge rebase am cherry-pick revert pull \
    config stash hook log rev-parse ls-remote
  exit 0
fi
restored=("$@")
while [ "$#" -gt 3 ]; do shift; done
if [ "$#" -eq 3 ] && [ "$1" = config ] && [ "$2" = --get ]; then
  case "$3" in
  alias.*)
    printf '<lookup %s>\n' "$3" >>"${LOOKUPS:-/dev/null}"
    name="${3#alias.}"
    override_set=0
    override=""
    nlead=$((${#restored[@]} - 3))
    i=0
    while [ "$i" -lt "$nlead" ]; do
      a="${restored[$i]}"
      kv=""
      if [ "$a" = "-c" ]; then
        i=$((i + 1))
        if [ "$i" -lt "$nlead" ]; then
          kv="${restored[$i]}"
        fi
      elif [ "${a#-c}" != "$a" ]; then
        kv="${a#-c}"
      fi
      if [ -n "$kv" ]; then
        case "$kv" in
        *=*)
          k="${kv%%=*}"
          v="${kv#*=}"
          if [ "$k" = "alias.$name" ]; then
            override="$v"
            override_set=1
          fi
          ;;
        esac
      fi
      i=$((i + 1))
    done
    if [ "$override_set" = 1 ]; then
      printf '%s\n' "$override"
      exit 0
    fi
    var="STUB_ALIAS_$name"
    if [ "${!var+x}" = x ]; then
      printf '%s\n' "${!var}"
      exit 0
    fi
    exit 1
    ;;
  esac
fi
set -- "${restored[@]}"
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
# words placed after the defaults (so it can override TMPDIR); LANE_DIR is the
# cwd (default $T/home); STUB_EXIT and STUB_READ_STDIN pass through to the
# stub. $T/calls is reset first, so its absence after a run proves the stub
# never ran.
lane() {
  rm -f "$T/calls" "$T/stdin" "$T/lookups"
  local out rc
  out="$(cd "${LANE_DIR:-$T/home}" && env -i CALLS="$T/calls" STDIN_FILE="$T/stdin" \
    LOOKUPS="$T/lookups" \
    PATH="${LANE_PATH:-$BASEPATH}" HOME="$T/home" TMPDIR="$T/tmproot" \
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
refused merge --no-verify
refused merge --no-verif
refused rebase --no-verify
refused rebase --no-veri
refused am --no-verify
refused am -n
refused hook run
refused hook run pre-commit
refused -C dir commit --no-verify
refused -c user.name=x commit --no-verify
refused -c core.hooksPath=/x commit
passed -c core.hookspath=/x status
passed -c CORE.HOOKSPATH=/x status
passed -c core.hooksPath status
passed -c core.hooksPath= status
passed -ccore.hooksPath=/x status
refused -c core.hooksPath=/x push
refused -c core.hooksPath=/x merge
refused -c core.hooksPath=/dev/null pull
refused --config-env=core.hooksPath=FOO commit
refused --config-env core.hooksPath=FOO commit
refused --config-env=core.hooksPath=FOO push
refused --config-env=core.hooksPath=FOO pull
refused -c user.name=x -c core.hooksPath=/x commit
refused config core.hooksPath /x
refused config --local core.hooksPath /x
refused config --worktree core.hooksPath /x
refused config --global core.hooksPath /x
refused config --global CORE.hookspath /x
refused config --add core.hooksPath /x
refused config --get --add core.hooksPath /x
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
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=" 1" GIT_CONFIG_KEY_0=core.hooksPath)
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=01 GIT_CONFIG_KEY_0=core.hooksPath)
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=-1 GIT_CONFIG_KEY_0=core.hooksPath)
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/x)
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=Core.HooksPath GIT_CONFIG_VALUE_0=/x)
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_1=core.hooksPath)
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null)
passed rev-parse HEAD
refused commit -m x
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.file:///x/.insteadOf GIT_CONFIG_VALUE_0=https://github.com/)
passed commit -m x
unset LANE_ENV
LANE_ENV=(HUSKY=0)
refused commit -m x
unset LANE_ENV
LANE_ENV=(HUSKY=0)
refused status
unset LANE_ENV

passed push -n
passed push --dry-run
passed merge --no-ff
passed merge -n
passed merge -m --no-verify
passed merge --message --no-verify
passed merge --no-ver
passed rebase origin/main
passed rebase -n
passed rebase -x --no-verify
passed am --signoff
passed am -p --no-verify
passed hook
passed --config-env=user.name=FOO commit -m x
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
passed config --get core.hooksPath /x
passed config --get-all core.hooksPath /x
passed config --get-regexp core.hooksPath /x
passed config --get-urlmatch core.hooksPath https://example.com
passed config --get-color core.hooksPath red
passed config --get-colorbool core.hooksPath true
passed config -l core.hooksPath /x
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
LANE_ENV=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath)
refused pull
unset LANE_ENV

LANE_ENV=(GIT_CONFIG_PARAMETERS="'core.hooksPath=/x'")
refused commit -m x
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_PARAMETERS="'core.hooksPath=/x'")
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_PARAMETERS="'user.name=bob' 'core.hooksPath=/x'")
refused push
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_PARAMETERS="'CORE.HOOKSPATH=/x'")
refused commit -m x
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_PARAMETERS="'core.hooksPath'")
refused commit -m x
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_PARAMETERS="'user.name=bob'")
passed commit -m x
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_PARAMETERS="bogus")
passed commit -m x
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_PARAMETERS="'core.hooksPath'='/dev/null'")
refused commit -m x
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_PARAMETERS="'core.hooksPath'='/dev/null'")
passed status
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_PARAMETERS="'user.name'='bob' 'core.hooksPath'='/x'")
refused push
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_PARAMETERS="'core.hooksPath'=")
refused commit -m x
unset LANE_ENV
LANE_ENV=(GIT_CONFIG_PARAMETERS="'core.hooksPath'='/x'extra")
refused commit -m x
unset LANE_ENV

LANE_ENV=(SKIP=flake8)
refused commit -m x
unset LANE_ENV
LANE_ENV=(SKIP=flake8)
refused pull
unset LANE_ENV
LANE_ENV=(SKIP=flake8)
passed status
unset LANE_ENV
LANE_ENV=(SKIP=flake8)
passed
unset LANE_ENV
LANE_ENV=(SKIP=)
passed commit -m x
unset LANE_ENV

# Aliases: the guard asks the real git for alias.<name> and checks the
# expansion as if typed. A refused expansion never reaches the stub as an
# exec (no $T/calls record); the lookups that resolved it are in $T/lookups.
LANE_ENV=(STUB_ALIAS_ci='commit --no-verify')
refused ci -m x
grep -q '<lookup alias.ci>' "$T/lookups" || fail "alias ci: no lookup ran"
unset LANE_ENV
LANE_ENV=(STUB_ALIAS_cm='commit')
refused cm --no-verify
grep -q '<lookup alias.cm>' "$T/lookups" || fail "alias cm: no lookup ran"
unset LANE_ENV
LANE_ENV=(STUB_ALIAS_hr='hook run')
refused hr
unset LANE_ENV
LANE_ENV=(STUB_ALIAS_aa='bb -m x' STUB_ALIAS_bb='commit --no-verify')
refused aa
unset LANE_ENV
LANE_ENV=(STUB_ALIAS_ci='commit')
refused -c core.hooksPath=/x ci
unset LANE_ENV
LANE_ENV=(STUB_ALIAS_probe='-c core.hooksPath=/dev/null commit --no-verify')
refused probe
grep -q '<lookup alias.probe>' "$T/lookups" || fail "alias probe: no lookup ran"
unset LANE_ENV
LANE_ENV=(STUB_ALIAS_outer='-c alias.inner="commit --no-verify" inner')
refused outer --dry-run
grep -q '<lookup alias.outer>' "$T/lookups" || fail "alias outer: no lookup ran"
grep -q '<lookup alias.inner>' "$T/lookups" || fail "alias inner: no lookup ran"
unset LANE_ENV
LANE_ENV=(STUB_ALIAS_lg='log --oneline')
passed lg
grep -q '<lookup alias.lg>' "$T/lookups" || fail "alias lg: no lookup ran"
unset LANE_ENV
LANE_ENV=(STUB_ALIAS_status='commit --no-verify')
passed status
unset LANE_ENV
LANE_ENV=(STUB_ALIAS_sh='!git commit --no-verify')
passed sh
unset LANE_ENV
LANE_ENV=(STUB_ALIAS_qm='commit -m "a b"')
passed qm
unset LANE_ENV

# No subcommand: a core.hooksPath -c option or environment entry runs no hook.
passed -c core.hooksPath=/dev/null
LANE_ENV=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath)
passed
unset LANE_ENV

# Fiber's tests spawn the binary with a cleared environment: only PATH, HOME
# and TMPDIR, no NEXTEST_RUN_ID, from a cwd outside the temp root. TMPDIR is
# pinned to $T/tmproot so the cwd sits outside it on every host, including
# CI's /tmp fixture. lane_cleared runs the shim that way and sets RC, OUT and ERR.
lane_cleared() {
  rm -f "$T/calls" "$T/stdin"
  local out rc
  out="$(cd "$T/home/work/sy-wt/lane" && env -i CALLS="$T/calls" \
    STDIN_FILE="$T/stdin" PATH="$BASEPATH" HOME="$T/home" TMPDIR="$T/tmproot" \
    "$T/shims/git" "$@" 2>"$T/err")"
  rc=$?
  OUT="$out"
  ERR="$(cat "$T/err")"
  RC="$rc"
}
FIBER_GLOBALS=(-c core.fsmonitor=false -c core.hooksPath=/dev/null)
lane_cleared "${FIBER_GLOBALS[@]}" ls-remote --tags --refs https://example.invalid/r
expect_passed "${FIBER_GLOBALS[@]}" ls-remote --tags --refs https://example.invalid/r
lane_cleared "${FIBER_GLOBALS[@]}" status
expect_passed "${FIBER_GLOBALS[@]}" status
lane_cleared "${FIBER_GLOBALS[@]}" commit -m x
expect_refused "${FIBER_GLOBALS[@]}" commit -m x
lane_cleared "${FIBER_GLOBALS[@]}" push
expect_refused "${FIBER_GLOBALS[@]}" push
lane_cleared "${FIBER_GLOBALS[@]}" merge x
expect_refused "${FIBER_GLOBALS[@]}" merge x

# A refusal does not need a real git: with no real git on PATH, the guard
# still refuses with 1 instead of failing the lookup with 127.
LANE_PATH="$T/shims:$T/py"
refused commit --no-verify
unset LANE_PATH

# Task 3: test-run pass-through.

LANE_ENV=(NEXTEST_RUN_ID=abc)
passed commit --no-verify
unset LANE_ENV
LANE_ENV=(NEXTEST_RUN_ID=)
refused commit --no-verify
unset LANE_ENV

LANE_DIR="$T/tmproot/work"
LANE_ENV=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath)
passed -c core.hooksPath=/dev/null commit
unset LANE_ENV
passed -c core.hooksPath=/dev/null commit
unset LANE_DIR

passed -C "$T/tmproot/work" push --no-verify
refused -C "$T/home" push --no-verify
LANE_DIR="$T/tmproot/work"
refused -C "$T/home" push --no-verify
unset LANE_DIR

LANE_ENV=(TMPDIR="$T/x/tmp")
LANE_DIR="$T/x/tmpfoo"
refused push --no-verify
unset LANE_DIR
unset LANE_ENV

LANE_DIR="$T/home/work/sy-wt/lane"
refused push --no-verify
LANE_ENV=(HUSKY=0)
refused status
unset LANE_ENV
unset LANE_DIR

# Task 4: bare stash forms pop whatever is on top of the shared stack,
# which can be another lane's work.

STASH_REFUSED='git-hook-guard: refused: use git stash push -u -m <unique-tag>, then git stash apply <sha>, then drop the entry by tag'

expect_stash_refused() {
  [ "$RC" = 1 ] || fail "stash-refused [$*]: exit $RC, want 1"
  [ -z "$OUT" ] || fail "stash-refused [$*]: stdout [$OUT], want empty"
  [ "$ERR" = "$STASH_REFUSED" ] || fail "stash-refused [$*]: stderr [$ERR]"
  [ ! -e "$T/calls" ] || fail "stash-refused [$*]: the stub ran"
}

srefused() {
  lane "$@"
  expect_stash_refused "$@"
}

srefused stash
srefused stash push
srefused stash push -u
srefused stash push -m
srefused stash pop
srefused stash pop 'stash@{0}'
srefused stash push -- -m x
srefused stash push --pathspec-from-file -m -q

passed stash list
passed stash apply abc123
passed stash push -m tag
passed stash push -u -m tag

# A stash refusal does not need a real git either.
LANE_PATH="$T/shims:$T/py"
srefused stash pop
unset LANE_PATH

echo "git-hook-guard: all cases passed"

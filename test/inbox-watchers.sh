#!/usr/bin/env bash
# Tests bin/inbox-watchers against a fresh mktemp -d fixture. The process
# listing comes from INBOX_WATCHERS_PS (a fixed file), and --host runs through
# a stub ssh that runs its command with a local `sh -c`. Never a live process,
# never a real inbox.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WS="$SCRIPT_DIR/../bin/inbox-watchers"

T="$(mktemp -d "${TMPDIR:-/tmp}/test-inbox-watchers.XXXXXX")"
trap 'rm -rf "$T"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# ps_lines: replace the fixture process listing with the given lines.
ps_lines() {
  printf '%s\n' "$@" >"$T/ps.txt"
}

# run_ws ARGS...: run the script against the fixture listing. Sets out, err
# and rc. Callers that need HOME or PATH set them on the call.
run_ws() {
  out="$(INBOX_WATCHERS_PS="cat $T/ps.txt" bash "$WS" "$@" 2>"$T/err")"
  rc=$?
  err="$(cat "$T/err")"
}

mkdir -p "$T/w" "$T/t" "$T/t2" "$T/u/read" "$T/d" "$T/d2" "$T/d/sub" \
  "$T/home/other" "$T/home/x" "$T/m1" "$T/m2" "$T/m3" "$T/sp ace"
printf 'x\n' >"$T/u/a.md"
printf 'x\n' >"$T/u/b.md"
printf 'x\n' >"$T/u/read/c.md"
printf 'x\n' >"$T/u/.dot.md"
printf 'x\n' >"$T/home/other/one.md"
printf 'x\n' >"$T/m1/one.md"
printf 'x\n' >"$T/m3/a.md"
printf 'x\n' >"$T/m3/b.md"
printf 'x\n' >"$T/m3/c.md"

# 1. A watched dir prints nothing and exits 0.
ps_lines "bash /x/bin/inbox-wait $T/w"
run_ws "$T/w"
[ "$rc" -eq 0 ] || fail "watched dir exits 0 (got $rc)"
[ -z "$out" ] || fail "watched dir prints nothing (got [$out])"

# 2. An unwatched dir counts only regular *.md files directly in it.
ps_lines "some other process $T/w"
run_ws "$T/u"
[ "$rc" -eq 0 ] || fail "unwatched dir exits 0 (got $rc)"
[ "$out" = "NO-WATCHER $T/u unread=2" ] || fail "unwatched dir counts 2 (got [$out])"

# 3. Trailing slash and the bash-invoked path both count as watched.
ps_lines "inbox-wait $T/t/" "bash /x/bin/inbox-wait $T/t2"
run_ws "$T/t" "$T/t2"
[ "$rc" -eq 0 ] || fail "trailing-slash and bash forms exit 0 (got $rc)"
[ -z "$out" ] || fail "trailing-slash and bash forms count as watched (got [$out])"

# 4. A watcher of /d2 or /d/sub does not watch /d, and neither does a
# look-alike script name.
ps_lines "inbox-wait $T/d2" "inbox-wait $T/d/sub" "/x/bin/notinbox-wait $T/d"
run_ws "$T/d"
[ "$out" = "NO-WATCHER $T/d unread=0" ] || fail "/d2 and /d/sub do not watch /d (got [$out])"

# 5. A leading ~/ expands to $HOME/ on both sides of the match.
export HOME="$T/home"
ps_lines "inbox-wait $T/home/x" "inbox-wait ~/x/"
# shellcheck disable=SC2088  # literal ~/ dirs, expanded by the script
run_ws "~/x" "~/other"
[ "$rc" -eq 0 ] || fail "tilde case exits 0 (got $rc)"
[ "$out" = "NO-WATCHER ~/other unread=1" ] || fail "tilde expands and prints the dir as given (got [$out])"
ps_lines "inbox-wait $T/home/x/"
# shellcheck disable=SC2088  # literal ~/ dir, expanded by the script
run_ws "~/x"
[ -z "$out" ] || fail "absolute watcher matches a ~/ dir (got [$out])"
unset HOME

# 6. A missing dir is reported with unread=0.
ps_lines "unrelated"
run_ws "$T/nope"
[ "$out" = "NO-WATCHER $T/nope unread=0" ] || fail "missing dir is reported (got [$out])"

# 7. Several dirs print in argument order, watched ones silently.
ps_lines "inbox-wait $T/m2"
run_ws "$T/m1" "$T/m2" "$T/m3"
[ "$out" = "NO-WATCHER $T/m1 unread=1
NO-WATCHER $T/m3 unread=3" ] || fail "multiple dirs print in order (got [$out])"

# 8. --host runs the check through one ssh call. The stub ssh logs its
# arguments and runs the remote command with a local sh -c.
STUBS="$T/stubs"
mkdir -p "$STUBS"
cat >"$STUBS/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$SSH_LOG"
[ -z "${FAKE_SSH_FAIL:-}" ] || exit 255
while [ "$1" = -o ]; do shift 2; done
host=$1
shift
[ "$host" = h1 ] || exit 254
exec sh -c "$*"
STUB
chmod +x "$STUBS/ssh"
SSH_LOG="$T/ssh.log"
export SSH_LOG

ps_lines "inbox-wait $T/m2"
export HOME="$T/home"
# shellcheck disable=SC2088  # literal ~/ dir, expanded by the remote check
out="$(PATH="$STUBS:$PATH" INBOX_WATCHERS_PS="cat $T/ps.txt" bash "$WS" --host h1 "$T/m1" "$T/m2" "$T/sp ace" "~/other" 2>"$T/err")"
rc=$?
err="$(cat "$T/err")"
unset HOME
[ "$rc" -eq 0 ] || fail "--host check exits 0 (got $rc, stderr [$err])"
[ "$out" = "NO-WATCHER $T/m1 unread=1
NO-WATCHER $T/sp ace unread=0
NO-WATCHER ~/other unread=1" ] || fail "--host prints the remote check (got [$out])"
grep -q '^-o BatchMode=yes -o ConnectTimeout=20 h1 sh -s -- --' "$SSH_LOG" \
  || fail "--host makes one ssh call to h1 with sh -s (log: $(cat "$SSH_LOG"))"
[ "$(wc -l <"$SSH_LOG" | tr -d ' ')" -eq 1 ] || fail "--host makes exactly one ssh call"

# 9. A failing ssh is never a clean result: non-zero exit and a stderr line.
: >"$SSH_LOG"
out="$(PATH="$STUBS:$PATH" FAKE_SSH_FAIL=1 INBOX_WATCHERS_PS="cat $T/ps.txt" bash "$WS" --host h1 "$T/u" 2>"$T/err")"
rc=$?
err="$(cat "$T/err")"
[ "$rc" -ne 0 ] || fail "failing ssh exits non-zero"
[ "$out" = "WATCH-ERROR inbox-watchers ssh h1 exit 255" ] \
  || fail "failing ssh prints a WATCH-ERROR line on stdout (got [$out])"
[ "$err" = "inbox-watchers: ssh h1 failed (exit 255)" ] \
  || fail "failing ssh names the host and exit code on stderr (got [$err])"

# 10. Usage errors exit 2 and print usage on stderr.
out="$(bash "$WS" 2>"$T/err")"
rc=$?
[ "$rc" -eq 2 ] || fail "no args exits 2 (got $rc)"
grep -q '^usage: inbox-watchers' "$T/err" || fail "no args prints usage on stderr"
out="$(bash "$WS" --host h1 2>"$T/err")"
rc=$?
[ "$rc" -eq 2 ] || fail "--host without a dir exits 2 (got $rc)"

echo "inbox-watchers: all cases passed"

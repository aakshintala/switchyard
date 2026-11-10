#!/usr/bin/env bash
# Tests claude-code/plugins/role-inbox's monitor against mktemp -d inboxes.
# A remote inbox runs through a stub ssh that runs its command locally with
# `sh -c`. The stub's stream ends when $T/drop exists, and the stub refuses to
# connect while it does, so the test drops a connection without a signal.
# Every monitor stops through ROLE_INBOX_STOP; the test sends no signals.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MON="$SCRIPT_DIR/../claude-code/plugins/role-inbox/scripts/role-inbox-monitor"

T="$(mktemp -d "${TMPDIR:-/tmp}/test-role-inbox.XXXXXX")"
T="$(cd "$T" && pwd -P)"
finish() {
  : >"$T/stop"
  : >"$T/drop"
  wait
  rm -rf "$T"
}
trap finish EXIT

fail() {
  echo "FAIL: $1" >&2
  echo "--- output:" >&2
  cat "$T/out" >&2 2>/dev/null
  exit 1
}

# wait_for <file> <fixed-string>: up to 15 s for the string to appear.
wait_for() {
  local i
  for i in $(seq 1 75); do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

count() { grep -cF -- "$2" "$1" 2>/dev/null || true; }

# start <cwd> <out>: run the monitor in <cwd>, output to <out>.
start() {
  : >"$2"
  (cd "$1" && ROLE_INBOX_CONF="$T/conf" ROLE_INBOX_SSH="bash $T/ssh" \
    ROLE_INBOX_RETRY_S=1 ROLE_INBOX_STOP="$T/stop" \
    exec bash "$MON" >"$2" 2>>"$T/err") &
  mon=$!
}

alive() { ps -p "$1" >/dev/null 2>&1; }

cat >"$T/ssh" <<EOF
#!/usr/bin/env bash
# stub ssh: refuse while $T/drop exists; else drop options and host and run
# the command locally, its stream ending when $T/drop appears.
[ -e "$T/drop" ] && exit 255
while [ \$# -gt 1 ]; do shift; done
ROLE_INBOX_STOP="$T/drop" sh -c "\$1"
[ -e "$T/drop" ] && exit 255
exit 0
EOF

mkdir -p "$T/role/home/sub" "$T/other" "$T/in/read" "$T/rin"
cat >"$T/conf" <<EOF
# comment
$T/role/home  $T/in
$T/role/home  stubhost:$T/rin
EOF

# --- local inbox ---
printf 'first message\n' >"$T/in/a.md"
printf 'old\n' >"$T/in/read/old.md"
printf 'staging\n' >"$T/in/.tmp.x.md"
head -c 2000 /dev/zero | tr '\0' 'x' >"$T/in/long.md"
start "$T/role/home/sub" "$T/out"

wait_for "$T/out" "INBOX $T/in/a.md (14 bytes)" || fail "waiting file not printed"
grep -qxF "first message" "$T/out" || fail "body not printed"
wait_for "$T/out" "INBOX $T/in/long.md (2000 bytes)" || fail "long file not printed"
grep -qxF "[truncated: read the file]" "$T/out" || fail "long file not truncated"
grep -qF "old.md" "$T/out" && fail "read/ file printed"
grep -qF ".tmp.x" "$T/out" && fail "dotfile printed"
grep -qE "^(READY|HEARTBEAT)" "$T/out" && fail "READY or HEARTBEAT reached the session"

printf 'second\n' >"$T/in/b.md"
wait_for "$T/out" "INBOX $T/in/b.md" || fail "new file not printed"
sleep 3
[ "$(count "$T/out" "INBOX $T/in/a.md")" = 1 ] || fail "a.md printed more than once"

mv "$T/in/a.md" "$T/in/read/a.md"
sleep 3
printf 'again\n' >"$T/in/a.md"
wait_for "$T/out" "again" || fail "a name that left and came back not printed again"

# --- remote inbox through the stub ssh ---
printf 'remote hello\n' >"$T/rin/r.md"
wait_for "$T/out" "INBOX $T/rin/r.md" || fail "remote file not printed"
grep -qxF "remote hello" "$T/out" || fail "remote body not printed"

: >"$T/drop"
wait_for "$T/out" "INBOX-WATCH lost stubhost:$T/rin" || fail "lost line not printed"
sleep 3
[ "$(count "$T/out" "INBOX-WATCH lost")" = 1 ] || fail "lost printed more than once per outage"
rm -f "$T/drop"
wait_for "$T/out" "INBOX-WATCH restored stubhost:$T/rin" || fail "restored line not printed"
sleep 3
[ "$(count "$T/out" "INBOX $T/rin/r.md")" = 2 ] || fail "a reconnect should replay the waiting remote file once"
alive "$mon" || fail "monitor exited"
m1=$mon

# --- a session matching no line ---
start "$T/other" "$T/out2"
sleep 3
[ -s "$T/out2" ] && fail "unmatched session printed output"
alive "$mon" || fail "unmatched monitor exited"

# --- the stop file ends both monitors (the stub's remote stream ends on drop) ---
: >"$T/stop"
: >"$T/drop"
for i in $(seq 1 50); do
  alive "$m1" || alive "$mon" || break
  sleep 0.2
done
alive "$m1" && fail "matched monitor did not stop"
alive "$mon" && fail "unmatched monitor did not stop"

echo "PASS: role-inbox"

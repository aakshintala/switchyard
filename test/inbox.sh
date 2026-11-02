#!/usr/bin/env bash
# Tests for bin/inbox-send and bin/inbox-wait, against a fresh mktemp -d
# fixture inbox (never a live run directory).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEND="$SCRIPT_DIR/../bin/inbox-send"
WAIT="$SCRIPT_DIR/../bin/inbox-wait"
DRAIN="$SCRIPT_DIR/../bin/inbox-drain"

fail() {
  [ -z "${WATCH:-}" ] || unwatch
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-inbox.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# Stub sleep first on PATH, in a PATH that holds no inotifywait, so
# inbox-wait always takes its sleep branch and every pause is
# test-controlled: the stub writes one line to the paused FIFO, reads one
# line from the go FIFO, then exits 0. It never really sleeps.
# pause_reached blocks until the waiter parks; release lets it recheck.
STUBSLEEP="$T/stubsleep"
mkdir -p "$STUBSLEEP"
mkfifo "$T/paused" "$T/go"
for tool in bash mkdir; do
  ln -s "$(command -v "$tool")" "$STUBSLEEP/$tool" || fail "cannot stage $tool"
done
cat >"$STUBSLEEP/sleep" <<STUB
#!/usr/bin/env bash
printf 'paused\n' >"$T/paused"
read -r _ <"$T/go"
STUB
chmod +x "$STUBSLEEP/sleep"
WAITPATH="$STUBSLEEP"

# pause_reached: block until the waiter is parked at its pause point.
pause_reached() { read -r _ <"$T/paused"; }
# release: let the parked waiter recheck.
release() { echo go >"$T/go"; }

# watch <waiter-pid>: hang guard for one waiter case. After 10 s it kills
# the waiter and the test itself. The test kills it on success. A failure
# bound only, never synchronization.
watch() {
  ( trap '' EXIT; sleep 10; kill "$1" 2>/dev/null; kill "$$" 2>/dev/null ) &
  WATCH=$!
}
unwatch() { kill "$WATCH" 2>/dev/null || true; wait "$WATCH" 2>/dev/null || true; }

# Two concurrent sends from the same sender produce two complete files.
INBOX="$T/inbox"
printf 'first message' | bash "$SEND" "$INBOX" lane >"$T/p1" &
p1=$!
printf 'second message' | bash "$SEND" "$INBOX" lane >"$T/p2" &
p2=$!
wait "$p1" || fail "first concurrent send failed"
wait "$p2" || fail "second concurrent send failed"
[ "$(find "$INBOX" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')" = "2" ] \
  || fail "two sends give two files: [$(ls "$INBOX")]"
[ -f "$(cat "$T/p1")" ] || fail "send 1 prints its delivered path: [$(cat "$T/p1")]"
[ -f "$(cat "$T/p2")" ] || fail "send 2 prints its delivered path: [$(cat "$T/p2")]"
[ "$(cat "$T/p1")" != "$(cat "$T/p2")" ] || fail "two sends give two paths"
for f in "$INBOX"/*.md; do
  c="$(cat "$f")"
  [ "$c" = "first message" ] || [ "$c" = "second message" ] \
    || fail "file is complete, not truncated: [$f] [$c]"
done
grep -q 'first message' "$INBOX"/*.md || fail "first message survived"
grep -q 'second message' "$INBOX"/*.md || fail "second message survived"

# A bad sender exits 2 with a message on stderr, and delivers nothing.
before="$(find "$INBOX" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')"
for bad in 'has/slash' 'has space' '' 'semi;colon' 'dol$lar' 'star*'; do
  err="$(printf 'x' | bash "$SEND" "$INBOX" "$bad" 2>&1 >/dev/null)"; rc=$?
  [ "$rc" = "2" ] || fail "sender [$bad] exits 2 (got $rc)"
  [ -n "$err" ] || fail "sender [$bad] says why on stderr"
done
[ "$(find "$INBOX" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')" = "$before" ] \
  || fail "bad senders deliver nothing"
printf 'ok' | bash "$SEND" "$INBOX" 'a.b_c-d9' >/dev/null \
  || fail "dotted sender is accepted"

# inbox-wait with a waiting file exits within 2 s and prints its path.
# A stray temp file must never be printed.
WBOX="$T/waiting"
delivered="$(printf 'waiting message' | bash "$SEND" "$WBOX" lane)"
printf 'partial' >"$WBOX/.tmp.stray"
SECONDS=0
out="$(bash "$WAIT" "$WBOX")"; rc=$?
[ "$rc" = "0" ] || fail "wait on a waiting file exits 0 (got $rc)"
[ "$SECONDS" -lt 2 ] || fail "wait on a waiting file is immediate (${SECONDS}s)"
[ "$out" = "$delivered" ] || fail "wait prints the waiting path: [$out] vs [$delivered]"

# inbox-wait on an empty inbox wakes for a later send: the waiter parks
# first (pause_reached), the send lands while it is parked, and release
# lets it recheck, print the new path and exit 0.
EBOX="$T/empty"
mkdir -p "$EBOX"
PATH="$WAITPATH" bash "$WAIT" "$EBOX" >"$T/wout" 2>"$T/werr" &
wpid=$!
watch "$wpid"
pause_reached
later="$(printf 'wake up' | bash "$SEND" "$EBOX" lane)"
release
wait "$wpid" || fail "wait exits 0 after the send"
unwatch
[ "$(cat "$T/wout")" = "$later" ] || fail "wait prints the new path: [$(cat "$T/wout")] vs [$later]"

# A file in read/ alone does not end the wait: the waiter rechecks on
# release and parks again (second pause_reached) instead of exiting.
# Then kill it, release once more to free the orphaned stub, and reap it.
RBOX="$T/readbox"
mkdir -p "$RBOX/read"
printf 'already read' >"$RBOX/read/lane-20200101T000000Z-$$-1.md"
PATH="$WAITPATH" bash "$WAIT" "$RBOX" >"$T/rout" 2>/dev/null &
rpid=$!
watch "$rpid"
pause_reached
release
pause_reached
kill "$rpid" 2>/dev/null || fail "wait ended on a read/ file alone"
release
wait "$rpid" 2>/dev/null || true
unwatch

# Remote mode: a stub ssh first on PATH runs its command locally with
# bash -c and logs its arguments.
STUB="$T/stubbin"
mkdir -p "$STUB"
cat >"$STUB/ssh" <<'STUB'
#!/usr/bin/env bash
# Stub ssh for tests: log the arguments, run the remote command locally.
printf '%s\n' "$@" >>"$SSH_LOG"
if [ "${SSH_FAIL:-}" = yes ]; then exit 255; fi
cmd="${@: -1}"
exec bash -c "$cmd"
STUB
chmod +x "$STUB/ssh"
export SSH_LOG="$T/ssh-args.log"
export HOME="$T/home"
mkdir -p "$HOME/.agents/bin"
cp "$SEND" "$HOME/.agents/bin/inbox-send"
remote_out="$(printf 'remote hello' | PATH="$STUB:$PATH" INBOX_HOST="mac-host" bash "$SEND" "$T/remote-inbox" lane)"
[ -f "$remote_out" ] || fail "remote send delivers the file: [$remote_out]"
[ "$(cat "$remote_out")" = "remote hello" ] || fail "remote file is complete: [$(cat "$remote_out")]"
grep -q 'mac-host' "$SSH_LOG" || fail "stub ssh got the host: [$(cat "$SSH_LOG" 2>/dev/null)]"
grep -q 'inbox-send' "$SSH_LOG" || fail "stub ssh got the command: [$(cat "$SSH_LOG" 2>/dev/null)]"
expected_ssh_options=$(printf '%s\n' -o BatchMode=yes -o ConnectTimeout=10)
[ "$(head -n 4 "$SSH_LOG")" = "$expected_ssh_options" ] \
  || fail "remote ssh uses bounded non-interactive options first: [$(head -n 6 "$SSH_LOG")]"
[ "$(sed -n '5p' "$SSH_LOG")" = mac-host ] || fail "remote ssh options precede the host"
FAILED_REMOTE="$T/failed-remote-inbox"
printf 'failure' | PATH="$STUB:$PATH" INBOX_HOST=mac-host SSH_FAIL=yes \
  bash "$SEND" "$FAILED_REMOTE" lane >"$T/failed-remote.out" 2>"$T/failed-remote.err"; rc=$?
[ "$rc" -ne 0 ] || fail "failed remote ssh makes inbox-send fail (got $rc)"
[ ! -e "$FAILED_REMOTE" ] || fail "failed remote ssh delivers no file"

# inbox-drain on an empty inbox prints INBOX n=0 and exits 0.
EMPTYDRAIN="$T/emptydrain"
mkdir -p "$EMPTYDRAIN"
printf 'hidden' >"$EMPTYDRAIN/.hidden.md"
printf 'not markdown' >"$EMPTYDRAIN/note.txt"
dout="$(bash "$DRAIN" "$EMPTYDRAIN")"; rc=$?
[ "$rc" = "0" ] || fail "drain on empty inbox exits 0 (got $rc)"
[ "$dout" = "INBOX n=0" ] || fail "drain on empty inbox prints INBOX n=0: [$dout]"
[ "$(find "$EMPTYDRAIN" -maxdepth 1 -type f | wc -l | tr -d ' ')" = "2" ] \
  || fail "drain leaves dotfiles and non-md files alone"

# inbox-drain on a missing dir is not an error.
dout="$(bash "$DRAIN" "$T/no-such-dir")"; rc=$?
[ "$rc" = "0" ] || fail "drain on missing dir exits 0 (got $rc)"
[ "$dout" = "INBOX n=0" ] || fail "drain on missing dir prints INBOX n=0: [$dout]"

# Bad usage exits 2: no dir, or an unknown argument.
bash "$DRAIN" >/dev/null 2>&1; [ "$?" = "2" ] || fail "drain with no dir exits 2"
bash "$DRAIN" "$EMPTYDRAIN" --bogus >/dev/null 2>&1; [ "$?" = "2" ] || fail "drain with unknown arg exits 2"
bash "$DRAIN" "$EMPTYDRAIN" --count extra >/dev/null 2>&1; [ "$?" = "2" ] || fail "drain with extra args exits 2"

# Two messages drain oldest first, each with its sender and time, body
# intact (the first body has no trailing newline); both end in read/.
DBOX="$T/drainbox"
first_path="$(printf 'first message' | bash "$SEND" "$DBOX" alice)"
sleep 1
second_path="$(printf 'second body\nwith newline\n' | bash "$SEND" "$DBOX" bob)"
first_base="$(basename "$first_path")"
second_base="$(basename "$second_path")"
first_ts="$(printf '%s' "$first_base" | sed -n 's/.*-\([0-9]\{8\}T[0-9]\{6\}Z\)-.*-.*\.md/\1/p')"
second_ts="$(printf '%s' "$second_base" | sed -n 's/.*-\([0-9]\{8\}T[0-9]\{6\}Z\)-.*-.*\.md/\1/p')"
[ -n "$first_ts" ] || fail "first filename holds a timestamp: [$first_base]"
[ -n "$second_ts" ] || fail "second filename holds a timestamp: [$second_base]"
dout="$(bash "$DRAIN" "$DBOX")"; rc=$?
[ "$rc" = "0" ] || fail "drain exits 0 (got $rc)"
[ "$(printf '%s\n' "$dout" | head -n 1)" = "INBOX n=2" ] \
  || fail "drain prints INBOX n=2 first: [$dout]"
printf '%s\n' "$dout" | grep -q "alice" || fail "drain prints the first sender: [$dout]"
printf '%s\n' "$dout" | grep -q "$first_ts" || fail "drain prints the first time: [$dout]"
printf '%s\n' "$dout" | grep -q "bob" || fail "drain prints the second sender: [$dout]"
printf '%s\n' "$dout" | grep -q "$second_ts" || fail "drain prints the second time: [$dout]"
printf '%s\n' "$dout" | grep -q 'first message' || fail "drain prints the first body: [$dout]"
printf '%s\n' "$dout" | grep -q 'second body' || fail "drain prints the second body: [$dout]"
first_line="$(printf '%s\n' "$dout" | grep -n 'first message' | cut -d: -f1)"
second_line="$(printf '%s\n' "$dout" | grep -n 'second body' | cut -d: -f1)"
[ "$first_line" -lt "$second_line" ] || fail "drain prints oldest first: [$dout]"
[ "$(find "$DBOX" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')" = "0" ] \
  || fail "drained files leave the inbox: [$(ls "$DBOX")]"
[ "$(find "$DBOX/read" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')" = "2" ] \
  || fail "both drained files end in read/: [$(ls "$DBOX/read")]"
grep -q 'first message' "$DBOX/read"/*.md || fail "first body survived in read/"
grep -q 'second body' "$DBOX/read"/*.md || fail "second body survived in read/"

# --count prints INBOX n=2 only, moves nothing and creates no read/;
# the next plain drain still prints and moves both.
CBOX="$T/countbox"
printf 'one' | bash "$SEND" "$CBOX" alice >/dev/null
sleep 1
printf 'two' | bash "$SEND" "$CBOX" bob >/dev/null
cout="$(bash "$DRAIN" "$CBOX" --count)"; rc=$?
[ "$rc" = "0" ] || fail "drain --count exits 0 (got $rc)"
[ "$cout" = "INBOX n=2" ] || fail "drain --count prints only INBOX n=2: [$cout]"
[ "$(find "$CBOX" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')" = "2" ] \
  || fail "drain --count moves nothing: [$(ls "$CBOX")]"
[ ! -e "$CBOX/read" ] || fail "drain --count creates no read/"
dout="$(bash "$DRAIN" "$CBOX")"; rc=$?
[ "$rc" = "0" ] || fail "plain drain after --count exits 0 (got $rc)"
[ "$(printf '%s\n' "$dout" | head -n 1)" = "INBOX n=2" ] \
  || fail "plain drain after --count still prints both: [$dout]"
[ "$(find "$CBOX/read" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')" = "2" ] \
  || fail "plain drain after --count moves both"

# A file arriving during the drain stays for the next drain: a PATH stub
# for cat sends one message on its first call, then runs the real tool.
LBOX="$T/latebox"
printf 'early' | bash "$SEND" "$LBOX" alice >/dev/null
REALCAT="$(command -v cat)"
DRAINSTUB="$T/drainstub"
mkdir -p "$DRAINSTUB"
rm -f "$T/cat-fired"
cat >"$DRAINSTUB/cat" <<STUB
#!/usr/bin/env bash
if [ ! -f "$T/cat-fired" ]; then
  touch "$T/cat-fired"
  PATH="/usr/bin:/bin" printf 'late arrival' | bash "$SEND" "$LBOX" late >/dev/null
fi
exec "$REALCAT" "\$@"
STUB
chmod +x "$DRAINSTUB/cat"
dout="$(PATH="$DRAINSTUB:$PATH" bash "$DRAIN" "$LBOX")"; rc=$?
[ "$rc" = "0" ] || fail "drain with a late arrival exits 0 (got $rc)"
[ "$(printf '%s\n' "$dout" | head -n 1)" = "INBOX n=1" ] \
  || fail "drain with a late arrival prints INBOX n=1: [$dout]"
printf '%s\n' "$dout" | grep -q 'early' || fail "drain prints the early message: [$dout]"
printf '%s\n' "$dout" | grep -q 'late arrival' \
  && fail "late arrival waits for the next drain: [$dout]"
[ "$(find "$LBOX" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')" = "1" ] \
  || fail "late file stays unread: [$(ls "$LBOX")]"
[ "$(find "$LBOX/read" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')" = "1" ] \
  || fail "early file moved to read/: [$(ls "$LBOX/read")]"
dout2="$(bash "$DRAIN" "$LBOX")"; rc=$?
[ "$rc" = "0" ] || fail "next drain exits 0 (got $rc)"
[ "$(printf '%s\n' "$dout2" | head -n 1)" = "INBOX n=1" ] \
  || fail "next drain prints INBOX n=1: [$dout2]"
printf '%s\n' "$dout2" | grep -q 'late arrival' \
  || fail "next drain prints the late message: [$dout2]"
[ "$(find "$LBOX" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')" = "0" ] \
  || fail "next drain moves the late file"

# read/ is never listed: a drain with only archived files prints INBOX n=0.
dout="$(bash "$DRAIN" "$LBOX")"; rc=$?
[ "$rc" = "0" ] || fail "drain after all moved exits 0 (got $rc)"
[ "$dout" = "INBOX n=0" ] || fail "read/ files are never listed: [$dout]"

echo "inbox: all cases passed"

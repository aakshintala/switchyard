#!/usr/bin/env bash
# Tests for bin/inbox-send and bin/inbox-wait, against a fresh mktemp -d
# fixture inbox (never a live run directory).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEND="$SCRIPT_DIR/../bin/inbox-send"
WAIT="$SCRIPT_DIR/../bin/inbox-wait"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-inbox.XXXXXX")"
trap 'rm -rf "$T"' EXIT

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

# inbox-wait with a waiting file exits within 1 s and prints its path.
# A stray temp file must never be printed.
WBOX="$T/waiting"
delivered="$(printf 'waiting message' | bash "$SEND" "$WBOX" lane)"
printf 'partial' >"$WBOX/.tmp.stray"
SECONDS=0
out="$(bash "$WAIT" "$WBOX")"; rc=$?
[ "$rc" = "0" ] || fail "wait on a waiting file exits 0 (got $rc)"
[ "$SECONDS" -lt 1 ] || fail "wait on a waiting file is immediate (${SECONDS}s)"
[ "$out" = "$delivered" ] || fail "wait prints the waiting path: [$out] vs [$delivered]"

# inbox-wait on an empty inbox, started in the background, exits within 5 s
# of a later inbox-send and prints that path.
EBOX="$T/empty"
mkdir -p "$EBOX"
bash "$WAIT" "$EBOX" >"$T/wout" 2>"$T/werr" &
wpid=$!
sleep 1
later="$(printf 'wake up' | bash "$SEND" "$EBOX" lane)"
SECONDS=0
while kill -0 "$wpid" 2>/dev/null; do
  [ "$SECONDS" -lt 5 ] || { kill "$wpid" 2>/dev/null; fail "wait did not wake within 5 s of the send"; }
  sleep 0.2
done
wait "$wpid" || fail "wait exits 0 after the send"
[ "$(cat "$T/wout")" = "$later" ] || fail "wait prints the new path: [$(cat "$T/wout")] vs [$later]"

# A file in read/ alone does not end the wait (kill after 3 s).
RBOX="$T/readbox"
mkdir -p "$RBOX/read"
printf 'already read' >"$RBOX/read/lane-20200101T000000Z-$$-1.md"
bash "$WAIT" "$RBOX" >"$T/rout" 2>/dev/null &
rpid=$!
sleep 3
if kill -0 "$rpid" 2>/dev/null; then
  kill "$rpid" 2>/dev/null || true
  wait "$rpid" 2>/dev/null || true
else
  fail "wait ended on a read/ file alone"
fi

# Remote mode: a stub ssh first on PATH runs its command locally with
# bash -c and logs its arguments.
STUB="$T/stubbin"
mkdir -p "$STUB"
cat >"$STUB/ssh" <<'STUB'
#!/usr/bin/env bash
# Stub ssh for tests: log the arguments, run the remote command locally.
printf '%s\n' "$@" >>"$SSH_LOG"
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

echo "inbox: all cases passed"

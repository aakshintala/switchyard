#!/usr/bin/env bash
# Tests bin/wired-check with fake owner-ask and inbox-send commands.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/../bin/wired-check"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-wired-check.XXXXXX")"
trap 'rm -rf "$T"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

export HOME="$T/home"
STUBS="$T/stubs"
mkdir -p "$HOME" "$STUBS"
export OWNER_ASK_LOG="$T/owner-ask.log" INBOX_SEND_LOG="$T/inbox-send.log"

cat >"$STUBS/owner-ask" <<'OWNER'
#!/usr/bin/env bash
printf 'owner-ask %s\n' "$*" >>"$OWNER_ASK_LOG"
OWNER
cat >"$STUBS/inbox-send" <<'INBOX'
#!/usr/bin/env bash
{
  printf 'args=%s\n' "$*"
  printf 'note='
  cat
  printf '\n--\n'
} >>"$INBOX_SEND_LOG"
INBOX
chmod +x "$STUBS/owner-ask" "$STUBS/inbox-send"
export PATH="$STUBS:$PATH"

STATE="$T/wired-check.state"
LOG="$T/wired-check.log"
INBOX="$T/inbox/switchyard"
OVER_LIMIT=$((8 * 1024 * 1024 * 1024))
UNDER_LIMIT=$((6 * 1024 * 1024 * 1024))

run_check() {
  WIRED_CHECK_BYTES="$1" \
    WIRED_CHECK_STATE_FILE="$STATE" \
    WIRED_CHECK_LOG="$LOG" \
    WIRED_CHECK_INBOX="$INBOX" \
    WIRED_CHECK_INBOX_SEND="$STUBS/inbox-send" \
    WIRED_CHECK_VNODES=1234 \
    WIRED_CHECK_MAXVNODES=5678 \
    bash "$BIN"
}

: >"$OWNER_ASK_LOG"; : >"$INBOX_SEND_LOG"
run_check "$OVER_LIMIT" >"$T/over-1.out" 2>"$T/over-1.err" || fail "first over-limit run failed: $(cat "$T/over-1.err")"
run_check "$OVER_LIMIT" >"$T/over-2.out" 2>"$T/over-2.err" || fail "second over-limit run failed: $(cat "$T/over-2.err")"
[ "$(grep -c -- '--kind breaker-on' "$OWNER_ASK_LOG")" -eq 1 ] || fail "two over-limit runs did not emit exactly one breaker-on"
grep -F -- '--from switchyard --kind breaker-on --name wired-memory' "$OWNER_ASK_LOG" >/dev/null \
  || fail "breaker-on omitted source or wired-memory name"
[ "$(grep -c '^note=wired-check: kernel wired memory is ' "$INBOX_SEND_LOG")" -eq 2 ] \
  || fail "inbox note was not retained on every over-limit run"
grep -F "args=$INBOX wired-check" "$INBOX_SEND_LOG" >/dev/null || fail "inbox note was not sent to switchyard inbox"
grep -F 'vnodes 1234/5678' "$INBOX_SEND_LOG" >/dev/null || fail "inbox note omitted vnode counts"
[ "$(wc -l <"$LOG" | tr -d ' ')" -eq 2 ] || fail "wired log did not record both runs"

# Recovery emits one breaker-off; repeated healthy runs stay quiet.
run_check "$UNDER_LIMIT" >"$T/recover-1.out" 2>"$T/recover-1.err" || fail "recovery run failed: $(cat "$T/recover-1.err")"
run_check "$UNDER_LIMIT" >"$T/recover-2.out" 2>"$T/recover-2.err" || fail "second recovery run failed: $(cat "$T/recover-2.err")"
[ "$(grep -c -- '--kind breaker-off' "$OWNER_ASK_LOG")" -eq 1 ] || fail "recovery did not emit exactly one breaker-off"
grep -F -- '--from switchyard --kind breaker-off --name wired-memory' "$OWNER_ASK_LOG" >/dev/null \
  || fail "breaker-off omitted source or wired-memory name"
[ "$(wc -l <"$INBOX_SEND_LOG" | tr -d ' ')" -gt 0 ] || fail "inbox log unexpectedly disappeared"
[ "$(wc -l <"$LOG" | tr -d ' ')" -eq 4 ] || fail "wired log did not record all four runs"

printf 'wired-check: all cases passed\n'

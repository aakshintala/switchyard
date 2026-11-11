#!/usr/bin/env bash
# A ruling with an unresolved session-send disposition waits for idle, then retries once.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
BIN="$here/../bin"
T=$(mktemp -d "${TMPDIR:-/tmp}/ruled.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/home"

cat >"$T/stub/delegate" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "session list")
    printf '%s idle pi/model turns=1 /work\n' "$SESSION_ID"
    ;;
  "session watch")
    printf 'watch\n' >>"$EVENTS"
    echo idle
    ;;
  "session send")
    n=$(cat "$SEND_COUNT")
    n=$((n + 1))
    printf '%s\n' "$n" >"$SEND_COUNT"
    cat >"$T/send-$n"
    printf 'send-%s\n' "$n" >>"$EVENTS"
    if [ "$n" -eq 1 ]; then echo "$FIRST_DISPOSITION"; else echo started; fi
    ;;
  *) echo "unexpected delegate call: $*" >&2; exit 2 ;;
esac
STUB
cat >"$T/stub/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
command=${!#}
case "$command" in
  *'session watch '*)
    printf 'watch\n' >>"$EVENTS"
    echo idle
    ;;
  *'session send '*)
    n=$(cat "$SEND_COUNT")
    n=$((n + 1))
    printf '%s\n' "$n" >"$SEND_COUNT"
    cat >"$T/send-$n"
    printf 'send-%s\n' "$n" >>"$EVENTS"
    if [ "$n" -eq 1 ]; then echo "$FIRST_DISPOSITION"; else echo started; fi
    ;;
  *) echo "unexpected ssh call: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/stub/delegate" "$T/stub/ssh"

case_number=0
failures=0
fail() { echo "FAIL $1" >&2; failures=$((failures + 1)); }

run_case() {
  local route=$1 disposition=$2 ticket run ruling sid output rc count
  case_number=$((case_number + 1))
  ticket=$((5100 + case_number))
  sid="session-$case_number"
  run="$T/run-$case_number"
  ruling="$T/ruling-$ticket.md"
  mkdir -p "$run" "$run/inbox" "$run/rulings"
  printf 'RULING-%s\n' "$ticket" >"$ruling"
  printf '2026-01-01T00:00:00Z\t%s\t%s\t%s\t%s\n' \
    "$ticket" "$route" "fiber-$ticket-build" "$sid" >"$run/roster"
  printf '0\n' >"$T/count-$case_number"
  : >"$T/events-$case_number"
  export T SESSION_ID="$sid" FIRST_DISPOSITION="$disposition"
  export SEND_COUNT="$T/count-$case_number" EVENTS="$T/events-$case_number"
  if [ "$route" = mac ]; then
    output=$(HOME="$T/home" FW_RUN="$run" FW_NO_BOX_PUSH=1 \
      FW_DELEGATE="$T/stub/delegate" INBOX_HOST=mac \
      bash "$BIN/ruled.sh" "$ticket" "$ruling" 2>&1) && rc=0 || rc=$?
  else
    output=$(HOME="$T/home" FW_RUN="$run" FW_NO_BOX_PUSH=1 \
      BOX_SSH="$T/stub/ssh" FW_BOX_HOST=fixture \
      bash "$BIN/ruled.sh" "$ticket" "$ruling" 2>&1) && rc=0 || rc=$?
  fi
  count=$(cat "$SEND_COUNT")
  if [ "$rc" -ne 0 ] || [ "$count" -ne 2 ] \
      || [ "$(cat "$EVENTS")" != $'send-1\nwatch\nsend-2' ] \
      || ! printf '%s\n' "$output" | grep -q "send returned $disposition; waiting for $sid to go idle" \
      || ! printf '%s\n' "$output" | grep -q 'lane is idle; resending ruling once as a fresh turn' \
      || ! printf '%s\n' "$output" | grep -q 'resent once after idle:' \
      || [ "$(cat "$T/send-1")" != "RULING-$ticket" ] \
      || [ "$(cat "$T/send-2")" != "RULING-$ticket" ]; then
    fail "$route $disposition waits for idle and resends once (rc=$rc count=$count events=$(cat "$EVENTS") output=$output)"
  else
    echo "ok $route-$disposition-waits-and-resends-once"
  fi
}

run_case mac unconsumed
run_case mac unconfirmed
run_case muse unconsumed
run_case muse unconfirmed
[ "$failures" -eq 0 ]

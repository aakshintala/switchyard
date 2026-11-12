#!/usr/bin/env bash
# A ruling waits for idle, then resends only when event history says it was not delivered.
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
    if [ "$n" -eq 1 ]; then
      printf '{"ok":true,"disposition":"%s","commandId":"%s"}\n' \
        "$FIRST_DISPOSITION" "$COMMAND_ID"
    else
      echo '{"ok":true,"disposition":"started"}'
    fi
    ;;
  "session logs")
    printf 'logs\n' >>"$EVENTS"
    case "$EVENT_OUTCOME" in
      consumed)
        printf '{"ok":true,"lines":[{"kind":"user","commandId":"%s"},{"kind":"steer.replayed","commandIds":["%s"]}]}\n' \
          "$COMMAND_ID" "$COMMAND_ID"
        ;;
      unconsumed)
        printf '{"ok":true,"lines":[{"kind":"steer.unconsumed","commandIds":["%s"]}]}\n' \
          "$COMMAND_ID"
        ;;
      missing) echo '{"ok":true,"lines":[]}' ;;
      *) echo "unexpected event outcome: $EVENT_OUTCOME" >&2; exit 2 ;;
    esac
    ;;
  *) echo "unexpected delegate call: $*" >&2; exit 2 ;;
esac
STUB
cat >"$T/stub/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
command=${!#}
case "$command" in
  *'session watch '* )
    printf 'watch\n' >>"$EVENTS"
    echo idle
    ;;
  *'session send '* )
    n=$(cat "$SEND_COUNT")
    n=$((n + 1))
    printf '%s\n' "$n" >"$SEND_COUNT"
    cat >"$T/send-$n"
    printf 'send-%s\n' "$n" >>"$EVENTS"
    if [ "$n" -eq 1 ]; then
      printf '{"ok":true,"disposition":"%s","commandId":"%s"}\n' \
        "$FIRST_DISPOSITION" "$COMMAND_ID"
    else
      echo '{"ok":true,"disposition":"started"}'
    fi
    ;;
  *'session logs '* )
    printf 'logs\n' >>"$EVENTS"
    case "$EVENT_OUTCOME" in
      consumed)
        printf '{"ok":true,"lines":[{"kind":"user","commandId":"%s"},{"kind":"steer.replayed","commandIds":["%s"]}]}\n' \
          "$COMMAND_ID" "$COMMAND_ID"
        ;;
      unconsumed)
        printf '{"ok":true,"lines":[{"kind":"steer.unconsumed","commandIds":["%s"]}]}\n' \
          "$COMMAND_ID"
        ;;
      missing) echo '{"ok":true,"lines":[]}' ;;
      *) echo "unexpected event outcome: $EVENT_OUTCOME" >&2; exit 2 ;;
    esac
    ;;
  *) echo "unexpected ssh call: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/stub/delegate" "$T/stub/ssh"

case_number=0
failures=0
fail() { echo "FAIL $1" >&2; failures=$((failures + 1)); }

run_case() {
  local route=$1 disposition=$2 outcome=$3 resend=$4 ticket run ruling sid output rc count expected_events expected_count
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
  export T SESSION_ID="$sid" FIRST_DISPOSITION="$disposition" EVENT_OUTCOME="$outcome"
  COMMAND_ID="command-$case_number"
  export COMMAND_ID
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
  if [ "$disposition" = unconfirmed ]; then
    if [ "$resend" = yes ]; then
      expected_count=2
      expected_events=$'send-1\nwatch\nlogs\nsend-2'
      if [ "$outcome" = unconsumed ]; then
        grep -q 'events confirm unconsumed commandId .*; resending once' <<<"$output" || fail "$route $disposition $outcome reports confirmed drop"
      else
        grep -q 'commandId is absent from delivery events; resending once' <<<"$output" || fail "$route $disposition $outcome reports missing event"
      fi
    else
      expected_count=1
      expected_events=$'send-1\nwatch\nlogs'
      grep -q 'delivery event confirms commandId .*; not resending' <<<"$output" || fail "$route $disposition $outcome reports no resend"
    fi
  else
    expected_count=2
    expected_events=$'send-1\nwatch\nsend-2'
    grep -q 'unconsumed; resending once as a fresh turn' <<<"$output" || fail "$route immediate unconsumed reports resend"
  fi
  if [ "$rc" -ne 0 ] || [ "$count" -ne "$expected_count" ] \
      || [ "$(cat "$EVENTS")" != "$expected_events" ] \
      || [ "$(cat "$T/send-1")" != "RULING-$ticket" ] \
      || { [ "$resend" = yes ] && [ "$(cat "$T/send-2")" != "RULING-$ticket" ]; }; then
    fail "$route $disposition $outcome resend=$resend (rc=$rc count=$count events=$(cat "$EVENTS") output=$output)"
  else
    echo "ok $route-$disposition-$outcome-resend-$resend"
  fi
}

for route in mac muse; do
  run_case "$route" unconfirmed consumed no
  run_case "$route" unconfirmed unconsumed yes
  run_case "$route" unconfirmed missing yes
  run_case "$route" unconsumed ignored yes
done
[ "$failures" -eq 0 ]

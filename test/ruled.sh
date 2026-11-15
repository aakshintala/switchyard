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
    if [ -n "${DELEGATE_CALLS:-}" ]; then printf '%s\n' "$*" >>"$DELEGATE_CALLS"; fi
    if [ "${LIST_RC:-0}" -ne 0 ]; then
      echo 'session list failed for test' >&2
      exit "$LIST_RC"
    fi
    printf '%s idle pi/model turns=1 /work\n' "$SESSION_ID"
    ;;
  "session status")
    if [ -n "${DELEGATE_CALLS:-}" ]; then printf '%s\n' "$*" >>"$DELEGATE_CALLS"; fi
    if [ "${STATUS_RC:-0}" -ne 0 ]; then
      printf '%s\n' "${STATUS_ERROR:-session status failed}" >&2
      exit "$STATUS_RC"
    fi
    printf '%s idle model=pi/model\n' "${3:-}"
    ;;
  "session watch")
    if [ -n "${DELEGATE_CALLS:-}" ]; then printf '%s\n' "$*" >>"$DELEGATE_CALLS"; fi
    printf 'watch\n' >>"$EVENTS"
    echo idle
    ;;
  "session send")
    if [ -n "${DELEGATE_CALLS:-}" ]; then printf '%s\n' "$*" >>"$DELEGATE_CALLS"; fi
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
    if [ -n "${DELEGATE_CALLS:-}" ]; then printf '%s\n' "$*" >>"$DELEGATE_CALLS"; fi
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
  : >"$T/delegate-calls-$case_number"
  export T SESSION_ID="$sid" FIRST_DISPOSITION="$disposition" EVENT_OUTCOME="$outcome"
  COMMAND_ID="command-$case_number"
  export COMMAND_ID
  export SEND_COUNT="$T/count-$case_number" EVENTS="$T/events-$case_number"
  export DELEGATE_CALLS="$T/delegate-calls-$case_number" STATUS_RC=0 LIST_RC=0
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

run_mac_lookup_case() {
  local name=$1 jid_mode=$2 status_rc=$3 list_rc=$4 delegate=$5 ticket run ruling sid
  local output rc count calls expected_calls
  case_number=$((case_number + 1))
  ticket=$((5100 + case_number))
  sid="session-$case_number"
  run="$T/run-$case_number"
  ruling="$T/ruling-$ticket.md"
  mkdir -p "$run" "$run/inbox" "$run/rulings"
  printf 'RULING-%s\n' "$ticket" >"$ruling"
  if [ "$jid_mode" = present ]; then
    printf '2026-01-01T00:00:00Z\t%s\tmac\t%s\t%s\n' \
      "$ticket" "fiber-$ticket-build" "$sid" >"$run/roster"
  else
    printf '2026-01-01T00:00:00Z\t%s\tmac\t%s\n' \
      "$ticket" "fiber-$ticket-build" >"$run/roster"
  fi
  printf '0\n' >"$T/count-$case_number"
  : >"$T/events-$case_number"
  : >"$T/delegate-calls-$case_number"
  export T SESSION_ID="$sid" FIRST_DISPOSITION=started EVENT_OUTCOME=missing
  export STATUS_RC="$status_rc" LIST_RC="$list_rc" STATUS_ERROR='status backend exploded'
  export SEND_COUNT="$T/count-$case_number" EVENTS="$T/events-$case_number"
  export DELEGATE_CALLS="$T/delegate-calls-$case_number"
  output=$(HOME="$T/home" FW_RUN="$run" FW_NO_BOX_PUSH=1 \
    FW_DELEGATE="$delegate" INBOX_HOST=mac \
    bash "$BIN/ruled.sh" "$ticket" "$ruling" 2>&1) && rc=0 || rc=$?
  count=$(cat "$SEND_COUNT")
  calls=$(cat "$DELEGATE_CALLS")
  case "$name" in
    list-fails-status-works)
      expected_calls=$(printf 'session status %s\nsession send %s - --json' "$sid" "$sid")
      if [ "$rc" -ne 0 ] || [ "$count" -ne 1 ] \
          || [ "$calls" != "$expected_calls" ] \
          || ! grep -q 'delivered into the turn' <<<"$output"; then
        fail "$name (rc=$rc count=$count calls=$calls output=$output)"
      else
        echo "ok $name"
      fi
      ;;
    missing-session)
      if [ "$rc" -ne 3 ] || [ "$count" -ne 0 ] \
          || [ "$calls" != "session status $sid" ] \
          || ! grep -q 'delegate store has no such session' <<<"$output" \
          || ! grep -Fq "delegate session $sid" <<<"$output" \
          || ! grep -q 'archive copy above is the durable record' <<<"$output" \
          || ! grep -q 'resolve delivery manually' <<<"$output" \
          || grep -Eqi 'Claude session|SendMessage' <<<"$output"; then
        fail "$name (rc=$rc count=$count calls=$calls output=$output)"
      else
        echo "ok $name"
      fi
      ;;
    status-error)
      if [ "$rc" -ne 3 ] || [ "$count" -ne 0 ] \
          || [ "$calls" != "session status $sid" ] \
          || ! grep -q 'delegate session status .* failed (exit 1)' <<<"$output" \
          || ! grep -q 'status backend exploded' <<<"$output" \
          || ! grep -q 'archive copy above is the durable record' <<<"$output" \
          || ! grep -q 'resolve delivery manually' <<<"$output" \
          || grep -Eqi 'Claude session|SendMessage' <<<"$output"; then
        fail "$name (rc=$rc count=$count calls=$calls output=$output)"
      else
        echo "ok $name"
      fi
      ;;
    missing-binary)
      if [ "$rc" -ne 3 ] || [ "$count" -ne 0 ] || [ -n "$calls" ] \
          || ! grep -q 'delegate lookup failed: binary .* missing or not executable' <<<"$output" \
          || ! grep -q 'lookup could not run' <<<"$output" \
          || ! grep -q 'archive copy above is the durable record' <<<"$output" \
          || ! grep -q 'resolve delivery manually' <<<"$output" \
          || grep -Eqi 'Claude session|SendMessage' <<<"$output"; then
        fail "$name (rc=$rc count=$count calls=$calls output=$output)"
      else
        echo "ok $name"
      fi
      ;;
    no-delegate-id)
      if [ "$rc" -ne 3 ] || [ "$count" -ne 0 ] || [ -n "$calls" ] \
          || ! grep -q 'is a mac Claude session' <<<"$output" \
          || ! grep -q 'SendMessage to' <<<"$output"; then
        fail "$name (rc=$rc count=$count calls=$calls output=$output)"
      else
        echo "ok $name"
      fi
      ;;
  esac
}

run_mac_lookup_case list-fails-status-works present 0 1 "$T/stub/delegate"
run_mac_lookup_case missing-session present 3 0 "$T/stub/delegate"
run_mac_lookup_case status-error present 1 0 "$T/stub/delegate"
run_mac_lookup_case missing-binary present 0 0 "$T/nonexistent/delegate"
run_mac_lookup_case no-delegate-id empty 0 0 "$T/stub/delegate"

[ "$failures" -eq 0 ]

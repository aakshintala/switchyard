#!/usr/bin/env bash
# Tests bin/lanewatch against fixture run dirs and PATH stubs, never live lanes.
set -uo pipefail
unset LANEWATCH_INTERVAL LANEWATCH_INBOX INBOX_HOST

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/ps-stub.sh"
LANEWATCH="$SCRIPT_DIR/../bin/lanewatch"
LANESTAT="$SCRIPT_DIR/../bin/lanestat"
fail() { echo "FAIL: $1" >&2; exit 1; }
strip_timestamp() {
  sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ //'
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-lanewatch.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/stall" "$T/run dir" "$T/wedged" "$T/stub" "$T/ps" \
  "$T/tmp" "$T/tmp/delegate-jobs" "$T/delegate-jobs" "$T/system-jobs"
DELEGATE_JOBS_DIR="$T/delegate-jobs"
JOB_RECORD_SYSTEM_DIR="$T/system-jobs"
TMPDIR="$T/tmp"
export DELEGATE_JOBS_DIR JOB_RECORD_SYSTEM_DIR TMPDIR
set_minute_mtime() {
  perl -e 'utime($ARGV[1], $ARGV[1], $ARGV[0]) or die "utime: $!"' "$1" "$2" \
    || fail "set settled log mtime $2"
}
settle_minute=$(( $(date +%s) / 60 * 60 - 660 ))

printf '111\n' >"$T/run/fiber-111-pi.pid"
printf '%s\n' \
  '{"type":"tool_execution_start","toolCallId":"c1","toolName":"bash"}' \
  '{"type":"queue_update"}' \
  '{"type":"response","command":"prompt","success":true,"data":{"status":"queued"}}' \
  >"$T/run/fiber-111-pi.jsonl"
printf '222\n' >"$T/run/fiber-222-pi.pid"
printf '%s\n' \
  '{"type":"tool_execution_start","toolCallId":"c2","toolName":"bash"}' \
  '{"type":"tool_execution_end","toolCallId":"c2"}' \
  '{"type":"agent_settled"}' \
  >"$T/run/fiber-222-pi.jsonl"
printf '444\n' >"$T/stall/fiber-444-pi.pid"
printf '{"type":"message_update"}\n' >"$T/stall/fiber-444-pi.jsonl"
touch -t 200001010000 "$T/stall/fiber-444-pi.jsonl"
printf '222\n' >"$T/run dir/fiber-222-pi.pid"
cp "$T/run/fiber-222-pi.jsonl" "$T/run dir/fiber-222-pi.jsonl"
set_minute_mtime "$T/run/fiber-222-pi.jsonl" "$settle_minute"
set_minute_mtime "$T/run dir/fiber-222-pi.jsonl" "$settle_minute"
printf '3333\n' >"$T/wedged/fiber-3333-pi.pid"
printf 'pi\n' >"$T/ps/3333.comm"
printf 'S 01:23\n' >"$T/ps/3333.info"
printf '%s\n' \
  '{"type":"agent_settled"}' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  >"$T/wedged/fiber-3333-pi.jsonl"
set_minute_mtime "$T/wedged/fiber-3333-pi.jsonl" "$settle_minute"
for pid in 111 222 444; do
  printf 'pi\n' >"$T/ps/$pid.comm"
  printf 'S 01:23\n' >"$T/ps/$pid.info"
done

write_ps_stub "$T/stub" "$T/ps"
export PATH="$T/stub:$PATH"

expect_invalid_interval() {
  interval_value=$1
  LANEWATCH_INTERVAL="$interval_value" bash "$LANEWATCH" --once "$T/run" \
    >"$T/interval.out" 2>"$T/interval.err"; rc=$?
  [ "$rc" = 2 ] || fail "invalid interval $interval_value exits 2 (got $rc)"
  [ ! -s "$T/interval.out" ] || fail "invalid interval $interval_value prints no stdout"
  expected='lanewatch: LANEWATCH_INTERVAL must be a non-negative integer'
  [ "$(<"$T/interval.err")" = "$expected" ] \
    || fail "invalid interval $interval_value prints one diagnostic: [$(<"$T/interval.err")]"
}
expect_invalid_interval abc
expect_invalid_interval -1
expect_invalid_interval $'abc\ndef'

bash "$LANEWATCH" --once "$T/run" >"$T/local.out" 2>"$T/local.err"; rc=$?
[ "$rc" = 0 ] || fail "local --once exits 0 (got $rc; $(<"$T/local.err"))"
[ "$(wc -l <"$T/local.out" | tr -d ' ')" = 1 ] \
  || fail "local --once prints one settled row: [$(<"$T/local.out")]"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ local lane 222 .*SETTLED$' "$T/local.out" \
  || fail "local --once identifies settled lane 222: [$(<"$T/local.out")]"
if grep -Eq '111 .*IN-TOOL' "$T/local.out"; then
  fail "local --once omits a lane still in a tool call: [$(<"$T/local.out")]"
fi

bash "$LANEWATCH" --once "$T/stall" >"$T/stall.out" 2>"$T/stall.err"; rc=$?
[ "$rc" = 0 ] || fail "stall --once exits 0 (got $rc; $(<"$T/stall.err"))"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ local lane 444 .*STALL no tool, not settled$' "$T/stall.out" \
  || fail "stall --once reports lane 444: [$(<"$T/stall.out")]"
bash "$LANEWATCH" --once "$T/wedged" >"$T/wedged.out" 2>"$T/wedged.err"; rc=$?
[ "$rc" = 0 ] || fail "wedged --once exits 0 (got $rc; $(<"$T/wedged.err"))"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ local lane 3333 .*WEDGED last=none$' "$T/wedged.out" \
  || fail "watcher reports a wedged lane: [$(<"$T/wedged.out")]"

# sleep ends the foreground watcher after three cycles; the 20-call hard cap
# prevents a regression from hanging this test. Its PPID is the lanewatch bash.
cat >"$T/stub/sleep" <<'STUB'
#!/bin/sh
count=0
if [ -f "$SLEEP_COUNT_FILE" ]; then
  IFS= read -r count <"$SLEEP_COUNT_FILE" || [ -n "${count:-}" ]
fi
count=$((count + 1))
printf '%s\n' "$count" >"$SLEEP_COUNT_FILE"
printf '%s\n' "$1" >>"$SLEEP_LOG"
if [ -n "${SLEEP_UPDATE_FILE:-}" ] && [ "$count" -eq "${SLEEP_UPDATE_COUNT:-0}" ]; then
  perl -e 'utime($ARGV[1], $ARGV[1], $ARGV[0]) or die "utime: $!"' \
    "$SLEEP_UPDATE_FILE" "$SLEEP_UPDATE_EPOCH"
fi
if [ "$count" -ge 20 ]; then
  kill -9 "$PPID"
elif [ "$count" -eq "${SLEEP_STOP_AT:-3}" ]; then
  kill "$PPID"
fi
STUB
chmod +x "$T/stub/sleep"
PATH="$T/stub:$PATH" LANEWATCH_INTERVAL=0 SLEEP_LOG="$T/sleeps-zero" \
  SLEEP_COUNT_FILE="$T/sleep-count-zero" bash "$LANEWATCH" "$T/run" \
  >"$T/dedup.out" 2>"$T/dedup.err"
loop_rc=$?
[ "$(wc -l <"$T/sleeps-zero" | tr -d ' ')" = 3 ] \
  || fail "zero-interval watcher sleeps three times (rc=$loop_rc)"
[ "$(grep -c '^0$' "$T/sleeps-zero")" = 3 ] \
  || fail "zero-interval watcher passes 0 to each sleep"
[ "$(grep -Ec '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ local lane 222 .*SETTLED$' "$T/dedup.out")" = 1 ] \
  || fail "settled lane prints once across three cycles: [$(<"$T/dedup.out")]"
if grep -Eq '111 .*IN-TOOL' "$T/dedup.out"; then
  fail "watcher omits an active tool lane: [$(<"$T/dedup.out")]"
fi
PATH="$T/stub:$PATH" LANEWATCH_INTERVAL=0 SLEEP_LOG="$T/sleeps-minute" \
  SLEEP_COUNT_FILE="$T/sleep-count-minute" SLEEP_STOP_AT=2 \
  SLEEP_UPDATE_COUNT=1 SLEEP_UPDATE_FILE="$T/run/fiber-222-pi.jsonl" \
  SLEEP_UPDATE_EPOCH="$((settle_minute + 60))" bash "$LANEWATCH" "$T/run" \
  >"$T/dedup-minute.out" 2>"$T/dedup-minute.err"
minute_loop_rc=$?
[ "$(grep -Ec '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ local lane 222 .*SETTLED$' "$T/dedup-minute.out")" = 2 ] \
  || fail "a new settle minute announces again (rc=$minute_loop_rc): [$(<"$T/dedup-minute.out")]"

PATH="$T/stub:$PATH" SLEEP_LOG="$T/sleeps-default" \
  SLEEP_COUNT_FILE="$T/sleep-count-default" bash "$LANEWATCH" "$T/run" \
  >"$T/default-interval.out" 2>"$T/default-interval.err"
default_loop_rc=$?
[ "$(wc -l <"$T/sleeps-default" | tr -d ' ')" = 3 ] \
  || fail "default-interval watcher sleeps three times (rc=$default_loop_rc)"
[ "$(grep -c '^120$' "$T/sleeps-default")" = 3 ] \
  || fail "default interval is 120 seconds"

cat >"$T/stub/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >"$SSH_ARGS_FILE"
cat >"$SSH_STDIN_FILE"
# The failed command's partial output must be discarded with the error.
printf '222      222      S 01:23 age=5 SETTLED\n'
if [ "$SSH_MODE" = fail ]; then
  exit 255
fi
exit 0
STUB
chmod +x "$T/stub/ssh"
remote_run="$T/run dir"
PATH="$T/stub:$PATH" SSH_MODE=fail SSH_ARGS_FILE="$T/ssh.args" \
  SSH_STDIN_FILE="$T/ssh.stdin" bash "$LANEWATCH" --once "$remote_run" box.example \
  >"$T/remote-fail.out" 2>"$T/remote-fail.err"; rc=$?
[ "$rc" = 0 ] || fail "remote failure --once exits 0 (got $rc)"
[ "$(strip_timestamp <"$T/remote-fail.out")" = 'WATCH-ERROR box.example lanestat exit 255' ] \
  || fail "ssh failure prints WATCH-ERROR and discards partial output: [$(<"$T/remote-fail.out")]"
remote_quoted=
printf -v remote_quoted '%q' "$remote_run"
printf '%s\n' -o BatchMode=yes -o ConnectTimeout=20 box.example bash -s -- "$remote_quoted" \
  >"$T/ssh.expected-args"
cmp -s "$T/ssh.expected-args" "$T/ssh.args" \
  || fail "ssh gets options, target and escaped run dir: [$(<"$T/ssh.args")]"
cmp -s "$LANESTAT" "$T/ssh.stdin" || fail "ssh receives bin/lanestat on stdin"

PATH="$T/stub:$PATH" SSH_MODE=success SSH_ARGS_FILE="$T/ssh.args" \
  SSH_STDIN_FILE="$T/ssh.stdin" bash "$LANEWATCH" --once "$remote_run" box.example \
  >"$T/remote-success.out" 2>"$T/remote-success.err"; rc=$?
[ "$rc" = 0 ] || fail "remote success --once exits 0 (got $rc)"
[ "$(wc -l <"$T/remote-success.out" | tr -d ' ')" = 1 ] \
  || fail "remote success prints one settled row: [$(<"$T/remote-success.out")]"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ box.example lane 222 .*SETTLED$' "$T/remote-success.out" \
  || fail "remote success uses ssh target as label: [$(<"$T/remote-success.out")]"

bash "$LANEWATCH" --once "$T/no-such-run" >"$T/local-fail.out" 2>"$T/local-fail.err"; rc=$?
[ "$rc" = 0 ] || fail "local failure --once exits 0 (got $rc)"
[ "$(strip_timestamp <"$T/local-fail.out")" = 'WATCH-ERROR local lanestat exit 2' ] \
  || fail "local lanestat failure prints WATCH-ERROR: [$(<"$T/local-fail.out")]"
bash "$LANEWATCH" >"$T/no-args.out" 2>"$T/no-args.err"; rc=$?
[ "$rc" = 2 ] || fail "missing run dir exits 2 (got $rc)"
bash "$LANEWATCH" --once >"$T/once-only.out" 2>"$T/once-only.err"; rc=$?
[ "$rc" = 2 ] || fail "--once without run dir exits 2 (got $rc)"
bash "$LANEWATCH" --once "$T/run" box.example extra >"$T/extra.out" 2>"$T/extra.err"; rc=$?
[ "$rc" = 2 ] || fail "extra argument exits 2 (got $rc)"

echo 'lanewatch: all cases passed'

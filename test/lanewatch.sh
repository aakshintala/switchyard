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
  "$T/tmp" "$T/tmp/delegate-jobs" "$T/delegate-jobs" "$T/system-jobs" "$T/home/.agents/bin"
DELEGATE_JOBS_DIR="$T/delegate-jobs"
JOB_RECORD_SYSTEM_DIR="$T/system-jobs"
TMPDIR="$T/tmp"
HOME="$T/home"
cp "$SCRIPT_DIR/../bin/inbox-send" "$HOME/.agents/bin/inbox-send"
export DELEGATE_JOBS_DIR JOB_RECORD_SYSTEM_DIR TMPDIR HOME
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
for arg do cmd=$arg; done
case $cmd in
  *inbox-send*)
    if [ -n "${SSH_FAIL_FILE:-}" ] && [ ! -e "$SSH_FAIL_FILE" ]; then exit 255; fi
    exec bash -c "$cmd"
    ;;
esac
cat >"$SSH_STDIN_FILE"
# The failed command's partial output must be discarded with the error.
if [ -n "${SSH_OUTPUT:-}" ]; then
  printf '%s\n' "$SSH_OUTPUT"
else
  printf '222      222      S 01:23 age=5 SETTLED\n'
fi
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

watch_lane() {
  local run_dir=$1 lane_pid=$2
  mkdir -p "$run_dir"
  printf '%s\n' "$lane_pid" >"$run_dir/fiber-$lane_pid-pi.pid"
  printf 'pi\n' >"$T/ps/$lane_pid.comm"
  printf 'S 00:01\n' >"$T/ps/$lane_pid.info"
  : >"$run_dir/fiber-$lane_pid-pi.jsonl"
}
watch_ruling() {
  local run_dir=$1 lane_pid=$2 epoch=$3
  printf 'ruling fixture\n' >"$run_dir/switchyard-$lane_pid-ruling-1.md"
  set_minute_mtime "$run_dir/switchyard-$lane_pid-ruling-1.md" "$epoch"
}
watch_message() {
  local file=$1 timestamp=$2 text=$3
  printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"%s"}],"timestamp":%s}}\n' \
    "$text" "$timestamp" >>"$file"
}
count_inbox_files() {
  [ -d "$1" ] || { printf '0\n'; return; }
  find "$1" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' '
}

# PARK, LOOP, WEDGED and DEAD-PROVIDER are sent to the inbox; other rows stay stdout-only.
events="$T/events"
answered="$T/answered"
loop_run="$T/loop-events"
wedged_run="$T/wedged-events"
dead_run="$T/dead-events"
plain_run="$T/plain-events"
watch_lane "$events" 2001
printf '%s\n' '{"type":"tool_execution_start","toolCallId":"t","toolName":"bash"}' \
  >"$events/fiber-2001-pi.jsonl"
watch_message "$events/fiber-2001-pi.jsonl" 1700000200000 'Which?'
printf '{"type":"agent_settled"}\n' >>"$events/fiber-2001-pi.jsonl"
watch_ruling "$events" 2001 1700000100
set_minute_mtime "$events/fiber-2001-pi.jsonl" "$settle_minute"
watch_lane "$answered" 2002
watch_message "$answered/fiber-2002-pi.jsonl" 1700000000000 'Which?'
printf '{"type":"agent_settled"}\n' >>"$answered/fiber-2002-pi.jsonl"
watch_ruling "$answered" 2002 1700000001
set_minute_mtime "$answered/fiber-2002-pi.jsonl" "$settle_minute"
watch_repo="$T/watch-worktree"
mkdir -p "$watch_repo"
git -C "$watch_repo" init -q || fail "initialize watcher worktree fixture"
git -C "$watch_repo" config user.name 'Switchyard Test' || fail "configure watcher worktree"
git -C "$watch_repo" config user.email 'switchyard-test@example.invalid' || fail "configure watcher worktree"
printf 'fixture\n' >"$watch_repo/file"
git -C "$watch_repo" add file || fail "add watcher worktree fixture"
GIT_AUTHOR_DATE='@1700000100 +0000' GIT_COMMITTER_DATE='@1700000100 +0000' \
  git -C "$watch_repo" commit -q -m fixture </dev/null || fail "commit watcher worktree fixture"
watch_lane "$loop_run" 2003
watch_message "$loop_run/fiber-2003-pi.jsonl" 1700000200000 'No question.'
printf '%s\n' '{"type":"agent_settled"}' '{"type":"agent_settled"}' \
  >>"$loop_run/fiber-2003-pi.jsonl"
watch_ruling "$loop_run" 2003 1700000100
printf 'worktree=%s\n' "$watch_repo" >"$loop_run/switchyard-2003.state"
set_minute_mtime "$loop_run/fiber-2003-pi.jsonl" "$settle_minute"
watch_lane "$wedged_run" 2004
printf '%s\n' \
  '{"type":"agent_settled"}' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  >"$wedged_run/fiber-2004-pi.jsonl"
set_minute_mtime "$wedged_run/fiber-2004-pi.jsonl" "$settle_minute"
watch_lane "$dead_run" 2005
printf '%s\n' \
  '{"type":"auto_retry_end","success":false,"finalError":"provider PARK LOOP SETTLED"}' \
  '{"type":"agent_settled"}' \
  >"$dead_run/fiber-2005-pi.jsonl"
set_minute_mtime "$dead_run/fiber-2005-pi.jsonl" "$settle_minute"
watch_lane "$plain_run" 2006
printf '{"type":"agent_settled"}\n' >"$plain_run/fiber-2006-pi.jsonl"
set_minute_mtime "$plain_run/fiber-2006-pi.jsonl" "$settle_minute"

LANEWATCH_INBOX="$T/inbox-park" bash "$LANEWATCH" --once "$events" >"$T/park-event.out" 2>"$T/park-event.err"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ local lane 2001 .*age=[0-9]+.*SETTLED PARK last=bash$' "$T/park-event.out" \
  || fail "PARK row names lane, last tool and age: [$(<"$T/park-event.out")]"
[ "$(count_inbox_files "$T/inbox-park")" = 1 ] || fail "PARK sends one inbox message"
grep -q 'local lane 2001 .*age=.*SETTLED PARK last=bash' "$T/inbox-park"/*.md \
  || fail "PARK inbox body is the dated lane row"
LANEWATCH_INBOX="$T/inbox-answered" bash "$LANEWATCH" --once "$answered" \
  >"$T/answered-event.out" 2>"$T/answered-event.err"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ local lane 2002 .*SETTLED$' "$T/answered-event.out" \
  || fail "answered PARK leaves a plain settled row"
if grep -q 'PARK' "$T/answered-event.out"; then fail "answered PARK is not announced"; fi
[ ! -e "$T/inbox-answered" ] || fail "answered PARK sends no inbox message"
LANEWATCH_INBOX="$T/inbox-loop" LANEWATCH_INTERVAL=0 SLEEP_LOG="$T/loop-sleeps" \
  SLEEP_COUNT_FILE="$T/loop-sleep-count" bash "$LANEWATCH" "$loop_run" \
  >"$T/loop-event.out" 2>"$T/loop-event.err"
[ "$(count_inbox_files "$T/inbox-loop")" = 1 ] || fail "LOOP sends one inbox message"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ local lane 2003 .*SETTLED LOOP last=none$' "$T/loop-event.out" \
  || fail "LOOP is announced once and does not stop the lane"
[ "$(PATH="$T/stub:$PATH" ps -o comm= -p 2003)" = pi ] || fail "LOOP leaves the lane process stub untouched"
sh "$LANESTAT" "$loop_run" >"$T/loop-next.out"
grep -Eq '^2003[[:space:]].*SETTLED LOOP last=none$' "$T/loop-next.out" \
  || fail "LOOP lane still appears on the next lanestat cycle"
LANEWATCH_INBOX="$T/inbox-wedged" bash "$LANEWATCH" --once "$wedged_run" \
  >"$T/wedged-event.out" 2>"$T/wedged-event.err"
[ "$(count_inbox_files "$T/inbox-wedged")" = 1 ] || fail "WEDGED sends one inbox message"
LANEWATCH_INBOX="$T/inbox-dead" bash "$LANEWATCH" --once "$dead_run" \
  >"$T/dead-event.out" 2>"$T/dead-event.err"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ local lane 2005 .*DEAD-PROVIDER provider PARK LOOP SETTLED$' "$T/dead-event.out" \
  || fail "DEAD-PROVIDER forwards its whole row without token-scanning the message"
[ "$(count_inbox_files "$T/inbox-dead")" = 1 ] || fail "DEAD-PROVIDER sends one inbox message"
LANEWATCH_INBOX="$T/inbox-plain" bash "$LANEWATCH" --once "$plain_run" \
  >"$T/plain-event.out" 2>"$T/plain-event.err"
[ "$(wc -l <"$T/plain-event.out" | tr -d ' ')" = 1 ] || fail "plain SETTLED still prints"
[ ! -e "$T/inbox-plain" ] || fail "plain SETTLED sends no inbox message"
LANEWATCH_INBOX="$T/inbox-stall" bash "$LANEWATCH" --once "$T/stall" \
  >"$T/stall-inbox.out" 2>"$T/stall-inbox.err"
[ ! -e "$T/inbox-stall" ] || fail "STALL sends no inbox message"
running_run="$T/running-events"
watch_lane "$running_run" 2011
printf '{"type":"tool_execution_start","toolCallId":"t","toolName":"bash"}\n' \
  >"$running_run/fiber-2011-pi.jsonl"
LANEWATCH_INBOX="$T/inbox-running" bash "$LANEWATCH" --once "$running_run" \
  >"$T/running-inbox.out" 2>"$T/running-inbox.err"
[ ! -e "$T/inbox-running" ] || fail "running lanes send no inbox message"
[ ! -s "$T/running-inbox.out" ] || fail "plain running lane prints no event"
watch_lane "$T/combined" 2007
printf '%s\n' '{"type":"tool_execution_start","toolCallId":"t","toolName":"bash"}' \
  >"$T/combined/fiber-2007-pi.jsonl"
watch_message "$T/combined/fiber-2007-pi.jsonl" 1700000200000 'Which?'
printf '%s\n' '{"type":"agent_settled"}' '{"type":"agent_settled"}' \
  >>"$T/combined/fiber-2007-pi.jsonl"
watch_ruling "$T/combined" 2007 1700000100
printf 'worktree=%s\n' "$watch_repo" >"$T/combined/switchyard-2007.state"
set_minute_mtime "$T/combined/fiber-2007-pi.jsonl" "$settle_minute"
LANEWATCH_INBOX="$T/inbox-combined" bash "$LANEWATCH" --once "$T/combined" \
  >"$T/combined-event.out" 2>"$T/combined-event.err"
[ "$(wc -l <"$T/combined-event.out" | tr -d ' ')" = 1 ] \
  || fail "PARK and LOOP on one row print one line"
[ "$(count_inbox_files "$T/inbox-combined")" = 1 ] \
  || fail "PARK and LOOP on one row send one inbox message"
grep -q 'SETTLED PARK LOOP last=bash' "$T/inbox-combined"/*.md \
  || fail "combined inbox row preserves all event tokens"
LANEWATCH_INBOX='' bash "$LANEWATCH" --once "$wedged_run" \
  >"$T/empty-inbox.out" 2>"$T/empty-inbox.err"
[ ! -e "$T/empty-inbox" ] || fail "empty inbox setting creates no directory"
grep -q 'local lane 2004 .*WEDGED' "$T/empty-inbox.out" \
  || fail "empty inbox setting preserves stdout events"

# A sorted id set deduplicates DONE-UNREAD independently of settle minutes.
done_id=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
second_id=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
printf '{"status":"RUNNING"}\n' >"$DELEGATE_JOBS_DIR/$done_id.json"
done_run="$T/done-events"
watch_lane "$done_run" 2010
printf '{"type":"tool_execution_end","toolCallId":"job","result":"%s"}\n' "$done_id" \
  >"$done_run/fiber-2010-pi.jsonl"
printf '{"type":"agent_settled"}\n' >>"$done_run/fiber-2010-pi.jsonl"
set_minute_mtime "$done_run/fiber-2010-pi.jsonl" "$settle_minute"
mkdir -p "$T/stub-events"
cat >"$T/stub-events/sleep" <<'STUB'
#!/bin/sh
count=0
if [ -f "$SLEEP_COUNT_FILE" ]; then
  IFS= read -r count <"$SLEEP_COUNT_FILE" || [ -n "${count:-}" ]
fi
count=$((count + 1))
printf '%s\n' "$count" >"$SLEEP_COUNT_FILE"
case $count in
  1) printf '{"status":"DONE"}\n' >"$DONE_JOB1" ;;
  3)
    printf '{"status":"DONE"}\n' >"$DONE_JOB2"
    printf '{"type":"tool_execution_end","toolCallId":"job2","result":"%s"}\n' "$DONE_ID2" \
      >>"$DONE_JSONL"
    ;;
  4) perl -e 'utime($ARGV[1], $ARGV[1], $ARGV[0]) or die "utime: $!"' "$DONE_JSONL" "$DONE_NEXT_MINUTE" ;;
esac
if [ "$count" -eq 5 ]; then kill "$PPID"; fi
STUB
chmod +x "$T/stub-events/sleep"
PATH="$T/stub-events:$T/stub:$PATH" LANEWATCH_INTERVAL=0 LANEWATCH_INBOX="$T/inbox-done" \
  SLEEP_COUNT_FILE="$T/done-sleep-count" DONE_JOB1="$DELEGATE_JOBS_DIR/$done_id.json" \
  DONE_JOB2="$DELEGATE_JOBS_DIR/$second_id.json" DONE_ID2="$second_id" \
  DONE_JSONL="$done_run/fiber-2010-pi.jsonl" DONE_NEXT_MINUTE="$((settle_minute + 60))" \
  bash "$LANEWATCH" "$done_run" >"$T/done-events.out" 2>"$T/done-events.err"
[ "$(count_inbox_files "$T/inbox-done")" = 2 ] \
  || fail "new finished job ids deliver once, unchanged set never redelivers"
[ "$(grep -Ec 'local lane 2010 .*SETTLED$' "$T/done-events.out")" = 1 ] \
  || fail "the first settled poll prints without DONE-UNREAD"
[ "$(grep -c "DONE-UNREAD $done_id" "$T/done-events.out")" = 3 ] \
  || fail "DONE-UNREAD prints on first finish, new id set and new settle minute"
[ "$(grep -c "DONE-UNREAD $done_id $second_id" "$T/done-events.out")" = 2 ] \
  || fail "the sorted second job set is repeated without another delivery"
for message in "$T/inbox-done"/*.md; do
  grep -q 'local lane 2010 .*age=.*DONE-UNREAD' "$message" \
    || fail "DONE-UNREAD inbox body names its lane and age: [$message]"
done

# Token parsing never mistakes a tool name or DEAD-PROVIDER message for a kind.
padded='321 321 S 01:23 age=40    SETTLED  PARK  last=bash'
LANEWATCH_INBOX="$T/inbox-padded" SSH_MODE=success SSH_OUTPUT="$padded" \
  SSH_ARGS_FILE="$T/ssh.args" SSH_STDIN_FILE="$T/ssh.stdin" \
  bash "$LANEWATCH" --once "$remote_run" box.example >"$T/padded.out" 2>"$T/padded.err"
[ "$(count_inbox_files "$T/inbox-padded")" = 1 ] || fail "padded row recognizes PARK"
grep -q 'SETTLED  PARK  last=bash' "$T/inbox-padded"/*.md \
  || fail "padded row body keeps its tokens"
single='321 321 S 01:23 age=40 SETTLED PARK last=bash'
LANEWATCH_INBOX="$T/inbox-single" SSH_MODE=success SSH_OUTPUT="$single" \
  SSH_ARGS_FILE="$T/ssh.args" SSH_STDIN_FILE="$T/ssh.stdin" \
  bash "$LANEWATCH" --once "$remote_run" box.example >"$T/single.out" 2>"$T/single.err"
[ "$(count_inbox_files "$T/inbox-single")" = 1 ] || fail "single-space row recognizes PARK"
no_tokens=$'321 321 S 01:23 age=40 IN-TOOL SETTLED\n322 322 S 01:23 age=40 SETTLED last=PARK\n323 323 S 01:23 age=40 SETTLED last=LOOP\n324 324 S 01:23 age=40 RUNNING last=LOOP'
LANEWATCH_INBOX="$T/inbox-no-token" SSH_MODE=success SSH_OUTPUT="$no_tokens" \
  SSH_ARGS_FILE="$T/ssh.args" SSH_STDIN_FILE="$T/ssh.stdin" \
  bash "$LANEWATCH" --once "$remote_run" box.example >"$T/no-token.out" 2>"$T/no-token.err"
[ "$(count_inbox_files "$T/inbox-no-token")" = 0 ] \
  || fail "tool names never trigger PARK or LOOP delivery"
[ "$(wc -l <"$T/no-token.out" | tr -d ' ')" = 2 ] \
  || fail "only the two plain settled rows are recognized"

# A failed remote inbox send stays unseen and retries after the host recovers.
mkdir -p "$T/stub-retry"
cat >"$T/stub-retry/sleep" <<'STUB'
#!/bin/sh
count=0
if [ -f "$SLEEP_COUNT_FILE" ]; then
  IFS= read -r count <"$SLEEP_COUNT_FILE" || [ -n "${count:-}" ]
fi
count=$((count + 1))
printf '%s\n' "$count" >"$SLEEP_COUNT_FILE"
if [ "$count" -eq 1 ]; then touch "$SSH_FAIL_FILE"; fi
if [ "$count" -eq 2 ]; then kill "$PPID"; fi
STUB
chmod +x "$T/stub-retry/sleep"
retry_enable="$T/ssh-retry-enable"
rm -f "$retry_enable"
PATH="$T/stub-retry:$T/stub:$PATH" LANEWATCH_INTERVAL=0 \
  LANEWATCH_INBOX="$T/inbox-remote-retry" INBOX_HOST=mac-host \
  SSH_FAIL_FILE="$retry_enable" SSH_MODE=success SSH_ARGS_FILE="$T/ssh.args" \
  SSH_STDIN_FILE="$T/ssh.stdin" SLEEP_COUNT_FILE="$T/ssh-retry-sleeps" \
  bash "$LANEWATCH" "$events" >"$T/ssh-retry.out" 2>"$T/ssh-retry.err"
[ "$(count_inbox_files "$T/inbox-remote-retry")" = 1 ] \
  || fail "remote inbox retry delivers after the host recovers"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ WATCH-ERROR local inbox-send exit 255$' "$T/ssh-retry.out" \
  || fail "failed inbox send prints a dated WATCH-ERROR: [$(<"$T/ssh-retry.out")]"
[ "$(grep -c 'local lane 2001 .*SETTLED PARK last=bash' "$T/ssh-retry.out")" = 2 ] \
  || fail "failed delivery leaves PARK unseen for retry"

echo 'lanewatch: all cases passed'

#!/usr/bin/env bash
# Tests bin/lanestat against a fixture run dir, never a live lane directory.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/ps-stub.sh"
LANESTAT="${LANESTAT:-$SCRIPT_DIR/../bin/lanestat}"
fail() { echo "FAIL: $1" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/test-lanestat.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/empty" "$T/stub" "$T/ps" \
  "$T/tmp" "$T/tmp/delegate-jobs" "$T/delegate-jobs" "$T/system-jobs"
DELEGATE_JOBS_DIR="$T/delegate-jobs"
JOB_RECORD_SYSTEM_DIR="$T/system-jobs"
TMPDIR="$T/tmp"
export DELEGATE_JOBS_DIR JOB_RECORD_SYSTEM_DIR TMPDIR

# The ordered keys are intentional: lanestat's toolName grep expects
# "type":"tool_execution_start","toolCallId":"..","toolName":"..".
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
printf '333\n' >"$T/run/fiber-333-pi.pid"
cp "$T/run/fiber-222-pi.jsonl" "$T/run/fiber-333-pi.jsonl"
printf '444\n' >"$T/run/fiber-444-pi.pid"
printf '{"type":"message_update"}\n' >"$T/run/fiber-444-pi.jsonl"
touch -t 200001010000 "$T/run/fiber-444-pi.jsonl"
printf '555\n' >"$T/run/fiber-555-pi.pid"
printf '{"type":"message_update"}\n' >"$T/run/fiber-555-pi.jsonl"

for pid in 111 222 444 555; do
  printf 'pi\n' >"$T/ps/$pid.comm"
  printf 'S 01:23\n' >"$T/ps/$pid.info"
done
printf '/usr/local/bin/pi\n' >"$T/ps/111.comm"
printf 'node\n' >"$T/ps/333.comm"
printf 'S 01:23\n' >"$T/ps/333.info"

# Separate fixtures for settled-threshold cases.
mkdir -p "$T/settled-run"
for pid in 610 611; do
  printf '%s\n' "$pid" >"$T/settled-run/fiber-$pid-pi.pid"
  printf 'pi\n' >"$T/ps/$pid.comm"
  printf 'S 01:23\n' >"$T/ps/$pid.info"
done
printf '%s\n' '{"type":"agent_settled"}' >"$T/settled-run/fiber-610-pi.jsonl"
printf '%s\n' '{"type":"message_update"}' >"$T/settled-run/fiber-611-pi.jsonl"

write_ps_stub "$T/stub" "$T/ps"

# Fix the reported clock so the strict 300-second boundary can be tested on
# both BSD and GNU systems. The production script still gets mtime from Perl.
NOW="$(date +%s)"
cat >"$T/stub/date" <<'STUB'
#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = +%s ]; then
  printf '%s\n' "$LANESTAT_TEST_NOW"
else
  exec /bin/date "$@"
fi
STUB
chmod +x "$T/stub/date"
run_stat() { PATH="$T/stub:$PATH" LANESTAT_TEST_NOW="$NOW" sh "$LANESTAT" "$@"; }

run_stat "$T/run" >"$T/default.out" 2>"$T/default.err"; rc=$?
[ "$rc" = 0 ] || fail "lanestat exits 0 on a run dir (got $rc; $(<"$T/default.err"))"
out="$(<"$T/default.out")"
assert_row() {
  field=$1
  pattern=$2
  rows=$3
  line="$(printf '%s\n' "$rows" | grep -E "^${field}[[:space:]]" || true)"
  [ -n "$line" ] || fail "row $field is present: [$rows]"
  printf '%s\n' "$line" | grep -Eq "$pattern" || fail "row $field matches $pattern: [$line]"
}
assert_no_row() {
  field=$1
  rows=$2
  if printf '%s\n' "$rows" | grep -Eq "^${field}[[:space:]]"; then
    fail "row $field is absent: [$rows]"
  fi
}
assert_row 111 'IN-TOOL bash$' "$out"
assert_row 222 'SETTLED$' "$out"
assert_no_row 333 "$out"
assert_row 444 'STALL no tool, not settled$' "$out"
assert_row 555 'RUNNING$' "$out"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 4 ] \
  || fail "without --all prints only the four live pi lanes: [$out]"

run_stat --all "$T/run" >"$T/all-before.out" 2>"$T/all-before.err"; rc=$?
[ "$rc" = 0 ] || fail "--all before run dir exits 0 (got $rc)"
run_stat "$T/run" --all >"$T/all-after.out" 2>"$T/all-after.err"; rc=$?
[ "$rc" = 0 ] || fail "--all after run dir exits 0 (got $rc)"
cmp -s "$T/all-before.out" "$T/all-after.out" || fail "--all works before or after run dir"
assert_row 333 '333[[:space:]]+333[[:space:]]+DEAD$' "$(<"$T/all-before.out")"

# At 299 and 300 seconds there is no stall; just above 300 there is.
set_age() {
  perl -e 'my $t = $ARGV[1] - $ARGV[2]; utime($t, $t, $ARGV[0]) or die "utime: $!"' \
    "$T/run/fiber-555-pi.jsonl" "$NOW" "$1" || fail "set fixture age $1"
}
set_age 299
run_stat "$T/run" >"$T/age-299.out" 2>"$T/age-299.err"; rc=$?
[ "$rc" = 0 ] || fail "age 299 exits 0 (got $rc)"
assert_row 555 'age=299[[:space:]]+RUNNING$' "$(<"$T/age-299.out")"
set_age 300
run_stat "$T/run" >"$T/age-300.out" 2>"$T/age-300.err"; rc=$?
[ "$rc" = 0 ] || fail "age 300 exits 0 (got $rc)"
assert_row 555 'age=300[[:space:]]+RUNNING$' "$(<"$T/age-300.out")"
set_age 301
run_stat "$T/run" >"$T/age-301.out" 2>"$T/age-301.err"; rc=$?
[ "$rc" = 0 ] || fail "age 301 exits 0 (got $rc)"
assert_row 555 'age=301[[:space:]]+STALL no tool, not settled$' "$(<"$T/age-301.out")"

run_stat >"$T/no-args.out" 2>"$T/no-args.err"; rc=$?
[ "$rc" = 2 ] || fail "missing run dir exits 2 (got $rc)"
run_stat "$T/no-such-run" >"$T/missing.out" 2>"$T/missing.err"; rc=$?
[ "$rc" = 2 ] || fail "nonexistent run dir exits 2 (got $rc)"
[ ! -s "$T/missing.out" ] || fail "nonexistent run dir has empty stdout"
[ -s "$T/missing.err" ] || fail "nonexistent run dir explains the error"
printf 'not a directory\n' >"$T/not-a-dir"
run_stat "$T/not-a-dir" >"$T/not-dir.out" 2>"$T/not-dir.err"; rc=$?
[ "$rc" = 2 ] || fail "run path that is not a directory exits 2 (got $rc)"
run_stat "$T/run" extra >"$T/extra.out" 2>"$T/extra.err"; rc=$?
[ "$rc" = 2 ] || fail "extra argument exits 2 (got $rc)"
run_stat --all --all "$T/run" >"$T/duplicate-all.out" 2>"$T/duplicate-all.err"; rc=$?
[ "$rc" = 2 ] || fail "duplicate --all exits 2 (got $rc)"
run_stat "$T/empty" >"$T/empty.out" 2>"$T/empty.err"; rc=$?
[ "$rc" = 0 ] || fail "empty run dir exits 0 (got $rc)"
[ "$(<"$T/empty.out")" = "lanestat: no live lanes in $T/empty" ] \
  || fail 'case 9: zero-live-row message for empty and dead-only run dirs'

# Settled rows are flagged only when their jsonl age is strictly over the
# configured threshold. The clock and mtimes are fixed, without sleeping.
set_settled_age() {
  perl -e 'my $t = $ARGV[1] - $ARGV[2]; utime($t, $t, $ARGV[0]) or die "utime: $!"' \
    "$T/settled-run/fiber-610-pi.jsonl" "$NOW" "$1" || fail "set settled fixture age $1"
}
run_settled_case() {
  local label=$1 max=$2 age=$3 expected=$4 rc output
  set_settled_age "$age"
  if [ "$max" = unset ]; then
    env -u LANESTAT_SETTLED_MAX PATH="$T/stub:$PATH" LANESTAT_TEST_NOW="$NOW" \
      sh "$LANESTAT" "$T/settled-run" >"$T/settled-$label.out" 2>"$T/settled-$label.err"
  else
    env LANESTAT_SETTLED_MAX="$max" PATH="$T/stub:$PATH" LANESTAT_TEST_NOW="$NOW" \
      sh "$LANESTAT" "$T/settled-run" >"$T/settled-$label.out" 2>"$T/settled-$label.err"
  fi
  rc=$?
  [ "$rc" = 0 ] || fail "settled case $label exits 0 (got $rc; $(<"$T/settled-$label.err"))"
  output="$(<"$T/settled-$label.out")"
  assert_row 610 "age=$age[[:space:]]+$expected$" "$output"
}
run_settled_case default-below unset 7199 SETTLED
run_settled_case default-at unset 7200 SETTLED
run_settled_case default-above unset 7201 SETTLED-OLD
run_settled_case override-below 60 59 SETTLED
run_settled_case override-at 60 60 SETTLED
run_settled_case override-above 60 61 SETTLED-OLD
for invalid in empty abc negative decimal suffix; do
  case $invalid in
    empty) value=; label=empty ;;
    abc) value=abc; label=abc ;;
    negative) value=-5; label=negative ;;
    decimal) value=1.5; label=decimal ;;
    suffix) value=1h; label=suffix ;;
  esac
  run_settled_case "invalid-$label-at" "$value" 7200 SETTLED
  run_settled_case "invalid-$label-above" "$value" 7201 SETTLED-OLD
done
run_settled_case zero-at 0 0 SETTLED
run_settled_case zero-above 0 1 SETTLED-OLD

# A non-settled lane keeps its age-based state and never gets the marker.
perl -e 'my $t = $ARGV[1] - $ARGV[2]; utime($t, $t, $ARGV[0]) or die "utime: $!"' \
  "$T/settled-run/fiber-611-pi.jsonl" "$NOW" 7201 || fail "set non-settled fixture age"
env LANESTAT_SETTLED_MAX=60 PATH="$T/stub:$PATH" LANESTAT_TEST_NOW="$NOW" \
  sh "$LANESTAT" "$T/settled-run" >"$T/non-settled.out" 2>"$T/non-settled.err"; rc=$?
[ "$rc" = 0 ] || fail "non-settled case exits 0 (got $rc)"
assert_row 611 'age=7201[[:space:]]+STALL no tool, not settled$' "$(<"$T/non-settled.out")"

# The unflagged row retains the existing printf layout and exact state text.
run_settled_case format-under 60 59 SETTLED
expected="$(printf '%-6s %-8s %-18s age=%-6s %s' 610 610 'S 01:23' 59 SETTLED)"
actual="$(grep -E '^610[[:space:]]' "$T/settled-format-under.out")"
[ "$actual" = "$expected" ] || fail "under-threshold row keeps its exact format: [$actual]"

new_case() {
  case_name=$1
  case_pid=$2
  case_dir=$(mktemp -d "$T/$case_name.XXXXXX") || fail "create $case_name run dir"
  printf '%s\n' "$case_pid" >"$case_dir/fiber-$case_pid-pi.pid"
  printf 'pi\n' >"$T/ps/$case_pid.comm"
  printf 'S 00:01\n' >"$T/ps/$case_pid.info"
}
set_file_age() {
  perl -e 'my $t = $ARGV[1] - $ARGV[2]; utime($t, $t, $ARGV[0]) or die "utime: $!"' \
    "$1" "$NOW" "$2" || fail "set fixture age $2"
}
# Pairing keeps the outer call open when an inner call ends.
new_case case-1 701
printf '%s\n' \
  '{"type":"tool_execution_start","toolCallId":"A","toolName":"bash"}' \
  '{"type":"tool_execution_start","toolCallId":"B","toolName":"read"}' \
  '{"type":"tool_execution_end","toolCallId":"B"}' \
  >"$case_dir/fiber-701-pi.jsonl"
run_stat "$case_dir" >"$T/case-1.out" 2>"$T/case-1.err"; rc=$?
[ "$rc" = 0 ] || fail "case 1 exits 0 (got $rc)"
assert_row 701 'IN-TOOL bash$' "$(<"$T/case-1.out")"

# A queue update after the inner end does not hide the still-open outer call.
new_case case-2 702
printf '%s\n' \
  '{"type":"tool_execution_start","toolCallId":"A","toolName":"bash"}' \
  '{"type":"tool_execution_start","toolCallId":"B","toolName":"read"}' \
  '{"type":"tool_execution_end","toolCallId":"B"}' \
  '{"type":"queue_update"}' \
  >"$case_dir/fiber-702-pi.jsonl"
run_stat "$case_dir" >"$T/case-2.out" 2>"$T/case-2.err"; rc=$?
[ "$rc" = 0 ] || fail "case 2 exits 0 (got $rc)"
assert_row 702 'IN-TOOL bash$' "$(<"$T/case-2.out")"

# Settles, non-settling events, and events after a settle retain their order.
new_case case-3 703
printf '%s\n' \
  '{"type":"tool_execution_start","toolCallId":"A","toolName":"bash"}' \
  '{"type":"agent_settled"}' >"$case_dir/fiber-703-pi.jsonl"
run_stat "$case_dir" >"$T/case-3.out" 2>"$T/case-3.err"; rc=$?
[ "$rc" = 0 ] || fail "case 3 exits 0 (got $rc)"
assert_row 703 'SETTLED$' "$(<"$T/case-3.out")"

new_case case-4 704
printf '%s\n' \
  '{"type":"tool_execution_start","toolCallId":"A","toolName":"bash"}' \
  '{"type":"tool_execution_end","toolCallId":"A"}' \
  '{"type":"agent_settled"}' >"$case_dir/fiber-704-pi.jsonl"
run_stat "$case_dir" >"$T/case-4.out" 2>"$T/case-4.err"; rc=$?
[ "$rc" = 0 ] || fail "case 4 exits 0 (got $rc)"
assert_row 704 'SETTLED$' "$(<"$T/case-4.out")"

new_case case-5 705
printf '%s\n' \
  '{"type":"tool_execution_start","toolCallId":"A","toolName":"bash"}' \
  '{"type":"tool_execution_end","toolCallId":"A"}' \
  '{"type":"queue_update"}' >"$case_dir/fiber-705-pi.jsonl"
set_file_age "$case_dir/fiber-705-pi.jsonl" 0
run_stat "$case_dir" >"$T/case-5-fresh.out" 2>"$T/case-5-fresh.err"; rc=$?
[ "$rc" = 0 ] || fail "case 5 fresh exits 0 (got $rc)"
assert_row 705 'RUNNING$' "$(<"$T/case-5-fresh.out")"
set_file_age "$case_dir/fiber-705-pi.jsonl" 301
run_stat "$case_dir" >"$T/case-5-aged.out" 2>"$T/case-5-aged.err"; rc=$?
[ "$rc" = 0 ] || fail "case 5 aged exits 0 (got $rc)"
assert_row 705 'STALL no tool, not settled$' "$(<"$T/case-5-aged.out")"

new_case case-6 706
printf '%s\n' \
  '{"type":"tool_execution_start","toolCallId":"A","toolName":"bash"}' \
  '{"type":"agent_settled"}' \
  '{"type":"tool_execution_start","toolCallId":"B","toolName":"B"}' \
  >"$case_dir/fiber-706-pi.jsonl"
run_stat "$case_dir" >"$T/case-6.out" 2>"$T/case-6.err"; rc=$?
[ "$rc" = 0 ] || fail "case 6 exits 0 (got $rc)"
assert_row 706 'IN-TOOL B$' "$(<"$T/case-6.out")"

new_case case-7 707
printf '%s\n' \
  '{"type":"tool_execution_start","toolCallId":"A","toolName":"bash"}' \
  '{"type":"agent_settled"}' \
  '{"type":"tool_execution_start","toolCallId":"B","toolName":"read"}' \
  '{"type":"tool_execution_end","toolCallId":"B"}' \
  >"$case_dir/fiber-707-pi.jsonl"
run_stat "$case_dir" >"$T/case-7.out" 2>"$T/case-7.err"; rc=$?
[ "$rc" = 0 ] || fail "case 7 exits 0 (got $rc)"
assert_row 707 'RUNNING$' "$(<"$T/case-7.out")"

new_case case-8 708
printf '%s\n' '{"type":"tool_execution_start","toolCallId":"A","toolName":"bash"}' \
  >"$case_dir/fiber-708-pi.jsonl"
perl -e 'my $pad = "x" x 1000; print qq({"type":"message_update","pad":"$pad"}) . chr(10) for 0..20000' \
  >>"$case_dir/fiber-708-pi.jsonl" || fail "write case 8 filler"
set_file_age "$case_dir/fiber-708-pi.jsonl" 301
run_stat "$case_dir" >"$T/case-8.out" 2>"$T/case-8.err"; rc=$?
[ "$rc" = 0 ] || fail "case 8 exits 0 (got $rc)"
assert_row 708 'STALL no tool, not settled$' "$(<"$T/case-8.out")"

# Dead pid files do not count as live rows, even when --all displays them.
case_dir=$(mktemp -d "$T/case-9.XXXXXX") || fail "create case-9 run dir"
printf '909\n' >"$case_dir/fiber-909-pi.pid"
run_stat "$case_dir" >"$T/case-9-default.out" 2>"$T/case-9-default.err"; rc=$?
[ "$rc" = 0 ] || fail "case 9 default exits 0 (got $rc)"
[ "$(<"$T/case-9-default.out")" = "lanestat: no live lanes in $case_dir" ] \
  || fail 'case 9: zero-live-row message for empty and dead-only run dirs'
run_stat --all "$case_dir" >"$T/case-9-all.out" 2>"$T/case-9-all.err"; rc=$?
[ "$rc" = 0 ] || fail "case 9 --all exits 0 (got $rc)"
expected="$(printf '%-6s %-8s %s\nlanestat: no live lanes in %s' 909 909 DEAD "$case_dir")"
[ "$(<"$T/case-9-all.out")" = "$expected" ] \
  || fail 'case 9: zero-live-row message for empty and dead-only run dirs'

check_case_row() {
  local pid=$1 pattern=$2 rc
  run_stat "$case_dir" >"$T/$pid.out" 2>"$T/$pid.err"; rc=$?
  [ "$rc" = 0 ] || fail "case $pid exits 0 (got $rc; $(<"$T/$pid.err"))"
  assert_row "$pid" "$pattern" "$(<"$T/$pid.out")"
}

# A delivered prompt after settlement with no following activity is WEDGED.
new_case wedged-none 710
printf '%s\n' \
  '{"type":"agent_settled"}' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  >"$case_dir/fiber-710-pi.jsonl"
check_case_row 710 'WEDGED last=none$'

# The newest tool start is retained as the event's last tool across settlement.
new_case wedged-last-tool 711
printf '%s\n' \
  '{"type":"tool_execution_start","toolCallId":"old","toolName":"read"}' \
  '{"type":"tool_execution_start","toolCallId":"new","toolName":"bash"}' \
  '{"type":"agent_settled"}' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  >"$case_dir/fiber-711-pi.jsonl"
check_case_row 711 'WEDGED last=bash$'

# A text response starts streaming at message_start; agent_start alone does not.
new_case wedged-streaming 712
printf '%s\n' \
  '{"type":"agent_settled"}' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  '{"type":"message_start","message":{"role":"assistant"}}' \
  >"$case_dir/fiber-712-pi.jsonl"
check_case_row 712 'RUNNING$'
new_case wedged-pi-order 713
printf '%s\n' \
  '{"type":"agent_settled"}' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  '{"type":"agent_start"}' \
  '{"type":"turn_start"}' \
  '{"type":"message_start","message":{"role":"assistant"}}' \
  >"$case_dir/fiber-713-pi.jsonl"
check_case_row 713 'RUNNING$'
new_case wedged-agent-start 714
printf '%s\n' \
  '{"type":"agent_settled"}' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  '{"type":"agent_start"}' \
  >"$case_dir/fiber-714-pi.jsonl"
check_case_row 714 'WEDGED last=none$'
new_case wedged-turn-start 715
printf '%s\n' \
  '{"type":"agent_settled"}' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  '{"type":"agent_start"}' \
  '{"type":"turn_start"}' \
  >"$case_dir/fiber-715-pi.jsonl"
check_case_row 715 'WEDGED last=none$'
new_case message-start-queued 716
printf '%s\n' \
  '{"type":"agent_settled"}' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"queued"}}' \
  '{"type":"message_start","message":{"role":"assistant"}}' \
  >"$case_dir/fiber-716-pi.jsonl"
check_case_row 716 'SETTLED$'
new_case message-start-no-prompt 717
printf '%s\n' \
  '{"type":"agent_settled"}' \
  '{"type":"message_start","message":{"role":"assistant"}}' \
  >"$case_dir/fiber-717-pi.jsonl"
check_case_row 717 'SETTLED$'

# Tool activity clears the prompt flag, and a later settle starts a new run.
new_case wedged-tool-response 718
printf '%s\n' \
  '{"type":"agent_settled"}' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  '{"type":"tool_execution_start","toolCallId":"t","toolName":"bash"}' \
  '{"type":"tool_execution_end","toolCallId":"t"}' \
  >"$case_dir/fiber-718-pi.jsonl"
check_case_row 718 'RUNNING$'
new_case wedged-resettled 719
printf '%s\n' \
  '{"type":"agent_settled"}' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  '{"type":"agent_settled"}' \
  >"$case_dir/fiber-719-pi.jsonl"
check_case_row 719 'SETTLED$'

# WEDGED has no settled-age cutoff and no last tool name when toolName is empty.
new_case wedged-old 720
printf '%s\n' \
  '{"type":"agent_settled"}' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  >"$case_dir/fiber-720-pi.jsonl"
set_file_age "$case_dir/fiber-720-pi.jsonl" 7201
check_case_row 720 'WEDGED last=none$'
new_case wedged-empty-tool 721
printf '%s\n' \
  '{"type":"tool_execution_start","toolCallId":"t","toolName":""}' \
  '{"type":"agent_settled"}' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  >"$case_dir/fiber-721-pi.jsonl"
check_case_row 721 'WEDGED last=none$'
new_case prompt-id-first 722
printf '%s\n' \
  '{"type":"agent_settled"}' \
  '{"id":"x1","type":"response","command":"prompt","success":true}' \
  >"$case_dir/fiber-722-pi.jsonl"
check_case_row 722 'WEDGED last=none$'

# A silent un-settled lane retains RUNNING/STALL, not WEDGED.
new_case prompt-without-settle 723
printf '%s\n' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  >"$case_dir/fiber-723-pi.jsonl"
check_case_row 723 'RUNNING$'
set_file_age "$case_dir/fiber-723-pi.jsonl" 301
check_case_row 723 'STALL no tool, not settled$'

# Streaming text followed by a queued prompt stays running in both pi shapes.
for queued_shape in disposition status; do
  case $queued_shape in
    disposition) queued='"disposition":"queued"' ;;
    status) queued='"status":"queued"' ;;
  esac
  pid=$((724 + ${#queued_shape}))
  new_case "streaming-queued-$queued_shape" "$pid"
  printf '%s\n' \
    '{"type":"agent_settled"}' \
    '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
    '{"type":"message_start","message":{"role":"assistant"}}' \
    '{"type":"message_update"}' \
    "{\"type\":\"response\",\"command\":\"prompt\",\"success\":true,\"data\":{$queued}}" \
    >"$case_dir/fiber-$pid-pi.jsonl"
  check_case_row "$pid" 'RUNNING$'
  pid=$((730 + ${#queued_shape}))
  new_case "settled-queued-$queued_shape" "$pid"
  printf '%s\n' \
    '{"type":"agent_settled"}' \
    "{\"type\":\"response\",\"command\":\"prompt\",\"success\":true,\"data\":{$queued}}" \
    >"$case_dir/fiber-$pid-pi.jsonl"
  check_case_row "$pid" 'SETTLED$'
done
new_case rejected-prompt 740
printf '%s\n' \
  '{"type":"agent_settled"}' \
  '{"type":"response","command":"prompt","success":false,"error":"x"}' \
  >"$case_dir/fiber-740-pi.jsonl"
check_case_row 740 'SETTLED$'

# DEAD-PROVIDER follows the last agent_end assistant message.
dead_run="$T/dead-provider"
mkdir -p "$dead_run"
for pid in 750 751 752 753 754 755 756 757 758 759; do
  printf '%s\n' "$pid" >"$dead_run/fiber-$pid-pi.pid"
  printf 'pi\n' >"$T/ps/$pid.comm"
  printf 'S 00:01\n' >"$T/ps/$pid.info"
done
printf '%s\n' \
  '{"type": "agent_end", "messages": [{"role": "assistant", "content": [], "api": "openai-responses", "provider": "opencode-go", "model": "muse-spark-1.3-contributor", "usage": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0, "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0}}, "stopReason": "error", "errorMessage": "opencode-go API error (402): {\"type\":\"server_error\",\"message\":\"Upstream request failed: Insufficient account funds\"}"}]}' \
  '{"type":"agent_settled"}' \
  >"$dead_run/fiber-750-pi.jsonl"
printf '%s\n' \
  '{"type": "agent_end", "messages": [{"role": "assistant", "content": [], "api": "openai-responses", "provider": "openai", "model": "gpt-5.4", "usage": {"totalTokens": 0}, "stopReason": "error", "errorMessage": "OpenAI API error (400): model_not_found"}]}' \
  '{"type":"agent_settled"}' \
  >"$dead_run/fiber-751-pi.jsonl"
printf '%s\n' \
  '{"type": "agent_end", "messages": [{"role": "assistant", "content": [{"type": "text", "text": "A normal report."}], "api": "openai-responses", "provider": "openai", "model": "gpt-6-luna", "usage": {"totalTokens": 12}, "stopReason": "stop"}]}' \
  '{"type":"agent_settled"}' \
  >"$dead_run/fiber-752-pi.jsonl"
printf '%s\n' \
  '{"type":"agent_end","messages":[{"role":"assistant","content":[],"provider":"openai","model":"gpt-5.4","usage":{"totalTokens":0},"stopReason":"error","errorMessage":"old failure"}]}' \
  '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"Recovered."}],"provider":"openai","model":"gpt-5.4","usage":{"totalTokens":8},"stopReason":"stop"}]}' \
  '{"type":"agent_settled"}' \
  >"$dead_run/fiber-753-pi.jsonl"
printf '%s\n' \
  '{"type":"agent_end","messages":[{"role":"assistant","content":[],"provider":"openai","model":"gpt-5.4","usage":{"totalTokens":1},"stopReason":"error","errorMessage":"not dead"}]}' \
  '{"type":"agent_settled"}' \
  >"$dead_run/fiber-754-pi.jsonl"
printf '%s\n' \
  '{"type":"auto_retry_end","success":false,"finalError":"legacy retry failure"}' \
  '{"type":"agent_settled"}' \
  >"$dead_run/fiber-755-pi.jsonl"
printf '%s\n' \
  '{"type":"agent_end","messages":[{"role":"assistant","content":[],"provider":"openai","model":"gpt-5.4","usage":{"totalTokens":0},"stopReason":"error","errorMessage":"OpenAI API error (400): first line\nsecond line"}]}' \
  '{"type":"agent_settled"}' \
  >"$dead_run/fiber-756-pi.jsonl"
printf '%s\n' \
  '{"type":"agent_end","messages":[{"role":"assistant","content":[],"provider":"openai","model":"gpt-5.4","usage":{"totalTokens":0},"stopReason":"error"}]}' \
  '{"type":"agent_settled"}' \
  >"$dead_run/fiber-757-pi.jsonl"
printf '%s\n' \
  '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"content with no tokens"}],"provider":"p","model":"m","usage":{"totalTokens":0},"stopReason":"error","errorMessage":"provider error"}]}' \
  '{"type":"agent_settled"}' \
  >"$dead_run/fiber-758-pi.jsonl"
printf '%s\n' \
  '{"type":"agent_end","messages":[{"role":"assistant","content":[],"provider":"openai","model":"gpt-5.4","usage":{"totalTokens":0},"stopReason":"error","errorMessage":""}]}' \
  '{"type":"agent_settled"}' \
  >"$dead_run/fiber-759-pi.jsonl"
run_stat "$dead_run" >"$T/dead-provider.out" 2>"$T/dead-provider.err"; rc=$?
[ "$rc" = 0 ] || fail "dead-provider fixture exits 0 (got $rc; $(<"$T/dead-provider.err"))"
assert_row 750 'DEAD-PROVIDER opencode-go/muse-spark-1\.3-contributor: opencode-go API error \(402\): .*Insufficient account funds' "$(<"$T/dead-provider.out")"
assert_row 751 'DEAD-PROVIDER openai/gpt-5\.4: OpenAI API error \(400\): model_not_found' "$(<"$T/dead-provider.out")"
assert_row 752 'SETTLED$' "$(<"$T/dead-provider.out")"
assert_row 753 'SETTLED$' "$(<"$T/dead-provider.out")"
assert_row 754 'SETTLED$' "$(<"$T/dead-provider.out")"
assert_row 755 'SETTLED$' "$(<"$T/dead-provider.out")"
assert_row 756 'DEAD-PROVIDER openai/gpt-5\.4: OpenAI API error \(400\): first line$' "$(<"$T/dead-provider.out")"
assert_row 757 'DEAD-PROVIDER openai/gpt-5\.4: no output$' "$(<"$T/dead-provider.out")"
assert_row 758 'DEAD-PROVIDER p/m: provider error$' "$(<"$T/dead-provider.out")"
assert_row 759 'DEAD-PROVIDER openai/gpt-5\.4: no output$' "$(<"$T/dead-provider.out")"

# Delegate job records are resolved only for UUIDs printed by the lane.
job_done=11111111-1111-4111-8111-111111111111
job_concerns=22222222-2222-4222-8222-222222222222
job_running=33333333-3333-4333-8333-333333333333
job_blocked=44444444-4444-4444-8444-444444444444
job_invalid=55555555-5555-4555-8555-555555555555
job_unresolved=66666666-6666-4666-8666-666666666666
job_tmp=77777777-7777-4777-8777-777777777777
job_system=88888888-8888-4888-8888-888888888888
job_first_wins=99999999-9999-4999-8999-999999999999
job_sup_old=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
job_sup_finished=abababab-abab-4bab-8bab-abababababab
job_sup_done=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
job_sup_running=dddddddd-dddd-4ddd-8ddd-dddddddddddd
job_chain_a=eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee
job_chain_b=ffffffff-ffff-4fff-8fff-ffffffffffff
job_loop_a=01234567-89ab-4cde-8fab-0123456789ab
job_loop_b=12345678-9abc-4def-8abc-123456789abc
job_missing_link=23456789-abcd-4ef0-8abc-23456789abcd
job_result_done=3456789a-bcde-4f01-8abc-3456789abcde
job_result_blocked=456789ab-cdef-4012-8abc-456789abcdef
job_result_empty=56789abc-def0-4123-8abc-56789abcdef0
job_home=6789abcd-ef01-4234-8abc-6789abcdef01
for job_id in "$job_done" "$job_concerns" "$job_sup_finished" "$job_sup_done" "$job_chain_b" "$job_result_done"; do
  printf '{"status":"DONE"}\n' >"$DELEGATE_JOBS_DIR/$job_id.json"
done
printf '{"status":"DONE_WITH_CONCERNS"}\n' >"$DELEGATE_JOBS_DIR/$job_concerns.json"
printf '{"status":"RUNNING"}\n' >"$DELEGATE_JOBS_DIR/$job_running.json"
printf '{"status":"BLOCKED"}\n' >"$DELEGATE_JOBS_DIR/$job_blocked.json"
printf 'not json\n' >"$DELEGATE_JOBS_DIR/$job_invalid.json"
printf '{"status":"RUNNING","supersededBy":"%s"}\n' "$job_sup_finished" \
  >"$DELEGATE_JOBS_DIR/$job_sup_old.json"
printf '{"status":"DONE","supersededBy":"%s"}\n' "$job_sup_running" \
  >"$DELEGATE_JOBS_DIR/$job_sup_done.json"
printf '{"status":"RUNNING"}\n' >"$DELEGATE_JOBS_DIR/$job_sup_running.json"
printf '{"status":"RUNNING","supersededBy":"%s"}\n' "$job_chain_b" \
  >"$DELEGATE_JOBS_DIR/$job_chain_a.json"
printf '{"status":"RUNNING","supersededBy":"%s"}\n' "$job_done" \
  >"$T/tmp/delegate-jobs/$job_chain_b.json"
printf '{"status":"RUNNING","supersededBy":"%s"}\n' "$job_loop_b" \
  >"$DELEGATE_JOBS_DIR/$job_loop_a.json"
printf '{"status":"RUNNING","supersededBy":"%s"}\n' "$job_loop_a" \
  >"$DELEGATE_JOBS_DIR/$job_loop_b.json"
printf '{"status":"RUNNING","supersededBy":"%s"}\n' "$job_unresolved" \
  >"$DELEGATE_JOBS_DIR/$job_missing_link.json"
printf '{"status":"RUNNING","result":{"status":"DONE"}}\n' \
  >"$DELEGATE_JOBS_DIR/$job_result_done.json"
printf '{"status":"DONE","result":{"status":"BLOCKED"}}\n' \
  >"$DELEGATE_JOBS_DIR/$job_result_blocked.json"
printf '{"status":"DONE","result":{"status":""}}\n' \
  >"$DELEGATE_JOBS_DIR/$job_result_empty.json"
printf '{"status":"DONE"}\n' >"$T/tmp/delegate-jobs/$job_tmp.json"
printf '{"status":"DONE"}\n' >"$JOB_RECORD_SYSTEM_DIR/$job_system.json"
printf '{"status":"RUNNING"}\n' >"$DELEGATE_JOBS_DIR/$job_first_wins.json"
printf '{"status":"DONE"}\n' >"$T/tmp/delegate-jobs/$job_first_wins.json"
mkdir -p "$T/home/.cache/tmp/delegate-jobs" "$T/no-tmp"
printf '{"status":"DONE"}\n' >"$T/home/.cache/tmp/delegate-jobs/$job_home.json"
job_run="$T/jobs-run"
mkdir -p "$job_run"
write_job_lane() {
  local lane_pid=$1 job_id
  shift
  printf '%s\n' "$lane_pid" >"$job_run/fiber-$lane_pid-pi.pid"
  printf 'pi\n' >"$T/ps/$lane_pid.comm"
  printf 'S 00:01\n' >"$T/ps/$lane_pid.info"
  : >"$job_run/fiber-$lane_pid-pi.jsonl"
  for job_id in "$@"; do
    printf '{"type":"tool_execution_end","toolCallId":"job","result":"%s"}\n' \
      "$job_id" >>"$job_run/fiber-$lane_pid-pi.jsonl"
  done
  printf '{"type":"agent_settled"}\n' >>"$job_run/fiber-$lane_pid-pi.jsonl"
}
write_job_lane 800 "$job_done"
write_job_lane 801 "$job_done" "$job_concerns"
write_job_lane 802 "$job_done" "$job_running"
write_job_lane 803 "$job_done" "$job_blocked"
write_job_lane 804 "$job_done" "$job_invalid"
write_job_lane 805
write_job_lane 806 "$job_unresolved" "$job_done"
write_job_lane 807 "$job_tmp"
write_job_lane 808 "$job_system"
write_job_lane 809 "$job_first_wins"
write_job_lane 810 "$job_sup_old"
write_job_lane 811 "$job_sup_done"
write_job_lane 812 "$job_chain_a"
write_job_lane 813 "$job_loop_a"
write_job_lane 814 "$job_missing_link"
write_job_lane 815 "$job_result_done"
write_job_lane 816 "$job_result_blocked"
write_job_lane 817 "$job_result_empty"
write_job_lane 818
printf '%s\n' \
  '{"type":"tool_execution_start","toolCallId":"t","toolName":"bash"}' \
  "{\"type\":\"tool_execution_end\",\"toolCallId\":\"job\",\"result\":\"$job_done\"}" \
  >"$job_run/fiber-819-pi.jsonl"
printf '819\n' >"$job_run/fiber-819-pi.pid"
printf 'pi\n' >"$T/ps/819.comm"
printf 'S 00:01\n' >"$T/ps/819.info"
printf '824\n' >"$job_run/fiber-824-pi.pid"
printf 'pi\n' >"$T/ps/824.comm"
printf 'S 00:01\n' >"$T/ps/824.info"
printf '{"type":"message_end","message":{"role":"assistant","content":[],"timestamp":1700000000000},"jobId":"%s"}\n' "$job_done" \
  >"$job_run/fiber-824-pi.jsonl"
write_job_lane 820 "$job_home"
write_job_lane 822 "$job_done"
set_file_age "$job_run/fiber-822-pi.jsonl" 7201
printf '%s\n' \
  "{\"type\":\"tool_execution_end\",\"toolCallId\":\"job\",\"result\":\"$job_done\"}" \
  '{"type":"agent_end","messages":[{"role":"assistant","content":[],"provider":"openai","model":"gpt-5.4","usage":{"totalTokens":0},"stopReason":"error","errorMessage":"provider exhausted"}]}' \
  '{"type":"agent_settled"}' \
  >"$job_run/fiber-823-pi.jsonl"
printf '823\n' >"$job_run/fiber-823-pi.pid"
printf 'pi\n' >"$T/ps/823.comm"
printf 'S 00:01\n' >"$T/ps/823.info"
run_stat "$job_run" >"$T/jobs.out" 2>"$T/jobs.err"; rc=$?
[ "$rc" = 0 ] || fail "job fixture exits 0 (got $rc; $(<"$T/jobs.err"))"
assert_row 800 "SETTLED DONE-UNREAD $job_done$" "$(<"$T/jobs.out")"
assert_row 801 "SETTLED DONE-UNREAD $job_done $job_concerns$" "$(<"$T/jobs.out")"
assert_row 802 'SETTLED$' "$(<"$T/jobs.out")"
assert_row 803 'SETTLED$' "$(<"$T/jobs.out")"
assert_row 804 'SETTLED$' "$(<"$T/jobs.out")"
assert_row 805 'SETTLED$' "$(<"$T/jobs.out")"
assert_row 806 "SETTLED DONE-UNREAD $job_done$" "$(<"$T/jobs.out")"
assert_row 807 "SETTLED DONE-UNREAD $job_tmp$" "$(<"$T/jobs.out")"
assert_row 808 "SETTLED DONE-UNREAD $job_system$" "$(<"$T/jobs.out")"
assert_row 809 'SETTLED$' "$(<"$T/jobs.out")"
assert_row 810 "SETTLED DONE-UNREAD $job_sup_old$" "$(<"$T/jobs.out")"
assert_row 811 'SETTLED$' "$(<"$T/jobs.out")"
assert_row 812 "SETTLED DONE-UNREAD $job_chain_a$" "$(<"$T/jobs.out")"
assert_row 813 'SETTLED$' "$(<"$T/jobs.out")"
assert_row 814 'SETTLED$' "$(<"$T/jobs.out")"
assert_row 815 "SETTLED DONE-UNREAD $job_result_done$" "$(<"$T/jobs.out")"
assert_row 816 'SETTLED$' "$(<"$T/jobs.out")"
assert_row 817 'SETTLED$' "$(<"$T/jobs.out")"
assert_row 818 'SETTLED$' "$(<"$T/jobs.out")"
assert_row 819 'IN-TOOL bash$' "$(<"$T/jobs.out")"
assert_row 824 'RUNNING$' "$(<"$T/jobs.out")"
assert_row 822 "SETTLED-OLD DONE-UNREAD $job_done$" "$(LANESTAT_SETTLED_MAX=60 run_stat "$job_run")"
env -u DELEGATE_JOBS_DIR TMPDIR="$T/no-tmp" JOB_RECORD_SYSTEM_DIR="$T/system-jobs" \
  HOME="$T/home" PATH="$T/stub:$PATH" LANESTAT_TEST_NOW="$NOW" \
  sh "$LANESTAT" "$job_run" >"$T/jobs-no-override.out" 2>"$T/jobs-no-override.err"
assert_row 820 'SETTLED$' "$(<"$T/jobs-no-override.out")"
env DELEGATE_JOBS_DIR="$T/home/.cache/tmp/delegate-jobs" TMPDIR="$T/no-tmp" \
  JOB_RECORD_SYSTEM_DIR="$T/system-jobs" HOME="$T/home" PATH="$T/stub:$PATH" \
  LANESTAT_TEST_NOW="$NOW" sh "$LANESTAT" "$job_run" \
  >"$T/jobs-override.out" 2>"$T/jobs-override.err"
assert_row 820 "SETTLED DONE-UNREAD $job_home$" "$(<"$T/jobs-override.out")"

# The first directory wins; newer records and locators never override it.
# The dead row takes precedence over finished jobs.
# (The fixture's tool end above already carried this lane's id before death.)
assert_row 823 'DEAD-PROVIDER openai/gpt-5\.4: provider exhausted$' "$(<"$T/jobs.out")"

make_lane() {
  local run_dir=$1 lane_pid=$2
  mkdir -p "$run_dir"
  printf '%s\n' "$lane_pid" >"$run_dir/fiber-$lane_pid-pi.pid"
  printf 'pi\n' >"$T/ps/$lane_pid.comm"
  printf 'S 00:01\n' >"$T/ps/$lane_pid.info"
  : >"$run_dir/fiber-$lane_pid-pi.jsonl"
}
set_epoch_mtime() {
  perl -e 'utime($ARGV[1], $ARGV[1], $ARGV[0]) or die "utime: $!"' "$1" "$2" \
    || fail "set fixture mtime $2 for $1"
}
write_ruling() {
  local run_dir=$1 name=$2 epoch=$3
  printf 'ruling fixture\n' >"$run_dir/$name"
  set_epoch_mtime "$run_dir/$name" "$epoch"
}
write_text_message() {
  local file=$1 timestamp=$2 text=$3
  printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"%s"}],"timestamp":%s}}\n' \
    "$text" "$timestamp" >>"$file"
}
write_question_lane() {
  local lane_pid=$1 timestamp=$2 text=$3
  new_case "question-$lane_pid" "$lane_pid"
  write_text_message "$case_dir/fiber-$lane_pid-pi.jsonl" "$timestamp" "$text"
  printf '{"type":"agent_settled"}\n' >>"$case_dir/fiber-$lane_pid-pi.jsonl"
}
make_fixture_repo() {
  local repo=$1 epoch=$2 no_commit=${3:-no}
  mkdir -p "$repo"
  git -C "$repo" init -q || fail "initialize fixture repo $repo"
  git -C "$repo" config user.name 'Switchyard Test' || fail "configure fixture repo"
  git -C "$repo" config user.email 'switchyard-test@example.invalid' || fail "configure fixture repo"
  [ "$no_commit" = yes ] && return
  printf 'fixture\n' >"$repo/file"
  git -C "$repo" add file || fail "add fixture repo file"
  GIT_AUTHOR_DATE="@$epoch +0000" GIT_COMMITTER_DATE="@$epoch +0000" \
    git -C "$repo" commit -q -m fixture </dev/null || fail "commit fixture repo"
}
write_loop_lane() {
  local run_dir=$1 lane_pid=$2 message_time=$3 settle_count=$4 text=${5:-'No question.'}
  make_lane "$run_dir" "$lane_pid"
  write_text_message "$run_dir/fiber-$lane_pid-pi.jsonl" "$message_time" "$text"
  while [ "$settle_count" -gt 0 ]; do
    printf '{"type":"agent_settled"}\n' >>"$run_dir/fiber-$lane_pid-pi.jsonl"
    settle_count=$((settle_count - 1))
  done
}

# PARK follows the latest assistant text message and only an unanswered ruling.
write_question_lane 900 1700000000000 'Which?'
printf '%s\n' \
  '{"type":"turn_end","message":{"role":"assistant","content":[{"type":"text","text":"Which?"}]}}' \
  '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"Which?"}]}]}' \
  >>"$case_dir/fiber-900-pi.jsonl"
check_case_row 900 'SETTLED PARK last=none$'
write_question_lane 901 1700000000000 'STATUS: BLOCKED'
check_case_row 901 'SETTLED PARK last=none$'
write_question_lane 902 1700000000000 'The request is UNBLOCKED.'
check_case_row 902 'SETTLED PARK last=none$'
write_question_lane 903 1700000000000 'Earlier?\nDone.'
check_case_row 903 'SETTLED$'
write_question_lane 904 1700000000000 'Earlier?'
printf '%s\n' \
  '{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Which?"}],"timestamp":1700000000001}}' \
  '{"type":"message_end","message":{"role":"assistant","content":[{"type":"toolCall","name":"read"}],"timestamp":1700000000002}}' \
  '{"type":"agent_settled"}' >>"$case_dir/fiber-904-pi.jsonl"
check_case_row 904 'SETTLED PARK last=none$'
write_question_lane 905 1700000000000 'Question?'
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Final."}],"timestamp":1700000000001}}\n' \
  >>"$case_dir/fiber-905-pi.jsonl"
check_case_row 905 'SETTLED$'
write_question_lane 906 1700000000000 'Which?'
write_ruling "$case_dir" switchyard-906-ruling-1.md 1699999999
check_case_row 906 'SETTLED PARK last=none$'
write_question_lane 907 1700000000000 'Which?'
write_ruling "$case_dir" switchyard-907-ruling-1.md 1700000000
check_case_row 907 'SETTLED PARK last=none$'
write_question_lane 908 1700000000000 'Which?'
write_ruling "$case_dir" switchyard-908-ruling-1.md 1700000001
check_case_row 908 'SETTLED$'
write_question_lane 909 1700000000000 'Which?'
write_ruling "$case_dir" switchyard-909-ruling-1.md 1700000001
check_case_row 909 'SETTLED$'
write_question_lane 910 1700000000000 'Which?'
write_ruling "$case_dir" fiber-910-ruling-1.md 1700000001
check_case_row 910 'SETTLED$'
write_question_lane 911 1700000000000 'Which?'
write_ruling "$case_dir" fiber-911-fence-grant-1.md 1700000001
check_case_row 911 'SETTLED$'
write_question_lane 912 1700000000000 'Which?'
write_ruling "$case_dir" switchyard-999-ruling-1.md 1700000001
check_case_row 912 'SETTLED PARK last=none$'
write_question_lane 913 1700000000000 'Which?'
write_ruling "$case_dir" fiber-9137-ruling-1.md 1700000001
check_case_row 913 'SETTLED PARK last=none$'
write_question_lane 914 1700000000000 'Which?'
write_ruling "$case_dir" fiber-914-surveyor-ruling.md 1700000001
check_case_row 914 'SETTLED PARK last=none$'
write_question_lane 915 1700000000000 'Earlier?\nDone.'
check_case_row 915 'SETTLED$'
write_question_lane 916 1700000000000 'Which?'
printf '%s\n' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  '{"type":"agent_start"}' \
  '{"type":"turn_start"}' \
  '{"type":"message_start","message":{"role":"assistant"}}' \
  '{"type":"message_update","delta":"streaming"}' \
  >>"$case_dir/fiber-916-pi.jsonl"
check_case_row 916 'RUNNING$'
write_question_lane 917 1700000000000 'Which?'
write_ruling "$case_dir" switchyard-917-ruling-1.md 1700000000
printf '%s\n' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  '{"type":"agent_start"}' \
  '{"type":"turn_start"}' \
  >>"$case_dir/fiber-917-pi.jsonl"
check_case_row 917 'WEDGED last=none$'
new_case malformed-question 918
printf '%s\n' \
  '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Which?"}],"timestamp":1700000000000' \
  '{"type":"agent_settled"}' >"$case_dir/fiber-918-pi.jsonl"
check_case_row 918 'SETTLED$'
new_case nested-timestamp-question 919
write_ruling "$case_dir" switchyard-919-ruling-1.md 1700000000
printf '%s\n' \
  '{"type":"message_end","message":{"role":"assistant","content":[{"type":"toolCall","arguments":{"timestamp":1700000000001}},{"type":"text","text":"Which?"}],"timestamp":1700000000000}}' \
  '{"type":"agent_settled"}' >"$case_dir/fiber-919-pi.jsonl"
check_case_row 919 'SETTLED PARK last=none$'
new_case truncated-question 920
perl -e 'print q({"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Which?"}],"timestamp":1700000000000,"padding":"}), "x" x 20000001, q("}) . chr(10) . q({"type":"agent_settled"}) . chr(10)' \
  >"$case_dir/fiber-920-pi.jsonl"
check_case_row 920 'SETTLED$'
new_case nonnumeric-question-time 924
printf '%s\n' \
  '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Which?"}],"timestamp":"not numeric"}}' \
  '{"type":"agent_settled"}' >"$case_dir/fiber-924-pi.jsonl"
check_case_row 924 'SETTLED$'
new_case missing-question-time 925
printf '%s\n' \
  '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Which?"}]}}' \
  '{"type":"agent_settled"}' >"$case_dir/fiber-925-pi.jsonl"
check_case_row 925 'SETTLED$'
new_case joined-text-blocks 926
printf '%s\n' \
  '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Earlier?"},{"type":"text","text":"Done."}],"timestamp":1700000000000}}' \
  '{"type":"agent_settled"}' >"$case_dir/fiber-926-pi.jsonl"
check_case_row 926 'SETTLED$'
new_case park-open-tool 927
write_text_message "$case_dir/fiber-927-pi.jsonl" 1700000000000 'Which?'
printf '%s\n' \
  '{"type":"agent_settled"}' \
  '{"type":"tool_execution_start","toolCallId":"t","toolName":"bash"}' \
  >>"$case_dir/fiber-927-pi.jsonl"
check_case_row 927 'IN-TOOL bash$'
new_case second-question-after-ruling 928
write_text_message "$case_dir/fiber-928-pi.jsonl" 1700000000000 'First question?'
printf '{"type":"agent_settled"}\n' >>"$case_dir/fiber-928-pi.jsonl"
write_ruling "$case_dir" switchyard-928-ruling-1.md 1700000001
write_text_message "$case_dir/fiber-928-pi.jsonl" 1700000002000 'Second question?'
printf '{"type":"agent_settled"}\n' >>"$case_dir/fiber-928-pi.jsonl"
check_case_row 928 'SETTLED PARK last=none$'

# PARK answer boundary: strictly newer rulings answer; equality is still open.
for pair in '921 1699999999 park' '922 1700000000 park' '923 1700000001 plain'; do
  set -- $pair
  write_question_lane "$1" 1700000000000 'Which?'
  write_ruling "$case_dir" "fiber-$1-ruling-1.md" "$2"
  case $3 in
    park) expected='SETTLED PARK last=none$' ;;
    plain) expected='SETTLED$' ;;
  esac
  check_case_row "$1" "$expected"
done

# LOOP requires two post-ruling settles and a worktree commit no newer than R.
loop_ruling=1700000100
repo="$T/repo-loop-base"
make_fixture_repo "$repo" "$loop_ruling"
new_case loop-one-settle 930
write_ruling "$case_dir" switchyard-930-ruling-1.md "$loop_ruling"
printf 'worktree=%s\n' "$repo" >"$case_dir/switchyard-930.state"
write_loop_lane "$case_dir" 930 1700000200000 1
check_case_row 930 'SETTLED$'
new_case loop-two-settles 931
write_ruling "$case_dir" switchyard-931-ruling-1.md "$loop_ruling"
printf 'worktree=%s\n' "$repo" >"$case_dir/switchyard-931.state"
write_loop_lane "$case_dir" 931 1700000200000 2
check_case_row 931 'SETTLED LOOP last=none$'
new_case loop-park-and-loop 932
write_ruling "$case_dir" switchyard-932-ruling-1.md "$loop_ruling"
printf 'worktree=%s\n' "$repo" >"$case_dir/switchyard-932.state"
write_loop_lane "$case_dir" 932 1700000200000 2 'Which?'
check_case_row 932 'SETTLED PARK LOOP last=none$'
new_case loop-pre-and-equal-cut 933
write_ruling "$case_dir" switchyard-933-ruling-1.md "$loop_ruling"
printf 'worktree=%s\n' "$repo" >"$case_dir/switchyard-933.state"
printf '%s\n' \
  '{"type":"message_end","message":{"role":"assistant","content":[],"timestamp":1700000050000}}' \
  '{"type":"agent_settled"}' \
  '{"type":"message_end","message":{"role":"assistant","content":[],"timestamp":1700000100000}}' \
  '{"type":"agent_settled"}' \
  '{"type":"message_end","message":{"role":"assistant","content":[],"timestamp":1700000200000}}' \
  >>"$case_dir/fiber-933-pi.jsonl"
check_case_row 933 'SETTLED$'
new_case loop-nested-time 934
write_ruling "$case_dir" switchyard-934-ruling-1.md "$loop_ruling"
printf 'worktree=%s\n' "$repo" >"$case_dir/switchyard-934.state"
printf '%s\n' \
  '{"type":"message_end","message":{"role":"assistant","content":[{"type":"toolCall","arguments":{"timestamp":1700000200000}}],"timestamp":1700000050000}}' \
  '{"type":"agent_settled"}' \
  '{"type":"agent_settled"}' \
  >>"$case_dir/fiber-934-pi.jsonl"
check_case_row 934 'SETTLED$'
repo_new="$T/repo-loop-new"
make_fixture_repo "$repo_new" "$((loop_ruling + 1))"
new_case loop-commit-after 935
write_ruling "$case_dir" switchyard-935-ruling-1.md "$loop_ruling"
printf 'worktree=%s\n' "$repo_new" >"$case_dir/switchyard-935.state"
write_loop_lane "$case_dir" 935 1700000200000 2
check_case_row 935 'SETTLED$'
new_case loop-ruling-moves 936
write_ruling "$case_dir" switchyard-936-ruling-1.md "$loop_ruling"
printf 'worktree=%s\n' "$repo_new" >"$case_dir/switchyard-936.state"
write_loop_lane "$case_dir" 936 1700000200000 2
write_ruling "$case_dir" switchyard-936-ruling-2.md "$((loop_ruling + 1))"
check_case_row 936 'SETTLED LOOP last=none$'
new_case loop-no-worktree-file 937
write_ruling "$case_dir" switchyard-937-ruling-1.md "$loop_ruling"
write_loop_lane "$case_dir" 937 1700000200000 2
check_case_row 937 'SETTLED$'
new_case loop-state-no-path 938
write_ruling "$case_dir" switchyard-938-ruling-1.md "$loop_ruling"
printf 'issue=938\n' >"$case_dir/switchyard-938.state"
write_loop_lane "$case_dir" 938 1700000200000 2
check_case_row 938 'SETTLED$'
new_case loop-invalid-repo 939
write_ruling "$case_dir" switchyard-939-ruling-1.md "$loop_ruling"
mkdir -p "$T/not-a-repo"
printf 'worktree=%s\n' "$T/not-a-repo" >"$case_dir/switchyard-939.state"
write_loop_lane "$case_dir" 939 1700000200000 2
check_case_row 939 'SETTLED$'
repo_no_commit="$T/repo-no-commit"
make_fixture_repo "$repo_no_commit" "$loop_ruling" yes
new_case loop-no-commit 940
write_ruling "$case_dir" switchyard-940-ruling-1.md "$loop_ruling"
printf 'worktree=%s\n' "$repo_no_commit" >"$case_dir/switchyard-940.state"
write_loop_lane "$case_dir" 940 1700000200000 2
check_case_row 940 'SETTLED$'
new_case loop-wrong-state-name 941
write_ruling "$case_dir" switchyard-941-ruling-1.md "$loop_ruling"
printf 'worktree=%s\n' "$repo" >"$case_dir/fiber-9417.state"
write_loop_lane "$case_dir" 941 1700000200000 2
check_case_row 941 'SETTLED$'
new_case loop-state-fallback 942
write_ruling "$case_dir" switchyard-942-ruling-1.md "$loop_ruling"
printf 'owner=none\n' >"$case_dir/fiber-942.state"
printf 'worktree=%s\n' "$repo" >"$case_dir/switchyard-942.state"
write_loop_lane "$case_dir" 942 1700000200000 2
check_case_row 942 'SETTLED LOOP last=none$'
new_case loop-fiber-state 943
write_ruling "$case_dir" switchyard-943-ruling-1.md "$loop_ruling"
printf 'worktree=%s\n' "$repo" >"$case_dir/fiber-943.state"
write_loop_lane "$case_dir" 943 1700000200000 2
check_case_row 943 'SETTLED LOOP last=none$'
new_case loop-artifact-files 944
write_ruling "$case_dir" switchyard-944-ruling-1.md "$loop_ruling"
printf 'worktree=%s\n' "$repo" >"$case_dir/switchyard-944.state"
write_loop_lane "$case_dir" 944 1700000200000 2
printf 'notes\n' >"$case_dir/fiber-944-notes.md"
printf 'findings\n' >"$case_dir/fiber-944-findings-1.md"
set_epoch_mtime "$case_dir/fiber-944-notes.md" "$((loop_ruling + 10))"
set_epoch_mtime "$case_dir/fiber-944-findings-1.md" "$((loop_ruling + 10))"
check_case_row 944 'SETTLED LOOP last=none$'
new_case loop-no-ruling 945
printf 'worktree=%s\n' "$repo" >"$case_dir/switchyard-945.state"
write_loop_lane "$case_dir" 945 1700000200000 2
check_case_row 945 'SETTLED$'
repo_older="$T/repo-loop-older"
make_fixture_repo "$repo_older" "$((loop_ruling - 1))"
new_case loop-commit-before 946
write_ruling "$case_dir" switchyard-946-ruling-1.md "$loop_ruling"
printf 'worktree=%s\n' "$repo_older" >"$case_dir/switchyard-946.state"
write_loop_lane "$case_dir" 946 1700000200000 2
check_case_row 946 'SETTLED LOOP last=none$'
new_case loop-three-settles 947
write_ruling "$case_dir" switchyard-947-ruling-1.md "$loop_ruling"
printf 'worktree=%s\n' "$repo" >"$case_dir/switchyard-947.state"
write_loop_lane "$case_dir" 947 1700000200000 3
check_case_row 947 'SETTLED LOOP last=none$'

# JSON::PP failure disables only decoded features; regex state and LOOP survive.
missing_json="$T/no-json"
mkdir -p "$missing_json/JSON"
printf 'die "hidden JSON::PP\\n";\n' >"$missing_json/JSON/PP.pm"
json_run="$T/missing-json-run"
mkdir -p "$json_run"
make_lane "$json_run" 950
write_text_message "$json_run/fiber-950-pi.jsonl" 1700000000000 'Which?'
printf '{"type":"agent_settled"}\n' >>"$json_run/fiber-950-pi.jsonl"
write_ruling "$json_run" switchyard-950-ruling-1.md 1699999999
write_ruling "$json_run" switchyard-951-ruling-1.md "$loop_ruling"
printf 'worktree=%s\n' "$repo" >"$json_run/switchyard-951.state"
write_loop_lane "$json_run" 951 1700000200000 2
write_job_lane 952 "$job_done"
cp "$job_run/fiber-952-pi.jsonl" "$json_run/fiber-952-pi.jsonl"
cp "$job_run/fiber-952-pi.pid" "$json_run/fiber-952-pi.pid"
make_lane "$json_run" 953
printf '%s\n' '{"type":"agent_settled"}' \
  '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}' \
  >"$json_run/fiber-953-pi.jsonl"
make_lane "$json_run" 954
printf '%s\n' '{"type":"agent_end","messages":[{"role":"assistant","content":[],"provider":"openai","model":"gpt-5.4","usage":{"totalTokens":0},"stopReason":"error","errorMessage":"provider exhausted"}]}' \
  '{"type":"agent_settled"}' >"$json_run/fiber-954-pi.jsonl"
make_lane "$json_run" 955
printf '{"type":"tool_execution_start","toolCallId":"t","toolName":"bash"}\n' \
  >"$json_run/fiber-955-pi.jsonl"
env PERL5LIB="$missing_json" PATH="$T/stub:$PATH" LANESTAT_TEST_NOW="$NOW" \
  DELEGATE_JOBS_DIR="$DELEGATE_JOBS_DIR" JOB_RECORD_SYSTEM_DIR="$JOB_RECORD_SYSTEM_DIR" TMPDIR="$TMPDIR" \
  sh "$LANESTAT" "$json_run" >"$T/missing-json.out" 2>"$T/missing-json.err"
assert_row 950 'SETTLED$' "$(<"$T/missing-json.out")"
assert_row 951 'SETTLED LOOP last=none$' "$(<"$T/missing-json.out")"
assert_row 952 'SETTLED$' "$(<"$T/missing-json.out")"
assert_row 953 'WEDGED last=none$' "$(<"$T/missing-json.out")"
assert_row 954 'DEAD-PROVIDER openai/gpt-5\.4: provider exhausted$' "$(<"$T/missing-json.out")"
assert_row 955 'IN-TOOL bash$' "$(<"$T/missing-json.out")"

# Running under ssh bash -s keeps its script stdin intact while Perl reads logs.
stdin_run="$T/ssh-stdin-run"
mkdir -p "$stdin_run"
make_lane "$stdin_run" 960
write_text_message "$stdin_run/fiber-960-pi.jsonl" 1700000000000 'Which?'
printf '{"type":"agent_settled"}\n' >>"$stdin_run/fiber-960-pi.jsonl"
write_ruling "$stdin_run" switchyard-960-ruling-1.md 1699999999
make_lane "$stdin_run" 961
write_ruling "$stdin_run" switchyard-961-ruling-1.md "$loop_ruling"
printf 'worktree=%s\n' "$repo" >"$stdin_run/switchyard-961.state"
write_loop_lane "$stdin_run" 961 1700000200000 2
make_lane "$stdin_run" 962
printf '{"type":"tool_execution_end","toolCallId":"job","result":"%s"}\n' "$job_done" \
  >"$stdin_run/fiber-962-pi.jsonl"
printf '{"type":"agent_settled"}\n' >>"$stdin_run/fiber-962-pi.jsonl"
run_stat "$stdin_run" >"$T/ssh-local.out" 2>"$T/ssh-local.err"; rc=$?
[ "$rc" = 0 ] || fail "ssh stdin fixture local run exits 0 (got $rc)"
env PATH="$T/stub:$PATH" LANESTAT_TEST_NOW="$NOW" \
  DELEGATE_JOBS_DIR="$DELEGATE_JOBS_DIR" JOB_RECORD_SYSTEM_DIR="$JOB_RECORD_SYSTEM_DIR" TMPDIR="$TMPDIR" \
  bash -s -- "$stdin_run" <"$LANESTAT" >"$T/ssh-script.out" 2>"$T/ssh-script.err"
cmp -s "$T/ssh-local.out" "$T/ssh-script.out" || fail "bash -s preserves all lane rows"
assert_row 960 'SETTLED PARK last=none$' "$(<"$T/ssh-script.out")"
assert_row 961 'SETTLED LOOP last=none$' "$(<"$T/ssh-script.out")"
assert_row 962 "SETTLED DONE-UNREAD $job_done$" "$(<"$T/ssh-script.out")"

echo 'lanestat: all cases passed'

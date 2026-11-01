#!/usr/bin/env bash
# Tests bin/lanestat against a fixture run dir, never a live lane directory.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/ps-stub.sh"
LANESTAT="${LANESTAT:-$SCRIPT_DIR/../bin/lanestat}"
fail() { echo "FAIL: $1" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/test-lanestat.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/empty" "$T/stub" "$T/ps"

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
red_failures=
record_failure() {
  red_failures="${red_failures}${red_failures:+
}$1"
}
case9_failed=
run_stat "$T/empty" >"$T/empty.out" 2>"$T/empty.err"; rc=$?
[ "$rc" = 0 ] || fail "empty run dir exits 0 (got $rc)"
[ "$(<"$T/empty.out")" = "lanestat: no live lanes in $T/empty" ] || case9_failed=1

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
expect_case_row() {
  label=$1
  field=$2
  pattern=$3
  rows=$4
  line="$(printf '%s\n' "$rows" | grep -E "^${field}[[:space:]]" || true)"
  if [ -z "$line" ] || ! printf '%s\n' "$line" | grep -Eq "$pattern"; then
    record_failure "$label"
  fi
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
expect_case_row 'case 1: outer tool remains open after inner end' 701 'IN-TOOL bash$' "$(<"$T/case-1.out")"

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
expect_case_row 'case 2: queue update preserves outer open tool' 702 'IN-TOOL bash$' "$(<"$T/case-2.out")"

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
perl -e 'my $pad = "x" x 1000; print qq({"type":"message_update","pad":"$pad"}\\n) for 0..20000' \
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
[ "$(<"$T/case-9-default.out")" = "lanestat: no live lanes in $case_dir" ] || case9_failed=1
run_stat --all "$case_dir" >"$T/case-9-all.out" 2>"$T/case-9-all.err"; rc=$?
[ "$rc" = 0 ] || fail "case 9 --all exits 0 (got $rc)"
expected="$(printf '%-6s %-8s %s\nlanestat: no live lanes in %s' 909 909 DEAD "$case_dir")"
[ "$(<"$T/case-9-all.out")" = "$expected" ] || case9_failed=1
[ -z "$case9_failed" ] || record_failure 'case 9: zero-live-row message for empty and dead-only run dirs'

if [ -n "$red_failures" ]; then
  printf '%s\n' "$red_failures" | while IFS= read -r failed; do
    printf 'FAIL: %s\n' "$failed" >&2
  done
  exit 1
fi

echo 'lanestat: all cases passed'

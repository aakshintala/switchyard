#!/usr/bin/env bash
# Tests bin/lanestat against a fixture run dir, never a live lane directory.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/ps-stub.sh"
LANESTAT="$SCRIPT_DIR/../bin/lanestat"
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
[ ! -s "$T/empty.out" ] || fail "empty run dir prints nothing"

echo 'lanestat: all cases passed'

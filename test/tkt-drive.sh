#!/usr/bin/env bash
# Tests for tkt-drive using fake tkt-* and fence-grant commands.
# Usage: bash test/tkt-drive.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DRIVER="$ROOT/bin/tkt-drive"
STATE_BIN="$ROOT/bin/tkt-state"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-tkt-drive.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp" "$T/bin"
export HOME="$T/home" TMPDIR="$T/tmp" TKT_BIN="$T/bin" PATH="$T/bin:$PATH"
export TEST_STATE_BIN="$STATE_BIN" TEST_CALLS="$T/calls.log"
export TEST_PLAN_VERDICT="$T/plan-verdict" TEST_POST_VERDICT="$T/post-verdict"
export TEST_BUILD_VERDICT="$T/build-verdict" TEST_SHIP_VERDICT="$T/ship-verdict"
export TEST_FENCE_MODE="$T/fence-mode" TEST_FENCE_CALLS="$T/fence-calls.log" TEST_FENCE_RESULTS="$T/fence-results.log"
export TEST_BUILD_EXTRA="$T/build-extra.md" TEST_MERGE_CALLS="$T/merge-calls.log" TEST_STATE_HELPERS="$T/state-helpers.sh"
export FW_TREE_CACHE="$T/tree-cache" TEST_TREE_JSON="$T/tree.json" TEST_TREE_SHA

cat >"$TEST_STATE_HELPERS" <<'EOF'
state_set() {
  local state="$1" key="$2" value="$3" tmp_state="${1}.tmp.$$"
  awk -F= -v key="$key" '$1 != key' "$state" >"$tmp_state"
  printf '%s=%s\n' "$key" "$value" >>"$tmp_state"
  mv "$tmp_state" "$state"
}
state_journal() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" >>"${1%.state}.journal"
}
EOF
# shellcheck disable=SC1090
. "$TEST_STATE_HELPERS"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

cat >"$T/bin/tkt-plan" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC1090
. "$TEST_STATE_HELPERS"
printf 'tkt-plan|%s\n' "$*" >>"$TEST_CALLS"
state="$1"; shift
sub="${1:-verify}"
case "$sub" in
  verify) verdict="$(cat "$TEST_PLAN_VERDICT")" ;;
  post) verdict="$(cat "$TEST_POST_VERDICT")" ;;
  *) echo "unexpected tkt-plan subcommand: $sub" >&2; exit 2 ;;
esac
case "$verdict" in
  SET) state_set "$state" plan_verdict triaged ;;
  PLAN-OK) state_set "$state" plan_verdict ok ;;
  LINES) state_set "$state" plan_verdict lines ;;
  STALE) state_set "$state" plan_verdict stale ;;
  QUESTIONS) state_set "$state" plan_verdict questions ;;
esac
state_journal "$state" "tkt-plan $verdict"
printf 'TKT tkt-plan %s payload=unchanged\nplan detail stays here\n' "$verdict"
case "$verdict" in SET|PLAN-OK|POSTED) exit 0 ;; *) exit 1 ;; esac
EOF
chmod +x "$T/bin/tkt-plan"

cat >"$T/bin/tkt-build" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC1090
. "$TEST_STATE_HELPERS"
printf 'tkt-build|%s\n' "$*" >>"$TEST_CALLS"
state="$1"
verdict="$(cat "$TEST_BUILD_VERDICT")"
extra="$("$TEST_STATE_BIN" "$state" get extra 2>/dev/null || true)"
extra="${extra#@}"
if [ -n "$extra" ]; then cat "$extra" >"$TEST_BUILD_EXTRA"; fi
state_journal "$state" "tkt-build $verdict"
printf 'TKT tkt-build %s payload=unchanged\nbuild detail stays here\n' "$verdict"
case "$verdict" in SET|PLAN-OK|POSTED|MERGED) exit 0 ;; *) exit 1 ;; esac
EOF
chmod +x "$T/bin/tkt-build"

cat >"$T/bin/tkt-fix" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC1090
. "$TEST_STATE_HELPERS"
printf 'tkt-fix|%s\n' "$*" >>"$TEST_CALLS"
state="$1"
state_journal "$state" 'tkt-fix FIX-INCOMPLETE'
printf 'TKT tkt-fix FIX-INCOMPLETE payload=unchanged\nfix detail stays here\n'
exit 1
EOF
chmod +x "$T/bin/tkt-fix"

cat >"$T/bin/tkt-ship" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC1090
. "$TEST_STATE_HELPERS"
printf 'tkt-ship|%s\n' "$*" >>"$TEST_CALLS"
state="$1"
verdict="$(cat "$TEST_SHIP_VERDICT")"
state_journal "$state" "tkt-ship $verdict"
printf 'TKT tkt-ship %s payload=unchanged\nship detail stays here\n' "$verdict"
case "$verdict" in MERGED) exit 0 ;; *) exit 1 ;; esac
EOF
chmod +x "$T/bin/tkt-ship"

cat >"$T/bin/fence-grant" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'fence-grant|%s\n' "$*" >>"$TEST_FENCE_CALLS"
case " $* " in
  *' --dry '*) echo 'unexpected --dry'; exit 90 ;;
  *' --ranges '*) echo 'unexpected --ranges'; exit 90 ;;
esac
mode="$(cat "$TEST_FENCE_MODE")"
if [ "$mode" = mixed ]; then
  calls="$(wc -l <"$TEST_FENCE_CALLS" | tr -d ' ')"
  if [ "$calls" -eq 1 ]; then mode=clean; else mode=overlap; fi
fi
printf '%s\n' "$mode" >>"$TEST_FENCE_RESULTS"
case "$mode" in
  clean) printf 'GRANT src/read.txt\nGRANT src/write.txt\n' ;;
  overlap) printf 'OVERLAP src/read.txt PR #88\nGRANT src/read.txt\nGRANT src/write.txt\n' ;;
  sweep) printf 'HELD src/read.txt by lane #88 sweep-88\n' ;;
  cap) printf 'HELD src/read.txt by file-claim grant cap\n' ;;
  rc3) printf 'ERROR cannot probe claims\n'; exit 3 ;;
  rc4) printf 'MISSING src/ghost.txt\nNOSYMBOL src/read.txt:8 does not hold symbol\n'; exit 4 ;;
  *) echo "unknown fence mode" >&2; exit 90 ;;
esac
EOF
chmod +x "$T/bin/fence-grant"

# Guard the test against an accidental direct merge route.
cat >"$T/bin/ship-pr" <<'EOF'
#!/usr/bin/env bash
printf 'ship-pr|%s\n' "$*" >>"$TEST_MERGE_CALLS"
exit 99
EOF
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  case "${2:-}" in
    repos/acme/switchyard/commits/main) printf '%s\n' "$TEST_TREE_SHA" ;;
    repos/acme/switchyard/git/trees/*) cat "$TEST_TREE_JSON" ;;
    *) echo "unexpected gh API request: $*" >&2; exit 90 ;;
  esac
else
  printf 'gh|%s\n' "$*" >>"$TEST_MERGE_CALLS"
  exit 99
fi
EOF
chmod +x "$T/bin/ship-pr" "$T/bin/gh"

reset_case() {
  local name="$1"
  CASE_DIR="$T/$name"
  mkdir -p "$CASE_DIR/run"
  TEST_TREE_SHA="$(printf '%s' "$name" | cksum | awk '{printf "%08x", $1}')"
  export TEST_TREE_SHA
  printf '{"truncated":false,"tree":[{"path":"src/read.txt","type":"blob"},{"path":"src/write.txt","type":"blob"}]}\n' >"$TEST_TREE_JSON"
  STATE="$CASE_DIR/ticket.state"
  PLAN="$CASE_DIR/plan.md"
  cat >"$PLAN" <<'PLANEOF'
## Files
- `src/read.txt` (read)
- `src/write.txt`
PLANEOF
  {
    printf 'issue=1472\nrepo=acme/switchyard\nrun=%s\nplan=%s\n' "$CASE_DIR/run" "$PLAN"
  } >"$STATE"
  printf 'PLAN-OK\n' >"$TEST_PLAN_VERDICT"
  printf 'POSTED\n' >"$TEST_POST_VERDICT"
  printf 'BLOCKED\n' >"$TEST_BUILD_VERDICT"
  printf 'MERGED\n' >"$TEST_SHIP_VERDICT"
  printf 'clean\n' >"$TEST_FENCE_MODE"
  : >"$TEST_CALLS"; : >"$TEST_FENCE_CALLS"; : >"$TEST_FENCE_RESULTS"; : >"$TEST_MERGE_CALLS"
  rm -f "$TEST_BUILD_EXTRA"
  export CASE_DIR STATE PLAN
}

run_drive() {
  OUT="$CASE_DIR/output" ERR="$CASE_DIR/stderr"
  if bash "$DRIVER" "$STATE" >"$OUT" 2>"$ERR"; then RC=0; else RC=$?; fi
}

assert_prefix() {
  local expected="$1" output="$2" bytes
  printf '%s' "$expected" >"$CASE_DIR/expected"
  bytes="$(wc -c <"$CASE_DIR/expected" | tr -d ' ')"
  head -c "$bytes" "$output" >"$CASE_DIR/prefix"
  cmp -s "$CASE_DIR/expected" "$CASE_DIR/prefix" || fail "output changed before the driver marker: $(cat "$output")"
}

assert_call_count() {
  local pattern="$1" expected="$2" actual
  actual="$(grep -c "$pattern" "$TEST_CALLS" || true)"
  [ "$actual" -eq "$expected" ] || fail "expected $expected calls matching [$pattern], got $actual: $(cat "$TEST_CALLS")"
}

assert_fence_args() {
  local expected_paths="${1:-src/read.txt,src/write.txt}" expected_new="${2:-}" expected_reads="${3-src/read.txt}" expected line
  expected="fence-grant|1472 --repo acme/switchyard --paths $expected_paths"
  [ -z "$expected_new" ] || expected="$expected --new $expected_new"
  [ -z "$expected_reads" ] || expected="$expected --reads $expected_reads"
  [ -s "$TEST_FENCE_CALLS" ] || fail 'fence-grant was not called'
  while IFS= read -r line; do
    [ "$line" = "$expected" ] || fail "incorrect fence-grant arguments: $line (expected $expected)"
  done <"$TEST_FENCE_CALLS"
}

assert_no_merge() {
  [ ! -s "$TEST_MERGE_CALLS" ] || fail "merge command ran: $(cat "$TEST_MERGE_CALLS")"
}

# New write paths are marked for fence-grant's existence check but remain in
# --paths, which is the grant scope. Mixed and all-new plans both grant.
reset_case mixed-new-write
cat >"$PLAN" <<'PLANEOF'
## Files
- `src/existing.txt`
- `src/new.snap`
PLANEOF
printf '{"truncated":false,"tree":[{"path":"src/existing.txt","type":"blob"}]}\n' >"$TEST_TREE_JSON"
run_drive
[ "$RC" -eq 1 ] || fail "mixed existing/new plan should grant then stop at fake BLOCKED (rc=$RC; out=$(cat "$OUT"); err=$(cat "$ERR"))"
assert_fence_args 'src/existing.txt,src/new.snap' 'src/new.snap' ''
grep -q '^.* tkt-drive fence-grant GRANT ' "${STATE%.state}.journal" || fail 'mixed existing/new plan did not record GRANT'
assert_no_merge

reset_case all-new-writes
cat >"$PLAN" <<'PLANEOF'
## Files
- `src/new-a.snap`
- `fixtures/events.jsonl`
PLANEOF
printf '{"truncated":false,"tree":[{"path":"README.md","type":"blob"}]}\n' >"$TEST_TREE_JSON"
run_drive
[ "$RC" -eq 1 ] || fail "all-new plan should grant then stop at fake BLOCKED (rc=$RC; out=$(cat "$OUT"); err=$(cat "$ERR"))"
assert_fence_args 'src/new-a.snap,fixtures/events.jsonl' 'src/new-a.snap,fixtures/events.jsonl' ''
grep -q '^.* tkt-drive fence-grant GRANT ' "${STATE%.state}.journal" || fail 'all-new plan did not record GRANT'
assert_no_merge

# SET chains to the next plan step; POSTED grants and continues into the build.
reset_case set-chain
printf 'SET\n' >"$TEST_PLAN_VERDICT"
run_drive
[ "$RC" -eq 1 ] || fail "SET chain should stop at fake BLOCKED (rc=$RC; out=$(cat "$OUT"); err=$(cat "$ERR"); calls=$(cat "$TEST_CALLS"))"
assert_call_count '^tkt-plan|.*verify$' 1
assert_call_count '^tkt-plan|.*post$' 1
assert_call_count '^tkt-build|' 1
[ "$(wc -l <"$TEST_FENCE_CALLS" | tr -d ' ')" -eq 1 ] || fail 'SET -> POSTED should grant once'
assert_fence_args
assert_prefix $'TKT tkt-build BLOCKED payload=unchanged\nbuild detail stays here\n' "$OUT"
assert_no_merge

# PLAN-OK grants a clean fence, then POSTED grants despite an advisory overlap.
# Both continue; the overlap reaches the lane brief's existing EXTRA input.
reset_case plan-ok-overlap
printf 'mixed\n' >"$TEST_FENCE_MODE"
printf 'Existing planning context.\n' >"$CASE_DIR/original-extra.md"
state_set "$STATE" extra "$CASE_DIR/original-extra.md"
run_drive
[ "$RC" -eq 1 ] || fail "grant chain should stop at fake BLOCKED (rc=$RC)"
assert_call_count '^tkt-plan|.*verify$' 1
assert_call_count '^tkt-plan|.*post$' 1
assert_call_count '^tkt-build|' 1
[ "$(wc -l <"$TEST_FENCE_CALLS" | tr -d ' ')" -eq 2 ] || fail 'PLAN-OK and POSTED should each grant once'
[ "$(cat "$TEST_FENCE_RESULTS")" = "$(printf 'clean\noverlap')" ] || fail "clean then overlap grants were not observed: $(cat "$TEST_FENCE_RESULTS")"
assert_fence_args
[ -s "$TEST_BUILD_EXTRA" ] || fail 'tkt-build did not receive the EXTRA brief input'
grep -Fxq 'Existing planning context.' "$TEST_BUILD_EXTRA" || fail 'overlap replaced existing brief context'
grep -Fxq '## Fence overlaps' "$TEST_BUILD_EXTRA" || fail 'overlap heading missing from brief input'
grep -Fxq 'OVERLAP src/read.txt PR #88' "$TEST_BUILD_EXTRA" || fail 'overlap line missing from brief input'
[ "$(grep -Fc 'OVERLAP src/read.txt PR #88' "$TEST_BUILD_EXTRA")" -eq 1 ] || fail 'overlap line duplicated in brief input'
assert_no_merge

# Fence-grant stop conditions preserve its output and prevent later steps.
for mode in sweep cap rc3 rc4; do
  reset_case "grant-$mode"
  printf '%s\n' "$mode" >"$TEST_FENCE_MODE"
  run_drive
  case "$mode" in
    sweep) expected=$'HELD src/read.txt by lane #88 sweep-88\n' ;;
    cap) expected=$'HELD src/read.txt by file-claim grant cap\n' ;;
    rc3) expected=$'ERROR cannot probe claims\n' ;;
    rc4) expected=$'MISSING src/ghost.txt\nNOSYMBOL src/read.txt:8 does not hold symbol\n' ;;
  esac
  assert_prefix "$expected" "$OUT"
  [ "$(grep -c '^tkt-plan|.* post$' "$TEST_CALLS" || true)" -eq 0 ] || fail "$mode: plan posting continued after fence stop"
  [ "$(grep -c '^tkt-build|' "$TEST_CALLS" || true)" -eq 0 ] || fail "$mode: build continued after fence stop"
  case "$mode" in rc3) [ "$RC" -eq 3 ] || fail "exit 3 propagated as $RC";; rc4) [ "$RC" -eq 4 ] || fail "exit 4 propagated as $RC";; *) [ "$RC" -ne 0 ] || fail "$mode hold did not stop";; esac
  assert_no_merge
done

# Every non-routine tool verdict stops with that tool's exact output first.
for verdict in LINES QUESTIONS; do
  reset_case "plan-$verdict"
  printf '%s\n' "$verdict" >"$TEST_PLAN_VERDICT"
  run_drive
  assert_prefix "$(printf 'TKT tkt-plan %s payload=unchanged\nplan detail stays here\n' "$verdict")" "$OUT"
  [ "$(grep -c '^tkt-plan|.* post$' "$TEST_CALLS" || true)" -eq 0 ] || fail "$verdict: plan post should not run"
  [ "$(grep -c '^tkt-build|' "$TEST_CALLS" || true)" -eq 0 ] || fail "$verdict: build should not run"
  assert_no_merge
done
for verdict in STALE BLOCKED; do
  reset_case "build-$verdict"
  state_set "$STATE" plan_verdict ok
  state_journal "$STATE" 'tkt-plan POSTED'
  printf '%s\n' "$verdict" >"$TEST_BUILD_VERDICT"
  run_drive
  assert_prefix "$(printf 'TKT tkt-build %s payload=unchanged\nbuild detail stays here\n' "$verdict")" "$OUT"
  [ "$(grep -c '^tkt-ship|' "$TEST_CALLS" || true)" -eq 0 ] || fail "$verdict: ship should not run"
  assert_no_merge
done

# Explicit owner-held and surveyor-sequence markers guard tkt-ship. Set them
# through the public tkt-state interface used by their documented writers.
for marker in owner_held surveyor_sequence; do
  reset_case "guard-$marker"
  state_set "$STATE" review_status "done"
  state_set "$STATE" reviewed 0000000000000000000000000000000000000001
  state_journal "$STATE" 'tkt-build APPROVE'
  if [ "$marker" = owner_held ]; then
    bash "$STATE_BIN" "$STATE" set owner_held yes || fail 'could not set owner_held marker'
  else
    bash "$STATE_BIN" "$STATE" set surveyor_sequence post-merge-review || fail 'could not set surveyor_sequence marker'
  fi
  run_drive
  [ "$RC" -ne 0 ] || fail "$marker did not stop tkt-ship"
  grep -Fq "state $marker marker prevents tkt-ship" "$ERR" || fail "$marker stop reason missing: $(cat "$ERR")"
  [ "$(head -n 1 "$OUT")" = 'TKT tkt-drive STOP' ] || fail "$marker did not report a bare STOP: $(cat "$OUT")"
  [ "$(grep -c '^tkt-ship|' "$TEST_CALLS" || true)" -eq 0 ] || fail "$marker called tkt-ship"
  assert_no_merge
done

# tkt-drive never invokes tkt-ship, even when a previous APPROVE or verify
# verdict and review_status would otherwise select it.
for status in ready done; do
  for prior in 'tkt-build APPROVE' 'tkt-fix FIX-OK' 'tkt-fix FIX-INCOMPLETE' 'tkt-fix VERIFY-FAIL' 'tkt-fix PUSHED'; do
    reset_case "no-ship-$status-${prior#* }"
    state_set "$STATE" review_status "$status"
    state_set "$STATE" reviewed 0000000000000000000000000000000000000001
    state_journal "$STATE" "$prior"
    run_drive
    [ "$(head -n 1 "$OUT")" = 'TKT tkt-drive STOP next=tkt-ship' ] || fail "$status after $prior did not report next=tkt-ship on stdout: $(cat "$OUT")"
    grep -Fq 'tkt-ship is a separate role step' "$ERR" || fail "$status after $prior lacked the separate-ship instruction: $(cat "$ERR")"
    [ "$(grep -c '^tkt-ship|' "$TEST_CALLS" || true)" -eq 0 ] || fail "$status after $prior called tkt-ship"
    assert_no_merge
  done
done

# Every documented or fallback review_status takes a non-shipping route.
for status in missing pending gate-failed ready done skipped other; do
  reset_case "status-$status"
  if [ "$status" != missing ]; then state_set "$STATE" review_status "$status"; fi
  state_set "$STATE" reviewed 0000000000000000000000000000000000000001
  state_journal "$STATE" 'tkt-build APPROVE'
  run_drive
  [ "$(grep -c '^tkt-ship|' "$TEST_CALLS" || true)" -eq 0 ] || fail "$status review_status called tkt-ship"
  assert_no_merge
done

echo 'tkt-drive: all tests passed'

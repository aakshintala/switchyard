#!/usr/bin/env bash
# Tests for bin/tkt-state. Exits non-zero on the first failed case.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TKT="$SCRIPT_DIR/../bin/tkt-state"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-tkt-state.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp"
export HOME="$T/home" TMPDIR="$T/tmp"

S="$T/t.state"

# set/get round trip
bash "$TKT" "$S" set greeting hello || fail "set exits 0"
[ "$(bash "$TKT" "$S" get greeting)" = "hello" ] || fail "get returns the set value"

# set replaces every line for the key with one line
bash "$TKT" "$S" add color red || fail "first add exits 0"
bash "$TKT" "$S" add color blue || fail "second add exits 0"
bash "$TKT" "$S" set color green || fail "set over a list exits 0"
[ "$(bash "$TKT" "$S" get color)" = "green" ] || fail "set replaces the whole list"
[ "$(bash "$TKT" "$S" list color)" = "green" ] || fail "list after set prints one line"

# add builds a list read by list; get reads the first value
rm -f "$S"
bash "$TKT" "$S" add fruit apple || fail "add apple exits 0"
bash "$TKT" "$S" add fruit banana || fail "add banana exits 0"
[ "$(bash "$TKT" "$S" get fruit)" = "apple" ] || fail "get prints the first value"
[ "$(bash "$TKT" "$S" list fruit)" = "$(printf 'apple\nbanana')" ] || fail "list prints every value"

# values with spaces and = survive
bash "$TKT" "$S" set note "a b=c d" || fail "set of a value with spaces and = exits 0"
[ "$(bash "$TKT" "$S" get note)" = "a b=c d" ] || fail "a value with spaces and = survives"
bash "$TKT" "$S" add note "x=y z" || fail "add of a value with = exits 0"
[ "$(bash "$TKT" "$S" list note)" = "$(printf 'a b=c d\nx=y z')" ] || fail "list keeps spaces and ="

# a key that is a prefix of another key does not match it
bash "$TKT" "$S" set ab deep || fail "set ab exits 0"
bash "$TKT" "$S" get a >/dev/null 2>"$T/err-prefix.txt" && fail "get of a prefix-only key exits non-zero"
[ "$?" = "2" ] || fail "get of a prefix-only key exits 2"
grep -q 'a' "$T/err-prefix.txt" || fail "get of a prefix-only key names the key"

# lines without = hold no value
printf 'bareline\n' >>"$S"
bash "$TKT" "$S" get bareline >/dev/null 2>&1 && fail "a line without = is not a value"
[ "$?" = "2" ] || fail "a line without = exits 2"

# get of a missing key exits 2 and names the key on stderr
out="$(bash "$TKT" "$S" get nope 2>"$T/err-get.txt")" && fail "get of a missing key exits non-zero"
[ "$?" = "2" ] || fail "get of a missing key exits 2"
[ -z "$out" ] || fail "get of a missing key prints nothing on stdout"
grep -q 'nope' "$T/err-get.txt" || fail "get of a missing key names the key"

# get on a state file that does not exist yet is a missing key
bash "$TKT" "$T/fresh.state" get k >/dev/null 2>"$T/err-fresh.txt" && fail "get on a missing file exits non-zero"
[ "$?" = "2" ] || fail "get on a missing file exits 2"
grep -q 'k' "$T/err-fresh.txt" || fail "get on a missing file names the key"

# list of a missing key prints nothing and exits 0
out="$(bash "$TKT" "$S" list never-there 2>"$T/err-list.txt")" || fail "list of a missing key exits 0"
[ -z "$out" ] || fail "list of a missing key prints nothing"
out="$(bash "$TKT" "$T/fresh.state" list k)" || fail "list on a missing file exits 0"
[ -z "$out" ] || fail "list on a missing file prints nothing"

# require: all present exits 0; the first missing key is named with exit 2
bash "$TKT" "$S" require fruit note >/dev/null || fail "require of present keys exits 0"
bash "$TKT" "$S" require fruit absent-key 2>"$T/err-req.txt" && fail "require with a missing key exits non-zero"
[ "$?" = "2" ] || fail "require with a missing key exits 2"
grep -q 'absent-key' "$T/err-req.txt" || fail "require names the missing key"

# a held lock makes set exit 2 and names the pid in the lock
S2="$T/l.state"
mkdir "$S2.lock"
echo "424242" >"$S2.lock/pid"
bash "$TKT" "$S2" set k v 2>"$T/err-lock.txt" && fail "set under a held lock exits non-zero"
[ "$?" = "2" ] || fail "set under a held lock exits 2"
grep -q '424242' "$T/err-lock.txt" || fail "a held lock names the pid in the lock"
[ ! -e "$S2" ] || fail "a held lock writes nothing"
[ -d "$S2.lock" ] || fail "a held lock is left in place"
rm -rf "$S2.lock"

# a lock without a pid file still blocks with exit 2
S4="$T/nl.state"
mkdir "$S4.lock"
bash "$TKT" "$S4" set k v 2>"$T/err-nl-lock.txt" && fail "set under a pid-less lock exits non-zero"
[ "$?" = "2" ] || fail "set under a pid-less lock exits 2"
grep -q 'tkt-state: state locked$' "$T/err-nl-lock.txt" || fail "a pid-less lock uses the generic message"
[ -d "$S4.lock" ] || fail "a pid-less lock is left in place"
rm -rf "$S4.lock"

# a write into a missing directory exits 2 instead of hanging or writing elsewhere
bash "$TKT" "$T/nodir/s.state" set k v 2>/dev/null && fail "set into a missing directory exits non-zero"
[ "$?" = "2" ] || fail "set into a missing directory exits 2"

# a successful write leaves no lock behind
bash "$TKT" "$S" set greeting hi || fail "set exits 0"
[ ! -e "$S.lock" ] || fail "a successful write removes its lock"

# a value with a newline exits 2 and is not stored
bash "$TKT" "$S" set bad "$(printf 'x\ny')" 2>"$T/err-nl.txt" && fail "a value with a newline exits non-zero"
[ "$?" = "2" ] || fail "a value with a newline exits 2"
bash "$TKT" "$S" get bad >/dev/null 2>&1 && fail "a rejected value is not stored"
[ "$?" = "2" ] || fail "a rejected value stays missing"

# set head only stores a full 40-hex commit SHA; a short SHA would compare
# unequal to the worktree HEAD and report bogus drift on the next command
HS="$T/head.state"
bash "$TKT" "$HS" set head abc1234 2>"$T/err-short-head.txt" && fail "set head with a short SHA exits non-zero"
[ "$?" = "2" ] || fail "set head with a short SHA exits 2"
grep -q 'head' "$T/err-short-head.txt" || fail "a short head names the key"
[ ! -e "$HS" ] || fail "a rejected short head writes nothing"
FULL=0123456789abcdef0123456789abcdef01234567
bash "$TKT" "$HS" set head "$FULL" || fail "set head with a full SHA exits 0"
[ "$(bash "$TKT" "$HS" get head)" = "$FULL" ] || fail "get returns the stored full head"
bash "$TKT" "$HS" set head "${FULL%?}z" 2>/dev/null && fail "set head with non-hex exits non-zero"
[ "$?" = "2" ] || fail "set head with non-hex exits 2"
[ "$(bash "$TKT" "$HS" get head)" = "$FULL" ] || fail "a rejected non-hex head keeps the old value"
bash "$TKT" "$HS" add head abc1234 2>/dev/null && fail "add head with a short SHA exits non-zero"
[ "$?" = "2" ] || fail "add head with a short SHA exits 2"

# every other commit-valued key rejects a non-SHA on both write paths, while
# an empty reset still succeeds where callers clear the key
for basekey in plan_verdict_base verified_base review_head; do
  BKS="$T/base-$basekey.state"
  bash "$TKT" "$BKS" set "$basekey" abc1234 2>"$T/err-short-$basekey.txt" && fail "set $basekey with a short SHA exits non-zero"
  [ "$?" = "2" ] || fail "set $basekey with a short SHA exits 2"
  grep -q "$basekey" "$T/err-short-$basekey.txt" || fail "a short $basekey names the key"
  [ ! -e "$BKS" ] || fail "a rejected short $basekey writes nothing"
  bash "$TKT" "$BKS" add "$basekey" garbage 2>/dev/null && fail "add $basekey with garbage exits non-zero"
  [ "$?" = "2" ] || fail "add $basekey with garbage exits 2"
  [ ! -e "$BKS" ] || fail "a rejected $basekey add writes nothing"
  bash "$TKT" "$BKS" set "$basekey" "$FULL" || fail "set $basekey with a full SHA exits 0"
  [ "$(bash "$TKT" "$BKS" get "$basekey")" = "$FULL" ] || fail "get returns the stored full $basekey"
done
# callers clear these keys by writing empty, so an empty write still resets them
for basekey in plan_verdict_base verified_base; do
  bash "$TKT" "$T/base-$basekey.state" set "$basekey" "" || fail "set $basekey to empty exits 0"
done

# journal appends a timestamped line to the sibling .journal file
S3="$T/j.state"
bash "$TKT" "$S3" journal "hello world" || fail "journal exits 0"
[ -f "$T/j.journal" ] || fail "journal writes the sibling .journal file"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z hello world$' "$T/j.journal" || fail "journal line format"
bash "$TKT" "$S3" journal "second line" || fail "second journal exits 0"
[ "$(wc -l <"$T/j.journal" | tr -d ' ')" = "2" ] || fail "journal appends"

# a journal line with a newline exits 2 and appends nothing
bash "$TKT" "$S3" journal "$(printf 'x\ny')" 2>/dev/null && fail "a journal line with a newline exits non-zero"
[ "$?" = "2" ] || fail "a journal line with a newline exits 2"
[ "$(wc -l <"$T/j.journal" | tr -d ' ')" = "2" ] || fail "a rejected journal line appends nothing"

# usage errors exit 2 with usage on stderr
bash "$TKT" >/dev/null 2>"$T/err-u1.txt"; [ "$?" = "2" ] || fail "no args exits 2"
grep -q 'usage' "$T/err-u1.txt" || fail "no args prints usage"
for sub in get list set add journal require; do
  grep -q "^  $sub " "$T/err-u1.txt" || fail "no args usage lists the $sub subcommand"
done
bash "$TKT" "$S" >/dev/null 2>"$T/err-u4.txt"; [ "$?" = "2" ] || fail "a state file without a command exits 2"
for sub in get list set add journal require; do
  grep -q "^  $sub " "$T/err-u4.txt" || fail "a state file without a command lists the $sub subcommand"
done
for sub in get list set add journal require; do
  grep -q "^#   $sub " "$TKT" || fail "header usage block names the $sub subcommand"
done
# the header help text says set replaces every line and names add the append form
grep -q 'replace every line' "$TKT" || fail "help says set replaces every line"
grep -q 'the append form of set' "$TKT" || fail "help names add as the append form of set"
bash "$TKT" "$S" bogus >/dev/null 2>"$T/err-u2.txt"; [ "$?" = "2" ] || fail "an unknown command exits 2"
grep -q 'usage' "$T/err-u2.txt" || fail "an unknown command prints usage"
for sub in get list set add journal require; do
  grep -q "^  $sub " "$T/err-u2.txt" || fail "an unknown command usage lists the $sub subcommand"
done
bash "$TKT" "$S" get >/dev/null 2>&1; [ "$?" = "2" ] || fail "get without a key exits 2"
bash "$TKT" "$S" set onlykey >/dev/null 2>&1; [ "$?" = "2" ] || fail "set without a value exits 2"
bash "$TKT" "$S" require >/dev/null 2>&1; [ "$?" = "2" ] || fail "require without a key exits 2"
bash "$TKT" "$S" set 'a=b' v >/dev/null 2>"$T/err-u3.txt"; [ "$?" = "2" ] || fail "a key with = exits 2"
grep -q 'usage' "$T/err-u3.txt" || fail "a key with = prints usage"
bash "$TKT" "$S" get '' >/dev/null 2>&1; [ "$?" = "2" ] || fail "an empty key exits 2"

# A write retries while a live owner's lock is held, then succeeds after release.
S5="$T/retry.state"
mkdir "$S5.lock"
printf '%s %s\n' "$(hostname)" "$$" >"$S5.lock/pid"
: >"$T/retry-hit"
TKT_STATE_TEST_LOCK_SIGNAL="$T/retry-hit" bash "$TKT" "$S5" set k v 2>"$T/err-retry.txt" &
retry_pid=$!
retry_signal_count=0
retry_wait_count=0
while [ "$retry_signal_count" -lt 2 ] && kill -0 "$retry_pid" 2>/dev/null && [ "$retry_wait_count" -lt 500 ]; do
  retry_signal_count="$(wc -l <"$T/retry-hit" | tr -d ' ')"
  sleep 0.01
  retry_wait_count=$((retry_wait_count + 1))
done
retry_signal_count="$(wc -l <"$T/retry-hit" | tr -d ' ')"
if [ "$retry_signal_count" -lt 2 ]; then
  rm -rf "$S5.lock"
  retry_wait_count=0
  while kill -0 "$retry_pid" 2>/dev/null && [ "$retry_wait_count" -lt 500 ]; do
    sleep 0.01
    retry_wait_count=$((retry_wait_count + 1))
  done
  if kill -0 "$retry_pid" 2>/dev/null; then
    kill "$retry_pid" 2>/dev/null || true
    wait "$retry_pid" 2>/dev/null || true
  else
    wait "$retry_pid" 2>/dev/null || true
  fi
  fail "two failed attempts are signaled before releasing the lock"
fi
rm -rf "$S5.lock"
retry_wait_count=0
while kill -0 "$retry_pid" 2>/dev/null && [ "$retry_wait_count" -lt 500 ]; do
  sleep 0.01
  retry_wait_count=$((retry_wait_count + 1))
done
if kill -0 "$retry_pid" 2>/dev/null; then
  kill "$retry_pid" 2>/dev/null || true
  wait "$retry_pid" 2>/dev/null || true
  fail "retry writer finishes before its deadline"
fi
wait "$retry_pid" || fail "set retries until the lock is released"
[ "$(bash "$TKT" "$S5" get k)" = "v" ] || fail "retry writes the requested value"
[ ! -e "$S5.lock" ] || fail "retry leaves no lock behind"

wait_for_test_file() {
  local test_file="$1" test_count=0
  while [ ! -e "$test_file" ] && [ "$test_count" -lt 500 ]; do
    sleep 0.01
    test_count=$((test_count + 1))
  done
  [ -e "$test_file" ]
}

wait_bounded() {
  local wait_pid="$1" wait_count=0
  while kill -0 "$wait_pid" 2>/dev/null && [ "$wait_count" -lt 500 ]; do
    sleep 0.01
    wait_count=$((wait_count + 1))
  done
  if kill -0 "$wait_pid" 2>/dev/null; then
    kill "$wait_pid" 2>/dev/null || true
    wait "$wait_pid" 2>/dev/null || true
    return 1
  fi
  wait "$wait_pid"
}

# A dead lock owner on this host is reaped before writing.
S6="$T/dead-owner.state"
true &
dead_pid=$!
wait "$dead_pid"
mkdir "$S6.lock"
printf '%s %s\n' "$(hostname)" "$dead_pid" >"$S6.lock/pid"
bash "$TKT" "$S6" set k v 2>"$T/err-dead-owner.txt" || fail "set reaps a dead same-host owner"
[ "$(bash "$TKT" "$S6" get k)" = "v" ] || fail "dead-owner reaping writes the value"
[ ! -e "$S6.lock" ] || fail "dead-owner reaping leaves no lock behind"

# A killed writer releases its lock so the next writer can reap and proceed.
S9="$T/killed-holder.state"
true &
killed_dead_pid=$!
wait_bounded "$killed_dead_pid" || fail "killed-holder dead-owner setup finishes before its deadline"
mkdir "$S9.lock"
printf '%s %s\n' "$(hostname)" "$killed_dead_pid" >"$S9.lock/pid"
TKT_STATE_TEST_LOCK_PAUSE="$T/killed-holder" bash "$TKT" "$S9" set a one >"$T/killed-holder.log" 2>&1 &
killed_holder_pid=$!
if ! wait_for_test_file "$T/killed-holder.ready"; then
  kill -9 "$killed_holder_pid" 2>/dev/null || true
  wait "$killed_holder_pid" 2>/dev/null || true
  fail "killed-holder writer pauses before checking the owner"
fi
kill -9 "$killed_holder_pid" 2>/dev/null || fail "killed-holder writer is stopped"
wait_bounded "$killed_holder_pid" >/dev/null 2>&1 || true
bash "$TKT" "$S9" set k v 2>"$T/err-killed-holder.txt" || fail "writer proceeds after the lock holder is killed"
[ "$(bash "$TKT" "$S9" get k)" = "v" ] || fail "writer after killed holder stores the value"
[ ! -e "$S9.lock" ] || fail "writer after killed holder removes the dead-owner lock"

# An empty-owner directory remains held and is never reaped.
S12="$T/empty-owner.state"
mkdir "$S12.lock"
if TKT_STATE_TEST_LOCK_TRIES=3 TKT_STATE_TEST_LOCK_SLEEP=0.01 bash "$TKT" "$S12" set k v 2>"$T/err-empty-owner.txt"; then
  empty_owner_rc=0
else
  empty_owner_rc=$?
fi
[ "$empty_owner_rc" = "2" ] || fail "empty-owner lock exits 2"
grep -q 'tkt-state: state locked' "$T/err-empty-owner.txt" || fail "empty-owner lock reports state locked"
grep -Fq "$S12.lock" "$T/err-empty-owner.txt" || fail "empty-owner message names the lock directory"
[ -d "$S12.lock" ] || fail "empty-owner lock is left in place"

# A lock attributed to another host is never reaped.
S7="$T/other-host.state"
mkdir "$S7.lock"
printf 'otherhost-not-this-host 4242\n' >"$S7.lock/pid"
if TKT_STATE_TEST_LOCK_TRIES=3 TKT_STATE_TEST_LOCK_SLEEP=0.01 bash "$TKT" "$S7" set k v 2>"$T/err-other-host.txt"; then
  other_host_rc=0
else
  other_host_rc=$?
fi
[ "$other_host_rc" = "2" ] || fail "other-host lock exits 2"
grep -q '4242' "$T/err-other-host.txt" || fail "other-host lock names its pid"
[ -d "$S7.lock" ] || fail "other-host lock is left in place"

# A live same-host owner remains locked after the retry budget.
S8="$T/live-owner.state"
mkdir "$S8.lock"
printf '%s %s\n' "$(hostname)" "$$" >"$S8.lock/pid"
if TKT_STATE_TEST_LOCK_TRIES=3 TKT_STATE_TEST_LOCK_SLEEP=0.01 bash "$TKT" "$S8" set k v 2>"$T/err-live-owner.txt"; then
  live_owner_rc=0
else
  live_owner_rc=$?
fi
[ "$live_owner_rc" = "2" ] || fail "live-owner lock exits 2 after the budget"
grep -q "state locked by pid $$" "$T/err-live-owner.txt" || fail "live-owner lock names the holder"
[ -d "$S8.lock" ] || fail "live-owner lock is left in place"

# Reads ignore a held write lock.
S10="$T/read-under-lock.state"
printf 'k=first\nk=second\n' >"$S10"
mkdir "$S10.lock"
printf '%s %s\n' "$(hostname)" "$$" >"$S10.lock/pid"
[ "$(bash "$TKT" "$S10" get k)" = "first" ] || fail "get succeeds under a held lock"
[ "$(bash "$TKT" "$S10" list k)" = "$(printf 'first\nsecond')" ] || fail "list succeeds under a held lock"
[ -d "$S10.lock" ] || fail "reads leave the held lock in place"
rm -rf "$S10.lock"

# Concurrent writers arbitrate dead-lock reaping and both retain their values.
for race_round in {1..20}; do
  race_state="$T/reaper-race-$race_round.state"
  sleep 0 &
  race_dead_pid=$!
  wait_bounded "$race_dead_pid" || fail "race dead-owner setup finishes before its deadline"
  mkdir "$race_state.lock"
  printf '%s %s\n' "$(hostname)" "$race_dead_pid" >"$race_state.lock/pid"
  bash "$TKT" "$race_state" add a "a-$race_round" >"$T/race-a-$race_round.log" 2>&1 &
  race_a_pid=$!
  bash "$TKT" "$race_state" add b "b-$race_round" >"$T/race-b-$race_round.log" 2>&1 &
  race_b_pid=$!
  if wait_bounded "$race_a_pid"; then
    race_a_rc=0
  else
    race_a_rc=$?
  fi
  if wait_bounded "$race_b_pid"; then
    race_b_rc=0
  else
    race_b_rc=$?
  fi
  [ "$race_a_rc" = "0" ] || fail "race writer a succeeds in round $race_round"
  [ "$race_b_rc" = "0" ] || fail "race writer b succeeds in round $race_round"
  [ "$(bash "$TKT" "$race_state" list a)" = "a-$race_round" ] || fail "race value a survives in round $race_round"
  [ "$(bash "$TKT" "$race_state" list b)" = "b-$race_round" ] || fail "race value b survives in round $race_round"
  [ ! -e "$race_state.lock" ] || fail "race leaves no lock in round $race_round"
done

# A paused writer holds the flock while the dead-owner directory remains untouched.
S11="$T/paused-writer.state"
true &
paused_dead_pid=$!
wait_bounded "$paused_dead_pid" || fail "paused-writer dead-owner setup finishes before its deadline"
mkdir "$S11.lock"
printf '%s %s\n' "$(hostname)" "$paused_dead_pid" >"$S11.lock/pid"
cp "$S11.lock/pid" "$T/lp-seeded.pid"
: >"$T/lp-b.sig"
(
  if TKT_STATE_TEST_LOCK_PAUSE="$T/lp-a" bash "$TKT" "$S11" set a one >"$T/lp-a.log" 2>&1; then
    lp_a_rc=0
  else
    lp_a_rc=$?
  fi
  printf '%s\n' "$lp_a_rc" >"$T/lp-a.result"
) &
lp_a_pid=$!
abort_lp() {
  touch "$T/lp-a.release"
  wait_bounded "$lp_a_pid" || true
  fail "$1"
}
if ! wait_for_test_file "$T/lp-a.ready"; then
  abort_lp "first writer pauses while holding the flock"
fi
if TKT_STATE_TEST_LOCK_TRIES=3 TKT_STATE_TEST_LOCK_SLEEP=0.01 TKT_STATE_TEST_LOCK_SIGNAL="$T/lp-b.sig" bash "$TKT" "$S11" set b two >"$T/lp-b.log" 2>&1; then
  lp_b_rc=0
else
  lp_b_rc=$?
fi
if [ "$lp_b_rc" != "2" ]; then
  abort_lp "second writer exits 2 while the first holds the flock"
fi
if [ ! -s "$T/lp-b.sig" ]; then
  abort_lp "second writer signals its failed flock attempts"
fi
if ! cmp -s "$T/lp-seeded.pid" "$S11.lock/pid"; then
  abort_lp "second writer does not reap the seeded owner outside the flock"
fi
if bash "$TKT" "$S11" get b >/dev/null 2>&1; then
  abort_lp "second writer does not write while the first holds the flock"
else
  lp_b_missing_rc=$?
fi
[ "$lp_b_missing_rc" = "2" ] || abort_lp "second writer's missing value exits 2"
touch "$T/lp-a.release"
wait_bounded "$lp_a_pid" || fail "first writer finishes after release"
[ "$(cat "$T/lp-a.result")" = "0" ] || fail "first writer succeeds after release"
[ "$(bash "$TKT" "$S11" get a)" = "one" ] || fail "first writer value is retained"
[ ! -e "$S11.lock" ] || fail "first writer leaves no state lock"
bash "$TKT" "$S11" set b two || fail "a fresh writer succeeds after the first releases the flock"
[ "$(bash "$TKT" "$S11" get b)" = "two" ] || fail "fresh writer stores its value"
[ -f "$S11.flock" ] || fail "a successful write leaves the persistent flock file"

# A partly written owner record is treated like an empty pid file.
S14="$T/partial-owner.state"
mkdir "$S14.lock"
printf '%s ' "$(hostname)" >"$S14.lock/pid"
if TKT_STATE_TEST_LOCK_TRIES=3 TKT_STATE_TEST_LOCK_SLEEP=0.01 bash "$TKT" "$S14" set k v 2>"$T/err-partial-owner.txt"; then
  partial_owner_rc=0
else
  partial_owner_rc=$?
fi
[ "$partial_owner_rc" = "2" ] || fail "partial-owner lock exits 2"
grep -q 'tkt-state: state locked$' "$T/err-partial-owner.txt" || fail "partial-owner lock uses the empty-owner message"
grep -Fq "$S14.lock" "$T/err-partial-owner.txt" || fail "partial-owner message names the lock directory"
[ -d "$S14.lock" ] || fail "partial-owner lock is left in place"

# Only flock's contention status is retried; neighboring statuses fail closed.
mkdir "$T/python-bin"
cat >"$T/python-bin/python3" <<'EOF'
#!/bin/sh
exit "$TKT_STATE_TEST_PYTHON_EXIT"
EOF
chmod 755 "$T/python-bin/python3"
for python_exit in 2 3 4 127; do
  python_state="$T/python-exit-$python_exit.state"
  python_signal="$T/python-exit-$python_exit.signal"
  python_error="$T/python-exit-$python_exit.err"
  : >"$python_signal"
  if PATH="$T/python-bin:$PATH" TKT_STATE_TEST_PYTHON_EXIT="$python_exit" TKT_STATE_TEST_LOCK_TRIES=3 TKT_STATE_TEST_LOCK_SLEEP=0.01 TKT_STATE_TEST_LOCK_SIGNAL="$python_signal" bash "$TKT" "$python_state" set k v 2>"$python_error"; then
    python_probe_rc=0
  else
    python_probe_rc=$?
  fi
  [ "$python_probe_rc" = "2" ] || fail "python probe status $python_exit exits 2"
  grep -Fq "tkt-state: cannot lock $python_state" "$python_error" || fail "python probe status $python_exit reports cannot lock"
  if [ "$python_exit" = "3" ]; then
    [ "$(wc -l <"$python_signal" | tr -d ' ')" = "3" ] || fail "flock status 3 uses the full retry budget"
  else
    [ ! -s "$python_signal" ] || fail "python probe status $python_exit is not retried"
  fi
  [ ! -e "$python_state.lock" ] || fail "python probe status $python_exit does not create a state lock"
done

# A stale lock that cannot be removed reports the lock path instead of retrying forever.
if [ "$(id -u)" = "0" ]; then
  echo "SKIP: stale-lock removal case cannot run as root"
else
  S13="$T/stale-lock.state"
  : >"$S13.flock"
  mkdir "$S13.lock"
  true &
  stale_dead_pid=$!
  wait_bounded "$stale_dead_pid" || fail "stale-lock dead-owner setup finishes before its deadline"
  printf '%s %s\n' "$(hostname)" "$stale_dead_pid" >"$S13.lock/pid"
  : >"$T/err-stale-lock.txt"
  stale_parent_readonly=0
  restore_test_tmp() {
    if [ "$stale_parent_readonly" = "1" ]; then
      chmod u+w "$T"
    fi
    rm -rf "$T"
  }
  trap restore_test_tmp EXIT
  stale_parent_readonly=1
  chmod a-w "$T"
  if TKT_STATE_TEST_LOCK_TRIES=3 TKT_STATE_TEST_LOCK_SLEEP=0.01 bash "$TKT" "$S13" set k v 2>"$T/err-stale-lock.txt"; then
    stale_lock_rc=0
  else
    stale_lock_rc=$?
  fi
  chmod u+w "$T"
  stale_parent_readonly=0
  [ "$stale_lock_rc" = "2" ] || fail "unremovable stale lock exits 2"
  grep -q 'stale lock not removed' "$T/err-stale-lock.txt" || fail "unremovable stale lock reports the stale-lock error"
  grep -Fq "$S13.lock" "$T/err-stale-lock.txt" || fail "unremovable stale-lock message names the lock directory"
fi

echo "tkt-state: all cases passed"

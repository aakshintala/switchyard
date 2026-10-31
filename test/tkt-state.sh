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
bash "$TKT" "$S4" set k v 2>/dev/null && fail "set under a pid-less lock exits non-zero"
[ "$?" = "2" ] || fail "set under a pid-less lock exits 2"
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
# the header help text says set replaces every line and names add the append form
grep -q 'replace every line' "$TKT" || fail "help says set replaces every line"
grep -q 'the append form of set' "$TKT" || fail "help names add as the append form of set"
bash "$TKT" "$S" bogus >/dev/null 2>"$T/err-u2.txt"; [ "$?" = "2" ] || fail "an unknown command exits 2"
grep -q 'usage' "$T/err-u2.txt" || fail "an unknown command prints usage"
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
(
  sleep 0.3
  rm -rf "$S5.lock"
) &
release_pid=$!
if TKT_STATE_TEST_LOCK_TRIES=50 TKT_STATE_TEST_LOCK_SLEEP=0.05 bash "$TKT" "$S5" set k v 2>"$T/err-retry.txt"; then
  retry_rc=0
else
  retry_rc=$?
fi
wait_count=0
while kill -0 "$release_pid" 2>/dev/null && [ "$wait_count" -lt 500 ]; do
  sleep 0.01
  wait_count=$((wait_count + 1))
done
if kill -0 "$release_pid" 2>/dev/null; then
  kill "$release_pid" 2>/dev/null || true
  wait "$release_pid" 2>/dev/null || true
  fail "lock release finishes before its deadline"
fi
wait "$release_pid" || fail "lock release exits 0"
[ "$retry_rc" = "0" ] || fail "set retries until the lock is released"
[ "$(bash "$TKT" "$S5" get k)" = "v" ] || fail "retry writes the requested value"
[ ! -e "$S5.lock" ] || fail "retry leaves no lock behind"

echo "tkt-state: all cases passed"

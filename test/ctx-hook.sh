#!/usr/bin/env bash
# Tests for bin/ctx-hook, against temp transcripts and a temp state dir (never the real ~/.cache).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../bin/ctx-hook"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-ctx-hook.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export CTX_HOOK_DIR="$T/state"
unset CTX_HOOK_WARN CTX_HOOK_URGENT

# transcript <file> <total>: a user line, one assistant usage line summing to <total>
# across the three fields, then a user line. Needs <total> >= 1000.
transcript() {
  printf '%s\n' '{"type":"user","message":{"content":"hi"}}' \
    "{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":$(($2 - 1000)),\"cache_read_input_tokens\":600,\"cache_creation_input_tokens\":400}}}" \
    '{"type":"user","message":{"content":"ok"}}' >"$1"
}
# big <file> <total> <usage-at-top|usage-at-end>: a transcript over 2 MB of filler lines.
big() {
  local filler
  filler='{"type":"user","message":{"content":"'"$(printf 'x%.0s' $(seq 1000))"'"}}'
  {
    if [ "$3" = usage-at-top ]; then
      printf '{"message":{"usage":{"input_tokens":%s}}}\n' "$2"
    fi
    yes "$filler" | head -n 2600
    if [ "$3" = usage-at-end ]; then
      printf '{"message":{"usage":{"input_tokens":%s}}}\n' "$2"
    fi
  } >"$1"
}

# run <session_id> <transcript_path>: runs the hook; leaves stdout in $out, exit code in $rc.
run() {
  out="$(jq -cn --arg s "$1" --arg t "$2" '{session_id:$s, transcript_path:$t}' | bash "$HOOK" 2>/dev/null)"
  rc=$?
}

# want <N>: the exact output for a level at N thousand tokens.
want() {
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"Context is at %sk of the 120k autocompact. Finish the current item, then update your state file (current state only), before starting anything new."}}\n' "$1"
}

S1="$T/s1.jsonl"
transcript "$S1" 99999
run s1 "$S1"
[ "$rc" = 0 ] || fail "below threshold exits 0 (got $rc)"
[ -z "$out" ] || fail "below threshold is silent: [$out]"

transcript "$S1" 100000
run s1 "$S1"
[ "$rc" = 0 ] || fail "at threshold exits 0 (got $rc)"
[ "$out" = "$(want 100)" ] || fail "at threshold emits the warn text for 100k: [$out]"

run s1 "$S1"
[ "$rc" = 0 ] || fail "second call exits 0 (got $rc)"
[ -z "$out" ] || fail "second call same session is silent: [$out]"

transcript "$S1" 115000
run s1 "$S1"
[ "$out" = "$(want 115)" ] || fail "urgent level emits once for 115k: [$out]"

transcript "$S1" 116000
run s1 "$S1"
[ -z "$out" ] || fail "urgent level stays silent after its emit: [$out]"

S2="$T/s2.jsonl"
transcript "$S2" 100000
run s2 "$S2"
[ "$out" = "$(want 100)" ] || fail "different session emits again: [$out]"

run s3 "$T/missing.jsonl"
[ "$rc" = 0 ] || fail "missing transcript exits 0 (got $rc)"
[ -z "$out" ] || fail "missing transcript is silent: [$out]"

out="$(printf 'not json {' | bash "$HOOK" 2>/dev/null)"
rc=$?
[ "$rc" = 0 ] || fail "garbage stdin exits 0 (got $rc)"
[ -z "$out" ] || fail "garbage stdin is silent: [$out]"

printf 'no usage here\n' >"$T/nousage.jsonl"
run s4 "$T/nousage.jsonl"
[ "$rc" = 0 ] && [ -z "$out" ] || fail "transcript without usage is silent: [$out] rc $rc"

BIG="$T/big.jsonl"
big "$BIG" 105000 usage-at-end
[ "$(wc -c <"$BIG" | tr -d ' ')" -gt 2097152 ] || fail "big fixture is over 2 MB"
run s5 "$BIG"
[ "$out" = "$(want 105)" ] || fail "over 2 MB with usage near the end still emits: [$out]"

big "$T/bigtop.jsonl" 150000 usage-at-top
run s6 "$T/bigtop.jsonl"
[ -z "$out" ] || fail "usage outside the 2 MB tail is not read: [$out]"

echo "ctx-hook: all cases passed"

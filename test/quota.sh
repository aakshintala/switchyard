#!/usr/bin/env bash
# Tests for bin/quota --route, against fixture feeds (never the live feed).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/../bin/quota"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-quota.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# route FIXTURE: run quota --route against a fixture feed file; sets OUT and RC.
route() {
  OUT="$(QUOTA_FEED="file://$1" bash "$BIN" --route 2>"$T/err")"
  RC=$?
  [ ! -s "$T/err" ] || fail "stderr not empty: [$(cat "$T/err")]"
}

# Depleted first choice: claude is depleted, so every tier routes to codex.
cat >"$T/depleted-first.json" <<'FIXTURE'
{"providers":[
  {"id":"claude","status":"depleted","quotas":[{"key":"weekly","label":"Weekly","percentRemaining":0,"resetText":"Resets in 14h"}]},
  {"id":"codex","status":"healthy","quotas":[{"key":"session","label":"Session","percentRemaining":93,"resetText":"Resets in 6d"}]},
  {"id":"cursor","status":"warning","quotas":[{"key":"time:Monthly","label":"Monthly","percentRemaining":20,"resetText":"Resets in 25d"}]}
]}
FIXTURE
route "$T/depleted-first.json"
[ "$RC" = 0 ] || fail "depleted first choice: exit $RC, want 0"
[ "$OUT" = "tier standard: codex (healthy)
tier strong: codex (healthy)
tier frontier: codex (healthy)" ] || fail "depleted first choice output was:
$OUT"

# Tie: cursor and codex are both warning, so feed order wins; critical loses.
# An unavailable claude with a healthy status must not win.
cat >"$T/tie.json" <<'FIXTURE'
{"providers":[
  {"id":"claude","status":"healthy","unavailable":"no oauth token","quotas":[]},
  {"id":"cursor","status":"warning","quotas":[{"key":"time:Monthly","label":"Monthly","percentRemaining":20,"resetText":"Resets in 25d"}]},
  {"id":"codex","status":"warning","quotas":[{"key":"session","label":"Session","percentRemaining":40,"resetText":"Resets in 6d"}]},
  {"id":"muse","status":"critical","quotas":[{"key":"weekly","label":"Weekly","percentRemaining":2,"resetText":"Resets in 4d"}]}
]}
FIXTURE
route "$T/tie.json"
[ "$RC" = 0 ] || fail "tie: exit $RC, want 0"
[ "$OUT" = "tier standard: cursor (warning)
tier strong: cursor (warning)
tier frontier: cursor (warning)" ] || fail "tie output was:
$OUT"

# Every provider depleted: every tier is none, exit 1.
cat >"$T/all-depleted.json" <<'FIXTURE'
{"providers":[
  {"id":"claude","status":"depleted","quotas":[]},
  {"id":"codex","status":"depleted","quotas":[]}
]}
FIXTURE
route "$T/all-depleted.json"
[ "$RC" = 1 ] || fail "all depleted: exit $RC, want 1"
[ "$OUT" = "tier standard: none
tier strong: none
tier frontier: none" ] || fail "all depleted output was:
$OUT"

# The script's tier list stays in step with the ladder in skills/delegate.
TIERS="$(grep -E '^[[:space:]]*TIERS=' "$BIN" | sed -E 's/^[[:space:]]*TIERS="//; s/"$//')" || fail "no TIERS list in $BIN"
[ -n "$TIERS" ] || fail "empty TIERS list in $BIN"
LADDER="$(awk '/^## Model ladder/{f=1;next} /^## /{f=0} f' "$SCRIPT_DIR/../skills/delegate/SKILL.md" \
  | grep -E '^- `[a-z]+`:' | sed -E 's/^- `([a-z]+)`.*/\1/' | tr '\n' ' ')"
[ "$TIERS " = "$LADDER" ] || fail "TIERS [$TIERS] is not the ladder [$LADDER]"

echo "quota: ok"

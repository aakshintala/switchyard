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

# Different tier winners: muse is healthy so standard and strong route to
# muse, but muse carries no frontier rung, so frontier falls to codex.
cat >"$T/tier-winners.json" <<'FIXTURE'
{"providers":[
  {"id":"muse","status":"healthy","quotas":[{"key":"weekly","label":"Weekly","percentRemaining":80,"resetText":"Resets in 4d"}]},
  {"id":"codex","status":"warning","quotas":[{"key":"session","label":"Session","percentRemaining":40,"resetText":"Resets in 6d"}]},
  {"id":"cursor","status":"critical","quotas":[{"key":"time:Monthly","label":"Monthly","percentRemaining":2,"resetText":"Resets in 25d"}]}
]}
FIXTURE
route "$T/tier-winners.json"
[ "$RC" = 0 ] || fail "tier winners: exit $RC, want 0"
[ "$OUT" = "tier standard: muse (healthy)
tier strong: muse (healthy)
tier frontier: codex (warning)" ] || fail "tier winners output was:
$OUT"

# opencode-go (muse at $0.20) carries standard and strong and ranks ahead of
# codex ($0.50) on a tie, even when the feed lists codex first.
cat >"$T/opencode-tie.json" <<'FIXTURE'
{"providers":[
  {"id":"codex","status":"healthy","quotas":[{"key":"session","label":"Session","percentRemaining":40,"resetText":"Resets in 6d"}]},
  {"id":"opencode-go","status":"healthy","quotas":[{"key":"weekly","label":"Weekly","percentRemaining":90,"resetText":"Resets in 4d"}]}
]}
FIXTURE
route "$T/opencode-tie.json"
[ "$RC" = 0 ] || fail "opencode tie: exit $RC, want 0"
[ "$OUT" = "tier standard: opencode-go (healthy)
tier strong: opencode-go (healthy)
tier frontier: codex (healthy)" ] || fail "opencode tie output was:
$OUT"

# Tie: codex is healthy but listed after muse, so the tier list wins over
# feed order; cursor leads the frontier list. Permuting the feed must not
# change the output.
cat >"$T/tie-codex-first.json" <<'FIXTURE'
{"providers":[
  {"id":"codex","status":"healthy","quotas":[{"key":"session","label":"Session","percentRemaining":40,"resetText":"Resets in 6d"}]},
  {"id":"muse","status":"healthy","quotas":[{"key":"weekly","label":"Weekly","percentRemaining":80,"resetText":"Resets in 4d"}]},
  {"id":"cursor","status":"healthy","quotas":[{"key":"time:Monthly","label":"Monthly","percentRemaining":90,"resetText":"Resets in 25d"}]}
]}
FIXTURE
route "$T/tie-codex-first.json"
[ "$RC" = 0 ] || fail "tie: exit $RC, want 0"
[ "$OUT" = "tier standard: muse (healthy)
tier strong: muse (healthy)
tier frontier: cursor (healthy)" ] || fail "tie output was:
$OUT"
cat >"$T/tie-muse-first.json" <<'FIXTURE'
{"providers":[
  {"id":"muse","status":"healthy","quotas":[{"key":"weekly","label":"Weekly","percentRemaining":80,"resetText":"Resets in 4d"}]},
  {"id":"codex","status":"healthy","quotas":[{"key":"session","label":"Session","percentRemaining":40,"resetText":"Resets in 6d"}]},
  {"id":"cursor","status":"healthy","quotas":[{"key":"time:Monthly","label":"Monthly","percentRemaining":90,"resetText":"Resets in 25d"}]}
]}
FIXTURE
route "$T/tie-muse-first.json"
[ "$RC" = 0 ] || fail "tie permuted: exit $RC, want 0"
[ "$OUT" = "tier standard: muse (healthy)
tier strong: muse (healthy)
tier frontier: cursor (healthy)" ] || fail "tie permuted output was:
$OUT"

# Depleted first choice: muse is depleted, so standard and strong fall to
# claude (healthy, next in their lists); frontier skips muse either way.
cat >"$T/depleted-first.json" <<'FIXTURE'
{"providers":[
  {"id":"muse","status":"depleted","quotas":[{"key":"weekly","label":"Weekly","percentRemaining":0,"resetText":"Resets in 14h"}]},
  {"id":"claude","status":"healthy","quotas":[{"key":"weekly","label":"Weekly","percentRemaining":70,"resetText":"Resets in 4d"}]},
  {"id":"codex","status":"healthy","quotas":[{"key":"session","label":"Session","percentRemaining":93,"resetText":"Resets in 6d"}]}
]}
FIXTURE
route "$T/depleted-first.json"
[ "$RC" = 0 ] || fail "depleted first choice: exit $RC, want 0"
[ "$OUT" = "tier standard: claude (healthy)
tier strong: claude (healthy)
tier frontier: codex (healthy)" ] || fail "depleted first choice output was:
$OUT"

# Every provider depleted: every tier is none, exit 1.
cat >"$T/all-depleted.json" <<'FIXTURE'
{"providers":[
  {"id":"muse","status":"depleted","quotas":[]},
  {"id":"claude","status":"depleted","quotas":[]},
  {"id":"codex","status":"depleted","quotas":[]},
  {"id":"cursor","status":"depleted","quotas":[]}
]}
FIXTURE
route "$T/all-depleted.json"
[ "$RC" = 1 ] || fail "all depleted: exit $RC, want 1"
[ "$OUT" = "tier standard: none
tier strong: none
tier frontier: none" ] || fail "all depleted output was:
$OUT"

# The script's tiers stay in step with the ladder in skills/delegate: each
# tier name is a rung there, and muse is absent from the frontier list,
# matching the muse backend note (standard and strong only).
TIERS="$(grep -E '^[[:space:]]*TIERS=' "$BIN" | sed -E 's/^[[:space:]]*TIERS="//; s/"$//')" || fail "no TIERS list in $BIN"
[ -n "$TIERS" ] || fail "empty TIERS list in $BIN"
for tier in $TIERS; do
  grep -qF '`'"$tier"'`:' "$SCRIPT_DIR/../skills/delegate/SKILL.md" \
    || fail "tier $tier is not a rung in skills/delegate/SKILL.md"
done
FRONTIER="$(grep -E '^[[:space:]]*FRONTIER=' "$BIN" | sed -E 's/^[[:space:]]*FRONTIER="//; s/"$//')" || fail "no FRONTIER list in $BIN"
[ -n "$FRONTIER" ] || fail "empty FRONTIER list in $BIN"
case " $FRONTIER " in
  *" muse "*) fail "muse must not be in the FRONTIER list (skills/delegate/SKILL.md: muse carries only standard and strong)" ;;
esac

echo "quota: ok"

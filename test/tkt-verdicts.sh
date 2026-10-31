#!/usr/bin/env bash
# Keep the implement skill's go-on table current with verdicts emitted by bin/tkt-*.
# Usage: test/tkt-verdicts.sh [ROOT] (default: this repo).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$SCRIPT_DIR/..}"
SKILL="$ROOT/skills/implement/SKILL.md"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -r "$SKILL" ] || fail "cannot read $SKILL"

words="$(grep -hEo '(emit|deny) \"[A-Z][A-Z-]*|verdict=\"[A-Z][A-Z-]*|RV=\"[A-Z][A-Z-]*|TKT tkt-[[:alnum:]-]+ [A-Z][A-Z-]*' "$ROOT"/bin/tkt-* | grep -Eo '[A-Z][A-Z-]*$' | sort -u)"
missing=0
while IFS= read -r word; do
  [ -n "$word" ] || continue
  if ! grep -Eq "(^|[^[:alnum:]_-])${word}([^[:alnum:]_-]|$)" "$SKILL"; then
    echo "missing verdict word in skills/implement/SKILL.md: $word" >&2
    missing=1
  fi
done <<< "$words"

[ "$missing" -eq 0 ] || exit 1
echo "tkt-verdicts: all emitted words are documented"

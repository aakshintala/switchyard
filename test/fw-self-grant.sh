#!/usr/bin/env bash
# Self-grant reads the posted Files paths, and records an empty grant when none exist.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/fw-self-grant.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/stubs"
export FW_RUN="$T/run" PLAN_BODY="$T/plan.md" FG_LOG="$T/fence-grant.log"
export FW_GH="$T/stubs/gh" FW_FENCE_GRANT="$T/stubs/fence-grant"

cat >"$FW_GH" <<'GH'
#!/usr/bin/env bash
cat "$PLAN_BODY"
GH
cat >"$FW_FENCE_GRANT" <<'FG'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FG_LOG"
ticket=$1
empty=0
dry=0
paths=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --empty) empty=1; shift;;
    --dry) dry=1; shift;;
    --paths) paths=$2; shift 2;;
    *) shift;;
  esac
done
[ "$dry" -eq 1 ] && exit 0
if [ "$empty" -eq 1 ]; then
  printf 'Grant 1 (fence-grant, test)\n\nTicket: %s\nPart: 1\nPaths:\nRanges: none\n' "$ticket" \
    >"$FW_RUN/fiber-$ticket-fence-grant-1.md"
else
  [ -n "$paths" ] || exit 2
  printf 'Grant 1 (fence-grant, test)\n\nTicket: %s\nPart: 1\nPaths:\n- %s\nRanges: none\n' "$ticket" "$paths" \
    >"$FW_RUN/fiber-$ticket-fence-grant-1.md"
fi
FG
chmod +x "$FW_GH" "$FW_FENCE_GRANT"

. "$here/../bin/lib/fw-lib.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

cat >"$PLAN_BODY" <<'PLAN'
## Files

- `src/main.c`

## Gate

`true`
PLAN
fw_self_grant test 1607 "$FW_RUN" 2>"$T/paths.stderr" || fail "plan with a path self-grants"
[ -f "$FW_RUN/fiber-1607-fence-grant-1.md" ] || fail "path plan writes a grant"
grep -q '^1607 --repo [^ ]* --paths src/main.c --dry$' "$FG_LOG" || fail "self-grant probes the path"
grep -q '^1607 --repo [^ ]* --paths src/main.c$' "$FG_LOG" || fail "path without a line range is granted whole"
! grep -q -- '--ranges' "$FG_LOG" || fail "path without a line range does not invent one"
grep -q '^- src/main.c$' "$FW_RUN/fiber-1607-fence-grant-1.md" || fail "whole-file path is in grant Paths"
grep -q '^Ranges: none$' "$FW_RUN/fiber-1607-fence-grant-1.md" || fail "whole-file grant has no line ranges"

rm -f "$FW_RUN/fiber-1607-fence-grant-1.md"
: >"$PLAN_BODY"
: >"$FG_LOG"
fw_self_grant test 1608 "$FW_RUN" 2>"$T/empty.stderr" || fail "missing plan self-grants empty"
[ -f "$FW_RUN/fiber-1608-fence-grant-1.md" ] || fail "missing plan writes an empty grant"
grep -q '^1608 --empty$' "$FG_LOG" || fail "missing plan requests an empty grant"
grep -q '^Paths:$' "$FW_RUN/fiber-1608-fence-grant-1.md" || fail "empty grant uses the standard Paths block"
grep -q '^Ranges: none$' "$FW_RUN/fiber-1608-fence-grant-1.md" || fail "empty grant uses the standard Ranges line"
printf 'ok fw-self-grant-whole-file-and-empty\n'

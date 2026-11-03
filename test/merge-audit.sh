#!/usr/bin/env bash
# Tests for bin/merge-audit, using a stand-in gh serving fixture files from
# test/fixtures/merge-audit (no network). $FAKE_PULLS and $FAKE_RULESET pick
# the fixture; any api path containing $FAKE_FAIL fails like a 404.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT="$SCRIPT_DIR/../bin/merge-audit"
export FIX="$SCRIPT_DIR/fixtures/merge-audit"

fail() {
  echo "FAIL: $1" >&2
  [ -n "${out:-}" ] && printf '%s\n' "--- output:" "$out" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-merge-audit.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export FAKE_GH_LOG="$T/gh.log"
export MERGE_AUDIT_NOW="2026-11-02T06:00:00Z"

cat >"$T/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
echo "gh $*" >>"$FAKE_GH_LOG"
[ "$#" -eq 2 ] && [ "$1" = api ] || { echo "fake gh: want 'gh api <path>', got: $*" >&2; exit 2; }
path="$2"
if [ -n "${FAKE_FAIL:-}" ] && [[ "$path" == *"$FAKE_FAIL"* ]]; then
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
fi
serve() { [ -e "$FIX/$1" ] || { echo "fake gh: no fixture $1 for $path" >&2; exit 2; }; cat "$FIX/$1"; }
case "$path" in
  repos/o/r) serve repo.json;;
  repos/o/r/pulls\?*) case "$path" in *page=1) serve "${FAKE_PULLS:-pulls.json}";; *) echo '[]';; esac;;
  repos/o/r/pulls/*) serve "pr-${path##*/}.json";;
  repos/o/r/commits/*/check-runs\?*) sha="${path#repos/o/r/commits/}"; serve "checks-${sha%%/*}.json";;
  repos/o/r/rulesets/24219615) serve "${FAKE_RULESET:-ruleset-empty.json}";;
  *) echo "fake gh: unknown path $path" >&2; exit 2;;
esac
FAKEGH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

run() { # run <args...>: sets out and rc
  out="$(python3 "$AUDIT" "$@" 2>&1)"
  rc=$?
}
has() { grep -qF -- "$1" <<<"$out" || fail "$2: missing [$1]"; }
hasnt() { grep -qF -- "$1" <<<"$out" && fail "$2: unexpected [$1]"; return 0; }
SINCE=(--since 2026-10-31T00:00:00Z)

# 1. Break-glass merge with red CI and a merge with no CI run are listed;
#    the green merge, the unmerged PR and the merge before the cutoff are not.
run --repo o/r "${SINCE[@]}" --ruleset 24219615
[ "$rc" -eq 0 ] || fail "listed merges: exit $rc, want 0"
has "merge-without-green-ci: #10 merger=aakshintala head=aaaa000000000000000000000000000000000010 ci=failure break-glass=yes" "break-glass merge"
has "merge-without-green-ci: #14 merger=octo-merger head=eeee000000000000000000000000000000000014 ci=none break-glass=no" "no-CI merge"
hasnt "#11" "green merge"
hasnt "#12" "merge before cutoff"
hasnt "#13" "unmerged PR"
hasnt "merges-without-green-ci: none" "listed merges"
has "ruleset 24219615 bypass: empty" "empty bypass list"
grep -v '^gh api [^ ]*$' "$FAKE_GH_LOG" && fail "gh called other than 'gh api <path>'"

# 2. Only a green merge: one explicit none line.
FAKE_PULLS=pulls-green.json run --repo o/r "${SINCE[@]}"
[ "$rc" -eq 0 ] || fail "none: exit $rc, want 0"
[ "$(grep -c '^merges-without-green-ci: none$' <<<"$out")" -eq 1 ] || fail "none: want one none line"
hasnt "ruleset" "no --ruleset prints no ruleset line"

# 3. Non-empty bypass list: a warning naming each actor and its mode.
FAKE_RULESET=ruleset-bypass.json run --repo o/r "${SINCE[@]}" --ruleset 24219615
[ "$rc" -eq 0 ] || fail "bypass: exit $rc, want 0"
has "WARNING: ruleset 24219615 bypass: RepositoryRole 5 mode=always, OrganizationAdmin mode=pull_request" "bypass warning"
hasnt "empty" "bypass warning"

# 4. Failed merge read: error line, never none, non-zero exit; ruleset still read.
FAKE_FAIL="pulls?" run --repo o/r "${SINCE[@]}" --ruleset 24219615
[ "$rc" -eq 1 ] || fail "failed merge read: exit $rc, want 1"
has "error: merges unread: gh api repos/o/r/pulls?" "failed merge read"
has "Not Found (HTTP 404)" "failed merge read"
hasnt "merges-without-green-ci: none" "failed merge read"
has "ruleset 24219615 bypass: empty" "failed merge read still reads ruleset"

# 5. Failed check-run read for one PR: error line for it, never none.
FAKE_FAIL="aaaa000000000000000000000000000000000010/check-runs" run --repo o/r "${SINCE[@]}"
[ "$rc" -eq 1 ] || fail "failed check read: exit $rc, want 1"
has "error: #10 unread:" "failed check read"
has "merge-without-green-ci: #14" "failed check read still lists the others"
hasnt "merges-without-green-ci: none" "failed check read"

# 6. Failed ruleset read: error line, never empty, non-zero exit.
FAKE_FAIL="rulesets" run --repo o/r "${SINCE[@]}" --ruleset 24219615
[ "$rc" -eq 1 ] || fail "failed ruleset read: exit $rc, want 1"
has "error: ruleset 24219615 unread:" "failed ruleset read"
hasnt "empty" "failed ruleset read"

# 7. A ruleset without bypass_actors (token lacks admin) is a failed read.
FAKE_RULESET=repo.json run --repo o/r "${SINCE[@]}" --ruleset 24219615
[ "$rc" -eq 1 ] || fail "no bypass_actors: exit $rc, want 1"
has "error: ruleset 24219615 unread: ruleset 24219615: no bypass_actors list" "no bypass_actors"
hasnt "empty" "no bypass_actors"

# 8. --state: no file means 24h back; a clean run records now; the next run
#    starts there; a failed run leaves the file alone.
ST="$T/state/merge-audit.json"
run --repo o/r --state "$ST"
[ "$rc" -eq 0 ] || fail "state first run: exit $rc"
has "merge-audit o/r since 2026-11-01T06:00:00Z" "state default 24h"
has "#10" "state default 24h window"
grep -qF '"last_run": "2026-11-02T06:00:00Z"' "$ST" || fail "state not written"
MERGE_AUDIT_NOW="2026-11-03T06:00:00Z" FAKE_FAIL="rulesets" run --repo o/r --state "$ST" --ruleset 24219615
[ "$rc" -eq 1 ] || fail "state failed run: exit $rc"
has "since 2026-11-02T06:00:00Z" "state read"
has "merges-without-green-ci: none" "state cutoff excludes earlier merges"
grep -qF '"last_run": "2026-11-02T06:00:00Z"' "$ST" || fail "failed run moved state"
[ "$(ls "$T/state")" = "merge-audit.json" ] || fail "state dir holds other files: $(ls "$T/state")"

# 9. Usage errors exit 2.
run --since 2026-10-31T00:00:00Z
[ "$rc" -eq 2 ] || fail "missing --repo: exit $rc, want 2"
run --repo o/r --since nope
[ "$rc" -eq 2 ] || fail "bad --since: exit $rc, want 2"
run --repo o/r --since 2026-10-31T00:00:00Z --state "$ST"
[ "$rc" -eq 2 ] || fail "--since with --state: exit $rc, want 2"
run --repo o/r --bogus x
[ "$rc" -eq 2 ] || fail "unknown flag: exit $rc, want 2"

echo "merge-audit: all cases passed"

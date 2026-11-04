#!/usr/bin/env bash
# Tests for bin/brief-lint. Exits non-zero on the first failed case.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../bin/brief-lint"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-brief-lint.XXXXXX")"
trap 'rm -rf "$T"' EXIT

cat >"$T/clean.md" <<'EOF'
plain text
Never use --no-verify.
don't write core.hooksPath.
Do not set HUSKY=0.
You may not set GIT_CONFIG_KEY_0.
You MUST NOT run git commit -n.
Forbid git commit -n.
git push -n --dry-run
EOF
out="$("$LINT" "$T/clean.md" 2>"$T/clean-err.txt")"; rc=$?
[ "$rc" = 0 ] || fail "clean brief exits 0 (got $rc: $(cat "$T/clean-err.txt"))"
[ -z "$out" ] || fail "clean brief prints nothing: [$out]"
[ ! -s "$T/clean-err.txt" ] || fail "clean brief is silent on stderr"

cat >"$T/hits.md" <<'EOF'
git push --no-verify
git config core.hooksPath /tmp/hooks
HUSKY=0 git push
GIT_CONFIG_KEY_0=core.hooksPath
git commit -n
run with --no-verification
EOF
expected="$(printf '%s\n' \
  "$T/hits.md:1: git push --no-verify" \
  "$T/hits.md:2: git config core.hooksPath /tmp/hooks" \
  "$T/hits.md:3: HUSKY=0 git push" \
  "$T/hits.md:4: GIT_CONFIG_KEY_0=core.hooksPath" \
  "$T/hits.md:5: git commit -n")"
out="$("$LINT" "$T/hits.md" 2>"$T/hits-err.txt")"; rc=$?
[ "$rc" = 1 ] || fail "bypass brief exits 1 (got $rc)"
[ "$out" = "$expected" ] || fail "one exact file:line:text per hit: got [$out]"
[ ! -s "$T/hits-err.txt" ] || fail "bypass hits are printed on stdout"

out="$("$LINT" 2>"$T/no-args.txt")"; rc=$?
[ "$rc" = 2 ] || fail "no arguments exits 2 (got $rc)"
[ -z "$out" ] || fail "no arguments prints nothing on stdout"

out="$("$LINT" "$T/missing.md" 2>"$T/missing-err.txt")"; rc=$?
[ "$rc" = 2 ] || fail "missing file exits 2 (got $rc)"
[ -z "$out" ] || fail "missing file prints nothing on stdout"
grep -q "$T/missing.md" "$T/missing-err.txt" || fail "missing file is named on stderr"

briefs=()
while IFS= read -r path; do
  [ -n "$path" ] && briefs[${#briefs[@]}]="$path"
done < <(find "$SCRIPT_DIR/../skills" -type f -path '*/briefs/*.md' -print | sort)
[ ${#briefs[@]} -gt 0 ] || fail "found pack brief templates"
out="$("$LINT" "${briefs[@]}" 2>"$T/pack-err.txt")"; rc=$?
[ "$rc" = 0 ] || fail "every pack brief template lints clean (got $rc: $out$(cat "$T/pack-err.txt"))"
[ -z "$out" ] || fail "pack brief templates print nothing: [$out]"
[ ! -s "$T/pack-err.txt" ] || fail "pack brief templates are silent on stderr"

echo "brief-lint: all cases passed"

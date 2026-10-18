#!/usr/bin/env bash
# Tests for bin/file-claim. Exits non-zero on the first failed case.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FC="$SCRIPT_DIR/../bin/file-claim"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-file-claim.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp"
export HOME="$T/home" TMPDIR="$T/tmp"

# --- stub gh: serves a fixture PR list, or fails on demand ------------------
mkdir -p "$T/stubbin"
REAL_GIT="$(command -v git)"
cat >"$T/stubbin/gh" <<'STUB_EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_ARGS_LOG"
if [ "${GH_STUB_FAIL:-0}" = "1" ]; then
  echo "stub gh: auth failure" >&2
  exit 1
fi
cat "$GH_PRS_JSON"
STUB_EOF
chmod +x "$T/stubbin/gh"
PATH="$T/stubbin:$PATH"
export PATH
export GH_ARGS_LOG="$T/gh-args.log"
: >"$GH_ARGS_LOG"
export GH_PRS_JSON="$T/prs-empty.json"
printf '[]' >"$T/prs-empty.json"
export GH_STUB_FAIL=0

# --- remotes -----------------------------------------------------------------
# Each case gets a fresh bare repo holding main with a.txt and sub/b.txt.
new_remote() {
  local r="$T/remote-$1.git" w="$T/seed-$1"
  git init -q --bare "$r" || fail "init bare $1"
  git -c init.defaultBranch=main init -q "$w" || fail "init seed $1"
  git -C "$w" config user.email "t@t.t" || fail "seed config $1"
  git -C "$w" config user.name "t" || fail "seed config $1"
  mkdir -p "$w/sub"
  printf 'a\n' >"$w/a.txt" || fail "seed file $1"
  printf 'b\n' >"$w/sub/b.txt" || fail "seed file $1"
  git -C "$w" add -A || fail "seed add $1"
  git -C "$w" commit -qm seed || fail "seed commit $1"
  git -C "$w" remote add origin "$r" || fail "seed remote $1"
  git -C "$w" push -q origin main || fail "seed push $1"
  printf '%s' "$r"
}

# claim_tip <remote>: the claims ref tip, or empty when the ref is absent.
claim_tip() {
  git -C "$1" rev-parse --verify --quiet 'refs/claims/live^{commit}' 2>/dev/null || true
}

# claims_blob <remote>: the stored claims text, or empty when the ref is absent.
claims_blob() {
  local tip
  tip="$(claim_tip "$1")"
  [ -n "$tip" ] || return 0
  git -C "$1" cat-file -p "$tip:claims" || fail "read claims blob"
}

NFILE="$T/n"
printf 0 >"$NFILE"
fresh() {
  n="$(cat "$NFILE")"
  n=$((n + 1))
  printf '%s' "$n" >"$NFILE"
  new_remote "$n"
}

CLAIM="claim --lane L --grant --worktree t:d1 --repo test/repo"

# --- ref absent on first use; new vs exists -----------------------------------
R="$(fresh)"
[ -z "$(claim_tip "$R")" ] || fail "claims ref absent before first claim"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM a.txt newfile.txt 2>"$T/e1")" || fail "first claim exits 0: $(cat "$T/e1")"
[ "$out" = "$(printf 'GRANT a.txt exists\nGRANT newfile.txt new\nfile-claim: 2 granted, 0 refused')" ] || fail "new vs exists lines: $out"
blob="$(claims_blob "$R")"
[ "$(printf '%s\n' "$blob" | grep -c '^')" = "2" ] || fail "two claim lines stored"
printf '%s' "$blob" | grep -q "^a.txt	L	grant	" || fail "a.txt stored as grant"
[ -n "$(claim_tip "$R")" ] || fail "claims ref created by first claim"

# gh was asked for the full open-PR list, not the 30-PR default.
grep -q -- '--limit 1000' "$GH_ARGS_LOG" || fail "gh asked with --limit 1000"
grep -q -- '--state open' "$GH_ARGS_LOG" || fail "gh asked with --state open"
grep -q -- '--json number,files' "$GH_ARGS_LOG" || fail "gh asked with --json number,files"

# --- jitter sleeps 0.2-1.0 s -----------------------------------------------------
# Extract jitter_sleep from the script and sample it: every sleep must land in
# 0.2-1.0 s (the old inline expression sometimes slept "0.10" = 0.1 s), and 1.0
# must be reachable (the old expression never slept it).
sed -n '/^jitter_sleep()/,/^}/p' "$FC" >"$T/jitter.sh" || fail "extract jitter helper"
[ -s "$T/jitter.sh" ] || fail "jitter helper present"
# shellcheck disable=SC1090
. "$T/jitter.sh"
sleep() { printf '%s\n' "$1" >>"$T/sleeps"; }
: >"$T/sleeps"
i=0
while [ "$i" -lt 500 ]; do
  jitter_sleep
  i=$((i + 1))
done
unset -f sleep
while IFS= read -r s || [ -n "$s" ]; do
  [ -n "$s" ] || continue
  case "$s" in
    0.2|0.3|0.4|0.5|0.6|0.7|0.8|0.9|1|1.0) ;;
    *) fail "jitter out of range: $s";;
  esac
done <"$T/sleeps"
grep -Eq '^(1|1\.0)$' "$T/sleeps" || fail "jitter never reaches 1.0"

# a directory path is not a file on main, so it reports new.
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM sub 2>/dev/null)" || fail "dir claim exits 0"
[ "$out" = "$(printf 'GRANT sub new\nfile-claim: 1 granted, 0 refused')" ] || fail "dir reports new: $out"

# --- PR refusal names the PR; nothing is written ------------------------------
R="$(fresh)"
printf '[{"number":42,"files":[{"path":"a.txt"}]}]' >"$T/prs1.json"
export GH_PRS_JSON="$T/prs1.json"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM a.txt newfile.txt 2>"$T/e2")" && fail "PR-held claim exits non-zero"
[ "$?" = "1" ] || fail "PR-held claim exits 1"
[ "$out" = "$(printf 'REFUSE a.txt pr#42\nGRANT newfile.txt new\nfile-claim: 1 granted, 1 refused')" ] || fail "PR refusal lines: $out"
[ -z "$(claim_tip "$R")" ] || fail "refused call writes nothing"

# the smallest PR number wins when several touch the path; PRs with no files match nothing.
printf '[{"number":9,"files":[{"path":"a.txt"}]},{"number":3,"files":[{"path":"a.txt"}]},{"number":5,"files":[]}]' >"$T/prs2.json"
export GH_PRS_JSON="$T/prs2.json"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM a.txt 2>/dev/null)" && fail "multi-PR claim exits non-zero"
[ "$out" = "$(printf 'REFUSE a.txt pr#3\nfile-claim: 0 granted, 1 refused')" ] || fail "smallest PR named: $out"

# --- --self-pr skips the lane's own PR -----------------------------------------
export GH_PRS_JSON="$T/prs1.json"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane L --grant --worktree t:d1 --repo test/repo --self-pr 42 a.txt 2>"$T/e3")" || fail "self-pr claim exits 0: $(cat "$T/e3")"
[ "$out" = "$(printf 'GRANT a.txt exists\nfile-claim: 1 granted, 0 refused')" ] || fail "self-pr lines: $out"

# other PRs still refuse even with --self-pr.
printf '[{"number":42,"files":[{"path":"a.txt"}]},{"number":7,"files":[{"path":"a.txt"}]}]' >"$T/prs3.json"
export GH_PRS_JSON="$T/prs3.json"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane L --grant --worktree t:d1 --repo test/repo --self-pr 42 a.txt 2>/dev/null)" && fail "other-PR claim exits non-zero"
[ "$out" = "$(printf 'REFUSE a.txt pr#7\nfile-claim: 0 granted, 1 refused')" ] || fail "other PR still refuses: $out"
export GH_PRS_JSON="$T/prs-empty.json"

# --- other-lane refusal; own re-claim is an idempotent no-op -------------------
R="$(fresh)"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane A --grant --worktree t:dA --repo test/repo x.txt 2>/dev/null)" || fail "lane A claim exits 0"
before="$(claims_blob "$R")"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane B --grant --worktree t:dB --repo test/repo x.txt 2>/dev/null)" && fail "other-lane claim exits non-zero"
[ "$?" = "1" ] || fail "other-lane claim exits 1"
[ "$out" = "$(printf 'REFUSE x.txt lane:A\nfile-claim: 0 granted, 1 refused')" ] || fail "other-lane refusal: $out"
[ "$(claims_blob "$R")" = "$before" ] || fail "other-lane refusal writes nothing"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane A --grant --worktree t:dA --repo test/repo x.txt 2>/dev/null)" || fail "re-claim exits 0"
[ "$out" = "$(printf 'GRANT x.txt new\nfile-claim: 1 granted, 0 refused')" ] || fail "re-claim lines: $out"
[ "$(claims_blob "$R")" = "$before" ] || fail "re-claim stores no second line"

# re-claim with the other kind keeps the recorded line: a no-op, not an upgrade.
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane A --plan --worktree t:dA --repo test/repo y.txt 2>/dev/null)" || fail "plan claim exits 0"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane A --grant --worktree t:dA --repo test/repo y.txt 2>/dev/null)" || fail "cross-kind re-claim exits 0"
printf '%s' "$(claims_blob "$R")" | grep -q "^y.txt	A	plan	" || fail "cross-kind re-claim keeps plan"

# a repeated path in one call is claimed once.
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane A --grant --worktree t:dA --repo test/repo d.txt d.txt 2>/dev/null)" || fail "dup-path claim exits 0"
[ "$out" = "$(printf 'GRANT d.txt new\nfile-claim: 1 granted, 0 refused')" ] || fail "dup path one line: $out"
[ "$(claims_blob "$R" | grep -c '^d.txt	')" = "1" ] || fail "dup path one stored line"

# --- mixed set is all-or-nothing ------------------------------------------------
R="$(fresh)"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane A --grant --worktree t:dA --repo test/repo x.txt 2>/dev/null)" || fail "setup claim exits 0"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane B --grant --worktree t:dB --repo test/repo x.txt y.txt 2>/dev/null)" && fail "mixed claim exits non-zero"
[ "$?" = "1" ] || fail "mixed claim exits 1"
[ "$out" = "$(printf 'REFUSE x.txt lane:A\nGRANT y.txt new\nfile-claim: 1 granted, 1 refused')" ] || fail "mixed lines: $out"
[ "$(claims_blob "$R" | grep -c '^')" = "1" ] || fail "mixed refusal stores y.txt too"

# --- cap of 5 grants; plan claims do not count ----------------------------------
R="$(fresh)"
i=1
while [ "$i" -le 5 ]; do
  FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane G --grant --worktree t:dG --repo test/repo "g$i" >/dev/null 2>&1 || fail "grant $i of 5 exits 0"
  i=$((i + 1))
done
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane G --grant --worktree t:dG --repo test/repo g6 2>/dev/null)" && fail "6th grant exits non-zero"
[ "$?" = "1" ] || fail "6th grant exits 1"
[ "$out" = "$(printf 'REFUSE g6 cap\nfile-claim: 0 granted, 1 refused')" ] || fail "cap refusal: $out"
[ "$(claims_blob "$R" | grep -c '^')" = "5" ] || fail "cap refusal writes nothing"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane G --plan --worktree t:dG --repo test/repo p1 p2 p3 >/dev/null 2>&1 || fail "plan claims exit 0 past the grant cap"
[ "$(claims_blob "$R" | grep -c '^')" = "8" ] || fail "plan claims stored past the cap"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane G --grant --worktree t:dG --repo test/repo g6 2>/dev/null)" && fail "grant past cap still refused"
[ "$out" = "$(printf 'REFUSE g6 cap\nfile-claim: 0 granted, 1 refused')" ] || fail "cap holds with plans: $out"

# a call that would cross the cap refuses every new grant path in the call.
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane G --grant --worktree t:dG --repo test/repo g1 g2 g3 >/dev/null 2>&1 || fail "setup 3 grants"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane G --grant --worktree t:dG --repo test/repo g4 g5 g6 2>/dev/null)" && fail "over-cap call exits non-zero"
[ "$out" = "$(printf 'REFUSE g4 cap\nREFUSE g5 cap\nREFUSE g6 cap\nfile-claim: 0 granted, 3 refused')" ] || fail "over-cap lines: $out"
[ "$(claims_blob "$R" | grep -c '^')" = "3" ] || fail "over-cap call writes nothing"

# --- --plan and --grant are exclusive --------------------------------------------
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane L --plan --grant --repo test/repo a.txt >/dev/null 2>&1 && fail "plan+grant exits non-zero"
[ "$?" = "2" ] || fail "plan+grant exits 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane L --repo test/repo a.txt >/dev/null 2>&1 && fail "neither exits non-zero"
[ "$?" = "2" ] || fail "neither exits 2"
[ -z "$(claim_tip "$R")" ] || fail "exclusive breach writes nothing"

# --- input rules ------------------------------------------------------------------
R="$(fresh)"
for bad in ../x /abs.txt a/../b a//b a/ . .. a/./b; do
  FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM "$bad" >/dev/null 2>&1 && fail "path '$bad' exits non-zero"
  [ "$?" = "2" ] || fail "path '$bad' exits 2"
done
FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM "$(printf 'ta\tb')" >/dev/null 2>&1 && fail "tab path exits non-zero"
[ "$?" = "2" ] || fail "tab path exits 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM "$(printf 'ta\nb')" >/dev/null 2>&1 && fail "newline path exits non-zero"
[ "$?" = "2" ] || fail "newline path exits 2"
[ -z "$(claim_tip "$R")" ] || fail "bad paths write nothing"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane L --grant --repo test/repo >/dev/null 2>&1 && fail "no paths exits non-zero"
[ "$?" = "2" ] || fail "no paths exits 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --grant --repo test/repo a.txt >/dev/null 2>&1 && fail "missing lane exits non-zero"
[ "$?" = "2" ] || fail "missing lane exits 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane '' --grant --repo test/repo a.txt >/dev/null 2>&1 && fail "empty lane exits non-zero"
[ "$?" = "2" ] || fail "empty lane exits 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane "$(printf 'a\tb')" --grant --repo test/repo a.txt >/dev/null 2>&1 && fail "tab lane exits non-zero"
[ "$?" = "2" ] || fail "tab lane exits 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane L --grant --self-pr x --repo test/repo a.txt >/dev/null 2>&1 && fail "non-numeric self-pr exits non-zero"
[ "$?" = "2" ] || fail "non-numeric self-pr exits 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" frobnicate >/dev/null 2>&1 && fail "unknown command exits non-zero"
[ "$?" = "2" ] || fail "unknown command exits 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane L --grant --bogus --repo test/repo a.txt >/dev/null 2>&1 && fail "unknown flag exits non-zero"
[ "$?" = "2" ] || fail "unknown flag exits 2"

# missing main is an API error with no overwrite.
E="$T/empty.git"
git init -q --bare "$E" || fail "init empty remote"
FILE_CLAIM_REMOTE="$E" bash "$FC" $CLAIM a.txt >/dev/null 2>"$T/e4" && fail "missing main exits non-zero"
[ "$?" = "2" ] || fail "missing main exits 2"
[ -z "$(git -C "$E" for-each-ref)" ] || fail "missing main writes nothing"
FILE_CLAIM_REMOTE="$E" bash "$FC" list >/dev/null 2>&1 && fail "list with missing main exits non-zero"
[ "$?" = "2" ] || fail "list with missing main exits 2"
FILE_CLAIM_REMOTE="$E" bash "$FC" release --lane L >/dev/null 2>&1 && fail "release with missing main exits non-zero"
[ "$?" = "2" ] || fail "release with missing main exits 2"

# a gh failure is an API error.
R="$(fresh)"
GH_STUB_FAIL=1
FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM a.txt >/dev/null 2>&1 && fail "gh failure exits non-zero"
[ "$?" = "2" ] || fail "gh failure exits 2"
[ -z "$(claim_tip "$R")" ] || fail "gh failure writes nothing"
# release does not call gh, so it still succeeds.
FILE_CLAIM_REMOTE="$R" bash "$FC" release --lane NOBODY >/dev/null 2>&1 || fail "release works when gh fails"
GH_STUB_FAIL=0

# --- corrupt claims: exit 2, no overwrite ------------------------------------------
corrupt_remote() {
  # corrupt_remote <n> <line>: bare repo with main plus a claims blob holding <line>.
  local r w blob tree commit mtip
  r="$T/corrupt-$1.git"
  w="$T/corrupt-$1"
  git init -q --bare "$r" || fail "init corrupt $1"
  git -c init.defaultBranch=main init -q "$w" || fail "init corrupt seed $1"
  git -C "$w" config user.email "t@t.t" || fail "corrupt config $1"
  git -C "$w" config user.name "t" || fail "corrupt config $1"
  git -C "$w" commit -q --allow-empty -m seed || fail "corrupt seed $1"
  git -C "$w" branch -M main || fail "corrupt branch $1"
  git -C "$w" push -q "$r" main || fail "corrupt push main $1"
  blob="$(printf '%s\n' "$2" | git -C "$w" hash-object -w --stdin)" || fail "corrupt blob $1"
  tree="$(printf '100644 blob %s\tclaims\n' "$blob" | git -C "$w" mktree)" || fail "corrupt tree $1"
  mtip="$(git -C "$w" rev-parse main)" || fail "corrupt mtip $1"
  commit="$(printf 'corrupt\n' | GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git -C "$w" commit-tree "$tree" -p "$mtip")" || fail "corrupt commit $1"
  git -C "$w" push -q "$r" "$commit:refs/claims/live" || fail "corrupt ref $1"
  printf '%s' "$r"
}

CR="$(corrupt_remote 1 'no-tabs-here')"
tip_before="$(claim_tip "$CR")"
FILE_CLAIM_REMOTE="$CR" bash "$FC" claim --lane L --grant --worktree t:d --repo test/repo a.txt >/dev/null 2>&1 && fail "bad-field claim exits non-zero"
[ "$?" = "2" ] || fail "bad-field claim exits 2"
[ "$(claim_tip "$CR")" = "$tip_before" ] || fail "bad-field claim overwrites"
FILE_CLAIM_REMOTE="$CR" bash "$FC" list >/dev/null 2>&1 && fail "bad-field list exits non-zero"
[ "$?" = "2" ] || fail "bad-field list exits 2"

CR="$(corrupt_remote 2 "$(printf 'a.txt\tL\tbogus\t2026-01-01T00:00:00Z\tt:d\t')")"
FILE_CLAIM_REMOTE="$CR" bash "$FC" claim --lane L --grant --worktree t:d --repo test/repo a.txt >/dev/null 2>&1 && fail "bad-kind claim exits non-zero"
[ "$?" = "2" ] || fail "bad-kind claim exits 2"

CR="$(corrupt_remote 3 "$(printf 'a.txt\tL\tgrant\tnot-a-date\tt:d\t')")"
FILE_CLAIM_REMOTE="$CR" bash "$FC" claim --lane L --grant --worktree t:d --repo test/repo a.txt >/dev/null 2>&1 && fail "bad-date claim exits non-zero"
[ "$?" = "2" ] || fail "bad-date claim exits 2"

# --- release -------------------------------------------------------------------------
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane A --grant --worktree t:dA --repo test/repo x.txt y.txt >/dev/null 2>&1 || fail "release setup A"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane B --grant --worktree t:dB --repo test/repo z.txt >/dev/null 2>&1 || fail "release setup B"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" release --lane A x.txt 2>/dev/null)" || fail "release named exits 0"
[ "$out" = "RELEASE x.txt" ] || fail "release named line: $out"
blob="$(claims_blob "$R")"
[ "$(printf '%s\n' "$blob" | grep -c '^')" = "2" ] || fail "one line released"
printf '%s' "$blob" | grep -q "^y.txt	A	grant	" || fail "y's claim kept"
printf '%s' "$blob" | grep -q "^z.txt	B	grant	" || fail "B's claim kept"
# releasing a path another lane holds drops nothing.
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" release --lane A z.txt 2>/dev/null)" || fail "foreign release exits 0"
[ -z "$out" ] || fail "foreign release prints nothing"
[ "$(claims_blob "$R" | grep -c '^')" = "2" ] || fail "foreign release drops nothing"
# release all of a lane.
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" release --lane A 2>/dev/null)" || fail "release all exits 0"
[ "$out" = "RELEASE y.txt" ] || fail "release all line: $out"
[ "$(claims_blob "$R" | grep -c '^')" = "1" ] || fail "release all drops the lane"
# a missing lane is a no-op success.
before="$(claims_blob "$R")"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" release --lane NOBODY 2>/dev/null)" || fail "missing-lane release exits 0"
[ -z "$out" ] || fail "missing-lane release prints nothing"
[ "$(claims_blob "$R")" = "$before" ] || fail "missing-lane release writes nothing"

# --- list -------------------------------------------------------------------------------
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane A --grant --worktree t:wtA --repo test/repo f2.txt >/dev/null 2>&1 || fail "list setup 1"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane A --plan --worktree t:wtA --repo test/repo f1.txt >/dev/null 2>&1 || fail "list setup 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane B --grant --worktree t:wtB --repo test/repo --self-pr 7 f3.txt >/dev/null 2>&1 || fail "list setup 3"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" list --repo test/repo 2>/dev/null)" || fail "list exits 0"
[ "$(printf '%s\n' "$out" | grep -c '^')" = "3" ] || fail "list has 3 lines: $out"
[ "$(printf '%s' "$out" | cut -f1 | tr '\n' ' ')" = "f1.txt f2.txt f3.txt " ] || fail "list sorted by path: $out"
printf '%s' "$out" | grep -Eq "^f1.txt	A	plan	[0-9]+	t:wtA	$" || fail "list plan line: $out"
printf '%s' "$out" | grep -Eq "^f2.txt	A	grant	[0-9]+	t:wtA	$" || fail "list grant line: $out"
printf '%s' "$out" | grep -Eq "^f3.txt	B	grant	[0-9]+	t:wtB	7$" || fail "list pr passthrough: $out"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" list --lane A --repo test/repo 2>/dev/null)" || fail "list --lane exits 0"
[ "$(printf '%s\n' "$out" | grep -c '^')" = "2" ] || fail "list --lane filters: $out"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" list --lane NOBODY --repo test/repo 2>/dev/null)" || fail "list empty lane exits 0"
[ -z "$out" ] || fail "list empty lane prints nothing"

# the default worktree is host:cwd.
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane W --grant --repo test/repo w.txt >/dev/null 2>&1 || fail "default worktree claim exits 0"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" list --lane W --repo test/repo 2>/dev/null)" || fail "default worktree list exits 0"
printf '%s' "$out" | grep -Eq "^w.txt	W	grant	[0-9]+	$(hostname -s):$(pwd)	$" || fail "default worktree: $out"

# --- forced non-fast-forward retries and succeeds -----------------------------------------
R="$(fresh)"
: >"$T/push.log"
mkdir -p "$T/gitwrap"
cat >"$T/gitwrap/git" <<WRAP_EOF
#!/usr/bin/env bash
echo "push \$*" >>"$T/push.log"
case " \$* " in
  *" push "*)
    if [ -z "\${CLAIM_HOOKED:-}" ]; then
      export CLAIM_HOOKED=1
      FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane rival --grant --worktree t:hook --repo test/repo rival.txt >/dev/null 2>&1 || exit 2
    fi
    ;;
esac
exec "$REAL_GIT" "\$@"
WRAP_EOF
chmod +x "$T/gitwrap/git"
out="$(PATH="$T/gitwrap:$PATH" FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane M --grant --worktree t:dM --repo test/repo outer.txt 2>"$T/e5")" || fail "NFF claim exits 0: $(cat "$T/e5")"
[ "$out" = "$(printf 'GRANT outer.txt new\nfile-claim: 1 granted, 0 refused')" ] || fail "NFF lines: $out"
[ "$(wc -l <"$T/push.log")" -ge 3 ] || fail "push retried after NFF"
blob="$(claims_blob "$R")"
printf '%s' "$blob" | grep -q "^outer.txt	M	grant	" || fail "outer claim recorded after retry"
printf '%s' "$blob" | grep -q "^rival.txt	rival	grant	" || fail "rival claim kept after retry"
PATH="$T/stubbin:$PATH"

# a push failure that is not a non-fast-forward exits 2 at once.
D="$T/not-a-repo"
mkdir -p "$D"
FILE_CLAIM_REMOTE="$D" bash "$FC" $CLAIM a.txt >/dev/null 2>&1 && fail "bad-remote claim exits non-zero"
[ "$?" = "2" ] || fail "bad-remote claim exits 2"

# --- concurrency: exactly one winner, twenty rounds -----------------------------------------
R="$(fresh)"
i=1
while [ "$i" -le 20 ]; do
  p="race-$i.txt"
  # Fresh lanes each round so the 5-grant cap never binds: the race alone
  # decides the single winner.
  (FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane "A$i" --grant --worktree t:dA --repo test/repo "$p" >/dev/null 2>&1; echo "$?" >"$T/c1-$i") &
  (FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane "B$i" --grant --worktree t:dB --repo test/repo "$p" >/dev/null 2>&1; echo "$?" >"$T/c2-$i") &
  wait
  c1="$(cat "$T/c1-$i")"
  c2="$(cat "$T/c2-$i")"
  case "$c1$c2" in
    01|10) ;;
    *) fail "round $i: exits $c1 and $c2, want one 0 and one 1";;
  esac
  i=$((i + 1))
done
[ "$(claims_blob "$R" | grep -c '^')" = "20" ] || fail "one claim per race recorded"

echo "file-claim tests passed"

#!/usr/bin/env bash
# Tests for bin/file-claim. Exits non-zero on the first failed case.
set -uo pipefail

# grep -q may close a producer's pipe early; under pipefail that can fail a
# passing assertion. Assert against captured output or a file instead.
if grep -nE '[|][[:space:]]*grep[[:space:]]+-[[:alnum:]]*q[[:alnum:]]*([[:space:]]|$)|[|][[:space:]]*grep[[:space:]]+--quiet([[:space:]]|$)' "$0"; then
  echo 'FAIL: grep -q assertions must not read producer pipelines under pipefail' >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FC="$SCRIPT_DIR/../bin/file-claim"
. "$SCRIPT_DIR/../bin/lib/lane-ticket.sh"
TAB="$(printf '\t')" # GNU grep reads \t in a pattern as a literal t

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ "$(claim_holder 4271)" = "fiber-4271" ] || fail "claim_holder derives the fiber holder name"

T="$(mktemp -d "${TMPDIR:-/tmp}/test-file-claim.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp" "$T/run"
export HOME="$T/home" TMPDIR="$T/tmp" FW_RUN="$T/run"

# --- stub gh: serves a fixture PR list, or fails on demand ------------------
mkdir -p "$T/stubbin"
REAL_GIT="$(command -v git)"
REAL_DATE="$(command -v date)"
cat >"$T/stubbin/gh" <<'STUB_EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_ARGS_LOG"
if [ "${GH_STUB_FAIL:-0}" = "1" ]; then
  echo "stub gh: auth failure" >&2
  exit 1
fi
if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  n="$3"
  if [ -n "${GH_DIFF_406_PR:-}" ] && [ "$n" = "$GH_DIFF_406_PR" ]; then
    echo "HTTP 406: the diff exceeded the maximum number of files (300)" >&2
    exit 1
  fi
  if [ -n "${GH_DIFF_FAIL_PR:-}" ] && [ "$n" = "$GH_DIFF_FAIL_PR" ]; then
    # A partial download: some of the diff, then a failure.
    [ -n "${GH_DIFF_DIR:-}" ] && [ -f "$GH_DIFF_DIR/$n.diff" ] && head -n 9 "$GH_DIFF_DIR/$n.diff"
    echo "stub gh: diff failure" >&2
    exit 1
  fi
  if [ -n "${GH_DIFF_DIR:-}" ] && [ -f "$GH_DIFF_DIR/$n.diff" ]; then
    cat "$GH_DIFF_DIR/$n.diff"
    exit 0
  fi
  echo "stub gh: no diff fixture for PR $n" >&2
  exit 1
fi
if [ "$1" = "api" ]; then
  if [ "${2:-}" = graphql ]; then
    [ "${GH_TICKET_FAIL:-0}" != 1 ] || { echo 'ticket state stub failure' >&2; exit 1; }
    [ "${GH_TICKET_BAD:-0}" != 1 ] || { printf 'not graphql json'; exit 0; }
    query=""
    for arg in "$@"; do case "$arg" in query=*) query="${arg#query=}";; esac; done
    python3 -c 'import json,re,sys
query, configured, omitted = sys.argv[1:]
states = {}
for item in configured.split(","):
  if ":" in item:
    number, state = item.split(":", 1)
    states[number] = state
omit = set(omitted.split(","))
result = {}
for alias, number in re.findall(r"(\w+):\s*issueOrPullRequest\(number:\s*(\d+)\)", query):
  if number not in omit:
    result[alias] = {"state": states.get(number, "OPEN")}
print(json.dumps({"data": {"repository": result}}))' "$query" "${GH_TICKET_STATES:-}" "${GH_TICKET_OMIT:-}"
    exit 0
  fi
  url=""
  for arg in "$@"; do case "$arg" in repos/*/pulls/*/files\?*) url="$arg";; esac; done
  pr="${url#*/pulls/}"; pr="${pr%%/*}"
  if [ -n "${GH_FAIL_FILES_PR:-}" ] && [ "$pr" = "$GH_FAIL_FILES_PR" ]; then
    count="$(cat "$GH_FAIL_FILES_COUNT" 2>/dev/null || printf 0)"
    if [ "$count" -lt "${GH_FAIL_FILES_TIMES:-0}" ]; then
      count=$((count + 1))
      printf '%s' "$count" >"$GH_FAIL_FILES_COUNT"
      echo "stub gh: transient read failure" >&2
      exit 1
    fi
  fi
  if [ -n "${GH_EMPTY_FILES_PR:-}" ] && [ "$pr" = "$GH_EMPTY_FILES_PR" ]; then
    count="$(cat "$GH_EMPTY_FILES_COUNT" 2>/dev/null || printf 0)"
    if [ "$count" -lt "${GH_EMPTY_FILES_TIMES:-0}" ]; then
      count=$((count + 1))
      printf '%s' "$count" >"$GH_EMPTY_FILES_COUNT"
      exit 0
    fi
  fi
  has_query=0
  for arg in "$@"; do [ "$arg" != "-q" ] || has_query=1; done
  if [ "$has_query" = 0 ] && [ -n "${GH_API_DIFF_FILES:-}" ]; then cat "$GH_API_DIFF_FILES"; exit 0; fi
  if [ -n "${GH_API_FILES:-}" ]; then cat "$GH_API_FILES"; exit 0; fi
  jq -r --arg n "$pr" '.[] | select((.number|tostring) == $n) | (.files // [])[] | (.filename // .path)' "$GH_PRS_JSON"
  exit 0
fi
cat "$GH_PRS_JSON"
STUB_EOF
chmod +x "$T/stubbin/gh"
PATH="$T/stubbin:$PATH"
export PATH FW_GH="$T/stubbin/gh"
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

CLAIM="claim --lane fiber-4222 --grant --worktree t:d1 --repo test/repo"

# make_plan NAME PATH...: write a plan under $T/plans whose Files section lists
# each PATH as a backticked list item; prints the plan path.
PLANS="$T/plans"
mkdir -p "$PLANS"
make_plan() {
  local f="$PLANS/$1"; shift
  { printf '## Files\n'; for p in "$@"; do printf -- "- \`%s\`\n" "$p"; done; } >"$f"
  printf '%s' "$f"
}

# --- claim lanes need a ticket number; read/release remain unrestricted --------
R="$(fresh)"
invalid_lane="muse/muse-spark-1.3-contributor"
rc=0
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane "$invalid_lane" --grant --worktree t:bad --repo test/repo a.txt 2>"$T/e-lane-invalid")" || rc=$?
[ "$rc" = 2 ] || fail "claim with unnumbered lane exits 2, got $rc: $out"
[ -z "$out" ] || fail "refused lane writes no claim output: $out"
[ "$(cat "$T/e-lane-invalid")" = "ERROR lane has no ticket number: $invalid_lane (expected fiber-<n> or sweep-<n>)" ] || fail "unnumbered lane diagnostic: $(cat "$T/e-lane-invalid")"
[ -z "$(claim_tip "$R")" ] || fail "unnumbered lane writes no claim ref"
malformed_sweep_lane="sweep-4226bad"
rc=0
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane "$malformed_sweep_lane" --grant --worktree t:bad --repo test/repo a.txt 2>"$T/e-sweep-invalid")" || rc=$?
[ "$rc" = 2 ] || fail "claim with malformed sweep lane exits 2, got $rc: $out"
[ "$(cat "$T/e-sweep-invalid")" = "ERROR lane has no ticket number: $malformed_sweep_lane (expected fiber-<n> or sweep-<n>)" ] || fail "malformed sweep diagnostic: $(cat "$T/e-sweep-invalid")"
[ -z "$(claim_tip "$R")" ] || fail "malformed sweep lane writes no claim ref"

branch_lane="docs/4271-x"
rc=0
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane "$branch_lane" --grant --worktree t:bad --repo test/repo a.txt 2>"$T/e-lane-branch")" || rc=$?
[ "$rc" = 2 ] || fail "claim with branch-shaped lane exits 2, got $rc: $out"
[ -z "$out" ] || fail "refused branch-shaped lane writes no claim output: $out"
[ "$(cat "$T/e-lane-branch")" = "RENAME-LANE $branch_lane: no file is held or refused; rerun with --lane fiber-4271 (one holder name per ticket, so retirement releases every claim)" ] || fail "branch-shaped lane diagnostic: $(cat "$T/e-lane-branch")"
[ -z "$(claim_tip "$R")" ] || fail "branch-shaped lane writes no claim ref"

suffixed_fiber_lane="fiber-4271-build"
rc=0
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane "$suffixed_fiber_lane" --grant --worktree t:bad --repo test/repo a.txt 2>"$T/e-lane-suffixed-fiber")" || rc=$?
[ "$rc" = 2 ] || fail "claim with suffixed fiber lane exits 2, got $rc: $out"
[ -z "$out" ] || fail "refused suffixed fiber lane writes no claim output: $out"
[ "$(cat "$T/e-lane-suffixed-fiber")" = "RENAME-LANE $suffixed_fiber_lane: no file is held or refused; rerun with --lane fiber-4271 (one holder name per ticket, so retirement releases every claim)" ] || fail "suffixed fiber lane diagnostic: $(cat "$T/e-lane-suffixed-fiber")"
[ -z "$(claim_tip "$R")" ] || fail "suffixed fiber lane writes no claim ref"

out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4271 --grant --worktree t:4271 --repo test/repo ticket-4271.txt 2>"$T/e-claim-4271")" || fail "claim under canonical holder exits 0: $(cat "$T/e-claim-4271")"
[ "$out" = "$(printf 'GRANT ticket-4271.txt new\nfile-claim: 1 granted, 0 refused')" ] || fail "canonical holder claim output: $out"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" release --lane fiber-4271 --repo test/repo 2>"$T/e-release-4271")" || fail "release under canonical holder exits 0: $(cat "$T/e-release-4271")"
[ "$out" = "RELEASE ticket-4271.txt" ] || fail "canonical holder release output: $out"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" list --repo test/repo 2>"$T/e-list-4271")" || fail "list after canonical holder release exits 0: $(cat "$T/e-list-4271")"
[ -z "$out" ] || fail "release leaves no ticket 4271 claim: $out"

valid_lanes=(fiber-4222 fiber-4271 fiber-4276 fiber-4226 sweep-12)
i=0
for lane in "${valid_lanes[@]}"; do
  path="lane-$i.txt"
  out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane "$lane" --grant --worktree "t:$i" --repo test/repo "$path" 2>"$T/e-lane-valid-$i")" || fail "claim with $lane exits 0: $(cat "$T/e-lane-valid-$i")"
  [ "$out" = "$(printf 'GRANT %s new\nfile-claim: 1 granted, 0 refused' "$path")" ] || fail "claim with $lane output: $out"
  i=$((i + 1))
done
blob="$(claims_blob "$R")"
for lane in "${valid_lanes[@]}"; do
  grep -q "^[^[:space:]]*${TAB}${lane}${TAB}grant${TAB}" <<<"$blob" || fail "claim with $lane is stored"
done

# Seed a historical malformed holder: these rows must remain visible and removable.
legacy="$T/legacy-claims"
git -c init.defaultBranch=main init -q "$legacy" || fail "init legacy claim fixture"
git -C "$legacy" config user.email t@t.t || fail "legacy fixture email"
git -C "$legacy" config user.name t || fail "legacy fixture name"
git -C "$legacy" remote add origin "$R" || fail "set legacy claim remote"
git -C "$legacy" fetch -q origin refs/claims/live || fail "fetch claims for legacy fixture"
git -C "$legacy" checkout -q -b legacy-claim FETCH_HEAD || fail "checkout claims for legacy fixture"
printf 'a.txt\t%s\tgrant\t2026-01-02T03:04:05Z\tt:legacy\t\n' "$invalid_lane" >>"$legacy/claims"
printf 'docs/workflow.md\t%s\tgrant\t2026-01-02T03:04:05Z\tt:legacy\t\n' "$branch_lane" >>"$legacy/claims"
git -C "$legacy" add claims || fail "stage legacy claim"
git -C "$legacy" commit -qm 'legacy malformed claim' || fail "commit legacy claim"
git -C "$legacy" push -q origin HEAD:refs/claims/live || fail "publish legacy claim"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" list --lane "$invalid_lane" --repo test/repo 2>"$T/e-list-invalid")" || fail "list accepts an unnumbered lane: $(cat "$T/e-list-invalid")"
[ "$(printf '%s\n' "$out" | cut -f1-3)" = "$(printf 'a.txt\t%s\tgrant' "$invalid_lane")" ] || fail "list finds legacy claim for unnumbered lane: $out"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" release --lane "$invalid_lane" --repo test/repo a.txt 2>"$T/e-release-invalid")" || fail "release accepts an unnumbered lane: $(cat "$T/e-release-invalid")"
[ "$out" = 'RELEASE a.txt' ] || fail "release removes legacy claim: $out"
grep -q "^[^[:space:]]*${TAB}${invalid_lane}${TAB}grant${TAB}" <<<"$(claims_blob "$R")" && fail "release removes legacy claim row"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" list --lane "$branch_lane" --repo test/repo 2>"$T/e-list-branch")" || fail "list accepts a branch-shaped legacy lane: $(cat "$T/e-list-branch")"
[ "$(printf '%s\n' "$out" | cut -f1-3)" = "$(printf 'docs/workflow.md\t%s\tgrant' "$branch_lane")" ] || fail "list finds branch-shaped legacy claim: $out"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" release --lane "$branch_lane" --repo test/repo docs/workflow.md 2>"$T/e-release-branch")" || fail "release accepts a branch-shaped lane: $(cat "$T/e-release-branch")"
[ "$out" = 'RELEASE docs/workflow.md' ] || fail "release removes branch-shaped legacy claim: $out"
grep -q "^[^[:space:]]*${TAB}${branch_lane}${TAB}grant${TAB}" <<<"$(claims_blob "$R")" && fail "release removes branch-shaped legacy claim row"

# --- ref absent on first use; new vs exists -----------------------------------
R="$(fresh)"
[ -z "$(claim_tip "$R")" ] || fail "claims ref absent before first claim"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM a.txt newfile.txt 2>"$T/e1")" || fail "first claim exits 0: $(cat "$T/e1")"
[ "$out" = "$(printf 'GRANT a.txt exists\nGRANT newfile.txt new\nfile-claim: 2 granted, 0 refused')" ] || fail "new vs exists lines: $out"
blob="$(claims_blob "$R")"
[ "$(printf '%s\n' "$blob" | grep -c '^')" = "2" ] || fail "two claim lines stored"
grep -q "^a.txt	fiber-4222	grant	" <<<"$blob" || fail "a.txt stored as grant"
[ -n "$(claim_tip "$R")" ] || fail "claims ref created by first claim"

# gh was asked for the full open-PR list, not the 30-PR default.
grep -q -- '--limit 1000' "$GH_ARGS_LOG" || fail "gh asked with --limit 1000"
grep -q -- '--state open' "$GH_ARGS_LOG" || fail "gh asked with --state open"
grep -q -- '--json number,changedFiles' "$GH_ARGS_LOG" || fail "gh asked with changedFiles"

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

# --- PR overlap is advisory, including draft PRs -----------------------------
R="$(fresh)"
printf '[{"number":42,"changedFiles":1,"isDraft":true,"files":[{"path":"a.txt"}] }]' >"$T/prs1.json"
export GH_PRS_JSON="$T/prs1.json"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM a.txt newfile.txt 2>"$T/e2")" || fail "draft-PR overlap claim exits 0: $(cat "$T/e2")"
[ "$out" = "$(printf 'OVERLAP a.txt pr#42\nGRANT a.txt exists\nGRANT newfile.txt new\nfile-claim: 2 granted, 0 refused')" ] || fail "draft-PR overlap lines: $out"
blob="$(claims_blob "$R")"
[ "$(printf '%s\n' "$blob" | grep -c '^')" = "2" ] || fail "draft-PR overlap records both claims"
grep -q "^a.txt${TAB}fiber-4222${TAB}grant${TAB}" <<<"$blob" || fail "draft-PR-held path is recorded"

# Every PR is reported when several PRs touch one path.
printf '[{"number":9,"changedFiles":1,"files":[{"path":"a.txt"}]},{"number":3,"changedFiles":1,"files":[{"path":"a.txt"}]},{"number":5,"changedFiles":0,"files":[]}]' >"$T/prs2.json"
export GH_PRS_JSON="$T/prs2.json"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM a.txt 2>/dev/null)" || fail "multi-PR overlap claim exits 0"
[ "$out" = "$(printf 'OVERLAP a.txt pr#3\nOVERLAP a.txt pr#9\nGRANT a.txt exists\nfile-claim: 1 granted, 0 refused')" ] || fail "all PR overlaps named: $out"

# --- sweep PR refusals name the holder's hunks --------------------------------
R="$(fresh)"
printf '[{"number":21,"changedFiles":3,"files":[{"path":"two.txt"},{"path":"ins.txt"},{"path":"new.txt"}]}]' >"$T/prs-hunks.json"
export GH_PRS_JSON="$T/prs-hunks.json"
mkdir -p "$T/diffs"
cat >"$T/diffs/21.diff" <<'DIFF_EOF'
diff --git a/two.txt b/two.txt
index 1111111..2222222 100644
--- a/two.txt
+++ b/two.txt
@@ -10,5 +10,6 @@ context
 context
@@ -100,3 +101,4 @@ context
 context
diff --git a/ins.txt b/ins.txt
index 1111111..2222222 100644
--- a/ins.txt
+++ b/ins.txt
@@ -5,0 +6,2 @@ context
+added
+added
diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,3 @@
+one
+two
+three
DIFF_EOF
: >"$GH_ARGS_LOG"
SWEEP_CLAIM="claim --lane sweep-4231 --grant --worktree t:d1 --repo test/repo"
out="$(FILE_CLAIM_REMOTE="$R" GH_DIFF_DIR="$T/diffs" bash "$FC" $SWEEP_CLAIM two.txt ins.txt new.txt other.txt 2>/dev/null)" && fail "sweep hunk claim exits non-zero"
[ "$?" = "1" ] || fail "hunk claim exits 1"
[ "$out" = "$(printf 'REFUSE two.txt pr#21 hunks=10-14,100-102\nREFUSE ins.txt pr#21 hunks=5-6\nREFUSE new.txt pr#21 hunks=whole\nUNCLAIMED other.txt batch-refused\nfile-claim: no claims recorded; 3 refused, 1 unclaimed because the batch was refused')" ] || fail "hunk ranges: $out"
[ "$(grep -cF 'pr diff 21' "$GH_ARGS_LOG")" = "1" ] || fail "holder diff fetched once per PR"
# A failed diff fetch, even a partial one, gives hunks=unknown for every path
# that PR holds, from one fetch, and the sweep refusals stand.
: >"$GH_ARGS_LOG"
out="$(FILE_CLAIM_REMOTE="$R" GH_DIFF_DIR="$T/diffs" GH_DIFF_FAIL_PR=21 bash "$FC" $SWEEP_CLAIM two.txt ins.txt new.txt 2>/dev/null)" && fail "sweep diff-fail claim exits non-zero"
[ "$?" = "1" ] || fail "diff-fail claim exits 1"
[ "$out" = "$(printf 'REFUSE two.txt pr#21 hunks=unknown\nREFUSE ins.txt pr#21 hunks=unknown\nREFUSE new.txt pr#21 hunks=unknown\nfile-claim: no claims recorded; 3 refused, 0 unclaimed because the batch was refused')" ] || fail "unknown hunks: $out"
[ "$(grep -cF 'pr diff 21' "$GH_ARGS_LOG")" = "1" ] || fail "failed diff fetched once per PR"

# A 406 fallback must preserve the same rename, hunk and whole-file holds.
R="$(fresh)"
printf '[{"number":21,"changedFiles":4,"files":[{"path":"renamed.txt"},{"path":"added.txt"},{"path":"modified.txt"},{"path":"patchless.bin"}]}]' >"$T/prs-406.json"
export GH_PRS_JSON="$T/prs-406.json"
cat >"$T/diffs/21.diff" <<'DIFF_EOF'
diff --git a/old.txt b/renamed.txt
similarity index 90%
rename from old.txt
rename to renamed.txt
index 1111111..2222222 100644
--- a/old.txt
+++ b/renamed.txt
@@ -5,2 +5,2 @@ context
-old
+new
diff --git a/added.txt b/added.txt
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/added.txt
@@ -0,0 +1,1 @@
+new
diff --git a/modified.txt b/modified.txt
index 1111111..2222222 100644
--- a/modified.txt
+++ b/modified.txt
@@ -10,2 +10,2 @@ context
-old
+new
diff --git a/patchless.bin b/patchless.bin
index 1111111..2222222 100644
DIFF_EOF
cat >"$T/api-pr-21-diff.json" <<'FILES_EOF'
[
  {"filename":"renamed.txt","previous_filename":"old.txt","status":"renamed","patch":"@@ -5,2 +5,2 @@ context\n-old\n+new"},
  {"filename":"added.txt","status":"added","patch":"@@ -0,0 +1,1 @@\n+new"},
  {"filename":"modified.txt","status":"modified","patch":"@@ -10,2 +10,2 @@ context\n-old\n+new"},
  {"filename":"patchless.bin","status":"modified"}
]
FILES_EOF
: >"$GH_ARGS_LOG"
rc=0
out="$(FILE_CLAIM_REMOTE="$R" GH_DIFF_DIR="$T/diffs" bash "$FC" $SWEEP_CLAIM renamed.txt added.txt modified.txt patchless.bin 2>/dev/null)" || rc=$?
[ "$rc" = "1" ] || fail "ordinary rename diff refusal exits 1, got $rc: $out"
ordinary_holds="$out"
: >"$GH_ARGS_LOG"
rc=0
out="$(FILE_CLAIM_REMOTE="$R" GH_DIFF_DIR="$T/diffs" GH_DIFF_406_PR=21 GH_API_DIFF_FILES="$T/api-pr-21-diff.json" bash "$FC" $SWEEP_CLAIM renamed.txt added.txt modified.txt patchless.bin 2>/dev/null)" || rc=$?
[ "$rc" = "1" ] || fail "406 API fallback refusal exits 1, got $rc: $out"
[ "$out" = "$ordinary_holds" ] || fail "406 API fallback holds differ from ordinary diff: $out vs $ordinary_holds"
case "$out" in *'renamed.txt pr#21 hunks=5-6'*) ;; *) fail "renamed path hunk missing from fallback: $out";; esac
case "$out" in *'patchless.bin pr#21 hunks=whole'*) ;; *) fail "patchless file is not held whole: $out";; esac
grep -qF 'api --paginate repos/test/repo/pulls/21/files?per_page=100' "$GH_ARGS_LOG" || fail "406 fallback uses paginated files API: $(cat "$GH_ARGS_LOG")"

# More than 3000 API entries fail closed as unknown holder hunks.
R="$(fresh)"
python3 - "$T/prs-over-3000.json" "$T/api-over-3000.json" <<'PY'
import json,sys
paths=["file-%04d.txt" % i for i in range(3001)]
with open(sys.argv[1], "w") as f:
  json.dump([{"number":21,"changedFiles":3001,"files":[{"path":p} for p in paths]}], f)
with open(sys.argv[2], "w") as f:
  json.dump([{"filename":p,"status":"modified","patch":"@@ -1 +1 @@"} for p in paths], f)
PY
export GH_PRS_JSON="$T/prs-over-3000.json"
rc=0
out="$(FILE_CLAIM_REMOTE="$R" GH_DIFF_406_PR=21 GH_API_DIFF_FILES="$T/api-over-3000.json" bash "$FC" $SWEEP_CLAIM file-0000.txt 2>/dev/null)" || rc=$?
[ "$rc" = "1" ] || fail "over-3000 holder remains a sweep refusal, got $rc: $out"
[ "$out" = "$(printf 'REFUSE file-0000.txt pr#21 hunks=unknown\nfile-claim: no claims recorded; 1 refused, 0 unclaimed because the batch was refused')" ] || fail "over-3000 holder is unknown: $out"

# A colliding path after the first 100 is returned by the paginated REST read.
R="$(fresh)"
pr_files='['
api_files=""
i=1
while [ "$i" -le 100 ]; do
  [ "$i" -eq 1 ] || pr_files+=','
  pr_files+="{\"path\":\"file-$i.txt\"}"
  api_files+="file-$i.txt\n"
  i=$((i + 1))
done
pr_files+=']'
printf '[{"number":101,"changedFiles":101,"files":%s}]' "$pr_files" >"$T/prs-paginated.json"
printf '%b' "${api_files}collision.txt\n" >"$T/api-paginated.txt"
export GH_PRS_JSON="$T/prs-paginated.json" GH_API_FILES="$T/api-paginated.txt"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM collision.txt 2>"$T/e-paginated")" || fail "path after 100 overlaps a PR and exits 0"
[ "$out" = "$(printf 'OVERLAP collision.txt pr#101\nGRANT collision.txt new\nfile-claim: 1 granted, 0 refused')" ] || fail "paginated PR overlap: $out"
grep -qF 'api --paginate repos/test/repo/pulls/101/files?per_page=100 -q .[].filename' "$GH_ARGS_LOG" || fail "PR file read did not paginate"
unset GH_API_FILES

# --- transient PR file-list failures are retried per PR -------------------------
R="$(fresh)"
printf '[{"number":7,"changedFiles":1,"files":[{"path":"a.txt"}]},{"number":8,"changedFiles":1,"files":[{"path":"b.txt"}]}]' >"$T/prs-retry.json"
export GH_PRS_JSON="$T/prs-retry.json"
GH_RETRY_COUNT="$T/gh-retry-count"
printf 0 >"$GH_RETRY_COUNT"
: >"$GH_ARGS_LOG"
out="$(FILE_CLAIM_REMOTE="$R" FILE_CLAIM_READ_WAIT=0 GH_FAIL_FILES_PR=7 GH_FAIL_FILES_TIMES=1 GH_FAIL_FILES_COUNT="$GH_RETRY_COUNT" bash "$FC" $CLAIM c.txt 2>"$T/e-retry-once")" || fail "claim retries one transient file-list failure: $(cat "$T/e-retry-once")"
[ "$out" = "$(printf 'GRANT c.txt new\nfile-claim: 1 granted, 0 refused')" ] || fail "claim after transient failure: $out"
[ "$(cat "$GH_RETRY_COUNT")" = "1" ] || fail "one transient file-list failure recorded"
[ "$(grep -cF 'pulls/7/files?per_page=100' "$GH_ARGS_LOG")" = "2" ] || fail "PR 7 file list retried once"
out="$(FILE_CLAIM_REMOTE="$R" FILE_CLAIM_READ_WAIT=0 GH_FAIL_FILES_PR=7 GH_FAIL_FILES_TIMES=1 GH_FAIL_FILES_COUNT="$GH_RETRY_COUNT" bash "$FC" $CLAIM a.txt 2>"$T/e-retry-refusal")" || fail "claim records a PR overlap after retry: $(cat "$T/e-retry-refusal")"
[ "$out" = "$(printf 'OVERLAP a.txt pr#7\nGRANT a.txt exists\nfile-claim: 1 granted, 0 refused')" ] || fail "PR overlap after retry: $out"

R="$(fresh)"
GH_RETRY_COUNT="$T/gh-retry-exhausted-count"
printf 0 >"$GH_RETRY_COUNT"
: >"$GH_ARGS_LOG"
FILE_CLAIM_REMOTE="$R" FILE_CLAIM_READ_WAIT=0 GH_FAIL_FILES_PR=7 GH_FAIL_FILES_TIMES=99 GH_FAIL_FILES_COUNT="$GH_RETRY_COUNT" bash "$FC" $CLAIM c.txt >/dev/null 2>"$T/e-retry-exhausted" && fail "claim exits 2 after all file-list retries fail"
[ "$?" = "2" ] || fail "exhausted file-list retries exit 2"
grep -qF 'cannot list files for open PR #7' "$T/e-retry-exhausted" || fail "exhausted file-list error names PR 7"
[ -z "$(claim_tip "$R")" ] || fail "exhausted file-list retries write no claim"
[ "$(cat "$GH_RETRY_COUNT")" = "3" ] || fail "three transient file-list failures recorded"
[ "$(grep -cF 'pulls/7/files?per_page=100' "$GH_ARGS_LOG")" = "3" ] || fail "PR 7 file list stops after three calls"

# Unfiltered list fails closed when even one open PR's file list is unreadable.
R="$(fresh)"
printf '[{"number":7,"changedFiles":1,"files":[{"path":"pr-file.txt"}]}]' >"$T/prs-list-failure.json"
export GH_PRS_JSON="$T/prs-list-failure.json"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM held.txt 2>"$T/e-list-failure-setup")" || fail "list failure setup claim exits 0: $(cat "$T/e-list-failure-setup")"
GH_RETRY_COUNT="$T/gh-list-failure-count"
printf 0 >"$GH_RETRY_COUNT"
rc=0
out="$(FILE_CLAIM_REMOTE="$R" FILE_CLAIM_READ_WAIT=0 GH_FAIL_FILES_PR=7 GH_FAIL_FILES_TIMES=99 GH_FAIL_FILES_COUNT="$GH_RETRY_COUNT" bash "$FC" list --repo test/repo 2>"$T/e-list-failure")" || rc=$?
[ "$rc" = "2" ] || fail "list with an unreadable PR file list exits 2, got $rc: $out"
[ -z "$out" ] || fail "list with an unreadable PR file list prints no rows: $out"
grep -qF 'cannot list files for open PR #7' "$T/e-list-failure" || fail "list unreadable-file diagnostic names PR 7: $(cat "$T/e-list-failure")"

# An empty or short listing is retried and fails loudly without writing a claim.
R="$(fresh)"
printf '[{"number":7,"changedFiles":2,"files":[{"path":"a.txt"},{"path":"b.txt"}]}]' >"$T/prs-empty-list.json"
export GH_PRS_JSON="$T/prs-empty-list.json"
GH_EMPTY_COUNT="$T/gh-empty-count"
printf 0 >"$GH_EMPTY_COUNT"
: >"$GH_ARGS_LOG"
FILE_CLAIM_REMOTE="$R" FILE_CLAIM_READ_WAIT=0 GH_EMPTY_FILES_PR=7 GH_EMPTY_FILES_TIMES=99 GH_EMPTY_FILES_COUNT="$GH_EMPTY_COUNT" bash "$FC" $CLAIM c.txt >/dev/null 2>"$T/e-empty-exhausted" && fail "empty file list exits 2"
[ "$?" = "2" ] || fail "empty file list exits 2"
grep -qF 'cannot list files for open PR #7' "$T/e-empty-exhausted" || fail "empty file list error names PR 7"
grep -qF 'file list has 0 files, changedFiles is 2' "$T/e-empty-exhausted" || fail "empty file list error reports counts"
[ -z "$(claim_tip "$R")" ] || fail "empty file list writes no claim"
[ "$(cat "$GH_EMPTY_COUNT")" = "3" ] || fail "empty file list retries three times"

# One empty read is retried; the complete list blocks its paths and permits others.
R="$(fresh)"
printf 0 >"$GH_EMPTY_COUNT"
: >"$GH_ARGS_LOG"
out="$(FILE_CLAIM_REMOTE="$R" FILE_CLAIM_READ_WAIT=0 GH_EMPTY_FILES_PR=7 GH_EMPTY_FILES_TIMES=1 GH_EMPTY_FILES_COUNT="$GH_EMPTY_COUNT" bash "$FC" $CLAIM a.txt 2>"$T/e-empty-once")" || fail "listed PR overlap exits 0: $(cat "$T/e-empty-once")"
[ "$out" = "$(printf 'OVERLAP a.txt pr#7\nGRANT a.txt exists\nfile-claim: 1 granted, 0 refused')" ] || fail "retried list reports overlap: $out"
[ "$(cat "$GH_EMPTY_COUNT")" = "1" ] || fail "one empty file-list response recorded"
: >"$GH_ARGS_LOG"
printf 0 >"$GH_EMPTY_COUNT"
out="$(FILE_CLAIM_REMOTE="$R" FILE_CLAIM_READ_WAIT=0 GH_EMPTY_FILES_PR=7 GH_EMPTY_FILES_TIMES=1 GH_EMPTY_FILES_COUNT="$GH_EMPTY_COUNT" bash "$FC" $CLAIM c.txt 2>"$T/e-empty-outside")" || fail "path outside retried PR list is granted: $(cat "$T/e-empty-outside")"
[ "$out" = "$(printf 'GRANT c.txt new\nfile-claim: 1 granted, 0 refused')" ] || fail "outside path granted after retry: $out"
[ "$(grep -cF 'pulls/7/files?per_page=100' "$GH_ARGS_LOG")" = "2" ] || fail "outside path retries the empty file-list response"

# Zero changed files and an empty listing are a valid complete result.
R="$(fresh)"
printf '[{"number":7,"changedFiles":0,"files":[]}]' >"$T/prs-zero-files.json"
export GH_PRS_JSON="$T/prs-zero-files.json"
out="$(FILE_CLAIM_REMOTE="$R" FILE_CLAIM_READ_WAIT=0 bash "$FC" $CLAIM c.txt 2>"$T/e-zero-files")" || fail "zero changed files are valid: $(cat "$T/e-zero-files")"
[ "$out" = "$(printf 'GRANT c.txt new\nfile-claim: 1 granted, 0 refused')" ] || fail "zero-file PR permits claim: $out"

export GH_PRS_JSON="$T/prs-empty.json"
FILE_CLAIM_READ_WAIT=x bash "$FC" list >/dev/null 2>"$T/e-retry-wait"
[ "$?" = "2" ] || fail "non-numeric FILE_CLAIM_READ_WAIT exits 2"
grep -qF 'FILE_CLAIM_READ_WAIT must be a whole number of seconds' "$T/e-retry-wait" || fail "invalid FILE_CLAIM_READ_WAIT is named"
export GH_PRS_JSON="$T/prs-empty.json"

# --- --self-pr skips the lane's own PR -----------------------------------------
export GH_PRS_JSON="$T/prs1.json"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4222 --grant --worktree t:d1 --repo test/repo --self-pr 42 a.txt 2>"$T/e3")" || fail "self-pr claim exits 0: $(cat "$T/e3")"
[ "$out" = "$(printf 'GRANT a.txt exists\nfile-claim: 1 granted, 0 refused')" ] || fail "self-pr lines: $out"
# --self-pr takes positive integers only: 0 and leading zeros exit with usage.
for bad_pr in "0" "042" "42 --self-pr 0"; do
  tip_before="$(claim_tip "$R")"
  # shellcheck disable=SC2086
  FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM --self-pr $bad_pr b.txt >/dev/null 2>"$T/e-bad-self-pr"
  rc=$?
  [ "$rc" = 2 ] || fail "--self-pr $bad_pr exits 2, got $rc"
  grep -q '^usage: file-claim' "$T/e-bad-self-pr" || fail "--self-pr $bad_pr prints usage: $(cat "$T/e-bad-self-pr")"
  [ "$(claim_tip "$R")" = "$tip_before" ] || fail "--self-pr $bad_pr stores nothing"
done

# Other PRs overlap, but do not refuse, even with --self-pr.
printf '[{"number":42,"changedFiles":1,"files":[{"path":"a.txt"}]},{"number":7,"changedFiles":1,"files":[{"path":"a.txt"}]}]' >"$T/prs3.json"
export GH_PRS_JSON="$T/prs3.json"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4222 --grant --worktree t:d1 --repo test/repo --self-pr 42 a.txt 2>/dev/null)" || fail "other-PR overlap exits 0"
[ "$out" = "$(printf 'OVERLAP a.txt pr#7\nGRANT a.txt exists\nfile-claim: 1 granted, 0 refused')" ] || fail "other PR overlap with --self-pr: $out"
# a repeated --self-pr exempts every own PR, not only the last.
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4222 --grant --worktree t:d1 --repo test/repo --self-pr 7 --self-pr 42 a.txt 2>&1)" || fail "two self-prs exit 0: $out"
[ "$out" = "$(printf 'GRANT a.txt exists\nfile-claim: 1 granted, 0 refused')" ] || fail "two self-prs exempt both: $out"
export GH_PRS_JSON="$T/prs-empty.json"

# --- ordinary lane overlap; own re-claim is an idempotent no-op --------------
R="$(fresh)"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4223 --grant --worktree t:dA --repo test/repo x.txt 2>/dev/null)" || fail "lane A claim exits 0"
before="$(claims_blob "$R")"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4224 --grant --worktree t:dB --repo test/repo x.txt 2>/dev/null)" || fail "ordinary overlap claim exits 0"
[ "$out" = "$(printf 'OVERLAP x.txt lane:fiber-4223\nGRANT x.txt new\nfile-claim: 1 granted, 0 refused')" ] || fail "ordinary lane overlap: $out"
[ "$(claims_blob "$R" | grep -c "^x.txt${TAB}")" = "2" ] || fail "overlapping claim is recorded beside its holder"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4223 --grant --worktree t:dA --repo test/repo x.txt 2>/dev/null)" || fail "re-claim exits 0"
[ "$out" = "$(printf 'OVERLAP x.txt lane:fiber-4224\nGRANT x.txt new\nfile-claim: 1 granted, 0 refused')" ] || fail "re-claim overlap lines: $out"
[ "$(claims_blob "$R" | grep -c "^x.txt${TAB}")" = "2" ] || fail "re-claim stores no second line"

# A sweep holder keeps an exclusive path; a sweep claimant also refuses an ordinary hold.
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane sweep-4231 --grant --worktree t:dS --repo test/repo x.txt >/dev/null 2>&1 || fail "sweep holder setup exits 0"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4224 --grant --worktree t:dB --repo test/repo x.txt 2>/dev/null)" && fail "ordinary claim cannot take a sweep-held path"
[ "$?" = "1" ] || fail "sweep-holder overlap exits 1"
[ "$out" = "$(printf 'REFUSE x.txt exclusive lane:sweep-4231\nfile-claim: no claims recorded; 1 refused, 0 unclaimed because the batch was refused')" ] || fail "exclusive sweep holder output: $out"
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4232 --grant --worktree t:dO --repo test/repo x.txt >/dev/null 2>&1 || fail "ordinary holder setup exits 0"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane sweep-4231 --grant --worktree t:dS --repo test/repo x.txt 2>/dev/null)" && fail "sweep claimant refuses an ordinary-held path"
[ "$?" = "1" ] || fail "sweep claimant exits 1"
[ "$out" = "$(printf 'REFUSE x.txt lane:fiber-4232\nfile-claim: no claims recorded; 1 refused, 0 unclaimed because the batch was refused')" ] || fail "sweep claimant output: $out"

# --paths claims the following paths.
R="$(fresh)"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4223 --paths --worktree t:dA --repo test/repo y-paths.txt 2>/dev/null)" || fail "--paths claim exits 0"
[ "$out" = "$(printf 'GRANT y-paths.txt new\nfile-claim: 1 granted, 0 refused')" ] || fail "--paths claim output: $out"
grep -q "^y-paths.txt${TAB}fiber-4223${TAB}plan${TAB}" <<<"$(claims_blob "$R")" || fail "--paths records the path claim"

# A plan-kind claim using the legacy --plan alias is still accepted.
# Re-claiming with the other kind keeps the recorded line: a no-op, not an upgrade.
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4223 --plan --worktree t:dA --repo test/repo y.txt 2>/dev/null)" || fail "legacy --plan alias claim exits 0"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4223 --grant --worktree t:dA --repo test/repo y.txt 2>/dev/null)" || fail "cross-kind re-claim exits 0"
grep -q "^y.txt	fiber-4223	plan	" <<<"$(claims_blob "$R")" || fail "cross-kind re-claim keeps plan"

# a repeated path in one call is claimed once.
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4223 --grant --worktree t:dA --repo test/repo d.txt d.txt 2>/dev/null)" || fail "dup-path claim exits 0"
[ "$out" = "$(printf 'GRANT d.txt new\nfile-claim: 1 granted, 0 refused')" ] || fail "dup path one line: $out"
[ "$(claims_blob "$R" | grep -c '^d.txt	')" = "1" ] || fail "dup path one stored line"

# --- mixed ordinary set records its overlaps and grants all paths -------------
R="$(fresh)"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4223 --grant --worktree t:dA --repo test/repo x.txt 2>/dev/null)" || fail "setup claim exits 0"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4224 --grant --worktree t:dB --repo test/repo x.txt y.txt z.txt 2>/dev/null)" || fail "mixed ordinary overlap claim exits 0"
[ "$out" = "$(printf 'OVERLAP x.txt lane:fiber-4223\nGRANT x.txt new\nGRANT y.txt new\nGRANT z.txt new\nfile-claim: 3 granted, 0 refused')" ] || fail "mixed overlap lines: $out"
[ "$(claims_blob "$R" | grep -c '^')" = "4" ] || fail "mixed overlap records every claim"

# --- --plan takes paths; a plan file passed there is refused, nothing claimed ----
R="$(fresh)"
UNTRACKED="$(make_plan untracked.md y3.txt)"
rc=0
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4229 --plan --worktree t:dP --repo test/repo "$UNTRACKED" >/dev/null 2>"$T/e-planpath" || rc=$?
[ "$rc" = "2" ] || fail "untracked plan file as --plan path exits 2, got $rc"
[ "$(cat "$T/e-planpath")" = "file-claim: $UNTRACKED is a plan file, not a path to claim; pass its Files paths after --paths, or the plan with --plan-file $UNTRACKED" ] || fail "plan-as-path message: $(cat "$T/e-planpath")"
[ -z "$(claim_tip "$R")" ] || fail "plan-as-path records no claim"

# A tracked repo file with a Files section is claimed as a path like any other.
TREPO="$T/trepo"
git init -q "$TREPO" || fail "init tracked repo"
printf "## Files\n- \`x.txt\`\n" >"$TREPO/doc.md"
git -C "$TREPO" add doc.md || fail "add tracked doc"
git -C "$TREPO" -c user.email=t@t.t -c user.name=t commit -qm doc || fail "commit tracked doc"
out="$(cd "$TREPO" && FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4229 --plan --worktree t:dP --repo test/repo doc.md 2>/dev/null)" || fail "tracked file with Files section claims as a path"
[ "$out" = "$(printf 'GRANT doc.md new\nfile-claim: 1 granted, 0 refused')" ] || fail "tracked doc lines: $out"

# An untracked plan whose name is a glob matching a tracked file is still a plan file.
R="$(fresh)"
cp "$TREPO/doc.md" "$TREPO/plan1.md"
git -C "$TREPO" add plan1.md || fail "add tracked plan1"
git -C "$TREPO" -c user.email=t@t.t -c user.name=t commit -qm plan1 || fail "commit tracked plan1"
cp "$TREPO/doc.md" "$TREPO/plan[1].md"
rc=0
(cd "$TREPO" && FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4229 --plan --worktree t:dP --repo test/repo 'plan[1].md') >/dev/null 2>&1 || rc=$?
[ "$rc" = "2" ] || fail "untracked glob-named plan as --plan path exits 2, got $rc"
[ -z "$(claim_tip "$R")" ] || fail "glob-named plan records no claim"

# --- --plan-file takes one plan; bad input claims nothing ------------------------
R="$(fresh)"
rc=0
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4229 --plan-file "$PLANS/missing.md" --worktree t:dP --repo test/repo >/dev/null 2>"$T/e-missing" || rc=$?
[ "$rc" = "2" ] || fail "missing plan exits 2, got $rc"
[ "$(cat "$T/e-missing")" = "file-claim: cannot read plan file: $PLANS/missing.md" ] || fail "missing plan message: $(cat "$T/e-missing")"
[ -z "$(claim_tip "$R")" ] || fail "missing plan records no claim"

rc=0
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4229 --plan-file "$PLANS" --worktree t:dP --repo test/repo >/dev/null 2>"$T/e-dir" || rc=$?
[ "$rc" = "2" ] || fail "plan that is a directory exits 2, got $rc"
[ "$(cat "$T/e-dir")" = "file-claim: cannot read plan file: $PLANS" ] || fail "directory plan message: $(cat "$T/e-dir")"
[ -z "$(claim_tip "$R")" ] || fail "directory plan records no claim"

printf "## Tasks\n- \`a.txt\` edit\n" >"$PLANS/nofiles.md"
printf '## Files\nNo paths yet.\n' >"$PLANS/emptyfiles.md"
for plan in "$PLANS/nofiles.md" "$PLANS/emptyfiles.md"; do
  rc=0
  FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4229 --plan-file "$plan" --worktree t:dP --repo test/repo >/dev/null 2>"$T/e-nopaths" || rc=$?
  [ "$rc" = "2" ] || fail "no-path plan $plan exits 2, got $rc"
  [ "$(cat "$T/e-nopaths")" = "file-claim: no paths in the Files section of $plan" ] || fail "no-path plan message: $(cat "$T/e-nopaths")"
  [ -z "$(claim_tip "$R")" ] || fail "no-path plan records no claim"
done

rc=0
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4229 --plan-file "$PLANS/nofiles.md" --worktree t:dP --repo test/repo a.txt >/dev/null 2>&1 || rc=$?
[ "$rc" = "2" ] || fail "--plan-file with two arguments exits 2, got $rc"
[ -z "$(claim_tip "$R")" ] || fail "--plan-file with two arguments records no claim"

rc=0
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4229 --plan --plan-file "$PLANS/nofiles.md" --worktree t:dP --repo test/repo >/dev/null 2>&1 || rc=$?
[ "$rc" = "2" ] || fail "--plan-file with --plan exits 2, got $rc"
rc=0
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4229 --plan-file "$PLANS/nofiles.md" --grant --worktree t:dP --repo test/repo >/dev/null 2>&1 || rc=$?
[ "$rc" = "2" ] || fail "--plan-file with --grant exits 2, got $rc"
[ -z "$(claim_tip "$R")" ] || fail "--plan-file conflicts record no claim"

R="$(fresh)"
VALID="$(make_plan valid.md y2.txt sub/b.txt)"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4229 --plan-file "$VALID" --worktree t:dP --repo test/repo 2>/dev/null)" || fail "valid plan exits 0"
[ "$out" = "$(printf 'GRANT y2.txt new\nGRANT sub/b.txt exists\nfile-claim: 2 granted, 0 refused')" ] || fail "valid plan lines: $out"
blob="$(claims_blob "$R")"
[ "$(cut -f1-3 <<<"$blob")" = "$(printf 'y2.txt\tfiber-4229\tplan\nsub/b.txt\tfiber-4229\tplan')" ] || fail "valid plan stores its Files paths as plan claims: $blob"
grep -q "valid.md" <<<"$blob" && fail "valid plan file itself is not claimed"

# --- --plan-file claims writes only: reads and Reads-section entries stay out ---
R="$(fresh)"
{ printf '## Files\n- `w1.txt`\n- `r1.rs` (read) -- reason\n| `r2.rs` | (read) |\n- `u1.txt` does more things\n### Reads (context)\n- `r3.rs`\n'; } >"$PLANS/reads.md"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4229 --plan-file "$PLANS/reads.md" --worktree t:dP --repo test/repo 2>/dev/null)" || fail "reads plan exits 0"
[ "$out" = "$(printf 'GRANT w1.txt new\nGRANT u1.txt new\nfile-claim: 2 granted, 0 refused')" ] || fail "reads plan claims writes only: $out"
blob="$(claims_blob "$R")"
[ "$(cut -f1 <<<"$blob" | tr '\n' ' ')" = "w1.txt u1.txt " ] || fail "reads plan stores writes only: $blob"

# --- a claim path holding whitespace is refused, but still releasable ----------
R="$(fresh)"
rc=0
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4222 --plan --worktree t:d1 --repo test/repo -- "a.txt b.txt" >/dev/null 2>"$T/e-space" || rc=$?
[ "$rc" = "2" ] || fail "space path exits 2, got $rc"
grep -qF "a.txt b.txt" "$T/e-space" || fail "space-path refusal names the argument: $(cat "$T/e-space")"
[ -z "$(claim_tip "$R")" ] || fail "space path records no claim"

# --- cap of 5 grants; plan claims do not count ----------------------------------
R="$(fresh)"
i=1
while [ "$i" -le 5 ]; do
  FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4225 --grant --worktree t:dG --repo test/repo "g$i" >/dev/null 2>&1 || fail "grant $i of 5 exits 0"
  i=$((i + 1))
done
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4225 --grant --worktree t:dG --repo test/repo g6 2>/dev/null)" && fail "6th grant exits non-zero"
[ "$?" = "1" ] || fail "6th grant exits 1"
[ "$out" = "$(printf 'REFUSE g6 cap\nfile-claim: no claims recorded; 1 refused, 0 unclaimed because the batch was refused')" ] || fail "cap refusal: $out"
[ "$(claims_blob "$R" | grep -c '^')" = "5" ] || fail "cap refusal writes nothing"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4225 --plan --worktree t:dG --repo test/repo p1 p2 p3 >/dev/null 2>&1 || fail "plan claims exit 0 past the grant cap"
[ "$(claims_blob "$R" | grep -c '^')" = "8" ] || fail "plan claims stored past the cap"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4225 --grant --worktree t:dG --repo test/repo g6 2>/dev/null)" && fail "grant past cap still refused"
[ "$out" = "$(printf 'REFUSE g6 cap\nfile-claim: no claims recorded; 1 refused, 0 unclaimed because the batch was refused')" ] || fail "cap holds with plans: $out"

# Other lanes' advisory claims do not exempt paths from the grant cap.
R="$(fresh)"
i=1
while [ "$i" -le 6 ]; do
  FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane "fiber-$((5000 + i))" --grant --worktree "t:h$i" --repo test/repo "shared-$i.txt" >/dev/null 2>&1 || fail "holder $i claim exits 0"
  i=$((i + 1))
done
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4233 --grant --worktree t:claimant --repo test/repo shared-1.txt shared-2.txt shared-3.txt shared-4.txt shared-5.txt shared-6.txt 2>/dev/null)" && fail "six overlapping grants exceed the default cap"
[ "$?" = "1" ] || fail "six overlapping grants exit 1"
[ "$(printf '%s\n' "$out" | grep -c '^REFUSE .* cap$')" = "6" ] || fail "all six overlapping grants refused by cap: $out"
[ "$(claims_blob "$R" | grep -c '^')" = "6" ] || fail "over-cap overlap batch writes no claimant rows"
[ "$(claims_blob "$R" | awk -F '\t' '$2=="fiber-4233" {n++} END {print n+0}')" = "0" ] || fail "over-cap overlap batch records no claimant rows"

# The grant cap admits exactly five new overlapping paths and refuses the sixth.
R="$(fresh)"
i=1
while [ "$i" -le 6 ]; do
  FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane "fiber-$((6000 + i))" --grant --worktree "t:eh$i" --repo test/repo "edge-$i.txt" >/dev/null 2>&1 || fail "edge holder $i claim exits 0"
  i=$((i + 1))
done
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4234 --grant --worktree t:ec --repo test/repo edge-1.txt edge-2.txt edge-3.txt edge-4.txt edge-5.txt 2>/dev/null)" || fail "five overlapping grants at cap exit 0"
[ "$(printf '%s\n' "$out" | grep -c '^GRANT edge-[1-5]\.txt new$')" = "5" ] || fail "five overlapping grants at cap are granted: $out"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4234 --grant --worktree t:ec --repo test/repo edge-6.txt 2>/dev/null)" && fail "one overlapping grant over the cap exits non-zero"
[ "$?" = "1" ] || fail "one overlapping grant over the cap exits 1"
[ "$out" = "$(printf 'OVERLAP edge-6.txt lane:fiber-6006\nREFUSE edge-6.txt cap\nfile-claim: no claims recorded; 1 refused, 0 unclaimed because the batch was refused')" ] || fail "one overlapping grant over cap: $out"
[ "$(claims_blob "$R" | awk -F '\t' '$2=="fiber-4234" {n++} END {print n+0}')" = "5" ] || fail "one-over-cap claim writes no extra row"

# FILE_CLAIM_MAX_GRANT raises the cap; a non-numeric value exits 2.
R="$(fresh)"
i=1
while [ "$i" -le 6 ]; do
  FILE_CLAIM_MAX_GRANT=6 FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4225 --grant --worktree t:dG --repo test/repo "g$i" >/dev/null 2>&1 || fail "grant $i of 6 with FILE_CLAIM_MAX_GRANT=6 exits 0"
  i=$((i + 1))
done
[ "$(claims_blob "$R" | grep -c '^')" = "6" ] || fail "FILE_CLAIM_MAX_GRANT=6: six grants stored"
FILE_CLAIM_MAX_GRANT=abc FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4225 --grant --worktree t:dG --repo test/repo g7 >/dev/null 2>&1
[ "$?" = "2" ] || fail "non-numeric FILE_CLAIM_MAX_GRANT exits 2"

# a call that would cross the cap refuses every new grant path in the call.
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4225 --grant --worktree t:dG --repo test/repo g1 g2 g3 >/dev/null 2>&1 || fail "setup 3 grants"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4225 --grant --worktree t:dG --repo test/repo g4 g5 g6 2>/dev/null)" && fail "over-cap call exits non-zero"
[ "$out" = "$(printf 'REFUSE g4 cap\nREFUSE g5 cap\nREFUSE g6 cap\nfile-claim: no claims recorded; 3 refused, 0 unclaimed because the batch was refused')" ] || fail "over-cap lines: $out"
[ "$(claims_blob "$R" | grep -c '^')" = "3" ] || fail "over-cap call writes nothing"

# --- refusal hints: stderr names the remedy; stdout REFUSE lines are unchanged --
# A cap refusal hints at FILE_CLAIM_MAX_GRANT on stderr.
R="$(fresh)"
i=1
while [ "$i" -le 5 ]; do
  FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4226 --grant --worktree t:dH --repo test/repo "h$i" >/dev/null 2>&1 || fail "hint setup grant $i of 5 exits 0"
  i=$((i + 1))
done
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4226 --grant --worktree t:dH --repo test/repo h6 2>"$T/e-cap-hint")" && fail "cap-hint claim exits non-zero"
[ "$?" = "1" ] || fail "cap-hint claim exits 1"
[ "$out" = "$(printf 'REFUSE h6 cap\nfile-claim: no claims recorded; 1 refused, 0 unclaimed because the batch was refused')" ] || fail "cap-hint stdout unchanged: $out"
grep -qF 'FILE_CLAIM_MAX_GRANT' "$T/e-cap-hint" || fail "cap hint names FILE_CLAIM_MAX_GRANT: $(cat "$T/e-cap-hint")"

# Ordinary PR overlaps are reported but carry no self-PR refusal hint.
R="$(fresh)"
printf '[{"number":42,"changedFiles":1,"files":[{"path":"a.txt"}]}]' >"$T/prs-hint.json"
export GH_PRS_JSON="$T/prs-hint.json"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM a.txt 2>"$T/e-pr-hint")" || fail "PR overlap claim exits 0"
[ "$out" = "$(printf 'OVERLAP a.txt pr#42\nGRANT a.txt exists\nfile-claim: 1 granted, 0 refused')" ] || fail "PR overlap output: $out"
[ ! -s "$T/e-pr-hint" ] || fail "ordinary PR overlap has no refusal hint: $(cat "$T/e-pr-hint")"

# A sweep claimant still receives the --self-pr hint when the PR blocks it.
R="$(fresh)"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane sweep-4231 --grant --worktree t:dS --repo test/repo a.txt 2>"$T/e-sweep-pr-hint")" && fail "sweep PR claim exits non-zero"
[ "$?" = "1" ] || fail "sweep PR refusal exits 1"
[ "$out" = "$(printf 'REFUSE a.txt pr#42 hunks=unknown\nfile-claim: no claims recorded; 1 refused, 0 unclaimed because the batch was refused')" ] || fail "sweep PR refusal output: $out"
grep -qF -- '--self-pr 42' "$T/e-sweep-pr-hint" || fail "sweep PR refusal hints at --self-pr 42"
export GH_PRS_JSON="$T/prs-empty.json"

# usage names the grant-cap variable.
bash "$FC" claim --lane fiber-4222 --repo test/repo >/dev/null 2>"$T/e-usage-hint" && fail "usage exits non-zero"
[ "$?" = "2" ] || fail "usage exits 2"
grep -qF 'FILE_CLAIM_MAX_GRANT' "$T/e-usage-hint" || fail "usage names FILE_CLAIM_MAX_GRANT: $(cat "$T/e-usage-hint")"
grep -qF 'file-claim prune --lane ID [--repo R]' "$T/e-usage-hint" || fail "usage documents prune --lane: $(cat "$T/e-usage-hint")"

# --- --plan and --grant are exclusive --------------------------------------------
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4222 --plan --grant --repo test/repo a.txt >/dev/null 2>&1 && fail "plan+grant exits non-zero"
[ "$?" = "2" ] || fail "plan+grant exits 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4222 --repo test/repo a.txt >/dev/null 2>&1 && fail "neither exits non-zero"
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
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4222 --grant --repo test/repo >/dev/null 2>&1 && fail "no paths exits non-zero"
[ "$?" = "2" ] || fail "no paths exits 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --grant --repo test/repo a.txt >/dev/null 2>&1 && fail "missing lane exits non-zero"
[ "$?" = "2" ] || fail "missing lane exits 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane '' --grant --repo test/repo a.txt >/dev/null 2>&1 && fail "empty lane exits non-zero"
[ "$?" = "2" ] || fail "empty lane exits 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane "$(printf 'a\tb')" --grant --repo test/repo a.txt >/dev/null 2>&1 && fail "tab lane exits non-zero"
[ "$?" = "2" ] || fail "tab lane exits 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4222 --grant --self-pr x --repo test/repo a.txt >/dev/null 2>&1 && fail "non-numeric self-pr exits non-zero"
[ "$?" = "2" ] || fail "non-numeric self-pr exits 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" frobnicate >/dev/null 2>&1 && fail "unknown command exits non-zero"
[ "$?" = "2" ] || fail "unknown command exits 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4222 --grant --bogus --repo test/repo a.txt >/dev/null 2>&1 && fail "unknown flag exits non-zero"
[ "$?" = "2" ] || fail "unknown flag exits 2"

# missing main is an API error with no overwrite.
E="$T/empty.git"
git init -q --bare "$E" || fail "init empty remote"
FILE_CLAIM_REMOTE="$E" bash "$FC" $CLAIM a.txt >/dev/null 2>"$T/e4" && fail "missing main exits non-zero"
[ "$?" = "2" ] || fail "missing main exits 2"
[ -z "$(git -C "$E" for-each-ref)" ] || fail "missing main writes nothing"
out="$(FILE_CLAIM_REMOTE="$E" bash "$FC" list --repo test/repo 2>"$T/e-list-no-main")" || fail "list without main or claims ref exits 0: $(cat "$T/e-list-no-main")"
[ -z "$out" ] || fail "list without main or claims ref has no claim rows: $out"
[ -z "$(git -C "$E" for-each-ref)" ] || fail "list without main or claims ref writes nothing"
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
FILE_CLAIM_REMOTE="$CR" bash "$FC" claim --lane fiber-4222 --grant --worktree t:d --repo test/repo a.txt >/dev/null 2>&1 && fail "bad-field claim exits non-zero"
[ "$?" = "2" ] || fail "bad-field claim exits 2"
[ "$(claim_tip "$CR")" = "$tip_before" ] || fail "bad-field claim overwrites"
FILE_CLAIM_REMOTE="$CR" bash "$FC" list >/dev/null 2>&1 && fail "bad-field list exits non-zero"
[ "$?" = "2" ] || fail "bad-field list exits 2"

CR="$(corrupt_remote 2 "$(printf 'a.txt\tL\tbogus\t2026-01-01T00:00:00Z\tt:d\t')")"
FILE_CLAIM_REMOTE="$CR" bash "$FC" claim --lane fiber-4222 --grant --worktree t:d --repo test/repo a.txt >/dev/null 2>&1 && fail "bad-kind claim exits non-zero"
[ "$?" = "2" ] || fail "bad-kind claim exits 2"

CR="$(corrupt_remote 3 "$(printf 'a.txt\tL\tgrant\tnot-a-date\tt:d\t')")"
FILE_CLAIM_REMOTE="$CR" bash "$FC" claim --lane fiber-4222 --grant --worktree t:d --repo test/repo a.txt >/dev/null 2>&1 && fail "bad-date claim exits non-zero"
[ "$?" = "2" ] || fail "bad-date claim exits 2"

CR="$(corrupt_remote 4 "$(printf 'a.txt\tL\tgrant\t2026-02-30T00:00:00Z\tt:d\t')")"
rc=0
FILE_CLAIM_REMOTE="$CR" bash "$FC" list --lane L --repo test/repo >/dev/null 2>"$T/e-impossible-date" || rc=$?
[ "$rc" = "2" ] || fail "impossible calendar date exits 2, got $rc"
[ "$(cat "$T/e-impossible-date")" = 'file-claim: claims line 1 is corrupt' ] || fail "impossible calendar date diagnostic: $(cat "$T/e-impossible-date")"

# A hand-built claims blob holding a composite row: list prints the row and a
# warning naming it, and release removes it.
CR="$(corrupt_remote ws "$(printf 'a.txt b.txt\tL\tplan\t2026-01-01T00:00:00Z\tt:d\t')")"
out="$(FILE_CLAIM_REMOTE="$CR" bash "$FC" list --lane L --repo test/repo 2>"$T/e-ws")" || fail "list with composite row exits 0: $(cat "$T/e-ws")"
grep -qF "a.txt b.txt" <<<"$out" || fail "list prints the composite row: $out"
grep -qF "a.txt b.txt" "$T/e-ws" || fail "list warns about the composite row: $(cat "$T/e-ws")"
out="$(FILE_CLAIM_REMOTE="$CR" bash "$FC" release --lane L "a.txt b.txt" 2>"$T/e-rel")" || fail "release of composite row exits 0: $(cat "$T/e-rel")"
[ "$out" = "RELEASE a.txt b.txt" ] || fail "release prints the composite path: $out"
[ -z "$(claims_blob "$CR")" ] || fail "composite row removed"

# --- release -------------------------------------------------------------------------
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4223 --grant --worktree t:dA --repo test/repo x.txt y.txt >/dev/null 2>&1 || fail "release setup A"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4224 --grant --worktree t:dB --repo test/repo z.txt >/dev/null 2>&1 || fail "release setup B"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" release --lane fiber-4223 x.txt 2>/dev/null)" || fail "release named exits 0"
[ "$out" = "RELEASE x.txt" ] || fail "release named line: $out"
blob="$(claims_blob "$R")"
[ "$(printf '%s\n' "$blob" | grep -c '^')" = "2" ] || fail "one line released"
grep -q "^y.txt	fiber-4223	grant	" <<<"$blob" || fail "y's claim kept"
grep -q "^z.txt	fiber-4224	grant	" <<<"$blob" || fail "B's claim kept"
# releasing a path another lane holds drops nothing.
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" release --lane fiber-4223 z.txt 2>/dev/null)" || fail "foreign release exits 0"
[ -z "$out" ] || fail "foreign release prints nothing"
[ "$(claims_blob "$R" | grep -c '^')" = "2" ] || fail "foreign release drops nothing"
# release all of a lane.
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" release --lane fiber-4223 2>/dev/null)" || fail "release all exits 0"
[ "$out" = "RELEASE y.txt" ] || fail "release all line: $out"
[ "$(claims_blob "$R" | grep -c '^')" = "1" ] || fail "release all drops the lane"
# a missing lane is a no-op success.
before="$(claims_blob "$R")"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" release --lane NOBODY 2>/dev/null)" || fail "missing-lane release exits 0"
[ -z "$out" ] || fail "missing-lane release prints nothing"
[ "$(claims_blob "$R")" = "$before" ] || fail "missing-lane release writes nothing"

# prune removes every row for its lane and preserves every other lane's rows.
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4223 --grant --worktree t:wtA --repo test/repo prune-a.txt prune-b.txt >/dev/null 2>&1 || fail "prune setup A"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4224 --grant --worktree t:wtB --repo test/repo prune-keep.txt >/dev/null 2>&1 || fail "prune setup B"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" prune --lane fiber-4223 --repo test/repo 2>/dev/null)" || fail "prune exits 0"
[ "$out" = "$(printf 'RELEASE prune-a.txt\nRELEASE prune-b.txt')" ] || fail "prune releases lane rows: $out"
blob="$(claims_blob "$R")"
[ "$(printf '%s\n' "$blob" | grep -c '^')" = "1" ] || fail "prune leaves one other-lane row"
grep -q "^prune-keep.txt${TAB}fiber-4224${TAB}grant${TAB}" <<<"$blob" || fail "prune preserves other lane's claim"

# --- list -------------------------------------------------------------------------------
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4223 --grant --worktree t:wtA --repo test/repo f2.txt >/dev/null 2>&1 || fail "list setup 1"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4223 --plan --worktree t:wtA --repo test/repo f1.txt >/dev/null 2>&1 || fail "list setup 2"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4224 --grant --worktree t:wtB --repo test/repo --self-pr 7 f3.txt >/dev/null 2>&1 || fail "list setup 3"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" list --repo test/repo 2>/dev/null)" || fail "list exits 0"
[ "$(printf '%s\n' "$out" | grep -c '^')" = "3" ] || fail "list has 3 lines: $out"
[ "$(printf '%s' "$out" | cut -f1 | tr '\n' ' ')" = "f1.txt f2.txt f3.txt " ] || fail "list sorted by path: $out"
grep -Eq "^f1.txt	fiber-4223	plan	[0-9]+	t:wtA	$" <<<"$out" || fail "list plan line: $out"
grep -Eq "^f2.txt	fiber-4223	grant	[0-9]+	t:wtA	$" <<<"$out" || fail "list grant line: $out"
grep -Eq "^f3.txt	fiber-4224	grant	[0-9]+	t:wtB	7$" <<<"$out" || fail "list pr passthrough: $out"
: >"$GH_ARGS_LOG"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" list --lane fiber-4223 --repo test/repo 2>/dev/null)" || fail "list --lane exits 0"
[ "$(printf '%s\n' "$out" | grep -c '^')" = "2" ] || fail "list --lane filters: $out"
[ ! -s "$GH_ARGS_LOG" ] || fail "list --lane skips open-PR API reads: $(cat "$GH_ARGS_LOG")"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" list --lane NOBODY --repo test/repo 2>/dev/null)" || fail "list empty lane exits 0"
[ -z "$out" ] || fail "list empty lane prints nothing"

# Full list output includes all six columns, sorted claim and open-PR rows, and
# ages for a leap day, an older timestamp, a future timestamp, and another date.
expected_age() {
  local timestamp="$1" epoch age
  epoch="$(date -u -d "$timestamp" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$timestamp" +%s 2>/dev/null)" || fail "test date conversion failed: $timestamp"
  age=$((LIST_NOW - epoch))
  [ "$age" -ge 0 ] || age=0
  printf '%s' "$age"
}
CR="$(corrupt_remote list-full "$(printf 'a-leap.txt\tfiber-4235\tplan\t2024-02-29T12:00:00Z\tt:leap\t\nb-old.txt\tfiber-4236\tgrant\t2025-01-15T00:00:00Z\tt:old\t9\nc-future.txt\tfiber-4237\tgrant\t2099-12-31T23:59:59Z\tt:future\t\nd-march.txt\tfiber-4238\tgrant\t2026-03-01T01:02:03Z\tt:march\t42')")"
printf '[{"number":22,"changedFiles":1,"files":[{"path":"e-pr22.txt"}]},{"number":5,"changedFiles":1,"files":[{"path":"f-pr5.txt"}]}]' >"$T/prs-list-full.json"
export GH_PRS_JSON="$T/prs-list-full.json"
LIST_NOW="$("$REAL_DATE" -u +%s)"
mkdir -p "$T/fixed-date-bin"
cat >"$T/fixed-date-bin/date" <<'DATE_STUB_EOF'
#!/bin/sh
if [ "$#" -eq 2 ] && [ "$1" = "-u" ] && [ "$2" = "+%s" ]; then
  printf '%s\n' "$*" >>"$FILE_CLAIM_DATE_LOG"
  printf '%s\n' "$FILE_CLAIM_TEST_NOW"
else
  exec "$FILE_CLAIM_REAL_DATE" "$@"
fi
DATE_STUB_EOF
chmod +x "$T/fixed-date-bin/date"
out="$(PATH="$T/fixed-date-bin:$PATH" FILE_CLAIM_TEST_NOW="$LIST_NOW" FILE_CLAIM_REAL_DATE="$REAL_DATE" FILE_CLAIM_DATE_LOG="$T/list-date-calls" FILE_CLAIM_REMOTE="$CR" bash "$FC" list --repo test/repo 2>"$T/e-list-full")" || fail "full list fixture exits 0: $(cat "$T/e-list-full")"
[ "$(cat "$T/list-date-calls")" = '-u +%s' ] || fail "list calls date once for all claim ages: $(cat "$T/list-date-calls")"
expected="$(printf 'a-leap.txt\tfiber-4235\tplan\t%s\tt:leap\t\nb-old.txt\tfiber-4236\tgrant\t%s\tt:old\t9\nc-future.txt\tfiber-4237\tgrant\t0\tt:future\t\nd-march.txt\tfiber-4238\tgrant\t%s\tt:march\t42\ne-pr22.txt\tpr#22\tpr\t-\t-\t22\nf-pr5.txt\tpr#5\tpr\t-\t-\t5' "$(expected_age 2024-02-29T12:00:00Z)" "$(expected_age 2025-01-15T00:00:00Z)" "$(expected_age 2026-03-01T01:02:03Z)")"
[ "$out" = "$expected" ] || fail "full list output and ages; expected: $(printf '\n%s' "$expected")\nactual: $(printf '\n%s' "$out")"

# --- list without --lane adds one row per open-PR path --------------------------
R="$(fresh)"
printf '[{"number":11,"changedFiles":1,"files":[{"path":"p.txt"}]}]' >"$T/prs-list-pr.json"
export GH_PRS_JSON="$T/prs-list-pr.json"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4223 --grant --worktree t:wtA --repo test/repo f1.txt >/dev/null 2>&1 || fail "list-pr setup"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" list --repo test/repo 2>/dev/null)" || fail "list with PR rows exits 0"
[ "$(printf '%s\n' "$out" | grep -c '^')" = "2" ] || fail "list has claim plus PR rows: $out"
grep -Eq "^p.txt	pr#11	pr	-	-	11$" <<<"$out" || fail "list PR row: $out"
grep -Eq "^f1.txt	fiber-4223	grant	[0-9]+	t:wtA	$" <<<"$out" || fail "list keeps claim rows: $out"
[ "$(printf '%s' "$out" | cut -f1 | tr '\n' ' ')" = "f1.txt p.txt " ] || fail "list sorts PR rows with claims: $out"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" list --lane fiber-4223 --repo test/repo 2>/dev/null)" || fail "list --lane exits 0"
grep -q "pr#" <<<"$out" && fail "list --lane omits PR rows: $out"
[ "$(printf '%s\n' "$out" | grep -c '^')" = "1" ] || fail "list --lane has claim rows only: $out"
# A failed PR-file read fails list closed.
GH_LIST_FAIL_COUNT="$T/gh-list-fail-count"
printf 0 >"$GH_LIST_FAIL_COUNT"
FILE_CLAIM_REMOTE="$R" FILE_CLAIM_READ_WAIT=0 GH_FAIL_FILES_PR=11 GH_FAIL_FILES_TIMES=99 GH_FAIL_FILES_COUNT="$GH_LIST_FAIL_COUNT" bash "$FC" list --repo test/repo >/dev/null 2>"$T/e-list-fail" && fail "list exits non-zero when a PR file read fails"
[ "$?" = "2" ] || fail "list exits 2 when a PR file read fails"
grep -qF 'cannot list files for open PR #11' "$T/e-list-fail" || fail "list failure names PR 11"
export GH_PRS_JSON="$T/prs-empty.json"

# the default worktree is host:cwd.
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4230 --grant --repo test/repo w.txt >/dev/null 2>&1 || fail "default worktree claim exits 0"
out="$(FILE_CLAIM_REMOTE="$R" bash "$FC" list --lane fiber-4230 --repo test/repo 2>/dev/null)" || fail "default worktree list exits 0"
grep -Eq "^w.txt	fiber-4230	grant	[0-9]+	$(hostname -s):$(pwd)	$" <<<"$out" || fail "default worktree: $out"

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
      FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4235 --grant --worktree t:hook --repo test/repo rival.txt >/dev/null 2>&1 || exit 2
    fi
    ;;
esac
exec "$REAL_GIT" "\$@"
WRAP_EOF
chmod +x "$T/gitwrap/git"
out="$(PATH="$T/gitwrap:$PATH" FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-4227 --grant --worktree t:dM --repo test/repo outer.txt 2>"$T/e5")" || fail "NFF claim exits 0: $(cat "$T/e5")"
[ "$out" = "$(printf 'GRANT outer.txt new\nfile-claim: 1 granted, 0 refused')" ] || fail "NFF lines: $out"
[ "$(wc -l <"$T/push.log")" -ge 3 ] || fail "push retried after NFF"
blob="$(claims_blob "$R")"
grep -q "^outer.txt	fiber-4227	grant	" <<<"$blob" || fail "outer claim recorded after retry"
grep -q "^rival.txt	fiber-4235	grant	" <<<"$blob" || fail "rival claim kept after retry"
PATH="$T/stubbin:$PATH"

# a push failure that is not a non-fast-forward exits 2 at once.
D="$T/not-a-repo"
mkdir -p "$D"
FILE_CLAIM_REMOTE="$D" bash "$FC" $CLAIM a.txt >/dev/null 2>&1 && fail "bad-remote claim exits non-zero"
[ "$?" = "2" ] || fail "bad-remote claim exits 2"

# --- server-side 'fatal error in commit_refs' is retried, then succeeds -------------------
R="$(fresh)"
COMMIT_COUNT="$T/commit-refs-count"
printf 0 >"$COMMIT_COUNT"
cat >"$R/hooks/update" <<'HOOK_EOF'
#!/usr/bin/env bash
count="$(cat "$COMMIT_HOOK_COUNT")"
count=$((count + 1))
printf '%s' "$count" >"$COMMIT_HOOK_COUNT"
if [ "$count" -le 2 ]; then
  echo "fatal error in commit_refs" >&2
  exit 1
fi
exit 0
HOOK_EOF
chmod +x "$R/hooks/update"
out="$(COMMIT_HOOK_COUNT="$COMMIT_COUNT" FILE_CLAIM_PUSH_WAIT=0 FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM retry.txt 2>"$T/e-commit-refs")" || fail "commit_refs retry claim exits 0: $(cat "$T/e-commit-refs")"
[ "$out" = "$(printf 'GRANT retry.txt new\nfile-claim: 1 granted, 0 refused')" ] || fail "commit_refs retry lines: $out"
[ "$(cat "$COMMIT_COUNT")" = "3" ] || fail "commit_refs retried twice then pushed: $(cat "$COMMIT_COUNT")"
grep -q "^retry.txt	fiber-4222	grant	" <<<"$(claims_blob "$R")" || fail "commit_refs retry recorded"

# persistent commit_refs failure exits 2 with the server message after 3 tries.
R="$(fresh)"
COMMIT_COUNT2="$T/commit-refs-count2"
printf 0 >"$COMMIT_COUNT2"
cat >"$R/hooks/update" <<'HOOK_EOF'
#!/usr/bin/env bash
count="$(cat "$COMMIT_HOOK_COUNT")"
count=$((count + 1))
printf '%s' "$count" >"$COMMIT_HOOK_COUNT"
echo "fatal error in commit_refs" >&2
exit 1
HOOK_EOF
chmod +x "$R/hooks/update"
rc=0
COMMIT_HOOK_COUNT="$COMMIT_COUNT2" FILE_CLAIM_PUSH_WAIT=0 FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM retry.txt >/dev/null 2>"$T/e-commit-refs-fail" || rc=$?
[ "$rc" = "2" ] || fail "persistent commit_refs exits 2, got $rc"
grep -qF 'fatal error in commit_refs' "$T/e-commit-refs-fail" || fail "persistent commit_refs names server message: $(cat "$T/e-commit-refs-fail")"
[ "$(cat "$COMMIT_COUNT2")" = "3" ] || fail "persistent commit_refs tried 3 times: $(cat "$COMMIT_COUNT2")"
[ -z "$(claim_tip "$R")" ] || fail "persistent commit_refs writes nothing"

# a permission-style rejection exits 2 after one try.
R="$(fresh)"
PERM_COUNT="$T/perm-count"
printf 0 >"$PERM_COUNT"
cat >"$R/hooks/update" <<'HOOK_EOF'
#!/usr/bin/env bash
count="$(cat "$COMMIT_HOOK_COUNT")"
count=$((count + 1))
printf '%s' "$count" >"$COMMIT_HOOK_COUNT"
echo "permission denied: cannot push to refs/claims/live" >&2
exit 1
HOOK_EOF
chmod +x "$R/hooks/update"
rc=0
COMMIT_HOOK_COUNT="$PERM_COUNT" FILE_CLAIM_PUSH_WAIT=0 FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM retry.txt >/dev/null 2>"$T/e-perm" || rc=$?
[ "$rc" = "2" ] || fail "permission rejection exits 2, got $rc"
[ "$(cat "$PERM_COUNT")" = "1" ] || fail "permission rejection tried once: $(cat "$PERM_COUNT")"
[ -z "$(claim_tip "$R")" ] || fail "permission rejection writes nothing"

# invalid push-wait exits 2 like the read wait.
FILE_CLAIM_PUSH_WAIT=x FILE_CLAIM_REMOTE="$R" bash "$FC" $CLAIM a.txt >/dev/null 2>"$T/e-push-wait"
[ "$?" = "2" ] || fail "non-numeric FILE_CLAIM_PUSH_WAIT exits 2"
grep -qF 'FILE_CLAIM_PUSH_WAIT must be a whole number of seconds' "$T/e-push-wait" || fail "invalid FILE_CLAIM_PUSH_WAIT is named"

# --- concurrency: both ordinary claimants record their overlap ----------------------
# One round of the race: both lanes start before a single wait. Both claims are
# advisory, so each lane records its claim even when the other gets there first.
RACE_TICKET=7000
race_round() {
  local label="$1" remote="$2" path="$3" c1 c2 n c f lane_a lane_b
  # Each round gets two fresh ticket numbers so the 5-grant cap never binds,
  # while each racing lane holds under a distinct canonical holder.
  lane_a="fiber-$RACE_TICKET"
  lane_b="fiber-$((RACE_TICKET + 1))"
  RACE_TICKET=$((RACE_TICKET + 2))
  (FILE_CLAIM_REMOTE="$remote" bash "$FC" claim --lane "$lane_a" --grant --worktree t:dA --repo test/repo "$path" >/dev/null 2>"$T/err1-$label"; echo "$?" >"$T/c1-$label") &
  (FILE_CLAIM_REMOTE="$remote" bash "$FC" claim --lane "$lane_b" --grant --worktree t:dB --repo test/repo "$path" >/dev/null 2>"$T/err2-$label"; echo "$?" >"$T/c2-$label") &
  wait
  c1="$(cat "$T/c1-$label")"
  c2="$(cat "$T/c2-$label")"
  case "$c1$c2" in
    00) ;;
    *)
      for n in 1 2; do
        if [ "$n" = "1" ]; then c="$c1"; else c="$c2"; fi
        [ -n "$c" ] || c="unknown"
        f="$T/err$n-$label"
        echo "round $label: lane $n (exit $c) stderr:" >&2
        if [ ! -r "$f" ]; then
          echo "  (unreadable: $f)" >&2
        elif [ -s "$f" ]; then
          sed 's/^/  /' "$f" >&2
        else
          echo "  (empty)" >&2
        fi
      done
      fail "round $label: exits $c1 and $c2, want both 0"
      ;;
  esac
}
R="$(fresh)"
i=1
while [ "$i" -le 20 ]; do
  race_round "$i" "$R" "race-$i.txt"
  i=$((i + 1))
done
[ "$(claims_blob "$R" | grep -c '^')" = "40" ] || fail "both claims in each race are recorded"
i=1
while [ "$i" -le 20 ]; do
  [ "$(claims_blob "$R" | grep -c "^race-$i.txt${TAB}")" = "2" ] || fail "race-$i overlap has both claim rows"
  i=$((i + 1))
done

# --- failing rounds dump each lane's stderr --------------------------------------
# A bad remote fails both lanes at once, driving the diagnostic path without a race.
diag_out="$( (race_round diag "$D" diag.txt) 2>&1 )"
diag_rc=$?
[ "$diag_rc" = "1" ] || fail "diagnostic round exits 1, got $diag_rc: $diag_out"
grep -qxF 'round diag: lane 1 (exit 2) stderr:' <<<"$diag_out" || fail "lane 1 dump label: $diag_out"
grep -qxF 'round diag: lane 2 (exit 2) stderr:' <<<"$diag_out" || fail "lane 2 dump label: $diag_out"
grep -qF "  file-claim: cannot fetch main from $D" <<<"$diag_out" || fail "lane stderr dumped: $diag_out"
grep -qxF 'FAIL: round diag: exits 2 and 2, want both 0' <<<"$diag_out" || fail "failure line kept: $diag_out"

# --- closed ticket and PR holds are reaped safely -------------------------------
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-6001 --grant --worktree t:closed --repo test/repo closed.txt >/dev/null 2>&1 || fail "closed-ticket claim setup"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-6002 --grant --worktree t:open --repo test/repo --self-pr 93 open.txt >/dev/null 2>&1 || fail "open-ticket claim setup"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-6003 --grant --worktree t:pr --repo test/repo --self-pr 92 pr-closed.txt >/dev/null 2>&1 || fail "closed-PR claim setup"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane sweep-6004 --grant --worktree t:sweep --repo test/repo sweep.txt >/dev/null 2>&1 || fail "sweep claim setup"
printf 'Grant 1\n\nTicket: 6001\nPaths:\n- closed.txt\n' >"$FW_RUN/fiber-6001-fence-grant-1.md"
printf 'Grant 1\n\nTicket: 6002\nPaths:\n- open.txt\n' >"$FW_RUN/fiber-6002-fence-grant-1.md"
printf 'Grant 1\n\nTicket: 6003\nPaths:\n- pr-closed.txt\n' >"$FW_RUN/fiber-6003-fence-grant-1.md"
printf 'Grant 1\n\nTicket: 92\nPaths:\n- pr-closed.txt\n' >"$FW_RUN/fiber-92-fence-grant-1.md"
out="$(GH_TICKET_STATES='6001:CLOSED,6002:OPEN,6003:OPEN,92:MERGED,93:OPEN,6004:CLOSED' FILE_CLAIM_REMOTE="$R" bash "$FC" reap --repo test/repo 2>"$T/e-reap")" || fail "reap succeeds: $(cat "$T/e-reap")"
grep -qF 'REAP claim closed.txt by fiber-6001' <<<"$out" || fail "closed-ticket claim reported: $out"
grep -qF 'REAP claim pr-closed.txt by fiber-6003' <<<"$out" || fail "closed-PR claim reported: $out"
grep -qF 'REAP grant fiber-6001-fence-grant-1.md' <<<"$out" || fail "closed-ticket grant reported: $out"
grep -qF 'REAP grant fiber-92-fence-grant-1.md' <<<"$out" || fail "merged-PR grant reported: $out"
grep -qF 'REAP grant fiber-6003-fence-grant-1.md (ticket #6003 or associated PR closed)' <<<"$out" || fail "grant for ticket with merged PR reported: $out"
[ "$(grep -c '^REAP ' <<<"$out")" = 5 ] || fail "reap reports each dropped claim and grant: $out"
[ ! -e "$FW_RUN/fiber-6001-fence-grant-1.md" ] || fail "closed-ticket grant removed"
[ ! -e "$FW_RUN/fiber-92-fence-grant-1.md" ] || fail "merged-PR grant removed"
[ ! -e "$FW_RUN/fiber-6003-fence-grant-1.md" ] || fail "grant for ticket with merged PR removed"
[ -e "$FW_RUN/fiber-6002-fence-grant-1.md" ] || fail "open-ticket grant with open PR kept"
[ "$(claims_blob "$R" | grep -c '^')" = 2 ] || fail "open and sweep claims remain after reap"
list="$(FILE_CLAIM_REMOTE="$R" bash "$FC" list --repo test/repo 2>/dev/null)" || fail "list after reap succeeds"
grep -qF 'open.txt' <<<"$list" || fail "open-ticket claim remains on next check: $list"
grep -qF 'sweep.txt' <<<"$list" || fail "sweep claim remains after closed ticket: $list"
! grep -qF 'closed.txt' <<<"$list" || fail "closed-ticket claim is gone on next check: $list"

# A stale-only holder is removed before a sweep claimant decides whether it can grant.
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-6010 --grant --worktree t:old --repo test/repo p.txt >/dev/null 2>&1 || fail "stale-only holder setup"
out="$(GH_TICKET_STATES='6010:CLOSED' FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane sweep-6011 --grant --worktree t:new --repo test/repo p.txt 2>"$T/e-reap-guard")" || fail "stale-only holder no longer refuses: $(cat "$T/e-reap-guard")"
grep -qF 'REAP claim p.txt by fiber-6010' <<<"$out" || fail "guard reports automatic stale reap: $out"
grep -qF 'GRANT p.txt new' <<<"$out" || fail "guard grants after stale holder is removed: $out"
[ "$(claims_blob "$R" | grep -c '^')" = 1 ] || fail "stale-only holder was replaced by claimant"

# A failed or partial ticket-state response keeps every hold in the batch.
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-6020 --grant --worktree t:one --repo test/repo fail-closed.txt >/dev/null 2>&1 || fail "lookup-failure setup 1"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-6021 --grant --worktree t:two --repo test/repo fail-open.txt >/dev/null 2>&1 || fail "lookup-failure setup 2"
printf 'Grant 1\n\nTicket: 6020\nPaths:\n- fail-closed.txt\n' >"$FW_RUN/fiber-6020-fence-grant-1.md"
printf 'Grant 1\n\nTicket: 6021\nPaths:\n- fail-open.txt\n' >"$FW_RUN/fiber-6021-fence-grant-1.md"
before="$(claims_blob "$R")"
out="$(GH_TICKET_FAIL=1 GH_TICKET_STATES='6020:CLOSED,6021:OPEN' FILE_CLAIM_REMOTE="$R" bash "$FC" reap --repo test/repo 2>"$T/e-reap-fail")" || fail "failed lookup is a safe no-op: $(cat "$T/e-reap-fail")"
[ -z "$out" ] || fail "failed lookup reports no drops: $out"
[ "$(claims_blob "$R")" = "$before" ] || fail "failed lookup keeps every claim"
[ -e "$FW_RUN/fiber-6020-fence-grant-1.md" ] && [ -e "$FW_RUN/fiber-6021-fence-grant-1.md" ] || fail "failed lookup keeps every fence grant"
out="$(GH_TICKET_OMIT=6021 GH_TICKET_STATES='6020:CLOSED' FILE_CLAIM_REMOTE="$R" bash "$FC" reap --repo test/repo 2>"$T/e-reap-partial")" || fail "partial lookup is a safe no-op: $(cat "$T/e-reap-partial")"
[ -z "$out" ] || fail "partial lookup reports no drops: $out"
[ "$(claims_blob "$R")" = "$before" ] || fail "partial lookup keeps every claim"
[ -e "$FW_RUN/fiber-6020-fence-grant-1.md" ] && [ -e "$FW_RUN/fiber-6021-fence-grant-1.md" ] || fail "partial lookup keeps every fence grant"

# A stored PR field of 0 (written before --self-pr rejected it) is skipped, so
# the batch lookup never asks gh for PR 0 and a closed ticket is still reaped.
R="$(fresh)"
FILE_CLAIM_REMOTE="$R" bash "$FC" claim --lane fiber-6030 --grant --worktree t:z --repo test/repo zero-a.txt >/dev/null 2>&1 || fail "pr-0 setup claim"
pr0="$T/pr0-claims"
git -c init.defaultBranch=main init -q "$pr0" || fail "init pr-0 fixture"
git -C "$pr0" config user.email t@t.t || fail "pr-0 fixture email"
git -C "$pr0" config user.name t || fail "pr-0 fixture name"
git -C "$pr0" remote add origin "$R" || fail "pr-0 fixture remote"
git -C "$pr0" fetch -q origin refs/claims/live || fail "fetch claims for pr-0 fixture"
git -C "$pr0" checkout -q -b pr0-claim FETCH_HEAD || fail "checkout claims for pr-0 fixture"
printf 'zero-b.txt\tfiber-6031\tgrant\t2026-01-02T03:04:05Z\tt:z\t0\n' >>"$pr0/claims"
printf 'zero-c.txt\tfiber-6032\tgrant\t2026-01-02T03:04:05Z\tt:z\t0,94\n' >>"$pr0/claims"
git -C "$pr0" add claims || fail "stage pr-0 claim"
git -C "$pr0" commit -qm 'pr-0 claim' || fail "commit pr-0 claim"
git -C "$pr0" push -q origin HEAD:refs/claims/live || fail "publish pr-0 claim"
out="$(GH_TICKET_OMIT=0 GH_TICKET_STATES='6030:CLOSED,6031:CLOSED,6032:OPEN,94:MERGED' FILE_CLAIM_REMOTE="$R" bash "$FC" reap --repo test/repo 2>"$T/e-reap-pr0")" || fail "reap with a PR-0 record succeeds: $(cat "$T/e-reap-pr0")"
! grep -q 'reap skipped' "$T/e-reap-pr0" || fail "PR-0 record does not skip the reap: $(cat "$T/e-reap-pr0")"
grep -qF 'REAP claim zero-a.txt by fiber-6030' <<<"$out" || fail "closed ticket reaped beside a PR-0 record: $out"
grep -qF 'REAP claim zero-b.txt by fiber-6031' <<<"$out" || fail "closed ticket with PR 0 reaped: $out"
grep -qF 'REAP claim zero-c.txt by fiber-6032' <<<"$out" || fail "merged PR beside PR 0 reaped: $out"
[ -z "$(claims_blob "$R")" ] || fail "every PR-0 batch claim reaped: $(claims_blob "$R")"

echo "file-claim tests passed"

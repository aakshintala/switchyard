#!/usr/bin/env bash
# Tests for bin/ship-pr: real git on throwaway repos (a bare origin, a clone
# and a linked worktree), a stand-in gh and sleep (functions, no network). The real
# gh-ci and pr-closes run against the stand-in gh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIP="$SCRIPT_DIR/../bin/ship-pr"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-ship-pr.XXXXXX")"
trap 'rm -rf "$T"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GH_CI_INTERVAL=7 SHIP_PR_INTERVAL=1
MERGE_SHA="1f2e3d4c5b6a79881726354433221100ffeeddcc"

# --- fake gh. Reads $ST (state dir) and $ORIGIN. The PR head is origin's
# --- feature branch, so a push is visible to gh-ci. --jq runs through jq.
gh() (
  set -euo pipefail
  echo "gh $*" >>"$ST/gh.log"
  rd() { [ -e "$ST/$1" ] && cat "$ST/$1" || echo "$2"; }
  if [ "$1" = "api" ]; then
    shift; [ "$1" != "--paginate" ] || shift; path="$1"; shift
    jq=""
    while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && jq="$2"; shift; done
    case "$path" in
      */rules/branches/main)
        [ ! -e "$ST/api-fail" ] || { echo "gh: forbidden (HTTP 403)" >&2; exit 1; }
        json="$(rd rules '[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"ci"}]}}]')";;
      */protection/required_status_checks)
        [ ! -e "$ST/classic-fail" ] || { echo "gh: forbidden (HTTP 403)" >&2; exit 1; }
        [ -e "$ST/classic" ] || { echo "gh: Branch not protected (HTTP 404)" >&2; exit 1; }
        json="$(cat "$ST/classic")";;
      */pulls/*)
        # gh-ci's REST read of the PR: the same head and state as pr view
        [ ! -e "$ST/view-fail" ] || { echo "gh: HTTP 502" >&2; exit 1; }
        if h="$(git --git-dir="$ORIGIN" rev-parse refs/heads/feature 2>/dev/null)"; then
          echo "$h" >"$ST/lasthead"
        else
          h="$(cat "$ST/lasthead")"
        fi
        json="$(jq -nc --arg h "$h" --arg d "$(rd draft false)" --arg ms "$(rd merge-state CLEAN | tr 'A-Z' 'a-z')" \
          '{head: {sha: $h}, mergeable_state: $ms, draft: ($d == "true"), base: {ref: "main"}}')";;
      */actions/runs*)
        json='{"workflow_runs":[]}';;
      */commits/*/check-runs*)
        # gh-ci's REST poll of the head's checks: the hooks run here, once per poll
        if [ -e "$ST/checks-hook" ]; then bash "$ST/checks-hook"; rm -f "$ST/checks-hook"; fi
        if [ -e "$ST/checks-each" ]; then bash "$ST/checks-each"; fi
        json="$(rd checks '[]' | jq -c '{total_count: length, check_runs: [.[] | {name: .name,
          status: (if .bucket == "pending" then "in_progress" else "completed" end),
          conclusion: ({pass: "success", fail: "failure", cancel: "cancelled", skipping: "skipped"}[.bucket] // null)}]}')";;
      *) echo "fake gh: unknown api $path" >&2; exit 2;;
    esac
    if [ -n "$jq" ]; then jq -r "$jq" <<<"$json"; else echo "$json"; fi
    exit 0
  fi
  [ "$1" = "pr" ] || { echo "fake gh: only pr and api supported" >&2; exit 2; }
  shift
  sub="$1"; shift
  case "$sub" in
    view)
      [ ! -e "$ST/view-fail" ] || exit 1
      case " $* " in *" --json body "*) [ ! -e "$ST/body-fail" ] || exit 1;; esac
      if h="$(git --git-dir="$ORIGIN" rev-parse refs/heads/feature 2>/dev/null)"; then
        echo "$h" >"$ST/lasthead"
      else
        h="$(cat "$ST/lasthead")"
      fi
      state="$(rd state OPEN)"
      json="$(jq -nc --arg h "$h" --arg s "$state" --arg d "$(rd draft false)" --arg ms "$(rd merge-state CLEAN)" --arg mg "$(rd mergeable MERGEABLE)" --arg b "$(rd body 'Resolves #97')" \
        --argjson bn "$([ -e "$ST/body-null" ] && echo true || echo false)" --argjson c "$(rd commits '[]')" --arg m "$MERGE_SHA" \
        '{state:$s, headRefName:"feature", baseRefName:"main", headRefOid:$h, isDraft:($d=="true"), mergeStateStatus:$ms, mergeable:$mg,
          title:"t", body:(if $bn then null else $b end), commits:$c, mergeCommit:(if $s=="MERGED" then {oid:$m} else null end)}')"
      jq=""
      while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && jq="$2"; shift; done
      if [ -n "$jq" ]; then jq -r "$jq" <<<"$json"; else echo "$json"; fi;;
    ready)
      [ ! -e "$ST/ready-fail" ] || exit 1
      echo false >"$ST/draft";;
    comment)
      [ ! -e "$ST/comment-fail" ] || exit 1
      while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && cp "$2" "$ST/comment.txt"; shift; done;;
    merge)
      if [ -e "$ST/merge-fail-once" ]; then
        cat "$ST/merge-fail-once" >&2
        rm -f "$ST/merge-fail-once"
        exit 1
      fi
      if [ -e "$ST/merge-fail-msg" ]; then cat "$ST/merge-fail-msg" >&2; exit 1; fi
      [ ! -e "$ST/merge-fail" ] || exit 1
      [ -e "$ST/no-merge" ] || echo MERGED >"$ST/state"
      [ ! -e "$ST/merge-deletes-branch" ] || git --git-dir="$ORIGIN" update-ref -d refs/heads/feature;;
    *) echo "fake gh: unknown $sub" >&2; exit 2;;
  esac
)
sleep() ( echo "$*" >>"$ST/sleeps.txt" )
export -f gh sleep

# --- fixture: main with file.txt, feature (one commit) pushed and checked out in $WT.
setup() {
  S="$T/case"; rm -rf "$S"; mkdir -p "$S/st"
  WT="$S/wt"; C="$S/clone"
  export ST="$S/st" ORIGIN="$S/origin.git" MERGE_SHA C
  git init -q --bare -b main "$ORIGIN"
  git init -q -b main "$C"
  git -C "$C" remote add origin "$ORIGIN"
  printf 'a\nb\nc\n' >"$C/file.txt"
  git -C "$C" add . && git -C "$C" commit -qm init
  git -C "$C" push -q origin main
  git -C "$C" worktree add -q -b feature "$WT"
  echo feature >"$WT/feature.txt"
  git -C "$WT" add . && git -C "$WT" commit -qm feature
  git -C "$WT" push -q -u origin feature
  HEAD0="$(git -C "$WT" rev-parse HEAD)"
  echo '[{"bucket":"pass","name":"ci"}]' >"$ST/checks"
}

origin_head() { git --git-dir="$ORIGIN" rev-parse --verify -q refs/heads/feature; }
# bump_ref <ref> in origin: a new commit on top, without a checkout.
bump_ref() {
  git --git-dir="$ORIGIN" update-ref "$1" \
    "$(git --git-dir="$ORIGIN" commit-tree "$1^{tree}" -p "$1" -m bump)"
}
# advance_main <file> <content>: a commit on main pushed to origin.
advance_main() {
  printf '%s\n' "$2" >"$C/$1"
  git -C "$C" add . && git -C "$C" commit -qm "main $1"
  git -C "$C" push -q origin main
}
# checks_hook <shell>: runs once, inside the first CI poll (a check-runs call).
checks_hook() { printf '%s\n' "$1" >"$ST/checks-hook"; }
# checks_each <shell>: runs inside every CI poll (a check-runs call).
checks_each() { printf '%s\n' "$1" >"$ST/checks-each"; }
# BUMP_MAIN: an empty commit on origin's main, without a checkout.
BUMP_MAIN='git --git-dir="$ORIGIN" update-ref refs/heads/main "$(git --git-dir="$ORIGIN" commit-tree "refs/heads/main^{tree}" -p refs/heads/main -m b)"'

OUT=""; ERR=""; CODE=0
run() {
  O0="$(origin_head)"; W0="$(git -C "$WT" rev-parse HEAD 2>/dev/null)"
  # git wrapper: with $ST/delete-fails, `push origin --delete` fails the way
  # GitHub's does after it auto-deletes the branch on merge. Defined and
  # exported only for the command under test, so the suite's own git calls
  # never see it.
  OUT="$(
    git() (
      if [ -e "$ST/delete-fails" ] && [[ " $* " == *" push origin --delete "* ]]; then
        echo "error: cannot lock ref 'refs/remotes/origin/feature': unable to resolve reference" >&2
        exit 1
      fi
      command git "$@"
    )
    export -f git
    bash "$SHIP" "$@" 2>"$S/stderr.txt"
  )"; CODE=$?
  ERR="$(cat "$S/stderr.txt")"
}
ship() { run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT" "$@"; }
untouched() {
  [ "$(origin_head)" = "$O0" ] || fail "$1: origin branch unchanged"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$W0" ] || fail "$1: worktree HEAD unchanged"
}
expect() { [ "$CODE" = "$1" ] || fail "$2: exit $1 (got $CODE): out=[$OUT] err=[$ERR]"; }
no_merge() { ! grep -q '^gh pr \(merge\|ready\)' "$ST/gh.log" 2>/dev/null || fail "$1: no ready or merge call"; }

# ===== exit 2: usage and preconditions
setup
for args in "" "abc" "7" "7 --repo O/N --reviewed x" "7 --reviewed x --worktree $WT" \
            "7 --repo O/N --worktree $WT" "7 --repo O/N --reviewed x --worktree $WT --bogus 1" \
            "7 --repo O/N --reviewed x --worktree $WT --timeout x" \
            "7 --repo O/N --reviewed x --worktree $WT --timeout -1" \
            "7 --repo O/N --reviewed x --worktree $WT --gate"; do
  # shellcheck disable=SC2086
  run $args; expect 2 "usage [$args]"; untouched "usage [$args]"
  grep -q '^usage: ship-pr' <<<"$ERR" || fail "usage text for [$args]: [$ERR]"
done

setup; touch "$ST/view-fail"; ship; expect 2 "unreadable PR"; untouched "unreadable PR"
setup; echo CLOSED >"$ST/state"; ship; expect 2 "PR not open"; untouched "PR not open"
setup; run 7 --repo O/N --reviewed "$HEAD0" --worktree "$S"; expect 2 "not a checkout"
setup; git -C "$WT" checkout -q -b other; ship; expect 2 "wrong branch"; untouched "wrong branch"
setup; echo x >>"$WT/feature.txt"; ship; expect 2 "dirty tree"; untouched "dirty tree"
setup; echo x >"$WT/untracked.txt"; ship; expect 2 "untracked file"; untouched "untracked file"
setup; bump_ref refs/heads/feature; ship; expect 2 "HEAD differs from PR head"; untouched "HEAD differs"
setup; run 7 --repo O/N --reviewed deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --worktree "$WT"
expect 2 "unknown reviewed"; untouched "unknown reviewed"
no_merge "preconditions"

# ===== exit 3: rebase conflict aborts cleanly
setup
echo changed >"$WT/file.txt"; git -C "$WT" commit -qam "touch file"; git -C "$WT" push -q origin feature
HEAD0="$(git -C "$WT" rev-parse HEAD)"
advance_main file.txt conflicting
ship; expect 3 "rebase conflict"; untouched "rebase conflict"
for d in rebase-merge rebase-apply; do
  [ ! -e "$(git -C "$WT" rev-parse --git-path $d)" ] || fail "conflict leaves no $d"
done
[ -z "$(git -C "$WT" status --porcelain)" ] || fail "conflict leaves a clean tree"
no_merge "conflict"

# ===== exit 4: a different patch than the reviewed one
setup
git -C "$C" checkout -q -b other
echo other >"$C/other.txt"; git -C "$C" add . && git -C "$C" commit -qm other
OTHER="$(git -C "$C" rev-parse HEAD)"
run 7 --repo O/N --reviewed "$OTHER" --worktree "$WT"; expect 4 "patch-id mismatch"; untouched "patch-id mismatch"
no_merge "mismatch"

# ===== --reviewed is the old head: a pushed head with the same patch-id is accepted,
# ===== and one whose patch-id differs exits 4 before any merge
setup
git -C "$WT" commit -q --amend -m 'feature, reworded'
[ "$(git -C "$WT" rev-parse HEAD)" != "$HEAD0" ] || fail "amend moved the head"
git -C "$WT" push -q --force-with-lease origin HEAD:refs/heads/feature
ship; expect 0 "pushed head whose patch-id matches --reviewed is accepted"
grep -q '^gh pr merge' "$ST/gh.log" || fail "same patch-id: merged"

setup
echo changed >"$WT/feature.txt"; git -C "$WT" commit -q --amend --no-edit -a
git -C "$WT" push -q --force-with-lease origin HEAD:refs/heads/feature
ship; expect 4 "pushed head whose patch-id differs from --reviewed exits 4"
no_merge "pushed head with a changed patch"

# ===== exit 1: gate
setup
ship --gate 'echo gate-line-1; echo gate-line-2; exit 3'
expect 1 "failing gate"; untouched "failing gate"
grep -q gate-line-2 <<<"$OUT" || fail "gate tail on stdout: [$OUT]"
no_merge "failing gate"
setup; advance_main other.txt o
ship --gate 'exit 3'; expect 1 "failing gate after main moved"; untouched "failing gate after main moved"
setup; advance_main other.txt o
ship --gate 'test ! -e other.txt'; expect 0 "gate runs on the pre-rebase head"
setup; ship --gate 'git commit -q --allow-empty -m gate'
expect 1 "gate that commits"; [ "$(origin_head)" = "$O0" ] || fail "gate commit never pushed"; no_merge "gate commit"
setup; ship --gate 'echo x >>feature.txt'; expect 1 "gate that dirties"; no_merge "gate dirty"
setup; ship --gate 'test "$PWD" = "$(cd "'"$WT"'" && pwd -P)"; test -f feature.txt'
expect 0 "gate runs in the worktree"

# ===== exit 1 and 124: push and CI
setup; echo '[{"bucket":"fail","name":"ci"},{"bucket":"pass","name":"lint"}]' >"$ST/checks"
ship; expect 1 "failing CI"; untouched "failing CI, no rebase, no push"
grep -q '^failing: ci$' <<<"$OUT" || fail "failing line printed: [$OUT]"
no_merge "failing CI"
[ -d "$WT" ] || fail "worktree kept after failing CI"

setup; echo DIRTY >"$ST/merge-state"
ship; expect 3 "conflict after the push"; no_merge "conflict after the push"
grep -q "PR conflicts with origin/main after the push; rebase again, then rerun" <<<"$ERR" || fail "conflict message: [$ERR]"
[ -d "$WT" ] || fail "worktree kept after a conflict"

setup; echo '[{"bucket":"pending","name":"ci"}]' >"$ST/checks"
ship --timeout 0; expect 124 "CI timeout"; no_merge "CI timeout"

setup; echo '[{"bucket":"pending","name":"ci"}]' >"$ST/checks"
ship --timeout 14; expect 124 "CI timeout after sleeps"
[ "$(cat "$ST/sleeps.txt")" = "7
7" ] || fail "timeout counts gh-ci sleeps: [$(cat "$ST/sleeps.txt")]"

setup; echo '[{"bucket":"pending","name":"ci"}]' >"$ST/checks"
export GH_CI_INTERVAL=3600
ship; expect 124 "default CI wait timeout is 7200"
grep -q "timeout after 7200s" <<<"$OUT" || fail "default timeout header: [$OUT]"
[ "$(cat "$ST/sleeps.txt")" = "3600
3600" ] || fail "default timeout sleeps twice with 3600: [$(cat "$ST/sleeps.txt" 2>/dev/null)]"
export GH_CI_INTERVAL=7

setup; advance_main other.txt o
checks_hook 'git --git-dir="$ORIGIN" rev-parse refs/heads/feature >"$ST/at-ci"'
ship; expect 0 "rebased happy path"
PIN="$(sed -n 's/.*--match-head-commit //p' "$ST/gh.log")"
[ "$(cat "$ST/at-ci")" = "$PIN" ] || fail "origin branch is the rebased head before the CI wait"
[ "$PIN" != "$HEAD0" ] || fail "the rebase moved HEAD"

setup; checks_hook 'git --git-dir="$ORIGIN" update-ref refs/heads/feature "$(git --git-dir="$ORIGIN" commit-tree "refs/heads/feature^{tree}" -p refs/heads/feature -m b)"'
ship; expect 1 "CI passes on a moved head"; no_merge "moved head"
grep -q 'other than' <<<"$ERR" || fail "moved head message: [$ERR]"

# main moving during the CI wait sends ship-pr back to the rebase, at most 3 times
setup; checks_hook "$BUMP_MAIN"
ship; expect 0 "main moves once during CI"
grep -q 'origin/main moved during CI; rebasing again (retry 1 of 3)' <<<"$ERR" || fail "retry message: [$ERR]"
PIN="$(sed -n 's/.*--match-head-commit //p' "$ST/gh.log")"
[ -n "$PIN" ] && git --git-dir="$ORIGIN" merge-base --is-ancestor refs/heads/main "$PIN" \
  || fail "merge pinned to a head that descends from the moved main: [$PIN]"
[ "$(grep -c 'check-runs' "$ST/gh.log")" -eq 2 ] || fail "two CI waits"

# the second push leases against the first pushed head, not the PR head read at the start
setup; advance_main other.txt o; checks_hook "$BUMP_MAIN"
ship; expect 0 "initial rebase, then main moves during CI"
grep -q 'retry 1 of 3' <<<"$ERR" || fail "retry after an initial rebase: [$ERR]"

setup; checks_each "$BUMP_MAIN"
ship; expect 1 "main moves on every CI wait"; no_merge "main moves every wait"
grep -q 'origin/main moved during CI after 3 retries; rerun ship-pr' <<<"$ERR" || fail "exhaustion message: [$ERR]"
for k in 1 2 3; do grep -q "retry $k of 3" <<<"$ERR" || fail "retry $k line: [$ERR]"; done
! grep -q 'retry 4' <<<"$ERR" || fail "no fourth retry: [$ERR]"
[ "$(grep -c 'check-runs' "$ST/gh.log")" -eq 4 ] || fail "exactly 4 CI waits"
[ -d "$WT" ] || fail "worktree kept when main keeps moving"

setup
echo changed >"$WT/file.txt"; git -C "$WT" commit -qam "touch file"; git -C "$WT" push -q origin feature
HEAD0="$(git -C "$WT" rev-parse HEAD)"
checks_hook 'echo conflicting >"$C/file.txt"; git -C "$C" commit -qam m; git -C "$C" push -q origin main'
ship; expect 3 "main moves during CI with a conflicting change"; no_merge "conflict on retry"
for d in rebase-merge rebase-apply; do
  [ ! -e "$(git -C "$WT" rev-parse --git-path $d)" ] || fail "retry conflict leaves no $d"
done
[ -z "$(git -C "$WT" status --porcelain)" ] || fail "retry conflict leaves a clean tree"

setup
sed -i.bak 1s/a/x/ "$WT/file.txt"; rm "$WT/file.txt.bak"
git -C "$WT" commit -qam "edit line 1"; git -C "$WT" push -q origin feature
HEAD0="$(git -C "$WT" rev-parse HEAD)"
checks_hook 'sed -i.bak 3s/c/z/ "$C/file.txt"; rm "$C/file.txt.bak"; git -C "$C" commit -qam m; git -C "$C" push -q origin main'
ship; expect 4 "main moves during CI with a clean rebase that changes the patch"; no_merge "patch-id on retry"

setup; checks_hook 'echo n >"$C/newfile.txt"; git -C "$C" add .; git -C "$C" commit -qm m; git -C "$C" push -q origin main'
ship --gate 'test ! -e newfile.txt && echo x >>"$ST/gates"'; expect 0 "gate runs once, not again after a rebase"
[ "$(wc -l <"$ST/gates")" -eq 1 ] || fail "gate ran exactly once"
[ "$(grep -c 'check-runs' "$ST/gh.log")" -eq 2 ] || fail "2 CI waits"
mh="$(grep -o 'match-head-commit [0-9a-f]*' "$ST/gh.log" | awk '{print $2}')"
git --git-dir="$ORIGIN" merge-base --is-ancestor main "$mh" || fail "merge pinned to a head descending from the moved main"

# ===== strictness of main's required checks decides when ship-pr rebases
STRICT_LINE='required checks on main are strict: rebasing when origin/main moves'
LOOSE_LINE='required checks on main are not strict: rebasing only on a conflict'
NOSTRICT='[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"ci"}]}}]'
FALLBACK_LINE='cannot read whether required checks on main are strict; assuming strict'

setup; ship; expect 0 "default reads strict"
grep -q "$STRICT_LINE" <<<"$ERR" || fail "strict mode line: [$ERR]"
setup; echo "$NOSTRICT" >"$ST/rules"; ship; expect 0 "rules not strict"
grep -q "$LOOSE_LINE" <<<"$ERR" || fail "not strict mode line: [$ERR]"
setup; echo '[]' >"$ST/rules"; ship; expect 0 "no rules"
grep -q "$LOOSE_LINE" <<<"$ERR" || fail "no rules is not strict: [$ERR]"
setup; echo '[{"type":"required_status_checks","parameters":{}},{"type":"deletion"}]' >"$ST/rules"; ship; expect 0 "rule without the strict field"
grep -q "$LOOSE_LINE" <<<"$ERR" || fail "missing strict field is not strict: [$ERR]"
setup; echo "$NOSTRICT" >"$ST/rules"; echo '{"strict":true}' >"$ST/classic"; ship; expect 0 "classic strict"
grep -q "$STRICT_LINE" <<<"$ERR" || fail "classic strict wins: [$ERR]"
setup; echo "$NOSTRICT" >"$ST/rules"; echo '{"strict":false}' >"$ST/classic"; ship; expect 0 "classic not strict"
grep -q "$LOOSE_LINE" <<<"$ERR" || fail "classic false is not strict: [$ERR]"
setup; touch "$ST/api-fail"; ship; expect 0 "lookup fails"
grep -q "$FALLBACK_LINE" <<<"$ERR" && grep -q "$STRICT_LINE" <<<"$ERR" || fail "lookup failure falls back to strict: [$ERR]"
setup; echo "$NOSTRICT" >"$ST/rules"; touch "$ST/classic-fail"; ship; expect 0 "classic lookup fails"
grep -q "$FALLBACK_LINE" <<<"$ERR" && grep -q "$STRICT_LINE" <<<"$ERR" || fail "classic failure falls back to strict: [$ERR]"

# not strict: no rebase because main moved
setup; echo "$NOSTRICT" >"$ST/rules"; advance_main other.txt o
ship; expect 0 "not strict, main moved before ship"
grep -q 'rebasing feature' <<<"$ERR" && fail "no rebase: [$ERR]"
! grep -q 'pushing rebased' <<<"$ERR" || fail "no push: [$ERR]"
grep -q "^gh pr merge 7 --repo O/N --squash --match-head-commit $HEAD0\$" "$ST/gh.log" || fail "merge pinned to HEAD0"
[ "$(grep -c 'check-runs' "$ST/gh.log")" -eq 1 ] || fail "one CI wait"

setup; echo "$NOSTRICT" >"$ST/rules"; checks_hook "$BUMP_MAIN"
ship; expect 0 "not strict, main moves during CI"
grep -q 'retry' <<<"$ERR" && fail "no retry: [$ERR]"
grep -q "^gh pr merge 7 --repo O/N --squash --match-head-commit $HEAD0\$" "$ST/gh.log" || fail "merge pinned to HEAD0 after a main move"
[ "$(grep -c 'check-runs' "$ST/gh.log")" -eq 1 ] || fail "one CI wait despite the main move"

# not strict: a reported conflict rebases, before the first push
setup; echo "$NOSTRICT" >"$ST/rules"; echo CONFLICTING >"$ST/mergeable"; advance_main other.txt o
ship --gate 'test ! -e other.txt && echo x >>"$ST/gates"'; expect 0 "not strict, conflict that rebases cleanly"
[ "$(wc -l <"$ST/gates")" -eq 1 ] || fail "gate ran once, on the pre-rebase head"
mh="$(grep -o 'match-head-commit [0-9a-f]*' "$ST/gh.log" | awk '{print $2}')"
[ "$mh" != "$HEAD0" ] && git --git-dir="$ORIGIN" merge-base --is-ancestor main "$mh" || fail "merge pinned to the rebased head"
[ "$(grep -c 'check-runs' "$ST/gh.log")" -eq 1 ] || fail "one CI wait after the rebase"

setup; echo "$NOSTRICT" >"$ST/rules"; echo CONFLICTING >"$ST/mergeable"; advance_main other.txt o
run 7 --repo O/N --reviewed "$(git -C "$C" rev-parse HEAD)" --worktree "$WT"; expect 4 "not strict, rebase checks the patch-id"
no_merge "not strict patch-id"; [ "$(origin_head)" = "$HEAD0" ] || fail "mismatch pushes nothing"

setup; echo "$NOSTRICT" >"$ST/rules"; echo DIRTY >"$ST/merge-state"; advance_main other.txt o
ship; expect 3 "not strict, DIRTY after the rebase and push"; no_merge "not strict DIRTY"
grep -q "PR conflicts with origin/main after the push; rebase again, then rerun" <<<"$ERR" || fail "DIRTY message: [$ERR]"
[ "$(origin_head)" != "$HEAD0" ] || fail "DIRTY probe rebased and pushed"

setup; echo "$NOSTRICT" >"$ST/rules"; echo UNKNOWN >"$ST/mergeable"; echo UNKNOWN >"$ST/merge-state"; advance_main other.txt o
ship; expect 0 "not strict, UNKNOWN mergeable"
! grep -q "rebasing feature" <<<"$ERR" || fail "UNKNOWN does not rebase: [$ERR]"

setup; echo "$NOSTRICT" >"$ST/rules"; echo CONFLICTING >"$ST/mergeable"
echo changed >"$WT/file.txt"; git -C "$WT" commit -qam "touch file"; git -C "$WT" push -q origin feature
HEAD0="$(git -C "$WT" rev-parse HEAD)"
advance_main file.txt conflicting
ship; expect 3 "not strict, truly conflicting"; untouched "not strict conflict"; no_merge "not strict conflict"
for d in rebase-merge rebase-apply; do
  [ ! -e "$(git -C "$WT" rev-parse --git-path $d)" ] || fail "not strict conflict leaves no $d"
done
[ -z "$(git -C "$WT" status --porcelain)" ] || fail "not strict conflict leaves a clean tree"

# the conflicting commit lands during the gate: the probe's rebase refetches main first
setup; echo "$NOSTRICT" >"$ST/rules"; echo CONFLICTING >"$ST/mergeable"
echo changed >"$WT/file.txt"; git -C "$WT" commit -qam "touch file"; git -C "$WT" push -q origin feature
HEAD0="$(git -C "$WT" rev-parse HEAD)"
ship --gate 'echo conflicting >"$C/file.txt"; git -C "$C" commit -qam m; git -C "$C" push -q origin main'
expect 3 "not strict, conflicting commit lands during the gate"; untouched "conflict during the gate"; no_merge "conflict during the gate"

# ===== #214: on a non-strict base with --gate, gate the PR merged with current origin/main
# main moved by an unrelated commit, gate passes on the merged tree: merge pinned to the PR head
setup; echo "$NOSTRICT" >"$ST/rules"; advance_main other.txt o
MAIN1="$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)"
ship --gate 'echo "$(git rev-parse HEAD)" >>"$ST/gate-heads"'
expect 0 "not strict guard passes on the merged tree"
[ "$(wc -l <"$ST/gate-heads")" -eq 2 ] || fail "guard runs the gate a second time on the merged tree"
[ "$(sed -n 1p "$ST/gate-heads")" = "$HEAD0" ] || fail "first gate runs on the pinned head"
[ "$(sed -n 2p "$ST/gate-heads")" != "$HEAD0" ] || fail "second gate runs on the merged tree"
git -C "$C" merge-base --is-ancestor "$MAIN1" "$(sed -n 2p "$ST/gate-heads")" \
  || fail "second gate runs on a tree merged with current origin/main"
grep -q "gate passes on the PR merged with current origin/main" <<<"$ERR" || fail "guard pass message: [$ERR]"
grep -q "^gh pr merge 7 --repo O/N --squash --match-head-commit $HEAD0\$" "$ST/gh.log" || fail "guard passes: merge pinned to the PR head"
[ ! -e "$WT" ] || fail "guard passes: worktree removed"
origin_head >/dev/null && fail "guard passes: no local merge commit leaks to origin"

# gate fails only on the merged tree: exit 1, no merge, worktree back on the pinned head and clean
setup; echo "$NOSTRICT" >"$ST/rules"; advance_main bad x
ship --gate 'echo gate-merged-line; test ! -e bad'
expect 1 "not strict guard fails on the merged tree"; no_merge "guard gate fails"
grep -q gate-merged-line <<<"$OUT" || fail "guard gate tail printed: [$OUT]"
grep -q "the PR merged with current origin/main fails the gate" <<<"$ERR" || fail "guard gate message: [$ERR]"
[ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD0" ] || fail "guard gate fails: worktree back on the pinned head"
[ -z "$(git -C "$WT" status --porcelain)" ] || fail "guard gate fails: worktree clean"
[ -d "$WT" ] || fail "worktree kept when the guard gate fails"

# SIGTERM during the merged-tree gate restores the pinned head and exits 143
setup; echo "$NOSTRICT" >"$ST/rules"; advance_main other.txt o
O0="$(origin_head)"
bash "$SHIP" 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT" \
  --gate 'if [ -e other.txt ]; then /bin/sleep 30 & echo $! >"$ST/gate-sleep.pid"; wait $!; fi' >"$S/kill-out.txt" 2>"$S/kill-err.txt" &
kill_pid=$!
for i in $(seq 1 100); do
  [ "$(git -C "$WT" rev-parse HEAD)" != "$HEAD0" ] && [ -e "$ST/gate-sleep.pid" ] && break
  /bin/sleep 0.1
done
[ "$(git -C "$WT" rev-parse HEAD)" != "$HEAD0" ] && [ -e "$ST/gate-sleep.pid" ] || fail "SIGTERM test: merged-tree gate started"
gate_sleep="$(cat "$ST/gate-sleep.pid")"
[ -n "$gate_sleep" ] || fail "SIGTERM test: gate sleep pid recorded"
kill -TERM "$kill_pid"
kill -TERM "$gate_sleep" 2>/dev/null || true
wait "$kill_pid"; kill_code=$?
[ "$kill_code" = 143 ] || fail "SIGTERM test: exit 143 (got $kill_code)"
[ "$(origin_head)" = "$O0" ] || fail "SIGTERM test: origin branch unchanged"
[ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD0" ] || fail "SIGTERM test: worktree back on the pinned head"
[ -z "$(git -C "$WT" status --porcelain)" ] || fail "SIGTERM test: worktree clean"
[ ! -e "$(git -C "$WT" rev-parse --git-path MERGE_HEAD)" ] || fail "SIGTERM test: no merge in progress"
! grep -q '^gh pr merge' "$ST/gh.log" || fail "SIGTERM test: no merge call"
[ -d "$WT" ] || fail "worktree kept after SIGTERM"
kill "$gate_sleep" 2>/dev/null || true

# a conflicting main move: exit 3, worktree clean on the pinned head
setup; echo "$NOSTRICT" >"$ST/rules"
echo changed >"$WT/file.txt"; git -C "$WT" commit -qam "touch file"; git -C "$WT" push -q origin feature
HEAD0="$(git -C "$WT" rev-parse HEAD)"
advance_main file.txt conflicting
ship --gate true
expect 3 "not strict guard conflicts"; no_merge "guard conflict"
grep -q "PR conflicts with current origin/main; rebase, then rerun" <<<"$ERR" || fail "guard conflict message: [$ERR]"
[ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD0" ] || fail "guard conflict: worktree back on the pinned head"
[ -z "$(git -C "$WT" status --porcelain)" ] || fail "guard conflict: worktree clean"
[ ! -e "$(git -C "$WT" rev-parse --git-path MERGE_HEAD)" ] || fail "guard conflict: no merge in progress"

# main has not moved: the guard does not run the gate a second time
setup; echo "$NOSTRICT" >"$ST/rules"
ship --gate 'echo x >>"$ST/gates"'
expect 0 "not strict, main unmoved"
[ "$(wc -l <"$ST/gates")" -eq 1 ] || fail "unmoved main: gate runs once"

# strict mode: the guard never runs, even when main moves during CI
setup; checks_hook 'echo n >"$C/newfile.txt"; git -C "$C" add .; git -C "$C" commit -qm m; git -C "$C" push -q origin main'
ship --gate 'test ! -e newfile.txt && echo x >>"$ST/gates"'
expect 0 "strict, main moves during CI"
[ "$(wc -l <"$ST/gates")" -eq 1 ] || fail "strict: gate runs once"

# ===== exit 5: stray closing keywords
setup; echo 'Resolves #97. also fixes #9' >"$ST/body"
ship; expect 5 "stray closing keyword"; no_merge "pr-closes"
grep -q '^#9 body: fixes #9$' <<<"$OUT" || fail "stray line printed: [$OUT]"
[ -d "$WT" ] || fail "worktree kept on exit 5"

# ===== --body-has: required PR body lines, checked before any rebase, push or CI call
setup
for args in "--body-has" "--body-has ''" ; do
  # shellcheck disable=SC2086
  eval "ship $args"; expect 2 "usage [$args]"; untouched "usage [$args]"
  grep -q '^usage: ship-pr' <<<"$ERR" || fail "usage text for [$args]: [$ERR]"
done
ship --body-has "$(printf 'a\nb')"; expect 2 "newline prefix"; untouched "newline prefix"
grep -q '^usage: ship-pr' <<<"$ERR" || fail "usage text for newline prefix: [$ERR]"
[ ! -e "$ST/gh.log" ] || fail "bad --body-has makes no gh call"

printf 'Resolves #97\nDoc friction: none\n' >"$ST/body"
ship --body-has 'Resolves #' --body-has 'Doc friction:'; expect 0 "body has every line"

# nothing_ran <name>: exit 5 left origin and worktree alone, made no CI call, kept the worktree.
nothing_ran() {
  expect 5 "$1"; untouched "$1"; no_merge "$1"
  ! grep -q 'check-runs' "$ST/gh.log" || fail "$1: no CI call"
  [ -d "$WT" ] || fail "$1: worktree kept"
}
setup; advance_main other.txt o; printf 'Resolves #97\n' >"$ST/body"
ship --body-has 'Resolves #' --body-has 'Doc friction:'; nothing_ran "one line missing"
[ "$OUT" = "missing body line: Doc friction:" ] || fail "one missing line printed: [$OUT]"
grep -q 'PR body lacks required lines; edit the PR body, then rerun' <<<"$ERR" || fail "miss message: [$ERR]"

setup; printf 'x\n' >"$ST/body"
ship --body-has 'Resolves #' --body-has 'Doc friction:'; nothing_ran "two lines missing"
[ "$OUT" = "missing body line: Resolves #
missing body line: Doc friction:" ] || fail "both missing lines printed: [$OUT]"

for b in '  Doc friction: x' 'doc friction: x' 'see Doc friction: x'; do
  setup; printf '%s\n' "$b" >"$ST/body"
  ship --body-has 'Doc friction:'; nothing_ran "no match for [$b]"
done
setup; printf 'Resolves #97\nab\n' >"$ST/body"
ship --body-has 'Resolves #[0-9]*' --body-has 'a.b' --body-has '*'; nothing_ran "glob and regex are literal"
[ "$(wc -l <<<"$OUT")" -eq 3 ] || fail "all three literal prefixes missing: [$OUT]"
setup; printf 'Resolves #[0-9]*: x\na.b\n* item\n' >"$ST/body"
ship --body-has 'Resolves #[0-9]*' --body-has 'a.b' --body-has '*'; expect 0 "literal glob and regex prefixes match"

setup; printf 'Resolves #97\r\nDoc friction: none\r\n' >"$ST/body"
ship --body-has 'Resolves #97' --body-has 'Doc friction: none'; expect 0 "CRLF body"
setup; printf 'Resolves #97\nDoc friction: none' >"$ST/body"
ship --body-has 'Doc friction: none'; expect 0 "no trailing newline"

setup; touch "$ST/body-fail"
ship --body-has 'Resolves #'; expect 2 "body read failure"; untouched "body read failure"
grep -q 'cannot read PR 7 body' <<<"$ERR" || fail "body read message: [$ERR]"
setup; touch "$ST/body-null"
ship --body-has null; nothing_ran "null body"
setup; : >"$ST/body"
ship --body-has x; nothing_ran "empty body"

setup; ship; expect 0 "no --body-has"
! grep -q -- '--json body' "$ST/gh.log" || fail "no --body-has: no body read before pr-closes"

# ===== merge and cleanup
setup; echo true >"$ST/draft"
cd "$WT" || fail "cd worktree"
run 7 --repo O/N --reviewed "$HEAD0" --worktree .
cd "$T" || fail "cd out"
expect 0 "draft happy path"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "merged line: [$OUT]"
grep -q "^gh pr merge 7 --repo O/N --squash --match-head-commit $HEAD0\$" "$ST/gh.log" || fail "merge call: [$(grep merge "$ST/gh.log")]"
[ "$(grep -n '^gh pr ready 7 --repo O/N' "$ST/gh.log" | cut -d: -f1)" -lt "$(grep -n -m1 'check-runs' "$ST/gh.log" | cut -d: -f1)" ] \
  || fail "ready runs before the first CI wait"
[ "$(grep -c '^gh pr ready' "$ST/gh.log")" -eq 1 ] || fail "ready runs once"
[ ! -e "$WT" ] || fail "worktree removed"
git -C "$C" rev-parse --verify -q refs/heads/feature >/dev/null && fail "local branch deleted"
origin_head >/dev/null && fail "origin branch deleted"

setup; ship; expect 0 "non-draft happy path"
! grep -q '^gh pr ready' "$ST/gh.log" || fail "non-draft never marked ready"
grep -q "check-runs?per_page=100&filter=latest" "$ST/gh.log" || fail "non-draft: CI read over REST check runs"
! grep -q startedAt "$ST/gh.log" || fail "non-draft: startedAt is never requested"
[ ! -e "$WT" ] || fail "non-draft: worktree removed"

setup; touch "$ST/merge-deletes-branch"; ship; expect 0 "remote branch already deleted"
grep -q 'cleanup:' <<<"$ERR" && fail "a missing remote ref counts as done: [$ERR]"

setup; touch "$ST/merge-deletes-branch" "$ST/delete-fails"; ship; expect 0 "auto-deleted remote, push error"
grep -q 'cleanup:' <<<"$ERR" && fail "a missing remote ref counts as done, whatever the push says: [$ERR]"

setup; touch "$ST/delete-fails"; ship; expect 0 "remote delete fails, branch still there"
grep -q 'cleanup: push origin --delete feature failed' <<<"$ERR" || fail "a remote branch still there is reported: [$ERR]"

setup; touch "$ST/no-merge"; ship; expect 1 "never MERGED"
[ -d "$WT" ] || fail "worktree kept when never MERGED"
[ "$(origin_head)" = "$HEAD0" ] || fail "origin branch kept when never MERGED"
[ "$(wc -l <"$ST/sleeps.txt")" -eq 11 ] || fail "11 sleeps across 12 polls: [$(cat "$ST/sleeps.txt")]"

setup; touch "$ST/merge-fail"; ship; expect 1 "merge refused"
[ -d "$WT" ] || fail "worktree kept when the merge is refused"

# ===== merge race: 'Base branch was modified' retries once after 5 s
setup; printf 'Base branch was modified. Review and try the merge again.' >"$ST/merge-fail-once"
ship; expect 0 "merge race retries once"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "merged line after retry: [$OUT]"
[ "$(grep -c '^gh pr merge' "$ST/gh.log")" -eq 2 ] || fail "merge called twice on a race"
grep -q 'retrying once' <<<"$ERR" || fail "retry message: [$ERR]"
grep -q '^5$' "$ST/sleeps.txt" || fail "retry sleeps 5 s: [$(cat "$ST/sleeps.txt" 2>/dev/null)]"
[ ! -e "$WT" ] || fail "worktree removed after a retried merge"

setup; printf 'Base branch was modified. Review and try the merge again.' >"$ST/merge-fail-msg"
ship; expect 1 "race on both attempts still dies 1"
[ "$(grep -c '^gh pr merge' "$ST/gh.log")" -eq 2 ] || fail "exactly one retry on a race"
grep -q 'Base branch was modified' <<<"$ERR" || fail "gh error printed on the second failure: [$ERR]"
[ -d "$WT" ] || fail "worktree kept when the retry fails"

setup; printf 'Pull request cannot be merged: review required.' >"$ST/merge-fail-msg"
ship; expect 1 "other merge errors never retry"
[ "$(grep -c '^gh pr merge' "$ST/gh.log")" -eq 1 ] || fail "no retry on another error"
! grep -q 'retrying once' <<<"$ERR" || fail "no retry message on another error: [$ERR]"
grep -q 'review required' <<<"$ERR" || fail "gh error printed: [$ERR]"
[ -d "$WT" ] || fail "worktree kept when the merge is refused"

# ===== draft PRs: marked ready once before the CI wait; a required check green
# ===== on the head counts whenever it ran; an absent required check is pending
RULES_CI='[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"ci"}]}}]'

setup; echo true >"$ST/draft"; echo "$RULES_CI" >"$ST/rules"
ship; expect 0 "draft whose head already has a green required check"
[ "$(grep -c 'check-runs' "$ST/gh.log")" -eq 1 ] || fail "green required check before ready satisfies the wait at once"
[ "$(grep -c '^gh pr ready' "$ST/gh.log")" -eq 1 ] || fail "draft marked ready once"
[ "$(grep -n '^gh pr ready' "$ST/gh.log" | cut -d: -f1)" -lt "$(grep -n -m1 'check-runs' "$ST/gh.log" | cut -d: -f1)" ] \
  || fail "ready before the first checks call"
! grep -q '/events' "$ST/gh.log" || fail "ship-pr never reads the PR's events"
! grep -q startedAt "$ST/gh.log" || fail "draft: startedAt is never requested"

setup; echo true >"$ST/draft"; echo "$RULES_CI" >"$ST/rules"
echo '[{"bucket":"pass","name":"ci (draft)"}]' >"$ST/checks"
ship --timeout 14; expect 124 "draft run under another name never satisfies the required check"
grep -q '^pending: ci$' <<<"$OUT" || fail "absent required check named: [$OUT]"
! grep -q '^gh pr merge' "$ST/gh.log" || fail "absent required check: no merge"

setup; echo true >"$ST/draft"; touch "$ST/ready-fail"
ship; expect 1 "gh pr ready fails"; ! grep -q '^gh pr \(checks\|merge\)' "$ST/gh.log" || fail "no CI wait or merge after ready fails"
[ -d "$WT" ] || fail "worktree kept when ready fails"

# ===== --unverified-fixes: a fix round with no real bug ships without a re-review
F="$T/findings.txt"; printf 'P2: missing test for x\n' >"$F"
BLANK="$T/blank.txt"; printf '\n  \t\n' >"$BLANK"
no_gh() { [ ! -s "$ST/gh.log" ] || fail "$1: no gh call before the usage check: [$(cat "$ST/gh.log")]"; }
comment_count() { grep -c '^gh pr comment' "$ST/gh.log" 2>/dev/null || true; }

# 1. a mismatch with the option: no exit 4, one comment, then a normal merge
setup
echo changed >"$WT/feature.txt"; git -C "$WT" commit -qam "fix nit"; git -C "$WT" push -q origin feature
SHORT="$(git -C "$WT" rev-parse --short "$HEAD0")"
run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT" --unverified-fixes "$F"
expect 0 "mismatch with --unverified-fixes merges"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "merged line after unverified fixes: [$OUT]"
[ "$(comment_count)" -eq 1 ] || fail "one comment: [$(cat "$ST/gh.log")]"
[ "$(head -n 1 "$ST/comment.txt")" = "Fixes since $SHORT shipped without re-review (review-loop step 2: no real bug in round one)." ] \
  || fail "comment first line: [$(head -n 1 "$ST/comment.txt")]"
grep -qx 'Findings:' "$ST/comment.txt" && grep -q 'P2: missing test for x' "$ST/comment.txt" || fail "comment holds the findings: [$(cat "$ST/comment.txt")]"
grep -qx 'Changed since review:' "$ST/comment.txt" && grep -q 'feature.txt' "$ST/comment.txt" || fail "comment holds the stat: [$(cat "$ST/comment.txt")]"
grep -q '^gh pr merge' "$ST/gh.log" || fail "unverified fixes: merged"
[ ! -e "$WT" ] || fail "unverified fixes: worktree removed"

# 2. a mismatch without the option: exit 4, as before
setup
echo changed >"$WT/feature.txt"; git -C "$WT" commit -qam "fix nit"; git -C "$WT" push -q origin feature
ship; expect 4 "mismatch without --unverified-fixes exits 4"; no_merge "mismatch without the option"
[ "$(comment_count)" -eq 0 ] || fail "no comment without the option"

# 3. a missing file, and an all-blank file: exit 2 before any gh call
setup; run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT" --unverified-fixes "$T/missing.txt"
expect 2 "missing findings file"; untouched "missing findings file"; no_gh "missing findings file"
setup; run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT" --unverified-fixes "$BLANK"
expect 2 "all-blank findings file"; untouched "all-blank findings file"; no_gh "all-blank findings file"
setup; run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT" --unverified-fixes ""
expect 2 "empty findings path"; no_gh "empty findings path"

# 4. a match with the option: no comment
setup; ship --unverified-fixes "$F"; expect 0 "match with --unverified-fixes merges"
[ "$(comment_count)" -eq 0 ] || fail "match: no comment posted"

# 5. a failed comment post: exit 1 and nothing pushed. The rebase moves the local
# head, so only the origin branch is checked.
setup
echo changed >"$WT/feature.txt"; git -C "$WT" commit -qam "fix nit"; git -C "$WT" push -q origin feature
advance_main other.txt o; touch "$ST/comment-fail"
O0="$(origin_head)"
run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT" --unverified-fixes "$F"
expect 1 "failed comment post"; [ "$(origin_head)" = "$O0" ] || fail "failed comment post: nothing pushed"
no_merge "failed comment post"; [ -d "$WT" ] || fail "failed comment post: worktree kept"

# 6. one comment per run: main moves during CI and the retried patch still differs
setup
echo changed >"$WT/feature.txt"; git -C "$WT" commit -qam "fix nit"; git -C "$WT" push -q origin feature
checks_hook "$BUMP_MAIN"
ship --unverified-fixes "$F"; expect 0 "retry with --unverified-fixes merges"
grep -q 'retry 1 of 3' <<<"$ERR" || fail "retry happened: [$ERR]"
[ "$(comment_count)" -eq 1 ] || fail "one comment per run: [$(comment_count)]"

echo "ship-pr: all cases passed"

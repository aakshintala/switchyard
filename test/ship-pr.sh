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
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"
trap 'rm -rf "$T"' EXIT

# The gate refuses when df reports under 20 GB free, so the suite shadows df
# with a stub reporting ample space and never depends on the host's real disk.
fake_df() {
  mkdir -p "$1"
  printf '%s\n' '#!/bin/sh' \
    "printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/fake 1000000 950000 $2 95%% $3\\n'" \
    >"$1/df"
  chmod 755 "$1/df"
}
export HOME="$T/home"; mkdir -p "$HOME"
fake_df "$T/bin" 104857600 /fake-ample
BASE_PATH="$T/bin:$PATH"; export PATH="$BASE_PATH"
[ "$(command -v df)" = "$T/bin/df" ] || fail "df resolves to the suite's stub, not the host's"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GH_CI_INTERVAL=7 SHIP_PR_INTERVAL=1
# CLAUDECODE must not change gh-ci wait timeouts under test (ship-pr passes
# --timeout 0 and 14 in cases below), so start unset however the suite is invoked.
unset CLAUDECODE
MERGE_SHA="1f2e3d4c5b6a79881726354433221100ffeeddcc"

# --- fake gh. Reads $ST (state dir) and $ORIGIN. The PR head is origin's
# --- feature branch, so a push is visible to gh-ci. --jq runs through jq.
gh() (
  set -euo pipefail
  echo "gh $*" >>"$ST/gh.log"
  rd() { [ -e "$ST/$1" ] && cat "$ST/$1" || echo "$2"; }
  if [ "$1" = "api" ]; then
    shift
    paginate=0
    if [ "$1" = "--paginate" ]; then paginate=1; shift; fi
    path="$1"; shift
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
      */labels\?per_page=100)
        [ ! -e "$ST/label-list-fail" ] || { echo "gh: forbidden (HTTP 403)" >&2; exit 1; }
        json="$(rd labels '[]')"
        [ "$paginate" = 1 ] || json="$(jq -c '.[0:100]' <<<"$json")";;
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
  [ "$1" = "pr" ] || [ "$1" = "run" ] || { echo "fake gh: only pr, run and api supported" >&2; exit 2; }
  if [ "$1" = "run" ]; then
    shift
    sub="$1"; shift
    case "$sub" in
      list)
        if [ -e "$ST/run-list.json" ]; then cat "$ST/run-list.json"; else echo '[]'; fi;;
      view)
        rid="$1"; shift
        jqex=""; json_fields=""; job=""; want_log=""; want_failed_log=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --jq) jqex="$2"; shift 2;;
            --json) json_fields="$2"; shift 2;;
            --job) job="$2"; shift 2;;
            --log) want_log=1; shift;;
            --log-failed) want_failed_log=1; shift;;
            --repo|--commit|--limit|--branch|--workflow) shift; [ $# -gt 0 ] && shift;;
            *) shift;;
          esac
        done
        if [ -n "$want_failed_log" ]; then
          [ -e "$ST/log-$rid-$job.log" ] && cat "$ST/log-$rid-$job.log" || true
        elif [ -n "$want_log" ]; then
          [ -e "$ST/log-$rid.log" ] && cat "$ST/log-$rid.log" || true
        else
          case "$json_fields" in
            *attempt*)
              # a requested rerun's new attempt appears after attempt-delay polls
              if [ -e "$ST/rerun-requested-$rid" ] && [ -e "$ST/attempt-delay-$rid" ]; then
                n="$(cat "$ST/attempt-delay-$rid")"
                case "$n" in ''|*[!0-9]*) n=1 ;; esac
                if [ "$n" -le 1 ]; then
                  rm -f "$ST/attempt-delay-$rid" "$ST/rerun-requested-$rid"
                  a="$(cat "$ST/attempt-$rid.txt" 2>/dev/null || echo 1)"
                  case "$a" in ''|*[!0-9]*) a=1 ;; esac
                  echo "$((a + 1))" >"$ST/attempt-$rid.txt"
                  echo completed >"$ST/status-$rid.txt"
                  [ ! -e "$ST/rerun-keeps-failing" ] && echo '[{"bucket":"pass","name":"ci"}]' >"$ST/checks" || true
                else
                  echo "$((n - 1))" >"$ST/attempt-delay-$rid"
                fi
              fi
              a="$(cat "$ST/attempt-$rid.txt" 2>/dev/null || echo 1)"
              s="$(cat "$ST/status-$rid.txt" 2>/dev/null || echo completed)"
              json="$(jq -nc --argjson a "$a" --arg s "$s" '{attempt: $a, status: $s}')";;
            *jobs*)
              if [ -e "$ST/jobs-$rid.json" ]; then
                json="$(jq -c '{jobs: .}' "$ST/jobs-$rid.json")"
              else
                json='{"jobs":[]}'
              fi;;
            *name*)
              json="$(jq -nc --arg r "$rid" '{name: ("run-" + $r)}')";;
            *headSha*)
              h="$(git --git-dir="$ORIGIN" rev-parse refs/heads/feature 2>/dev/null || cat "$ST/lasthead")"
              json="$(jq -nc --arg h "$h" '{headSha: $h}')";;
            *status*)
              json='{"status":"completed"}';;
            *) json='{}';;
          esac
          if [ -n "$jqex" ]; then jq -r "$jqex" <<<"$json"; else echo "$json"; fi
        fi;;
      rerun)
        rid="$1"
        if [ -e "$ST/rerun-fail" ]; then
          if grep -qxF "$rid" "$ST/rerun-fail" 2>/dev/null || grep -qx 'all' "$ST/rerun-fail" 2>/dev/null; then
            echo "gh: rerun of $rid failed" >&2
            exit 1
          fi
        fi
        touch "$ST/rerun-requested-$rid"
        if [ ! -e "$ST/attempt-delay-$rid" ]; then
          rm -f "$ST/rerun-requested-$rid"
          a="$(cat "$ST/attempt-$rid.txt" 2>/dev/null || echo 1)"
          case "$a" in ''|*[!0-9]*) a=1 ;; esac
          echo "$((a + 1))" >"$ST/attempt-$rid.txt"
          echo completed >"$ST/status-$rid.txt"
          [ ! -e "$ST/rerun-keeps-failing" ] && echo '[{"bucket":"pass","name":"ci"}]' >"$ST/checks" || true
        fi;;
      *) echo "fake gh: unknown run $sub" >&2; exit 2;;
    esac
    exit 0
  fi
  shift
  sub="$1"; shift
  case "$sub" in
    view)
      [ ! -e "$ST/view-fail" ] || exit 1
      case " $* " in *" --json body "*) [ ! -e "$ST/body-fail" ] || exit 1;; esac
      case " $* " in *" --json labels "*) [ ! -e "$ST/pr-labels-fail" ] || exit 1;; esac
      if h="$(git --git-dir="$ORIGIN" rev-parse refs/heads/feature 2>/dev/null)"; then
        echo "$h" >"$ST/lasthead"
      else
        h="$(cat "$ST/lasthead")"
      fi
      if [ -e "$ST/head-first-stale" ]; then
        h="$(cat "$ST/head-first-stale")"
        rm -f "$ST/head-first-stale"
      fi
      state="$(rd state OPEN)"
      json="$(jq -nc --arg h "$h" --arg s "$state" --arg d "$(rd draft false)" --arg ms "$(rd merge-state CLEAN)" --arg mg "$(rd mergeable MERGEABLE)" --arg b "$(rd body 'Resolves #97')" \
        --argjson bn "$([ -e "$ST/body-null" ] && echo true || echo false)" --argjson c "$(rd commits '[]')" --arg m "$MERGE_SHA" \
        --argjson l "$(rd pr-labels '[]')" \
        '{state:$s, headRefName:"feature", baseRefName:"main", headRefOid:$h, isDraft:($d=="true"), mergeStateStatus:$ms, mergeable:$mg,
          title:"t", body:(if $bn then null else $b end), commits:$c, labels:$l, mergeCommit:(if $s=="MERGED" then {oid:$m} else null end)}')"
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
        [ ! -e "$ST/merge-fails-but-merges" ] || echo MERGED >"$ST/state"
        exit 1
      fi
      if [ -e "$ST/merge-fail-msg" ]; then cat "$ST/merge-fail-msg" >&2; [ ! -e "$ST/merge-fails-but-merges" ] || echo MERGED >"$ST/state"; exit 1; fi
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
      if [[ " $* " == *" fetch "* ]]; then
        echo "fetch $*" >>"$ST/fetch.log"
        if [ -e "$ST/fetch-always-fail" ]; then
          echo "error: cannot lock ref 'refs/remotes/origin/feature'" >&2
          exit 1
        fi
        if [ -e "$ST/fetch-fail-once" ]; then
          rm -f "$ST/fetch-fail-once"
          echo "error: some local refs could not be updated" >&2
          exit 1
        fi
      fi
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
GATE_PANIC='echo gate-start; echo "thread prune::young_fork panicked at src/prune.rs:42:5:"; echo "assertion left == right failed"; echo "  left: 1"; echo " right: 2"; for i in $(seq 1 25); do echo "gate-tail-$i"; done; exit 1'
assert_gate_panic_failure() {
  local label="$1" gate_file
  grep -q 'panicked at' <<<"$OUT" || fail "$label: panic line printed: [$OUT]"
  grep -q 'assertion .*left == right.* failed' <<<"$OUT" || fail "$label: assertion printed: [$OUT]"
  grep -q '^  left: 1$' <<<"$OUT" || fail "$label: left value printed: [$OUT]"
  grep -q '^ right: 2$' <<<"$OUT" || fail "$label: right value printed: [$OUT]"
  grep -q '^gate-tail-6$' <<<"$OUT" || fail "$label: last 20 lines printed: [$OUT]"
  grep -q '^gate-tail-5$' <<<"$OUT" && fail "$label: output before the last 20 lines omitted: [$OUT]"
  gate_file="$(sed -n 's/^full gate output: //p' <<<"$OUT")"
  case "$gate_file" in "$TMPDIR"/ship-pr-7-gate.*) ;; *) fail "$label: named log path printed: [$gate_file]" ;; esac
  [ -f "$gate_file" ] || fail "$label: full output file exists: [$gate_file]"
  [ "$(wc -l <"$gate_file" | tr -d ' ')" = 30 ] || fail "$label: file holds all 30 output lines: [$(wc -l <"$gate_file")]"
  grep -qx 'gate-start' "$gate_file" || fail "$label: file holds the first line"
  grep -q 'panicked at' "$gate_file" || fail "$label: file holds the panic"
  for i in $(seq 1 25); do grep -qx "gate-tail-$i" "$gate_file" || fail "$label: file is missing gate-tail-$i"; done
  rm -f "$gate_file"
}

# ===== exit 2: usage and preconditions
setup
for args in "" "abc" "7" "7 --repo O/N --reviewed x" "7 --reviewed x --worktree $WT" \
            "7 --repo O/N --worktree $WT" "7 --repo O/N --reviewed x --worktree $WT --bogus 1" \
            "7 --repo O/N --reviewed x --worktree $WT --timeout x" \
            "7 --repo O/N --reviewed x --worktree $WT --timeout -1" \
            "7 --repo O/N --reviewed x --worktree $WT --gate" \
            "7 --repo O/N --reviewed x --worktree $WT --no-mutants-label"; do
  # shellcheck disable=SC2086
  run $args; expect 2 "usage [$args]"; untouched "usage [$args]"
  grep -q '^usage: ship-pr' <<<"$ERR" || fail "usage text for [$args]: [$ERR]"
done
setup
# shellcheck disable=SC2086
eval "run 7 --repo O/N --reviewed x --worktree $WT --no-mutants-label ''"; expect 2 "empty reason"; untouched "empty reason"
grep -q '^usage: ship-pr' <<<"$ERR" || fail "usage text for empty reason: [$ERR]"
[ ! -e "$ST/gh.log" ] || fail "empty reason makes no gh call"

setup; touch "$ST/view-fail"; ship; expect 2 "unreadable PR"; untouched "unreadable PR"
setup; echo CLOSED >"$ST/state"; ship; expect 2 "PR not open"; untouched "PR not open"
setup; run 7 --repo O/N --reviewed "$HEAD0" --worktree "$S"; expect 2 "not a checkout"
setup; git -C "$WT" checkout -q -b other; ship; expect 2 "wrong branch"; untouched "wrong branch"
setup; echo x >>"$WT/feature.txt"; ship; expect 2 "dirty tree"; untouched "dirty tree"
setup; echo x >"$WT/untracked.txt"; ship; expect 2 "untracked file"; untouched "untracked file"

# proptest-regressions seeds are not dirt: untracked seeds alone never refuse,
# but another untracked file or a tracked change still does
setup; mkdir -p "$WT/proptest-regressions"; echo seed >"$WT/proptest-regressions/a.txt"
ship; expect 0 "untracked proptest-regressions alone does not refuse"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "proptest-regressions still merges: [$OUT]"
setup; mkdir -p "$WT/proptest-regressions"; echo seed >"$WT/proptest-regressions/a.txt"
echo x >"$WT/untracked.txt"; ship; expect 2 "proptest-regressions plus another untracked file still refuses"
untouched "proptest-regressions plus another untracked file"
setup; mkdir -p "$WT/proptest-regressions"; echo seed >"$WT/proptest-regressions/a.txt"
echo x >>"$WT/feature.txt"; ship; expect 2 "a tracked change still refuses with proptest-regressions present"
untouched "tracked change with proptest-regressions"
setup; bump_ref refs/heads/feature; ship; expect 2 "HEAD differs from PR head"; untouched "HEAD differs"
setup; run 7 --repo O/N --reviewed deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --worktree "$WT"
expect 2 "unknown reviewed"; untouched "unknown reviewed"
no_merge "preconditions"

# fetch retry: a transient ref-lock failure retries instead of exiting 1
setup; touch "$ST/fetch-fail-once"
ship; expect 0 "fetch retries after a transient lock failure"
[ "$(grep -c ' fetch -q origin$' "$ST/fetch.log")" -eq 2 ] || fail "transient fetch tries twice: [$(cat "$ST/fetch.log" 2>/dev/null)]"
[ "$(grep -c '^1$' "$ST/sleeps.txt" 2>/dev/null)" = "1" ] || fail "transient fetch sleeps 1 s once: [$(cat "$ST/sleeps.txt" 2>/dev/null)]"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "transient fetch still merges: [$OUT]"

setup; touch "$ST/fetch-always-fail"
ship; expect 1 "a fetch that always fails exits non-zero after 3 tries"
[ "$(grep -c ' fetch -q origin$' "$ST/fetch.log")" -eq 3 ] || fail "always-fail fetch tries 3 times: [$(cat "$ST/fetch.log" 2>/dev/null)]"
[ "$(grep -c '^1$' "$ST/sleeps.txt" 2>/dev/null)" = "2" ] || fail "always-fail fetch sleeps 1 s twice: [$(cat "$ST/sleeps.txt" 2>/dev/null)]"
no_merge "always-fail fetch"

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
ship --gate "$GATE_PANIC"
expect 1 "failing gate"; untouched "failing gate"
assert_gate_panic_failure "step 2 gate"
no_merge "failing gate"
setup; advance_main other.txt o
ship --gate 'echo main-moved-gate; exit 3'; expect 1 "failing gate after main moved"; untouched "failing gate after main moved"
GATE_FILE="$(sed -n 's/^full gate output: //p' <<<"$OUT")"
[ -f "$GATE_FILE" ] || fail "failing gate after main moved: log exists: [$GATE_FILE]"
rm -f "$GATE_FILE"
setup; advance_main other.txt o
ship --gate 'test ! -e other.txt'; expect 0 "gate runs on the pre-rebase head"
! compgen -G "$TMPDIR/ship-pr-7-gate.*" >/dev/null || fail "passing gate leaves no log file"
setup
ship --gate "cat '$SCRIPT_DIR/fixtures/ship-pr-nextest-flaky.txt'"
expect 0 "a flaky nextest test keeps the gate passing"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "flaky gate still merges: [$OUT]"
grep -Fq 'ship-pr: FLAKY nextest-flaky::flaky flaky_once' <<<"$ERR" || fail "flaky test reported: [$ERR]"
grep -Fq "thread 'flaky_once' (788635) panicked at" <<<"$ERR" || fail "failed attempt panic printed: [$ERR]"
grep -Fq 'panic from first attempt' <<<"$ERR" || fail "failed attempt panic text printed: [$ERR]"
setup; ship --gate 'git commit -q --allow-empty -m gate'
expect 1 "gate that commits"; [ "$(origin_head)" = "$O0" ] || fail "gate commit never pushed"; no_merge "gate commit"
setup; ship --gate 'echo x >>feature.txt'; expect 1 "gate that dirties"; no_merge "gate dirty"
setup; ship --gate 'test "$PWD" = "$(cd "'"$WT"'" && pwd -P)"; test -f feature.txt'
expect 0 "gate runs in the worktree"

# disk preflight blocks a low-space gate, and its cache sweep only removes old xcrun files
setup
mkdir -p "$S/bin"
printf '%s\n' '#!/bin/sh' \
  "printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/fake 1000000 950000 50000 95%% /fake\\n'" \
  >"$S/bin/df"
chmod +x "$S/bin/df"
PATH="$S/bin:$BASE_PATH"; export PATH
ship --gate 'touch "$ST/gate-ran"'
expect 1 "low free space refuses the gate"
grep -Fq 'ship-pr: only 0 GB free on /fake; a gate needs 20 GB. Free space, then rerun.' <<<"$ERR" \
  || fail "low free space message: [$ERR]"
[ ! -e "$ST/gate-ran" ] || fail "low free space starts no gate"
no_merge "low free space"
PATH="$BASE_PATH"; export PATH

setup
TMPDIR="$T/tmp"; export TMPDIR
mkdir -p "$TMPDIR"
touch "$TMPDIR/xcrun_db-x" "$TMPDIR/xcrun_db-fresh"
touch -t 202001010000 "$TMPDIR/xcrun_db-x"
ship; expect 0 "stale cache sweep runs without --gate"
[ ! -e "$TMPDIR/xcrun_db-x" ] || fail "no-gate run deletes old xcrun cache"
[ -f "$TMPDIR/xcrun_db-fresh" ] || fail "no-gate run keeps fresh xcrun cache"

setup
cache_dir="$T/cache-target"; cache_link="$T/cache-tmp"
mkdir -p "$cache_dir"; ln -s "$cache_dir" "$cache_link"
TMPDIR="$cache_link"; export TMPDIR
touch "$TMPDIR/xcrun_db-x" "$TMPDIR/xcrun_db-fresh" "$TMPDIR/other-cache"
touch -t 202001010000 "$TMPDIR/xcrun_db-x" "$TMPDIR/other-cache"
ship --gate true; expect 0 "stale cache sweep follows a symlinked TMPDIR"
[ ! -e "$TMPDIR/xcrun_db-x" ] || fail "old xcrun cache deleted through TMPDIR symlink"
[ -f "$TMPDIR/xcrun_db-fresh" ] || fail "fresh xcrun cache kept through TMPDIR symlink"
[ -f "$TMPDIR/other-cache" ] || fail "other old file kept through TMPDIR symlink"
TMPDIR="$T/tmp"; export TMPDIR

# ===== exit 1 and 124: push and CI
setup; echo '[{"bucket":"fail","name":"ci"},{"bucket":"pass","name":"lint"}]' >"$ST/checks"
ship; expect 1 "failing CI"; untouched "failing CI, no rebase, no push"
grep -q '^failing: ci$' <<<"$OUT" || fail "failing line printed: [$OUT]"
grep -qx "gh-ci: ${HEAD0:0:8} pending=0 passed=0 failing=1" <<<"$ERR" || fail "gh-ci progress reaches ship-pr stderr: [$ERR]"
grep -q 'pending' <<<"$OUT" && fail "progress stays off ship-pr stdout: [$OUT]"
no_merge "failing CI"
[ -d "$WT" ] || fail "worktree kept after failing CI"

setup; echo DIRTY >"$ST/merge-state"
ship; expect 3 "conflict after the push"; no_merge "conflict after the push"
grep -q "PR conflicts with origin/main after the push; rebase again, then rerun" <<<"$ERR" || fail "conflict message: [$ERR]"
[ -d "$WT" ] || fail "worktree kept after a conflict"

setup; echo '[{"bucket":"pending","name":"ci"}]' >"$ST/checks"
ship --timeout 0; expect 124 "CI timeout"; no_merge "CI timeout"
[ "$(grep -c "^gh-ci: ${HEAD0:0:8} pending=1 passed=0 failing=0$" <<<"$ERR")" = 1 ] || fail "one progress line while the counts hold: [$ERR]"

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
setup; echo "$NOSTRICT" >"$ST/rules"; advance_main other.txt o
ship --gate 'echo "$NEXTEST_RETRIES" >>"$ST/retries"'
expect 0 "both gate steps enable nextest retries"
[ "$(cat "$ST/retries")" = "1
1" ] || fail "both gate steps see NEXTEST_RETRIES=1: [$(cat "$ST/retries")]"
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

# gate fails only on the merged tree: print panic context and restore the pinned head
GATE_PANIC_ON_MERGED="if [ ! -e bad ]; then echo gate-step-2-pass; exit 0; fi; $GATE_PANIC"
setup; echo "$NOSTRICT" >"$ST/rules"; advance_main bad x; echo true >"$ST/draft"
ship --gate "$GATE_PANIC_ON_MERGED"
expect 1 "not strict guard fails on the merged tree"
! grep -q '^gh pr merge' "$ST/gh.log" || fail "guard gate fails: no merge call"
assert_gate_panic_failure "step 7 gate"
grep -qF 'ship-pr: the PR merged with current origin/main fails the gate; nothing merged, PR 7 is still marked ready' <<<"$ERR" \
  || fail "guard gate status message: [$ERR]"
grep -q '^gh pr ready 7 --repo O/N$' "$ST/gh.log" || fail "draft marked ready before the gate fails"
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
cd "$T" || fail "cd out"
run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT"
expect 0 "draft happy path"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "merged line: [$OUT]"
grep -q "^gh pr merge 7 --repo O/N --squash --match-head-commit $HEAD0\$" "$ST/gh.log" || fail "merge call: [$(grep merge "$ST/gh.log")]"
[ "$(grep -n '^gh pr ready 7 --repo O/N' "$ST/gh.log" | cut -d: -f1)" -lt "$(grep -n -m1 'check-runs' "$ST/gh.log" | cut -d: -f1)" ] \
  || fail "ready runs before the first CI wait"
grep -qx false "$ST/draft" || fail "draft ends ready"
[ ! -e "$WT" ] || fail "worktree removed"
git -C "$C" rev-parse --verify -q refs/heads/feature >/dev/null && fail "local branch deleted"
origin_head >/dev/null && fail "origin branch deleted"

# ===== merge and cleanup from inside the worktree: the worktree and local
# ===== branch are kept, the origin branch is deleted
setup; echo true >"$ST/draft"
cd "$WT" || fail "cd worktree"
run 7 --repo O/N --reviewed "$HEAD0" --worktree .
cd "$T" || fail "cd out"
expect 0 "inside happy path"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "inside merged line: [$OUT]"
[ -d "$WT" ] || fail "inside: worktree kept"
git -C "$C" rev-parse --verify -q refs/heads/feature >/dev/null || fail "inside: local branch kept"
origin_head >/dev/null && fail "inside: origin branch deleted"
grep -q 'worktree kept' <<<"$ERR" || fail "inside: worktree kept message: [$ERR]"

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

setup; echo true >"$ST/draft"; touch "$ST/no-merge"; ship; expect 1 "never MERGED"
grep -qF 'ship-pr: merge status could not be confirmed after 12 polls; worktree left in place' <<<"$ERR" \
  || fail "unconfirmed merge status message: [$ERR]"
! grep -qE 'nothing merged|still marked ready' <<<"$ERR" || fail "post-merge polling makes no merge or ready claim: [$ERR]"
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
grep -qx false "$ST/draft" || fail "draft ends ready"
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

# ===== mutants label: a draft needs the label when the repo defines it,
# ===== so mutants run on the draft from the first push
repo_labels() { printf '%s\n' "$1" >"$ST/labels"; }
on_pr_labels() { printf '%s\n' "$1" >"$ST/pr-labels"; }
MUTANTS_LABEL='[{"name":"mutants"}]'

# (a) repo defines mutants, draft PR without the label: exit 5, no ready call
setup; echo true >"$ST/draft"; repo_labels "$MUTANTS_LABEL"
ship; expect 5 "draft without the mutants label"
untouched "draft without the mutants label"; no_merge "draft without the mutants label"
grep -q 'PR lacks the mutants label' <<<"$ERR" || fail "missing-label message: [$ERR]"
grep -q -- '--no-mutants-label' <<<"$ERR" || fail "missing-label names the flag: [$ERR]"
! grep -q 'check-runs' "$ST/gh.log" || fail "missing label: no CI call"
[ -d "$WT" ] || fail "missing label: worktree kept"

# a differently-named label is not the mutants label
setup; echo true >"$ST/draft"; repo_labels "$MUTANTS_LABEL"; on_pr_labels '[{"name":"mutants-foo"}]'
ship; expect 5 "near-miss label still exits 5"; no_merge "near-miss label"

# (b) same with the label: passes
setup; echo true >"$ST/draft"; repo_labels "$MUTANTS_LABEL"; on_pr_labels "$MUTANTS_LABEL"
ship; expect 0 "draft with the mutants label"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "labelled draft merged line: [$OUT]"
grep -qx false "$ST/draft" || fail "labelled draft ends ready"

# mutants beyond the first API page are still enforced
setup; echo true >"$ST/draft"
repo_labels "$(jq -nc '[range(100) | {name: ("label-" + tostring)}] + [{name: "mutants"}]')"
ship; expect 5 "mutants after first 100 labels is enforced"
no_merge "mutants after first 100 labels"
grep -q 'PR lacks the mutants label' <<<"$ERR" || fail "late-label message: [$ERR]"

# (c) repo without the label: passes unchecked, without reading PR labels
setup; echo true >"$ST/draft"
ship; expect 0 "repo without the mutants label passes unchecked"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "unchecked repo merged line: [$OUT]"
! grep -q -- '--json labels' "$ST/gh.log" || fail "unchecked repo: no PR label read"

# a repo with other labels only is not checked either
setup; echo true >"$ST/draft"; repo_labels '[{"name":"docs"}]'
ship; expect 0 "repo with other labels passes unchecked"

# a non-draft is not checked even when the repo defines the label
setup; repo_labels "$MUTANTS_LABEL"
ship; expect 0 "non-draft skips the mutants check"
! grep -q -- '--json labels' "$ST/gh.log" || fail "non-draft: no PR label read"

# (d) --no-mutants-label skips the check and prints the reason
setup; echo true >"$ST/draft"; repo_labels "$MUTANTS_LABEL"
ship --no-mutants-label 'mutants not run for a docs-only change'; expect 0 "no-mutants-label passes"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "skipped check merged line: [$OUT]"
grep -q 'mutants not run for a docs-only change' <<<"$ERR" || fail "skip reason printed: [$ERR]"
! grep -q 'label' "$ST/gh.log" || fail "skipped check: no label read"

# an unreadable label list fails before any push
setup; echo true >"$ST/draft"; repo_labels "$MUTANTS_LABEL"; touch "$ST/label-list-fail"
ship; expect 2 "unreadable label list"; untouched "unreadable label list"; no_merge "unreadable label list"

# an unreadable PR label read fails before any push
setup; echo true >"$ST/draft"; repo_labels "$MUTANTS_LABEL"; touch "$ST/pr-labels-fail"
ship; expect 2 "unreadable PR labels"; untouched "unreadable PR labels"; no_merge "unreadable PR labels"

# ===== Implemented by:: the value holds model ids, never unknown or empty.
# A bad value prints `bad body line: <line>` and exits 5, like a missing line.
bad_impl() {
  nothing_ran "$2"
  [ "$OUT" = "bad body line: $1" ] || fail "$2: bad line printed: [$OUT]"
  grep -q 'PR body lacks required lines; edit the PR body, then rerun' <<<"$ERR" || fail "$2: miss message: [$ERR]"
}
good_impl() {
  expect 0 "$1"
  [ "$OUT" = "merged $MERGE_SHA" ] || fail "$1: merged line: [$OUT]"
}
setup; printf 'Implemented by: unknown\n' >"$ST/body"
ship --body-has 'Implemented by:'; bad_impl 'Implemented by: unknown' "unknown refused"
setup; printf 'Implemented by: UNKNOWN\n' >"$ST/body"
ship --body-has 'Implemented by:'; bad_impl 'Implemented by: UNKNOWN' "UNKNOWN refused"
setup; printf 'Implemented by: Unknown\n' >"$ST/body"
ship --body-has 'Implemented by:'; bad_impl 'Implemented by: Unknown' "Unknown refused"
setup; printf 'Implemented by:\n' >"$ST/body"
ship --body-has 'Implemented by:'; bad_impl 'Implemented by:' "empty value refused"
setup; printf 'Implemented by:   \n' >"$ST/body"
ship --body-has 'Implemented by:'; bad_impl 'Implemented by:   ' "spaces value refused"
setup; printf 'Implemented by:\tunknown\n' >"$ST/body"
ship --body-has 'Implemented by:'; nothing_ran "tab before unknown"
[ "$OUT" = "$(printf 'bad body line: Implemented by:\tunknown')" ] || fail "tab line printed: [$OUT]"
grep -q 'PR body lacks required lines; edit the PR body, then rerun' <<<"$ERR" || fail "tab miss message: [$ERR]"
setup; printf 'Implemented by: m/a, unknown\n' >"$ST/body"
ship --body-has 'Implemented by:'; bad_impl 'Implemented by: m/a, unknown' "unknown beside a valid id refused"
setup; printf 'Implemented by: m/a,, m/b\n' >"$ST/body"
ship --body-has 'Implemented by:'; bad_impl 'Implemented by: m/a,, m/b' "empty item refused"
setup; printf 'Implemented by: m/a,\n' >"$ST/body"
ship --body-has 'Implemented by:'; bad_impl 'Implemented by: m/a,' "trailing comma refused"
setup; printf 'Implemented by: m/a\nImplemented by: unknown\n' >"$ST/body"
ship --body-has 'Implemented by:'; bad_impl 'Implemented by: unknown' "second line checked"
setup; printf 'Implemented by: unknown\r\n' >"$ST/body"
ship --body-has 'Implemented by:'; bad_impl 'Implemented by: unknown' "CRLF bad line printed without CR"

setup; printf 'Implemented by: m/a\n' >"$ST/body"
ship --body-has 'Implemented by:'; good_impl "one id passes"
setup; printf 'Implemented by: m/a, claude-sonnet-5-5\n' >"$ST/body"
ship --body-has 'Implemented by:'; good_impl "two ids pass"
setup; printf 'Implemented by: m/unknown-2\n' >"$ST/body"
ship --body-has 'Implemented by:'; good_impl "unknown inside an id passes"
setup; printf 'Implemented by: unknownish\n' >"$ST/body"
ship --body-has 'Implemented by:'; good_impl "unknownish passes"
setup; printf 'Implemented by: m/a\r\n' >"$ST/body"
ship --body-has 'Implemented by:'; good_impl "CRLF valid line passes"

setup; printf 'Implemented by: unknown\n' >"$ST/body"
ship; good_impl "no flag skips the value check"
setup; printf 'Implemented by: unknown\n' >"$ST/body"
ship --body-has 'Implemented by: unk'; good_impl "another prefix skips the value check"
setup; printf 'Implemented by: unknown\nDoc friction: none\n' >"$ST/body"
ship --body-has 'Doc friction:'; good_impl "another line only skips the value check"

setup; printf 'Resolves #97\n' >"$ST/body"
ship --body-has 'Implemented by:'; nothing_ran "no Implemented by line"
[ "$OUT" = "missing body line: Implemented by:" ] || fail "missing line printed: [$OUT]"
grep -q 'PR body lacks required lines; edit the PR body, then rerun' <<<"$ERR" || fail "missing message: [$ERR]"

setup; printf 'Implemented by: unknown\n' >"$ST/body"
ship --body-has 'Implemented by:' --body-has 'Doc friction:'; nothing_ran "missing and bad together"
grep -Fqx 'missing body line: Doc friction:' <<<"$OUT" || fail "missing line printed: [$OUT]"
grep -Fqx 'bad body line: Implemented by: unknown' <<<"$OUT" || fail "bad line printed: [$OUT]"
grep -q 'PR body lacks required lines; edit the PR body, then rerun' <<<"$ERR" || fail "missing and bad message: [$ERR]"

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
[ "$(head -n 1 "$ST/comment.txt")" = "Fixes since $SHORT shipped without re-review (review-loop step 3: no real bug in round one)." ] \
  || fail "comment first line: [$(head -n 1 "$ST/comment.txt")]"
grep -qx 'Findings:' "$ST/comment.txt" && grep -q 'P2: missing test for x' "$ST/comment.txt" || fail "comment holds the findings: [$(cat "$ST/comment.txt")]"
grep -qx 'Changed since review:' "$ST/comment.txt" && grep -q 'feature.txt' "$ST/comment.txt" || fail "comment holds the stat: [$(cat "$ST/comment.txt")]"
grep -q '^gh pr merge' "$ST/gh.log" || fail "unverified fixes: merged"
[ ! -e "$WT" ] || fail "unverified fixes: worktree removed"

# 1b. a repair that merges main: the stat lists the repair's files, not the base's
setup
echo changed >"$WT/feature.txt"; git -C "$WT" commit -qam "fix nit"
advance_main unrelated.txt u
git -C "$WT" merge -q --no-edit origin/main; git -C "$WT" push -q origin feature
run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT" --unverified-fixes "$F"
expect 0 "repair with a merge of main merges"
[ "$(comment_count)" -eq 1 ] || fail "merge of main: one comment: [$(cat "$ST/gh.log")]"
grep -q 'feature.txt' "$ST/comment.txt" || fail "merge of main: stat lists feature.txt: [$(cat "$ST/comment.txt")]"
! grep -q 'unrelated.txt' "$ST/comment.txt" || fail "merge of main: stat omits base files: [$(cat "$ST/comment.txt")]"

# 2. a mismatch without the option: exit 4, as before
setup
echo changed >"$WT/feature.txt"; git -C "$WT" commit -qam "fix nit"; git -C "$WT" push -q origin feature
ship; expect 4 "mismatch without --unverified-fixes exits 4"; no_merge "mismatch without the option"
[ "$(comment_count)" -eq 0 ] || fail "no comment without the option"
grep -q -- '--unverified-fixes' <<<"$ERR" || fail "exit-4 message names --unverified-fixes: [$ERR]"
grep -q 'scoped verify' <<<"$ERR" || fail "exit-4 message names the scoped verify: [$ERR]"
grep -q -- '--verify' <<<"$ERR" || fail "exit-4 message names --verify: [$ERR]"
grep -q "$HEAD0" <<<"$ERR" || fail "exit-4 message keeps the reviewed sha: [$ERR]"

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

# ===== (A) rerun CI once when the failure is outside the diff
setup; echo '[{"bucket":"cancel","name":"ci"}]' >"$ST/checks"
echo '[{"databaseId":101,"name":"ci","workflowName":"CI","event":"push","conclusion":"cancelled"}]' >"$ST/run-list.json"
echo '[{"conclusion":"cancelled","databaseId":201,"name":"ci"}]' >"$ST/jobs-101.json"
ship; expect 0 "cancelled failure reruns once and merges"
grep -q 'gh run rerun 101 --failed' "$ST/gh.log" || fail "cancelled: rerun called: [$(cat "$ST/gh.log")]"
grep -q 'CI failure outside the diff' <<<"$ERR" || fail "cancelled: outside message: [$ERR]"
grep -q 'rerunning failed jobs once' <<<"$ERR" || fail "cancelled: rerun message: [$ERR]"
grep -q 'file the flake' <<<"$ERR" || fail "cancelled: flake message: [$ERR]"
grep -q 'ci' <<<"$ERR" || fail "cancelled: reason names the job: [$ERR]"
[ "$(grep -c 'gh run rerun' "$ST/gh.log")" -eq 1 ] || fail "cancelled: exactly one rerun"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "cancelled rerun merges: [$OUT]"

setup; echo '[{"bucket":"fail","name":"ci"}]' >"$ST/checks"
echo '[{"databaseId":102,"name":"ci","workflowName":"CI","event":"push","conclusion":"failure"}]' >"$ST/run-list.json"
echo '[{"conclusion":"failure","databaseId":202,"name":"ci"}]' >"$ST/jobs-102.json"
printf '%s\n' "thread 't' panicked at src/outside.rs:10:5:" "assertion failed" >"$ST/log-102-202.log"
ship; expect 0 "panic outside the diff reruns once and merges"
grep -q 'gh run rerun 102 --failed' "$ST/gh.log" || fail "panic outside: rerun called"
grep -q 'src/outside.rs' <<<"$ERR" || fail "panic outside: reason names the path: [$ERR]"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "panic outside rerun merges: [$OUT]"

setup; echo '[{"bucket":"fail","name":"ci"}]' >"$ST/checks"
echo '[{"databaseId":103,"name":"ci","workflowName":"CI","event":"push","conclusion":"failure"}]' >"$ST/run-list.json"
echo '[{"conclusion":"failure","databaseId":203,"name":"ci"}]' >"$ST/jobs-103.json"
printf '%s\n' "thread 't' panicked at feature.txt:1:1:" "boom" >"$ST/log-103-203.log"
ship; expect 1 "panic inside the diff never reruns"
! grep -q 'gh run rerun' "$ST/gh.log" || fail "panic inside: no rerun"
! grep -q 'outside the diff' <<<"$ERR" || fail "panic inside: no outside message: [$ERR]"
grep -q 'CI failed' <<<"$ERR" || fail "panic inside: CI failed message: [$ERR]"

setup; echo '[{"bucket":"fail","name":"ci"}]' >"$ST/checks"
echo '[{"databaseId":104,"name":"ci","workflowName":"CI","event":"push","conclusion":"failure"}]' >"$ST/run-list.json"
echo '[{"conclusion":"failure","databaseId":204,"name":"ci"}]' >"$ST/jobs-104.json"
printf '%s\n' "build failed: clippy error" "no panic here" >"$ST/log-104-204.log"
ship; expect 1 "failed job with no panic never reruns"
! grep -q 'gh run rerun' "$ST/gh.log" || fail "no panic: no rerun"
grep -q 'CI failed' <<<"$ERR" || fail "no panic: CI failed message: [$ERR]"

setup; echo '[{"bucket":"cancel","name":"ci"}]' >"$ST/checks"
echo '[{"databaseId":105,"name":"ci","workflowName":"CI","event":"push","conclusion":"cancelled"}]' >"$ST/run-list.json"
echo '[{"conclusion":"cancelled","databaseId":205,"name":"ci"}]' >"$ST/jobs-105.json"
echo 105 >"$ST/rerun-fail"
ship; expect 1 "failed rerun names the run"
grep -q 'gh run rerun 105 --failed' "$ST/gh.log" || fail "rerun-fail: rerun attempted"
grep -q 'gh run rerun 105 --failed failed' <<<"$ERR" || fail "rerun-fail message names the run: [$ERR]"

setup; echo '[{"bucket":"cancel","name":"ci"}]' >"$ST/checks"
echo '[{"databaseId":106,"name":"ci","workflowName":"CI","event":"push","conclusion":"cancelled"}]' >"$ST/run-list.json"
echo '[{"conclusion":"cancelled","databaseId":206,"name":"ci"}]' >"$ST/jobs-106.json"
touch "$ST/rerun-keeps-failing"
ship; expect 1 "rerun wait that also fails exits 1"
grep -q 'CI failure outside the diff' <<<"$ERR" || fail "second fail: outside message"
[ "$(grep -c 'gh run rerun' "$ST/gh.log")" -eq 1 ] || fail "second fail: exactly one rerun"
grep -q 'CI failed' <<<"$ERR" || fail "second fail: CI failed message: [$ERR]"
no_merge "rerun wait fails"

setup; echo '[{"bucket":"cancel","name":"ci"}]' >"$ST/checks"
echo '[{"databaseId":111,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"cancelled"},{"databaseId":112,"name":"CI","workflowName":"CI","event":"push","conclusion":"success"}]' >"$ST/run-list.json"
echo '[{"conclusion":"cancelled","databaseId":211,"name":"ci"}]' >"$ST/jobs-111.json"
ship; expect 0 "failed pull_request run reruns despite a newer successful push run"
grep -q 'gh run rerun 111 --failed' "$ST/gh.log" || fail "mixed event: pull_request run rerun"
! grep -q 'gh run rerun 112' "$ST/gh.log" || fail "mixed event: successful push run never rerun"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "mixed event rerun merges: [$OUT]"

setup; echo '[{"bucket":"cancel","name":"ci"}]' >"$ST/checks"
echo '[{"databaseId":107,"name":"ci","workflowName":"CI","event":"push","conclusion":"cancelled"}]' >"$ST/run-list.json"
echo '[{"conclusion":"cancelled","databaseId":207,"name":"ci"}]' >"$ST/jobs-107.json"
echo 3 >"$ST/attempt-delay-107"
ship; expect 0 "rerun waits for the new attempt before the second wait"
grep -q 'gh run rerun 107 --failed' "$ST/gh.log" || fail "delayed: rerun called"
grep -q 'attempt' "$ST/gh.log" || fail "delayed: attempt polled: [$(cat "$ST/gh.log")]"
[ "$(grep -c '^5$' "$ST/sleeps.txt")" -eq 2 ] || fail "delayed: two 5 s attempt polls: [$(cat "$ST/sleeps.txt")]"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "delayed rerun merges: [$OUT]"

setup; echo '[{"bucket":"cancel","name":"ci"}]' >"$ST/checks"
echo '[{"databaseId":108,"name":"ci","workflowName":"CI","event":"push","conclusion":"cancelled"}]' >"$ST/run-list.json"
echo '[{"conclusion":"cancelled","databaseId":208,"name":"ci"}]' >"$ST/jobs-108.json"
echo 999 >"$ST/attempt-delay-108"
ship; expect 1 "missing rerun attempt exits 1 naming the run"
grep -q '108' <<<"$ERR" || fail "missing attempt names the run: [$ERR]"
grep -q 'no new attempt' <<<"$ERR" || fail "missing attempt message: [$ERR]"
[ "$(grep -c '^5$' "$ST/sleeps.txt")" -eq 24 ] || fail "missing attempt polls 120 s: [$(cat "$ST/sleeps.txt")]"
no_merge "missing attempt"

# many cancelled runs: the rerun wait looks each pre-attempt up in a long
# list, which must not die on SIGPIPE when awk exits early (pipefail)
setup; echo '[{"bucket":"cancel","name":"ci"}]' >"$ST/checks"
jq -n '[range(3000) | {"databaseId": (1000+.), "name": "ci", "workflowName": "CI-\(.)", "event": "push", "conclusion": "cancelled"}]' >"$ST/run-list.json"
for i in $(seq 1 3000); do
  echo '[{"conclusion":"cancelled","databaseId":1,"name":"ci"}]' >"$ST/jobs-$((1000 + i)).json"
done
ship; expect 0 "many cancelled runs rerun once and merge"
[ "$(grep -c 'gh run rerun' "$ST/gh.log")" -eq 3000 ] || fail "many runs: every run rerun once: [$(grep -c 'gh run rerun' "$ST/gh.log")]"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "many reruns merge: [$OUT]"

# ===== (B) retry the merge once on a GraphQL error, polling MERGED after a failed retry
setup; printf 'GraphQL error: something went wrong' >"$ST/merge-fail-once"
ship; expect 0 "GraphQL error retries once"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "merged line after GraphQL retry: [$OUT]"
[ "$(grep -c '^gh pr merge' "$ST/gh.log")" -eq 2 ] || fail "GraphQL: merge called twice"
grep -q 'retrying once' <<<"$ERR" || fail "GraphQL retry message: [$ERR]"
grep -q 'GraphQL' <<<"$ERR" || fail "GraphQL error printed: [$ERR]"
grep -q '^5$' "$ST/sleeps.txt" || fail "GraphQL retry sleeps 5 s"
[ ! -e "$WT" ] || fail "worktree removed after a GraphQL retry"

setup; printf 'GraphQL error: still broken' >"$ST/merge-fail-msg"; touch "$ST/merge-fails-but-merges"
ship; expect 0 "failed GraphQL retry still polls MERGED"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "merged despite GraphQL retry failure: [$OUT]"
[ "$(grep -c '^gh pr merge' "$ST/gh.log")" -eq 2 ] || fail "GraphQL merged-despite-error: two merge calls"

setup; printf 'Base branch was modified. Review and try the merge again.' >"$ST/merge-fail-msg"
ship; expect 1 "failed retry still polls MERGED before failing"
[ "$(grep -c '^gh pr merge' "$ST/gh.log")" -eq 2 ] || fail "failed retry polls: two merge calls"
grep -q 'gh pr merge failed' <<<"$ERR" || fail "failed retry says the merge command failed: [$ERR]"
[ -d "$WT" ] || fail "worktree kept when the retry fails and nothing merged"
grep -qx '1' "$ST/sleeps.txt" || fail "failed retry polls MERGED (sleep 1): [$(cat "$ST/sleeps.txt" 2>/dev/null)]"

# ===== (C) wait for GitHub head to match the local HEAD
setup; git -C "$WT" commit -q --amend -m 'feature, reworded'
git -C "$WT" push -q --force-with-lease origin HEAD:refs/heads/feature
echo "$HEAD0" >"$ST/head-first-stale"
ship; expect 0 "fresh push shows up within 60 s"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "head wait merges: [$OUT]"
grep -qx '2' "$ST/sleeps.txt" || fail "head wait sleeps 2 s: [$(cat "$ST/sleeps.txt" 2>/dev/null)]"

setup; bump_ref refs/heads/feature
ship; expect 2 "HEAD that never matches exits 2 after 60 s"
grep -q 'is not the PR head' <<<"$ERR" || fail "head wait timeout message: [$ERR]"
[ "$(grep -c '^2$' "$ST/sleeps.txt")" -eq 30 ] || fail "head wait polls 30 times: [$(cat "$ST/sleeps.txt" 2>/dev/null)]"
untouched "head wait timeout"; no_merge "head wait timeout"

# ===== (D) pr-closes runs before the gate, never after CI
setup; echo 'Resolves #97. also fixes #9' >"$ST/body"
ship --gate 'touch "$ST/gate-ran"; exit 1'; expect 5 "stray text fails before the gate"
[ ! -e "$ST/gate-ran" ] || fail "pr-closes before the gate starts no gate"
! grep -q 'running gate' <<<"$ERR" || fail "pr-closes before the gate: no gate message: [$ERR]"
grep -q '^#9 body: fixes #9$' <<<"$OUT" || fail "stray line printed: [$OUT]"
no_merge "pr-closes before gate"
! grep -q 'check-runs' "$ST/gh.log" || fail "pr-closes before the gate: no CI call"

setup; printf 'Resolves #97\n' >"$ST/body"
checks_hook 'printf "Resolves #97\nfixes #9\n" >"$ST/body"'
ship; expect 0 "pr-closes never runs after CI"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "late stray body still merges: [$OUT]"

# ===== (E) --allow-commit-closes
setup; printf 'Resolves #97\n' >"$ST/body"
printf '[{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","messageHeadline":"Fixes #9","messageBody":""}]' >"$ST/commits"
run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT" --allow-commit-closes
expect 0 "commit-only matches warn and merge"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "commit-only merges: [$OUT]"
grep -q 'allowing' <<<"$ERR" || fail "commit-only warning: [$ERR]"
grep -q '#9' <<<"$ERR" || fail "commit-only warning names the issue: [$ERR]"
! grep -q '#9' <<<"$OUT" || fail "commit-only match stays off stdout: [$OUT]"

setup; printf 'Resolves #97\n' >"$ST/body"
printf '[{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","messageHeadline":"Fixes #9","messageBody":""}]' >"$ST/commits"
ship; expect 5 "commit-only matches fail without the flag"
no_merge "commit-only without the flag"

setup; printf 'Resolves #97. also fixes #9\n' >"$ST/body"
printf '[{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","messageHeadline":"Fixes #8","messageBody":""}]' >"$ST/commits"
run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT" --allow-commit-closes
expect 5 "title or body matches still exit 5 with the flag"
grep -q '^#9 body: fixes #9$' <<<"$OUT" || fail "body stray still printed: [$OUT]"
grep -q 'allowing' <<<"$ERR" || fail "commit warning alongside body failure: [$ERR]"
no_merge "body match with the flag"

echo "ship-pr: all cases passed"

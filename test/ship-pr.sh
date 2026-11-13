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
cat >"$T/bin/lsof" <<'LSOF'
#!/bin/sh
[ ! -e "$ST/worktree-busy" ] || { echo 12345; exit 0; }
exit 1
LSOF
chmod 755 "$T/bin/lsof"
BASE_PATH="$T/bin:$PATH"; export PATH="$BASE_PATH"
[ "$(command -v df)" = "$T/bin/df" ] || fail "df resolves to the suite's stub, not the host's"
cat >"$T/bin/cargo" <<'CARGO'
#!/usr/bin/env bash
if [ "${1:-}" = metadata ]; then
  [ ! -e "$ST/cargo-metadata-fail" ] || exit 127
  printf 'metadata=%s cwd=%s\n' "$*" "$PWD" >>"$ST/cargo-metadata.log"
  if [ -e "$ST/cargo-metadata.json" ]; then
    cat "$ST/cargo-metadata.json"
  else
    jq -nc --arg manifest "$PWD/crates/main/Cargo.toml" \
      --arg lib "$PWD/crates/main/src/lib.rs" \
      --arg integration "$PWD/crates/main/tests/integration_tests.rs" \
      '{packages:[{name:"crate-name",manifest_path:$manifest,targets:[{name:"crate_name",kind:["lib"],src_path:$lib},{name:"integration_tests",kind:["test"],src_path:$integration}]}]}'
  fi
  exit 0
fi
printf 'held=%s\n' "${CARGO_SLOT_HELD-unset}" >"$ST/cargo-held"
printf 'threads=%s\n' "${NEXTEST_TEST_THREADS-unset}" >"$ST/cargo-threads"
CARGO
chmod 755 "$T/bin/cargo"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GH_CI_INTERVAL=7 SHIP_PR_INTERVAL=1
# CLAUDECODE must not change gh-ci wait timeouts under test (ship-pr passes
# --timeout 0 and 14 in cases below), so start unset however the suite is invoked.
unset CLAUDECODE GH_CI_NO_JOBS_AFTER
MERGE_SHA="1f2e3d4c5b6a79881726354433221100ffeeddcc"

# Build the immutable base once. Each case clones its own refs and worktree,
# sharing only these read-only Git objects.
TEMPLATE="$T/template.git"
git init -q --bare -b main "$TEMPLATE"
git init -q -b main "$T/template-seed"
printf 'a\nb\nc\n' >"$T/template-seed/file.txt"
mkdir -p "$T/template-seed/crates/main/src" "$T/template-seed/crates/main/tests"
printf '[package]\nname = "crate-name"\nversion = "0.1.0"\n' >"$T/template-seed/crates/main/Cargo.toml"
printf 'pub fn baseline() {}\n' >"$T/template-seed/crates/main/src/lib.rs"
printf 'fn baseline() {}\n' >"$T/template-seed/crates/main/tests/integration_tests.rs"
printf 'baseline\n' >"$T/template-seed/crates/main/README.md"
git -C "$T/template-seed" add .
git -C "$T/template-seed" commit -qm init
git -C "$T/template-seed" push -q "$TEMPLATE" main

# --- fake gh. Reads $ST (state dir) and $ORIGIN. The PR head is origin's
# --- feature branch, so a push is visible to gh-ci. --jq runs through jq.
gh() {
  local many_rid="${3:-}" many_fields="" many_jq=""
  # The stress case below intentionally exercises all 3,000 failed runs. Keep
  # its fake API responses equivalent, but avoid a nested shell and jq process
  # for every attempt read; the test still checks every rerun call.
  if [ -e "$ST/jobs-many-cancelled.json" ] && [ "${1:-}" = run ]; then
    case "${2:-}" in
      list)
        printf 'gh %s\n' "$*" >>"$ST/gh.log"
        if [[ "$*" == *'--json databaseId,name,event,conclusion,workflowName,status'* ]]; then
          # gh-ci needs one cancelled job to classify the failure as external;
          # the full 3,000-run list below remains for ship-pr's rerun stress case.
          printf '%s\n' '[{"databaseId":1000,"name":"ci","event":"push","conclusion":"cancelled","workflowName":"CI-0","status":"completed"}]'
        elif [ -e "$ST/run-list.json" ]; then
          cat "$ST/run-list.json"
        else
          echo '[]'
        fi
        return 0 ;;
      view)
        printf 'gh %s\n' "$*" >>"$ST/gh.log"
        shift 3
        while [ $# -gt 0 ]; do
          case "$1" in
            --json) many_fields="$2"; shift 2;;
            --jq) many_jq="$2"; shift 2;;
            *) shift;;
          esac
        done
        case "$many_fields" in
          jobs)
            printf '%s\n' '{"jobs":[{"conclusion":"cancelled","databaseId":1,"name":"ci"}]}' ;;
          status)
            printf '%s\n' '{"status":"completed"}' ;;
          attempt,status)
            if [ -e "$ST/many-reruns-started" ]; then many_rid=2; else many_rid=1; fi
            if [ "$many_jq" = '[.attempt, .status] | @tsv' ]; then
              printf '%s\tcompleted\n' "$many_rid"
            else
              printf '{"attempt":%s,"status":"completed"}\n' "$many_rid"
            fi ;;
          *) echo "fake gh: unexpected many-run view $many_fields" >&2; return 2;;
        esac
        return 0 ;;
      rerun)
        printf 'gh %s\n' "$*" >>"$ST/gh.log"
        if [ ! -e "$ST/many-reruns-started" ]; then
          touch "$ST/many-reruns-started"
          printf '%s\n' '[{"bucket":"pass","name":"ci"}]' >"$ST/checks"
        fi
        return 0 ;;
    esac
  fi
  if [ -e "$ST/jobs-many-cancelled.json" ] && [ "${1:-}" = api ] \
    && [[ "$*" == *actions/runs/* ]]; then
    printf 'gh %s\n' "$*" >>"$ST/gh.log"
    printf ' \n'
    return 0
  fi
  (
  set -euo pipefail
  echo "gh $*" >>"$ST/gh.log"
  rd() { [ -e "$ST/$1" ] && cat "$ST/$1" || echo "$2"; }
  if [ "$1" = "issue" ]; then
    shift
    sub="$1"; shift
    case "$sub" in
      list)
        [ ! -e "$ST/issue-list-fail" ] || { echo 'gh: issue list failed' >&2; exit 1; }
        rd issues '[]';;
      view)
        number="$1"; shift
        fields="" jq=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --json) fields="$2"; shift 2;;
            --jq) jq="$2"; shift 2;;
            *) shift;;
          esac
        done
        ticket="$(rd "ticket-$number.json" '{"state":"CLOSED","body":"","createdAt":"2026-11-01T00:00:00Z","comments":[]}')"
        if [ "$number" = 166 ] && [ -e "$ST/ticket-created-after-gate" ] && [ -e "$ST/gate-ran" ]; then
          ticket="$(jq -c '.createdAt = "2099-12-31T23:59:59Z"' <<<"$ticket")"
          printf '%s\n' "$ticket" >"$ST/ticket-166-post-gate.json"
          touch "$ST/ticket-created-after-gate-seen"
        fi
        if [ -n "$jq" ]; then jq -r "$jq" <<<"$ticket"; else echo "$ticket"; fi;;
      comment)
        number="$1"; shift
        body_file=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --body-file) body_file="$2"; shift 2;;
            *) shift;;
          esac
        done
        [ -n "$body_file" ] || { echo 'fake gh: issue comment needs --body-file' >&2; exit 2; }
        cp "$body_file" "$ST/ticket-comment-$number.txt";;
      create)
        title=""; body_file=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --title) title="$2"; shift 2;;
            --body-file) body_file="$2"; shift 2;;
            *) shift;;
          esac
        done
        number="$(rd next-issue 200)"
        body="$(cat "$body_file")"
        url="https://github.com/O/N/issues/$number"
        issue="$(jq -nc --argjson n "$number" --arg title "$title" --arg body "$body" --arg url "$url" \
          '{number:$n,title:$title,body:$body,url:$url}')"
        jq --argjson issue "$issue" '. + [$issue]' < <(rd issues '[]') >"$ST/issues.tmp"
        mv "$ST/issues.tmp" "$ST/issues"
        jq --argjson issue "$issue" '. + [$issue]' < <(rd created-issues '[]') >"$ST/created-issues.tmp"
        mv "$ST/created-issues.tmp" "$ST/created-issues"
        echo "$url"
        echo "$((number + 1))" >"$ST/next-issue";;
      *) echo "fake gh: unknown issue $sub" >&2; exit 2;;
    esac
    exit 0
  fi
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
      */issues/*/comments)
        # Preserve test comments and add the implicit approved review used by
        # existing cases unless a test supplies explicit review-pr comments.
        base_comments="$(rd comments '[]')"
        if [ -e "$ST/review-comments" ]; then
          review_comments="$(cat "$ST/review-comments")"
        elif [ -n "${SHIP_TEST_REVIEW_PID:-}" ] && [ -n "${SHIP_TEST_REVIEW_HEAD:-}" ]; then
          review_comments="$(jq -nc --arg pid "$SHIP_TEST_REVIEW_PID" --arg head "$SHIP_TEST_REVIEW_HEAD" '[{id:1,created_at:"2026-11-04T00:00:00Z",body:("review-pr: patch-id " + $pid + ", head " + $head + "\n\n## standards (test)\n\nVERDICT standards: APPROVE")}]')"
        else
          review_comments='[]'
        fi
        json="$(jq -nc --argjson base "$base_comments" --argjson reviews "$review_comments" '$base + $reviews')";;
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
        if [ -e "$ST/late-ready-run" ]; then
          n="$(cat "$ST/late-ready-run-list-calls" 2>/dev/null || echo 0)"
          n=$((n + 1)); echo "$n" >"$ST/late-ready-run-list-calls"
          if [ -e "$ST/late-ready-run-marked-ready" ] && [ "$n" -ge 5 ] && [ -e "$ST/run-list-after-ready-3.json" ]; then
            cat "$ST/run-list-after-ready-3.json"
          elif [ -e "$ST/late-ready-run-marked-ready" ] && [ "$n" -ge 4 ] && [ -e "$ST/run-list-after-ready-2.json" ]; then
            cat "$ST/run-list-after-ready-2.json"
          elif [ -e "$ST/late-ready-run-marked-ready" ] && [ "$n" -ge 3 ]; then
            cat "$ST/run-list-after-ready.json"
          else
            cat "$ST/run-list-before-ready.json"
          fi
        elif [ -e "$ST/run-list.json" ]; then cat "$ST/run-list.json"; else echo '[]'; fi;;
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
          if [ -e "$ST/log-$rid-$job.log" ]; then cat "$ST/log-$rid-$job.log"
          elif [ -e "$ST/log-$rid.log" ]; then cat "$ST/log-$rid.log"; fi
        else
          case "$json_fields" in
            *attempt*)
              # an injected attempt-read failure exits with the file's code after printing its stderr
              if [ -e "$ST/attempt-fail-$rid" ]; then
                rc="$(head -n 1 "$ST/attempt-fail-$rid")"
                tail -n +2 "$ST/attempt-fail-$rid" >&2
                exit "$rc"
              fi
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
              case "$a" in ''|*[!0-9]*) a=1 ;; esac
              s="$(cat "$ST/status-$rid.txt" 2>/dev/null || echo completed)"
              json="$(jq -nc --argjson a "$a" --arg s "$s" '{attempt: $a, status: $s}')";;
            *jobs*)
              if [ -e "$ST/jobs-$rid.json" ]; then
                json="$(jq -c '{jobs: .}' "$ST/jobs-$rid.json")"
              elif [ -e "$ST/jobs-many-cancelled.json" ] && [ "$rid" -ge 1000 ] && [ "$rid" -lt 4000 ]; then
                json='{"jobs":[{"conclusion":"cancelled","databaseId":1,"name":"ci"}]}'
              else
                json='{"jobs":[]}'
              fi;;
            *name*)
              json="$(jq -nc --arg r "$rid" '{name: ("run-" + $r)}')";;
            *headSha*)
              h="$(git --git-dir="$ORIGIN" rev-parse refs/heads/feature 2>/dev/null || cat "$ST/lasthead")"
              json="$(jq -nc --arg h "$h" '{headSha: $h}')";;
            *status*)
              if [ -e "$ST/late-ready-run" ] && [ "$rid" = "$(cat "$ST/late-ready-run-id" 2>/dev/null || echo 701)" ]; then
                n="$(cat "$ST/late-ready-run-view-calls" 2>/dev/null || echo 0)"
                n=$((n + 1)); echo "$n" >"$ST/late-ready-run-view-calls"
                if [ "$n" -ge 2 ]; then
                  touch "$ST/late-ready-run-completed"
                  echo '[{"bucket":"pass","name":"ci"}]' >"$ST/checks"
                  json='{"status":"completed"}'
                else
                  json='{"status":"in_progress"}'
                fi
              else
                json='{"status":"completed"}'
              fi;;
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
      json="$(jq -nc --arg h "$h" --arg s "$state" --arg d "$(rd draft false)" --arg ms "$(rd merge-state CLEAN)" --arg mg "$(rd mergeable MERGEABLE)" --arg b "$(rd body 'Resolves #97')" --arg ca "$(rd pr-created 2026-11-04T00:00:00Z)" \
        --argjson bn "$([ -e "$ST/body-null" ] && echo true || echo false)" --argjson c "$(rd commits '[]')" --arg m "$MERGE_SHA" \
        --argjson l "$(rd pr-labels '[]')" \
        '{state:$s, headRefName:"feature", baseRefName:"main", headRefOid:$h, isDraft:($d=="true"), mergeStateStatus:$ms, mergeable:$mg,
          title:"t", body:(if $bn then null else $b end), createdAt:$ca, commits:$c, labels:$l, mergeCommit:(if $s=="MERGED" then {oid:$m} else null end)}')"
      jq=""
      while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && jq="$2"; shift; done
      if [ -n "$jq" ]; then jq -r "$jq" <<<"$json"; else echo "$json"; fi;;
    ready)
      [ ! -e "$ST/ready-fail" ] || exit 1
      echo false >"$ST/draft"
      [ ! -e "$ST/late-ready-run" ] || touch "$ST/late-ready-run-marked-ready";;
    comment)
      [ ! -e "$ST/comment-fail" ] || exit 1
      while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && cp "$2" "$ST/comment.txt"; shift; done;;
    merge)
      if [ -e "$ST/late-ready-run" ] && [ ! -e "$ST/late-ready-run-completed" ]; then
        touch "$ST/merged-before-late-run-finished"
      fi
      if [ -e "$ST/merge-each" ]; then bash "$ST/merge-each"; fi
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
}
sleep() ( echo "$*" >>"$ST/sleeps.txt" )
export -f gh sleep

# --- fixture: main with file.txt, feature (one commit) pushed and checked out in $WT.
setup() {
  S="$T/case"; rm -rf "$S"; mkdir -p "$S/st"
  WT="$S/wt"; C="$S/clone"
  export ST="$S/st" ORIGIN="$S/origin.git" MERGE_SHA C
  git clone -q --bare --shared "$TEMPLATE" "$ORIGIN"
  git clone -q --shared "$ORIGIN" "$C"
  git -C "$C" worktree add -q -b feature "$WT"
  echo feature >"$WT/feature.txt"
  git -C "$WT" add . && git -C "$WT" commit -qm feature
  git -C "$WT" push -q -u origin feature
  HEAD0="$(git -C "$WT" rev-parse HEAD)"
  echo '[{"bucket":"pass","name":"ci"}]' >"$ST/checks"
}
publish_main_test_fixture() {
  git -C "$C" add -- test || fail "stage baseline test fixtures"
  git -C "$C" commit -qm 'seed test citation fixtures' || fail "commit baseline test fixtures"
  git -C "$C" push -q origin main || fail "push baseline test fixtures"
  git -C "$WT" fetch -q origin || fail "fetch baseline test fixtures"
  git -C "$WT" rebase -q origin/main || fail "rebase feature over baseline test fixtures"
  git -C "$WT" push -q --force-with-lease origin feature || fail "push rebased feature"
  HEAD0="$(git -C "$WT" rev-parse HEAD)"
}
push_test_change() {
  local path="$1" message="$2"
  if [ -e "$WT/$path" ]; then
    git -C "$WT" add -- "$path" || fail "stage test change $path"
  elif git -C "$WT" diff --cached --quiet -- "$path"; then
    fail "deleted test is not staged: $path"
  fi
  git -C "$WT" commit -qm "$message" || fail "commit test change $path"
  git -C "$WT" push -q origin feature || fail "push test change $path"
  HEAD0="$(git -C "$WT" rev-parse HEAD)"
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
# merge_each <shell>: runs inside every stubbed `gh pr merge` call.
merge_each() { printf '%s\n' "$1" >"$ST/merge-each"; }
# merge_once <shell>: merge_each, but only on the first merge call.
merge_once() { printf 'if [ ! -e "$ST/m1" ]; then touch "$ST/m1"; %s; fi\n' "$1" >"$ST/merge-each"; }
# OUTDATED: the strict-mode error when the head lost the race to origin/main.
OUTDATED='Pull request #7 is not mergeable: the head branch is not up to date with the base branch.'
# BUMP_MAIN: an empty commit on origin's main, without a checkout.
BUMP_MAIN='git --git-dir="$ORIGIN" update-ref refs/heads/main "$(git --git-dir="$ORIGIN" commit-tree "refs/heads/main^{tree}" -p refs/heads/main -m b)"'

OUT=""; ERR=""; CODE=0
run() {
  local reviewed="" reviewed_pid="" reviewed_head="" i
  local -a ship_args=("$@")
  for ((i = 0; i < ${#ship_args[@]}; i++)); do
    if [ "${ship_args[$i]}" = "--reviewed" ]; then
      reviewed="${ship_args[$((i + 1))]}"
      break
    fi
  done
  if [ -n "$reviewed" ]; then
    reviewed_pid="$(git -C "$WT" diff "origin/main...$reviewed" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}' || true)"
    [ -n "$reviewed_pid" ] || reviewed_pid=none
    reviewed_head="$(git -C "$WT" rev-parse "$reviewed" 2>/dev/null || true)"
  fi
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
      if [[ " $* " == *" push "* ]]; then printf 'git %s\n' "$*" >>"$ST/push.log"; fi
      if [ -e "$ST/delete-fails" ] && [[ " $* " == *" push origin --delete "* ]]; then
        echo "error: cannot lock ref 'refs/remotes/origin/feature': unable to resolve reference" >&2
        exit 1
      fi
      command git "$@"
    )
    export -f git
    SHIP_TEST_REVIEW_PID="$reviewed_pid" SHIP_TEST_REVIEW_HEAD="$reviewed_head" bash "$SHIP" "$@" 2>"$S/stderr.txt"
  )"; CODE=$?
  ERR="$(cat "$S/stderr.txt")"
}
ship() { run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT" "$@"; }
untouched() {
  [ "$(origin_head)" = "$O0" ] || fail "$1: origin branch unchanged"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$W0" ] || fail "$1: worktree HEAD unchanged"
}
expect() { [ "$CODE" = "$1" ] || fail "$2: exit $1 (got $CODE): out=[$OUT] err=[$ERR]"; }
expect_refused() {
  [ "$CODE" = 5 ] || fail "$1: exit $CODE, wants 5"
  [ "$(tail -n 1 <<<"$ERR")" = "ship-pr: refused $1" ] \
    || fail "$1: last stderr line [$(tail -n 1 <<<"$ERR")] wants [ship-pr: refused $1]"
}
no_merge() { ! grep -q '^gh pr \(merge\|ready\)' "$ST/gh.log" 2>/dev/null || fail "$1: no ready or merge call"; }
GATE_PANIC='echo gate-start; echo "thread prune::young_fork panicked at src/prune.rs:42:5:"; echo "assertion left == right failed"; echo "  left: 1"; echo " right: 2"; for i in $(seq 1 25); do echo "gate-tail-$i"; done; exit 1'
assert_gate_panic_failure() {
  local label="$1" gate_file
  grep -q 'panicked at' <<<"$OUT" || fail "$label: panic line printed: [$OUT] err=[$ERR]"
  grep -q 'assertion .*left == right.* failed' <<<"$OUT" || fail "$label: assertion printed: [$OUT] err=[$ERR]"
  grep -q '^  left: 1$' <<<"$OUT" || fail "$label: left value printed: [$OUT] err=[$ERR]"
  grep -q '^ right: 2$' <<<"$OUT" || fail "$label: right value printed: [$OUT] err=[$ERR]"
  grep -q '^gate-tail-6$' <<<"$OUT" || fail "$label: last 20 lines printed: [$OUT] err=[$ERR]"
  grep -q '^gate-tail-5$' <<<"$OUT" && fail "$label: output before the last 20 lines omitted: [$OUT] err=[$ERR]"
  gate_file="$(sed -n 's/^full gate output: //p' <<<"$OUT")"
  case "$gate_file" in "$TMPDIR"/ship-pr-7-gate.*) ;; *) fail "$label: named log path printed: [$gate_file] err=[$ERR]" ;; esac
  [ -f "$gate_file" ] || fail "$label: full output file exists: [$gate_file] err=[$ERR]"
  [ "$(wc -l <"$gate_file" | tr -d ' ')" = 30 ] || fail "$label: file holds all 30 output lines: [$(wc -l <"$gate_file")] err=[$ERR]"
  grep -qx 'gate-start' "$gate_file" || fail "$label: file holds the first line err=[$ERR]"
  grep -q 'panicked at' "$gate_file" || fail "$label: file holds the panic err=[$ERR]"
  for i in $(seq 1 25); do grep -qx "gate-tail-$i" "$gate_file" || fail "$label: file is missing gate-tail-$i err=[$ERR]"; done
  rm -f "$gate_file"
}

# ===== a switchyard merge fast-forwards only a clean ~/.agents checkout
setup
rm -rf "$HOME/.agents"
git clone -q "$ORIGIN" "$HOME/.agents"
AGENTS_HEAD0="$(git -C "$HOME/.agents" rev-parse HEAD)"
echo keep >"$HOME/.agents/untracked-note"
merge_once 'git --git-dir="$ORIGIN" update-ref refs/heads/main refs/heads/feature'
run 7 --repo aakshintala/switchyard --reviewed "$HEAD0" --worktree "$WT" --keep-branch
expect 0 "switchyard merge fast-forwards clean ~/.agents"
[ "$(git -C "$HOME/.agents" branch --show-current)" = main ] || fail "agents clean: remains on main"
AGENTS_MAIN="$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)"
[ "$(git -C "$HOME/.agents" rev-parse HEAD)" = "$AGENTS_MAIN" ] || fail "agents clean: fast-forwarded to main"
[ "$(git -C "$HOME/.agents" rev-parse HEAD)" != "$AGENTS_HEAD0" ] || fail "agents clean: HEAD advanced"
[ -f "$HOME/.agents/untracked-note" ] || fail "agents clean: untracked file is preserved"
! grep -q 'not fast-forwarded' <<<"$ERR" || fail "agents clean: no warning: [$ERR]"
OLD_SHORT="$(git -C "$HOME/.agents" rev-parse --short "$AGENTS_HEAD0")"
NEW_SHORT="$(git -C "$HOME/.agents" rev-parse --short "$AGENTS_MAIN")"
grep -Fq "$HOME/.agents: fast-forwarded $OLD_SHORT -> $NEW_SHORT" <<<"$ERR" || fail "agents clean: fast-forward line with SHAs: [$ERR]"
grep -Fq "(1 commits)" <<<"$ERR" || fail "agents clean: fast-forward line with count: [$ERR]"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "agents clean: switchyard merge still succeeds: [$OUT]"

setup
rm -rf "$HOME/.agents"
git clone -q "$ORIGIN" "$HOME/.agents"
git -C "$HOME/.agents" merge -q --ff-only origin/feature
AGENTS_HEAD0="$(git -C "$HOME/.agents" rev-parse HEAD)"
merge_once 'git --git-dir="$ORIGIN" update-ref refs/heads/main refs/heads/feature'
run 7 --repo aakshintala/switchyard --reviewed "$HEAD0" --worktree "$WT" --keep-branch
expect 0 "switchyard merge leaves current ~/.agents quiet"
[ "$(git -C "$HOME/.agents" rev-parse HEAD)" = "$AGENTS_HEAD0" ] || fail "agents current: HEAD stays put"
! grep -q 'fast-forwarded' <<<"$ERR" || fail "agents current: no fast-forward line: [$ERR]"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "agents current: switchyard merge still succeeds: [$OUT]"

setup
rm -rf "$HOME/.agents"
git clone -q "$ORIGIN" "$HOME/.agents"
AGENTS_HEAD0="$(git -C "$HOME/.agents" rev-parse HEAD)"
echo dirty >"$HOME/.agents/file.txt"
merge_once 'git --git-dir="$ORIGIN" update-ref refs/heads/main refs/heads/feature'
run 7 --repo aakshintala/switchyard --reviewed "$HEAD0" --worktree "$WT" --keep-branch
expect 0 "switchyard merge leaves dirty ~/.agents alone"
[ "$(git -C "$HOME/.agents" rev-parse HEAD)" = "$AGENTS_HEAD0" ] || fail "agents dirty: HEAD stays put"
[ "$(cat "$HOME/.agents/file.txt")" = dirty ] || fail "agents dirty: tracked change stays put"
grep -Fq "$HOME/.agents" <<<"$ERR" && grep -q 'behind 1 commit' <<<"$ERR" \
  || fail "agents dirty: warning names checkout and lag: [$ERR]"
! grep -q ': fast-forwarded ' <<<"$ERR" || fail "agents dirty: no success line: [$ERR]"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "agents dirty: switchyard merge still succeeds: [$OUT]"

setup
rm -rf "$HOME/.agents"
git clone -q "$ORIGIN" "$HOME/.agents"
AGENTS_HEAD0="$(git -C "$HOME/.agents" rev-parse HEAD)"
git -C "$HOME/.agents" checkout -q -b other
merge_once 'git --git-dir="$ORIGIN" update-ref refs/heads/main refs/heads/feature'
run 7 --repo aakshintala/switchyard --reviewed "$HEAD0" --worktree "$WT" --keep-branch
expect 0 "switchyard merge leaves another ~/.agents branch alone"
[ "$(git -C "$HOME/.agents" branch --show-current)" = other ] || fail "agents branch: remains on other"
[ "$(git -C "$HOME/.agents" rev-parse HEAD)" = "$AGENTS_HEAD0" ] || fail "agents branch: HEAD stays put"
grep -Fq "$HOME/.agents" <<<"$ERR" && grep -q 'behind 1 commit' <<<"$ERR" \
  || fail "agents branch: warning names checkout and lag: [$ERR]"
! grep -q ': fast-forwarded ' <<<"$ERR" || fail "agents branch: no success line: [$ERR]"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "agents branch: switchyard merge still succeeds: [$OUT]"

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

# ===== exit 3: merge conflict aborts cleanly
setup
echo changed >"$WT/file.txt"; git -C "$WT" commit -qam "touch file"; git -C "$WT" push -q origin feature
HEAD0="$(git -C "$WT" rev-parse HEAD)"
advance_main file.txt conflicting
ship; expect 3 "merge conflict"; untouched "merge conflict"
[ ! -e "$(git -C "$WT" rev-parse --git-path MERGE_HEAD)" ] || fail "conflict leaves no MERGE_HEAD"
[ -z "$(git -C "$WT" status --porcelain)" ] || fail "conflict leaves a clean tree"
no_merge "conflict"

# A later clean merge keeps an earlier conflict-resolution merge commit intact.
setup
echo feature >"$WT/file.txt"; git -C "$WT" commit -qam "touch file"; git -C "$WT" push -q origin feature
advance_main file.txt conflicting
git -C "$WT" fetch -q origin main
if git -C "$WT" merge --no-edit origin/main >/dev/null 2>&1; then
  fail "conflict-resolution fixture creates a conflict"
fi
echo resolved >"$WT/file.txt"; git -C "$WT" add file.txt
git -C "$WT" commit -qm "merge main and resolve conflict"
git -C "$WT" push -q origin feature
HEAD0="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" rev-parse --verify "$HEAD0^2" >/dev/null || fail "conflict resolution is a merge commit"
advance_main other.txt unrelated
MAIN1="$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)"
ship; expect 0 "strict merge preserves an earlier conflict resolution"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "resolved merge still merges: [$OUT]"
PIN="$(sed -n 's/.*--match-head-commit //p' "$ST/gh.log")"
git --git-dir="$ORIGIN" cat-file -p "$PIN" | grep -qx "parent $HEAD0" \
  || fail "new merge keeps the previous conflict-resolution head as a parent"
git --git-dir="$ORIGIN" cat-file -p "$PIN" | grep -qx "parent $MAIN1" \
  || fail "new merge includes the latest main as a parent"

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

# ===== the last review-pr verdict for --reviewed must approve before merge
setup
REVIEW_PID="$(git -C "$WT" diff "origin/main...$HEAD0" | git patch-id --stable | awk '{print $1}')"
jq -nc --arg pid "$REVIEW_PID" --arg head "$HEAD0" '[
  {created_at:"2026-11-04T12:00:00Z",id:103,body:("review-pr: patch-id ffffffffffffffffffffffffffffffffffffffff, head " + $head + "\n\n## standards (test)\n\nVERDICT standards: APPROVE")},
  {created_at:"2026-11-04T11:00:00Z",id:102,body:("review-pr: patch-id " + $pid + ", head " + $head + "\n\n## standards (test)\n\nVERDICT standards: APPROVE\n\n## spec (test)\n\nVERDICT spec: CHANGES\n\nP1 finding remains open")},
  {created_at:"2026-11-04T10:00:00Z",id:101,body:("review-pr: patch-id " + $pid + ", head " + $head + "\n\n## standards (test)\n\nVERDICT standards: APPROVE\n\n## spec (test)\n\nVERDICT spec: APPROVE")}
]' >"$ST/review-comments"
ship; expect 5 "last CHANGES verdict refuses merge"; expect_refused REVIEW; no_merge "last CHANGES verdict"
grep -q 'review' <<<"$ERR" || fail "review refusal explains the missing approval: [$ERR]"

setup
REVIEW_PID="$(git -C "$WT" diff "origin/main...$HEAD0" | git patch-id --stable | awk '{print $1}')"
jq -nc --arg pid "$REVIEW_PID" --arg head "$HEAD0" '[
  {created_at:"2026-11-04T11:00:00Z",id:104,body:("review-pr: patch-id " + $pid + ", head " + $head + "\n\n## verify (test)\n\nFIX-OK all findings repaired")}
]' >"$ST/review-comments"
ship; expect 0 "scoped FIX-OK verdict permits merge"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "scoped FIX-OK still merges: [$OUT]"

setup
REVIEW_PID="$(git -C "$WT" diff "origin/main...$HEAD0" | git patch-id --stable | awk '{print $1}')"
jq -nc --arg pid "$REVIEW_PID" --arg head "$HEAD0" '[
  {created_at:"2026-11-04T11:00:00Z",id:105,body:("review-pr: patch-id " + $pid + ", head " + $head + "\n\n## spec (test)\n\nVERDICT spec: CHANGES")}
]' >"$ST/review-comments"
echo 'P2: no real bug; keep the test finding' >"$T/no-real-bug.txt"
echo changed >>"$WT/feature.txt"; git -C "$WT" commit -qam "address review nit"; git -C "$WT" push -q origin feature
run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT" --unverified-fixes "$T/no-real-bug.txt"
expect 0 "--unverified-fixes still ships a no-real-bug CHANGES round"
grep -q '^gh pr merge' "$ST/gh.log" || fail "no-real-bug CHANGES round merged"
grep -q '^Fixes since .* shipped without re-review' "$ST/comment.txt" || fail "no-real-bug CHANGES round records the fix"

setup
REVIEW_PID="$(git -C "$WT" diff "origin/main...$HEAD0" | git patch-id --stable | awk '{print $1}')"
jq -nc --arg pid "$REVIEW_PID" --arg head "$HEAD0" '[
  {created_at:"2026-11-04T11:00:00Z",id:106,body:("review-pr: patch-id " + $pid + ", head " + $head + "\n\n## verify (test)\n\nFIX-INCOMPLETE repair not present")}
]' >"$ST/review-comments"
echo changed >>"$WT/feature.txt"; git -C "$WT" commit -qam "address ruled finding"; git -C "$WT" push -q origin feature
run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT"
expect 5 "FIX-INCOMPLETE without --unverified-fixes refuses merge"; expect_refused REVIEW; no_merge "FIX-INCOMPLETE without the option"

# A scoped FIX-INCOMPLETE passes only when the posted verify findings are readable,
# non-empty and exclusively P3; ship-pr files/reuses each issue and links it from PR.
setup
REVIEW_PID="$(git -C "$WT" diff "origin/main...$HEAD0" | git patch-id --stable | awk '{print $1}')"
jq -nc --arg pid "$REVIEW_PID" --arg head "$HEAD0" '[
  {created_at:"2026-11-04T11:00:00Z",id:108,body:("review-pr: patch-id " + $pid + ", head " + $head + "\n\n## verify (test)\n\nFIX-INCOMPLETE findings remain\n**P3** first open finding\nP3 second open finding")}
]' >"$ST/review-comments"
ship; expect 0 "FIX-INCOMPLETE with only P3 findings merges"
[ "$(jq 'length' "$ST/created-issues")" = 2 ] || fail "one issue filed per P3: [$(cat "$ST/created-issues")]"
jq -e '.[0].body | contains("P3 first open finding")' "$ST/created-issues" >/dev/null \
  || fail "first P3 is in its issue body: [$(cat "$ST/created-issues")]"
! jq -e '.[0].body | contains("**P3**")' "$ST/created-issues" >/dev/null \
  || fail "bold P3 finding is stored normalized: [$(cat "$ST/created-issues")]"
jq -e '.[1].body | contains("P3 second open finding")' "$ST/created-issues" >/dev/null \
  || fail "second P3 is in its issue body: [$(cat "$ST/created-issues")]"
grep -qF 'issues/200' "$ST/comment.txt" && grep -qF 'issues/201' "$ST/comment.txt" \
  || fail "both P3 issues are linked from the PR: [$(cat "$ST/comment.txt")]"
grep -qF 'P3 first open finding' "$ST/comment.txt" && grep -qF 'P3 second open finding' "$ST/comment.txt" \
  || fail "PR comment names both P3 findings: [$(cat "$ST/comment.txt")]"
[ "$(grep -n '^gh issue create' "$ST/gh.log" | head -n 1 | cut -d: -f1)" -lt \
  "$(grep -n '^gh pr comment' "$ST/gh.log" | tail -n 1 | cut -d: -f1)" ] \
  || fail "issues are created before the linking comment"
[ "$(grep -n '^gh pr comment' "$ST/gh.log" | tail -n 1 | cut -d: -f1)" -lt \
  "$(grep -n '^gh pr merge' "$ST/gh.log" | head -n 1 | cut -d: -f1)" ] \
  || fail "P3 issues are linked before the merge"

# A decorated verify heading is normalised the same way as review-pr's parser.
setup
REVIEW_PID="$(git -C "$WT" diff "origin/main...$HEAD0" | git patch-id --stable | awk '{print $1}')"
jq -nc --arg pid "$REVIEW_PID" --arg head "$HEAD0" '[
  {created_at:"2026-11-04T11:00:00Z",id:114,body:("review-pr: patch-id " + $pid + ", head " + $head + "\n\n**## verify**\n\nFIX-INCOMPLETE one finding remains\nP3 decorated-heading finding")}
]' >"$ST/review-comments"
ship; expect 0 "decorated verify heading opens the P3 findings section"
[ "$(jq 'length' "$ST/created-issues")" = 1 ] || fail "decorated verify heading files its P3 finding: [$(cat "$ST/created-issues")]"
jq -e '.[0].body | contains("P3 decorated-heading finding")' "$ST/created-issues" >/dev/null \
  || fail "decorated verify heading keeps the finding: [$(cat "$ST/created-issues")]"

# The P3 issue side effect is deferred until CI and every other refusal check pass.
setup
REVIEW_PID="$(git -C "$WT" diff "origin/main...$HEAD0" | git patch-id --stable | awk '{print $1}')"
jq -nc --arg pid "$REVIEW_PID" --arg head "$HEAD0" '[
  {created_at:"2026-11-04T11:00:00Z",id:112,body:("review-pr: patch-id " + $pid + ", head " + $head + "\n\n## verify (test)\n\nFIX-INCOMPLETE one finding remains\nP3 non-blocking finding")}
]' >"$ST/review-comments"
echo '[{"bucket":"fail","name":"ci"}]' >"$ST/checks"
ship; expect 1 "P3 findings still wait for passing CI"; no_merge "P3 CI failure"
! grep -q '^gh issue \(list\|create\)' "$ST/gh.log" || fail "CI refusal files no P3 issue"
! grep -q '^gh pr comment' "$ST/gh.log" || fail "CI refusal posts no P3 issue link"

# An open issue with the exact finding line is reused instead of duplicated.
setup
REVIEW_PID="$(git -C "$WT" diff "origin/main...$HEAD0" | git patch-id --stable | awk '{print $1}')"
jq -nc '{number:432,title:"existing P3",body:"P3 existing open finding",url:"https://github.com/O/N/issues/432"}' >"$ST/existing-issue.json"
jq -nc --slurpfile existing "$ST/existing-issue.json" '$existing' >"$ST/issues"
jq -nc --arg pid "$REVIEW_PID" --arg head "$HEAD0" '[
  {created_at:"2026-11-04T11:00:00Z",id:109,body:("review-pr: patch-id " + $pid + ", head " + $head + "\n\n## verify (test)\n\nFIX-INCOMPLETE finding remains\nP3 existing open finding")}
]' >"$ST/review-comments"
ship; expect 0 "matching open P3 issue is reused"
[ "$(jq 'length' "$ST/created-issues" 2>/dev/null || echo 0)" = 0 ] || fail "no duplicate P3 issue filed"
grep -qF 'issues/432' "$ST/comment.txt" || fail "existing P3 issue linked from PR: [$(cat "$ST/comment.txt")]"

# The shape of PR #1353's verify: prose naming a fixed P2 is not an open finding.
setup
REVIEW_PID="$(git -C "$WT" diff "origin/main...$HEAD0" | git patch-id --stable | awk '{print $1}')"
jq -nc --arg pid "$REVIEW_PID" --arg head "$HEAD0" '[
  {created_at:"2026-11-04T11:00:00Z",id:113,body:("review-pr: patch-id " + $pid + ", head " + $head + "\n\n## verify (test)\n\nThe P2 ownership finding is fixed. No new findings.\n\nFIX-INCOMPLETE\n\nP3 bin/x:1 duplicated code remains\n\nSTATUS: DONE_WITH_CONCERNS")}
]' >"$ST/review-comments"
ship; expect 0 "prose naming a fixed P2 does not block a P3-only verify"
jq -e '.[0].body | contains("P3 bin/x:1 duplicated code remains")' "$ST/created-issues" >/dev/null \
  || fail "P3 from #1353-shaped verify is filed: [$(cat "$ST/created-issues")]"

# Any P1 or P2 in readable findings keeps the refusal and files no issues.
for priority in P1 P2; do
  setup
  REVIEW_PID="$(git -C "$WT" diff "origin/main...$HEAD0" | git patch-id --stable | awk '{print $1}')"
  jq -nc --arg pid "$REVIEW_PID" --arg head "$HEAD0" --arg priority "$priority" '[
    {created_at:"2026-11-04T11:00:00Z",id:110,body:("review-pr: patch-id " + $pid + ", head " + $head + "\n\n## verify (test)\n\nFIX-INCOMPLETE mixed findings\nP3 non-blocking finding\n" + $priority + " blocking finding")}
  ]' >"$ST/review-comments"
  ship; expect 5 "FIX-INCOMPLETE with $priority still refuses"; expect_refused REVIEW; no_merge "FIX-INCOMPLETE with $priority"
  ! grep -q '^gh issue \(list\|create\)' "$ST/gh.log" || fail "$priority refusal files no issue"
  ! grep -q '^gh pr comment' "$ST/gh.log" || fail "$priority refusal posts no issue links"
done

# Markup and numbering must not hide P0-P2 findings from the fail-closed parser.
for finding in '**P2** bold finding' '`P1` backticked finding' '1. P2 numbered finding' '- P2 bulleted finding'; do
  setup
  REVIEW_PID="$(git -C "$WT" diff "origin/main...$HEAD0" | git patch-id --stable | awk '{print $1}')"
  jq -nc --arg pid "$REVIEW_PID" --arg head "$HEAD0" --arg finding "$finding" '[
    {created_at:"2026-11-04T11:00:00Z",id:111,body:("review-pr: patch-id " + $pid + ", head " + $head + "\n\n## verify (test)\n\nFIX-INCOMPLETE unreadable findings\nP3 visible finding\n" + $finding)}
  ]' >"$ST/review-comments"
  ship; expect 5 "FIX-INCOMPLETE with $finding refuses"; expect_refused REVIEW; no_merge "marked-up FIX-INCOMPLETE finding"
  ! grep -q '^gh issue \(list\|create\)' "$ST/gh.log" || fail "unreadable findings file no issue"
done

setup
REVIEW_PID="$(git -C "$WT" diff "origin/main...$HEAD0" | git patch-id --stable | awk '{print $1}')"
jq -nc --arg pid "$REVIEW_PID" --arg head "$HEAD0" '[
  {created_at:"2026-11-04T11:00:00Z",id:107,body:("review-pr: patch-id " + $pid + ", head " + $head + "\n\n## verify (test)\n\nFIX-INCOMPLETE repair not present")}
]' >"$ST/review-comments"
echo changed >>"$WT/feature.txt"; git -C "$WT" commit -qam "address ruled finding"; git -C "$WT" push -q origin feature
run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT" --unverified-fixes "$T/no-real-bug.txt"
expect 0 "FIX-INCOMPLETE with --unverified-fixes ships the unverified path"
grep -q '^gh pr merge' "$ST/gh.log" || fail "FIX-INCOMPLETE unverified path merged"

# ===== patch-id ignores context lines: a clean merge over a main commit that
# ===== touched only the neighbouring line keeps the reviewed patch-id, while
# ===== a changed added line still mismatches
setup
printf 'A\nb\nc\n' >"$WT/file.txt"
git -C "$WT" commit -qam "PR changes line 1"; git -C "$WT" push -q origin feature
HEAD0="$(git -C "$WT" rev-parse HEAD)"
REVIEWED_PID="$(git -C "$WT" diff -U0 "origin/main...$HEAD0" | git patch-id --stable | awk '{print $1}')"
advance_main file.txt "$(printf 'a\nb\nC')"
ship; expect 0 "clean merge over a context-only change keeps the reviewed patch-id"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "context-only change still merges: [$OUT]"
PIN="$(sed -n 's/.*--match-head-commit //p' "$ST/gh.log")"
PIN_PID="$(git --git-dir="$ORIGIN" diff -U0 refs/heads/main..."$PIN" | git patch-id --stable | awk '{print $1}')"
[ "$PIN_PID" = "$REVIEWED_PID" ] || fail "clean merge patch-id matches reviewed patch: reviewed=$REVIEWED_PID merged=$PIN_PID"

setup
printf 'A\nb\nc\n' >"$WT/file.txt"
git -C "$WT" commit -qam "PR changes line 1"; git -C "$WT" push -q origin feature
HEAD0="$(git -C "$WT" rev-parse HEAD)"
printf 'A2\nb\nc\n' >"$WT/file.txt"
git -C "$WT" commit -q --amend --no-edit -a
git -C "$WT" push -q --force-with-lease origin HEAD:refs/heads/feature
ship; expect 4 "changed added line exits 4"
no_merge "changed added line"

# ===== exit 1: gate
setup
export CARGO_SLOTS=1 CARGO_SLOT_DIR="$T/cargo-slots" CARGO_SLOT_TEST_CORES=12
ship --gate 'cargo nextest run'; expect 0 "nextest gate takes a cargo slot"
unset CARGO_SLOTS CARGO_SLOT_DIR CARGO_SLOT_TEST_CORES
[ "$(cat "$ST/cargo-held")" = "held=1" ] || fail "ship-pr gate cargo did not hold a slot"
[ "$(cat "$ST/cargo-threads")" = "threads=12" ] || fail "ship-pr gate nextest did not get the per-slot thread cap"

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
ship --gate 'test ! -e other.txt'; expect 0 "gate runs on the pre-merge head"
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
fake_df "$S/bin" 50000 /fake
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
ship; expect 1 "failing CI"; untouched "failing CI, no merge, no push"
grep -q '^failing: ci$' <<<"$OUT" || fail "failing line printed: [$OUT]"
grep -qx "gh-ci: ${HEAD0:0:8} pending=0 passed=0 failing=1" <<<"$ERR" || fail "gh-ci progress reaches ship-pr stderr: [$ERR]"
grep -q 'pending' <<<"$OUT" && fail "progress stays off ship-pr stdout: [$OUT]"
no_merge "failing CI"
[ -d "$WT" ] || fail "worktree kept after failing CI"

setup; echo DIRTY >"$ST/merge-state"
ship; expect 3 "conflict after the push"; no_merge "conflict after the push"
grep -q "PR conflicts with origin/main after the push; merge origin/main again, then rerun" <<<"$ERR" || fail "conflict message: [$ERR]"
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
MAIN1="$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)"
checks_hook 'git --git-dir="$ORIGIN" rev-parse refs/heads/feature >"$ST/at-ci"'
ship; expect 0 "moved strict main is merged into the branch"
PIN="$(sed -n 's/.*--match-head-commit //p' "$ST/gh.log")"
[ "$(cat "$ST/at-ci")" = "$PIN" ] || fail "origin branch is the merged head before the CI wait"
[ "$PIN" != "$HEAD0" ] || fail "the merge moved HEAD"
git --git-dir="$ORIGIN" cat-file -p "$PIN" | grep -qx "parent $HEAD0" || fail "merge keeps the reviewed head as a parent"
git --git-dir="$ORIGIN" cat-file -p "$PIN" | grep -qx "parent $MAIN1" || fail "merge includes moved origin/main as a parent"
git --git-dir="$ORIGIN" merge-base --is-ancestor "$O0" "$PIN" || fail "push is a fast-forward from the previous remote head"
grep -Fq ' push origin HEAD:refs/heads/feature' "$ST/push.log" || fail "merge is pushed without force: [$(cat "$ST/push.log")]"
! grep -q -- '--force-with-lease' "$ST/push.log" || fail "ship-pr never force-pushes: [$(cat "$ST/push.log")]"

setup; checks_hook 'git --git-dir="$ORIGIN" update-ref refs/heads/feature "$(git --git-dir="$ORIGIN" commit-tree "refs/heads/feature^{tree}" -p refs/heads/feature -m b)"'
ship; expect 1 "CI passes on a moved head"; no_merge "moved head"
grep -q 'other than' <<<"$ERR" || fail "moved head message: [$ERR]"

# main moving during the CI wait sends ship-pr back to merge origin/main, at most 3 times
setup; checks_hook "$BUMP_MAIN"
ship; expect 0 "main moves once during CI"
grep -q 'origin/main moved during CI; merging again (retry 1 of 3)' <<<"$ERR" || fail "retry message: [$ERR]"
PIN="$(sed -n 's/.*--match-head-commit //p' "$ST/gh.log")"
[ -n "$PIN" ] && git --git-dir="$ORIGIN" merge-base --is-ancestor refs/heads/main "$PIN" \
  || fail "merge pinned to a head that descends from the moved main: [$PIN]"
[ "$(grep -c 'check-runs' "$ST/gh.log")" -eq 2 ] || fail "two CI waits"

# a retry pushes the merge commit as a fast-forward from the first pushed head
setup; advance_main other.txt o; checks_hook "$BUMP_MAIN"
ship; expect 0 "initial merge, then main moves during CI"
grep -q 'retry 1 of 3' <<<"$ERR" || fail "retry after an initial merge: [$ERR]"

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
[ ! -e "$(git -C "$WT" rev-parse --git-path MERGE_HEAD)" ] || fail "retry conflict leaves no MERGE_HEAD"
[ -z "$(git -C "$WT" status --porcelain)" ] || fail "retry conflict leaves a clean tree"

setup
sed -i.bak 1s/a/x/ "$WT/file.txt"; rm "$WT/file.txt.bak"
git -C "$WT" commit -qam "edit line 1"; git -C "$WT" push -q origin feature
HEAD0="$(git -C "$WT" rev-parse HEAD)"
checks_hook 'sed -i.bak 3s/c/z/ "$C/file.txt"; rm "$C/file.txt.bak"; git -C "$C" commit -qam m; git -C "$C" push -q origin main'
ship; expect 0 "main moves during CI with a clean merge that changes only context"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "context-only merge on retry still merges: [$OUT]"

setup; checks_hook 'echo n >"$C/newfile.txt"; git -C "$C" add .; git -C "$C" commit -qm m; git -C "$C" push -q origin main'
ship --gate 'test ! -e newfile.txt && echo x >>"$ST/gates"'; expect 0 "gate runs once, not again after a merge"
[ "$(wc -l <"$ST/gates")" -eq 1 ] || fail "gate ran exactly once"
[ "$(grep -c 'check-runs' "$ST/gh.log")" -eq 2 ] || fail "2 CI waits"
mh="$(grep -o 'match-head-commit [0-9a-f]*' "$ST/gh.log" | awk '{print $2}')"
git --git-dir="$ORIGIN" merge-base --is-ancestor main "$mh" || fail "merge pinned to a head descending from the moved main"

# ===== strictness of main's required checks decides when ship-pr merges
STRICT_LINE='required checks on main are strict: merging origin/main when it moved'
LOOSE_LINE='required checks on main are not strict: merging only on a conflict'
NOSTRICT='[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"ci"}]}}]'
setup; echo "$NOSTRICT" >"$ST/rules"; advance_main other.txt o
ship --gate 'echo "$NEXTEST_RETRIES" >>"$ST/retries"'
expect 0 "both gate steps enable nextest retries"
[ "$(cat "$ST/retries")" = "1
1" ] || fail "both gate steps see NEXTEST_RETRIES=1: [$(cat "$ST/retries")]"
setup; mkdir -p "$WT/.config"; printf '[profile.ci]\nretries = 0\n' >"$WT/.config/nextest.toml"
git -C "$WT" add .config && git -C "$WT" commit -qm nextest && git -C "$WT" push -q origin feature
HEAD0="$(git -C "$WT" rev-parse HEAD)"; echo "$NOSTRICT" >"$ST/rules"; advance_main other.txt o
NEXTEST_RETRIES=5 ship --gate 'echo "${NEXTEST_RETRIES-unset}" >>"$ST/retries"'
expect 0 "a repo nextest retry policy keeps ship-pr's override off"
[ "$(cat "$ST/retries")" = "unset
unset" ] || fail "a nextest config with retries gets no NEXTEST_RETRIES: [$(cat "$ST/retries")]"
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

# not strict: no merge because main moved without a reported conflict
setup; echo "$NOSTRICT" >"$ST/rules"; advance_main other.txt o
ship; expect 0 "not strict, main moved before ship"
grep -q 'merging feature' <<<"$ERR" && fail "no merge: [$ERR]"
! grep -q 'pushing merged' <<<"$ERR" || fail "no push: [$ERR]"
grep -q "^gh pr merge 7 --repo O/N --squash --match-head-commit $HEAD0\$" "$ST/gh.log" || fail "merge pinned to HEAD0"
[ "$(grep -c 'check-runs' "$ST/gh.log")" -eq 1 ] || fail "one CI wait"

setup; echo "$NOSTRICT" >"$ST/rules"; checks_hook "$BUMP_MAIN"
ship; expect 0 "not strict, main moves during CI"
grep -q 'retry' <<<"$ERR" && fail "no retry: [$ERR]"
grep -q "^gh pr merge 7 --repo O/N --squash --match-head-commit $HEAD0\$" "$ST/gh.log" || fail "merge pinned to HEAD0 after a main move"
[ "$(grep -c 'check-runs' "$ST/gh.log")" -eq 1 ] || fail "one CI wait despite the main move"

# not strict: a reported conflict merges origin/main, before the first push
setup; echo "$NOSTRICT" >"$ST/rules"; echo CONFLICTING >"$ST/mergeable"; advance_main other.txt o
ship --gate 'test ! -e other.txt && echo x >>"$ST/gates"'; expect 0 "not strict, conflict that merges cleanly"
[ "$(wc -l <"$ST/gates")" -eq 1 ] || fail "gate ran once, on the pre-merge head"
mh="$(grep -o 'match-head-commit [0-9a-f]*' "$ST/gh.log" | awk '{print $2}')"
[ "$mh" != "$HEAD0" ] && git --git-dir="$ORIGIN" merge-base --is-ancestor main "$mh" || fail "merge pinned to a head descending from main"
[ "$(grep -c 'check-runs' "$ST/gh.log")" -eq 1 ] || fail "one CI wait after the merge"

setup; echo "$NOSTRICT" >"$ST/rules"; echo CONFLICTING >"$ST/mergeable"; advance_main other.txt o
run 7 --repo O/N --reviewed "$(git -C "$C" rev-parse HEAD)" --worktree "$WT"; expect 4 "not strict, merge checks the patch-id"
no_merge "not strict patch-id"; [ "$(origin_head)" = "$HEAD0" ] || fail "mismatch pushes nothing"

setup; echo "$NOSTRICT" >"$ST/rules"; echo DIRTY >"$ST/merge-state"; advance_main other.txt o
ship; expect 3 "not strict, DIRTY after the merge and push"; no_merge "not strict DIRTY"
grep -q "PR conflicts with origin/main after the push; merge origin/main again, then rerun" <<<"$ERR" || fail "DIRTY message: [$ERR]"
[ "$(origin_head)" != "$HEAD0" ] || fail "DIRTY probe merged and pushed"

setup; echo "$NOSTRICT" >"$ST/rules"; echo UNKNOWN >"$ST/mergeable"; echo UNKNOWN >"$ST/merge-state"; advance_main other.txt o
ship; expect 0 "not strict, UNKNOWN mergeable"
! grep -q "merging feature" <<<"$ERR" || fail "UNKNOWN does not merge: [$ERR]"

setup; echo "$NOSTRICT" >"$ST/rules"; echo CONFLICTING >"$ST/mergeable"
echo changed >"$WT/file.txt"; git -C "$WT" commit -qam "touch file"; git -C "$WT" push -q origin feature
HEAD0="$(git -C "$WT" rev-parse HEAD)"
advance_main file.txt conflicting
ship; expect 3 "not strict, truly conflicting"; untouched "not strict conflict"; no_merge "not strict conflict"
[ ! -e "$(git -C "$WT" rev-parse --git-path MERGE_HEAD)" ] || fail "not strict conflict leaves no MERGE_HEAD"
[ -z "$(git -C "$WT" status --porcelain)" ] || fail "not strict conflict leaves a clean tree"

# the conflicting commit lands during the gate: the conflict probe refetches main first
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

# A merge check on a non-strict base sees main's new file and fails before merge.
setup; echo "$NOSTRICT" >"$ST/rules"; advance_main other.txt o
ship --merge-check 'if [ -e other.txt ]; then for i in $(seq 1 25); do echo gate-tail-$i; done; exit 1; fi'
expect 1 "not strict merge check fails on moved main"
! grep -q '^gh pr merge' "$ST/gh.log" || fail "merge check failure: no merge call"
grep -q '^gate-tail-25$' <<<"$OUT" || fail "merge check failure: last 20 lines printed"
grep -q '^gate-tail-5$' <<<"$OUT" && fail "merge check failure: output before last 20 lines omitted"
grep -q '^full merge check output: ' <<<"$OUT" || fail "merge check failure: saved log path printed"
merge_check_log="$(sed -n 's/^full merge check output: //p' <<<"$OUT")"
case "$merge_check_log" in "$TMPDIR"/ship-pr-7-merge-check.*) ;; *) fail "merge check failure: path identifies the check: [$merge_check_log]" ;; esac
[ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD0" ] || fail "merge check failure: worktree back on pinned head"
[ -z "$(git -C "$WT" status --porcelain)" ] || fail "merge check failure: worktree clean"
[ -d "$WT" ] || fail "merge check failure: worktree kept"

# A passing merge check runs on current main and allows the pinned head to merge.
setup; echo "$NOSTRICT" >"$ST/rules"; advance_main other.txt o
MAIN1="$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)"
ship --merge-check 'test -e other.txt; git rev-parse HEAD >>"$ST/merge-check-heads"'
expect 0 "not strict merge check passes on moved main"
[ "$(wc -l <"$ST/merge-check-heads")" -eq 1 ] || fail "merge check runs once on a moved main"
git -C "$C" merge-base --is-ancestor "$MAIN1" "$(cat "$ST/merge-check-heads")" \
  || fail "merge check passes on the tree with current origin/main"
grep -q "merge check passes on the PR merged with current origin/main" <<<"$ERR" || fail "merge check pass message: [$ERR]"
[ ! -e "$WT" ] || fail "merge check pass: worktree removed"
origin_head >/dev/null && fail "merge check pass: no local merge commit leaks to origin"

# If main moves during a passing check, the check reruns on the new tip.
setup; echo "$NOSTRICT" >"$ST/rules"; advance_main initial.txt before
ship --merge-check 'if [ ! -e "$ST/merge-check-once" ]; then touch "$ST/merge-check-once"; echo moved >"$C/other.txt"; git -C "$C" add .; git -C "$C" commit -qm moved; git -C "$C" push -q origin main; else test -e other.txt; fi; git rev-parse HEAD >>"$ST/merge-check-heads"'
expect 0 "merge check retries after main moves"
[ "$(wc -l <"$ST/merge-check-heads")" -eq 2 ] || fail "merge check reruns once after main moves"
MAIN2="$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)"
git -C "$C" merge-base --is-ancestor "$MAIN2" "$(sed -n 2p "$ST/merge-check-heads")" \
  || fail "merge check retry runs on the new tip"
[ ! -e "$WT" ] || fail "merge check retry pass: worktree removed"

# With both flags, only --gate runs on the merged tree.
setup; echo "$NOSTRICT" >"$ST/rules"; advance_main other.txt o
ship --gate 'if [ -e other.txt ] && [ ! -e "$ST/gate-main-moved" ]; then touch "$ST/gate-main-moved"; echo later >"$C/later.txt"; git -C "$C" add .; git -C "$C" commit -qm later; git -C "$C" push -q origin main; fi; git rev-parse HEAD >>"$ST/gate-heads"' --merge-check 'touch "$ST/merge-check-ran"'
expect 0 "merge check is ignored when gate is set"
[ "$(wc -l <"$ST/gate-heads")" -eq 2 ] || fail "gate runs initially and on merged main without merge-check retries"
[ ! -e "$ST/merge-check-ran" ] || fail "merge check is ignored when gate is set"

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
SHIP_TEST_REVIEW_PID="$(git -C "$WT" diff "origin/main...$HEAD0" | git patch-id --stable | awk '{print $1}')" \
SHIP_TEST_REVIEW_HEAD="$HEAD0" bash "$SHIP" 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT" \
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
grep -q "PR conflicts with current origin/main; merge origin/main, then rerun" <<<"$ERR" || fail "guard conflict message: [$ERR]"
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

# ===== --body-has: required PR body lines, checked before any merge, push or CI call
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
expect_refused BODY
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

# ===== --body-ends: the body's last non-blank line must equal the text
setup
for args in "--body-ends" "--body-ends ''" ; do
  # shellcheck disable=SC2086
  eval "ship $args"; expect 2 "usage [$args]"; untouched "usage [$args]"
  grep -q '^usage: ship-pr' <<<"$ERR" || fail "usage text for [$args]: [$ERR]"
done
ship --body-ends "$(printf 'a\nb')"; expect 2 "newline body-ends"; untouched "newline body-ends"
grep -q '^usage: ship-pr' <<<"$ERR" || fail "usage text for newline body-ends: [$ERR]"
[ ! -e "$ST/gh.log" ] || fail "bad --body-ends makes no gh call"

setup; printf 'Resolves #97\nCo-authored with Claude Code.\n' >"$ST/body"
ship --body-ends 'Co-authored with Claude Code.'; expect 0 "body ends with the line"

setup; printf 'Resolves #97\nCo-authored with Claude Code.\n\n\n' >"$ST/body"
ship --body-ends 'Co-authored with Claude Code.'; expect 0 "trailing blank lines ignored"
setup; printf 'Resolves #97\nCo-authored with Claude Code.\n  \n\t\n' >"$ST/body"
ship --body-ends 'Co-authored with Claude Code.'; expect 0 "trailing whitespace-only lines ignored"
setup; printf 'Resolves #97\r\nCo-authored with Claude Code.\r\n' >"$ST/body"
ship --body-ends 'Co-authored with Claude Code.'; expect 0 "CRLF body ending"
setup; printf 'Resolves #97\nCo-authored with Claude Code.' >"$ST/body"
ship --body-ends 'Co-authored with Claude Code.'; expect 0 "no trailing newline"

setup; printf 'Co-authored with Claude Code.\nDoc friction: none\n' >"$ST/body"
ship --body-ends 'Co-authored with Claude Code.'; nothing_ran "attribution mid-body"
[ "$OUT" = "body does not end with (--body-ends): Co-authored with Claude Code." ] || fail "mid-body printed: [$OUT]"
grep -q 'PR body lacks required lines; edit the PR body, then rerun' <<<"$ERR" || fail "ends message: [$ERR]"

for b in 'Co-authored with Claude Code. ' 'Co-authored with Claude Code.x' 'x Co-authored with Claude Code.' 'co-authored with claude code.'; do
  setup; printf 'Resolves #97\n%s\n' "$b" >"$ST/body"
  ship --body-ends 'Co-authored with Claude Code.'; nothing_ran "no exact match for [$b]"
done

setup; touch "$ST/body-null"
ship --body-ends 'Co-authored with Claude Code.'; nothing_ran "null body"
setup; : >"$ST/body"
ship --body-ends 'Co-authored with Claude Code.'; nothing_ran "empty body"

setup; printf 'Doc friction: none\n' >"$ST/body"
ship --body-has 'Resolves #' --body-ends 'Co-authored with Claude Code.'; nothing_ran "both checks fail"
[ "$OUT" = "missing body line: Resolves #
body does not end with (--body-ends): Co-authored with Claude Code." ] || fail "both lines printed: [$OUT]"

setup; touch "$ST/body-fail"
ship --body-ends 'Co-authored with Claude Code.'; expect 2 "body-ends read failure"; untouched "body-ends read failure"
grep -q 'cannot read PR 7 body' <<<"$ERR" || fail "body-ends read message: [$ERR]"

# ===== --outside-plan: every recorded path needs a one-line reason in its section
setup; printf 'Resolves #97\n' >"$ST/body"
ship --outside-plan 'src/a.go'; nothing_ran "outside-plan path missing"
expect_refused BODY
grep -qxF 'missing outside-plan path: src/a.go' <<<"$OUT" || fail "missing outside-plan path printed: [$OUT]"

setup; printf '## Outside-plan files\n- src/a.go — inspected existing parser\n' >"$ST/body"
ship --outside-plan 'src/a.go' --outside-plan 'src/b.go'; nothing_ran "outside-plan second path missing"
grep -qxF 'missing outside-plan path: src/b.go' <<<"$OUT" || fail "second outside-plan path printed: [$OUT]"

setup; printf '## Outside-plan files\n- src/a.go\n' >"$ST/body"
ship --outside-plan 'src/a.go'; nothing_ran "outside-plan reason missing"
grep -qxF 'outside-plan path has no one-line reason: src/a.go' <<<"$OUT" || fail "missing reason printed: [$OUT]"

setup; printf '## Summary\nNo extra scope.\n\n## Outside-plan files\n- src/a.go — inspected existing parser\n- src/b.go — updated caller for new interface\n\n## Tests\nPassed.\n' >"$ST/body"
ship --outside-plan 'src/a.go' --outside-plan 'src/b.go'; expect 0 "outside-plan paths and reasons listed"

setup; printf '## Outside-plan files\n- src/a.go - checked scope\n' >"$ST/body"
ship --outside-plan 'src/a.go'; expect 0 "outside-plan path accepts spaced hyphen separator"

setup; printf '## Outside-plan files\n- `src/a.go`: checked scope\n' >"$ST/body"
ship --outside-plan 'src/a.go'; expect 0 "outside-plan path accepts backticks and colon separator"

setup; ship; expect 0 "no --body-has"
[ "$(grep -c -- '--json body ' "$ST/gh.log")" -eq 1 ] || fail "no --body-has: one body read, for the authority check: [$(cat "$ST/gh.log")]"

# ===== authority claims: a body or round-closed comment line that claims an
# authority needs a citation on the same line, else exit 5 before any push
comments_json() { jq -nc --arg u "$1" --arg b "$2" '[{html_url: $u, body: $b}]' >"$ST/comments"; }
U7="https://github.com/O/N/pull/7#issuecomment-5"

setup; printf 'Resolves #97\nApproved by the lane.\n' >"$ST/body"
ship; nothing_ran "uncited authority in the body"
grep -qxF 'uncited authority: Approved by the lane.' <<<"$OUT" || fail "uncited body line printed: [$OUT]"
grep -q 'PR text claims authority without a citation on the same line or in the same bullet' <<<"$ERR" || fail "authority message: [$ERR]"
setup; printf 'Resolves #97\nAccepted gap per the owner-side ruling #4069.\n' >"$ST/body"
ship; expect 0 "cited authority in the body"
setup; printf 'Resolves #97\nAccepted gap per the owner-side ruling: behavior remains out of scope; see `test_negative_claim_in_same_pr`.\n' >"$ST/body"
mkdir -p "$WT/test"
printf 'test_negative_claim_in_same_pr() { [ ruled_out = ruled_out ]; }\ntest_negative_claim_in_same_pr\n' >"$WT/test/negative-claim.sh"
git -C "$WT" add test/negative-claim.sh && git -C "$WT" commit -qm add-negative-claim-test && git -C "$WT" push -q origin feature || fail "add test to PR diff"
HEAD0="$(git -C "$WT" rev-parse HEAD)"
ship; expect 0 "negative claim cites a test added by this PR"
setup; printf 'Resolves #97\nAccepted gap per the owner-side ruling: behavior remains out of scope; see `test_absent_from_pr`.\n' >"$ST/body"
ship; nothing_ran "negative claim cites a test absent from the PR"
grep -qxF 'uncited authority: Accepted gap per the owner-side ruling: behavior remains out of scope; see `test_absent_from_pr`.' <<<"$OUT" || fail "absent test citation leaves claim uncited: [$OUT]"
setup; printf 'Resolves #97\nApproved by the owner: test `test_positive_claim_in_same_pr` confirms the ruling.\n' >"$ST/body"
mkdir -p "$WT/test"
printf 'test_positive_claim_in_same_pr() { [ approved = approved ]; }\ntest_positive_claim_in_same_pr\n' >"$WT/test/positive-claim.sh"
git -C "$WT" add test/positive-claim.sh && git -C "$WT" commit -qm add-positive-claim-test && git -C "$WT" push -q origin feature || fail "add positive-claim test to PR diff"
HEAD0="$(git -C "$WT" rev-parse HEAD)"
ship; nothing_ran "positive claim cannot use a test as its citation"
grep -qxF 'uncited authority: Approved by the owner: test `test_positive_claim_in_same_pr` confirms the ruling.' <<<"$OUT" || fail "positive claim still requires authority citation: [$OUT]"
setup; printf 'Resolves #97\nApproved by the lane.\nSee #4069.\n' >"$ST/body"
ship; nothing_ran "authority citation on the next line"
grep -qxF 'uncited authority: Approved by the lane.' <<<"$OUT" || fail "next-line citation did not leave the claim uncited: [$OUT]"
grep -qF 'PR text claims authority without a citation on the same line or in the same bullet; cite it there (#<n>, comment URL or <doc>:<line>) or drop the claim, then rerun' <<<"$ERR" || fail "same-line refusal message: [$ERR]"
setup; printf 'Resolves #97\nWe cite `approved by` as a term.\n> per the ruling, quoted\n' >"$ST/body"
ship; expect 0 "code span and quote in the body"

# A review finding number is not an issue: P2 #2 does not cite, a real #N still does
FINDING='P2 #2 (no nextest run at 2754 terms in CI): accepted gap per the owner-side ruling'
setup; printf 'Resolves #97\n%s\n' "$FINDING" >"$ST/body"
ship; nothing_ran "finding number in the body"
grep -qxF "uncited authority: $FINDING" <<<"$OUT" || fail "finding number line printed: [$OUT]"
setup; printf 'Resolves #97\nP2 #2: accepted gap per #4069 Not established\n' >"$ST/body"
ship; expect 0 "finding number with a real citation"
setup; printf 'Resolves #97\n' >"$ST/body"; comments_json "$U7" "Review round closed on abc123.
$FINDING"
ship; nothing_ran "finding number in a round-closed comment"
grep -qxF "uncited authority: $FINDING (comment $U7)" <<<"$OUT" || fail "finding number comment line: [$OUT]"

# A bullet is one unit with its more indented continuation lines
setup; printf 'Resolves #97\n- Accepted gap per the owner-side ruling;\n  see #4069.\n' >"$ST/body"
ship; expect 0 "bullet cited on a continuation line"
setup; printf 'Resolves #97\n- Accepted gap per the owner-side ruling;\n  no citation here.\n' >"$ST/body"
ship; nothing_ran "bullet with no citation on either line"
grep -qxF 'uncited authority: - Accepted gap per the owner-side ruling;' <<<"$OUT" || fail "bullet first line printed: [$OUT]"
setup; printf 'Resolves #97\n- Accepted gap per the owner-side ruling #4069\n- Approved by the lane.\n' >"$ST/body"
ship; nothing_ran "cited bullet then a separate uncited bullet"
[ "$OUT" = "uncited authority: - Approved by the lane." ] || fail "only the second bullet printed: [$OUT]"
# A blank line inside a loose bullet keeps its citation; an unindented line after it starts a new unit
setup; printf 'Resolves #97\n- Accepted gap per the owner-side ruling;\n\n  see #4069.\n' >"$ST/body"
ship; expect 0 "loose bullet cited after a blank line"
setup; printf 'Resolves #97\n- Accepted gap per the owner-side ruling;\n\nsee #4069.\n' >"$ST/body"
ship; nothing_ran "bullet, blank line, then an unindented citation"
[ "$OUT" = "uncited authority: - Accepted gap per the owner-side ruling;" ] || fail "loose bullet first line printed: [$OUT]"

setup; printf 'Resolves #97\n' >"$ST/body"; comments_json "$U7" 'Review round closed on abc123 with a fix.
Accepted gap per the owner-side ruling.'
ship; nothing_ran "uncited authority in a round-closed comment"
grep -qxF "uncited authority: Accepted gap per the owner-side ruling. (comment $U7)" <<<"$OUT" || fail "uncited comment line names its URL: [$OUT]"

setup; printf 'Resolves #97\n' >"$ST/body"; comments_json "$U7" 'Review round closed on abc123 with a fix.
Accepted gap per the owner-side ruling #4069.'
ship; expect 0 "cited round-closed comment"

# Exempt lines inside a round-closed comment: a quote, a fenced block, a code span
for b in '> per the ruling, quoted' $'\n```\nper the ruling\n```' 'Wording: `approved by` only'; do
  setup; printf 'Resolves #97\n' >"$ST/body"; comments_json "$U7" "Review round closed on abc123.
$b"
  ship; expect 0 "exempt line in a round-closed comment [$b]"
done

# A plain discussion comment is not scanned at all
setup; printf 'Resolves #97\n' >"$ST/body"; comments_json "$U7" 'approved, go ahead. Per the ruling, fine.'
ship; expect 0 "plain discussion comment not scanned"

# ===== PR-head test citation scope =========================================
setup
mkdir -p "$C/test"
cat >"$C/test/deleted-citation.sh" <<'TEST'
test_deleted_test_citation() { :; }
TEST
publish_main_test_fixture
git -C "$WT" rm -q -- test/deleted-citation.sh || fail 'remove deleted citation test'
push_test_change test/deleted-citation.sh delete-test-citation
printf 'Resolves #97\nAccepted gap per the owner-side ruling: out of scope; see `test_deleted_test_citation`.\n' >"$ST/body"
ship; nothing_ran 'deleted test cannot cite a negative claim'
grep -qxF 'uncited authority: Accepted gap per the owner-side ruling: out of scope; see `test_deleted_test_citation`.' <<<"$OUT" \
  || fail "deleted test citation remains uncited: [$OUT]"

setup
mkdir -p "$C/test"
cat >"$C/test/changed-citation.sh" <<'TEST'
test_unchanged_test_in_changed_file() { :; }
marker: before
TEST
publish_main_test_fixture
cat >"$WT/test/changed-citation.sh" <<'TEST'
test_unchanged_test_in_changed_file() { :; }
marker: after
TEST
push_test_change test/changed-citation.sh change-marker
printf 'Resolves #97\nAccepted gap per the owner-side ruling: out of scope; see `test_unchanged_test_in_changed_file`.\n' >"$ST/body"
ship; expect 0 'unchanged test in a changed file cites a negative claim'

setup
mkdir -p "$WT/test"
printf 'test_space_path_citation() { :; }\n' >"$WT/test/citation with spaces.sh"
push_test_change 'test/citation with spaces.sh' add-space-path-test
printf 'Resolves #97\nAccepted gap per the owner-side ruling: out of scope; see `test_space_path_citation`.\n' >"$ST/body"
ship; expect 0 'a test in a changed path with spaces cites a negative claim'

setup
mkdir -p "$C/test"
printf 'test_split_path_citation() { :; }\n' >"$C/test/untouched-citation.sh"
publish_main_test_fixture
mkdir -p "$WT/test/split"$'\036'"test"
printf 'marker\n' >"$WT/test/split"$'\036'"test/untouched-citation.sh"
push_test_change "test/split"$'\036'"test/untouched-citation.sh" add-control-char-path
printf 'Resolves #97\nAccepted gap per the owner-side ruling: out of scope; see `test_split_path_citation`.\n' >"$ST/body"
ship; nothing_ran 'a control character in a changed path does not widen the citation scope'

setup
mkdir -p "$C/test"
cat >"$C/test/untouched-citation.sh" <<'TEST'
test_in_untouched_file() { :; }
TEST
cat >"$C/test/changed-marker.sh" <<'TEST'
marker: before
TEST
publish_main_test_fixture
printf 'marker: after\n' >"$WT/test/changed-marker.sh"
push_test_change test/changed-marker.sh change-marker
printf 'Resolves #97\nAccepted gap per the owner-side ruling: out of scope; see `test_in_untouched_file`.\n' >"$ST/body"
ship; nothing_ran 'test in an untouched file cannot cite a negative claim'
grep -qxF 'uncited authority: Accepted gap per the owner-side ruling: out of scope; see `test_in_untouched_file`.' <<<"$OUT" \
  || fail "untouched test citation remains uncited: [$OUT]"

setup
mkdir -p "$WT/test"
printf 'test_bullet_continuation_citation() { :; }\n' >"$WT/test/bullet-citation.sh"
git -C "$WT" add -- test/bullet-citation.sh && git -C "$WT" commit -qm add-bullet-citation-test \
  && git -C "$WT" push -q origin feature || fail 'add bullet continuation test'
HEAD0="$(git -C "$WT" rev-parse HEAD)"
printf 'Resolves #97\n- Accepted gap per the owner-side ruling: out of scope.\n  See `test_bullet_continuation_citation`.\n' >"$ST/body"
ship; expect 0 'test citation on the same bullet continuation line'

setup
mkdir -p "$WT/test"
printf 'test_citation_in_next_bullet() { :; }\n' >"$WT/test/next-bullet-citation.sh"
git -C "$WT" add -- test/next-bullet-citation.sh && git -C "$WT" commit -qm add-next-bullet-test \
  && git -C "$WT" push -q origin feature || fail 'add next-bullet citation test'
HEAD0="$(git -C "$WT" rev-parse HEAD)"
printf 'Resolves #97\n- Accepted gap per the owner-side ruling: out of scope.\n- See `test_citation_in_next_bullet`.\n' >"$ST/body"
ship; nothing_ran 'test citation in the next bullet is separate'
grep -qxF 'uncited authority: - Accepted gap per the owner-side ruling: out of scope.' <<<"$OUT" \
  || fail "next-bullet citation leaves claim uncited: [$OUT]"

setup
mkdir -p "$WT/test"
printf 'test_citation_in_next_paragraph() { :; }\n' >"$WT/test/next-paragraph-citation.sh"
git -C "$WT" add -- test/next-paragraph-citation.sh && git -C "$WT" commit -qm add-next-paragraph-test \
  && git -C "$WT" push -q origin feature || fail 'add next-paragraph citation test'
HEAD0="$(git -C "$WT" rev-parse HEAD)"
printf 'Resolves #97\nAccepted gap per the owner-side ruling: out of scope.\nSee `test_citation_in_next_paragraph`.\n' >"$ST/body"
ship; nothing_ran 'test citation in the next paragraph is separate'
grep -qxF 'uncited authority: Accepted gap per the owner-side ruling: out of scope.' <<<"$OUT" \
  || fail "next-paragraph citation leaves claim uncited: [$OUT]"

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

# A run already green on the head must not satisfy the wait triggered by ready.
setup; echo true >"$ST/draft"; touch "$ST/late-ready-run"
jq -nc --arg h "$HEAD0" '[{databaseId:700,name:"CI (draft)",event:"pull_request",headSha:$h,status:"completed",conclusion:"success"}]' >"$ST/run-list-before-ready.json"
jq -nc --arg h "$HEAD0" '[{databaseId:700,name:"CI (draft)",event:"pull_request",headSha:$h,status:"completed",conclusion:"success"},{databaseId:701,name:"CI",event:"pull_request",headSha:$h,status:"in_progress",conclusion:null}]' >"$ST/run-list-after-ready.json"
ship --keep-branch; expect 0 "ready waits for its late run"
[ ! -e "$ST/merged-before-late-run-finished" ] || fail "ready run: merged before the ready_for_review run finished"
[ -e "$ST/late-ready-run-completed" ] || fail "ready run: new run completed before merge"
grep -q 'gh run view 701' "$ST/gh.log" || fail "ready run: explicitly waited on late pull_request run: [$(cat "$ST/gh.log")]"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "ready run: merge succeeded: [$OUT]"

# Ready starts two runs: 701 is listed first and finishes at once; 702, which
# carries the required check, is listed only on the next call and finishes later.
setup; echo true >"$ST/draft"; touch "$ST/late-ready-run"; echo 702 >"$ST/late-ready-run-id"
jq -nc --arg h "$HEAD0" '[{databaseId:700,name:"CI (draft)",event:"pull_request",headSha:$h,status:"completed",conclusion:"success"}]' >"$ST/run-list-before-ready.json"
jq -nc --arg h "$HEAD0" '[{databaseId:700,name:"CI (draft)",event:"pull_request",headSha:$h,status:"completed",conclusion:"success"},{databaseId:701,name:"Lint",event:"pull_request",headSha:$h,status:"in_progress",conclusion:null}]' >"$ST/run-list-after-ready.json"
jq -nc --arg h "$HEAD0" '[{databaseId:700,name:"CI (draft)",event:"pull_request",headSha:$h,status:"completed",conclusion:"success"},{databaseId:701,name:"Lint",event:"pull_request",headSha:$h,status:"completed",conclusion:"success"},{databaseId:702,name:"CI",event:"pull_request",headSha:$h,status:"in_progress",conclusion:null}]' >"$ST/run-list-after-ready-2.json"
ship --keep-branch; expect 0 "ready waits for every new run"
[ ! -e "$ST/merged-before-late-run-finished" ] || fail "two ready runs: merged before run 702 finished"
[ -e "$ST/late-ready-run-completed" ] || fail "two ready runs: run 702 completed before merge"
grep -q 'gh run view 702' "$ST/gh.log" || fail "two ready runs: waited on the later-listed run: [$(cat "$ST/gh.log")]"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "two ready runs: merge succeeded: [$OUT]"

# 702 is listed two calls after 701: one quiet re-list is not enough; ship-pr
# keeps listing until three passes in a row add no new run.
setup; echo true >"$ST/draft"; touch "$ST/late-ready-run"; echo 702 >"$ST/late-ready-run-id"
jq -nc --arg h "$HEAD0" '[{databaseId:700,name:"CI (draft)",event:"pull_request",headSha:$h,status:"completed",conclusion:"success"}]' >"$ST/run-list-before-ready.json"
jq -nc --arg h "$HEAD0" '[{databaseId:700,name:"CI (draft)",event:"pull_request",headSha:$h,status:"completed",conclusion:"success"},{databaseId:701,name:"Lint",event:"pull_request",headSha:$h,status:"in_progress",conclusion:null}]' >"$ST/run-list-after-ready.json"
cp "$ST/run-list-after-ready.json" "$ST/run-list-after-ready-2.json"
jq -nc --arg h "$HEAD0" '[{databaseId:700,name:"CI (draft)",event:"pull_request",headSha:$h,status:"completed",conclusion:"success"},{databaseId:701,name:"Lint",event:"pull_request",headSha:$h,status:"completed",conclusion:"success"},{databaseId:702,name:"CI",event:"pull_request",headSha:$h,status:"in_progress",conclusion:null}]' >"$ST/run-list-after-ready-3.json"
ship --keep-branch; expect 0 "ready waits for a run listed two passes late"
[ ! -e "$ST/merged-before-late-run-finished" ] || fail "late second run: merged before run 702 finished"
grep -q 'gh run view 702' "$ST/gh.log" || fail "late second run: waited on run 702: [$(cat "$ST/gh.log")]"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "late second run: merge succeeded: [$OUT]"

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

# ===== diagnostic PRs keep the local worktree and branch even when ship-pr
# ===== runs outside them
setup; printf 'Diagnostic PR: the ticket stays open\nRefs #97\n' >"$ST/body"
cd "$T" || fail "cd out for diagnostic ship"
ship; expect 0 "diagnostic PR happy path"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "diagnostic PR merged line: [$OUT]"
[ -d "$WT" ] || fail "diagnostic PR worktree kept outside"
git -C "$C" rev-parse --verify -q refs/heads/feature >/dev/null || fail "diagnostic PR local branch kept outside"
origin_head >/dev/null && fail "diagnostic PR remote branch is still deleted"
grep -q 'worktree kept' <<<"$ERR" || fail "diagnostic PR keep message: [$ERR]"

setup; printf 'Refs #97\nResolves #97\n' >"$ST/body"
ship; expect 0 "a closing line prevents diagnostic keep inference"
[ ! -e "$WT" ] || fail "a closing line permits default worktree removal"
git -C "$C" rev-parse --verify -q refs/heads/feature >/dev/null && fail "a closing line permits default local branch deletion"

setup; printf 'Resolves #97\n' >"$ST/body"
ship --keep-branch; expect 0 "explicit --keep-branch"
[ -d "$WT" ] || fail "explicit --keep-branch keeps worktree"
git -C "$C" rev-parse --verify -q refs/heads/feature >/dev/null || fail "explicit --keep-branch keeps local branch"
grep -q 'worktree kept' <<<"$ERR" || fail "explicit --keep-branch log: [$ERR]"

setup; printf 'Resolves #97\n' >"$ST/body"; cd "$T" || fail "cd out for default cleanup"
run 7 --repo O/N --reviewed "$HEAD0" --worktree "$WT"; expect 0 "outside clean Resolves ship removes worktree by default"
[ ! -e "$WT" ] || fail "outside clean Resolves ship removes worktree by default"
git -C "$C" rev-parse --verify -q refs/heads/feature >/dev/null && fail "outside clean Resolves ship deletes local branch by default"
grep -Fq 'worktree removed: ' <<<"$ERR" && grep -Fq '; local branch deleted: feature' <<<"$ERR" || fail "outside default cleanup log: [$ERR]"

setup; touch "$ST/worktree-busy"; cd "$T" || fail "cd out for busy cleanup"
ship; expect 0 "active worktree is kept"
[ -d "$WT" ] || fail "active worktree remains"
git -C "$C" rev-parse --verify -q refs/heads/feature >/dev/null || fail "active worktree branch remains"
grep -q 'worktree kept: a process has its cwd inside it' <<<"$ERR" || fail "active worktree keep log: [$ERR]"

setup; printf 'echo late > %q\n' "$WT/late.txt" >"$ST/merge-each"; cd "$T" || fail "cd out for dirty cleanup"
ship; expect 0 "dirty worktree is kept"
[ -d "$WT" ] || fail "dirty worktree remains"
git -C "$C" rev-parse --verify -q refs/heads/feature >/dev/null || fail "dirty worktree branch remains"
grep -q 'worktree kept: it is not clean after merge' <<<"$ERR" || fail "dirty worktree keep log: [$ERR]"

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
[ "$(grep -c '^1$' "$ST/sleeps.txt")" -eq 11 ] || fail "11 one-second sleeps across 12 polls: [$(cat "$ST/sleeps.txt")]"
[ "$(grep -c '^5$' "$ST/sleeps.txt")" -eq 24 ] || fail "bounded no-run wait: 24 five-second sleeps: [$(cat "$ST/sleeps.txt")]"
[ "$(wc -l <"$ST/sleeps.txt")" -eq 35 ] || fail "no sleeps besides the 11 polls and the 24 no-run waits: [$(cat "$ST/sleeps.txt")]"

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

# A BLOCKED merge reports the actionable workflow run without repeating gh hints.
setup; echo BLOCKED >"$ST/merge-state"
printf '%s\n' 'Pull request cannot be merged: the base branch policy prohibits the merge. Use the --auto flag to merge when requirements are met.' >"$ST/merge-fail-msg"
jq -nc --arg h "$HEAD0" '[{databaseId:802,name:"CI - Required",event:"pull_request",headSha:$h,status:"in_progress",conclusion:null}]' >"$ST/run-list.json"
ship; expect 1 "BLOCKED merge names its pending run"
grep -q 'CI - Required' <<<"$ERR" || fail "BLOCKED merge: run name is reported: [$ERR]"
grep -q '802' <<<"$ERR" || fail "BLOCKED merge: run id is reported: [$ERR]"
grep -q 'in_progress' <<<"$ERR" || fail "BLOCKED merge: run status is reported: [$ERR]"
! grep -Eqi -- '--auto|--admin' <<<"$ERR" || fail "BLOCKED merge: gh merge hints are removed: [$ERR]"
grep -q 'the base branch policy prohibits the merge' <<<"$ERR" || fail "BLOCKED merge: gh reason kept: [$ERR]"

# ===== lost race: 'the head branch is not up to date with the base branch'
# ===== re-enters the merge once, counted against the retries budget of 3
setup; merge_once "$BUMP_MAIN"; printf '%s' "$OUTDATED" >"$ST/merge-fail-once"
ship; expect 0 "lost race recovers"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "merged line after recovery: [$OUT]"
[ "$(grep -c '^gh pr merge' "$ST/gh.log")" -eq 2 ] || fail "recovery merges twice"
[ "$(grep -c 'check-runs' "$ST/gh.log")" -eq 2 ] || fail "recovery waits twice"
grep -q 'origin/main moved before the merge; merging again (retry 1 of 3)' <<<"$ERR" || fail "recovery message: [$ERR]"
PIN="$(sed -n 's/.*--match-head-commit //p' "$ST/gh.log" | tail -n 1)"
git --git-dir="$ORIGIN" merge-base --is-ancestor refs/heads/main "$PIN" || fail "second merge pinned below the moved main: [$PIN]"
[ ! -e "$ST/sleeps.txt" ] || ! grep -qx '5' "$ST/sleeps.txt" || fail "recovery sleeps zero"
[ ! -e "$WT" ] || fail "worktree removed after recovery"

ABS_SHIP="$(cd "$SCRIPT_DIR/../bin" && pwd)/ship-pr"
setup; merge_each "$BUMP_MAIN"; printf '%s' "$OUTDATED" >"$ST/merge-fail-msg"
ship; expect 1 "second loss exits 1"
[ "$(grep -c '^gh pr merge' "$ST/gh.log")" -eq 2 ] || fail "second loss merges twice"
grep -qF 'gh pr merge failed: lost the race to origin/main' <<<"$ERR" || fail "lost-race message: [$ERR]"
grep -qF "rerun: bash $ABS_SHIP 7 --repo O/N --reviewed $HEAD0 --worktree $WT" <<<"$ERR" || fail "rerun line: [$ERR]"
[ -d "$WT" ] || fail "worktree kept after a second loss"
[ "$(origin_head)" != "$HEAD0" ] || fail "second pass pushed a merged head"
[ "$OUT" != "merged $MERGE_SHA" ] || fail "second loss never merges"

setup; merge_once "$BUMP_MAIN"; printf '%s' "$OUTDATED" >"$ST/merge-fail-once"; touch "$ST/merge-fails-but-merges"
ship; expect 0 "merged despite the error still merges"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "merged line when already merged: [$OUT]"
[ "$(grep -c '^gh pr merge' "$ST/gh.log")" -eq 1 ] || fail "no second merge when already merged"
! grep -q 'merging again' <<<"$ERR" || fail "no recovery when already merged: [$ERR]"

setup; printf '%s' "$OUTDATED" >"$ST/merge-fail-msg"
ship; expect 1 "race with main unmoved exits 1"
[ "$(grep -c '^gh pr merge' "$ST/gh.log")" -eq 1 ] || fail "no retry when main never moved"
grep -qF 'lost the race to origin/main (origin/main has not moved' <<<"$ERR" || fail "unmoved message: [$ERR]"
[ "$(origin_head)" = "$HEAD0" ] || fail "unmoved race pushes nothing"
[ -d "$WT" ] || fail "worktree kept when main never moved"

setup
checks_each 'c="$(cat "$ST/n" 2>/dev/null || echo 0)"; c=$((c + 1)); echo "$c" >"$ST/n"; [ "$c" -le 2 ] && { '"$BUMP_MAIN"'; }; true'
merge_once "$BUMP_MAIN"; printf '%s' "$OUTDATED" >"$ST/merge-fail-once"
ship; expect 0 "race on the last retry recovers"
grep -q 'retry 3 of 3' <<<"$ERR" || fail "third retry line: [$ERR]"

setup
checks_each 'c="$(cat "$ST/n" 2>/dev/null || echo 0)"; c=$((c + 1)); echo "$c" >"$ST/n"; [ "$c" -le 3 ] && { '"$BUMP_MAIN"'; }; true'
merge_each "$BUMP_MAIN"; printf '%s' "$OUTDATED" >"$ST/merge-fail-msg"
ship; expect 1 "race with no retries left exits 1"
[ "$(grep -c '^gh pr merge' "$ST/gh.log")" -eq 1 ] || fail "no recovery with no retries left"
[ "$(grep -c 'check-runs' "$ST/gh.log")" -eq 4 ] || fail "four CI waits before the race"
grep -qF 'lost the race to origin/main (no retries left)' <<<"$ERR" || fail "exhausted message: [$ERR]"
[ -d "$WT" ] || fail "worktree kept when retries are spent"

setup; echo "$NOSTRICT" >"$ST/rules"; merge_each "$BUMP_MAIN"; printf '%s' "$OUTDATED" >"$ST/merge-fail-msg"
ship; expect 1 "non-strict never recovers a lost race"
[ "$(grep -c '^gh pr merge' "$ST/gh.log")" -eq 1 ] || fail "non-strict merges once"
! grep -q 'lost the race' <<<"$ERR" || fail "non-strict names no lost race: [$ERR]"
! grep -q 'merging again' <<<"$ERR" || fail "non-strict never merges again: [$ERR]"

setup; merge_once "$BUMP_MAIN"; printf 'GraphQL error: %s' "$OUTDATED" >"$ST/merge-fail-once"
ship; expect 0 "strict prefers the lost race over GraphQL"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "merged line after a GraphQL race: [$OUT]"
[ "$(grep -c '^gh pr merge' "$ST/gh.log")" -eq 2 ] || fail "GraphQL race merges twice"
[ ! -e "$ST/sleeps.txt" ] || ! grep -qx '5' "$ST/sleeps.txt" || fail "lost race sleeps zero on a GraphQL race"

setup
printf 'GraphQL error: transient failure' >"$ST/merge-fail-once"
printf 'if [ -e "$ST/m1" ] && [ ! -e "$ST/m2" ]; then touch "$ST/m2"; printf %%s %s >"$ST/merge-fail-once"; fi\n' "'$OUTDATED'" >"$ST/merge-each"
printf 'if [ ! -e "$ST/m1" ]; then touch "$ST/m1"; %s; fi\n' "$BUMP_MAIN" >>"$ST/merge-each"
ship; expect 0 "GraphQL then lost race recovers"
[ "$OUT" = "merged $MERGE_SHA" ] || fail "merged line after a retry-path race: [$OUT]"
[ "$(grep -c '^gh pr merge' "$ST/gh.log")" -eq 3 ] || fail "retry-path race merges three times"
[ "$(grep -c 'check-runs' "$ST/gh.log")" -eq 2 ] || fail "retry-path race waits twice"
grep -q 'origin/main moved before the merge; merging again (retry 1 of 3)' <<<"$ERR" || fail "retry-path recovery message: [$ERR]"
PIN="$(sed -n 's/.*--match-head-commit //p' "$ST/gh.log" | tail -n 1)"
git --git-dir="$ORIGIN" merge-base --is-ancestor refs/heads/main "$PIN" || fail "retry-path second merge pinned below the moved main: [$PIN]"
[ "$(grep -c '^5$' "$ST/sleeps.txt")" -eq 1 ] || fail "retry-path sleeps 5 s once, on the GraphQL retry: [$(cat "$ST/sleeps.txt" 2>/dev/null)]"
[ ! -e "$WT" ] || fail "worktree removed after a retry-path recovery"

setup; echo true >"$ST/draft"
merge_once "$BUMP_MAIN"; printf '%s' "$OUTDATED" >"$ST/merge-fail-once"
ship --gate 'echo x >>"$ST/gates"'; expect 0 "recovery keeps once-only work once-only"
[ "$(wc -l <"$ST/gates" | tr -d ' ')" -eq 1 ] || fail "gate ran exactly once across the recovery"
[ "$(grep -c '^gh pr ready' "$ST/gh.log")" -eq 1 ] || fail "ready called exactly once across the recovery"

setup; echo true >"$ST/draft"
merge_once "$BUMP_MAIN; echo '[{\"bucket\":\"fail\",\"name\":\"ci\"}]' >\"\$ST/checks\""; printf '%s' "$OUTDATED" >"$ST/merge-fail-once"
ship; expect 1 "CI failure after recovery still reports the ready PR"
[ "$(tail -n 1 <<<"$ERR")" = "ship-pr: CI failed; nothing merged, PR 7 is still marked ready" ] || fail "ready suffix after recovery: [$ERR]"

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
expect_refused LABEL
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
! grep -q '^gh run list.*databaseId,status,conclusion,headSha,createdAt' "$ST/gh.log" \
  || fail "unchecked repo: no mutants proof lookup"

# a repo with other labels only is not checked either
setup; echo true >"$ST/draft"; repo_labels '[{"name":"docs"}]'
ship; expect 0 "repo with other labels passes unchecked"

# a non-draft is not checked even when the repo defines the label
setup; repo_labels "$MUTANTS_LABEL"
ship; expect 0 "non-draft skips the mutants check"
! grep -q -- '--json labels' "$ST/gh.log" || fail "non-draft: no PR label read"

# ===== --mutants-gate: before ready, require a label or zero-mutant proof
setup; echo true >"$ST/draft"; on_pr_labels "$MUTANTS_LABEL"
ship --mutants-gate; expect 0 "mutants gate accepts the PR label"
! grep -q '^gh run list.*databaseId,status,conclusion,headSha,createdAt' "$ST/gh.log" \
  || fail "mutants label: no mutants proof lookup needed"
grep -q -- '--json labels' "$ST/gh.log" || fail "mutants label: PR labels read"

setup; echo true >"$ST/draft"
jq -nc --arg h "$HEAD0" '[{databaseId:417,status:"completed",conclusion:"success",headSha:$h,createdAt:"2026-11-04T08:16:00Z"}]' >"$ST/run-list.json"
echo '[{"databaseId":901,"name":"Selection","status":"completed","conclusion":"success"}]' >"$ST/jobs-417.json"
echo 'mutants in the diff: 0' >"$ST/log-417-901.log"
ship --mutants-gate; expect 0 "mutants gate accepts completed zero-mutant proof"
grep -q 'gh run list.*--commit' "$ST/gh.log" || fail "zero-mutant proof: run list is pinned to the head"
grep -q 'gh run view 417.*--job 901 --log' "$ST/gh.log" || fail "zero-mutant proof: Selection job log read"

setup; echo true >"$ST/draft"
jq -nc --arg h "$HEAD0" '[{databaseId:417,status:"completed",conclusion:"success",headSha:$h,createdAt:"2026-11-04T08:16:00Z"}]' >"$ST/run-list.json"
echo '[{"databaseId":901,"name":"Selection","status":"completed","conclusion":"success"}]' >"$ST/jobs-417.json"
printf 'Selection\tPlan\t2026-11-05T10:47:00.0000000Z mutants in the diff: 0\n' >"$ST/log-417-901.log"
ship --mutants-gate; expect 0 "mutants gate accepts a prefixed zero-mutant proof"

setup; echo true >"$ST/draft"
jq -nc --arg h "$HEAD0" '[{databaseId:417,status:"completed",conclusion:"success",headSha:$h,createdAt:"2026-11-04T08:16:00Z"}]' >"$ST/run-list.json"
echo '[{"databaseId":901,"name":"Selection","status":"completed","conclusion":"success"}]' >"$ST/jobs-417.json"
printf 'Selection\tPlan\t2026-11-05T10:47:00.0000000Z mutants in the diff: 05\n' >"$ST/log-417-901.log"
ship --mutants-gate; expect 5 "mutants gate rejects a prefixed 05 count"
no_merge "mutants gate with prefixed 05"
grep -q 'mutants gate failed' <<<"$ERR" || fail "prefixed 05 failure names the check: [$ERR]"

setup; echo true >"$ST/draft"
ship --mutants-gate; expect 5 "mutants gate rejects no label and no proof"
expect_refused MUTANTS
no_merge "mutants gate without proof"
grep -q 'mutants gate failed' <<<"$ERR" || fail "mutants gate failure names the check: [$ERR]"
! grep -q 'gh label create\|gh label edit' "$ST/gh.log" || fail "mutants gate never adds a label"

setup; echo true >"$ST/draft"
jq -nc --arg h "$HEAD0" '[{databaseId:416,status:"completed",conclusion:"success",headSha:$h,createdAt:"2026-11-04T08:00:00Z"},{databaseId:417,status:"in_progress",conclusion:null,headSha:$h,createdAt:"2026-11-04T08:16:00Z"}]' >"$ST/run-list.json"
echo '[{"databaseId":901,"name":"Selection","status":"completed","conclusion":"success"}]' >"$ST/jobs-416.json"
echo 'mutants in the diff: 0' >"$ST/log-416-901.log"
ship --mutants-gate; expect 5 "mutants gate rejects an in-progress current-head run"
no_merge "mutants gate with in-progress run"
grep -q 'mutants gate failed' <<<"$ERR" || fail "in-progress gate failure names the check: [$ERR]"

setup; ship --mutants-gate; expect 0 "mutants gate leaves an already-ready PR alone"
! grep -q -- '--json labels' "$ST/gh.log" || fail "already-ready PR: no label read"
! grep -q '^gh run list' "$ST/gh.log" || fail "already-ready PR: no run lookup"

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

# 5. a failed comment post: exit 1 and nothing pushed. A merge moves the local
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

setup; echo '[{"bucket":"cancel","name":"ci"}]' >"$ST/checks"
echo '[{"databaseId":113,"name":"ci","workflowName":"CI","event":"push","conclusion":"cancelled"}]' >"$ST/run-list.json"
echo '[{"conclusion":"cancelled","databaseId":213,"name":"ci"}]' >"$ST/jobs-113.json"
printf '%s\n' '7' 'gh: HTTP 502: bad gateway' 'retry later' >"$ST/attempt-fail-113"
ship; expect 1 "unreadable attempt 113 names gh exit code and stderr"
line="$(grep 'cannot read attempt of run 113 before rerun' <<<"$ERR")"
grep -q 'exit 7' <<<"$line" || fail "113: attempt read names gh exit code: [$ERR]"
grep -q 'gh: HTTP 502: bad gateway' <<<"$line" || fail "113: attempt read names gh stderr: [$ERR]"
grep -q 'retry later' <<<"$line" || fail "113: multi-line gh stderr stays on one line: [$ERR]"
! grep -q 'gh run rerun' "$ST/gh.log" || fail "113: unreadable attempt never reruns"
no_merge "113 unreadable attempt"

setup; echo '[{"bucket":"cancel","name":"ci"}]' >"$ST/checks"
echo '[{"databaseId":114,"name":"ci","workflowName":"CI","event":"push","conclusion":"cancelled"}]' >"$ST/run-list.json"
echo '[{"conclusion":"cancelled","databaseId":214,"name":"ci"}]' >"$ST/jobs-114.json"
printf '%s\n' '9' >"$ST/attempt-fail-114"
ship; expect 1 "unreadable attempt 114 with empty stderr names the exit code"
line="$(grep 'cannot read attempt of run 114 before rerun' <<<"$ERR")"
grep -q 'exit 9' <<<"$line" || fail "114: attempt read names gh exit code: [$ERR]"
grep -q '(no stderr)' <<<"$line" || fail "114: empty gh stderr reads (no stderr): [$ERR]"
! grep -q 'gh run rerun' "$ST/gh.log" || fail "114: unreadable attempt never reruns"
no_merge "114 unreadable attempt"

! compgen -G "$TMPDIR/ship-pr-7-attempt.*" >/dev/null || fail "attempt stderr temp file removed after unreadable attempt"

# an empty attempt file reads as attempt 1, as the rerun branch already does:
# the pre-rerun read must not hand jq an empty --argjson
setup; echo '[{"bucket":"cancel","name":"ci"}]' >"$ST/checks"
echo '[{"databaseId":130,"name":"ci","workflowName":"CI","event":"push","conclusion":"cancelled"}]' >"$ST/run-list.json"
echo '[{"conclusion":"cancelled","databaseId":230,"name":"ci"}]' >"$ST/jobs-130.json"
: >"$ST/attempt-130.txt"
ship; expect 0 "empty attempt file reads as attempt 1"
[ "$(grep -c 'gh run rerun 130' "$ST/gh.log")" -eq 1 ] || fail "empty attempt: rerun once: [$(grep -c 'gh run rerun 130' "$ST/gh.log")]"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "empty attempt merges: [$OUT]"

# many cancelled runs: the rerun wait looks each pre-attempt up in a long
# list, which must not die on SIGPIPE when awk exits early (pipefail)
setup; echo '[{"bucket":"cancel","name":"ci"}]' >"$ST/checks"
jq -n '[range(3000) | {"databaseId": (1000+.), "name": "ci", "workflowName": "CI-\(.)", "event": "push", "conclusion": "cancelled"}]' >"$ST/run-list.json"
touch "$ST/jobs-many-cancelled.json"
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

# Longest-wait notice is first on stderr and uses the effective CI timeout.
setup; ship; expect 0 "default wait notice case"
[ "$(head -n 1 <<<"$ERR")" = "ship-pr: no shell timeout: waits are bounded at 36000 s (10 h), worst case; a clean run takes minutes" ] \
  || fail "default longest-wait notice: [$ERR]"
setup; ship --timeout 14; expect 0 "short wait notice case"
[ "$(head -n 1 <<<"$ERR")" = "ship-pr: no shell timeout: waits are bounded at 70 s (0 h), worst case; a clean run takes minutes" ] \
  || fail "short longest-wait notice: [$ERR]"
setup; CLAUDECODE=1 ship --timeout 14; expect 0 "Claude Code wait notice case"
[ "$(head -n 1 <<<"$ERR")" = "ship-pr: no shell timeout: waits are bounded at 36000 s (10 h), worst case; a clean run takes minutes" ] \
  || fail "Claude Code longest-wait notice: [$ERR]"
setup; CLAUDECODE=1 ship --timeout 599; expect 0 "one-below wait notice case"
[ "$(head -n 1 <<<"$ERR")" = "ship-pr: no shell timeout: waits are bounded at 36000 s (10 h), worst case; a clean run takes minutes" ] \
  || fail "599 s uses the Claude Code timeout: [$ERR]"
setup; CLAUDECODE=1 ship --timeout 600; expect 0 "at-boundary wait notice case"
[ "$(head -n 1 <<<"$ERR")" = "ship-pr: no shell timeout: waits are bounded at 3000 s (0 h), worst case; a clean run takes minutes" ] \
  || fail "600 s stays unchanged: [$ERR]"
setup; CLAUDECODE=1 ship --timeout 601; expect 0 "above-boundary wait notice case"
[ "$(head -n 1 <<<"$ERR")" = "ship-pr: no shell timeout: waits are bounded at 3005 s (0 h), worst case; a clean run takes minutes" ] \
  || fail "601 s stays unchanged: [$ERR]"
setup; run 7 --repo O/N --worktree "$WT"; expect 2 "usage has no longest-wait notice"
! grep -q '^ship-pr: no shell timeout' <<<"$ERR" || fail "usage error has no longest-wait notice: [$ERR]"
grep -q 'background' <<<"$ERR" && grep -q 'no shell timeout' <<<"$ERR" \
  || fail "usage mentions background and no shell timeout: [$ERR]"

# A never-started required check is a CI failure, not a rerunnable failure.
setup
cat >"$ST/rules" <<'RULES'
[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"ci"},{"context":"lint"}]}}]
RULES
echo '[{"bucket":"fail","name":"lint","link":"https://github.com/O/N/actions/runs/111/job/1"}]' >"$ST/checks"
echo '[{"databaseId":111,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"cancelled"}]' >"$ST/run-list.json"
echo '[{"databaseId":1,"name":"lint","conclusion":"cancelled"}]' >"$ST/jobs-111.json"
GH_CI_NO_JOBS_AFTER=1 ship --timeout 90
expect 1 "never-started required check fails ship-pr"
grep -Fq 'gh-ci: check ci has no check run after 1 min; it never started' <<<"$OUT" \
  || fail "ship-pr prints the never-started line: [$OUT]"
grep -Fq 'failing: lint' <<<"$OUT" || fail "ship-pr prints the failing required check: [$OUT]"
! grep -q 'gh run rerun' "$ST/gh.log" || fail "never-started check is not rerun: [$(cat "$ST/gh.log")]"
[ "$(grep -c 'check-runs' "$ST/gh.log")" = "10" ] || fail "one-minute bound is reached after ten polls at seven-second intervals: [$(cat "$ST/gh.log")]"

# ===== --known-flake: only flywheel can opt into ticket-backed red-gate acceptance
KNOWN_TEST='tests::flaky'
KNOWN_GATE="printf '%s\\n' 'FAIL [ 0.001s] crate_name::integration_tests $KNOWN_TEST' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed'; exit 100"
CARGO_FAILURE_GATE="printf '%s\\n' 'test tests::unknown ... FAILED' 'failures:' '    tests::unknown' 'test result: FAILED. 0 passed; 1 failed'; exit 1"
CARGO_SOURCE_DIFF_GATE="printf '%s\\n' 'Running unittests crates/main/src/lib.rs (target/debug/deps/crate_name-000)' 'test crate_name::foo::tests::flaky ... FAILED' 'failures:' '    crate_name::foo::tests::flaky' 'test result: FAILED. 0 passed; 1 failed'; exit 1"
prepare_known_flake() {
  setup
  printf '%s\n' '2026-11-05T00:00:00Z' >"$ST/pr-created"
  jq -nc --arg name "$KNOWN_TEST" '{state:"OPEN",body:("known flake: " + $name),createdAt:"2026-11-01T00:00:00Z",comments:[]}' >"$ST/ticket-166.json"
  jq -nc --arg h "$HEAD0" '[{databaseId:771,name:"CI",workflowName:"CI",event:"pull_request",status:"completed",conclusion:"success",headSha:$h,createdAt:"2026-11-05T00:01:00Z"}]' >"$ST/run-list.json"
}
known_ship() {
  ship --known-flake 166 --by flywheel --gate "$KNOWN_GATE" --keep-branch
}
known_ship_multiple_tickets() {
  ship --known-flake 165 166 --by flywheel --gate "$KNOWN_GATE" --keep-branch
}

prepare_known_flake
ship --known-flake 166 --gate 'touch "$ST/gate-ran"; exit 1' --keep-branch
expect_refused KNOWN-FLAKE
[ ! -e "$ST/gate-ran" ] || fail "known-flake missing by: no gate runs"
! grep -q 'check-runs' "$ST/gh.log" 2>/dev/null || fail "known-flake missing by: no CI wait"
no_merge "known-flake missing by"

prepare_known_flake
ship --known-flake 166 --by lane --gate 'touch "$ST/gate-ran"; exit 1' --keep-branch
expect_refused KNOWN-FLAKE
[ ! -e "$ST/gate-ran" ] || fail "known-flake wrong by: no gate runs"
! grep -q 'check-runs' "$ST/gh.log" 2>/dev/null || fail "known-flake wrong by: no CI wait"
no_merge "known-flake wrong by"

# CI is the first acceptance check and must be green on the pinned head.
prepare_known_flake
ship --known-flake 166 --by flywheel --gate "$CARGO_FAILURE_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'known-flake: gate output is cargo libtest; only nextest gates are supported' <<<"$ERR" \
  || fail "libtest failure refuses with unsupported-format message: [$ERR]"
no_merge "cargo libtest refusal"

# A full libtest failure followed by a compile error is never accepted.
prepare_known_flake
LIBTEST_FAIL_GATE="cat '$SCRIPT_DIR/fixtures/ship-pr-cargo-libtest-fail.txt'; exit 1"
ship --known-flake 166 --by flywheel --gate "$LIBTEST_FAIL_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'known-flake: gate output is cargo libtest; only nextest gates are supported' <<<"$ERR" \
  || fail "flywheel libtest compile failure refusal: [$ERR]"
no_merge "cargo libtest compile failure"

# A clean libtest-only log is unsupported even without a compile error.
prepare_known_flake
LIBTEST_CLEAN_GATE="cat '$SCRIPT_DIR/fixtures/ship-pr-cargo-libtest-clean.txt'; exit 1"
ship --known-flake 166 --by flywheel --gate "$LIBTEST_CLEAN_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'known-flake: gate output is cargo libtest; only nextest gates are supported' <<<"$ERR" \
  || fail "clean libtest refusal: [$ERR]"
no_merge "clean cargo libtest refusal"

# A bare libtest failure line has no nextest status block to contain it.
prepare_known_flake
BARE_LIBTEST_GATE="printf '%s\\n' 'test x ... FAILED'; exit 1"
ship --known-flake 166 --by flywheel --gate "$BARE_LIBTEST_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'known-flake: gate output is cargo libtest; only nextest gates are supported' <<<"$ERR" \
  || fail "bare libtest failure refusal: [$ERR]"
no_merge "bare cargo libtest refusal"

prepare_known_flake
HEADER_LIBTEST_GATE="printf '%s\\n' ' ---- x stderr ----'; exit 1"
ship --known-flake 166 --by flywheel --gate "$HEADER_LIBTEST_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'known-flake: gate output is cargo libtest; only nextest gates are supported' <<<"$ERR" \
  || fail "indented libtest header refusal: [$ERR]"
no_merge "indented libtest header refusal"

prepare_known_flake
echo '[{"bucket":"fail","name":"ci"}]' >"$ST/checks"
known_ship
expect 5 "known-flake CI refusal"
expect_refused KNOWN-FLAKE
grep -q 'known-flake check 1 failed: CI is not green' <<<"$ERR" || fail "known-flake CI refusal names the red CI gate: [$ERR]"
no_merge "known-flake CI refusal"

# An unnamed red test refuses even when it appears on a closed or unrelated ticket.
prepare_known_flake
jq -nc --arg name 'integration_tests tests::different' '{state:"OPEN",body:("known flake: " + $name),createdAt:"2026-11-01T00:00:00Z",comments:[]}' >"$ST/ticket-166.json"
known_ship
expect_refused KNOWN-FLAKE
grep -q 'not named' <<<"$ERR" || fail "unnamed red test message: [$ERR]"
no_merge "unnamed red test"

prepare_known_flake
jq -nc --arg name "$KNOWN_TEST" '{state:"CLOSED",body:("known flake: " + $name),createdAt:"2026-11-01T00:00:00Z",comments:[]}' >"$ST/ticket-166.json"
known_ship
expect_refused KNOWN-FLAKE
grep -q 'closed' <<<"$ERR" || fail "closed ticket message: [$ERR]"
no_merge "closed ticket"

# An open ticket created after the PR opened can name the red test in its body.
prepare_known_flake
jq -nc --arg name "$KNOWN_TEST" '{state:"OPEN",body:("known flake: " + $name),createdAt:"2026-11-06T00:00:00Z",comments:[]}' >"$ST/ticket-166.json"
known_ship
expect 0 "ticket created after PR opens"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "post-PR ticket merged output: [$OUT]"

# The issue view returns a ticket creation date after this fixture's fresh gate.
prepare_known_flake
touch "$ST/ticket-created-after-gate"
POST_GATE_TICKET_GATE='touch "$ST/gate-ran"; printf "%s\\n" "FAIL [ 0.001s] crate_name::integration_tests tests::flaky" "Summary [ 0.001s] 1 test run: 0 passed, 1 failed"; exit 100'
ship --known-flake 166 --by flywheel --gate "$POST_GATE_TICKET_GATE" --keep-branch
expect 0 "ticket created after fresh gate"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "post-gate ticket merged output: [$OUT]"
[ -e "$ST/ticket-created-after-gate-seen" ] || fail "ticket fixture assigned its date after the gate"
jq -e '.createdAt == "2099-12-31T23:59:59Z"' "$ST/ticket-166-post-gate.json" >/dev/null \
  || fail "post-gate ticket date: [$(cat "$ST/ticket-166-post-gate.json" 2>/dev/null)]"

# A named red test refuses when cargo metadata cannot resolve its crate.
prepare_known_flake
jq -nc --arg manifest "$WT/crates/other/Cargo.toml" --arg lib "$WT/crates/other/src/lib.rs" \
  '{packages:[{name:"other",manifest_path:$manifest,targets:[{name:"lib",kind:["lib"],src_path:$lib}]}]}' >"$ST/cargo-metadata.json"
UNKNOWN_CRATE_GATE="printf '%s\\n' 'FAIL [ 0.001s] missing_crate::integration_tests $KNOWN_TEST' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed'; exit 100"
ship --known-flake 166 --by flywheel --gate "$UNKNOWN_CRATE_GATE" --keep-branch
[ "$CODE" = 5 ] || fail "unresolved test crate must refuse: out=[$OUT] err=[$ERR]"
expect_refused KNOWN-FLAKE
grep -q "check 3 failed.*red test '$KNOWN_TEST'.*crate" <<<"$ERR" || fail "unresolved test crate message: [$ERR]"
no_merge "unresolved test crate"

# Cargo metadata falls back to the standard user cargo path if PATH cargo cannot run.
prepare_known_flake
touch "$ST/cargo-metadata-fail"
mkdir -p "$HOME/.cargo/bin"
cat >"$HOME/.cargo/bin/cargo" <<'CARGO_HOME'
#!/usr/bin/env bash
[ "${1:-}" = metadata ] || exit 2
jq -nc --arg manifest "$PWD/crates/main/Cargo.toml" \
  --arg lib "$PWD/crates/main/src/lib.rs" \
  --arg integration "$PWD/crates/main/tests/integration_tests.rs" \
  '{packages:[{name:"crate-name",manifest_path:$manifest,targets:[{name:"crate_name",kind:["lib"],src_path:$lib},{name:"integration_tests",kind:["test"],src_path:$integration}]}]}'
CARGO_HOME
chmod 755 "$HOME/.cargo/bin/cargo"
known_ship
expect 0 "known-flake cargo metadata fallback"
rm -f "$HOME/.cargo/bin/cargo"
rmdir "$HOME/.cargo/bin" "$HOME/.cargo" 2>/dev/null || true

prepare_known_flake
touch "$ST/cargo-metadata-fail"
ship --known-flake 166 --by flywheel --gate "$KNOWN_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'check 3 failed: cannot run cargo metadata' <<<"$ERR" || fail "unavailable cargo metadata refusal: [$ERR]"
grep -Fq "$KNOWN_TEST" <<<"$ERR" || fail "unavailable metadata refusal names red test: [$ERR]"
no_merge "unavailable cargo metadata"

# A space-padded nextest progress counter is not the binary identifier.
prepare_known_flake
PADDED_TEST='registry::tests::restore_detached_rejects_paths_outside_root_or_without_an_existing_file'
jq -nc --arg name "$PADDED_TEST" '{state:"OPEN",body:("known flake: " + $name),createdAt:"2026-11-01T00:00:00Z",comments:[]}' >"$ST/ticket-166.json"
jq -nc --arg manifest "$(cd "$WT" && pwd -P)/crates/jobs/Cargo.toml" \
  '{packages:[{name:"jobs",manifest_path:$manifest,targets:[]}]}' >"$ST/cargo-metadata.json"
PADDED_GATE="cat '$SCRIPT_DIR/fixtures/ship-pr-nextest-lib-test.txt'; printf '%s\\n' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed'; exit 100"
ship --known-flake 166 --by flywheel --gate "$PADDED_GATE" --keep-branch
expect 0 "known-flake padded nextest counter"
grep -Fq "$PADDED_TEST" "$ST/comment.txt" || fail "padded counter preserves test name"

# Real nextest captured panic output belongs to the failing test block.
prepare_known_flake
REAL_TEST='keeper::a_second_crash_leaves_one_keeper_the_log_and_the_third_resume_orphans_the_other'
prepare_real_tail_known_flake() {
  prepare_known_flake
  jq -nc --arg name "$REAL_TEST" '{state:"OPEN",body:("known flake: " + $name),createdAt:"2026-11-01T00:00:00Z",comments:[]}' >"$ST/ticket-166.json"
  jq -nc --arg manifest "$(cd "$WT" && pwd -P)/crates/main/Cargo.toml" \
    '{packages:[{name:"main",manifest_path:$manifest,targets:[]}]}' >"$ST/cargo-metadata.json"
}
jq -nc --arg name "$REAL_TEST" '{state:"OPEN",body:("known flake: " + $name),createdAt:"2026-11-01T00:00:00Z",comments:[]}' >"$ST/ticket-166.json"
jq -nc --arg manifest "$(cd "$WT" && pwd -P)/crates/main/Cargo.toml" \
  '{packages:[{name:"main",manifest_path:$manifest,targets:[]}]}' >"$ST/cargo-metadata.json"
REAL_GATE="cat '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real.txt'; printf '%s\\n' 'Summary [ 40.810s] 1 test run: 0 passed, 1 failed' 'FAIL [  40.810s] (5338/7469) main::hub_daemon $REAL_TEST' 'error: test run failed' '== leak scan' 'scripts/check: full output in /tmp/check.log' 'scripts/check: FAIL (exit 100)'; exit 100"
ship --known-flake 166 --by flywheel --gate "$REAL_GATE" --keep-branch
expect 0 "known-flake real nextest panic block"
[ -f "$ST/comment.txt" ] || fail "real nextest PR comment posted"
grep -Fq "$REAL_TEST" "$ST/comment.txt" || fail "real nextest PR comment names the red test"
[ -f "$ST/ticket-comment-166.txt" ] || fail "real nextest ticket comment posted"
grep -Fq "$REAL_TEST" "$ST/ticket-comment-166.txt" || fail "real nextest ticket comment names the red test"

prepare_known_flake
REAL_101_GATE="cat '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real.txt'; printf '%s\\n' 'Summary [ 40.810s] 1 test run: 0 passed, 1 failed'; exit 101"
ship --known-flake 166 --by flywheel --gate "$REAL_101_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'gate exit status was 101, not nextest' <<<"$ERR" || fail "non-nextest exit refusal: [$ERR]"
no_merge "known-flake exit 101 refusal"

prepare_known_flake
SUMMARY_MISMATCH_GATE="printf '%s\\n' 'FAIL [ 0.001s] crate_name::integration_tests $KNOWN_TEST' 'Summary [ 0.001s] 2 tests run: 0 passed, 2 failed'; exit 100"
ship --known-flake 166 --by flywheel --gate "$SUMMARY_MISMATCH_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'Summary reports 2 failing tests but 1 distinct failures' <<<"$ERR" \
  || fail "mismatched nextest summary refusal: [$ERR]"
no_merge "known-flake summary mismatch refusal"

prepare_known_flake
LEAK_AFTER_GATE="printf '%s\\n' 'FAIL [ 0.001s] crate_name::integration_tests $KNOWN_TEST' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed' 'scripts/check: leaked processes (exit 1)'; exit 100"
ship --known-flake 166 --by flywheel --gate "$LEAK_AFTER_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'gate output contains a build or other non-test failure' <<<"$ERR" \
  || fail "leaked process refusal after nextest summary: [$ERR]"
no_merge "known-flake leaked process refusal"

# The real scripts/check tail accepts its orphan-process warning, with both audit comments.
prepare_real_tail_known_flake
REAL_TAIL_GATE="cat '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real.txt' '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real-tail.txt'; exit 100"
ship --known-flake 166 --by flywheel --gate "$REAL_TAIL_GATE" --keep-branch
expect 0 "known-flake real scripts/check tail"
[ -f "$ST/comment.txt" ] || fail "real tail posts a PR comment"
[ -f "$ST/ticket-comment-166.txt" ] || fail "real tail posts a ticket comment"

# The fixed tail line allows only surrounding whitespace, not a resource-cause suffix.
prepare_real_tail_known_flake
REAL_TAIL_TRAILING_SPACE_GATE="cat '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real.txt' '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real-tail.txt'; printf '%s\\n' '  scripts/check: FAIL (exit 100)  '; exit 100"
ship --known-flake 166 --by flywheel --gate "$REAL_TAIL_TRAILING_SPACE_GATE" --keep-branch
expect 0 "known-flake tail line surrounding whitespace"
[ -f "$ST/comment.txt" ] && [ -f "$ST/ticket-comment-166.txt" ] || fail "whitespace tail comments posted"

prepare_real_tail_known_flake
REAL_TAIL_RESOURCE_FAILURE_GATE="cat '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real.txt' '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real-tail.txt'; printf '%s\\n' 'scripts/check: FAIL (exit 100): out of disk'; exit 100"
ship --known-flake 166 --by flywheel --gate "$REAL_TAIL_RESOURCE_FAILURE_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'gate output contains a build or other non-test failure' <<<"$ERR" \
  || fail "tail resource cause is refused: [$ERR]"
no_merge "real tail resource failure"

prepare_real_tail_known_flake
REAL_TAIL_LEAK_100_GATE="cat '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real.txt' '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real-tail.txt'; printf '%s\\n' 'scripts/check: leaked processes (exit 100)'; exit 100"
ship --known-flake 166 --by flywheel --gate "$REAL_TAIL_LEAK_100_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'gate output contains a build or other non-test failure' <<<"$ERR" \
  || fail "exit-100 leaked-process line is refused: [$ERR]"
no_merge "real tail leaked processes exit 100"

# The raw gate exit code must be 100, not merely ship-pr's wrapper code 2.
prepare_real_tail_known_flake
REAL_TAIL_101_GATE="cat '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real.txt' '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real-tail.txt'; exit 101"
ship --known-flake 166 --by flywheel --gate "$REAL_TAIL_101_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'gate exit status was 101' <<<"$ERR" || fail "real tail exit 101 refusal: [$ERR]"
no_merge "real tail exit 101"

# The final Summary count must agree with the distinct failing tests.
prepare_real_tail_known_flake
REAL_TAIL_MISMATCH_GATE="cat '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real.txt'; sed 's/7469 tests run: 7468 passed (5 slow), 1 failed/7469 tests run: 7468 passed (5 slow), 2 failed/' '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real-tail.txt'; exit 100"
ship --known-flake 166 --by flywheel --gate "$REAL_TAIL_MISMATCH_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'Summary reports 2 failing tests but 1 distinct failures' <<<"$ERR" \
  || fail "real tail summary mismatch refusal: [$ERR]"
no_merge "real tail summary mismatch"

# A leak-scan warning still refuses even though the gate exits 100.
prepare_real_tail_known_flake
LEAK_SCAN_TAIL_GATE="cat '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real.txt' '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real-tail.txt'; printf '%s\\n' 'scripts/check: leaked processes (exit 1)'; exit 100"
ship --known-flake 166 --by flywheel --gate "$LEAK_SCAN_TAIL_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'gate output contains a build or other non-test failure' <<<"$ERR" \
  || fail "real tail leaked-process refusal: [$ERR]"
no_merge "real tail leaked process"

# A TRY status repeats a failing test but must still identify that test.
prepare_real_tail_known_flake
TRY_REPEAT_GATE="printf '%s\\n' 'TRY 1 FAIL [  40.810s] (5338/7469) main::hub_daemon $REAL_TEST' 'Summary [1083.889s] 7469 tests run: 7468 passed (5 slow), 1 failed, 13 skipped'; exit 100"
ship --known-flake 166 --by flywheel --gate "$TRY_REPEAT_GATE" --keep-branch
expect 0 "known-flake TRY status parses"
[ -f "$ST/comment.txt" ] || fail "TRY status posts a PR comment"
[ -f "$ST/ticket-comment-166.txt" ] || fail "TRY status posts a ticket comment"

# Legacy nextest output can capture unindented panic lines under --- STDERR:.
prepare_known_flake
LEGACY_CAPTURE_GATE="printf '%s\\n' 'FAIL [ 0.001s] crate_name::integration_tests $KNOWN_TEST' '--- STDERR:' 'thread tests::flaky panicked at src/lib.rs:1:1:' 'assertion failed: deliberate failure' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed'; exit 100"
ship --known-flake 166 --by flywheel --gate "$LEGACY_CAPTURE_GATE" --keep-branch
expect 0 "known-flake legacy unindented panic block"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "legacy captured panic merged output: [$OUT]"

# A panic after the nextest summary is still an unrelated gate failure.
prepare_known_flake
jq -nc --arg name "$REAL_TEST" '{state:"OPEN",body:("known flake: " + $name),createdAt:"2026-11-01T00:00:00Z",comments:[]}' >"$ST/ticket-166.json"
jq -nc --arg manifest "$(cd "$WT" && pwd -P)/crates/main/Cargo.toml" \
  '{packages:[{name:"main",manifest_path:$manifest,targets:[]}]}' >"$ST/cargo-metadata.json"
STRAY_PANIC_GATE="cat '$SCRIPT_DIR/fixtures/ship-pr-known-flake-real.txt'; printf '%s\\n' 'Summary [ 40.810s] 1 test run: 0 passed, 1 failed' 'thread build_script panicked at build.rs:1:1:'; exit 100"
ship --known-flake 166 --by flywheel --gate "$STRAY_PANIC_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'known-flake check 4 failed: gate output contains a build or other non-test failure' <<<"$ERR" \
  || fail "stray panic after test block is refused by check 4: [$ERR]"
no_merge "known-flake stray panic outside test block"

# A ticket naming foo_bar does not name the distinct test foo.
prepare_known_flake
jq -nc '{state:"OPEN",body:"known flake: foo_bar",createdAt:"2026-11-01T00:00:00Z",comments:[]}' >"$ST/ticket-166.json"
FOO_GATE="printf '%s\\n' 'FAIL [ 0.001s] crate_name::integration_tests foo' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed'; exit 100"
ship --known-flake 166 --by flywheel --gate "$FOO_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq "check 2 failed: red test 'foo' is not named" <<<"$ERR" || fail "foo does not match foo_bar ticket: [$ERR]"
no_merge "foo does not match foo_bar ticket"

# A ticket naming the complete test token still authorizes it.
prepare_known_flake
jq -nc '{state:"OPEN",body:"known flake: foo",createdAt:"2026-11-01T00:00:00Z",comments:[]}' >"$ST/ticket-166.json"
ship --known-flake 166 --by flywheel --gate "$FOO_GATE" --keep-branch
expect 0 "known-flake exact test-name token"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "exact test-name token merged output: [$OUT]"

# Any file under the red test's Cargo package directory is excluded, not only its source.
prepare_known_flake
printf 'touched\n' >"$WT/crates/main/README.md"
push_test_change crates/main/README.md 'touch flaky test crate'
jq --arg h "$HEAD0" 'map(.headSha = $h)' "$ST/run-list.json" >"$ST/run-list.tmp" && mv "$ST/run-list.tmp" "$ST/run-list.json"
known_ship
[ "$CODE" = 5 ] || fail "test crate directory diff must refuse: out=[$OUT] err=[$ERR]"
expect_refused KNOWN-FLAKE
grep -q "check 3 failed.*red test 'tests::flaky'.*crates/main" <<<"$ERR" || fail "red test crate directory in diff: [$ERR]"
no_merge "red test crate directory in diff"

# Cargo unit-test source mapping is outside the supported known-flake format.
prepare_known_flake
ship --known-flake 166 --by flywheel --gate "$CARGO_SOURCE_DIFF_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'known-flake: gate output is cargo libtest; only nextest gates are supported' <<<"$ERR" \
  || fail "cargo unit-test source log refusal: [$ERR]"
no_merge "cargo unit-test source refusal"

# A PASS status closes blocks and cannot hide libtest output from the unsupported-format check.
prepare_known_flake
PASS_LIBTEST_GATE="printf '%s\\n' 'PASS [ 0.001s] crate_name::integration_tests tests::ok' 'test tests::flaky_lib ... FAILED' 'failures:' 'test result: FAILED. 0 passed; 1 failed' 'FAIL [ 0.001s] crate_name::integration_tests $KNOWN_TEST' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed'; exit 100"
ship --known-flake 166 --by flywheel --gate "$PASS_LIBTEST_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'known-flake: gate output is cargo libtest; only nextest gates are supported' <<<"$ERR" \
  || fail "PASS before libtest refuses: [$ERR]"
no_merge "PASS before libtest refusal"

# A PASS line cannot open a test block that hides a following compile error.
prepare_known_flake
PASS_BUILD_GATE="printf '%s\\n' 'PASS [ 0.001s] crate_name::integration_tests tests::ok' 'error: could not compile \`fixture\` (test \"unit\")' 'FAIL [ 0.001s] crate_name::integration_tests $KNOWN_TEST' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed'; exit 100"
ship --known-flake 166 --by flywheel --gate "$PASS_BUILD_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'gate output contains a build or other non-test failure' <<<"$ERR" \
  || fail "PASS does not hide compile error: [$ERR]"
no_merge "PASS then compile error refusal"

# A keyword-free tool failure after Summary is outside the post-summary allowlist.
prepare_known_flake
MACHETE_AFTER_SUMMARY_GATE="printf '%s\\n' 'FAIL [ 0.001s] crate_name::integration_tests $KNOWN_TEST' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed' 'cargo-machete found the following unused dependencies in crates/main:'; exit 100"
ship --known-flake 166 --by flywheel --gate "$MACHETE_AFTER_SUMMARY_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'gate output contains a build or other non-test failure' <<<"$ERR" \
  || fail "cargo-machete after Summary refuses: [$ERR]"
no_merge "cargo-machete after Summary refusal"

# Any other non-test failure is refused before accepting known flakes.
prepare_known_flake
ship --known-flake 166 --by flywheel --gate "echo 'error[E0425]: cannot find value'; exit 1" --keep-branch
expect_refused KNOWN-FLAKE
grep -q 'gate exit status was 1\|build\|compile\|only test failures' <<<"$ERR" || fail "build failure message: [$ERR]"
no_merge "known-flake build failure"

prepare_known_flake
NON_TEST_GATE="printf '%s\\n' 'FAIL [ 0.001s] crate_name::integration_tests $KNOWN_TEST' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed' 'format check failed'; exit 100"
ship --known-flake 166 --by flywheel --gate "$NON_TEST_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -q 'other failure\|only test failures\|non-test failure' <<<"$ERR" || fail "non-test gate failure message: [$ERR]"
no_merge "known-flake non-test failure"

# Every nextest timeout is a named failure and must be ticketed like FAIL.
prepare_known_flake
TIMEOUT_UNNAMED_GATE="printf '%s\\n' 'TIMEOUT [ 0.001s] crate_name::integration_tests tests::not_ticketed' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed'; exit 100"
ship --known-flake 166 --by flywheel --gate "$TIMEOUT_UNNAMED_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq "red test 'tests::not_ticketed' is not named" <<<"$ERR" || fail "unticketed timeout is parsed as a named red test: [$ERR]"
no_merge "unticketed timeout"

prepare_known_flake
TIMEOUT_TICKETED_GATE="printf '%s\\n' 'TIMEOUT [ 0.001s] ( 1/1) crate_name::integration_tests $KNOWN_TEST' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed'; exit 100"
ship --known-flake 166 --by flywheel --gate "$TIMEOUT_TICKETED_GATE" --keep-branch
expect 0 "known-flake ticketed timeout merges"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "known-flake ticketed timeout merged output: [$OUT]"

# A rustfmt diff is a non-test gate failure even if a known test also failed.
prepare_known_flake
FMT_DIFF_GATE="printf '%s\\n' 'FAIL [ 0.001s] crate_name::integration_tests $KNOWN_TEST' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed' 'Diff in crates/main/src/lib.rs at line 1'; exit 100"
ship --known-flake 166 --by flywheel --gate "$FMT_DIFF_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'gate output contains a build or other non-test failure' <<<"$ERR" || fail "rustfmt diff is a non-test failure: [$ERR]"
no_merge "known-flake rustfmt failure"

prepare_known_flake
LEAKED_PROCESS_GATE="printf '%s\\n' 'FAIL [ 0.001s] crate_name::integration_tests $KNOWN_TEST' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed' 'leaked child process pid 123'; exit 100"
ship --known-flake 166 --by flywheel --gate "$LEAKED_PROCESS_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'gate output contains a build or other non-test failure' <<<"$ERR" || fail "leaked process is a non-test failure: [$ERR]"
no_merge "known-flake leaked process"

prepare_known_flake
NON_TEST_PANIC_GATE="printf '%s\\n' 'thread main panicked at build.rs:1:1:' 'FAIL [ 0.001s] crate_name::integration_tests $KNOWN_TEST' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed'; exit 100"
ship --known-flake 166 --by flywheel --gate "$NON_TEST_PANIC_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'gate output contains a build or other non-test failure' <<<"$ERR" || fail "non-test step panic is refused: [$ERR]"
no_merge "known-flake non-test panic"

prepare_known_flake
MALFORMED_TIMEOUT_GATE="printf '%s\\n' 'FAIL [ 0.001s] crate_name::integration_tests $KNOWN_TEST' 'TIMEOUT [ 0.001s]' 'Summary [ 0.001s] 1 test run: 0 passed, 1 failed'; exit 100"
ship --known-flake 166 --by flywheel --gate "$MALFORMED_TIMEOUT_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'gate output contains a build or other non-test failure' <<<"$ERR" || fail "unnamed timeout failure is refused: [$ERR]"
no_merge "unnamed timeout failure"

prepare_known_flake
NO_STATUS_SIGNAL_GATE='kill -TERM $$'
ship --known-flake 166 --by flywheel --gate "$NO_STATUS_SIGNAL_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq 'gate was terminated by signal' <<<"$ERR" || fail "signalled gate is refused: [$ERR]"
no_merge "signal without parsed test failure"

# Nextest failure statuses other than FAIL are still named, ticketable tests.
prepare_known_flake
jq -nc --arg segv 'tests::segv' --arg abrt 'tests::abrt' --arg leak 'tests::leak' --arg leak_fail 'tests::leak_fail' \
  '{state:"OPEN",body:([$segv,$abrt,$leak,$leak_fail] | join("\n")),createdAt:"2026-11-01T00:00:00Z",comments:[]}' >"$ST/ticket-166.json"
STATUS_GATE="printf '%s\\n' 'SIGSEGV [ 0.001s] ( 1/4) crate_name::integration_tests tests::segv' 'SIGABRT [ 0.001s] ( 2/4) crate_name::integration_tests tests::abrt' 'LEAK [ 0.001s] ( 3/4) crate_name::integration_tests tests::leak' 'LEAK-FAIL [ 0.001s] ( 4/4) crate_name::integration_tests tests::leak_fail' 'Summary [ 0.001s] 4 tests run: 0 passed, 4 failed'; exit 100"
ship --known-flake 166 --by flywheel --gate "$STATUS_GATE" --keep-branch
expect 0 "ticketed nextest statuses merge"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "ticketed nextest statuses merged output: [$OUT]"

# All four checks allow merge; a body or comment can name the test.
prepare_known_flake
jq -nc --arg name "$KNOWN_TEST" '{state:"OPEN",body:"",createdAt:"2026-11-06T00:00:00Z",comments:[{body:("known flake: " + $name),createdAt:"2026-11-07T00:00:00Z"}]}' >"$ST/ticket-166.json"
known_ship_multiple_tickets
expect 0 "known-flake ticketed red gate merges"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "known-flake merged output: [$OUT]"
[ -f "$ST/comment.txt" ] || fail "known-flake PR comment posted"
grep -Fq "$KNOWN_TEST" "$ST/comment.txt" || fail "known-flake PR comment names the red test"
grep -Fq '166' "$ST/comment.txt" || fail "known-flake PR comment names its ticket"
grep -Fq 'CI run id: 771' "$ST/comment.txt" || fail "known-flake PR comment names the CI run"
grep -Fq 'feature.txt' "$ST/comment.txt" || fail "known-flake PR comment lists diff paths"
grep -Fq 'script checked the red tests' "$ST/comment.txt" || fail "known-flake PR comment records file check and judgment"
grep -Fq 'crate directories against the diff' "$ST/comment.txt" || fail "known-flake PR comment records crate-directory check"
[ -f "$ST/ticket-comment-166.txt" ] || fail "known-flake ticket sighting posted"
grep -Fq 'PR #7' "$ST/ticket-comment-166.txt" || fail "ticket sighting names the PR"
grep -Fq "$HEAD0" "$ST/ticket-comment-166.txt" || fail "ticket sighting names the PR head"
grep -Fq 'ship-pr-7-gate.' "$ST/ticket-comment-166.txt" || fail "ticket sighting names the gate output"
[ "$(grep -c '^gh pr comment 7 ' "$ST/gh.log")" -eq 1 ] || fail "known-flake posts one PR comment"
[ "$(grep -c '^gh issue comment 166 ' "$ST/gh.log")" -eq 1 ] || fail "known-flake posts one ticket comment"
GATE_FILE="$(sed -n 's/^full gate output: //p' <<<"$OUT")"
case "$GATE_FILE" in "$TMPDIR"/ship-pr-7-gate.*) ;; *) fail "known-flake keeps the gate output path: [$GATE_FILE]" ;; esac
[ -f "$GATE_FILE" ] || fail "known-flake retains the gate output file: [$GATE_FILE]"

# Step 7 checks the PR merged with a newly moved base using the same acceptance.
prepare_known_flake
echo "$NOSTRICT" >"$ST/rules"
checks_hook "$BUMP_MAIN"
BEFORE_KNOWN_GATE_COUNT="$(find "$TMPDIR" -maxdepth 1 -type f -name 'ship-pr-7-gate.*' | wc -l | tr -d ' ')"
known_ship
expect 0 "known-flake step-7 gate on a moved base"
[ "$(tail -n 1 <<<"$OUT")" = "merged $MERGE_SHA" ] || fail "step-7 known-flake merged output: [$OUT]"
[ "$(find "$TMPDIR" -maxdepth 1 -type f -name 'ship-pr-7-gate.*' | wc -l | tr -d ' ')" -ge "$((BEFORE_KNOWN_GATE_COUNT + 2))" ] \
  || fail "step-7 acceptance retains both gate output files"
grep -Fq 'ship-pr-7-gate.' "$ST/comment.txt" || fail "step-7 PR comment records its gate output"
grep -Fq 'ship-pr-7-gate.' "$ST/ticket-comment-166.txt" || fail "step-7 ticket comment records its gate output"

# Step 7 refuses by the same ordered ticket check and restores the pinned head.
prepare_known_flake
echo "$NOSTRICT" >"$ST/rules"
checks_hook "$BUMP_MAIN"
STEP7_UNNAMED_GATE='if [ ! -e "$ST/step7-ran" ]; then touch "$ST/step7-ran"; printf "%s\\n" "FAIL [ 0.001s] crate_name::integration_tests tests::flaky" "Summary [ 0.001s] 1 test run: 0 passed, 1 failed"; else printf "%s\\n" "TIMEOUT [ 0.001s] crate_name::integration_tests tests::different" "Summary [ 0.001s] 1 test run: 0 passed, 1 failed"; fi; exit 100'
ship --known-flake 166 --by flywheel --gate "$STEP7_UNNAMED_GATE" --keep-branch
expect_refused KNOWN-FLAKE
grep -Fq "red test 'tests::different' is not named" <<<"$ERR" || fail "step-7 ticket refusal names the first failed check: [$ERR]"
[ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD0" ] || fail "step-7 known-flake refusal restores pinned head"
no_merge "step-7 unnamed red test"

echo "ship-pr: all cases passed"

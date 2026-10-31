#!/usr/bin/env bash
# Tests for bin/review-pr start/collect, using stand-in delegate/gh
# functions and a throwaway git repo as CLONE (no network, no models).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REVIEW="$SCRIPT_DIR/../bin/review-pr"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-review-pr.XXXXXX")"
trap 'rm -rf "$T"' EXIT

export TMPDIR="$T/tmp"
export REVIEW_PR_RUN_ROOT="$T/runs"
export JOB_RECORD_SYSTEM_DIR="$T/no-system-jobs"
unset DELEGATE_JOBS_DIR
mkdir -p "$TMPDIR" "$T/canned" "$T/state" "$T/override"

# --- throwaway repos: ORIGIN carries refs/pull/7/head, CLONE is cloned from it
git init -q -b main "$T/origin"
git -C "$T/origin" config user.email t@t
git -C "$T/origin" config user.name t
echo v1 >"$T/origin/file.txt"
git -C "$T/origin" add .
git -C "$T/origin" commit -qm init
FAKE_SHA="$(git -C "$T/origin" rev-parse HEAD)"
SHORT="${FAKE_SHA:0:8}"
echo v2 >"$T/origin/file.txt"
git -C "$T/origin" diff >"$T/diff.txt"
git -C "$T/origin" checkout -q -- file.txt
git -C "$T/origin" update-ref refs/pull/7/head "$FAKE_SHA"
# PR 8: NEW_SHA is one commit on top of main (OLD_SHA is main's tip).
OLD_SHA="$FAKE_SHA"
git -C "$T/origin" checkout -q -b feat
echo pr >"$T/origin/pr.txt"
git -C "$T/origin" add pr.txt
git -C "$T/origin" commit -qm pr
NEW_SHA="$(git -C "$T/origin" rev-parse HEAD)"
git -C "$T/origin" checkout -q main
git -C "$T/origin" update-ref refs/pull/8/head "$NEW_SHA"
# PR 9 commits .review-context as a symlink to an external test directory.
mkdir -p "$T/context-target"
git -C "$T/origin" checkout -q -b context-link main
ln -s "$T/context-target" "$T/origin/.review-context"
git -C "$T/origin" add .review-context
git -C "$T/origin" commit -qm context-link
SYMLINK_SHA="$(git -C "$T/origin" rev-parse HEAD)"
git -C "$T/origin" checkout -q main
git -C "$T/origin" update-ref refs/pull/9/head "$SYMLINK_SHA"
EXPECTED_NEW_PID="$(git -C "$T/origin" diff "main...$NEW_SHA" | git patch-id --stable | awk '{print $1}')"
[ -n "$EXPECTED_NEW_PID" ] || fail "fixture new patch-id computable"
git clone -q "$T/origin" "$T/clone"
EXPECTED_PID="$(git patch-id --stable <"$T/diff.txt" | awk '{print $1}')"
[ -n "$EXPECTED_PID" ] || fail "fixture patch-id computable"

# --- fake gh
gh() (
  set -euo pipefail
  if [ "$1" = "api" ]; then
    # check runs of a commit, as gh api --jq emits them: name, status, conclusion, started_at, id
    # plus review-pr comment history for the refusal guard, as gh api --jq emits them
    ep="${*: -1}"
    case "$ep" in
      repos/O/N/issues/*/comments)
        if [ -e "$T/state/fail-comments" ]; then echo "fake gh: comments failed" >&2; exit 1; fi
        if [ ! -f "$T/state/comments.json" ]; then exit 0; fi
        jq_expr=""; prev=""
        for a in "$@"; do
          if [ "$prev" = "--jq" ]; then jq_expr="$a"; break; fi
          case "$a" in --jq) prev="--jq";; esac
        done
        [ -n "$jq_expr" ] || { echo "fake gh: missing --jq for comments" >&2; exit 2; }
        jq -r "$jq_expr" "$T/state/comments.json"
        exit 0
        ;;
      repos/O/N/commits/*/check-runs) ;;
      *) echo "fake gh: unknown api $ep" >&2; exit 2;;
    esac
    printf '%s\n' "$ep" >>"$T/state/api.txt"
    if [ -n "${CI_RUNS_FILE:-}" ]; then cat "$CI_RUNS_FILE"; exit 0; fi
    awk -F'\t' 'NF >= 2 {
      if ($2 == "pass") { st = "completed"; c = "success" }
      else if ($2 == "fail") { st = "completed"; c = "failure" }
      else if ($2 == "cancel") { st = "completed"; c = "cancelled" }
      else { st = "in_progress"; c = "" }
      printf "%s\t%s\t%s\t2026-10-09T00:00:00Z\t%d\n", $1, st, c, NR }' "$T/checks.txt"
    exit 0
  fi
  if [ "$1" = "issue" ]; then
    shift
    [ "$1" = "view" ] || { echo "fake gh: unknown issue command $1" >&2; exit 2; }
    issue_n="$2"; shift 2
    issue_mode="BODY"
    issue_flag="body"
    while [ $# -gt 0 ]; do case "$1" in
      --repo) shift 2;;
      --comments) issue_mode="COMMENTS"; issue_flag="comments"; shift;;
      *) echo "fake gh: unknown issue view arg $1" >&2; exit 2;;
    esac; done
    printf '%s %s\n' "$issue_n" "$issue_flag" >>"$T/state/issue-calls.txt"
    if [ -e "$T/state/fail-issue" ]; then echo "fake gh: issue #$issue_n failed" >&2; exit 1; fi
    if [ "$issue_flag" = "comments" ] && [ -e "$T/state/fail-issue-comments" ]; then
      echo "fake gh: issue #$issue_n comments failed" >&2; exit 1
    fi
    printf 'ISSUE-%s %s\n' "$issue_n" "$issue_mode"
    exit 0
  fi
  [ "$1" = "pr" ] || { echo "fake gh: only pr/issue supported" >&2; exit 2; }
  shift
  case "$1" in
    view)
      if [ "${5:-}" = "--json" ] && [ "${6:-}" = "number" ]; then
        if [ -e "$T/state/not-pr" ]; then
          echo "GraphQL: Could not resolve to a PullRequest with the number of $2. (repository.pullRequest)" >&2
          exit 1
        fi
        printf '{"number":%s}\n' "$2"; exit 0
      fi
      if [ "${5:-}" = "--json" ] && [ "${6:-}" = "isDraft" ]; then
        if [ -e "$T/state/fail-draft" ]; then echo "fake gh: draft lookup failed" >&2; exit 1; fi
        if [ -e "$T/state/draft" ]; then echo true; else echo false; fi; exit 0
      fi
      if [ "${5:-}" = "--json" ] && [ "${6:-}" = "body" ]; then
        printf '%s\n' "$2" >>"$T/state/body-calls.txt"
        if [ -e "$T/state/fail-body" ]; then echo "fake gh: body failed" >&2; exit 1; fi
        if [ -f "$T/state/pr-body.txt" ]; then cat "$T/state/pr-body.txt"; else printf '\n'; fi
        exit 0
      fi
      h="$FAKE_SHA"
      if [ "$2" = "9" ]; then h="$SYMLINK_SHA"; fi
      if [ -f "$T/state/heads.txt" ]; then
        h="$(head -1 "$T/state/heads.txt")"
        if [ "$(wc -l <"$T/state/heads.txt")" -gt 1 ]; then
          tail -n +2 "$T/state/heads.txt" >"$T/state/heads.tmp"; mv "$T/state/heads.tmp" "$T/state/heads.txt"
        fi
      fi
      printf '{"headRefOid":"%s","baseRefName":"main"}\n' "$h";;
    diff)
      if [ -e "$T/state/fail-diff" ]; then echo "fake gh: diff failed" >&2; exit 1; fi
      if [ ! -e "$T/state/empty-diff" ]; then cat "$T/diff.txt"; fi
      ;;
    checks) cat "$T/checks.txt";;
    comment)
      if [ -e "$T/state/fail-comment" ]; then echo "fake gh: comment failed" >&2; exit 1; fi
      pr="$2"; shift 2
      body=""
      while [ $# -gt 0 ]; do case "$1" in
        --repo) shift 2;;
        --body-file) body="$2"; shift 2;;
        *) shift;;
      esac; done
      printf '%s' "$pr" >"$T/state/comment-pr.txt"
      cp "$body" "$T/state/comment.md"
      cat "$body" >>"$T/state/comments.log"
      printf '\n' >>"$T/state/comments.log"
      echo "https://example.invalid/x/pull/$pr"
      ;;
    *) echo "fake gh: unknown $1" >&2; exit 2;;
  esac
)

# --- fake delegate: run files the canned record keyed by worktree role
delegate() (
  set -euo pipefail
  cmd="${1:?}"; shift
  case "$cmd" in
    run)
      model=""; cwd=""; prompt=""
      while [ $# -gt 0 ]; do case "$1" in
        --model) model="$2"; shift 2;;
        --cwd) cwd="$2"; shift 2;;
        --prompt-file) prompt="$2"; shift 2;;
        *) shift;;
      esac; done
      role="${cwd##*-}"
      if [ -e "$T/state/fail-$role" ]; then echo "fake delegate: run failed for $role" >&2; exit 1; fi
      printf '%s %s\n' "$role" "$model" >>"$T/state/runs.txt"
      cp "$prompt" "$T/state/prompt-$role.md"
      id="job-$role"
      mkdir -p "${DELEGATE_JOBS_DIR:-${TMPDIR:-/tmp}/delegate-jobs}"
      cp "$T/canned/$role.json" "${DELEGATE_JOBS_DIR:-${TMPDIR:-/tmp}/delegate-jobs}/$id.json"
      printf '%s\n' "$id"
      ;;
    watch)
      printf 'watch %s\n' "$*" >>"$T/state/watch.txt"
      while [ $# -gt 0 ]; do case "$1" in --timeout) shift 2;; *) break;; esac; done
      if [ -e "$T/state/fail-watch" ]; then echo "fake delegate: watch timed out" >&2; exit 1; fi
      for id in "$@"; do cat "${TMPDIR:-/tmp}/delegate-jobs/$id.json"; done
      ;;
    *) echo "fake delegate: unknown $cmd" >&2; exit 2;;
  esac
)
# --- fake sleep: log the call, return at once
sleep() (
  echo "$*" >>"$T/state/sleeps.txt"
)
export T FAKE_SHA SYMLINK_SHA
export -f gh delegate sleep

write_record() {
  # write_record ROLE STATUS TEXT [GATE_EXIT]: GATE_EXIT absent means gateResult null.
  local gate_json="null" text_json
  if [ $# -ge 4 ]; then gate_json="{\"exitCode\": $4}"; fi
  text_json="$(printf '%s' "$3" | jq -Rs .)"
  printf '{"status":"%s","result":{"status":"%s","text":%s,"gateResult":%s}}\n' \
    "$2" "$2" "$text_json" "$gate_json" >"$T/canned/$1.json"
}

reset_state() {
  for old_run in "$REVIEW_PR_RUN_ROOT"/review-pr.run.*; do
    [ -d "$old_run" ] || continue
    for old_wt in "$old_run"/wt-*; do
      [ -d "$old_wt" ] || continue
      git -C "$T/clone" worktree remove --force "$old_wt" >/dev/null 2>&1 || rm -rf "$old_wt"
    done
  done
  git -C "$T/clone" worktree prune >/dev/null 2>&1 || true
  rm -rf "$REVIEW_PR_RUN_ROOT"/review-pr.run.* 2>/dev/null || true
  rm -f "$T/state/runs.txt" "$T/state/watch.txt" "$T/state/comment.md" "$T/state/comment-pr.txt" \
    "$T/state/pr-body.txt" "$T/state/body-calls.txt" "$T/state/comments.log"
  rm -f "$T/state"/fail-* "$T/state/not-pr" "$T/state/draft" "$T/state/heads.txt" "$T/state/sleeps.txt" "$T/state/empty-diff" "$T/state/issue-calls.txt"
  rm -f "$T/state/comments.json" "$T/state/fail-comments"
  rm -f "$T/state"/prompt-*.md "$TMPDIR"/delegate-jobs/*.json "$T/override"/*.json "$TMPDIR"/review-pr/* 2>/dev/null || true
}

plant_comment() {
  # plant_comment CREATED ID BODY: append one comment object to comments.json.
  created="$1"; cid="$2"; cbody="$3"
  if [ ! -f "$T/state/comments.json" ]; then printf '[]' >"$T/state/comments.json"; fi
  tmp_plant="$(mktemp "$T/plant.XXXXXX")"
  jq --arg created "$created" --argjson cid "$cid" --arg body "$cbody" \
    '. + [{created_at: $created, id: $cid, body: $body}]' \
    "$T/state/comments.json" >"$tmp_plant" && mv "$tmp_plant" "$T/state/comments.json"
}

start_review() {
  # start_review ...args: run review-pr start, stdout is the "<role> <id>" lines.
  bash "$REVIEW" start "$@"
}

worktree_for() {
  sed -n 's/^worktree=//p' "$TMPDIR/review-pr/job-$1"
}

reset_with_approvals() {
  # reset_state plus the shared all-approve fixture: CI pass plus APPROVE
  # records for the three review roles. Used by the refusal and
  # full-rereview scenarios; each keeps its own comments and assertions.
  reset_state
  printf 'ci\tpass\n' >"$T/checks.txt"
  write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
  write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
  write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
}

stale_ts_for() {
  # stale_ts_for AGE: touch -t timestamp for AGE (hours by default;
  # trailing h for hours, m for minutes). Keeps bare numbers meaning hours
  # so existing callers are unchanged.
  stale_age_spec="$1"
  case "$stale_age_spec" in
    *m) stale_n="${stale_age_spec%m}"; stale_unit="M"; stale_word="minutes";;
    *h) stale_n="${stale_age_spec%h}"; stale_unit="H"; stale_word="hours";;
    *) stale_n="$stale_age_spec"; stale_unit="H"; stale_word="hours";;
  esac
  date -v-"${stale_n}${stale_unit}" +%Y%m%d%H%M 2>/dev/null || date -d "$stale_n $stale_word ago" +%Y%m%d%H%M
}

stale_state() {
  # stale_state RUN_DIR JID ROLE STATE_AGE STATUS CLONE [RECORD_AGE]: plant
  # one stale-run fixture: a real worktree RUN_DIR/wt-ROLE added from the
  # fixture clone, a state file TMPDIR/review-pr/JID aged STATE_AGE, and,
  # unless STATUS is NOREC, a job record carrying that status aged
  # RECORD_AGE (default STATE_AGE, so existing callers age both together).
  stale_run_dir="$1"; stale_jid="$2"; stale_role="$3"
  stale_age="$4"; stale_status="$5"; stale_clone="$6"
  stale_rec_age="${7:-$4}"
  mkdir -p "$TMPDIR/review-pr" "$TMPDIR/delegate-jobs"
  git -C "$T/clone" worktree add -q --detach "$stale_run_dir/wt-$stale_role" "$FAKE_SHA" || fail "stale fixture worktree setup"
  {
    printf 'role=%s\n' "$stale_role"
    printf 'repo=%s\n' "O/N"
    printf 'pr=%s\n' "7"
    printf 'sha=%s\n' "$FAKE_SHA"
    printf 'patch_id=%s\n' "none"
    printf 'model=%s\n' "M"
    printf 'clone=%s\n' "$stale_clone"
    printf 'worktree=%s\n' "$stale_run_dir/wt-$stale_role"
    printf 'run_dir=%s\n' "$stale_run_dir"
  } >"$TMPDIR/review-pr/$stale_jid"
  if [ "$stale_status" = "NOREC" ]; then
    rm -f "$TMPDIR/delegate-jobs/$stale_jid.json"
  else
    printf '{"status":"%s"}\n' "$stale_status" >"$TMPDIR/delegate-jobs/$stale_jid.json"
    stale_rec_ts="$(stale_ts_for "$stale_rec_age")"
    touch -t "$stale_rec_ts" "$TMPDIR/delegate-jobs/$stale_jid.json" || fail "stale fixture record touch"
  fi
  stale_ts="$(stale_ts_for "$stale_age")"
  touch -t "$stale_ts" "$TMPDIR/review-pr/$stale_jid" || fail "stale fixture touch"
}

# --- case: review-mode success across start and collect
reset_state
printf 'ci\tpass\nlint\tpass\n' >"$T/checks.txt"
write_record standards DONE "too long, will quote the verdict lines
VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: CHANGES
P1 fix the off-by-one
STATUS: DONE" 0
write_record overbuild DONE "looks lean
VERDICT: APPROVE
STATUS: DONE" 0
start_out="$(start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 2>"$T/stderr.txt")" || fail "start exits 0"
[ "$start_out" = "standards job-standards
spec job-spec
overbuild job-overbuild
watch: delegate watch job-standards job-spec job-overbuild
collect: review-pr collect job-standards job-spec job-overbuild" ] || fail "start prints a role id line per job, then watch and collect with the ids: [$start_out]"
[ ! -e "$T/state/comment.md" ] || fail "start posts no comment"
[ -f "$TMPDIR/review-pr/job-standards" ] || fail "start saves state findable by job id"
[ -f "$TMPDIR/review-pr/job-spec" ] || fail "start saves state for every job"
[ -f "$TMPDIR/review-pr/job-overbuild" ] || fail "start saves state for every job"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "3" ] || fail "start leaves the worktrees for the jobs"
[ ! -e "$T/state/watch.txt" ] || fail "start does not wait"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>"$T/stderr.txt")" || fail "collect exits 0"
[ "$(printf '%s' "$out" | head -1)" = "patch-id $EXPECTED_PID" ] || fail "collect patch-id line"
grep -q "^VERDICT standards: APPROVE$" <<<"$out" || fail "collect carries the standards VERDICT"
grep -q "^VERDICT spec: CHANGES$" <<<"$out" || fail "collect carries VERDICT lines"
grep -q "^VERDICT overbuild: APPROVE$" <<<"$out" || fail "collect labels the overbuild verdict"
grep -q "^VERDICT: APPROVE$" <<<"$out" && fail "overbuild verdict is never bare"
grep -q "^P1 fix the off-by-one$" <<<"$out" || fail "collect carries P1 lines"
grep -q "^CI $SHORT pass$" <<<"$out" || fail "collect CI line"
grep -q UNFINISHED <<<"$out" && fail "collect has no UNFINISHED"
leftovers="$(printf '%s' "$out" | grep -vE '^(patch-id |VERDICT|P[123] |FIX-OK|FIX-INCOMPLETE|CI |UNFINISHED |BAD-VERDICT )' || true)"
[ -z "$leftovers" ] || fail "collect stdout shapes only: [$leftovers]"
[ "$(cat "$T/state/comment-pr.txt")" = "7" ] || fail "comment posted to PR 7"
[ "$(head -1 "$T/state/comment.md")" = "review-pr: patch-id $EXPECTED_PID, head $FAKE_SHA" ] || fail "comment first line"
grep -q '^## standards (M)$' "$T/state/comment.md" || fail "comment standards heading"
grep -q '^## spec (M)$' "$T/state/comment.md" || fail "comment spec heading"
grep -q '^## overbuild (M2)$' "$T/state/comment.md" || fail "comment overbuild heading"
grep -q 'P1 fix the off-by-one' "$T/state/comment.md" || fail "comment carries full text"
grep -q 'Code review (Spec axis) of PR #7 in O/N for issue #1 (spec #2)' "$T/state/prompt-spec.md" || fail "spec brief filled"
grep -q 'Standards axis' "$T/state/prompt-standards.md" || fail "standards brief names its axis"
grep -q '__[A-Z]' "$T/state/prompt-standards.md" && fail "standards brief has no placeholders left"
grep -q '__[A-Z]' "$T/state/prompt-spec.md" && fail "spec brief has no placeholders left"
grep -q '__[A-Z]' "$T/state/prompt-overbuild.md" && fail "overbuild brief has no placeholders left"
grep -q 'workflow doc is none' "$T/state/prompt-spec.md" || fail "workflow doc defaults to none"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "0" ] || fail "collect removes the worktrees"
[ -z "$(ls -d "$REVIEW_PR_RUN_ROOT"/review-pr.run.* 2>/dev/null)" ] || fail "collect removes the run dir"
[ ! -e "$T/state/watch.txt" ] || fail "collect does not wait"

# --- case: repeated --issue values fill the spec brief together
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --issue 3 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "multi-issue start exits 0"
grep -q 'Code review (Spec axis) of PR #7 in O/N for issue #1 and #3 (spec #2)' \
  "$T/state/prompt-spec.md" || fail "spec brief joins multiple issues"
grep -q '__[A-Z]' "$T/state/prompt-spec.md" && fail "multi-issue review brief has no placeholders"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "multi-issue collect exits 0"

# --- case: three issues keep first-occurrence order and drop duplicates
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --issue 3 --issue 1 --issue 4 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "deduplicated multi-issue start exits 0"
grep -q 'Code review (Spec axis) of PR #7 in O/N for issue #1, #3 and #4 (spec #2)' \
  "$T/state/prompt-spec.md" || fail "review brief joins three distinct issues in order"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "deduplicated multi-issue collect exits 0"

# --- case: overbuild-only ticket fetch failure starts no job
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
: >"$T/state/fail-issue"
st=0
err="$(start_review 7 --repo O/N --cwd "$T/clone" --axes overbuild --issue 886 --spec 886 \
  --model M --overbuild-model M2 2>&1 >/dev/null)" || st=$?
[ "$st" -ne 0 ] || fail "overbuild-only issue fetch failure exits non-zero"
grep -q 'could not fetch ticket #886' <<<"$err" || fail "overbuild-only issue failure names ticket #886"
[ ! -e "$T/state/runs.txt" ] || fail "overbuild-only issue failure starts no job"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)" = "0" ] || fail "overbuild-only issue failure creates no worktree"
[ -z "$(ls -d "$REVIEW_PR_RUN_ROOT"/review-pr.run.* 2>/dev/null || true)" ] || \
  fail "overbuild-only issue failure removes its run dir"

# --- case: review worktrees receive the diff and ordered ticket text
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --issue 3 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "prefetch review start exits 0"
for role in standards spec overbuild; do
  wt="$(worktree_for "$role")"
  [ -f "$wt/.review-context/pr.diff" ] || fail "$role worktree holds the PR diff"
  cmp -s "$T/diff.txt" "$wt/.review-context/pr.diff" || fail "$role diff matches the fetched PR diff"
  ! grep -Eq '(^|[^[:alnum:]])gh[[:space:]]' "$T/state/prompt-$role.md" || fail "$role prompt does not tell the reviewer to run gh"
  ! grep -Eq '__[A-Z]' "$T/state/prompt-$role.md" || fail "$role prompt has no placeholders"
done
for n in 1 3 2; do
  issue_file="$(worktree_for spec)/.review-context/issue-$n.md"
  [ -f "$issue_file" ] || fail "spec worktree holds ticket #$n text"
  printf 'ISSUE-%s BODY\nISSUE-%s COMMENTS\n' "$n" "$n" >"$T/expected-issue.md"
  cmp -s "$T/expected-issue.md" "$issue_file" || fail "ticket #$n body precedes its comments"
  grep -Fq ".review-context/issue-$n.md" "$T/state/prompt-spec.md" || fail "spec prompt names ticket #$n file"
done
for n in 1 3 2; do
  issue_file="$(worktree_for overbuild)/.review-context/issue-$n.md"
  [ -f "$issue_file" ] || fail "overbuild worktree holds ticket #$n text"
  printf 'ISSUE-%s BODY\nISSUE-%s COMMENTS\n' "$n" "$n" >"$T/expected-issue.md"
  cmp -s "$T/expected-issue.md" "$issue_file" || fail "overbuild ticket #$n body precedes its comments"
  grep -Fq ".review-context/issue-$n.md" "$T/state/prompt-overbuild.md" || fail "overbuild prompt names ticket #$n file"
done
! find "$(worktree_for standards)/.review-context" -name 'issue-*.md' -print | grep -q . || \
  fail "standards worktree has no ticket text"
grep -Fq '.review-context/pr.diff' "$T/state/prompt-standards.md" || fail "standards prompt names the diff file"
grep -Fq '.review-context/pr.diff' "$T/state/prompt-spec.md" || fail "spec prompt names the diff file"
grep -Fq '.review-context/pr.diff' "$T/state/prompt-overbuild.md" || fail "overbuild prompt names the diff file"
printf '1 body\n1 comments\n3 body\n3 comments\n2 body\n2 comments\n' >"$T/expected-issue-calls.txt"
cmp -s "$T/expected-issue-calls.txt" "$T/state/issue-calls.txt" || fail "ticket fetches preserve issue order and fetch body then comments"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "prefetch review collect exits 0"

# --- case: a non-empty PR body reaches every reviewer as an untrusted claim
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
printf 'claim: 30-run load proof\n' >"$T/state/pr-body.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "non-empty body start exits 0"
for role in standards spec overbuild; do
  body_file="$(worktree_for "$role")/.review-context/pr-body.md"
  [ -f "$body_file" ] || fail "$role worktree holds the PR body"
  cmp -s "$T/state/pr-body.txt" "$body_file" || fail "$role worktree body matches the fetched body"
  grep -Fq "The PR body is the lane's claim, not ground truth. Check evidence it cites; do not trust it." \
    "$T/state/prompt-$role.md" || fail "$role prompt treats the PR body as an untrusted claim"
  grep -Fq '.review-context/pr-body.md' "$T/state/prompt-$role.md" || fail "$role prompt names the PR body file"
done
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "non-empty body collect exits 0"

for body_kind in empty whitespace; do
  reset_state
  printf 'ci\tpass\n' >"$T/checks.txt"
  if [ "$body_kind" = empty ]; then : >"$T/state/pr-body.txt"; else printf ' \t\n  \n' >"$T/state/pr-body.txt"; fi
  write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
  start_review 7 --repo O/N --cwd "$T/clone" --axes standards --model M >/dev/null 2>&1 || \
    fail "$body_kind body start exits 0"
  wt="$(worktree_for standards)/.review-context"
  [ ! -e "$wt/pr-body.md" ] || fail "$body_kind body creates no PR body file"
  ! grep -Fq "The PR body is the lane's claim" "$T/state/prompt-standards.md" || \
    fail "$body_kind body adds no claim line"
  bash "$REVIEW" collect job-standards >/dev/null 2>&1 || fail "$body_kind body collect exits 0"
done

# --- case: a --context pr-body.md is disambiguated from the fetched PR body
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
printf 'claim from PR\n' >"$T/state/pr-body.txt"
printf 'outside context\n' >"$T/pr-body.md"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --axes standards --model M --context "$T/pr-body.md" \
  >/dev/null 2>&1 || fail "body context collision start exits 0"
wt="$(worktree_for standards)/.review-context"
cmp -s "$T/state/pr-body.txt" "$wt/pr-body.md" || fail "the fetched body keeps its canonical path"
cmp -s "$T/pr-body.md" "$wt/1-pr-body.md" || fail "the context file gets a disambiguated path"
bash "$REVIEW" collect job-standards >/dev/null 2>&1 || fail "body context collision collect exits 0"

# --- case: a checked-out .review-context symlink cannot redirect the copy
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
start_review 9 --repo O/N --cwd "$T/clone" --axes standards --head "$SYMLINK_SHA" \
  --model M >/dev/null 2>&1 || fail "symlink context start exits 0"
wt="$(worktree_for standards)"
[ ! -L "$wt/.review-context" ] || fail "review context is a fresh directory, not the PR symlink"
[ -f "$wt/.review-context/pr.diff" ] || fail "fresh review context holds the diff"
[ ! -e "$T/context-target/pr.diff" ] || fail "copy does not write through the PR symlink"
bash "$REVIEW" collect job-standards >/dev/null 2>&1 || fail "symlink context collect exits 0"

# --- case: absent issue and spec default fetches the PR ticket only
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --axes spec --model M >/dev/null 2>&1 || fail "default ticket prefetch start exits 0"
wt="$(worktree_for spec)/.review-context"
[ -f "$wt/issue-7.md" ] || fail "spec worktree holds PR #7 as ticket text"
[ ! -e "$wt/issue-1.md" ] || fail "spec worktree fetches no unrelated ticket"
printf '7 body\n7 comments\n' >"$T/expected-issue-calls.txt"
cmp -s "$T/expected-issue-calls.txt" "$T/state/issue-calls.txt" || fail "default ticket fetches only the PR body and comments"
bash "$REVIEW" collect job-spec >/dev/null 2>&1 || fail "default ticket prefetch collect exits 0"

# --- case: an explicit spec joins the PR ticket and deduplicates issues
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --axes spec --spec 2 --model M >/dev/null 2>&1 || \
  fail "explicit spec prefetch start exits 0"
wt="$(worktree_for spec)/.review-context"
[ -f "$wt/issue-7.md" ] || fail "explicit spec fetches the PR ticket"
[ -f "$wt/issue-2.md" ] || fail "explicit spec fetches its ticket"
printf '7 body\n7 comments\n2 body\n2 comments\n' >"$T/expected-issue-calls.txt"
cmp -s "$T/expected-issue-calls.txt" "$T/state/issue-calls.txt" || fail "PR ticket precedes an explicit spec ticket"
bash "$REVIEW" collect job-spec >/dev/null 2>&1 || fail "explicit spec prefetch collect exits 0"

reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --axes spec --issue 2 --issue 2 --spec 2 \
  --model M >/dev/null 2>&1 || fail "duplicate spec ticket prefetch start exits 0"
wt="$(worktree_for spec)/.review-context"
[ -f "$wt/issue-2.md" ] || fail "duplicate spec ticket file exists"
printf '2 body\n2 comments\n' >"$T/expected-issue-calls.txt"
cmp -s "$T/expected-issue-calls.txt" "$T/state/issue-calls.txt" || fail "issue and spec duplicates fetch once"
bash "$REVIEW" collect job-spec >/dev/null 2>&1 || fail "duplicate spec ticket prefetch collect exits 0"

# --- case: only the spec axis fetches ticket text
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --axes standards --model M >/dev/null 2>&1 || fail "standards-only prefetch start exits 0"
[ -f "$(worktree_for standards)/.review-context/pr.diff" ] || fail "standards-only worktree holds the diff"
[ ! -e "$T/state/issue-calls.txt" ] || fail "standards-only run fetches no tickets"
bash "$REVIEW" collect job-standards >/dev/null 2>&1 || fail "standards-only prefetch collect exits 0"
start_review 7 --repo O/N --cwd "$T/clone" --axes spec --model M >/dev/null 2>&1 || fail "spec-only prefetch start exits 0"
[ -f "$(worktree_for spec)/.review-context/issue-7.md" ] || fail "spec-only run fetches the PR ticket"
bash "$REVIEW" collect job-spec >/dev/null 2>&1 || fail "spec-only prefetch collect exits 0"

# --- case: overbuild-only runs fetch and receive ticket text
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --axes overbuild --issue 886 --spec 886 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "overbuild-only prefetch start exits 0"
wt="$(worktree_for overbuild)/.review-context"
[ -f "$wt/issue-886.md" ] || fail "overbuild-only worktree holds ticket #886"
grep -Fq '.review-context/issue-886.md' "$T/state/prompt-overbuild.md" || \
  fail "overbuild-only prompt names ticket #886"
! grep -Eq '(^|[^[:alnum:]])gh[[:space:]]' "$T/state/prompt-overbuild.md" || \
  fail "overbuild-only prompt does not tell the reviewer to run gh"
bash "$REVIEW" collect job-overbuild >/dev/null 2>&1 || fail "overbuild-only prefetch collect exits 0"

# --- case: fetch failure stops before any worktree or job starts
for failed_fetch in fail-diff empty-diff fail-issue fail-issue-comments fail-body; do
  reset_state
  printf 'ci\tpass\n' >"$T/checks.txt"
  write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
  : >"$T/state/$failed_fetch"
  st=0
  err="$(start_review 7 --repo O/N --cwd "$T/clone" --head "$FAKE_SHA" --axes spec \
    --model M --issue 1 2>&1 >/dev/null)" || st=$?
  [ "$st" -ne 0 ] || fail "$failed_fetch exits non-zero"
  case "$failed_fetch" in
    fail-diff|empty-diff) grep -q 'could not fetch the diff of PR 7' <<<"$err" || fail "$failed_fetch names the PR diff";;
    fail-issue|fail-issue-comments) grep -q 'could not fetch ticket #1' <<<"$err" || fail "$failed_fetch names the ticket";;
    fail-body) grep -q 'could not fetch the body of PR 7' <<<"$err" || fail "$failed_fetch names the PR body";;
  esac
  [ ! -e "$T/state/runs.txt" ] || fail "$failed_fetch starts no job"
  [ "$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)" = "0" ] || fail "$failed_fetch creates no worktree"
  [ -z "$(ls -d "$REVIEW_PR_RUN_ROOT"/review-pr.run.* 2>/dev/null || true)" ] || fail "$failed_fetch removes its run dir"
done

# --- case: --issue without --spec defaults SPEC to the first --issue, not the PR
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "issue without spec start exits 0"
grep -q 'for issue #1 (spec #1)' "$T/state/prompt-spec.md" || fail "SPEC defaults to the first --issue, not the PR number"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "issue without spec collects"

# --- case: malformed issue values and issues in verify mode fail before launch
for bad_issue in '#3' '3x'; do
  reset_state
  start_review 7 --repo O/N --cwd "$T/clone" --issue "$bad_issue" --spec 2 \
    --model M --overbuild-model M2 >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "malformed --issue $bad_issue exits 2"
  [ ! -e "$T/state/runs.txt" ] || fail "malformed --issue $bad_issue starts no job"
done
# --- case: verify ignores start-only flags, one stderr note per flag, and launches
printf 'P1 findings text\n' >"$T/findings.txt"
write_record verify DONE "rechecked
FIX-OK all repaired
STATUS: DONE" 0
for ignored in "--issue 1" "--spec 2" "--overbuild-model M2"; do
  reset_state
  flag="${ignored%% *}"
  # shellcheck disable=SC2086
  start_out="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --verify "$T/findings.txt" \
    --since "$FAKE_SHA" $ignored 2>"$T/stderr-ignored.txt")" || fail "verify with $flag exits 0"
  [ "$start_out" = "verify job-verify
watch: delegate watch job-verify
collect: review-pr collect job-verify" ] || fail "verify with $flag prints the verify job lines: [$start_out]"
  grep -Fxq "review-pr: $flag is not used with --verify; ignored" "$T/stderr-ignored.txt" || \
    fail "verify with $flag prints its ignored note"
  [ "$(wc -l <"$T/state/runs.txt" | tr -d ' ')" = "1" ] || fail "verify with $flag launches its job"
  [ ! -e "$T/state/body-calls.txt" ] || fail "verify with $flag does not fetch the PR body"
  bash "$REVIEW" collect job-verify >/dev/null 2>&1 || fail "verify with $flag collects"
done
reset_state
start_review 7 --repo O/N --cwd "$T/clone" --model M --verify "$T/findings.txt" \
  --since "$FAKE_SHA" --issue 1 --issue 2 --spec 3 --overbuild-model M2 >/dev/null 2>"$T/stderr-ignored.txt" || \
  fail "verify with every start-only flag exits 0"
[ "$(grep -c '^review-pr: --issue is not used' "$T/stderr-ignored.txt")" = "1" ] || \
  fail "verify repeated --issue prints one note"
[ "$(grep -c 'is not used with --verify; ignored$' "$T/stderr-ignored.txt" || true)" = "3" ] || \
  fail "verify prints one note for each ignored flag"
[ "$(wc -l <"$T/state/runs.txt" | tr -d ' ')" = "1" ] || fail "verify with start-only flags runs exactly one job"
bash "$REVIEW" collect job-verify >/dev/null 2>&1 || fail "verify with start-only flags collects"

# --- case: a job that did not finish is UNFINISHED, never done; collect exits 1
reset_state
printf 'ci\tfail\n' >"$T/checks.txt"
write_record standards ERROR "something broke mid-run"
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
wt_standards="$(worktree_for standards)"
wt_spec="$(worktree_for spec)"
wt_overbuild="$(worktree_for overbuild)"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" && fail "unfinished collect exits 1"
rec="$TMPDIR/delegate-jobs/job-standards.json"
grep -q "^UNFINISHED standards ERROR gate=none $rec reason: something broke mid-run$" <<<"$out" || fail "unfinished names role status gate record"
grep -q "^CI $SHORT fail$" <<<"$out" || fail "failing CI line"
[ "$(cat "$T/state/comment-pr.txt")" = "7" ] || fail "unfinished still posts the comment"
[ -d "$wt_standards" ] || fail "unfinished keeps its worktree"
[ ! -d "$wt_spec" ] || fail "finished spec worktree is removed"
[ ! -d "$wt_overbuild" ] || fail "finished overbuild worktree is removed"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "1" ] || fail "unfinished keeps only its worktree"
grep -Fxq 'resume: delegate resume job-standards' <<<"$out" || fail "unfinished prints its resume command"
[ -f "$TMPDIR/review-pr/job-standards" ] || fail "unfinished state file is kept"
[ ! -e "$TMPDIR/review-pr/job-spec" ] || fail "finished spec state file is removed"
[ ! -e "$TMPDIR/review-pr/job-overbuild" ] || fail "finished overbuild state file is removed"
run_dir="$(sed -n 's/^run_dir=//p' "$TMPDIR/review-pr/job-standards")"
run_entries=("$run_dir"/*)
[ "${#run_entries[@]}" = "1" ] && [ "${run_entries[0]}" = "$wt_standards" ] || fail "unfinished run keeps only its worktree"

# --- case: one UNFINISHED job and one finished job keep only the resumable worktree
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec NEEDS_CONTEXT "Owner ruling needed before review can continue"
start_review 7 --repo O/N --cwd "$T/clone" --axes standards,spec --model M >/dev/null 2>&1 || \
  fail "mixed completion start exits 0"
wt_spec="$(worktree_for spec)"
wt_standards="$(worktree_for standards)"
run_dir="$(sed -n 's/^run_dir=//p' "$TMPDIR/review-pr/job-spec")"
out="$(bash "$REVIEW" collect job-standards job-spec 2>/dev/null)" && fail "mixed completion collect exits 1"
rec="$TMPDIR/delegate-jobs/job-spec.json"
grep -q "^UNFINISHED spec NEEDS_CONTEXT gate=none $rec$" <<<"$out" || fail "mixed completion reports unfinished spec"
[ "$(grep -Fxc 'resume: delegate resume job-spec' <<<"$out")" = "1" ] || fail "mixed completion prints one spec resume command"
! grep -q '^resume:.*job-standards$' <<<"$out" || fail "mixed completion prints no standards resume command"
[ -d "$wt_spec" ] || fail "mixed completion keeps the unfinished worktree"
[ ! -d "$wt_standards" ] || fail "mixed completion removes the finished worktree"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-spec')" = "1" ] || fail "mixed completion registers the unfinished worktree"
! git -C "$T/clone" worktree list | grep -q 'wt-standards' || fail "mixed completion unregisters the finished worktree"
grep -Fxq 'posted=1' "$TMPDIR/review-pr/job-spec" || fail "mixed completion marks its posted comment"
[ ! -e "$TMPDIR/review-pr/job-standards" ] || fail "mixed completion removes the finished state file"
run_entries=("$run_dir"/*)
[ "${#run_entries[@]}" = "1" ] && [ "${run_entries[0]}" = "$wt_spec" ] || fail "mixed completion run keeps only the unfinished worktree"
[ "$(grep -c '^review-pr: patch-id ' "$T/state/comments.log")" = "1" ] || fail "mixed completion posts one comment"

# --- case: re-collecting a kept id reads its state and never posts twice
rm -f "$T/state/comment-pr.txt" "$T/state/comment.md"
out="$(bash "$REVIEW" collect job-standards job-spec 2>/dev/null)" && fail "re-collecting unfinished spec exits 1"
grep -q '^COLLECTED job-standards ' <<<"$out" || fail "re-collect reprints the finished standards job"
grep -Fxq "patch-id $EXPECTED_PID" <<<"$out" || fail "re-collect reads the kept run header"
grep -q "^UNFINISHED spec NEEDS_CONTEXT gate=none $rec$" <<<"$out" || fail "re-collect reads the kept spec record"
[ "$(grep -Fxc 'resume: delegate resume job-spec' <<<"$out")" = "1" ] || fail "re-collect prints one resume command"
! grep -q '^UNFINISHED standards MISSING' <<<"$out" || fail "re-collect does not mark the finished job missing"
[ ! -e "$T/state/comment-pr.txt" ] || fail "re-collect does not post another comment"
[ -d "$wt_spec" ] || fail "re-collect keeps the unfinished worktree"
grep -Fxq 'posted=1' "$TMPDIR/review-pr/job-spec" || fail "re-collect keeps its posted marker"
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
cp "$T/canned/spec.json" "$TMPDIR/delegate-jobs/job-spec.json"
out="$(bash "$REVIEW" collect job-spec 2>/dev/null)" || fail "collecting the resumed finished spec exits 0"
grep -Fxq 'VERDICT spec: APPROVE' <<<"$out" || fail "re-collect prints the resumed verdict"
[ ! -e "$T/state/comment-pr.txt" ] || fail "collecting a posted kept job does not post again"
[ ! -e "$T/state/comment.md" ] || fail "collecting a posted kept job creates no new comment body"
[ ! -d "$wt_spec" ] || fail "finished resumed worktree is removed"
[ ! -e "$TMPDIR/review-pr/job-spec" ] || fail "finished resumed state file is removed"
[ ! -d "$run_dir" ] || fail "finished resumed run directory is removed"
[ "$(grep -c '^review-pr: patch-id ' "$T/state/comments.log")" = "1" ] || fail "re-collect never duplicates the comment"

# --- case: mixed collect posts only for the fresh run
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record spec NEEDS_CONTEXT "Owner ruling needed before review can continue"
start_review 7 --repo O/N --cwd "$T/clone" --axes spec --model M >/dev/null 2>&1 || \
  fail "kept-run mixed fixture start exits 0"
wt_spec="$(worktree_for spec)"
out="$(bash "$REVIEW" collect job-spec 2>/dev/null)" && fail "kept-run mixed fixture collect exits 1"
grep -Fxq 'posted=1' "$TMPDIR/review-pr/job-spec" || fail "kept-run mixed fixture stores its posted marker"
fresh_run_dir="$REVIEW_PR_RUN_ROOT/review-pr.run.fresh"
mkdir -p "$fresh_run_dir" "$TMPDIR/review-pr" "$TMPDIR/delegate-jobs"
fresh_wt="$fresh_run_dir/wt-spec-fresh"
git -C "$T/clone" worktree add -q --detach "$fresh_wt" "$FAKE_SHA" || fail "fresh mixed worktree setup"
{
  printf 'role=spec\nrepo=O/N\npr=7\nsha=%s\npatch_id=fresh-group-pid\n' "$FAKE_SHA"
  printf 'model=Fresh-M\naxes=spec\nclone=%s\nworktree=%s\nrun_dir=%s\n' "$T/clone" "$fresh_wt" "$fresh_run_dir"
} >"$TMPDIR/review-pr/job-fresh"
write_record spec DONE "VERDICT spec: APPROVE
fresh group marker" 0
cp "$T/canned/spec.json" "$TMPDIR/delegate-jobs/job-fresh.json"
out="$(bash "$REVIEW" collect job-spec job-fresh 2>/dev/null)" && fail "mixed kept and fresh collect exits 1"
grep -q '^UNFINISHED spec NEEDS_CONTEXT ' <<<"$out" || fail "mixed collect still reports the kept job"
[ "$(grep -c '^review-pr: patch-id ' "$T/state/comments.log")" = "2" ] || fail "mixed collect posts one new comment"
[ "$(grep -c 'fresh group marker' "$T/state/comments.log")" = "1" ] || fail "mixed collect posts the fresh job once"
grep -Fq 'review-pr: patch-id fresh-group-pid' "$T/state/comments.log" || fail "mixed comment uses the fresh run header"
[ -d "$wt_spec" ] || fail "mixed collect keeps the already-posted worktree"
grep -Fxq 'posted=1' "$TMPDIR/review-pr/job-spec" || fail "mixed collect preserves the kept posted marker"
[ ! -d "$fresh_wt" ] || fail "mixed collect removes the finished fresh worktree"
[ ! -e "$TMPDIR/review-pr/job-fresh" ] || fail "mixed collect removes the finished fresh state file"
[ ! -d "$fresh_run_dir" ] || fail "mixed collect removes the fresh run directory"

# --- case: re-collecting one kept job preserves every unfinished sibling
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards ERROR "standards review stopped"
write_record spec NEEDS_CONTEXT "Owner ruling needed before review can continue"
start_review 7 --repo O/N --cwd "$T/clone" --axes standards,spec --issue 1 --spec 2 \
  --model M >/dev/null 2>&1 || fail "two-kept fixture start exits 0"
wt_standards="$(worktree_for standards)"
wt_spec="$(worktree_for spec)"
run_dir="$(sed -n 's/^run_dir=//p' "$TMPDIR/review-pr/job-standards")"
out="$(bash "$REVIEW" collect job-standards job-spec 2>/dev/null)" && fail "two-kept fixture collect exits 1"
[ "$(grep -Fxc 'resume: delegate resume job-standards' <<<"$out")" = "1" ] || fail "two-kept fixture prints standards resume"
[ "$(grep -Fxc 'resume: delegate resume job-spec' <<<"$out")" = "1" ] || fail "two-kept fixture prints spec resume"
[ -d "$wt_standards" ] && [ -d "$wt_spec" ] || fail "two-kept fixture keeps both unfinished worktrees"
grep -Fxq 'posted=1' "$TMPDIR/review-pr/job-standards" || fail "two-kept fixture marks standards posted"
grep -Fxq 'posted=1' "$TMPDIR/review-pr/job-spec" || fail "two-kept fixture marks spec posted"
run_entries=("$run_dir"/*)
[ "${#run_entries[@]}" = "2" ] && [ "${run_entries[0]}" = "$run_dir/wt-spec" ] && \
  [ "${run_entries[1]}" = "$run_dir/wt-standards" ] || fail "two-kept run contains only its unfinished worktrees"
awk -F= '$1 != "posted" { print }' "$TMPDIR/review-pr/job-spec" >"$T/state/job-spec.tmp" && \
  mv "$T/state/job-spec.tmp" "$TMPDIR/review-pr/job-spec"
out="$(bash "$REVIEW" collect job-standards job-spec 2>/dev/null)" && fail "partial kept re-collect exits 1"
grep -q '^UNFINISHED standards ERROR ' <<<"$out" || fail "partial kept re-collect reports standards"
[ -d "$wt_standards" ] && [ -d "$wt_spec" ] || fail "partial kept re-collect preserves the unrequested sibling"
[ -f "$TMPDIR/review-pr/job-spec" ] || fail "partial kept re-collect preserves the sibling state"
grep -Fxq 'posted=1' "$TMPDIR/review-pr/job-spec" || fail "partial kept re-collect repairs its sibling posted marker"
run_entries=("$run_dir"/*)
[ "${#run_entries[@]}" = "2" ] && [ "${run_entries[0]}" = "$run_dir/wt-spec" ] && \
  [ "${run_entries[1]}" = "$run_dir/wt-standards" ] || fail "partial kept re-collect leaves both worktrees registered"
[ "$(grep -c '^review-pr: patch-id ' "$T/state/comments.log")" = "1" ] || fail "partial kept re-collect does not repost"

# --- case: an ERROR job's UNFINISHED line names the reason from the record
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards ERROR "$(printf 'Your authentication token has expired.\nmore')"
write_record spec DONE "VERDICT spec: APPROVE\nSTATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" && fail "error reason collect exits 1"
printf '%s\n' "$out" | grep "UNFINISHED standards ERROR" | grep -q "reason: Your authentication token has expired\." || fail "ERROR line names the record reason"
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards ERROR ""
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" && fail "empty reason collect exits 1"
grep -q "^UNFINISHED standards ERROR" <<<"$out" || fail "empty error text is still UNFINISHED"
grep -q "reason:" <<<"$out" && fail "empty error text prints no reason"

# --- case: DONE without a verdict line is UNFINISHED; collect exits 1
reset_state
: >"$T/checks.txt"
write_record standards DONE "all good, nothing to report
STATUS: DONE" 3
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" && fail "no-verdict collect exits 1"
grep -q "^UNFINISHED standards DONE gate=3 .*/job-standards.json$" <<<"$out" || fail "no-verdict UNFINISHED with gate"
grep -q "^CI $SHORT none$" <<<"$out" || fail "empty checks CI none"

# --- case: a draft PR with no check runs prints CI draft; a non-draft one stays none
reset_state
: >"$T/checks.txt"
: >"$T/state/draft"
write_record standards DONE "all good, nothing to report
VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "draft start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" || true
grep -qx "CI $SHORT draft" <<<"$out" || fail "draft PR with no runs prints CI draft, got [$(grep '^CI ' <<<"$out")]"
reset_state
: >"$T/checks.txt"
write_record standards DONE "all good, nothing to report
VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "non-draft start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" || true
grep -qx "CI $SHORT none" <<<"$out" || fail "non-draft PR with no runs prints CI none, got [$(grep '^CI ' <<<"$out")]"

# --- case: draft CI display uses draft-specific results
reset_state
: >"$T/checks.txt"
: >"$T/state/draft"
printf 'ci\tcompleted\tsuccess\t2026-10-09T10:00:00Z\t1\nlint\tcompleted\tskipped\t2026-10-09T10:00:01Z\t2\n' >"$T/canned/draft-skipped.tsv"
export CI_RUNS_FILE="$T/canned/draft-skipped.tsv"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "draft skipped start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" || true
draft_skipped_ci="$(grep '^CI ' <<<"$out")"
[ "$draft_skipped_ci" = "CI $SHORT draft" ] || fail "draft with skipped check should print CI $SHORT draft, got [$draft_skipped_ci]"
rm -f "$T/state/draft"
unset CI_RUNS_FILE

reset_state
: >"$T/checks.txt"
: >"$T/state/draft"
printf 'ci\tcompleted\tfailure\t2026-10-09T10:00:00Z\t1\nlint\tcompleted\tsuccess\t2026-10-09T10:00:01Z\t2\n' >"$T/canned/draft-failure.tsv"
export CI_RUNS_FILE="$T/canned/draft-failure.tsv"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "draft failure start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" || true
draft_failure_ci="$(grep '^CI ' <<<"$out")"
[ "$draft_failure_ci" = "CI $SHORT draft-fail" ] || fail "draft with failed check should print CI $SHORT draft-fail, got [$draft_failure_ci]"
rm -f "$T/state/draft"
unset CI_RUNS_FILE

reset_state
: >"$T/checks.txt"
rm -f "$T/state/draft"
printf 'ci\tcompleted\tsuccess\t2026-10-09T10:00:00Z\t1\nlint\tcompleted\tskipped\t2026-10-09T10:00:01Z\t2\n' >"$T/canned/ready-skipped.tsv"
export CI_RUNS_FILE="$T/canned/ready-skipped.tsv"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "ready skipped start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" || true
ready_skipped_ci="$(grep '^CI ' <<<"$out")"
[ "$ready_skipped_ci" = "CI $SHORT pass" ] || fail "ready PR with skipped check should print CI $SHORT pass, got [$ready_skipped_ci]"
rm -f "$T/state/draft"
unset CI_RUNS_FILE

reset_state
: >"$T/checks.txt"
: >"$T/state/fail-draft"
printf 'ci\tcompleted\tsuccess\t2026-10-09T10:00:00Z\t1\nlint\tcompleted\tskipped\t2026-10-09T10:00:01Z\t2\n' >"$T/canned/draft-lookup-failure.tsv"
export CI_RUNS_FILE="$T/canned/draft-lookup-failure.tsv"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "draft lookup failure start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" || true
draft_lookup_failure_ci="$(grep '^CI ' <<<"$out")"
[ "$draft_lookup_failure_ci" = "CI $SHORT none" ] || fail "failed draft lookup should print CI $SHORT none, got [$draft_lookup_failure_ci]"
unset CI_RUNS_FILE

# --- case: a decorated verdict is accepted
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE '  `VERDICT standards: APPROVE`
STATUS: DONE' 0
write_record spec DONE '**VERDICT spec: CHANGES**
P1 a.ts:1 — defect — fix
STATUS: DONE' 0
write_record overbuild DONE '**VERDICT: CHANGES**
P3 a.ts:2 — yagni — cut helper — replace with inline
STATUS: DONE' 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" || fail "decorated verdicts collect exits 0"
grep -q "^VERDICT standards: APPROVE$" <<<"$out" || fail "decorated standards verdict accepted"
grep -q "^VERDICT spec: CHANGES$" <<<"$out" || fail "decorated spec verdict accepted"
grep -q "^VERDICT overbuild: CHANGES$" <<<"$out" || fail "decorated overbuild verdict accepted"
grep -q UNFINISHED <<<"$out" && fail "decorated verdicts are finished"
grep -q BAD-VERDICT <<<"$out" && fail "decorated verdicts are not bad"

# --- case: an unrecognised verdict fails loudly, never UNFINISHED; collect exits 1
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: REQUEST_CHANGES
P3 x.ts:1 — yagni — cut foo — replace with bar
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" && fail "bad verdict collect exits 1"
grep -q "^BAD-VERDICT overbuild VERDICT: REQUEST_CHANGES$" <<<"$out" || fail "bad verdict names role and line"
grep -q UNFINISHED <<<"$out" && fail "bad verdict is never UNFINISHED"

# --- case: an unknown job id is UNFINISHED; collect exits 1
reset_state
: >"$T/checks.txt"
out="$(bash "$REVIEW" collect job-nope 2>/dev/null)" && fail "unknown id collect exits 1"
grep -q "^UNFINISHED job-nope MISSING" <<<"$out" || fail "unknown id is UNFINISHED"

# --- case: a second collect of collected ids reprints findings, posts nothing
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: CHANGES
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
P2 rename the helper
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "first collect exits 0"
rm -f "$T/state/comment-pr.txt"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" || fail "re-collect exits 0"
[ "$(grep -c '^COLLECTED job-' <<<"$out")" = "3" ] || fail "re-collect prints a COLLECTED line for each id: [$out]"
grep -q "^VERDICT standards: CHANGES$" <<<"$out" || fail "re-collect reprints the reviewer verdict"
grep -q "^P2 rename the helper$" <<<"$out" || fail "re-collect reprints the P2 line"
grep -q UNFINISHED <<<"$out" && fail "re-collect is not UNFINISHED"
[ ! -e "$T/state/comment-pr.txt" ] || fail "re-collect makes no gh pr comment call"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild job-nope 2>/dev/null)" && fail "re-collect with an unknown id exits 1"
grep -q "^UNFINISHED job-nope MISSING" <<<"$out" || fail "unknown id beside collected ids is UNFINISHED"

# --- case: verify mode runs one job with SINCE and FINDINGS filled
reset_state
printf 'ci\tpending\n' >"$T/checks.txt"
printf 'P2 findings text & more\n' >"$T/findings.txt"
write_record verify DONE "rechecked
FIX-OK all repaired
STATUS: DONE" 0
start_out="$(start_review 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings.txt" --since "$FAKE_SHA" 2>"$T/stderr4.txt")" || fail "verify start exits 0"
[ "$start_out" = "verify job-verify
watch: delegate watch job-verify
collect: review-pr collect job-verify" ] || fail "verify start prints its job id, then watch and collect: [$start_out]"
out="$(bash "$REVIEW" collect job-verify 2>/dev/null)" || fail "verify collect exits 0"
grep -q "^FIX-OK all repaired$" <<<"$out" || fail "verify carries FIX-OK line"
grep -q "^CI $SHORT pending$" <<<"$out" || fail "verify pending CI line"
[ "$(wc -l <"$T/state/runs.txt" | tr -d ' ')" = "1" ] || fail "verify runs exactly one job"
grep -q '^verify M$' "$T/state/runs.txt" || fail "verify job role and model"
grep -q "git diff $FAKE_SHA..HEAD" "$T/state/prompt-verify.md" || fail "verify brief SINCE filled"
grep -q 'P2 findings text & more' "$T/state/prompt-verify.md" || fail "verify brief FINDINGS filled"
grep -q '^## verify (M)$' "$T/state/comment.md" || fail "comment verify heading"

# --- case: run starts, waits on the started ids, collects; exits 0 on all APPROVE
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
run_out="$(bash "$REVIEW" run 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 2>"$T/stderr-run.txt")" || fail "run exits 0 on all APPROVE"
[ "$(head -5 <<<"$run_out")" = "standards job-standards
spec job-spec
overbuild job-overbuild
watch: delegate watch job-standards job-spec job-overbuild
collect: review-pr collect job-standards job-spec job-overbuild" ] || fail "run prints start's lines first: [$run_out]"
[ "$(sed -n 6p <<<"$run_out")" = "patch-id $EXPECTED_PID" ] || fail "run prints collect's output after start's lines"
grep -q "^VERDICT overbuild: APPROVE$" <<<"$run_out" || fail "run prints collect's verdicts"
grep -q "^CI $SHORT pass$" <<<"$run_out" || fail "run prints collect's CI line"
grep -qx 'watch job-standards job-spec job-overbuild' "$T/state/watch.txt" || fail "run waits on every started job id"
[ "$(cat "$T/state/comment-pr.txt")" = "7" ] || fail "run posts the comment through collect"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)" = "0" ] || fail "run removes its worktrees through collect"

# --- case: run with a watch failure prints the ids and collect line, exits non-zero, posts nothing
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
touch "$T/state/fail-watch"
bash "$REVIEW" run 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >"$T/stdout-run.txt" 2>"$T/stderr-run.txt" && fail "run with a watch failure exits non-zero"
grep -Fxq "collect: review-pr collect job-standards job-spec job-overbuild" "$T/stderr-run.txt" || \
  fail "run with a watch failure prints the collect line"
grep -q 'job-standards job-spec job-overbuild' "$T/stderr-run.txt" || fail "run with a watch failure prints the ids"
[ ! -e "$T/state/comment.md" ] || fail "run with a watch failure posts no comment"
[ -f "$TMPDIR/review-pr/job-standards" ] || fail "run with a watch failure keeps state for the resume"
rm -f "$T/state/fail-watch"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "run with a watch failure resumes with collect"

# --- case: bad usage exits 2
bash "$REVIEW" >/dev/null 2>&1; [ "$?" = "2" ] || fail "no args exits 2"
bash "$REVIEW" start 7 --repo O/N --cwd "$T/clone" --model M >/dev/null 2>&1; [ "$?" = "2" ] || fail "start missing flags exits 2"
bash "$REVIEW" collect >/dev/null 2>&1; [ "$?" = "2" ] || fail "collect without ids exits 2"
bash "$REVIEW" 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1; [ "$?" = "2" ] || fail "old blocking form exits 2"


# --- case: a job without its own axis verdict is UNFINISHED; collect exits 1
reset_state
: >"$T/checks.txt"
write_record standards DONE "all good, nothing to report
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" && fail "no-verdict axis collect exits 1"
grep -q "^UNFINISHED standards DONE" <<<"$out" || fail "axis without its verdict is UNFINISHED"

# --- case: a ticketless PR whose reviewer ends DONE_WITH_CONCERNS with a full verdict
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE_WITH_CONCERNS "VERDICT standards: APPROVE
STATUS: DONE_WITH_CONCERNS" 0
write_record spec DONE_WITH_CONCERNS "VERDICT spec: CHANGES
P2 a.sh:1 — defect — fix
STATUS: DONE_WITH_CONCERNS" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" || fail "concerns with a verdict collect exits 0"
grep -q UNFINISHED <<<"$out" && fail "concerns with a verdict is finished"
grep -q 'for issue #7 (spec #7)' "$T/state/prompt-spec.md" || fail "ticketless PR is its own issue and spec"

# --- case: a verdict glued onto narration is no verdict
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "long narration about what to drop no behavior.VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" && fail "glued verdict collect exits 1"
grep -q 'UNFINISHED overbuild' <<<"$out" || fail "glued verdict is unfinished overbuild"
grep -q BAD-VERDICT <<<"$out" && fail "glued verdict is not bad"
grep -q '^VERDICT overbuild: APPROVE$' <<<"$out" && fail "glued line is not a verdict line"

# --- case: verify with a finding line that mentions VERDICT and a real FIX-OK line
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
printf 'P2 findings text\n' >"$T/findings.txt"
write_record verify DONE "- P2 fixture/test: fixed. Fixture's final assistant message (line 30) begins \`VERDICT: APPROVE\`, and the test's exact \`assert_eq!\` pins \`\nVERDICT: APPROVE\n\`, asserting the verdict starts a line.
FIX-OK
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings.txt" --since "$FAKE_SHA" >/dev/null 2>&1 || fail "verify start exits 0"
out="$(bash "$REVIEW" collect job-verify 2>/dev/null)" || fail "mention plus FIX-OK collect exits 0"
grep -q '^FIX-OK$' <<<"$out" || fail "FIX-OK counts"
grep -q BAD-VERDICT <<<"$out" && fail "mention line is not bad"
grep -q UNFINISHED <<<"$out" && fail "mention plus FIX-OK is finished"

# --- case: prose that merely contains FIX-OK is not a verify verdict
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
printf 'P2 findings text\n' >"$T/findings.txt"
write_record verify DONE "this is not FIX-OK yet
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings.txt" --since "$FAKE_SHA" >/dev/null 2>&1 || fail "verify start exits 0"
out="$(bash "$REVIEW" collect job-verify 2>/dev/null)" && fail "not FIX-OK prose collect exits 1"
grep -q 'UNFINISHED verify' <<<"$out" || fail "not FIX-OK prose is unfinished verify"
grep -q '^FIX-OK$' <<<"$out" && fail "not FIX-OK prose is not FIX-OK"
grep -q BAD-VERDICT <<<"$out" && fail "not FIX-OK prose is not bad"

# --- case: a bare FIX-OK line is a verdict
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
printf 'P2 findings text\n' >"$T/findings.txt"
write_record verify DONE "FIX-OK" 0
start_review 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings.txt" --since "$FAKE_SHA" >/dev/null 2>&1 || fail "verify start exits 0"
out="$(bash "$REVIEW" collect job-verify 2>/dev/null)" || fail "bare FIX-OK collect exits 0"
grep -q "^FIX-OK$" <<<"$out" || fail "bare FIX-OK counts"
grep -q BAD-VERDICT <<<"$out" && fail "bare FIX-OK is not bad"

# --- case: prose or a finding that merely mentions VERDICT is no verdict attempt
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
the word VERDICT appears here in plain prose
P3 x.ts:1 — yagni — cut VERDICT helper — replace with inline
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" || fail "verdict mention collect exits 0"
grep -q BAD-VERDICT <<<"$out" && fail "a VERDICT mention is not a bad verdict"
grep -q UNFINISHED <<<"$out" && fail "a VERDICT mention is finished"

# --- case: a RUNNING job waits: no post, nothing removed, retry collects
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards RUNNING "still working, no verdict yet"
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" && fail "running collect exits 1"
[ "$out" = "RUNNING standards job-standards: wait with delegate watch job-standards job-spec job-overbuild" ] || \
  fail "running line names role id and watch: [$out]"
[ ! -e "$T/state/comment.md" ] || fail "running collect posts no comment"
[ -f "$TMPDIR/review-pr/job-standards" ] || fail "running collect keeps state for the retry"
[ -f "$TMPDIR/review-pr/job-spec" ] || fail "running collect keeps the sibling state"
[ -f "$TMPDIR/review-pr/job-overbuild" ] || fail "running collect keeps the sibling state"
rd="$(sed -n 's/^run_dir=//p' "$TMPDIR/review-pr/job-standards")"
[ -n "$rd" ] && [ -d "$rd" ] || fail "running collect keeps the run dir"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "3" ] || fail "running collect keeps the worktrees"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
cp "$T/canned/standards.json" "$TMPDIR/delegate-jobs/job-standards.json"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" || fail "retry after running exits 0"
grep -q "^VERDICT standards: APPROVE$" <<<"$out" || fail "retry carries the review verdict"
grep -q "^VERDICT overbuild: APPROVE$" <<<"$out" || fail "retry carries the labelled overbuild verdict"
grep -q UNFINISHED <<<"$out" && fail "retry is finished"

# --- case: collect with only one role's job id fails before posting and keeps state
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
out="$(bash "$REVIEW" collect job-standards 2>/dev/null)" && fail "partial collect exits 1"
grep -q "^UNFINISHED spec MISSING" <<<"$out" || fail "partial collect names the missing spec role"
grep -q "^UNFINISHED overbuild MISSING" <<<"$out" || fail "partial collect names the missing overbuild role"
[ ! -e "$T/state/comment.md" ] || fail "partial collect posts no comment"
[ -f "$TMPDIR/review-pr/job-standards" ] || fail "partial collect keeps state for the retry"
[ -f "$TMPDIR/review-pr/job-spec" ] || fail "partial collect keeps every state"
[ -f "$TMPDIR/review-pr/job-overbuild" ] || fail "partial collect keeps the sibling state"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" || fail "retry with every id exits 0"
grep -q UNFINISHED <<<"$out" && fail "retry is finished"

# --- case: a failed comment post keeps state for the retry
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start exits 0"
touch "$T/state/fail-comment"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 && fail "failed post collect exits nonzero"
[ -f "$TMPDIR/review-pr/job-standards" ] || fail "failed post keeps state"
[ -f "$TMPDIR/review-pr/job-spec" ] || fail "failed post keeps every state"
[ -f "$TMPDIR/review-pr/job-overbuild" ] || fail "failed post keeps every state"
rm -f "$T/state/fail-comment"
out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" || fail "retry after failed post exits 0"
[ "$(cat "$T/state/comment-pr.txt")" = "7" ] || fail "retry posts the comment"

# --- case: a failing second start leaves the launched job's worktree and state
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
touch "$T/state/fail-overbuild"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 && fail "start with a failing job exits nonzero"
rm -f "$T/state/fail-overbuild"
[ -f "$TMPDIR/review-pr/job-standards" ] || fail "failed start keeps the launched state"
[ -f "$TMPDIR/review-pr/job-spec" ] || fail "failed start keeps every launched state"
wt="$(sed -n 's/^worktree=//p' "$TMPDIR/review-pr/job-standards")"
wt2="$(sed -n 's/^worktree=//p' "$TMPDIR/review-pr/job-spec")"
rd="$(sed -n 's/^run_dir=//p' "$TMPDIR/review-pr/job-standards")"
[ -n "$wt" ] && [ -d "$wt" ] || fail "failed start keeps the launched worktree"
[ -n "$wt2" ] && [ -d "$wt2" ] || fail "failed start keeps every launched worktree"
git -C "$T/clone" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
git -C "$T/clone" worktree remove --force "$wt2" >/dev/null 2>&1 || rm -rf "$wt2"
rm -rf "$rd"
rm -f "$TMPDIR/review-pr/job-standards" "$TMPDIR/review-pr/job-spec"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "0" ] || fail "failed-start cleanup leaves no worktree"
# --- case: --head with a lagging API head: wait, then review exactly the pushed head
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
printf '%s\n%s\n%s\n' "$OLD_SHA" "$OLD_SHA" "$NEW_SHA" >"$T/state/heads.txt"
start_review 8 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 \
  --head "$NEW_SHA" >/dev/null 2>&1 || fail "--head lagging start exits 0"
[ "$(wc -l <"$T/state/sleeps.txt")" -eq 2 ] || fail "--head lagging sleeps twice"
wt="$(sed -n 's/^worktree=//p' "$TMPDIR/review-pr/job-standards")"
[ "$(git -C "$wt" rev-parse HEAD)" = "$NEW_SHA" ] || fail "--head worktree is at the expected head"
[ "$(sed -n 's/^sha=//p' "$TMPDIR/review-pr/job-standards")" = "$NEW_SHA" ] || fail "--head state sha"
[ "$(sed -n 's/^patch_id=//p' "$TMPDIR/review-pr/job-standards")" = "$EXPECTED_NEW_PID" ] || fail "--head state patch_id"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "--head collect exits 0"
[ "$(head -1 "$T/state/comment.md")" = "review-pr: patch-id $EXPECTED_NEW_PID, head $NEW_SHA" ] || fail "--head comment first line"

# --- case: --head the API never reaches: exit 1, nothing created or posted
reset_state
printf '%s\n' "$OLD_SHA" >"$T/state/heads.txt"
err="$(start_review 8 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 \
  --head "$NEW_SHA" 2>&1 >/dev/null)" && fail "--head timeout exits nonzero"
grep -q "$OLD_SHA" <<<"$err" || fail "--head timeout names the API head"
grep -q "$NEW_SHA" <<<"$err" || fail "--head timeout names the expected head"
[ ! -e "$T/state/runs.txt" ] || fail "--head timeout starts no job"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "0" ] || fail "--head timeout makes no worktree"
[ -z "$(ls -d "$REVIEW_PR_RUN_ROOT"/review-pr.run.* 2>/dev/null)" ] || fail "--head timeout makes no run dir"
[ -z "$(ls "$TMPDIR/review-pr" 2>/dev/null)" ] || fail "--head timeout saves no state"
[ ! -e "$T/state/comment.md" ] || fail "--head timeout posts nothing"
[ "$(wc -l <"$T/state/sleeps.txt")" -eq 30 ] || fail "--head timeout polls 30 times"

# --- case: an issue number, not a PR: exit 2 at once, nothing created
reset_state
touch "$T/state/not-pr"
err="$(start_review 9 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 \
  --head "$NEW_SHA" 2>&1 >/dev/null)"
[ $? -eq 2 ] || fail "not-a-PR exits 2"
[ "$err" = "review-pr: #9 is not a pull request in O/N (an issue number?)" ] || fail "not-a-PR message: $err"
[ ! -e "$T/state/sleeps.txt" ] || fail "not-a-PR does not wait"
[ ! -e "$T/state/runs.txt" ] || fail "not-a-PR starts no job"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-')" = "0" ] || fail "not-a-PR makes no worktree"

# --- case: --head already matching: no wait
reset_state
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
printf '%s\n' "$NEW_SHA" >"$T/state/heads.txt"
start_review 8 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 \
  --head "$NEW_SHA" >/dev/null 2>&1 || fail "--head matching start exits 0"
[ ! -e "$T/state/sleeps.txt" ] || fail "--head matching does not sleep"
wt="$(sed -n 's/^worktree=//p' "$TMPDIR/review-pr/job-standards")"
[ "$(git -C "$wt" rev-parse HEAD)" = "$NEW_SHA" ] || fail "--head matching worktree head"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "--head matching collect exits 0"

# --- case: --head must be a full SHA
reset_state
err="$(start_review 8 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 \
  --head abc123 2>&1 >/dev/null)"
[ $? -eq 2 ] || fail "--head short sha is a usage error"
[ "$err" = "review-pr: --head needs the full 40-character SHA (git rev-parse <sha>)" ] || \
  fail "--head short sha message: [$err]"

# --- case: --head in verify mode
reset_state
write_record verify DONE "FIX-OK
STATUS: DONE" 0
printf 'P1 x\n' >"$T/findings.txt"
printf '%s\n' "$NEW_SHA" >"$T/state/heads.txt"
start_review 8 --repo O/N --cwd "$T/clone" --model M --verify "$T/findings.txt" \
  --since "$OLD_SHA" --head "$NEW_SHA" >/dev/null 2>&1 || fail "--head verify start exits 0"
wt="$(sed -n 's/^worktree=//p' "$TMPDIR/review-pr/job-verify")"
[ "$(git -C "$wt" rev-parse HEAD)" = "$NEW_SHA" ] || fail "--head verify worktree head"
bash "$REVIEW" collect job-verify >/dev/null 2>&1 || true

# --- case: verify on a rebased PR compares only the repair patch
reset_state
write_record verify DONE "FIX-OK
STATUS: DONE" 0
git init -q -b main "$T/rebase-origin"
git -C "$T/rebase-origin" config user.email t@t
git -C "$T/rebase-origin" config user.name t
echo 'base line' >"$T/rebase-origin/main.txt"
git -C "$T/rebase-origin" add .
git -C "$T/rebase-origin" commit -qm 'rebase fixture base'
git -C "$T/rebase-origin" checkout -q -b pr9
echo 'original line' >"$T/rebase-origin/pr.txt"
git -C "$T/rebase-origin" add pr.txt
git -C "$T/rebase-origin" commit -qm 'reviewed change'
OLD9="$(git -C "$T/rebase-origin" rev-parse HEAD)"
git -C "$T/rebase-origin" checkout -q main
echo 'main moved' >"$T/rebase-origin/main.txt"
git -C "$T/rebase-origin" commit -qam 'move main'
git -C "$T/rebase-origin" checkout -q -b rebased-pr9
echo 'original line' >"$T/rebase-origin/pr.txt"
git -C "$T/rebase-origin" add pr.txt
git -C "$T/rebase-origin" commit -qm 'replay reviewed change'
echo 'repair line' >"$T/rebase-origin/pr.txt"
git -C "$T/rebase-origin" commit -qam 'repair'
NEW9="$(git -C "$T/rebase-origin" rev-parse HEAD)"
git -C "$T/rebase-origin" update-ref refs/pull/9/head "$NEW9"
git clone -q "$T/rebase-origin" "$T/rebase-clone"
printf '%s\n' "$NEW9" >"$T/state/heads.txt"
start_review 9 --repo O/N --cwd "$T/rebase-clone" --model M \
  --verify "$T/findings.txt" --since "$OLD9" --head "$NEW9" \
  >/dev/null 2>"$T/rebase-stderr.txt" || fail "rebased verify start exits 0"
REPAIR_BASE="$(sed -n 's/^review-pr: repair base \([0-9a-f]\{40\}\).*/\1/p' "$T/rebase-stderr.txt")"
[ -n "$REPAIR_BASE" ] || fail "verify logs the repair base"
[ "$REPAIR_BASE" != "$OLD9" ] || fail "rebased verify uses a base other than the reviewed head"
grep -q "git diff $REPAIR_BASE..HEAD" "$T/state/prompt-verify.md" || fail "rebased verify brief uses repair base"
[ "$(git -C "$T/rebase-clone" diff --name-only "$REPAIR_BASE" "$NEW9")" = "pr.txt" ] || \
  fail "rebased verify diff excludes changes that only exist on main"
repair_diff="$(git -C "$T/rebase-clone" diff "$REPAIR_BASE" "$NEW9" -- pr.txt)"
grep -q '^-original line$' <<<"$repair_diff" || fail "rebased verify diff removes reviewed line"
grep -q '^+repair line$' <<<"$repair_diff" || fail "rebased verify diff contains the repair line"
if grep -q 'main moved' <<<"$repair_diff"; then fail "rebased verify diff excludes main's change"; fi
grep -q "review-pr: repair base $REPAIR_BASE" "$T/rebase-stderr.txt" || fail "stderr identifies repair base"
bash "$REVIEW" collect job-verify >/dev/null 2>&1 || fail "rebased verify collect exits 0"

# --- case: verify reports conflicts while excluding changes only on main
reset_state
write_record verify DONE "FIX-OK
STATUS: DONE" 0
git init -q -b main "$T/conflict-origin"
git -C "$T/conflict-origin" config user.email t@t
git -C "$T/conflict-origin" config user.name t
echo 'same line' >"$T/conflict-origin/shared.txt"
git -C "$T/conflict-origin" add .
git -C "$T/conflict-origin" commit -qm 'conflict fixture base'
git -C "$T/conflict-origin" checkout -q -b pr10
echo 'reviewed branch line' >"$T/conflict-origin/shared.txt"
git -C "$T/conflict-origin" commit -qam 'reviewed conflicting change'
OLD_CONFLICT="$(git -C "$T/conflict-origin" rev-parse HEAD)"
git -C "$T/conflict-origin" checkout -q main
echo 'main line' >"$T/conflict-origin/shared.txt"
echo 'main only' >"$T/conflict-origin/main-only.txt"
git -C "$T/conflict-origin" add .
git -C "$T/conflict-origin" commit -qm 'conflicting main change'
git -C "$T/conflict-origin" checkout -q -b rebased-pr10
echo 'resolved line' >"$T/conflict-origin/shared.txt"
git -C "$T/conflict-origin" commit -qam 'resolve rebase conflict'
echo 'repair line' >"$T/conflict-origin/shared.txt"
git -C "$T/conflict-origin" commit -qam 'repair conflict resolution'
NEW_CONFLICT="$(git -C "$T/conflict-origin" rev-parse HEAD)"
git -C "$T/conflict-origin" update-ref refs/pull/10/head "$NEW_CONFLICT"
git clone -q "$T/conflict-origin" "$T/conflict-clone"
printf '%s\n' "$NEW_CONFLICT" >"$T/state/heads.txt"
start_review 10 --repo O/N --cwd "$T/conflict-clone" --model M \
  --verify "$T/findings.txt" --since "$OLD_CONFLICT" --head "$NEW_CONFLICT" \
  >/dev/null 2>"$T/conflict-stderr.txt" || fail "conflicted verify start exits 0"
CONFLICT_BASE="$(sed -n 's/^review-pr: repair base \([0-9a-f]\{40\}\).*/\1/p' "$T/conflict-stderr.txt")"
[ -n "$CONFLICT_BASE" ] || fail "conflicted verify logs repair base"
git -C "$T/conflict-clone" cat-file -e "$CONFLICT_BASE^{commit}" || fail "conflicted repair base is a commit"
grep -q "$OLD_CONFLICT does not replay cleanly onto .*the repair diff includes the rebase's conflict resolution" \
  "$T/conflict-stderr.txt" || fail "conflicted verify reports merge-tree conflict"
conflict_files="$(git -C "$T/conflict-clone" diff --name-only "$CONFLICT_BASE" "$NEW_CONFLICT")"
[ "$conflict_files" = "shared.txt" ] || fail "conflicted repair diff excludes main-only files: [$conflict_files]"
bash "$REVIEW" collect job-verify >/dev/null 2>&1 || fail "conflicted verify collect exits 0"

# --- case: missing --since fails before creating a worktree, state or job
reset_state
MISSING_SINCE=ffffffffffffffffffffffffffffffffffffffff
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings.txt" --since "$MISSING_SINCE" 2>&1 >/dev/null)" && \
  fail "missing --since exits nonzero"
grep -q -- "--since $MISSING_SINCE is not fetchable" <<<"$err" || fail "missing --since error names the value"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)" = "0" ] || \
  fail "missing --since creates no worktree"
[ -z "$(ls "$TMPDIR/review-pr" 2>/dev/null)" ] || fail "missing --since saves no state"
[ -z "$(ls -d "$REVIEW_PR_RUN_ROOT"/review-pr.run.* 2>/dev/null)" ] || fail "missing --since leaves no run dir"
[ ! -e "$T/state/runs.txt" ] || fail "missing --since launches no job"

# --- case: a short --since the clone holds is accepted
reset_state
printf 'P1 findings text\n' >"$T/findings.txt"
write_record verify DONE "rechecked
FIX-OK all repaired
STATUS: DONE" 0
start_out="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --verify "$T/findings.txt" \
  --since "$SHORT" 2>"$T/stderr-short.txt")" || fail "short --since present in clone exits 0"
[ "$start_out" = "verify job-verify
watch: delegate watch job-verify
collect: review-pr collect job-verify" ] || fail "short --since prints the verify job lines: [$start_out]"
bash "$REVIEW" collect job-verify >/dev/null 2>&1 || fail "short --since collects"

# --- case: a short --since the clone lacks exits 2 before fetching
reset_state
printf 'P1 findings text\n' >"$T/findings.txt"
git -C "$T/clone" cat-file -e "deadbee^{commit}" 2>/dev/null && fail "fixture deadbee unexpectedly resolves"
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings.txt" --since deadbee 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "short --since absent from clone exits 2 (got $st)"
grep -Fxq "review-pr: --since needs the full 40-character sha (deadbee is not in the clone)" <<<"$err" || \
  fail "short --since names the value and the fix: [$err]"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)" = "0" ] || \
  fail "short --since absent creates no worktree"
[ -z "$(ls "$TMPDIR/review-pr" 2>/dev/null)" ] || fail "short --since absent saves no state"
[ -z "$(ls -d "$REVIEW_PR_RUN_ROOT"/review-pr.run.* 2>/dev/null)" ] || fail "short --since absent leaves no run dir"
[ ! -e "$T/state/runs.txt" ] || fail "short --since absent launches no job"

# --- case: an empty or whitespace-only --verify findings file exits 2 before launch
for blank in '' '  \n\t \n'; do
  reset_state
  printf "$blank" >"$T/findings-blank.txt"
  err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M \
    --verify "$T/findings-blank.txt" --since "$FAKE_SHA" 2>&1 >/dev/null)"
  st=$?
  [ "$st" -eq 2 ] || fail "empty --verify findings file exits 2 (got $st)"
  grep -Fxq "review-pr: findings file $T/findings-blank.txt is empty; write the open findings, or \"no open findings\"" <<<"$err" || \
    fail "empty --verify findings file names the file and the fix"
  [ "$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)" = "0" ] || \
    fail "empty --verify findings file creates no worktree"
  [ -z "$(ls "$TMPDIR/review-pr" 2>/dev/null)" ] || fail "empty --verify findings file saves no state"
  [ ! -e "$T/state/runs.txt" ] || fail "empty --verify findings file launches no job"
done

# --- case: collect unregisters the run's worktrees after --cwd is gone, and
# leaves another run's worktrees alone
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "sibling run start exits 0"
mkdir -p "$T/keep"
mv "$TMPDIR/review-pr/job-standards" "$T/keep/job-standards"
mv "$TMPDIR/review-pr/job-spec" "$T/keep/job-spec"
mv "$TMPDIR/review-pr/job-overbuild" "$T/keep/job-overbuild"
sibling_rd="$(sed -n 's/^run_dir=//p' "$T/keep/job-standards")"
git -C "$T/clone" worktree add -q --detach "$T/lane" HEAD
start_review 7 --repo O/N --cwd "$T/lane" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start from a lane worktree exits 0"
rd="$(sed -n 's/^run_dir=//p' "$TMPDIR/review-pr/job-standards")"
rm -rf "$T/lane"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "collect after --cwd is gone exits 0"
[ "$(git -C "$T/clone" worktree list | grep -c "$(basename "$rd")/wt-" || true)" = "0" ] || \
  fail "collect unregisters the run's worktrees when --cwd is gone"
[ ! -e "$rd" ] || fail "collect removes the run dir when --cwd is gone"
[ "$(git -C "$T/clone" worktree list | grep -c "$(basename "$sibling_rd")/wt-")" = "3" ] || \
  fail "collect leaves another run's worktrees registered"
[ -d "$sibling_rd/wt-standards" ] || fail "collect leaves another run's dir"

# --- case: start prunes a finished run nobody collected
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$REVIEW_PR_RUN_ROOT/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-old standards 7 DONE "$T/clone"
stale_sf="$TMPDIR/review-pr/job-old"
stale_wt="$stale_rd/wt-standards"
start_out="$(start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 2>"$T/stderr.txt")" || fail "pruning start exits 0"
[ "$start_out" = "standards job-standards
spec job-spec
overbuild job-overbuild
watch: delegate watch job-standards job-spec job-overbuild
collect: review-pr collect job-standards job-spec job-overbuild" ] || fail "pruning start prints only the new jobs: [$start_out]"
[ ! -e "$stale_sf" ] || fail "prune removes the stale state file"
[ ! -e "$stale_wt" ] || fail "prune removes the stale worktree"
[ ! -e "$stale_rd" ] || fail "prune removes the stale run dir"
stale_base="$(basename "$stale_rd")"
[ "$(git -C "$T/clone" worktree list | grep -c "$stale_base/wt-" || true)" = "0" ] || fail "prune unregisters the stale worktree"
[ -f "$TMPDIR/review-pr/job-standards" ] || fail "pruning start still saves the new state"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "collect after prune exits 0"

# --- case: start keeps a stale state file whose job is still running
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$REVIEW_PR_RUN_ROOT/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-old standards 7 RUNNING "$T/clone"
stale_sf="$TMPDIR/review-pr/job-old"
stale_wt="$stale_rd/wt-standards"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start with a running stale run exits 0"
[ -f "$stale_sf" ] || fail "running stale state is kept"
[ -d "$stale_wt" ] || fail "running stale worktree is kept"
[ -d "$stale_rd" ] || fail "running stale run dir is kept"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "collect after running-stale exits 0"
git -C "$T/clone" worktree remove --force "$stale_wt" >/dev/null 2>&1 || rm -rf "$stale_wt"
rm -rf "$stale_rd"
rm -f "$stale_sf" "$TMPDIR/delegate-jobs/job-old.json"

# --- case: start keeps a finished run whose state file is fresh
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$REVIEW_PR_RUN_ROOT/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-old standards 1 DONE "$T/clone" 0
stale_sf="$TMPDIR/review-pr/job-old"
stale_wt="$stale_rd/wt-standards"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start with a fresh stale run exits 0"
[ -f "$stale_sf" ] || fail "fresh state is kept"
[ -d "$stale_wt" ] || fail "fresh worktree is kept"
[ -d "$stale_rd" ] || fail "fresh run dir is kept"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "collect after fresh-stale exits 0"
git -C "$T/clone" worktree remove --force "$stale_wt" >/dev/null 2>&1 || rm -rf "$stale_wt"
rm -rf "$stale_rd"
rm -f "$stale_sf" "$TMPDIR/delegate-jobs/job-old.json"

# --- case: start prunes a stale state file with no job record
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$REVIEW_PR_RUN_ROOT/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-old standards 7 NOREC "$T/clone"
stale_sf="$TMPDIR/review-pr/job-old"
stale_wt="$stale_rd/wt-standards"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "pruning start exits 0"
[ ! -e "$stale_sf" ] || fail "prune removes the recordless state file"
[ ! -e "$stale_wt" ] || fail "prune removes the recordless worktree"
[ ! -e "$stale_rd" ] || fail "prune removes the recordless run dir"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "collect after recordless prune exits 0"

# --- case: start prunes a DONE run two hours after it ends
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$REVIEW_PR_RUN_ROOT/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-done2 standards 2h DONE "$T/clone" 2h
stale_sf="$TMPDIR/review-pr/job-done2"
stale_wt="$stale_rd/wt-standards"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "pruning start exits 0"
[ ! -e "$stale_sf" ] || fail "prune removes the two-hour finished state file"
[ ! -e "$stale_wt" ] || fail "prune removes the two-hour finished worktree"
[ ! -e "$stale_rd" ] || fail "prune removes the two-hour finished run dir"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "collect after two-hour prune exits 0"

# --- case: start keeps a long job that finished ten minutes ago
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$REVIEW_PR_RUN_ROOT/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-justdone standards 7h DONE "$T/clone" 10m
stale_sf="$TMPDIR/review-pr/job-justdone"
stale_wt="$stale_rd/wt-standards"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start with a just-finished run exits 0"
[ -f "$stale_sf" ] || fail "just-finished state is kept"
[ -d "$stale_wt" ] || fail "just-finished worktree is kept"
[ -d "$stale_rd" ] || fail "just-finished run dir is kept"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "collect after just-finished exits 0"
git -C "$T/clone" worktree remove --force "$stale_wt" >/dev/null 2>&1 || rm -rf "$stale_wt"
rm -rf "$stale_rd"
rm -f "$stale_sf" "$TMPDIR/delegate-jobs/job-justdone.json"

# --- case: a run with no record is kept at two hours, pruned at seven
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
young_rd="$(mktemp -d "$REVIEW_PR_RUN_ROOT/review-pr.run.XXXXXX")"
stale_state "$young_rd" job-norec2 standards 2h NOREC "$T/clone"
old_rd="$(mktemp -d "$REVIEW_PR_RUN_ROOT/review-pr.run.XXXXXX")"
stale_state "$old_rd" job-norec7 standards 7h NOREC "$T/clone"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start with recordless runs exits 0"
[ -f "$TMPDIR/review-pr/job-norec2" ] || fail "two-hour recordless state is kept"
[ -d "$young_rd/wt-standards" ] || fail "two-hour recordless worktree is kept"
[ ! -e "$TMPDIR/review-pr/job-norec7" ] || fail "prune removes the seven-hour recordless state"
[ ! -e "$old_rd" ] || fail "prune removes the seven-hour recordless run dir"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "collect after recordless ages exits 0"
git -C "$T/clone" worktree remove --force "$young_rd/wt-standards" >/dev/null 2>&1 || rm -rf "$young_rd/wt-standards"
rm -rf "$young_rd"
rm -f "$TMPDIR/review-pr/job-norec2"

# --- case: start prunes a stale two-file run sharing one run dir when the clone is gone
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
gone_clone="$T/clone-gone"
stale_rd="$(mktemp -d "$REVIEW_PR_RUN_ROOT/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-stale-review standards 7 DONE "$gone_clone"
stale_state "$stale_rd" job-stale-overbuild overbuild 7 DONE "$gone_clone"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start with a stale two-file run exits 0"
[ ! -e "$TMPDIR/review-pr/job-stale-review" ] || fail "prune removes the stale standards state"
[ ! -e "$TMPDIR/review-pr/job-stale-overbuild" ] || fail "prune removes the stale overbuild state"
[ ! -e "$stale_rd" ] || fail "prune removes the shared run dir"
stale_base="$(basename "$stale_rd")"
[ "$(git -C "$T/clone" worktree list | grep -c "$stale_base/wt-" || true)" = "0" ] || fail "prune deregisters both worktrees when the clone is gone"
[ -f "$TMPDIR/review-pr/job-standards" ] || fail "two-file prune still saves the new state"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "collect after two-file prune exits 0"

# --- case: start spares a run with a live sibling: review DONE but overbuild RUNNING
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$REVIEW_PR_RUN_ROOT/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-live-review standards 7 DONE "$T/clone"
stale_state "$stale_rd" job-live-overbuild overbuild 7 RUNNING "$T/clone"
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "start with a live sibling exits 0"
[ -f "$TMPDIR/review-pr/job-live-review" ] || fail "live run keeps the finished state"
[ -f "$TMPDIR/review-pr/job-live-overbuild" ] || fail "live run keeps the running state"
[ -d "$stale_rd/wt-standards" ] || fail "live run keeps the finished worktree"
[ -d "$stale_rd/wt-overbuild" ] || fail "live run keeps the running worktree"
[ -d "$stale_rd" ] || fail "live run keeps the run dir"
stale_base="$(basename "$stale_rd")"
[ "$(git -C "$T/clone" worktree list | grep -c "$stale_base/wt-" || true)" = "2" ] || fail "live run keeps both worktrees registered"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "collect after live-sibling exits 0"
git -C "$T/clone" worktree remove --force "$stale_rd/wt-standards" >/dev/null 2>&1 || rm -rf "$stale_rd/wt-standards"
git -C "$T/clone" worktree remove --force "$stale_rd/wt-overbuild" >/dev/null 2>&1 || rm -rf "$stale_rd/wt-overbuild"
rm -rf "$stale_rd"
rm -f "$TMPDIR/review-pr/job-live-review" "$TMPDIR/review-pr/job-live-overbuild"
rm -f "$TMPDIR/delegate-jobs/job-live-review.json" "$TMPDIR/delegate-jobs/job-live-overbuild.json"

# --- case: collect reads records from DELEGATE_JOBS_DIR
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: CHANGES
P1 fix the off-by-one
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "override start exits 0"
mv "$TMPDIR/delegate-jobs/job-standards.json" "$TMPDIR/delegate-jobs/job-spec.json" \
  "$TMPDIR/delegate-jobs/job-overbuild.json" "$T/override/" || fail "override fixture move"
out="$(DELEGATE_JOBS_DIR="$T/override" bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" || fail "override collect exits 0"
grep -q "^VERDICT standards: APPROVE$" <<<"$out" || fail "override collect carries the standards verdict"
grep -q "^VERDICT spec: CHANGES$" <<<"$out" || fail "override collect carries the spec verdict"
grep -q "^VERDICT overbuild: APPROVE$" <<<"$out" || fail "override collect labels the overbuild verdict"
grep -q "^P1 fix the off-by-one$" <<<"$out" || fail "override collect carries P1 lines"
grep -q UNFINISHED <<<"$out" && fail "override collect has no UNFINISHED"
[ "$(cat "$T/state/comment-pr.txt")" = "7" ] || fail "override collect posts the comment"

# --- case: re-collect from the override names the override record path
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
P1 lone finding
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --axes standards >/dev/null 2>&1 || fail "recollect-override start exits 0"
bash "$REVIEW" collect job-standards >/dev/null 2>&1 || fail "recollect-override first collect exits 0"
mv "$TMPDIR/delegate-jobs/job-standards.json" "$T/override/" || fail "recollect-override fixture move"
rm -f "$T/state/comment-pr.txt"
out="$(DELEGATE_JOBS_DIR="$T/override" bash "$REVIEW" collect job-standards 2>/dev/null)" || fail "recollect-override exits 0"
grep -qx "COLLECTED job-standards $T/override/job-standards.json: already posted to the PR; findings reprinted from the job record, nothing posted" <<<"$out" || \
  fail "recollect-override names the override path: [$out]"
grep -q "^VERDICT standards: APPROVE$" <<<"$out" || fail "recollect-override reprints the verdict"
grep -q "^P1 lone finding$" <<<"$out" || fail "recollect-override reprints the P1 line"
[ ! -e "$T/state/comment-pr.txt" ] || fail "recollect-override posts nothing"

# --- case: a RUNNING record in the override waits the same as in the tmp dir
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards RUNNING "still working, no verdict yet"
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "running-override start exits 0"
mv "$TMPDIR/delegate-jobs/job-standards.json" "$T/override/" || fail "running-override fixture move"
touch -t "$(stale_ts_for 7)" "$TMPDIR/review-pr/job-standards" || fail "running-override fixture touch"
out="$(DELEGATE_JOBS_DIR="$T/override" bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" && fail "running-override collect exits 1"
[ "$out" = "RUNNING standards job-standards: wait with delegate watch job-standards job-spec job-overbuild" ] || \
  fail "running-override line names role id and watch: [$out]"
[ ! -e "$T/state/comment.md" ] || fail "running-override collect posts no comment"
[ -f "$TMPDIR/review-pr/job-standards" ] || fail "running-override collect keeps state for the retry"
[ -f "$TMPDIR/review-pr/job-spec" ] || fail "running-override collect keeps the sibling state"

# --- case: start prunes a run whose winning record is a stale override record
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$REVIEW_PR_RUN_ROOT/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-old standards 1 DONE "$T/clone" 7
mv "$TMPDIR/delegate-jobs/job-old.json" "$T/override/" || fail "override-prune fixture move"
stale_sf="$TMPDIR/review-pr/job-old"
stale_wt="$stale_rd/wt-standards"
DELEGATE_JOBS_DIR="$T/override" start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "override-prune start exits 0"
[ ! -e "$stale_sf" ] || fail "override prune removes the stale state file"
[ ! -e "$stale_wt" ] || fail "override prune removes the stale worktree"
[ ! -e "$stale_rd" ] || fail "override prune removes the stale run dir"
[ -f "$TMPDIR/review-pr/job-standards" ] || fail "override-prune start still saves the new state"
DELEGATE_JOBS_DIR="$T/override" bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "collect after override prune exits 0"

# --- case: a fresh RUNNING override record spares a run with a stale tmp record
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$REVIEW_PR_RUN_ROOT/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-old standards 7 DONE "$T/clone"
printf '{"status":"RUNNING"}\n' >"$T/override/job-old.json"
stale_sf="$TMPDIR/review-pr/job-old"
stale_wt="$stale_rd/wt-standards"
DELEGATE_JOBS_DIR="$T/override" start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "winner-running start exits 0"
[ -f "$stale_sf" ] || fail "running winner keeps the stale state file"
[ -d "$stale_wt" ] || fail "running winner keeps the stale worktree"
[ -d "$stale_rd" ] || fail "running winner keeps the stale run dir"
DELEGATE_JOBS_DIR="$T/override" bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "collect after winner-running exits 0"
git -C "$T/clone" worktree remove --force "$stale_wt" >/dev/null 2>&1 || rm -rf "$stale_wt"
rm -rf "$stale_rd"
rm -f "$stale_sf" "$TMPDIR/delegate-jobs/job-old.json" "$T/override/job-old.json"

# --- case: a stale override record prunes a run with a fresh tmp record
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
stale_rd="$(mktemp -d "$REVIEW_PR_RUN_ROOT/review-pr.run.XXXXXX")"
stale_state "$stale_rd" job-old standards 7 DONE "$T/clone" 0
printf '{"status":"DONE"}\n' >"$T/override/job-old.json"
touch -t "$(stale_ts_for 2)" "$T/override/job-old.json" || fail "winner-stale fixture touch"
stale_sf="$TMPDIR/review-pr/job-old"
stale_wt="$stale_rd/wt-standards"
DELEGATE_JOBS_DIR="$T/override" start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "winner-stale start exits 0"
[ ! -e "$stale_sf" ] || fail "stale winner prunes the state file"
[ ! -e "$stale_wt" ] || fail "stale winner prunes the worktree"
[ ! -e "$stale_rd" ] || fail "stale winner prunes the run dir"
DELEGATE_JOBS_DIR="$T/override" bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "collect after winner-stale exits 0"

# --- ci_case LABEL RUNS WANT: one review round trip whose reviewed head has the
# check runs RUNS (TSV rows of name, status, conclusion, started_at, id, joined
# by \n). The CI line must read WANT, and the API must be asked for the reviewed
# head's check runs. Runs in a subshell with its own HOME and TMPDIR.
ci_case() {
  ci_label="$1"; ci_want="$3"
  ci_runs="$T/canned/ci-$(printf '%s' "$ci_label" | tr ' ' '_').tsv"
  printf '%b' "$2" >"$ci_runs"
  # the legacy gh pr checks fixture, derived from the same runs for the old code
  awk -F'\t' 'NF >= 5 { s = ($3 == "failure") ? "fail" : ($3 == "cancelled") ? "cancel" : ($2 == "completed") ? "pass" : "pending"; print $1 "\t" s }' "$ci_runs" >"$T/checks.txt"
  rm -f "$T/state/api.txt"
  (
    export HOME="$(mktemp -d "$T/home.XXXXXX")"
    export TMPDIR="$(mktemp -d "$T/tmp.XXXXXX")"
    export CI_RUNS_FILE="$ci_runs"
    write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
    write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
    start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 --model M --overbuild-model M2 >/dev/null 2>&1 || fail "$ci_label: start exits 0"
    out="$(bash "$REVIEW" collect job-standards job-spec job-overbuild 2>/dev/null)" || true
    grep -qx "CI $SHORT $ci_want" <<<"$out" || fail "$ci_label: want CI $SHORT $ci_want, got [$(grep '^CI ' <<<"$out")]"
    grep -qx "repos/O/N/commits/$FAKE_SHA/check-runs" "$T/state/api.txt" || fail "$ci_label: check runs asked for the reviewed head"
  )
}

# --- case: CI state comes from the reviewed head's check runs, not gh pr checks
ci_case "cancelled only" 'ci\tcompleted\tcancelled\t2026-10-09T10:00:00Z\t101\nlint\tcompleted\tcancelled\t2026-10-09T10:00:01Z\t102\n' cancelled || exit 1
ci_case "cancelled then later success" 'ci\tcompleted\tcancelled\t2026-10-09T10:00:00Z\t300\nci\tcompleted\tsuccess\t2026-10-09T10:05:00Z\t200\nlint\tcompleted\tsuccess\t2026-10-09T10:00:00Z\t150\n' pass || exit 1
ci_case "one failure" 'ci\tcompleted\tfailure\t2026-10-09T10:00:00Z\t1\nlint\tcompleted\tsuccess\t2026-10-09T10:00:00Z\t2\n' fail || exit 1
ci_case "in progress" 'ci\tin_progress\t\t2026-10-09T10:00:00Z\t1\nlint\tcompleted\tsuccess\t2026-10-09T10:00:00Z\t2\n' pending || exit 1

# --- case: --axes standards starts only the standards job
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
before="$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)"
run_out="$(bash "$REVIEW" run 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 --axes standards 2>"$T/stderr.txt")" || fail "axes standards run exits 0"
[ "$(head -3 <<<"$run_out")" = "standards job-standards
watch: delegate watch job-standards
collect: review-pr collect job-standards" ] || fail "axes standards prints one job id, then watch and collect: [$run_out]"
[ "$(wc -l <"$T/state/runs.txt" | tr -d ' ')" = "1" ] || fail "axes standards runs exactly one job"
grep -qx 'standards M' "$T/state/runs.txt" || fail "the one job is the standards job"
grep -qx 'watch job-standards' "$T/state/watch.txt" || fail "axes standards run waits on its job"
grep -q "^VERDICT standards: APPROVE$" <<<"$run_out" || fail "axes standards output carries its verdict"
grep -q "^VERDICT spec:" <<<"$run_out" && fail "axes standards output has no spec verdict"
grep -q "^VERDICT overbuild:" <<<"$run_out" && fail "axes standards output has no overbuild verdict"
grep -q UNFINISHED <<<"$run_out" && fail "axes standards run is finished"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)" = "$before" ] || fail "axes standards run removes its worktree"

# --- case: --axes without overbuild needs no --overbuild-model; unknown axes fail
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --model M --axes standards >/dev/null 2>&1 || \
  fail "axes standards without --overbuild-model exits 0"
bash "$REVIEW" collect job-standards >/dev/null 2>&1 || fail "axes standards without --overbuild-model collects"
reset_state
before="$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)"
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 \
  --axes bogus 2>&1 >/dev/null)"
[ "$?" = "2" ] || fail "unknown axis exits 2"
[ "$err" = "review-pr: unknown axis: bogus (standards, spec, overbuild)" ] || fail "unknown axis names the axis: [$err]"
[ ! -e "$T/state/runs.txt" ] || fail "unknown axis starts no job"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)" = "$before" ] || fail "unknown axis makes no worktree"

# --- case: collect --findings-out writes the file run --verify reads
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: CHANGES
P2 slow.ts:9 — missing check — add it
P1 slow.ts:3 — wrong total — sum the parts
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "findings start exits 0"
bash "$REVIEW" collect job-standards job-spec job-overbuild --findings-out "$T/findings-out.txt" \
  >/dev/null 2>&1 || fail "collect --findings-out exits 0"
[ -f "$T/findings-out.txt" ] || fail "collect --findings-out writes the file"
grep -qx 'P2 slow.ts:9 — missing check — add it' "$T/findings-out.txt" || fail "findings file carries the P2 line"
grep -qx 'P1 slow.ts:3 — wrong total — sum the parts' "$T/findings-out.txt" || fail "findings file carries the P1 line"
grep -q VERDICT "$T/findings-out.txt" && fail "findings file holds findings, not verdicts"
write_record verify DONE "FIX-OK all repaired
STATUS: DONE" 0
run_out="$(bash "$REVIEW" run 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings-out.txt" --since "$FAKE_SHA" 2>/dev/null)" || \
  fail "run --verify accepts the findings file"
grep -q "^FIX-OK all repaired$" <<<"$run_out" || fail "verify run prints FIX-OK"
grep -q 'P1 slow.ts:3' "$T/state/prompt-verify.md" || fail "verify brief carries the findings file"

# --- case: collect --findings-out with no open findings writes the no-findings line
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: APPROVE
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "clean start exits 0"
bash "$REVIEW" collect job-standards job-spec job-overbuild --findings-out "$T/clean-findings.txt" \
  >/dev/null 2>&1 || fail "clean collect --findings-out exits 0"
[ "$(cat "$T/clean-findings.txt")" = "no open findings" ] || fail "no findings writes the no-findings line"
write_record verify DONE "FIX-OK
STATUS: DONE" 0
bash "$REVIEW" run 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/clean-findings.txt" --since "$FAKE_SHA" >/dev/null 2>&1 || \
  fail "run --verify accepts the no-findings file"

# --- case: a reprint of a collected job writes --findings-out too, and posts nothing
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
write_record spec DONE "VERDICT spec: CHANGES
P2 slow.ts:9 — missing check — add it
P1 slow.ts:3 — wrong total — sum the parts
STATUS: DONE" 0
write_record overbuild DONE "VERDICT: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --issue 1 --spec 2 \
  --model M --overbuild-model M2 >/dev/null 2>&1 || fail "reprint start exits 0"
bash "$REVIEW" collect job-standards job-spec job-overbuild --findings-out "$T/reprint-a.txt" \
  >/dev/null 2>&1 || fail "reprint first collect exits 0"
cp "$T/reprint-a.txt" "$T/reprint-a.saved"
[ -f "$T/state/comment-pr.txt" ] || fail "reprint first collect posts the comment"
rm -f "$T/reprint-a.txt" "$T/state/comment-pr.txt"
bash "$REVIEW" collect job-standards job-spec job-overbuild --findings-out "$T/reprint-b.txt" \
  >/dev/null 2>&1 || fail "reprint collect exits 0"
[ -f "$T/reprint-b.txt" ] || fail "reprint collect --findings-out writes the file"
cmp -s "$T/reprint-a.saved" "$T/reprint-b.txt" || fail "reprint findings file matches the first collect's file"
[ ! -e "$T/state/comment-pr.txt" ] || fail "reprint collect posts no PR comment"

# --- case: --context copies outside-checkout files into the verify worktree
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
printf 'P2 findings text\n' >"$T/findings.txt"
mkdir -p "$T/ctx-a" "$T/ctx-b"
printf 'plan text\n' >"$T/ctx-a/plan.md"
printf 'mutant list\n' >"$T/ctx-b/plan.md"
write_record verify DONE "FIX-OK
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings.txt" --since "$FAKE_SHA" \
  --context "$T/ctx-a/plan.md" --context "$T/ctx-b/plan.md" >/dev/null 2>&1 || fail "verify --context start exits 0"
wt="$(sed -n 's/^worktree=//p' "$TMPDIR/review-pr/job-verify")"
[ -f "$wt/.review-context/plan.md" ] || fail "verify --context copies the file under its basename"
[ -f "$wt/.review-context/1-plan.md" ] || fail "verify --context disambiguates a basename collision"
cmp -s "$T/ctx-a/plan.md" "$wt/.review-context/plan.md" || fail "verify --context copy matches the first file"
cmp -s "$T/ctx-b/plan.md" "$wt/.review-context/1-plan.md" || fail "verify --context collision copy matches the second file"
grep -q '\.review-context/plan\.md' "$T/state/prompt-verify.md" || fail "verify brief lists the context file"
grep -q '\.review-context/1-plan\.md' "$T/state/prompt-verify.md" || fail "verify brief lists the collision copy"
bash "$REVIEW" collect job-verify >/dev/null 2>&1 || fail "verify --context collect exits 0"

# --- case: a missing --context file exits 1 before creating a worktree
reset_state
printf 'P1 x\n' >"$T/findings.txt"
write_record verify DONE "FIX-OK
STATUS: DONE" 0
st=0
# an earlier case leaves a sibling run's worktrees behind by design, so
# compare against the counts from before this start, like the --axes cases.
before_wt="$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)"
before_rd="$(ls -d "$REVIEW_PR_RUN_ROOT"/review-pr.run.* 2>/dev/null || true)"
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M \
  --verify "$T/findings.txt" --since "$FAKE_SHA" --context "$T/nope.md" 2>&1 >/dev/null)" || st=$?
[ "$st" -eq 1 ] || fail "missing --context exits 1 (got $st)"
grep -Fxq "review-pr: --context file not found: $T/nope.md" <<<"$err" || fail "missing --context names the file"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)" = "$before_wt" ] || \
  fail "missing --context creates no worktree"
[ -z "$(ls "$TMPDIR/review-pr" 2>/dev/null)" ] || fail "missing --context saves no state"
[ "$(ls -d "$REVIEW_PR_RUN_ROOT"/review-pr.run.* 2>/dev/null || true)" = "$before_rd" ] || \
  fail "missing --context leaves no run dir"
[ ! -e "$T/state/runs.txt" ] || fail "missing --context launches no job"

# --- case: review --context appears in the reviewer brief; no-context brief stays unchanged
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
start_review 7 --repo O/N --cwd "$T/clone" --axes standards --model M >/dev/null 2>&1 || \
  fail "review without --context starts"
cp "$T/state/prompt-standards.md" "$T/standards-baseline.md"
! grep -Fq 'Context files outside the checkout' "$T/standards-baseline.md" || \
  fail "review without --context adds no context section"
bash "$REVIEW" collect job-standards >/dev/null 2>&1 || fail "review without --context collects"

reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
mkdir -p "$T/ctx-a" "$T/ctx-b"
printf 'first review context\n' >"$T/ctx-a/plan.md"
printf 'second review context\n' >"$T/ctx-b/plan.md"
start_review 7 --repo O/N --cwd "$T/clone" --axes standards --model M \
  --context "$T/ctx-a/plan.md" --context "$T/ctx-b/plan.md" \
  >/dev/null 2>"$T/stderr-ctx.txt" || fail "review with --context starts"
! grep -Fq 'only used with --verify; ignored' "$T/stderr-ctx.txt" || \
  fail "review with --context is not ignored"
wt="$(worktree_for standards)"
[ -f "$wt/.review-context/plan.md" ] || fail "review --context copies first file"
[ -f "$wt/.review-context/1-plan.md" ] || fail "review --context disambiguates repeated basenames"
cmp -s "$T/ctx-a/plan.md" "$wt/.review-context/plan.md" || fail "review --context copies first file contents"
cmp -s "$T/ctx-b/plan.md" "$wt/.review-context/1-plan.md" || fail "review --context copies second file contents"
grep -Fq '.review-context/plan.md' "$T/state/prompt-standards.md" || fail "review brief names first context file"
grep -Fq '.review-context/1-plan.md' "$T/state/prompt-standards.md" || fail "review brief names second context file"
baseline_lines="$(wc -l <"$T/standards-baseline.md" | tr -d ' ')"
head -n "$baseline_lines" "$T/state/prompt-standards.md" >"$T/standards-context-prefix.md"
cmp -s "$T/standards-baseline.md" "$T/standards-context-prefix.md" || \
  fail "review with --context leaves the existing brief unchanged"
bash "$REVIEW" collect job-standards >/dev/null 2>&1 || fail "review with --context collects"

# --- case: without REVIEW_PR_RUN_ROOT the run dir goes under XDG_CACHE_HOME, not TMPDIR
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
(unset REVIEW_PR_RUN_ROOT; export XDG_CACHE_HOME="$T/xdg"
  start_review 7 --repo O/N --cwd "$T/clone" --model M --axes standards >/dev/null 2>"$T/stderr-xdg.txt") || fail "start without a run root exits 0"
xdg_rd="$(sed -n 's/^run_dir=//p' "$TMPDIR/review-pr/job-standards")"
case "$xdg_rd" in "$T/xdg/review-pr-runs/review-pr.run."*) ;; *) fail "run dir is under XDG_CACHE_HOME: [$xdg_rd]" ;; esac
[ -d "$xdg_rd" ] || fail "run dir exists on disk"
[ -z "$(ls -d "$TMPDIR"/review-pr.run.* 2>/dev/null)" ] || fail "no run dir under TMPDIR"
(unset REVIEW_PR_RUN_ROOT; export XDG_CACHE_HOME="$T/xdg"; bash "$REVIEW" collect job-standards >/dev/null 2>&1) || fail "xdg-root review collects"

# --- refusal and full-rereview cases: a bare second review on a PR that already
# has a review-pr comment for an earlier head at a different patch-id refuses.
OTHER_HEAD="1111111111111111111111111111111111111111"
OTHER_PID="abc123"

# --- case a: refused with a prior comment at a different patch-id (default path)
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $OTHER_PID, head $OTHER_HEAD"
before_wt="$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)"
before_rd="$(ls -d "$REVIEW_PR_RUN_ROOT"/review-pr.run.* 2>/dev/null || true)"
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "refused default path exits 2 (got $st)"
grep -Fq -- "--verify <findings file> --since $OTHER_HEAD" <<<"$err" || fail "refusal names the scoped verify with the prior head"
grep -Fq -- "--cwd $T/clone" <<<"$err" || fail "refusal names the clone"
grep -Fq -- "--model M" <<<"$err" || fail "refusal names the model"
grep -Fq -- "--full-rereview" <<<"$err" || fail "refusal names the override flag"
[ ! -e "$T/state/runs.txt" ] || fail "refused start launches no job"
[ -z "$(ls "$TMPDIR/review-pr" 2>/dev/null)" ] || fail "refused start saves no state"
[ -z "$(ls "$TMPDIR/delegate-jobs" 2>/dev/null || true)" ] || fail "refused start writes no delegate record"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)" = "$before_wt" ] || fail "refused start makes no worktree"
[ "$(ls -d "$REVIEW_PR_RUN_ROOT"/review-pr.run.* 2>/dev/null || true)" = "$before_rd" ] || fail "refused start leaves no run dir"

# --- case b: refused on the --head path too
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $OTHER_PID, head $OTHER_HEAD"
printf '%s\n' "$NEW_SHA" >"$T/state/heads.txt"
before_wt="$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)"
before_rd="$(ls -d "$REVIEW_PR_RUN_ROOT"/review-pr.run.* 2>/dev/null || true)"
err="$(start_review 8 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 --head "$NEW_SHA" 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "refused --head path exits 2 (got $st)"
grep -Fq -- "--since $OTHER_HEAD" <<<"$err" || fail "refused --head names the prior head"
[ ! -e "$T/state/runs.txt" ] || fail "refused --head launches no job"
[ -z "$(ls "$TMPDIR/review-pr" 2>/dev/null)" ] || fail "refused --head saves no state"
[ "$(git -C "$T/clone" worktree list | grep -c 'wt-' || true)" = "$before_wt" ] || fail "refused --head makes no worktree"
[ "$(ls -d "$REVIEW_PR_RUN_ROOT"/review-pr.run.* 2>/dev/null || true)" = "$before_rd" ] || fail "refused --head leaves no run dir"

# --- case c: run is refused before watch writes
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $OTHER_PID, head $OTHER_HEAD"
bash "$REVIEW" run 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 \
  >"$T/stdout-run-refuse.txt" 2>"$T/stderr-run-refuse.txt"; st=$?
[ "$st" -eq 2 ] || fail "refused run exits 2 (got $st)"
[ ! -e "$T/state/watch.txt" ] || fail "refused run writes no watch"
[ ! -e "$T/state/runs.txt" ] || fail "refused run launches no job"
grep -Fq -- "--since $OTHER_HEAD" "$T/stderr-run-refuse.txt" || fail "refused run names the prior head"

# --- case d: no prior comment starts, and a non-matching comment starts
reset_with_approvals
start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 >/dev/null 2>&1 || fail "no prior comment starts"
[ -f "$T/state/runs.txt" ] || fail "no prior comment launches jobs"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "no prior comment collects"
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "LGTM"
start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 >/dev/null 2>&1 || fail "non-matching comment starts"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "non-matching comment collects"

# --- case e: same patch-id with a different head starts (rebase kept the patch)
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $EXPECTED_PID, head $OTHER_HEAD"
start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 >/dev/null 2>&1 || fail "same patch-id rerun starts"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "same patch-id rerun collects"

# --- case f: different patch-id with the same head starts (unchanged-head retry)
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $OTHER_PID, head $FAKE_SHA"
start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 >/dev/null 2>&1 || fail "same head retry starts"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "same head retry collects"

# --- case g: different patch-id and different head refuses
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $OTHER_PID, head $OTHER_HEAD"
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "different patch and head refuses with exit 2 (got $st)"
[ ! -e "$T/state/runs.txt" ] || fail "different patch and head launches no job"

# --- case h: newest comment wins regardless of listing order
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $EXPECTED_PID, head $FAKE_SHA"
plant_comment "2026-10-09T11:00:00Z" 102 "review-pr: patch-id $OTHER_PID, head $OTHER_HEAD"
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "newest different refuses oldest-first (got $st)"
grep -Fq -- "$OTHER_HEAD" <<<"$err" || fail "newest different names the newer head oldest-first"
reset_with_approvals
plant_comment "2026-10-09T11:00:00Z" 102 "review-pr: patch-id $OTHER_PID, head $OTHER_HEAD"
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $EXPECTED_PID, head $FAKE_SHA"
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "newest different refuses newest-first (got $st)"
grep -Fq -- "$OTHER_HEAD" <<<"$err" || fail "newest different names the newer head newest-first"
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $OTHER_PID, head $OTHER_HEAD"
plant_comment "2026-10-09T11:00:00Z" 102 "review-pr: patch-id $EXPECTED_PID, head $OTHER_HEAD"
start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 >/dev/null 2>&1 || fail "newer same-patch starts oldest-first"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "newer same-patch collects oldest-first"
reset_with_approvals
plant_comment "2026-10-09T11:00:00Z" 102 "review-pr: patch-id $EXPECTED_PID, head $OTHER_HEAD"
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $OTHER_PID, head $OTHER_HEAD"
start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 >/dev/null 2>&1 || fail "newer same-patch starts newest-first"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "newer same-patch collects newest-first"

# --- case i: malformed newest falls back to the older valid header
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $OTHER_PID, head $OTHER_HEAD"
plant_comment "2026-10-09T11:00:00Z" 102 "review-pr: patch-id"
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "malformed newest falls back and refuses (got $st)"
grep -Fq -- "$OTHER_HEAD" <<<"$err" || fail "malformed newest names the older valid head"

# --- case j: patch-id none never counts as the same patch
reset_with_approvals
cp "$T/diff.txt" "$T/diff-saved.txt"
: >"$T/diff.txt"
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id none, head $OTHER_HEAD"
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 2>&1 >/dev/null)"; st=$?
cp "$T/diff-saved.txt" "$T/diff.txt"
[ "$st" -eq 2 ] || fail "none patch-ids with different heads refuse (got $st)"
[ ! -e "$T/state/runs.txt" ] || fail "none patch-ids launch no job"

# --- case k: comment fetch failure fails closed with exit 1
reset_with_approvals
touch "$T/state/fail-comments"
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 1 ] || fail "comment fetch failure exits 1 (got $st)"
grep -Fq "could not read PR comments" <<<"$err" || fail "fetch failure names the cause"
grep -Fq "Rerun once the API is reachable" <<<"$err" || fail "fetch failure says to rerun"
[ ! -e "$T/state/runs.txt" ] || fail "fetch failure launches no job"
[ -z "$(ls "$TMPDIR/review-pr" 2>/dev/null)" ] || fail "fetch failure saves no state"

# --- case k2: malformed-only history starts (no valid header picked)
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id"
start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 >/dev/null 2>&1 || fail "malformed-only history starts"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "malformed-only history collects"

# --- case l: --full-rereview overrides the refusal and lands in the header
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $OTHER_PID, head $OTHER_HEAD"
start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 \
  --full-rereview "re-plan after round 2" 2>"$T/stderr-full.txt" >/dev/null || fail "full-rereview with a prior comment starts"
grep -Fq "review-pr: full re-review: re-plan after round 2" "$T/stderr-full.txt" || fail "full-rereview prints the reason"
grep -Fxq "full_rereview=re-plan after round 2" "$TMPDIR/review-pr/job-standards" || fail "full-rereview lands in the state file"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "full-rereview collects"
[ "$(head -1 "$T/state/comment.md")" = "review-pr: patch-id $EXPECTED_PID, head $FAKE_SHA, full-rereview: re-plan after round 2" ] || fail "full-rereview lands in the posted header"
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $OTHER_PID, head $OTHER_HEAD"
touch "$T/state/fail-comments"
start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 \
  --full-rereview "re-plan after round 2" >/dev/null 2>&1 || fail "full-rereview skips the fetch when the API is down"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "full-rereview with a failed fetch collects"
[ "$(head -1 "$T/state/comment.md")" = "review-pr: patch-id $EXPECTED_PID, head $FAKE_SHA, full-rereview: re-plan after round 2" ] || fail "failed-fetch override header carries the reason"
reset_with_approvals
start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 \
  --full-rereview "re-plan after round 2" >/dev/null 2>&1 || fail "full-rereview without a prior comment starts"
bash "$REVIEW" collect job-standards job-spec job-overbuild >/dev/null 2>&1 || fail "full-rereview without prior collects"
[ "$(head -1 "$T/state/comment.md")" = "review-pr: patch-id $EXPECTED_PID, head $FAKE_SHA, full-rereview: re-plan after round 2" ] || fail "no-prior override header carries the reason"

# --- case m: blank, whitespace-only and multi-line reasons are usage errors
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 --full-rereview "" 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "empty full-rereview exits 2 (got $st)"
[ ! -e "$T/state/runs.txt" ] || fail "empty full-rereview launches no job"
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 --full-rereview "   " 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "whitespace-only full-rereview exits 2 (got $st)"
[ ! -e "$T/state/runs.txt" ] || fail "whitespace-only full-rereview launches no job"
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 --full-rereview "$(printf 'one\ntwo')" 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "multi-line full-rereview exits 2 (got $st)"
[ ! -e "$T/state/runs.txt" ] || fail "multi-line full-rereview launches no job"
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
printf 'P1 findings text\n' >"$T/findings.txt"
write_record verify DONE "FIX-OK
STATUS: DONE" 0
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --verify "$T/findings.txt" --since "$FAKE_SHA" --full-rereview "re-plan" 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "full-rereview with --verify exits 2 (got $st)"
[ ! -e "$T/state/runs.txt" ] || fail "full-rereview with --verify launches no job"

# --- case m2: leading-dash reasons are usage errors, never a swallowed flag
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 --full-rereview -x 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "leading-dash full-rereview exits 2 (got $st)"
grep -q "^usage:" <<<"$err" || fail "leading-dash full-rereview prints usage"
[ ! -e "$T/state/runs.txt" ] || fail "leading-dash full-rereview launches no job"
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
write_record standards DONE "VERDICT standards: APPROVE
STATUS: DONE" 0
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 --full-rereview --model 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "flag-looking full-rereview exits 2 (got $st)"
grep -q "^usage:" <<<"$err" || fail "flag-looking full-rereview prints usage"
[ ! -e "$T/state/runs.txt" ] || fail "flag-looking full-rereview launches no job"

# --- case n: verify mode with a prior comment is not refused
reset_state
printf 'ci\tpass\n' >"$T/checks.txt"
printf 'P1 findings text\n' >"$T/findings.txt"
write_record verify DONE "rechecked
FIX-OK all repaired
STATUS: DONE" 0
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $OTHER_PID, head $OTHER_HEAD"
start_review 7 --repo O/N --cwd "$T/clone" --model M --verify "$T/findings.txt" --since "$FAKE_SHA" >/dev/null 2>&1 || fail "verify with a prior comment starts"
bash "$REVIEW" collect job-verify >/dev/null 2>&1 || fail "verify with a prior comment collects"

# --- case o: a reason containing ", head <SHA>" never masks the reviewed head
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $OTHER_PID, head $OTHER_HEAD, full-rereview: take back, head $FAKE_SHA"
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "reason head does not mask the reviewed head (got $st)"
grep -Fq -- "--since $OTHER_HEAD" <<<"$err" || fail "reason-head refusal names the reviewed head"
grep -Fq -- "already has a review for head $OTHER_HEAD" <<<"$err" || fail "reason-head refusal prints the reviewed head"
[ ! -e "$T/state/runs.txt" ] || fail "reason-head refusal launches no job"

# --- case o2: a reason containing a complete header prefix never masks the reviewed head
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $OTHER_PID, head $OTHER_HEAD, full-rereview: take back review-pr: patch-id def456, head 2222222222222222222222222222222222222222"
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "reason header prefix does not mask the reviewed head (got $st)"
grep -Fq -- "--since $OTHER_HEAD" <<<"$err" || fail "reason-prefix refusal names the reviewed head"
grep -Fq -- "already has a review for head $OTHER_HEAD" <<<"$err" || fail "reason-prefix refusal prints the reviewed head"
[ ! -e "$T/state/runs.txt" ] || fail "reason-prefix refusal launches no job"
reset_with_approvals
plant_comment "2026-10-09T10:00:00Z" 101 "review-pr: patch-id $OTHER_PID, head $OTHER_HEAD, full-rereview: take back review-pr: patch-id def456, head $FAKE_SHA"
err="$(start_review 7 --repo O/N --cwd "$T/clone" --model M --overbuild-model M2 2>&1 >/dev/null)"; st=$?
[ "$st" -eq 2 ] || fail "reason header prefix at the current head still refuses (got $st)"
grep -Fq -- "--since $OTHER_HEAD" <<<"$err" || fail "reason-prefix bypass refusal names the reviewed head"
grep -Fq -- "already has a review for head $OTHER_HEAD" <<<"$err" || fail "reason-prefix bypass refusal prints the reviewed head"
[ ! -e "$T/state/runs.txt" ] || fail "reason-prefix bypass refusal launches no job"

echo "review-pr: all cases passed"

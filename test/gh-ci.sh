#!/usr/bin/env bash
# Tests for bin/gh-ci wait, using stand-in gh and sleep functions
# (no network). The wait loop reads REST only: the pull request
# (repos/O/N/pulls/n), the head's workflow runs and its check runs. Fake gh
# serves those from state files (last line sticky) and logs its args. Any
# gh pr view or gh pr checks call is refused and recorded, and every wait
# case fails if one happened.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GHCI="$SCRIPT_DIR/../bin/gh-ci"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-gh-ci.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/state"
export GH_CI_REPO="O/N"
export GH_CI_INTERVAL=7
# CLAUDECODE must not change wait timeouts under test: each case below
# controls it explicitly, so start unset however the suite is invoked.
unset CLAUDECODE

A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# --- fake gh. pulls: head sha advances per head read (draft and base reads
# --- do not); merge states (default CLEAN) advance with it, served lower-case
# --- as REST does. check-runs and actions/runs: one state per poll, last line
# --- sticky; the runs list peeks, the check-runs call advances both.
gh() (
  set -euo pipefail
  echo "gh $*" >>"$T/state/gh-args.txt"
  advance() {
    local f="$1"
    head -1 "$f"
    if [ "$(wc -l <"$f")" -gt 1 ]; then
      tail -n +2 "$f" >"$f.tmp"; mv "$f.tmp" "$f"
    fi
  }
  if [ "$1" = "pr" ]; then
    shift
    # snapshot's reads, served from state files when a snapshot case sets them up
    if [ "${1:-}" = "checks" ] && [ -e "$T/state/pr-checks.txt" ]; then
      cat "$T/state/pr-checks.txt"
      rc=0
      if [ -e "$T/state/pr-checks-rc" ]; then rc="$(cat "$T/state/pr-checks-rc")"; fi
      exit "$rc"
    fi
    if [ "${1:-}" = "view" ] && { [ -e "$T/state/pr-view.json" ] || [ -e "$T/state/pr-view-fail" ]; }; then
      if [ -e "$T/state/pr-view-fail" ]; then
        echo "fake gh: cannot read merge status" >&2
        exit 1
      fi
      cat "$T/state/pr-view.json"
      exit 0
    fi
    # the loop must read REST: a pr view or pr checks call is a failure
    echo "gh pr $*" >>"$T/state/banned.txt"
    echo "fake gh: gh pr $1 is refused: gh-ci wait reads REST (repos/O/N/pulls, commits/SHA/check-runs)" >&2
    exit 9
  fi
  if [ "$1" = "api" ]; then
    shift
    path=""; jq=""
    while [ $# -gt 0 ]; do case "$1" in
      --jq) jq="$2"; shift 2;;
      --paginate|--allow-escape-sequences) shift;;
      *) [ -n "$path" ] || path="$1"; shift;;
    esac; done
    case "$path" in
      repos/O/N/pulls/7)
        [ ! -e "$T/state/view-fail" ] || { echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1; }
        h="$(head -1 "$T/state/heads.txt")"; m=CLEAN
        case "$jq" in *head*)
          # a not-found state file makes the head read fail as a wrong PR number does
          [ ! -e "$T/state/not-found" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
          # a FAIL line makes that head read fail once, as a network blip does
          if [ "$(head -1 "$T/state/heads.txt")" = FAIL ]; then
            advance "$T/state/heads.txt" >/dev/null
            echo "gh: error connecting to api.github.com" >&2; exit 1
          fi
          h="$(advance "$T/state/heads.txt")"
          if [ -e "$T/state/merge-state.txt" ]; then m="$(advance "$T/state/merge-state.txt")"; fi;;
        esac
        draft=false
        if [ -e "$T/state/draft" ]; then draft="$(cat "$T/state/draft")"; fi
        m="$(printf '%s' "$m" | tr 'A-Z' 'a-z')"
        jq -n --arg sha "$h" --arg m "$m" --argjson draft "$draft" \
          '{head: {sha: $sha}, mergeable_state: $m, draft: $draft, base: {ref: "main"}}' \
          | jq -r "$jq";;
      repos/O/N/rules/branches/main)
        [ ! -e "$T/state/rules-fail" ] || { echo "gh: forbidden (HTTP 403)" >&2; exit 1; }
        json="$(cat "$T/state/rules" 2>/dev/null || echo '[]')"
        jq -r "$jq" <<<"$json";;
      repos/O/N/branches/main/protection/required_status_checks)
        [ -e "$T/state/classic" ] || { echo "gh: Branch not protected (HTTP 404)" >&2; exit 1; }
        json="$(cat "$T/state/classic")"
        jq -r "$jq" <<<"$json";;
      repos/O/N/actions/runs*)
        jq -c '{total_count: length, workflow_runs: .}' <<<"$(head -1 "$T/state/runs.txt")";;
      repos/O/N/commits/*/check-runs*)
        line="$(advance "$T/state/checks.txt")"
        [ "$line" != "FAIL" ] || { echo "gh: HTTP 500 from check-runs" >&2; exit 1; }
        advance "$T/state/runs.txt" >/dev/null
        case "$path" in *filter=latest*) line="$(jq -c '[group_by(.name)[] | max_by(.id)]' <<<"$line")";; esac
        jq -c '{total_count: length, check_runs: .}' <<<"$line";;
      *) echo "fake gh: unknown api $path" >&2; exit 2;;
    esac
    exit 0
  fi
  if [ "$1" = "run" ]; then
    shift
    case "${1:-}" in
      list)
        [ ! -e "$T/state/runs-fail" ] || { echo "fake gh: cannot list runs" >&2; exit 1; }
        cat "$T/state/runs.json"
        exit 0;;
      view)
        shift
        _rv_run="${1:-}"; shift || true
        _rv_job=""; _prev=""
        for _a in "$@"; do
          if [ "$_prev" = "--job" ]; then _rv_job="$_a"; fi
          _prev="$_a"
        done
        case " $* " in
          *" --log-failed "*)
            cat "$T/state/log-$_rv_job.txt"
            exit 0;;
          *" --log "*)
            cat "$T/state/runlog-$_rv_run.txt" 2>/dev/null || exit 1
            exit 0;;
          *" --json jobs "*)
            [ ! -e "$T/state/jobs-fail" ] || { echo "fake gh: cannot read jobs" >&2; exit 1; }
            cat "$T/state/jobs-$_rv_run.json"
            exit 0;;
          *" --json headSha "*)
            cat "$T/state/run-$_rv_run-head.txt"
            exit 0;;
          *" --json status"*)
            [ ! -e "$T/state/run-$_rv_run-poll-fail" ] || { echo "fake gh: cannot read run" >&2; exit 1; }
            advance "$T/state/run-$_rv_run-poll.txt"
            exit 0;;
          *" --json name "*)
            cat "$T/state/run-name-$_rv_run.txt" 2>/dev/null || printf '%s\n' "wf-$_rv_run"
            exit 0;;
          *)
            echo "fake gh: unknown run view args: $*" >&2; exit 2;;
        esac;;
      *)
        echo "fake gh: unknown run $1" >&2; exit 2;;
    esac
  fi
  if [ "$1" = "issue" ]; then
    shift
    [ "${1:-}" = "view" ] || { echo "fake gh: unknown issue ${1:-}" >&2; exit 2; }
    shift; num="$1"; shift
    jq_f=""
    while [ $# -gt 0 ]; do case "$1" in -q) jq_f="$2"; shift 2;; *) shift;; esac; done
    [ -e "$T/state/issue-$num-labels.txt" ] || { echo "gh: could not resolve issue $num" >&2; exit 1; }
    jq -Rn '{labels: [inputs | select(length > 0) | {name: .}]}' "$T/state/issue-$num-labels.txt" | jq -r "$jq_f"
    exit 0
  fi
  echo "fake gh: only pr, run, issue and api supported" >&2; exit 2
)
sleep() ( echo "$*" >>"$T/state/sleeps.txt" )
export T
export -f gh sleep

reset_state() {
  rm -f "$T/state/sleeps.txt" "$T/state/gh-args.txt" "$T/state/banned.txt" "$T/state/merge-state.txt" "$T/state/view-fail"
  rm -f "$T/state/heads.txt" "$T/state/checks.txt" "$T/state/runs.txt" "$T/state/rules" "$T/state/rules-fail" "$T/state/classic" "$T/state/draft"
  rm -f "$T/state/runs.json" "$T/state/runs-fail" "$T/state/jobs-fail" "$T/state/not-found"
  rm -f "$T/state"/jobs-*.json "$T/state"/run-name-*.txt "$T/state"/log-*.txt
  rm -f "$T/state"/run-*-head.txt "$T/state"/run-*-poll.txt "$T/state"/run-*-poll-fail
  rm -f "$T/state"/issue-*-labels.txt "$T/state"/runlog-*.txt
  rm -f "$T/state/pr-checks.txt" "$T/state/pr-checks-rc" "$T/state/pr-view.json" "$T/state/pr-view-fail"
  : >"$T/state/gh-args.txt"
}

set_heads() { printf '%s\n' "$@" >"$T/state/heads.txt"; }
set_merge() { printf '%s\n' "$@" >"$T/state/merge-state.txt"; }

# set_run <id> <head-sha> <poll-json>...: the run's head plus one
# status/conclusion JSON object per poll, last line sticky.
set_run() {
  local id="$1" sha="$2"; shift 2
  printf '%s\n' "$sha" >"$T/state/run-$id-head.txt"
  printf '%s\n' "$@" >"$T/state/run-$id-poll.txt"
}

# set_checks <gh-shaped check list>...: one state per poll. Each list (name,
# bucket, and for Actions runs the link and workflow/event) becomes REST check
# runs with the matching conclusion, and the run list the loop reads for the
# head. FAIL makes the check-runs call fail for that poll.
set_checks() {
  : >"$T/state/checks.txt"; : >"$T/state/runs.txt"
  local s
  for s in "$@"; do
    if [ "$s" = FAIL ]; then echo FAIL >>"$T/state/checks.txt"; echo '[]' >>"$T/state/runs.txt"; continue; fi
    printf '%s' "$s" | jq -c '[.[] | {
        name: .name,
        status: (if .bucket == "pending" then "in_progress" else "completed" end),
        conclusion: ({pass: "success", fail: "failure", cancel: "cancelled", skipping: "skipped"}[.bucket] // null),
        details_url: (.link // null),
        app: (if (.app | type) == "object" then .app
              elif (.app | type) == "string" then {slug: .app}
              elif ((.link // "") | test("/actions/runs/[0-9]+/")) then {slug: "github-actions"}
              else null end)}] | to_entries | map(.value + {id: .key})' >>"$T/state/checks.txt"
    printf '%s' "$s" | jq -c '[.[] | select((.link // "") | test("/actions/runs/[0-9]+/"))
        | {id: (.link | capture("/actions/runs/(?<r>[0-9]+)/").r | tonumber), name: .workflow, event: .event}] | unique_by(.id)' \
      >>"$T/state/runs.txt"
  done
}

# set_rest <REST check-run list>: one raw state per poll, no runs list
set_rest() {
  printf '%s\n' "$@" >"$T/state/checks.txt"
  : >"$T/state/runs.txt"
  local i
  for i in $(seq 1 "$#"); do echo '[]' >>"$T/state/runs.txt"; done
}

OUT=""; CODE=0
run_wait() {
  OUT="$(bash "$GHCI" wait "$@" 2>"$T/stderr.txt")"; CODE=$?
  [ ! -s "$T/state/banned.txt" ] || fail "wait called gh pr view or gh pr checks: [$(cat "$T/state/banned.txt")]"
}

RULES_CI='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci"}]}}]'

# --- case: pending then green, with a passing name containing
# --- "failing: 0 pending: 0" (proves no substring matching)
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks \
  '[{"bucket":"pending","name":"ci"},{"bucket":"pass","name":"setup"}]' \
  '[{"bucket":"pass","name":"failing: 0 pending: 0 lint-fail"},{"bucket":"pass","name":"ci"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "pending-then-green exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "pending-then-green pass line: [$OUT]"
grep -q "failing:" <<<"$OUT" && fail "passing names never listed as failing: [$OUT]"
[ -s "$T/state/sleeps.txt" ] || fail "pending-then-green sleeps at least once"
grep -q "^7$" "$T/state/sleeps.txt" || fail "sleep uses GH_CI_INTERVAL: [$(cat "$T/state/sleeps.txt")]"
grep -q "repos/O/N/commits/$A/check-runs?per_page=100&filter=latest" "$T/state/gh-args.txt" \
  || fail "checks read over REST check runs of the head"
grep -q "repos/O/N/actions/runs?head_sha=$A" "$T/state/gh-args.txt" \
  || fail "run list read over REST for the newest-run map"

# --- case: pending then one failure (plus one pass)
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks \
  '[{"bucket":"pending","name":"ci"}]' \
  '[{"bucket":"fail","name":"ci"},{"bucket":"pass","name":"lint"}]'
run_wait 7
[ "$CODE" = "1" ] || fail "one failure exits 1 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: fail" <<<"$OUT" || fail "fail header: [$OUT]"
grep -q "^failing: ci$" <<<"$OUT" || fail "failing job named: [$OUT]"
grep -q "failing: lint" <<<"$OUT" && fail "passing job not listed: [$OUT]"

# --- case: progress goes to stderr when the counts change, once per change;
# --- stdout stays the two lines the callers parse.
reset_state
set_heads "$A"; echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci"},{"context":"lint"}]}}]' >"$T/state/rules"
set_checks \
  '[{"bucket":"pending","name":"ci"},{"bucket":"pass","name":"lint"}]' \
  '[{"bucket":"pending","name":"ci"},{"bucket":"pass","name":"lint"}]' \
  '[{"bucket":"pass","name":"ci"},{"bucket":"pass","name":"lint"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "progress case exits 0 (got $CODE): [$OUT]"
[ "$OUT" = "head: ${A:0:8} CI: pass" ] || fail "progress case stdout unchanged: [$OUT]"
[ "$(cat "$T/stderr.txt")" = "gh-ci: ${A:0:8} pending=1 passed=1 failing=0
gh-ci: ${A:0:8} pending=0 passed=2 failing=0" ] || fail "progress lines on change only, on stderr: [$(cat "$T/stderr.txt")]"

# --- case: progress counts failing checks, and stdout keeps its failing lines
reset_state
set_heads "$A"; echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci"},{"context":"lint"}]}}]' >"$T/state/rules"
set_checks \
  '[{"bucket":"pending","name":"ci"},{"bucket":"pass","name":"lint"}]' \
  '[{"bucket":"fail","name":"ci"},{"bucket":"pass","name":"lint"}]'
run_wait 7
[ "$CODE" = "1" ] || fail "failing progress case exits 1 (got $CODE): [$OUT]"
[ "$OUT" = "$(printf 'head: %s CI: fail\nfailing: ci' "${A:0:8}")" ] || fail "failing progress case stdout unchanged: [$OUT]"
[ "$(cat "$T/stderr.txt")" = "gh-ci: ${A:0:8} pending=1 passed=1 failing=0
gh-ci: ${A:0:8} pending=0 passed=1 failing=1" ] || fail "failing progress lines: [$(cat "$T/stderr.txt")]"

# --- cases: --fail-fast. A failed required check returns at once while another
# --- required check is still pending; without the flag the wait keeps polling.
FF_RULES='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci"},{"context":"lint"}]}}]'
reset_state
set_heads "$A"; echo "$FF_RULES" >"$T/state/rules"
set_checks '[{"bucket":"fail","name":"ci"},{"bucket":"pending","name":"lint"}]'
run_wait 7 --timeout 7 --fail-fast
[ "$CODE" = "1" ] || fail "--fail-fast returns 1 on a failure with a check pending (got $CODE): [$OUT]"
grep -q "^failing: ci$" <<<"$OUT" || fail "--fail-fast names the failing check: [$OUT]"
[ ! -e "$T/state/sleeps.txt" ] || fail "--fail-fast does not wait for the pending check: [$(tr '\n' ' ' <"$T/state/sleeps.txt")]"

reset_state
set_heads "$A"; echo "$FF_RULES" >"$T/state/rules"
set_checks '[{"bucket":"fail","name":"ci"},{"bucket":"pending","name":"lint"}]'
run_wait 7 --timeout 7
[ "$CODE" = "124" ] || fail "without --fail-fast a pending check keeps the wait going (got $CODE): [$OUT]"

# --- case: cancel counts as failing
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"cancel","name":"ci"}]'
run_wait 7
[ "$CODE" = "1" ] || fail "cancel exits 1 (got $CODE): [$OUT]"
grep -q "^failing: ci$" <<<"$OUT" || fail "cancel named as failing: [$OUT]"

# --- case: failing name with an embedded newline still fails (not timeout)
reset_state
set_heads "$A"; echo true >"$T/state/draft"
set_checks '[{"bucket":"fail","name":"ci\nextra"},{"bucket":"pass","name":"ci"}]'
run_wait 7 --timeout 0
[ "$CODE" = "1" ] || fail "newline failing name exits 1 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: fail" <<<"$OUT" || fail "newline failing name header: [$OUT]"

# --- case: passing name with an embedded newline plus a fake record still passes
reset_state
set_heads "$A"; echo true >"$T/state/draft"
set_checks '[{"bucket":"pass","name":"ok\nfail\u001fphantom"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "injection passing name exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "injection passing name line: [$OUT]"
grep -q "failing:" <<<"$OUT" && fail "injection names never listed as failing: [$OUT]"

# --- case: always pending hits the timeout
reset_state
export GH_CI_INTERVAL=30
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pending","name":"ci"}]'
run_wait 7 --timeout 60
[ "$CODE" = "124" ] || fail "timeout exits 124 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} timeout after 60s" <<<"$OUT" || fail "timeout header: [$OUT]"
grep -q "^pending: ci$" <<<"$OUT" || fail "pending job named: [$OUT]"
[ "$(cat "$T/state/sleeps.txt")" = "30
30" ] || fail "timeout sleeps exactly twice with 30: [$(cat "$T/state/sleeps.txt")]"

# --- case: --timeout 0 polls exactly once
reset_state
export GH_CI_INTERVAL=30
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pending","name":"ci"}]'
run_wait 7 --timeout 0
[ "$CODE" = "124" ] || fail "timeout 0 exits 124 (got $CODE): [$OUT]"
[ ! -e "$T/state/sleeps.txt" ] || fail "timeout 0 never sleeps"

# --- case: the default wait timeout is 7200 s
reset_state
export GH_CI_INTERVAL=3600
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pending","name":"ci"}]'
run_wait 7
[ "$CODE" = "124" ] || fail "default timeout exits 124 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} timeout after 7200s" <<<"$OUT" || fail "default timeout header: [$OUT]"
[ "$(cat "$T/state/sleeps.txt")" = "3600
3600" ] || fail "default timeout sleeps twice with 3600: [$(cat "$T/state/sleeps.txt")]"
export GH_CI_INTERVAL=7

# --- case: empty list and a failed check-runs call never exit 0 early while a check is required
reset_state
export GH_CI_INTERVAL=7
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[]' FAIL '[{"bucket":"pass","name":"ci"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "empty-then-green exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "empty-then-green pass line: [$OUT]"
[ "$(grep -c 'check-runs' "$T/state/gh-args.txt")" -ge 3 ] \
  || fail "empty and failed polls keep polling"

# --- case: head changes mid-wait waits on the new head
reset_state
set_heads "$A" "$B"; echo "$RULES_CI" >"$T/state/rules"
set_checks \
  '[{"bucket":"pending","name":"ci"}]' \
  '[{"bucket":"pass","name":"ci"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "head change exits 0 (got $CODE): [$OUT]"
grep -q "head: ${B:0:8} CI: pass" <<<"$OUT" || fail "head change names new head: [$OUT]"

# --- case: head moves during a verdict discards it
reset_state
set_heads "$A" "$B"; echo "$RULES_CI" >"$T/state/rules"
set_checks \
  '[{"bucket":"fail","name":"ci"}]' \
  '[{"bucket":"pass","name":"ci"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "verdict race exits 0 (got $CODE): [$OUT]"
grep -q "head: ${B:0:8} CI: pass" <<<"$OUT" || fail "verdict race names new head: [$OUT]"

# --- cases: conflicts. Grace polls sleep 5 s (not GH_CI_INTERVAL) and count
# --- toward --timeout; only a head that stays DIRTY is reported.
CONFLICT_MSG="PR 7 has merge conflicts: GitHub runs no CI on it. Rebase first."
sleeps_are() { # sleeps_are <n> <secs>: sleeps.txt is exactly n lines of secs
  local want="" i
  for i in $(seq 1 "$1"); do want="${want}${2}"$'\n'; done
  [ "$(cat "$T/state/sleeps.txt" 2>/dev/null)" = "${want%$'\n'}" ]
}
PASS='[{"bucket":"pass","name":"ci"}]'
PEND='[{"bucket":"pending","name":"ci"}]'

# persistent DIRTY: exit 3 after six 5 s sleeps
reset_state
export GH_CI_INTERVAL=30
set_heads "$A"; set_checks "$PASS"; set_merge DIRTY
run_wait 7
[ "$CODE" = "3" ] || fail "persistent conflict exits 3 (got $CODE): [$OUT]"
grep -qF "$CONFLICT_MSG" "$T/stderr.txt" || fail "conflict message: [$(cat "$T/stderr.txt")]"
sleeps_are 6 5 || fail "conflict grace is six 5s sleeps: [$(cat "$T/state/sleeps.txt")]"

# DIRTY then CLEAN within the grace: normal verdict
reset_state
set_heads "$A"; set_checks "$PASS"; echo "$RULES_CI" >"$T/state/rules"; set_merge DIRTY DIRTY CLEAN
run_wait 7
[ "$CODE" = "0" ] || fail "recovered conflict exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "recovered conflict pass line: [$OUT]"
sleeps_are 2 5 || fail "recovered conflict sleeps twice: [$(cat "$T/state/sleeps.txt")]"

# UNKNOWN resets the clock: three DIRTY, UNKNOWN (pending checks), then six DIRTY sleeps
reset_state
set_heads "$A"; set_checks "$PEND"; echo "$RULES_CI" >"$T/state/rules"
set_merge DIRTY DIRTY DIRTY UNKNOWN DIRTY
run_wait 7
[ "$CODE" = "3" ] || fail "reset clock still ends in 3 (got $CODE): [$OUT]"
[ "$(grep -c '^5$' "$T/state/sleeps.txt")" = "9" ] || fail "3 + 6 grace sleeps: [$(tr '\n' ' ' <"$T/state/sleeps.txt")]"
[ "$(grep -c -v '^5$' "$T/state/sleeps.txt")" = "1" ] || fail "UNKNOWN polls checks at the interval: [$(tr '\n' ' ' <"$T/state/sleeps.txt")]"

# UNKNOWN with pending checks never reports a conflict
reset_state
set_heads "$A"; set_checks "$PEND"; echo "$RULES_CI" >"$T/state/rules"; set_merge UNKNOWN
run_wait 7 --timeout 60
[ "$CODE" = "124" ] || fail "UNKNOWN is not a conflict (got $CODE): [$OUT]"

# a new head restarts the clock
reset_state
set_heads "$A" "$A" "$A" "$B"; set_checks "$PASS"; set_merge DIRTY
run_wait 7
[ "$CODE" = "3" ] || fail "head change conflict exits 3 (got $CODE): [$OUT]"
sleeps_are 9 5 || fail "clock restarts on the new head (3 + 6 sleeps): [$(tr '\n' ' ' <"$T/state/sleeps.txt")]"

# --timeout bounds the grace; budget spent while DIRTY reports the conflict
reset_state
set_heads "$A"; set_checks "$PASS"; set_merge DIRTY
run_wait 7 --timeout 0
[ "$CODE" = "3" ] || fail "timeout 0 on conflict exits 3 (got $CODE): [$OUT]"
[ ! -e "$T/state/sleeps.txt" ] || fail "timeout 0 on conflict never sleeps"
reset_state
set_heads "$A"; set_checks "$PASS"; set_merge DIRTY
run_wait 7 --timeout 10
[ "$CODE" = "3" ] || fail "timeout 10 on conflict exits 3 (got $CODE): [$OUT]"
sleeps_are 2 5 || fail "timeout 10 sleeps two 5s: [$(cat "$T/state/sleeps.txt")]"

# a conflict that appears after the checks call discards the verdict
reset_state
set_heads "$A"; set_checks "$PASS"; echo "$RULES_CI" >"$T/state/rules"; set_merge CLEAN DIRTY
run_wait 7 --timeout 0
[ "$CODE" = "3" ] || fail "conflict after checks exits 3 (got $CODE): [$OUT]"

# snapshot and watch-verified exit 3 at once
reset_state
set_heads "$A"; set_checks "$PASS"; set_merge DIRTY
OUT="$(bash "$GHCI" snapshot 7 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "3" ] || fail "snapshot conflict exits 3 (got $CODE): [$OUT]"
grep -qF "$CONFLICT_MSG" "$T/stderr.txt" || fail "snapshot conflict message: [$(cat "$T/stderr.txt")]"
[ ! -e "$T/state/sleeps.txt" ] || fail "snapshot conflict never sleeps"
OUT="$(bash "$GHCI" watch-verified 99 --pr 7 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "3" ] || fail "watch-verified conflict exits 3 (got $CODE): [$OUT]"

# --- cases: snapshot with no checks on the head prints a merge line (#438).
# --- "no checks" is gh pr checks output with no tab-separated check line.
# no checks: pr checks reports none and exits 1, so snapshot reads
# mergeable and mergeStateStatus and prints them with the hint
reset_state
set_heads "$A"
printf "%s\n" "no checks reported on the 'b' branch" >"$T/state/pr-checks.txt"
echo 1 >"$T/state/pr-checks-rc"
printf '%s' '{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' >"$T/state/pr-view.json"
OUT="$(bash "$GHCI" snapshot 7 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "0" ] || fail "snapshot no-checks exits 0 (got $CODE): [$OUT]"
[ "$OUT" = "$(printf 'head: %s\nCI: unknown\nFlake: unknown\npending: 0 failing: 0\nmerge: mergeable=CONFLICTING state=DIRTY; no checks on this head; a conflicting PR gets none: check mergeable or rebase' "${A:0:8}")" ] \
  || fail "snapshot no-checks merge line: [$OUT]"
grep -q 'pr view' "$T/state/gh-args.txt" || fail "snapshot no-checks reads pr view: [$(cat "$T/state/gh-args.txt")]"

# pr view fails: the merge values are unknown but the hint stays, still exit 0
reset_state
set_heads "$A"
printf "%s\n" "no checks reported on the 'b' branch" >"$T/state/pr-checks.txt"
echo 1 >"$T/state/pr-checks-rc"
touch "$T/state/pr-view-fail"
printf '%s' '{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' >"$T/state/pr-view.json"
OUT="$(bash "$GHCI" snapshot 7 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "0" ] || fail "snapshot pr-view-fail exits 0 (got $CODE): [$OUT]"
grep -q '^merge: unknown; no checks on this head; a conflicting PR gets none: check mergeable or rebase$' <<<"$OUT" \
  || fail "snapshot unknown merge line: [$OUT]"

# a gh failure other than "no checks" prints no merge line, still exit 0
reset_state
set_heads "$A"
printf "%s\n" "fake gh: HTTP 502" >"$T/state/pr-checks.txt"
echo 1 >"$T/state/pr-checks-rc"
printf '%s' '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' >"$T/state/pr-view.json"
OUT="$(bash "$GHCI" snapshot 7 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "0" ] || fail "snapshot gh-failure exits 0 (got $CODE): [$OUT]"
grep -q '^CI: unknown$' <<<"$OUT" || fail "snapshot gh-failure keeps CI unknown: [$OUT]"
grep -q '^merge: ' <<<"$OUT" && fail "snapshot gh-failure prints no merge line: [$OUT]"
grep -q 'pr view' "$T/state/gh-args.txt" && fail "snapshot gh-failure makes no pr view call: [$(cat "$T/state/gh-args.txt")]"

# one check: no merge line and no pr view call
reset_state
set_heads "$A"
printf 'ci\tpass\n' >"$T/state/pr-checks.txt"
printf '%s' '{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' >"$T/state/pr-view.json"
OUT="$(bash "$GHCI" snapshot 7 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "0" ] || fail "snapshot with a check exits 0 (got $CODE): [$OUT]"
grep -q '^merge: ' <<<"$OUT" && fail "snapshot with a check prints no merge line: [$OUT]"
grep -q 'pr view' "$T/state/gh-args.txt" && fail "snapshot with a check makes no pr view call: [$(cat "$T/state/gh-args.txt")]"

# --- case: an unreadable head is pending: the first read fails, the next succeeds
export GH_CI_INTERVAL=7
reset_state
set_heads FAIL "$A"
set_checks '[{"bucket":"pass","name":"ci"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "one failed head read then green exits 0 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "failed head read names the head read after it: [$OUT]"
grep -q "could not read the head of PR 7" "$T/stderr.txt" || fail "failed head read is reported: [$(cat "$T/stderr.txt")]"
sleeps_are 1 7 || fail "failed head read sleeps once: [$(tr '\n' ' ' <"$T/state/sleeps.txt")]"

# --- case: a head that is never readable times out with 124, not 1
reset_state
set_heads FAIL FAIL FAIL FAIL FAIL FAIL FAIL FAIL
set_checks '[{"bucket":"pass","name":"ci"}]'
run_wait 7 --timeout 7
[ "$CODE" = "124" ] || fail "unreadable head times out with 124 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
grep -qx "head: unreadable timeout after 7s" <<<"$OUT" || fail "unreadable timeout line: [$OUT]"
! grep -q "CI: " <<<"$OUT" || fail "unreadable head prints no verdict: [$OUT]"

# --- case: a PR not found (HTTP 404 on the head read) fails at once with 1, no sleep
reset_state
touch "$T/state/not-found"
set_heads "$A"
run_wait 7 --timeout 7
[ "$CODE" = "1" ] || fail "not-found PR exits 1 at once (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
[ ! -e "$T/state/sleeps.txt" ] || fail "not-found PR never sleeps: [$(tr '\n' ' ' <"$T/state/sleeps.txt")]"
[ -z "$OUT" ] || fail "not-found PR prints no verdict: [$OUT]"
grep -qx "PR 7 not found in O/N" "$T/stderr.txt" || fail "not-found line: [$(cat "$T/stderr.txt")]"

# --- case: a failed recheck retries from the top; no pass before a readable recheck
reset_state
set_heads "$A" FAIL "$A"
set_checks '[{"bucket":"pass","name":"ci"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "failed recheck then readable exits 0 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
[ "$(grep -c "CI: pass" <<<"$OUT")" = "1" ] || fail "one pass line after a readable recheck: [$OUT]"
grep -q "could not read the head of PR 7" "$T/stderr.txt" || fail "failed recheck is reported: [$(cat "$T/stderr.txt")]"

# --- cases: a required check green on the head passes whenever it ran;
# --- a required name of the base branch with no check on the head is pending
# a green required check passes at once, and startedAt is never requested
reset_state
export GH_CI_INTERVAL=7
set_heads "$A"; set_checks "$PASS"; echo "$RULES_CI" >"$T/state/rules"
run_wait 7
[ "$CODE" = "0" ] || fail "green required check exits 0 (got $CODE): [$OUT]"
[ ! -e "$T/state/sleeps.txt" ] || fail "green required check never sleeps"
! grep -q startedAt "$T/state/gh-args.txt" || fail "startedAt is never requested"

# only a differently named (draft) check ran: ci is absent, so it is pending
reset_state
set_heads "$A"; set_checks '[]'; echo "$RULES_CI" >"$T/state/rules"
run_wait 7 --timeout 7
[ "$CODE" = "124" ] || fail "draft-only check times out (got $CODE): [$OUT]"
grep -q "^pending: ci$" <<<"$OUT" || fail "draft-only names ci pending: [$OUT]"

# a required name with no check stays pending, while the others pass
reset_state
set_heads "$A"
set_checks '[{"bucket":"pass","name":"lint"}]'
echo '{"contexts":["lint","ci"]}' >"$T/state/classic"
run_wait 7 --timeout 7
[ "$CODE" = "124" ] || fail "absent required check times out (got $CODE): [$OUT]"
grep -q "^pending: ci$" <<<"$OUT" || fail "absent check named pending: [$OUT]"

# no required names (classic 404, no rules): gh's "no checks" text passes at once (#155)
reset_state
set_heads "$A"; set_checks '[]'
run_wait 7 --timeout 0
[ "$CODE" = "0" ] || fail "no required names passes (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "no required names pass line: [$OUT]"
[ ! -e "$T/state/sleeps.txt" ] || fail "no required names never sleeps"
! grep -q 'check-runs' "$T/state/gh-args.txt" || fail "no required names never reads check runs"

# no required names while a non-required check is pending: still passes at once (#155)
reset_state
set_heads "$A"; set_checks '[{"bucket":"pending","name":"lint"}]'
run_wait 7 --timeout 0
[ "$CODE" = "0" ] || fail "no required names, pending non-required passes (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "non-required pending pass line: [$OUT]"
[ ! -e "$T/state/sleeps.txt" ] || fail "non-required pending never sleeps"

# rules lookup fails: warning, empty list stays pending
reset_state
set_heads "$A"; set_checks '[]'; touch "$T/state/rules-fail"
run_wait 7 --timeout 0
[ "$CODE" = "124" ] || fail "unreadable names, empty list is pending (got $CODE): [$OUT]"
grep -q "gh-ci: cannot read required checks; judging every check on the head" "$T/stderr.txt" \
  || fail "lookup warning: [$(cat "$T/stderr.txt")]"
grep -q 'check-runs' "$T/state/gh-args.txt" \
  || fail "unreadable names still read the head's check runs: [$(cat "$T/state/gh-args.txt")]"

# --- cases: draft PRs settle on the head's checks (no required names, no padding)
# a draft whose only check is `CI (draft)` passes at once, though `CI` is required
reset_state
export GH_CI_INTERVAL=7
set_heads "$A"; echo true >"$T/state/draft"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pass","name":"CI (draft)"}]'
run_wait 7 --timeout 7
[ "$CODE" = "0" ] || fail "draft green exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass (draft: required checks run once ready)" <<<"$OUT" \
  || fail "draft pass note: [$OUT]"
[ ! -e "$T/state/sleeps.txt" ] || fail "draft green never sleeps"
! grep -q 'rules/branches' "$T/state/gh-args.txt" || fail "draft: required names never read"

# a draft with a failing check fails
reset_state
set_heads "$A"; echo true >"$T/state/draft"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"fail","name":"CI (draft)"}]'
run_wait 7
[ "$CODE" = "1" ] || fail "draft failure exits 1 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: fail" <<<"$OUT" || fail "draft fail header: [$OUT]"
grep -q '^failing: CI (draft)$' <<<"$OUT" || fail "draft failing job named: [$OUT]"

# --- cases: wait ignores checks from a superseded workflow run
# a stale fail from run 1 next to passes from run 2 of the same workflow passes
reset_state
set_heads "$A"; echo true >"$T/state/draft"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"name":"CI (draft)","bucket":"fail","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/1/job/11"},{"name":"CI","bucket":"pass","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/2/job/21"},{"name":"lint","bucket":"pass","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/2/job/22"}]'
run_wait 7 --timeout 7
[ "$CODE" = "0" ] || fail "superseded draft fail exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass (draft: required checks run once ready)" <<<"$OUT" \
  || fail "superseded draft pass line: [$OUT]"
grep -q 'actions/runs?head_sha=' "$T/state/gh-args.txt" \
  || fail "draft run list read for workflow and event"

# a failing check from the current run still fails
reset_state
set_heads "$A"; echo true >"$T/state/draft"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"name":"CI (draft)","bucket":"pass","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/1/job/11"},{"name":"CI","bucket":"fail","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/2/job/21"}]'
run_wait 7
[ "$CODE" = "1" ] || fail "current-run failure exits 1 (got $CODE): [$OUT]"
grep -q "^failing: CI$" <<<"$OUT" || fail "current failing job named: [$OUT]"

# a failing check run with a non-Actions link is kept
reset_state
set_heads "$A"; echo true >"$T/state/draft"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"name":"third-party","bucket":"fail","link":"https://example.com/status/1"},{"name":"CI","bucket":"pass","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/2/job/21"}]'
run_wait 7
[ "$CODE" = "1" ] || fail "status-context failure exits 1 (got $CODE): [$OUT]"
grep -q "^failing: third-party$" <<<"$OUT" || fail "status context named: [$OUT]"

# a cancelled required check from an old run is pending while the new run's
# required job has not appeared yet (a non-required job proves the new run)
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
printf 'ci\n' >"$T/state/required-filter"
set_checks '[{"name":"ci","bucket":"cancel","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/1/job/11"},{"name":"setup","bucket":"pending","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/2/job/21"}]'
run_wait 7 --timeout 0
[ "$CODE" = "124" ] || fail "superseded required cancel is pending (got $CODE): [$OUT]"
grep -q "^pending: ci$" <<<"$OUT" || fail "superseded required check named pending: [$OUT]"

# a cancelled required check replaced by a passing one in the new run passes
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"name":"ci","bucket":"cancel","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/1/job/11"},{"name":"ci","bucket":"pass","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/2/job/21"}]'
run_wait 7
[ "$CODE" = "0" ] || fail "replaced required cancel passes (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "replaced required pass line: [$OUT]"

# required names unreadable: the newest-run map still uses every check, so a
# cancelled required check from a superseded run is pending, not failing
reset_state
set_heads "$A"; touch "$T/state/rules-fail"
printf 'ci\n' >"$T/state/required-filter"
set_checks '[{"name":"ci","bucket":"cancel","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/1/job/11"},{"name":"setup","bucket":"pending","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/2/job/21"}]'
run_wait 7 --timeout 0
[ "$CODE" = "124" ] || fail "superseded required cancel with unreadable names is pending (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} timeout after 0s" <<<"$OUT" || fail "superseded unreadable-names timeout header: [$OUT]"

# a draft with no checks yet stays pending to timeout
reset_state
set_heads "$A"; echo true >"$T/state/draft"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[]'
run_wait 7 --timeout 7
[ "$CODE" = "124" ] || fail "draft empty stays pending (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} timeout after 7s" <<<"$OUT" || fail "draft empty timeout header: [$OUT]"

# --- case: a rerun under the same run ID replaces its failed first attempt
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
printf '%s\n' '[{"id":1,"name":"ci","status":"completed","conclusion":"failure","details_url":"https://github.com/O/N/actions/runs/5/job/11"},{"id":2,"name":"ci","status":"completed","conclusion":"success","details_url":"https://github.com/O/N/actions/runs/5/job/12"}]' >"$T/state/checks.txt"
echo '[{"id":5,"name":"CI","event":"pull_request"}]' >"$T/state/runs.txt"
run_wait 7 --timeout 0
[ "$CODE" = "0" ] || fail "rerun of a failed check passes (got $CODE): [$OUT]"
grep -q 'filter=latest' "$T/state/gh-args.txt" || fail "check runs read with filter=latest: [$(cat "$T/state/gh-args.txt")]"

# --- case: a rerun in flight keeps the wait pending: the old failure's
# --- check-run is completed but its run is not completed (#282)
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
printf '%s\n' '[{"id":1,"name":"ci","status":"completed","conclusion":"failure","details_url":"https://github.com/O/N/actions/runs/5/job/11"}]' >"$T/state/checks.txt"
echo '[{"id":5,"name":"CI","event":"pull_request","status":"in_progress","run_attempt":2}]' >"$T/state/runs.txt"
run_wait 7 --timeout 0
[ "$CODE" = "124" ] || fail "rerun in flight stays pending (got $CODE): [$OUT]"
grep -q "^pending: ci$" <<<"$OUT" || fail "rerun in flight names ci pending: [$OUT]"

# --- case: a separate queued run does not hide the completed result (#476)
# --- two runs of the same workflow and event on the head: the older
# --- completed green (run_attempt 1), the newer queued (run_attempt 1).
# --- The wait settles on the completed result and names the queued run.
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
printf '%s\n' '[{"id":1,"name":"ci","status":"completed","conclusion":"success","details_url":"https://github.com/O/N/actions/runs/5/job/11"},{"id":2,"name":"setup","status":"in_progress","conclusion":null,"details_url":"https://github.com/O/N/actions/runs/6/job/21"}]' >"$T/state/checks.txt"
echo '[{"id":5,"name":"CI","event":"pull_request","status":"completed","run_attempt":1},{"id":6,"name":"CI","event":"pull_request","status":"queued","run_attempt":1}]' >"$T/state/runs.txt"
run_wait 7 --timeout 0
[ "$CODE" = "0" ] || fail "separate queued run settles on the completed result (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} CI: pass" <<<"$OUT" || fail "separate queued run pass line: [$OUT]"
grep -q "queued run 6" "$T/stderr.txt" || fail "separate queued run id on stderr: [$(cat "$T/stderr.txt")]"

# --- cases: REST check-run conclusions map onto the buckets the verdict reads
# the loop never calls gh pr view or gh pr checks (refused by the stand-in)
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_rest '[{"name":"ci","status":"completed","conclusion":"neutral"},{"name":"lint","status":"completed","conclusion":"skipped"},{"name":"stale","status":"completed","conclusion":"stale"}]'
run_wait 7 --timeout 0
[ "$CODE" = "0" ] || fail "neutral, skipped and stale pass (got $CODE): [$OUT]"
[ ! -s "$T/state/banned.txt" ] || fail "loop reads no gh pr view or gh pr checks"
for c in timed_out startup_failure action_required cancelled; do
  reset_state
  set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
  set_rest "[{\"name\":\"ci\",\"status\":\"completed\",\"conclusion\":\"$c\"}]"
  run_wait 7 --timeout 0
  [ "$CODE" = "1" ] || fail "conclusion $c fails (got $CODE): [$OUT]"
  grep -q "^failing: ci$" <<<"$OUT" || fail "conclusion $c names ci: [$OUT]"
done
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_rest '[{"name":"ci","status":"queued","conclusion":null}]'
run_wait 7 --timeout 0
[ "$CODE" = "124" ] || fail "queued check is pending (got $CODE): [$OUT]"
grep -q "^pending: ci$" <<<"$OUT" || fail "queued check named pending: [$OUT]"

# a failed check-runs call polls again and never reports a verdict
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks FAIL
run_wait 7 --timeout 0
[ "$CODE" = "124" ] || fail "failed check-runs call stays pending (got $CODE): [$OUT]"

# a check run that is green on the head, and a loop that polls twice, never reads
# gh pr view or gh pr checks
reset_state
set_heads "$A" "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks "$PEND" "$PASS"
run_wait 7
[ "$CODE" = "0" ] || fail "pending then green over REST (got $CODE): [$OUT]"
[ ! -e "$T/state/banned.txt" ] || fail "no banned gh pr call in the loop"
grep -q 'gh api repos/O/N/pulls/7 --jq' "$T/state/gh-args.txt" || fail "head read over REST pulls"

# --- cases: --job waits on the newest run's job of exactly that name (#439)
# the job is absent, then pending, then passes while another check stays
# pending: the wait returns on the job, not the run
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks \
  '[]' \
  '[{"bucket":"pending","name":"e2e","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/5/job/51","app":{"slug":"github-actions"}}]' \
  '[{"bucket":"pass","name":"e2e","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/5/job/51","app":{"slug":"github-actions"}},{"bucket":"pending","name":"lint","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/5/job/52","app":{"slug":"github-actions"}}]'
run_wait 7 --job e2e
[ "$CODE" = "0" ] || fail "job pass exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} job: e2e pass" <<<"$OUT" || fail "job pass line: [$OUT]"
grep -q "CI: " <<<"$OUT" && fail "job pass prints no CI line: [$OUT]"
! grep -q 'rules/branches' "$T/state/gh-args.txt" || fail "job: required names never read: [$(cat "$T/state/gh-args.txt")]"
! grep -q -- '--jq .draft' "$T/state/gh-args.txt" || fail "job: draft never read: [$(cat "$T/state/gh-args.txt")]"

# the job fails while other checks are pending: exit 1 with failing: <name>
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"fail","name":"e2e","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/5/job/51","app":{"slug":"github-actions"}},{"bucket":"pending","name":"lint","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/5/job/52","app":{"slug":"github-actions"}}]'
run_wait 7 --job e2e
[ "$CODE" = "1" ] || fail "job fail exits 1 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} job: e2e fail" <<<"$OUT" || fail "job fail line: [$OUT]"
grep -q "^failing: e2e$" <<<"$OUT" || fail "failing job named: [$OUT]"
grep -q "failing: lint" <<<"$OUT" && fail "other checks not listed: [$OUT]"

# the job never appears: 124 at the timeout
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pass","name":"lint"}]'
run_wait 7 --job e2e --timeout 7
[ "$CODE" = "124" ] || fail "absent job times out (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} timeout after 7s" <<<"$OUT" || fail "absent job timeout header: [$OUT]"

# the name match is exact: "<name> extra" does not count
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pass","name":"e2e extra"}]'
run_wait 7 --job e2e --timeout 0
[ "$CODE" = "124" ] || fail "inexact name stays pending (got $CODE): [$OUT]"
grep -q "job: e2e pass" <<<"$OUT" && fail "inexact name never passes: [$OUT]"

# a non-Actions check-run named e2e with no Actions job e2e stays pending
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pass","name":"e2e","link":"https://example.com/status/1"}]'
run_wait 7 --job e2e --timeout 0
[ "$CODE" = "124" ] || fail "non-Actions e2e stays pending (got $CODE): [$OUT]"
grep -q "job: e2e pass" <<<"$OUT" && fail "non-Actions e2e never passes: [$OUT]"

# an external check-run named e2e with an Actions-shaped link but a
# non-Actions app stays pending: only the head's own Actions jobs count
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pass","name":"e2e","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/5/job/51","app":{"slug":"some-app"}}]'
run_wait 7 --job e2e --timeout 0
[ "$CODE" = "124" ] || fail "external-app e2e stays pending (got $CODE): [$OUT]"
grep -q "job: e2e pass" <<<"$OUT" && fail "external-app e2e never passes: [$OUT]"

# --job with no value or an empty value is usage
reset_state
run_wait 7 --job; [ "$CODE" = "2" ] || fail "--job with no value exits 2 (got $CODE)"
run_wait 7 --job ""; [ "$CODE" = "2" ] || fail "--job with an empty value exits 2 (got $CODE)"

# a draft PR with --job still waits on the named job: an empty list stays
# pending instead of passing at once with the draft note
reset_state
set_heads "$A"; echo true >"$T/state/draft"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[]' '[{"bucket":"pass","name":"e2e","workflow":"CI","event":"pull_request","link":"https://github.com/O/N/actions/runs/5/job/51","app":{"slug":"github-actions"}}]'
run_wait 7 --job e2e
[ "$CODE" = "0" ] || fail "draft job pass exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} job: e2e pass" <<<"$OUT" || fail "draft job pass line: [$OUT]"
grep -q "draft" <<<"$OUT" && fail "draft note never printed with --job: [$OUT]"
[ -s "$T/state/sleeps.txt" ] || fail "draft empty list stays pending: never passes at once"

# --- cases: --run waits on ONE workflow run by id and returns its own conclusion (#309)
export GH_CI_INTERVAL=7
# a failing dispatch run fails even though the PR's required checks pass (a plain wait would pass)
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pass","name":"ci"}]'
set_run 555 "$A" '{"status":"in_progress","conclusion":null}' '{"status":"completed","conclusion":"failure"}'
printf '%s' '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}' >"$T/state/jobs-555.json"
run_wait 7 --run 555
[ "$CODE" = "1" ] || fail "run fail exits 1 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} run: 555 fail" <<<"$OUT" || fail "run fail line: [$OUT]"
grep -q "^failing: build$" <<<"$OUT" || fail "run failing job named: [$OUT]"
! grep -q 'check-runs' "$T/state/gh-args.txt" || fail "run: the head checks are never read: [$(cat "$T/state/gh-args.txt")]"
! grep -q 'rules/branches' "$T/state/gh-args.txt" || fail "run: required names never read: [$(cat "$T/state/gh-args.txt")]"

# the run passes: exit 0 with the run pass line
reset_state
set_heads "$A"
set_run 556 "$A" '{"status":"in_progress","conclusion":null}' '{"status":"completed","conclusion":"success"}'
run_wait 7 --run 556
[ "$CODE" = "0" ] || fail "run pass exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} run: 556 pass" <<<"$OUT" || fail "run pass line: [$OUT]"

# the run is on another sha: stale, exit 1 with no waiting
reset_state
set_heads "$A"
set_run 557 "$B" '{"status":"completed","conclusion":"success"}'
run_wait 7 --run 557
[ "$CODE" = "1" ] || fail "stale run exits 1 (got $CODE): [$OUT]"
grep -qF "run 557 is on ${B:0:8}, PR head is ${A:0:8}: stale run" "$T/stderr.txt" || fail "stale line: [$(cat "$T/stderr.txt")]"
[ ! -e "$T/state/sleeps.txt" ] || fail "stale run never sleeps: [$(cat "$T/state/sleeps.txt")]"

# a run that never completes times out with 124
reset_state
set_heads "$A"
set_run 558 "$A" '{"status":"in_progress","conclusion":null}'
run_wait 7 --run 558 --timeout 7
[ "$CODE" = "124" ] || fail "run timeout exits 124 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} timeout after 7s" <<<"$OUT" || fail "run timeout header: [$OUT]"

# --run with --job, or with a non-numeric id, is usage
reset_state
set_heads "$A"
set_run 555 "$A" '{"status":"completed","conclusion":"success"}'
run_wait 7 --job e2e --run 555; [ "$CODE" = "2" ] || fail "--run with --job exits 2 (got $CODE)"
run_wait 7 --run abc; [ "$CODE" = "2" ] || fail "--run abc exits 2 (got $CODE)"

# --- cases: --run without a PR waits on the run alone with no head check (#309)
# no PR, pass: exit 0 with "run: <id> pass" and no head read
reset_state
set_run 559 "$A" '{"status":"in_progress","conclusion":null}' '{"status":"completed","conclusion":"success"}'
run_wait --run 559
[ "$CODE" = "0" ] || fail "run-alone pass exits 0 (got $CODE): [$OUT]"
grep -q "^run: 559 pass$" <<<"$OUT" || fail "run-alone pass line: [$OUT]"
grep -q "head:" <<<"$OUT" && fail "run-alone pass prints no head: [$OUT]"
! grep -q 'pulls' "$T/state/gh-args.txt" || fail "run-alone pass makes no head read: [$(cat "$T/state/gh-args.txt")]"
[ -s "$T/state/sleeps.txt" ] || fail "run-alone pass waits at least once"

# no PR, fail: exit 1 with "run: <id> fail" and the failing job
reset_state
set_run 560 "$A" '{"status":"completed","conclusion":"failure"}'
printf '%s' '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}' >"$T/state/jobs-560.json"
run_wait --run 560
[ "$CODE" = "1" ] || fail "run-alone fail exits 1 (got $CODE): [$OUT]"
grep -q "^run: 560 fail$" <<<"$OUT" || fail "run-alone fail line: [$OUT]"
grep -q "^failing: build$" <<<"$OUT" || fail "run-alone failing job named: [$OUT]"
! grep -q 'pulls' "$T/state/gh-args.txt" || fail "run-alone fail makes no head read: [$(cat "$T/state/gh-args.txt")]"

# no PR, timeout: exit 124 with "run <id> timeout after <n>s"
reset_state
set_run 561 "$A" '{"status":"in_progress","conclusion":null}'
run_wait --run 561 --timeout 7
[ "$CODE" = "124" ] || fail "run-alone timeout exits 124 (got $CODE): [$OUT]"
grep -q "^run 561 timeout after 7s$" <<<"$OUT" || fail "run-alone timeout line: [$OUT]"

# --run with --pr: a run on the head passes, a run on another sha is stale
reset_state
set_heads "$A"
set_run 562 "$A" '{"status":"completed","conclusion":"success"}'
run_wait --run 562 --pr 7
[ "$CODE" = "0" ] || fail "run --pr pass exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} run: 562 pass" <<<"$OUT" || fail "run --pr pass line: [$OUT]"
reset_state
set_heads "$A"
set_run 563 "$B" '{"status":"completed","conclusion":"success"}'
run_wait --run 563 --pr 7
[ "$CODE" = "1" ] || fail "run --pr stale exits 1 (got $CODE): [$OUT]"
grep -qF "run 563 is on ${B:0:8}, PR head is ${A:0:8}: stale run" "$T/stderr.txt" || fail "run --pr stale line: [$(cat "$T/stderr.txt")]"
[ ! -e "$T/state/sleeps.txt" ] || fail "run --pr stale never sleeps"

# the positional PR form still works: pass and fail
reset_state
set_heads "$A"
set_run 564 "$A" '{"status":"completed","conclusion":"success"}'
run_wait 7 --run 564
[ "$CODE" = "0" ] || fail "positional run pass exits 0 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} run: 564 pass" <<<"$OUT" || fail "positional run pass line: [$OUT]"
reset_state
set_heads "$A"
set_run 565 "$A" '{"status":"completed","conclusion":"failure"}'
printf '%s' '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}' >"$T/state/jobs-565.json"
run_wait 7 --run 565
[ "$CODE" = "1" ] || fail "positional run fail exits 1 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} run: 565 fail" <<<"$OUT" || fail "positional run fail line: [$OUT]"
grep -q "^failing: build$" <<<"$OUT" || fail "positional run failing job named: [$OUT]"

# --pr without --run is usage
reset_state
run_wait --pr 7; [ "$CODE" = "2" ] || fail "wait --pr without --run exits 2 (got $CODE)"

# --- case: usage errors exit 2
reset_state
run_wait; [ "$CODE" = "2" ] || fail "missing pr exits 2 (got $CODE)"
run_wait --pr 7; [ "$CODE" = "2" ] || fail "--pr misuse exits 2 (got $CODE)"
run_wait 7 --bogus; [ "$CODE" = "2" ] || fail "unknown flag exits 2 (got $CODE)"
run_wait 7 --timeout abc; [ "$CODE" = "2" ] || fail "non-numeric timeout exits 2 (got $CODE)"
run_wait 7 --timeout; [ "$CODE" = "2" ] || fail "missing timeout value exits 2 (got $CODE)"
run_wait 7 --since 2026-10-06T12:00:00Z; [ "$CODE" = "2" ] || fail "--since is an unknown flag, exits 2 (got $CODE)"

# --- case: no subcommand and unknown subcommand print usage, exit 2
OUT="$(bash "$GHCI" 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "no args exits 2 (got $CODE)"
grep -q '^usage: gh-ci' "$T/stderr.txt" || fail "no args prints usage on stderr: [$(cat "$T/stderr.txt")]"
OUT="$(bash "$GHCI" bogus 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "unknown subcommand exits 2 (got $CODE)"
grep -q '^usage: gh-ci' "$T/stderr.txt" || fail "unknown subcommand prints usage on stderr"

# usage comes before the repo lookup: with no override and a failing gh
(
  gh() ( exit 1 )
  export -f gh
  for a in "" bogus; do
    OUT="$(env -u GH_CI_REPO bash "$GHCI" $a 2>"$T/stderr.txt")"; CODE=$?
    [ "$CODE" = "2" ] || fail "usage without repo lookup exits 2 for [$a] (got $CODE)"
    grep -q '^usage: gh-ci' "$T/stderr.txt" || fail "usage without repo lookup for [$a]"
  done
) || exit 1

# --- cases: failures prints a cleaned digest of the failed and cancelled jobs ---
run_failures() {
  OUT="$(bash "$GHCI" failures "$@" 2>"$T/stderr.txt")"; CODE=$?
}
set_runs() { printf '%s' "$1" >"$T/state/runs.json"; }
set_jobs() { printf '%s' "$2" >"$T/state/jobs-$1.json"; }
make_rust_log() { # 100 ANSI/timestamp/prefixed lines with Rust failures inside
  local jid="$1" i msg
  {
    for i in $(seq 1 100); do
      case "$i" in
        90) msg="test foo::bar ... FAILED";;
        95) msg="error[E0308]: mismatched types";;
        *) msg="line $i content";;
      esac
      printf 'myjob\tmystep\t2026-10-07T12:00:%02dZ \033[31m%s\033[0m\n' "$((i % 60))" "$msg"
    done
  } >"$T/state/log-$jid.txt"
}
ESC_BYTES="$(printf '\033')"

# a 100-line coloured, timestamped, prefixed log digests to its last 60
# cleaned lines, Rust failure lines included
reset_state
set_jobs 123 '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}'
make_rust_log 111
run_failures 123
[ "$CODE" = "0" ] || fail "failures digest exits 0 (got $CODE): [$OUT]"
grep -q "=== wf-123 / build (111): failure" <<<"$OUT" || fail "failure header: [$OUT]"
grep -q "test foo::bar ... FAILED" <<<"$OUT" || fail "Rust FAILED line in digest"
grep -q "error\[E0308\]: mismatched types" <<<"$OUT" || fail "Rust error line in digest"
LINES="$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
[ "$LINES" = "61" ] || fail "header plus exactly 60 lines (got $LINES)"
grep -q "$ESC_BYTES" <<<"$OUT" && fail "no escape bytes in digest"
grep -q "2026-10-07" <<<"$OUT" && fail "no timestamps in digest"
grep -q "myjob" <<<"$OUT" && fail "no job/step prefix in digest"
grep -q "line 41 content" <<<"$OUT" || fail "keeps the last 60 (line 41 present)"
grep -q "line 40 content" <<<"$OUT" && fail "drops lines before the last 60"

# --pr with one failed and one passed run on the head: only the failed run
reset_state
set_heads "$A"
set_runs '[{"databaseId":11,"name":"ci","conclusion":"failure"},{"databaseId":22,"name":"lint","conclusion":"success"}]'
set_jobs 11 '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}'
set_jobs 22 '{"jobs":[{"databaseId":222,"name":"ok-job","conclusion":"success"}]}'
make_rust_log 111
run_failures --pr 7
[ "$CODE" = "0" ] || fail "--pr digest exits 0 (got $CODE): [$OUT]"
grep -q "=== ci / build (111): failure" <<<"$OUT" || fail "--pr failed run header: [$OUT]"
grep -q "ok-job" <<<"$OUT" && fail "passed run jobs never appear: [$OUT]"
grep -q "lint" <<<"$OUT" && fail "passed run name never appears: [$OUT]"
grep -q "superseded" <<<"$OUT" && fail "nothing superseded, no note line: [$OUT]"
grep -q -- "run list .*--limit 100" "$T/state/gh-args.txt" || fail "--pr lists runs with --limit 100: [$(cat "$T/state/gh-args.txt")]"

# gh prints ESC as the literal text ^[ ; those colour codes are stripped too
reset_state
set_jobs 123 '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}'
{
  printf 'myjob\tmystep\t2026-10-07T12:00:01Z ^[[32;1m        PASS^[[0m ok\n'
  printf 'myjob\tmystep\t2026-10-07T12:00:02Z ^[[31;1m        FAIL^[[0m [   8.5s] jobs a_test\n'
} >"$T/state/log-111.txt"
run_failures 123
[ "$CODE" = "0" ] || fail "literal-escape digest exits 0 (got $CODE): [$OUT]"
grep -qF '^[[' <<<"$OUT" && fail "no literal ^[[ codes in digest: [$OUT]"
grep -q "$ESC_BYTES" <<<"$OUT" && fail "no escape bytes in literal-escape digest"
grep -q "FAIL" <<<"$OUT" || fail "literal-escape digest keeps FAIL: [$OUT]"
grep -q "a_test" <<<"$OUT" || fail "literal-escape digest keeps a_test: [$OUT]"

# --pr ignores a superseded run: cancelled run 1 replaced by a successful
# run 2 of the same workflow reports no failed jobs
reset_state
set_heads "$A"
set_runs '[{"databaseId":1,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"cancelled"},{"databaseId":2,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"success"}]'
set_jobs 2 '{"jobs":[{"databaseId":222,"name":"ok-job","conclusion":"success"}]}'
run_failures --pr 7
[ "$CODE" = "0" ] || fail "superseded cancel exits 0 (got $CODE): [$OUT]"
grep -q "no failed jobs on ${A:0:8}" <<<"$OUT" || fail "superseded cancel line: [$OUT]"
grep -qx "skipped 1 superseded runs: 1" <<<"$OUT" || fail "superseded cancel names run 1: [$OUT]"
grep -q -- "run list .*databaseId,name,event,conclusion,workflowName" "$T/state/gh-args.txt" \
  || fail "run list asks for event,workflowName: [$(cat "$T/state/gh-args.txt")]"

# --pr names every superseded failed or cancelled run, after the digest; a
# superseded success is not named
reset_state
set_heads "$A"
set_runs '[{"databaseId":37925057416,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"cancelled"},{"databaseId":37925058210,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"failure"},{"databaseId":37925059000,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"success"},{"databaseId":40000000001,"name":"Lint","workflowName":"Lint","event":"pull_request","conclusion":"success"},{"databaseId":40000000002,"name":"Lint","workflowName":"Lint","event":"pull_request","conclusion":"failure"}]'
set_jobs 37925059000 '{"jobs":[{"databaseId":222,"name":"ok-job","conclusion":"success"}]}'
set_jobs 40000000002 '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}'
make_rust_log 111
run_failures --pr 7
[ "$CODE" = "0" ] || fail "two superseded exits 0 (got $CODE): [$OUT]"
grep -q "=== Lint / build (111): failure" <<<"$OUT" || fail "kept failed run digest: [$OUT]"
grep -q "superseded runs: " <<<"$OUT" || fail "note after the digest: [$OUT]"
[ "$(tail -n 1 <<<"$OUT")" = "skipped 2 superseded runs: 37925057416 37925058210" ] \
  || fail "note names the cancelled and failed superseded runs in order: [$OUT]"
grep -q "40000000001" <<<"$OUT" && fail "superseded success is not named: [$OUT]"
grep -q "37925059000" <<<"$OUT" && fail "kept run is not named as superseded: [$OUT]"

# superseded runs that all succeeded name nothing
reset_state
set_heads "$A"
set_runs '[{"databaseId":1,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"success"},{"databaseId":2,"name":"CI","workflowName":"CI","event":"pull_request","conclusion":"success"}]'
set_jobs 2 '{"jobs":[{"databaseId":222,"name":"ok-job","conclusion":"success"}]}'
run_failures --pr 7
[ "$CODE" = "0" ] || fail "superseded successes exit 0 (got $CODE): [$OUT]"
grep -q "superseded" <<<"$OUT" && fail "superseded successes name no run: [$OUT]"

# --pr still reports a cancelled run of another workflow
reset_state
set_heads "$A"
set_runs '[{"databaseId":1,"name":"A","workflowName":"A","event":"pull_request","conclusion":"cancelled"},{"databaseId":2,"name":"B","workflowName":"B","event":"pull_request","conclusion":"success"}]'
set_jobs 1 '{"jobs":[{"databaseId":111,"name":"old-job","conclusion":"cancelled"}]}'
set_jobs 2 '{"jobs":[{"databaseId":222,"name":"ok-job","conclusion":"success"}]}'
run_failures --pr 7
[ "$CODE" = "0" ] || fail "other-workflow cancel exits 0 (got $CODE): [$OUT]"
grep -q "=== A / old-job: cancelled" <<<"$OUT" || fail "other-workflow cancelled line: [$OUT]"

# a cancelled job prints one line and triggers no log call
reset_state
set_jobs 123 '{"jobs":[{"databaseId":222,"name":"flaky","conclusion":"cancelled"},{"databaseId":111,"name":"build","conclusion":"failure"}]}'
make_rust_log 111
run_failures 123
[ "$CODE" = "0" ] || fail "cancelled digest exits 0 (got $CODE): [$OUT]"
grep -q "=== wf-123 / flaky: cancelled" <<<"$OUT" || fail "cancelled line: [$OUT]"
grep -q -- "--job 222" "$T/state/gh-args.txt" && fail "no log call for cancelled jobs"
grep -q -- "--job 111" "$T/state/gh-args.txt" || fail "log call for failed jobs"

# nothing failed: names the run, or the PR head short SHA, and exits 0
reset_state
set_jobs 123 '{"jobs":[{"databaseId":111,"name":"build","conclusion":"success"}]}'
run_failures 123
[ "$CODE" = "0" ] || fail "no failures exits 0 (got $CODE): [$OUT]"
grep -q "no failed jobs" <<<"$OUT" || fail "no-failures line: [$OUT]"
grep -q "123" <<<"$OUT" || fail "no-failures names the run: [$OUT]"
reset_state
set_heads "$A"
set_runs '[]'
run_failures --pr 7
[ "$CODE" = "0" ] || fail "--pr no failures exits 0 (got $CODE): [$OUT]"
grep -q "no failed jobs" <<<"$OUT" || fail "--pr no-failures line: [$OUT]"
grep -q "${A:0:8}" <<<"$OUT" || fail "--pr no-failures names the short SHA: [$OUT]"

# GH_CI_LOG_LINES=5 keeps 5 lines
reset_state
set_jobs 123 '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}'
make_rust_log 111
OUT="$(GH_CI_LOG_LINES=5 bash "$GHCI" failures 123 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "0" ] || fail "log-lines=5 exits 0 (got $CODE): [$OUT]"
LINES="$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
[ "$LINES" = "6" ] || fail "5 lines kept (got $LINES)"

# A panic above the tail keeps its assertion context alongside the same tail.
reset_state
set_jobs 123 '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}'
{
  echo "thread 'prune::young_fork' panicked at src/prune.rs:42:5:"
  echo 'assertion `left == right` failed'
  echo '  left: 1'
  echo ' right: 2'
  for i in $(seq 1 10); do echo "retry summary $i"; done
} >"$T/state/log-111.txt"
OUT="$(GH_CI_LOG_LINES=5 bash "$GHCI" failures 123 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "0" ] || fail "panic context exits 0 (got $CODE): [$OUT]"
grep -q '^panic context (outside the last 5 lines):$' <<<"$OUT" || fail "panic context heading: [$OUT]"
grep -q "thread 'prune::young_fork' panicked at" <<<"$OUT" || fail "panic line outside the tail: [$OUT]"
grep -q '^assertion `left == right` failed$' <<<"$OUT" || fail "assertion outside the tail: [$OUT]"
grep -q '^  left: 1$' <<<"$OUT" || fail "left value outside the tail: [$OUT]"
grep -q '^ right: 2$' <<<"$OUT" || fail "right value outside the tail: [$OUT]"
grep -q '^retry summary 6$' <<<"$OUT" || fail "keeps the last five lines: [$OUT]"
grep -q '^retry summary 5$' <<<"$OUT" && fail "drops lines before the last five: [$OUT]"

# panics reads stdin and emits only excerpts missing from the supplied tail.
PANIC_OUT="$(printf '%s\n' \
  'thread prune::young_fork panicked at src/prune.rs:42:5:' \
  'assertion failed' '  left: 1' ' right: 2' \
  'retry summary 1' 'retry summary 2' 'retry summary 3' 'retry summary 4' 'retry summary 5' \
  | env -u GH_CI_REPO GH_CI_LOG_LINES=5 bash "$GHCI" panics 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "0" ] || fail "panics stdin command exits 0 (got $CODE): [$PANIC_OUT]"
grep -q '^panic context (outside the last 5 lines):$' <<<"$PANIC_OUT" || fail "panics heading: [$PANIC_OUT]"
grep -q '^thread prune::young_fork panicked at src/prune.rs:42:5:$' <<<"$PANIC_OUT" || fail "panics prints its marker: [$PANIC_OUT]"
grep -q '^  left: 1$' <<<"$PANIC_OUT" && grep -q '^ right: 2$' <<<"$PANIC_OUT" || fail "panics prints assertion values: [$PANIC_OUT]"
PANIC_OUT="$(printf '%s\n' 'thread prune::young_fork panicked at src/prune.rs:42:5:' 'assertion failed' '  left: 1' ' right: 2' 'retry summary' \
  | bash "$GHCI" panics 5 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "0" ] && [ -z "$PANIC_OUT" ] || fail "panics omits excerpts already in the tail: [$PANIC_OUT] (exit $CODE)"
PANIC_OUT="$(printf '%s\n' \
  'thread prune::young_fork panicked at src/prune.rs:42:5:' 'assertion failed' '  left: 1' ' right: 2' \
  'separator' \
  'thread prune::young_fork panicked at src/prune.rs:42:5:' 'assertion failed' '  left: 1' ' right: 2' 'tail' \
  | bash "$GHCI" panics 5 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "0" ] || fail "duplicate panic text exits 0 (got $CODE): [$PANIC_OUT]"
grep -q '^panic context (outside the last 5 lines):$' <<<"$PANIC_OUT" || fail "panic line index controls tail suppression: [$PANIC_OUT]"
grep -q '^thread prune::young_fork panicked at src/prune.rs:42:5:$' <<<"$PANIC_OUT" \
  || fail "identical text in the tail does not suppress the earlier panic: [$PANIC_OUT]"

# a failed "red commit" job whose ticket has lost its bug label: the hint
# names the ticket and the run, and says to rerun the whole run
reset_state
set_jobs 123 '{"jobs":[{"databaseId":111,"name":"Bug fix fails at the red commit","conclusion":"failure"}]}'
printf 'myjob\tmystep\t2026-10-07T12:00:01Z FAIL red\n' >"$T/state/log-111.txt"
printf 'select\tcheck\t2026-10-07T12:00:00Z ticket: 77; bug: true\n' >"$T/state/runlog-123.txt"
printf '%s\n' test-only >"$T/state/issue-77-labels.txt"
run_failures 123
[ "$CODE" = "0" ] || fail "red-commit hint exits 0 (got $CODE): [$OUT]"
grep -qx "ticket #77 no longer has the bug label: rerun the whole run (gh run rerun 123, not --failed) or push" <<<"$OUT" \
  || fail "red-commit hint names #77 and run 123: [$OUT]"

# the same failure with the bug label still on the ticket: no hint
reset_state
set_jobs 123 '{"jobs":[{"databaseId":111,"name":"Bug fix fails at the red commit","conclusion":"failure"}]}'
printf 'myjob\tmystep\t2026-10-07T12:00:01Z FAIL red\n' >"$T/state/log-111.txt"
printf 'select\tcheck\t2026-10-07T12:00:00Z ticket: 77; bug: true\n' >"$T/state/runlog-123.txt"
printf '%s\n' bug test-only >"$T/state/issue-77-labels.txt"
run_failures 123
[ "$CODE" = "0" ] || fail "red-commit with bug exits 0 (got $CODE): [$OUT]"
grep -q "no longer has the bug label" <<<"$OUT" && fail "bug still labelled: no hint: [$OUT]"

# a failed job with another name never looks the ticket up
reset_state
set_jobs 123 '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}'
printf 'myjob\tmystep\t2026-10-07T12:00:01Z FAIL build\n' >"$T/state/log-111.txt"
printf 'select\tcheck\t2026-10-07T12:00:00Z ticket: 77; bug: true\n' >"$T/state/runlog-123.txt"
printf '%s\n' test-only >"$T/state/issue-77-labels.txt"
run_failures 123
[ "$CODE" = "0" ] || fail "other job exits 0 (got $CODE): [$OUT]"
grep -q "no longer has the bug label" <<<"$OUT" && fail "other job name: no hint: [$OUT]"
grep -q "gh issue" "$T/state/gh-args.txt" && fail "other job name: issue never looked up: [$(cat "$T/state/gh-args.txt")]"

# failures usage errors exit 2
reset_state
run_failures; [ "$CODE" = "2" ] || fail "failures with no argument exits 2 (got $CODE)"
run_failures --pr; [ "$CODE" = "2" ] || fail "failures --pr with no number exits 2 (got $CODE)"
run_failures --pr abc; [ "$CODE" = "2" ] || fail "failures --pr abc exits 2 (got $CODE)"
reset_state
run_failures abc; [ "$CODE" = "2" ] || fail "failures abc exits 2 (got $CODE)"
[ ! -s "$T/state/gh-args.txt" ] || fail "failures abc makes no gh call: [$(cat "$T/state/gh-args.txt")]"

# a run id whose jobs cannot be read hints at --pr, exit 1
reset_state
: >"$T/state/jobs-fail"
run_failures 2136; [ "$CODE" = "1" ] || fail "failures 2136 with unreadable jobs exits 1 (got $CODE)"
grep -q 'gh-ci failures --pr 2136' "$T/stderr.txt" || fail "unreadable run hints at --pr: [$(cat "$T/stderr.txt")]"

# --- cases: --repo. From a non-git cwd with no GH_CI_REPO, the flag alone
# --- names the repo (leading position here), and it never asks gh for the
# --- checkout's origin
reset_state
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pass","name":"ci"}]'
OUT="$(cd "$(mktemp -d)" && env -u GH_CI_REPO bash "$GHCI" --repo O/N wait 7 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "0" ] || fail "--repo from a non-git cwd waits to pass (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
grep -q 'gh api repos/O/N/pulls/7 --jq' "$T/state/gh-args.txt" || fail "--repo names the repo for the REST reads"
! grep -q 'repo view' "$T/state/gh-args.txt" || fail "--repo skips gh repo view"

# --- case: --repo overrides GH_CI_REPO and the origin (trailing position)
(
  gh() { echo "gh $*" >>"$T/state/repo-args.txt"; exit 1; }
  export -f gh
  rm -f "$T/state/repo-args.txt"
  GH_CI_REPO=O/N bash "$GHCI" snapshot 7 --repo P/Q >/dev/null 2>&1 || true
  grep -q 'repos/P/Q/pulls/7' "$T/state/repo-args.txt" || fail "--repo beats GH_CI_REPO: [$(cat "$T/state/repo-args.txt")]"
  ! grep -q 'O/N' "$T/state/repo-args.txt" || fail "GH_CI_REPO unused when --repo is set"
  ! grep -q 'repo view' "$T/state/repo-args.txt" || fail "--repo skips the origin lookup"
) || exit 1

# --- case: no --repo, no GH_CI_REPO, no checkout: exit 2 with one line naming --repo
(
  gh() ( exit 1 )
  export -f gh
  cd "$(mktemp -d)" || exit 1
  OUT="$(env -u GH_CI_REPO bash "$GHCI" snapshot 7 2>"$T/stderr.txt")"; CODE=$?
  [ "$CODE" = "2" ] || fail "no repo from anywhere exits 2 (got $CODE)"
  [ "$(wc -l <"$T/stderr.txt" | tr -d ' ')" = "1" ] || fail "no repo prints one line: [$(cat "$T/stderr.txt")]"
  grep -q -- '--repo' "$T/stderr.txt" || fail "no repo message names --repo: [$(cat "$T/stderr.txt")]"
) || exit 1

# --- case: --repo without a value, or not OWNER/NAME, is a usage error
reset_state
OUT="$(bash "$GHCI" snapshot 7 --repo 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "--repo with no value exits 2 (got $CODE)"
OUT="$(bash "$GHCI" snapshot 7 --repo nameonly 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "--repo not OWNER/NAME exits 2 (got $CODE)"
[ ! -s "$T/state/gh-args.txt" ] || fail "bad --repo makes no gh call"

# --- cases: origin's GitHub URL names the repo with no gh repo view call.
# --- Each form reaches the REST read for O/N, and gh is never asked to view.
for url in git@github.com:O/N.git git@github.com:O/N ssh://git@github.com/O/N.git \
  ssh://git@github.com/O/N https://github.com/O/N.git https://github.com/O/N; do
  (
    gh() { echo "gh $*" >>"$T/state/origin-args.txt"; exit 1; }
    export -f gh
    cd "$(mktemp -d)" || exit 1
    git init -q . && git remote add origin "$url"
    rm -f "$T/state/origin-args.txt"
    env -u GH_CI_REPO bash "$GHCI" snapshot 7 >/dev/null 2>&1 || true
    grep -q 'repos/O/N/pulls/7' "$T/state/origin-args.txt" || fail "origin $url names O/N: [$(cat "$T/state/origin-args.txt" 2>/dev/null)]"
    ! grep -q 'repo view' "$T/state/origin-args.txt" || fail "origin $url skips gh repo view"
  ) || exit 1
done

# --- case: no origin, gh repo view fails: exit 2 with its last stderr line appended
(
  gh() { if [ "$1" = repo ]; then echo boom >&2; exit 1; fi; exit 1; }
  export -f gh
  cd "$(mktemp -d)" || exit 1
  git init -q .
  env -u GH_CI_REPO bash "$GHCI" snapshot 7 >/dev/null 2>"$T/stderr.txt"; CODE=$?
  [ "$CODE" = "2" ] || fail "no origin and failing gh repo view exits 2 (got $CODE)"
  grep -q 'no repo' "$T/stderr.txt" || fail "no origin names the no repo error: [$(cat "$T/stderr.txt")]"
  grep -q 'boom' "$T/stderr.txt" || fail "no origin keeps gh's stderr: [$(cat "$T/stderr.txt")]"
) || exit 1

# --- case: under Claude Code a short --timeout is ignored, not raised
reset_state
export GH_CI_INTERVAL=3600
export CLAUDECODE=1
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pending","name":"ci"}]'
run_wait 7 --timeout 300
unset CLAUDECODE
export GH_CI_INTERVAL=7
[ "$CODE" = "124" ] || fail "Claude Code short timeout exits 124 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} timeout after 7200s" <<<"$OUT" || fail "Claude Code short timeout uses 7200: [$OUT]"
grep -q "gh-ci: --timeout 300 ignored under Claude Code (waits run in the background); using 7200" "$T/stderr.txt" \
  || fail "Claude Code ignore line: [$(cat "$T/stderr.txt")]"
[ "$(cat "$T/state/sleeps.txt")" = "3600
3600" ] || fail "ignored timeout sleeps twice with 3600: [$(cat "$T/state/sleeps.txt")]"

# --- case: under Claude Code --timeout 600 passes through unchanged
reset_state
export GH_CI_INTERVAL=600
export CLAUDECODE=1
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pending","name":"ci"}]'
run_wait 7 --timeout 600
unset CLAUDECODE
export GH_CI_INTERVAL=7
[ "$CODE" = "124" ] || fail "Claude Code 600 timeout exits 124 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} timeout after 600s" <<<"$OUT" || fail "600 timeout header unchanged: [$OUT]"
! grep -q "ignored under Claude Code" "$T/stderr.txt" || fail "no ignore line at 600: [$(cat "$T/stderr.txt")]"
[ "$(cat "$T/state/sleeps.txt")" = "600" ] || fail "600 timeout sleeps once: [$(cat "$T/state/sleeps.txt")]"

# --- case: under Claude Code --timeout above 600 passes through unchanged
reset_state
export GH_CI_INTERVAL=900
export CLAUDECODE=1
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pending","name":"ci"}]'
run_wait 7 --timeout 900
unset CLAUDECODE
export GH_CI_INTERVAL=7
[ "$CODE" = "124" ] || fail "Claude Code 900 timeout exits 124 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} timeout after 900s" <<<"$OUT" || fail "900 timeout header unchanged: [$OUT]"
! grep -q "ignored under Claude Code" "$T/stderr.txt" || fail "no ignore line at 900: [$(cat "$T/stderr.txt")]"

# --- case: without CLAUDECODE a short --timeout is unchanged
reset_state
export GH_CI_INTERVAL=300
set_heads "$A"; echo "$RULES_CI" >"$T/state/rules"
set_checks '[{"bucket":"pending","name":"ci"}]'
run_wait 7 --timeout 300
export GH_CI_INTERVAL=7
[ "$CODE" = "124" ] || fail "plain short timeout exits 124 (got $CODE): [$OUT]"
grep -q "head: ${A:0:8} timeout after 300s" <<<"$OUT" || fail "plain short timeout header unchanged: [$OUT]"
! grep -q "ignored under Claude Code" "$T/stderr.txt" || fail "no ignore line without CLAUDECODE: [$(cat "$T/stderr.txt")]"
[ "$(cat "$T/state/sleeps.txt")" = "300" ] || fail "plain short timeout sleeps once: [$(cat "$T/state/sleeps.txt")]"

# --- #490: failures names the failed budget rows under the job ---
reset_state
set_jobs 123 '{"jobs":[{"databaseId":111,"name":"Benchmarks","conclusion":"failure"}]}'
{
  printf 'job\tstep\t2026-10-07T12:00:01Z bench-report: paging_open_ms median 15.2 ms over 12 ms budget (base 10 ms)\n'
  printf 'job\tstep\t2026-10-07T12:00:02Z bench-report: paging_width_ms median 9.1 ms over 8 ms budget (base 7 ms)\n'
  printf 'job\tstep\t2026-10-07T12:00:03Z some other failure line\n'
} >"$T/state/log-111.txt"
run_failures 123
[ "$CODE" = "0" ] || fail "budget rows exits 0 (got $CODE): [$OUT]"
grep -qx "budget: paging_open_ms 15.2 ms > 12 ms" <<<"$OUT" || fail "paging_open_ms named: [$OUT]"
grep -qx "budget: paging_width_ms 9.1 ms > 8 ms" <<<"$OUT" || fail "paging_width_ms named: [$OUT]"
# a failed log with no budget lines prints no budget block
reset_state
set_jobs 123 '{"jobs":[{"databaseId":111,"name":"build","conclusion":"failure"}]}'
make_rust_log 111
run_failures 123
[ "$CODE" = "0" ] || fail "no-budget digest exits 0 (got $CODE): [$OUT]"
grep -q "^budget:" <<<"$OUT" && fail "no budget block without budget lines: [$OUT]"

echo "gh-ci: all cases passed"

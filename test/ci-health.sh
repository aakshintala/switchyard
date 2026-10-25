#!/usr/bin/env bash
# Tests for bin/ci-health, using a stand-in gh serving fixture files
# (no network). Fake gh maps the api path to test/fixtures/ci-health,
# logs its args, and fails paths listed in $T/fail-<key>.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HEALTH="$SCRIPT_DIR/../bin/ci-health"
FIX="$SCRIPT_DIR/fixtures/ci-health"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-ci-health.XXXXXX")"
export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export CI_HEALTH_NOW="2026-10-09T18:30:00Z"

# --- fake gh ---
cat >"$T/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
# args: gh api [--allow-escape-sequences] <path>
echo "gh $*" >>"$FAKE_GH_LOG"
path=""
for a in "$@"; do
  case "$a" in
    api|--allow-escape-sequences) continue;;
    -*) continue;;
    *) path="$a";;
  esac
done
[ -n "$path" ] || { echo "fake gh: no path" >&2; exit 2; }
scen="$FAKE_SCEN"
serve() { # serve <file>: cat it, or fail when the fail flag is set
  local f="$1" key="$2"
  if [ -e "$T/fail-$key" ]; then
    cat "$T/fail-$key" >&2
    exit 1
  fi
  if [ -e "$scen/$f" ]; then cat "$scen/$f"; return 0; fi
  if [ -e "$FAKE_BASE/$f" ]; then cat "$FAKE_BASE/$f"; return 0; fi
  echo "fake gh: no fixture $f for $path" >&2
  exit 2
}
case "$path" in
  *actions/runs\?branch=main*)
    serve main-runs.json main;;
  *actions/runs\?created=*)
    case "$path" in *page=1*) serve runs.json runs;; *) printf '{"workflow_runs":[]}';; esac;;
  *actions/runs/*/jobs*)
    rid="$(printf '%s' "$path" | sed -E 's/.*runs\/([0-9]+).*/\1/')"
    f="jobs-$rid.json"
    if [ -e "$T/fail-jobs-$rid" ]; then cat "$T/fail-jobs-$rid" >&2; exit 1; fi
    if [ -e "$scen/$f" ]; then cat "$scen/$f";
    elif [ -e "$FAKE_BASE/$f" ]; then cat "$FAKE_BASE/$f";
    else printf '{"total_count":0,"jobs":[]}'; fi;;
  *actions/jobs/*/logs)
    jid="$(printf '%s' "$path" | sed -E 's/.*jobs\/([0-9]+).*/\1/')"
    if [ -e "$T/fail-log-$jid" ]; then cat "$T/fail-log-$jid" >&2; exit 1; fi
    serve "logs/$jid.txt" "log-$jid";;
  *check-runs/*/annotations*)
    jid="$(printf '%s' "$path" | sed -E 's/.*check-runs\/([0-9]+).*/\1/')"
    serve "annotations-$jid.json" "ann-$jid";;
  *actions/caches\?*)
    case "$path" in *page=2*) serve caches-2.json caches2;; *) serve caches-1.json caches1;; esac;;
  *commits/main)
    serve head.json head;;
  *commits\?sha=main*)
    serve target.json target;;
  *compare/*)
    base="$(printf '%s' "$path" | sed -E 's/.*compare\/([^.]+).*/\1/')"
    f="compare-${base:0:8}.json"
    if [ -e "$scen/$f" ]; then cat "$scen/$f"; else serve compare.json compare; fi;;
  *) echo "fake gh: unknown path $path" >&2; exit 2;;
esac
FAKEGH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
export FAKE_BASE="$FIX/_base"

export HOME="$T/home"
export TMPDIR="$T/tmp"
mkdir -p "$HOME" "$TMPDIR"

OUT=""; CODE=0
setup() { # setup <scenario>: fresh HOME, scenario fixtures
  export FAKE_SCEN="$FIX/$1"
  export FAKE_GH_LOG="$T/gh-args-$1.txt"
  : >"$FAKE_GH_LOG"
  rm -rf "$HOME" "$TMPDIR" "$T"/fail-*
  mkdir -p "$HOME" "$TMPDIR"
}
run_health() {
  OUT="$(python3 "$HEALTH" --repo O/N "$@" 2>"$T/stderr.txt")"; CODE=$?
}
expect() { # expect <code> <grep>: exit code and output pattern
  [ "$CODE" = "$1" ] || fail "exit $1 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
  grep -q "$2" <<<"$OUT" || fail "output matches [$2]: [$OUT]"
}
jget() { # jget <python-expr>: eval OUT as JSON (OUT must be --json output)
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print('"$1"')' "$OUT"
}

# --- calm: exit 0, one-line summary ---
setup calm
run_health
expect 0 "^ci-health O/N: OK"
grep -q "pr p90" <<<"$OUT" || fail "summary queue part: [$OUT]"
grep -q "saturated 0m" <<<"$OUT" || fail "summary saturation part: [$OUT]"
grep -q "cache 8.00 GB" <<<"$OUT" || fail "summary cache part: [$OUT]"

# --- calm --json: field presence and values ---
setup calm
run_health --json
[ "$CODE" = "0" ] || fail "calm json exits 0 (got $CODE): [$OUT]"
[ "$(jget "d['pr_queue']['Selection']['n']")" = "2" ] || fail "Selection n=2: [$OUT]"
[ "$(jget "d['pr_queue']['Tests linux-x64']['n']")" = "1" ] || fail "Tests n=1: [$OUT]"
[ "$(jget "d['pr_queue'].get('Mutants', 'absent')")" = "absent" ] || fail "Mutants excluded: [$OUT]"
[ "$(jget "d['main_queue']")" = "{}" ] || fail "main_queue empty: [$OUT]"
[ "$(jget "d['saturated_minutes']")" = "0" ] || fail "saturated 0"
[ "$(jget "d['macos_capped_minutes']")" = "0" ] || fail "macos capped 0"
[ "$(jget "d['backstop']['commits_behind']")" = "0" ] || fail "behind 0: [$OUT]"
[ "$(jget "d['backstop']['red_streak']")" = "0" ] || fail "red streak 0"
[ "$(jget "d['backstop']['red_causes']")" = "[]" ] || fail "red causes []"
[ "$(jget "d['timeouts']")" = "[]" ] || fail "no timeouts"
[ "$(jget "d['design_failures']")" = "[]" ] || fail "no design failures"
[ "$(jget "d['cache_bytes']")" = "8000000000" ] || fail "cache bytes"
[ "$(jget "d['breaches']")" = "[]" ] || fail "no breaches"
[ "$(jget "d['partial']")" = "False" ] || fail "not partial"
[ "$(jget "d['window']")" = "{'start': '2026-10-09T17:15:00Z', 'end': '2026-10-09T18:30:00Z'}" ] \
  || fail "window: [$OUT]"
[ "$(jget "d['backstop']['head_sha']")" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ] || fail "head sha"

# --- queue-p90 breach, and the flag moves it out ---
setup q90
run_health
expect 1 "BREACH queue-p90"
setup q90
run_health --queue-p90 99
expect 0 "^ci-health O/N: OK"

# --- queue-max: a 17.2m Selection and a still-queued Tests job breach;
# --- a terminal job that never started is excluded ---
setup qmax
run_health
[ "$CODE" = "1" ] || fail "qmax exits 1 (got $CODE): [$OUT]"
grep -q "BREACH queue-max" <<<"$OUT" || fail "qmax line: [$OUT]"
setup qmax
run_health --json
grep -q "Selection queued 17.2 min (job 21)" <<<"$OUT" || fail "queue-max detail: [$OUT]"
grep -q "job 22" <<<"$OUT" || fail "still-queued job breaches: [$OUT]"
setup qmax
run_health --json
[ "$(jget "sorted(d['pr_queue'].keys())")" = "['Selection', 'Tests linux-x64']" ] \
  || fail "terminal-unstarted job excluded: [$OUT]"
setup qmax
run_health --queue-max 99
[ "$CODE" = "1" ] || fail "queue-p90 still breaches at --queue-max 99 (got $CODE): [$OUT]"
grep -q "queue-p90" <<<"$OUT" || fail "only queue-p90 left: [$OUT]"

# --- saturation: flags move the breach in and out ---
setup sat
run_health --sat-jobs 2 --sat-min 2
expect 1 "BREACH saturation"
setup sat
run_health
expect 0 "^ci-health O/N: OK"

# --- design: timeout (20.0m cancelled Tests linux-arm, limit 20, annotation
# --- says the time limit was exceeded) ---
setup timeout
run_health
expect 1 "BREACH design"
setup timeout
run_health --json
[ "$CODE" = "1" ] || fail "timeout json exits 1 (got $CODE)"
[ "$(jget "len(d['timeouts'])")" = "1" ] || fail "one timeout: [$OUT]"
[ "$(jget "d['timeouts'][0]['minutes']")" = "20.0" ] || fail "timeout minutes: [$OUT]"
[ "$(jget "d['design_failures'][0]['kind']")" = "timeout" ] || fail "design kind: [$OUT]"

# --- concurrency cancel: a 20.0m cancelled arm job whose annotation says a
# --- higher priority request cancelled it is no breach; nor is a 15m Release
# --- cancel (limit 30, where the stale 15 counted it as a timeout) ---
setup concur
run_health --json
[ "$CODE" = "0" ] || fail "concurrency cancel exits 0 (got $CODE): [$OUT]"
[ "$(jget "d['timeouts']")" = "[]" ] || fail "no timeouts on concurrency cancel: [$OUT]"
[ "$(jget "d['design_failures']")" = "[]" ] || fail "no design failures: [$OUT]"
grep -q "check-runs/41/annotations" "$FAKE_GH_LOG" || fail "arm annotations fetched: [$(cat "$FAKE_GH_LOG")]"
grep -q "check-runs/51/annotations" "$FAKE_GH_LOG" || fail "Release 15m read for its annotations: [$(cat "$FAKE_GH_LOG")]"

# --- below the bound: a 14.8m cancelled arm job (limit 20) whose annotation
# --- says the time limit was exceeded is still a timeout ---
setup early
run_health --json
[ "$CODE" = "1" ] || fail "below-bound time-limit annotation exits 1 (got $CODE): [$OUT]"
[ "$(jget "len(d['timeouts'])")" = "1" ] || fail "below-bound timeout: [$OUT]"
[ "$(jget "d['timeouts'][0]['minutes']")" = "14.8" ] || fail "below-bound minutes: [$OUT]"

# --- annotation fetch fails: the duration rule decides, so the 20.0m arm
# --- cancel is still a timeout breach, reported as partial ---
setup timeout
echo "HTTP 503 annotations" >"$T/fail-ann-41"
run_health --json
[ "$CODE" = "1" ] || fail "annotation fetch failure falls back to duration (got $CODE): [$OUT]"
[ "$(jget "len(d['timeouts'])")" = "1" ] || fail "fallback timeout: [$OUT]"
[ "$(jget "d['partial']")" = "True" ] || fail "fetch failure reported as partial: [$OUT]"

# --- design: bench comment failure ---
setup bench
run_health --json
expect 1 "bench-comment"
[ "$(jget "d['design_failures'][0]['kind']")" = "bench-comment" ] || fail "bench kind: [$OUT]"

# --- design: release exit 127 ---
setup rel127
run_health --json
expect 1 "release-exit-127"
[ "$(jget "d['design_failures'][0]['kind']")" = "release-exit-127" ] || fail "release kind: [$OUT]"

# --- design: exit 127 persists on a warm state (evidence cached, not raw text) ---
setup rel127
run_health --json
[ "$CODE" = "1" ] || fail "first run exits 1 (got $CODE): [$OUT]"
run_health --json
expect 1 "release-exit-127"
[ "$(grep -c 'actions/jobs/43/logs' "$FAKE_GH_LOG")" = "1" ] \
  || fail "release log fetched once across runs: [$(cat "$FAKE_GH_LOG")]"
python3 -c "import json; d=json.load(open('$HOME/.cache/switchyard/ci-health.json')); assert all('text' not in v for v in d.get('logcache', {}).values() if isinstance(v, dict)), d.get('logcache')" \
  || fail "no raw log text cached"

# --- backstop: an unfinished core job skips the run (neither green nor red) ---
setup unfinished
run_health --json
[ "$CODE" = "0" ] || fail "unfinished exits 0 (got $CODE): [$OUT]"
[ "$(jget "d['backstop']['red_streak']")" = "0" ] || fail "no red streak: [$OUT]"
[ "$(jget "d['backstop']['last_core_green_sha']")" = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ] \
  || fail "green at the older run: [$OUT]"
grep -q '"check": "backstop"' <<<"$OUT" && fail "covered backstop stays quiet: [$OUT]"

# --- cache breach, and the flag moves it out ---
setup cache
run_health
expect 1 "BREACH cache"
setup cache
run_health --cache-max 11
expect 0 "^ci-health O/N: OK"

# --- cache: listing summed across two pages; stale usage endpoint ignored ---
setup cache-pages
run_health --json
[ "$(jget "d['cache_bytes']")" = "7750000000" ] || fail "cache bytes summed across pages: [$OUT]"
[ "$(jget "d['cache_count']")" = "102" ] || fail "cache count across pages: [$OUT]"
grep -q "actions/caches?per_page=100&page=2" "$FAKE_GH_LOG" || fail "second page fetched: [$(cat "$FAKE_GH_LOG")]"
grep -q "actions/cache/usage" "$FAKE_GH_LOG" && fail "usage endpoint not called"
grep -q '"check": "cache"' <<<"$OUT" && fail "7.75 GB is under 9.5: [$OUT]"

# --- backstop: uncovered target breaches ---
setup bs-breach
run_health
expect 1 "BREACH backstop"
setup bs-breach
run_health --json
[ "$(jget "d['backstop']['commits_behind']")" = "5" ] || fail "behind 5: [$OUT]"
grep -q '"check": "backstop"' <<<"$OUT" || fail "backstop check: [$OUT]"
grep -q 'backstop-broken' <<<"$OUT" && fail "no broken breach: [$OUT]"

# --- backstop: no green known breaches, nulls reported ---
setup bs-nogreen
run_health
expect 1 "BREACH backstop"
setup bs-nogreen
run_health --json
[ "$(jget "d['backstop']['last_core_green_sha']")" = "None" ] || fail "green null: [$OUT]"
[ "$(jget "d['backstop']['last_core_green_at']")" = "None" ] || fail "green at null: [$OUT]"
[ "$(jget "d['backstop']['red_streak']")" = "2" ] || fail "red streak 2: [$OUT]"

# --- backstop-broken: two reds, same compile error ---
setup broken-same
run_health
expect 1 "BREACH backstop-broken"
setup broken-same
run_health --json
[ "$(jget "d['backstop']['red_streak']")" = "2" ] || fail "streak 2: [$OUT]"
[ "$(jget "d['backstop']['red_causes']")" = "['compile tui: error[E0277]: mismatched types']" ] \
  || fail "red causes: [$OUT]"
grep -q '"check": "backstop"' <<<"$OUT" && fail "covered backstop stays quiet: [$OUT]"

# --- same jobs, different tests: red but not broken ---
setup broken-diff
run_health
expect 0 "^ci-health O/N: OK"
setup broken-diff
run_health --json
[ "$(jget "d['backstop']['red_streak']")" = "2" ] || fail "streak 2: [$OUT]"
[ "$(jget "d['backstop']['red_causes']")" = "['test fiber-core doors::open', 'test fiber-core doors::watch']" ] \
  || fail "red causes: [$OUT]"

# --- backstop-broken: two reds, same bench-report budget (medians differ) ---
setup budget-same
run_health
expect 1 "BREACH backstop-broken"
setup budget-same
run_health --json
[ "$(jget "d['backstop']['red_causes']")" = "['budget Terminal, idle over 9048 KiB']" ] \
  || fail "budget red causes: [$OUT]"

# --- same jobs, different budgets: red but not broken ---
setup budget-diff
run_health
expect 0 "^ci-health O/N: OK"
grep -q 'backstop-broken' <<<"$OUT" && fail "different budgets not broken: [$OUT]"
setup budget-diff
run_health --json
[ "$(jget "d['backstop']['red_streak']")" = "2" ] || fail "budget-diff streak 2: [$OUT]"

# --- state: second run fetches no jobs; corrupt state warns and runs ---
setup calm
run_health
[ "$CODE" = "0" ] || fail "first run exits 0 (got $CODE)"
[ -e "$HOME/.cache/switchyard/ci-health.json" ] || fail "state written under HOME"
python3 -c "import json; d=json.load(open('$HOME/.cache/switchyard/ci-health.json')); assert d['last_core_green_sha'], d; assert '101' in d['runs'], d.keys()" \
  || fail "state holds check time, job cache and last green"
run_health
[ "$CODE" = "0" ] || fail "second run exits 0 (got $CODE)"
[ "$(grep -c 'actions/runs/101/jobs' "$FAKE_GH_LOG")" = "1" ] \
  || fail "jobs fetched once across runs: [$(cat "$FAKE_GH_LOG")]"
echo "not json" >"$HOME/.cache/switchyard/ci-health.json"
run_health
expect 0 "^ci-health O/N: OK"
grep -qi "state unreadable" "$T/stderr.txt" || fail "corrupt state warning: [$(cat "$T/stderr.txt")]"

# --- exits: 2 on bad flag, missing repo, runs failure ---
OUT="$(python3 "$HEALTH" --repo O/N --bogus 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "bad flag exits 2 (got $CODE)"
OUT="$(python3 "$HEALTH" --window 5 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "missing repo exits 2 (got $CODE)"
OUT="$(python3 "$HEALTH" --repo 'not a repo' 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "bad repo exits 2 (got $CODE)"
OUT="$(python3 "$HEALTH" --repo O/N --window 5x 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "bad window exits 2 (got $CODE)"
OUT="$(python3 "$HEALTH" --repo O/N --sat-jobs 0 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "bad sat-jobs exits 2 (got $CODE)"
setup calm
echo "HTTP 401 Unauthorized" >"$T/fail-runs"
run_health
[ "$CODE" = "2" ] || fail "runs 401 exits 2 (got $CODE): [$OUT]"

# --- exits: 3 on partial without breach; 1 wins over 3 ---
setup calm
echo "HTTP 500 boom" >"$T/fail-jobs-101"
run_health --json
[ "$CODE" = "3" ] || fail "one jobs failure exits 3 (got $CODE): [$OUT]"
[ "$(jget "d['partial']")" = "True" ] || fail "partial true: [$OUT]"
setup bs-breach
echo "HTTP 500 boom" >"$T/fail-jobs-101"
run_health
[ "$CODE" = "1" ] || fail "breach beats partial (got $CODE): [$OUT]"

# --- cache: an in-progress snapshot is refetched when updated_at is unchanged ---
# GitHub keeps a run's updated_at while its jobs finish, so a cache hit needs a
# completed run; otherwise the backstop reuses a null conclusion and breaches.
setup calm
SCENA="$T/scen-a"; SCENB="$T/scen-b"; mkdir -p "$SCENA" "$SCENB"
printf '{"workflow_runs":[]}' >"$SCENA/runs.json"
printf '{"workflow_runs":[]}' >"$SCENB/runs.json"
printf '{"sha":"cccccccccccccccccccccccccccccccccccccccc"}' >"$SCENA/head.json"
printf '{"sha":"cccccccccccccccccccccccccccccccccccccccc"}' >"$SCENB/head.json"
printf '[{"sha":"cccccccccccccccccccccccccccccccccccccccc"}]' >"$SCENA/target.json"
printf '[{"sha":"cccccccccccccccccccccccccccccccccccccccc"}]' >"$SCENB/target.json"
printf '{"status":"ahead","ahead_by":0}' >"$SCENA/compare.json"
printf '{"status":"ahead","ahead_by":0}' >"$SCENB/compare.json"
cat >"$SCENA/main-runs.json" <<'EOF'
{"workflow_runs": [{"id": 1001, "event": "push", "conclusion": null, "status": "in_progress", "pull_requests": [], "head_branch": "main", "head_sha": "cccccccccccccccccccccccccccccccccccccccc", "path": ".github/workflows/ci.yml", "created_at": "2026-10-09T18:00:00Z", "updated_at": "2026-10-09T18:00:00Z", "run_attempt": 1}]}
EOF
cat >"$SCENB/main-runs.json" <<'EOF'
{"workflow_runs": [{"id": 1001, "event": "push", "conclusion": "success", "status": "completed", "pull_requests": [], "head_branch": "main", "head_sha": "cccccccccccccccccccccccccccccccccccccccc", "path": ".github/workflows/ci.yml", "created_at": "2026-10-09T18:00:00Z", "updated_at": "2026-10-09T18:00:00Z", "run_attempt": 1}]}
EOF
cat >"$SCENA/jobs-1001.json" <<'EOF'
{"total_count": 6, "jobs": [{"id": 3000, "run_id": 1001, "name": "Selection", "labels": ["ubuntu-24.04"], "runner_name": "GitHub Actions 1", "status": "completed", "conclusion": "success", "created_at": "2026-10-09T18:00:00Z", "started_at": "2026-10-09T18:00:00Z", "completed_at": "2026-10-09T18:00:30Z", "steps": []}, {"id": 3001, "run_id": 1001, "name": "Linux x86_64 checks", "labels": ["ubuntu-24.04"], "runner_name": "GitHub Actions 1", "status": "completed", "conclusion": "success", "created_at": "2026-10-09T18:00:00Z", "started_at": "2026-10-09T18:00:00Z", "completed_at": "2026-10-09T18:05:00Z", "steps": []}, {"id": 3002, "run_id": 1001, "name": "Tests (ubuntu-24.04)", "labels": ["ubuntu-24.04"], "runner_name": "GitHub Actions 1", "status": "completed", "conclusion": "success", "created_at": "2026-10-09T18:00:00Z", "started_at": "2026-10-09T18:00:00Z", "completed_at": "2026-10-09T18:05:00Z", "steps": []}, {"id": 3003, "run_id": 1001, "name": "Tests (ubuntu-24.04-arm)", "labels": ["ubuntu-24.04-arm"], "runner_name": "GitHub Actions 1", "status": "completed", "conclusion": "success", "created_at": "2026-10-09T18:00:00Z", "started_at": "2026-10-09T18:00:00Z", "completed_at": "2026-10-09T18:05:00Z", "steps": []}, {"id": 3004, "run_id": 1001, "name": "Tests (macos-26)", "labels": ["macos-26"], "runner_name": "GitHub Actions 1", "status": "in_progress", "conclusion": null, "created_at": "2026-10-09T18:00:00Z", "started_at": "2026-10-09T18:00:00Z", "completed_at": null, "steps": []}, {"id": 3005, "run_id": 1001, "name": "Release build and size (Linux x86_64)", "labels": ["ubuntu-24.04"], "runner_name": "GitHub Actions 1", "status": "completed", "conclusion": "success", "created_at": "2026-10-09T18:00:00Z", "started_at": "2026-10-09T18:00:00Z", "completed_at": "2026-10-09T18:05:00Z", "steps": []}]}
EOF
cat >"$SCENB/jobs-1001.json" <<'EOF'
{"total_count": 6, "jobs": [{"id": 3000, "run_id": 1001, "name": "Selection", "labels": ["ubuntu-24.04"], "runner_name": "GitHub Actions 1", "status": "completed", "conclusion": "success", "created_at": "2026-10-09T18:00:00Z", "started_at": "2026-10-09T18:00:00Z", "completed_at": "2026-10-09T18:00:30Z", "steps": []}, {"id": 3001, "run_id": 1001, "name": "Linux x86_64 checks", "labels": ["ubuntu-24.04"], "runner_name": "GitHub Actions 1", "status": "completed", "conclusion": "success", "created_at": "2026-10-09T18:00:00Z", "started_at": "2026-10-09T18:00:00Z", "completed_at": "2026-10-09T18:05:00Z", "steps": []}, {"id": 3002, "run_id": 1001, "name": "Tests (ubuntu-24.04)", "labels": ["ubuntu-24.04"], "runner_name": "GitHub Actions 1", "status": "completed", "conclusion": "success", "created_at": "2026-10-09T18:00:00Z", "started_at": "2026-10-09T18:00:00Z", "completed_at": "2026-10-09T18:05:00Z", "steps": []}, {"id": 3003, "run_id": 1001, "name": "Tests (ubuntu-24.04-arm)", "labels": ["ubuntu-24.04-arm"], "runner_name": "GitHub Actions 1", "status": "completed", "conclusion": "success", "created_at": "2026-10-09T18:00:00Z", "started_at": "2026-10-09T18:00:00Z", "completed_at": "2026-10-09T18:05:00Z", "steps": []}, {"id": 3004, "run_id": 1001, "name": "Tests (macos-26)", "labels": ["macos-26"], "runner_name": "GitHub Actions 1", "status": "completed", "conclusion": "success", "created_at": "2026-10-09T18:00:00Z", "started_at": "2026-10-09T18:00:00Z", "completed_at": "2026-10-09T18:05:00Z", "steps": []}, {"id": 3005, "run_id": 1001, "name": "Release build and size (Linux x86_64)", "labels": ["ubuntu-24.04"], "runner_name": "GitHub Actions 1", "status": "completed", "conclusion": "success", "created_at": "2026-10-09T18:00:00Z", "started_at": "2026-10-09T18:00:00Z", "completed_at": "2026-10-09T18:05:00Z", "steps": []}]}
EOF
export FAKE_SCEN="$SCENA"
run_health --json
[ "$CODE" = "1" ] || fail "in-progress run breaches (got $CODE): [$OUT]"
grep -q '"check": "backstop"' <<<"$OUT" || fail "in-progress backstop breach: [$OUT]"
export FAKE_SCEN="$SCENB"
run_health --json
[ "$CODE" = "0" ] || fail "completed run with same updated_at exits 0 (got $CODE): [$OUT]"
[ "$(jget "d['backstop']['last_core_green_sha']")" = "cccccccccccccccccccccccccccccccccccccccc" ] || fail "green at 1001: [$OUT]"
grep -q '"check": "backstop"' <<<"$OUT" && fail "completed backstop stays quiet: [$OUT]"
[ "$(grep -c 'actions/runs/1001/jobs' "$FAKE_GH_LOG")" = "2" ] || fail "in-progress run refetched: [$(cat "$FAKE_GH_LOG")]"
run_health --json
[ "$CODE" = "0" ] || fail "completed rerun exits 0 (got $CODE): [$OUT]"
[ "$(grep -c 'actions/runs/1001/jobs' "$FAKE_GH_LOG")" = "2" ] || fail "completed run reused: [$(cat "$FAKE_GH_LOG")]"

echo "ci-health: all cases passed"

#!/usr/bin/env bash
# Tests for bin/ci-friction, using a stand-in gh serving fixture files
# (no network). Fake gh maps the api path to test/fixtures/ci-friction,
# logs its args, and fails paths with a $T/fail-<key> flag file.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRICTION="$SCRIPT_DIR/../bin/ci-friction"
FIX="$SCRIPT_DIR/fixtures/ci-friction"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-ci-friction.XXXXXX")"
export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export CI_FRICTION_NOW="2026-10-09T18:30:00Z"
export CI_FRICTION_RETRY_SLEEP=0

# --- fake gh ---
cat >"$T/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
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
serve() { # serve <file> <key>: cat it, or fail when flagged
  local f="$1" key="$2"
  if [ -e "$T/fail-$key" ]; then
    cat "$T/fail-$key" >&2
    exit 1
  fi
  if [ -e "$scen/$f" ]; then cat "$scen/$f"; return 0; fi
  echo "fake gh: no fixture $f for $path" >&2
  exit 2
}
if [[ "$*" == *graphql* ]]; then
  n="$(printf '%s' "$*" | sed -nE 's/.*issue\(number:([0-9]+)\).*/\1/p')"
  if [ -e "$T/fail-graphql-$n" ] || [ -e "$scen/graphql/$n.json" ]; then
    serve "graphql/$n.json" "graphql-$n"
  else
    printf '{"data":{"repository":{"issue":{"timelineItems":{"nodes":[]}}}}}'
  fi
  exit 0
fi
case "$path" in
  *actions/runs\?created=*)
    if [ -e "$T/fail-runs" ]; then cat "$T/fail-runs" >&2; exit 1; fi
    case "$path" in *page=1*) cat "$scen/runs.json";; *) printf '{"workflow_runs":[]}';; esac;;
  *actions/runs/*/jobs*)
    rid="$(printf '%s' "$path" | sed -E 's/.*runs\/([0-9]+).*/\1/')"
    page="$(printf '%s' "$path" | sed -nE 's/.*[?&]page=([0-9]+).*/\1/p')"
    [ -n "$page" ] || page=1
    if [ -e "$T/fail-jobs-$rid" ]; then cat "$T/fail-jobs-$rid" >&2; exit 1; fi
    if [ -e "$T/once-jobs-$rid" ]; then rm -f "$T/once-jobs-$rid"; echo "HTTP 502: Bad Gateway" >&2; exit 1; fi
    if [ -e "$scen/jobs-$rid-p$page.json" ]; then cat "$scen/jobs-$rid-p$page.json";
    elif [ "$page" = "1" ] && [ -e "$scen/jobs-$rid.json" ]; then cat "$scen/jobs-$rid.json";
    else printf '{"total_count":0,"jobs":[]}'; fi;;
  *actions/jobs/*/logs)
    jid="$(printf '%s' "$path" | sed -E 's/.*jobs\/([0-9]+).*/\1/')"
    if [ -e "$T/fail-log-$jid" ]; then cat "$T/fail-log-$jid" >&2; exit 1; fi
    serve "logs/$jid.txt" "log-$jid";;
  search/issues*)
    q="$(printf '%s' "$path" | sed -E 's/.*"([^"]+)"[^"]*$/\1/')"
    if [ -e "$T/fail-flaky" ] && [[ "$path" == *Flaky* ]]; then cat "$T/fail-flaky" >&2; exit 1; fi
    if [ -e "$T/once-ratelimit" ]; then rm -f "$T/once-ratelimit"; echo "gh: API rate limit exceeded for user ID 1. If you reach out to GitHub Support for help, please include your request ID. (HTTP 403)" >&2; exit 1; fi
    key="$(printf '%s' "$q" | sed -E 's/[^A-Za-z0-9]+/-/g')"
    spage="$(printf '%s' "$path" | sed -nE 's/.*[?&]page=([0-9]+).*/\1/p')"
    [ -n "$spage" ] || spage=1
    f="search/$key.json"
    [ "$spage" = "1" ] || f="search/$key-p$spage.json"  # page 2+ has its own fixture, else empty
    if [ -e "$scen/$f" ]; then cat "$scen/$f"; else printf '{"total_count":0,"items":[]}'; fi;;
  *issues/*/events*)
    n="$(printf '%s' "$path" | sed -E 's/.*issues\/([0-9]+).*/\1/')"
    page="$(printf '%s' "$path" | sed -nE 's/.*[?&]page=([0-9]+).*/\1/p')"
    [ -n "$page" ] || page=1
    if [ -e "$T/fail-events-$n" ]; then cat "$T/fail-events-$n" >&2; exit 1; fi
    if [ -e "$scen/events/$n-p$page.json" ]; then cat "$scen/events/$n-p$page.json";
    elif [ "$page" = "1" ] && [ -e "$scen/events/$n.json" ]; then cat "$scen/events/$n.json";
    else printf '[]'; fi;;
  *repos/*/issues\?*)
    if [ -e "$scen/blocked.json" ]; then cat "$scen/blocked.json"; else printf '[]'; fi;;
  *repos/*/issues/*/comments*)
    n="$(printf '%s' "$path" | sed -E 's/.*issues\/([0-9]+).*/\1/')"
    page="$(printf '%s' "$path" | sed -nE 's/.*[?&]page=([0-9]+).*/\1/p')"
    [ -n "$page" ] || page=1
    if [ "$page" = "1" ] && [ -e "$scen/comments-$n.json" ]; then cat "$scen/comments-$n.json";
    else printf '[]'; fi;;
  *repos/*/issues/*)
    # the --repo fixtures are issues/<n>.json; other repos are issues/<owner>-<name>-<n>.json
    set -- $(printf '%s' "$path" | sed -E 's/.*repos\/([^/]+)\/([^/]+)\/issues\/([0-9]+).*/\1 \2 \3/')
    if [ "$1/$2" = "O/N" ]; then serve "issues/$3.json" "issues-$3"
    else serve "issues/$1-$2-$3.json" "issues-$1-$2-$3"; fi;;
  *pulls\?*)
    br="$(printf '%s' "$path" | sed -E 's/.*head=[^:]+:([^&]+).*/\1/')"
    key="$(printf '%s' "$br" | sed -E 's/[^A-Za-z0-9]+/-/g')"
    f="pulls-$key.json"
    if [ -e "$scen/$f" ]; then cat "$scen/$f"; else printf '[]'; fi;;
  *compare/*)
    pair="$(printf '%s' "$path" | sed -E 's/.*compare\/([^.]+)\.\.\.(.+)/\1 \2/')"
    set -- $pair
    serve "compare-${1:0:8}-${2:0:8}.json" "compare-$1-$2";;
  rate_limit) printf '{"resources":{"search":{"reset":0}}}';;
  *) echo "fake gh: unknown path $path" >&2; exit 2;;
esac
FAKEGH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

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
run_friction() {
  OUT="$(python3 "$FRICTION" --repo O/N "$@" 2>"$T/stderr.txt")"; CODE=$?
}
flake_scen() { # flake_scen <scenario>: writable copy of a fixture scenario for overlays
  TSCEN="$T/scen-$1"; rm -rf "$TSCEN"; cp -r "$FIX/$1" "$TSCEN"
  mkdir -p "$TSCEN/search"
  export FAKE_SCEN="$TSCEN"
}
jget() {
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print('"$1"')' "$OUT"
}

# --- classifier: every class from one log fixture each ---
setup classes
run_friction --min-lanes 1 --json
[ "$CODE" = "1" ] || fail "classes exits 1 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
[ "$(jget "sorted(r['test'] for r in d['repeats'])")" = \
  "['compile fiber-core: error[E0308]: mismatched types', 'compile tui: error[E0277]: the trait bound is not satisfied', 'fiber-core base::works', 'fiber-core doors::watch']" ] \
  || fail "repeat tests: [$OUT]"
[ "$(jget "sorted(c['cause'] for c in d['design'])")" = \
  "['bench-artifact-missing', 'bench-budget', 'bug-red', 'ci-script-missing-at-base', 'fmt', 'infra', 'mutant-timeout', 'mutants-baseline', 'size-budget']" ] \
  || fail "design causes: [$OUT]"
[ "$(jget "d['design'][0]['count']")" = "1" ] || fail "design counts per job: [$OUT]"
[ "$(jget "d['design'][0]['lanes']")" = "['#1401']" ] || fail "design lanes: [$OUT]"
# the duplicated FAIL line counts once: one search for the name
[ "$(grep -c 'search/issues.*doors' "$FAKE_GH_LOG")" = "1" ] \
  || fail "one search per test name: [$(cat "$FAKE_GH_LOG")]"
# recurrence after a closed issue
[ "$(jget "len(d['recurred_after_close'])")" = "1" ] || fail "one recurrence: [$OUT]"
[ "$(jget "d['recurred_after_close'][0]['issue']")" = "1465" ] || fail "recur issue: [$OUT]"
[ "$(jget "d['recurred_after_close'][0]['lanes']")" = "['#1401', 'main']" ] || fail "recur lanes: [$OUT]"
# excluded classes never appear anywhere
grep -q "missed-mutant" <<<"$OUT" && fail "missed-mutant excluded: [$OUT]"
grep -q '"cause": "other"' <<<"$OUT" && fail "other excluded: [$OUT]"
grep -q '"cause": "compile"' <<<"$OUT" && fail "compile excluded from design: [$OUT]"

# --- grouping: same test in a PR lane and main is a repeat ---
setup repeat
run_friction
[ "$CODE" = "1" ] || fail "repeat exits 1 (got $CODE): [$OUT]"
grep -q "^repeat: fiber-core doors::watch lanes #1385,main os linux-x64,macOS issue #1386 open$" <<<"$OUT" \
  || fail "summary line: [$OUT]"
setup repeat
run_friction --json
[ "$(jget "d['repeats'][0]['lanes']")" = "['#1385', 'main']" ] || fail "repeat lanes: [$OUT]"
[ "$(jget "d['repeats'][0]['os']")" = "['linux-x64', 'macOS']" ] || fail "repeat os: [$OUT]"
[ "$(jget "d['repeats'][0]['issue']")" = "1386" ] || fail "repeat issue: [$OUT]"
[ "$(jget "d['repeats'][0]['issue_state']")" = "open" ] || fail "issue state: [$OUT]"
[ "$(jget "d['recurred_after_close']")" = "[]" ] || fail "open issue never recurs: [$OUT]"

# --- compile keys: one error in two type-path spellings is one repeat ---
setup compilepath
run_friction --json
[ "$CODE" = "1" ] || fail "compile spellings exit 1 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
[ "$(jget "len(d['repeats'])")" = "1" ] || fail "compile spellings: one repeat: [$OUT]"
[ "$(jget "d['repeats'][0]['lanes']")" = "['#1401', 'main']" ] || fail "compile spellings lanes: [$OUT]"
[ "$(jget "d['repeats'][0]['test']")" = "compile fiber-core: error[E0277]: a value of type Vec<Vec<(String, Option<Spot>, Ink)>> cannot be built from an iterator" ] \
  || fail "compile spellings key: [$OUT]"

# --- upgrade: a compile job cached under the old qualified key is reclassified ---
setup compilepath
mkdir -p "$HOME/.cache/switchyard"
python3 -c "import json; json.dump({'jobs': {'901': {'class': 'compile', 'detail': 'fiber-core: old', 'tests': ['compile fiber-core: error[E0277]: a value of type Vec<Vec<(std::string::String, Option<swapped::Spot>, Ink)>> cannot be built from an iterator'], 'lane': '#1401', 'os': 'linux-x64', 'completed_at': '2026-10-09T17:40:00Z', 'head_sha': 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'}}, 'issues': {}, 'branches': {}}, open('$HOME/.cache/switchyard/ci-friction.json', 'w'))"
run_friction --json
[ "$CODE" = "1" ] || fail "upgrade exits 1 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
[ "$(jget "len(d['repeats'])")" = "1" ] || fail "upgrade: one repeat: [$OUT]"
[ "$(jget "d['repeats'][0]['lanes']")" = "['#1401', 'main']" ] || fail "upgrade lanes: [$OUT]"

# --- 279: a run rerun to green still yields its failed attempt-1 job; attempt-1 success is skipped ---
setup rerun
run_friction --json
[ "$CODE" = "1" ] || fail "rerun exits 1 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
[ "$(jget "[(r['test'], r['lanes']) for r in d['repeats']]")" = "[('fiber-core doors::watch', ['#1385', 'main'])]" ] \
  || fail "rerun repeat from attempt 1: [$OUT]"
[ "$(grep -c 'actions/runs/611/jobs?filter=all' "$FAKE_GH_LOG")" = "1" ] \
  || fail "rerun jobs listed with filter=all: [$(cat "$FAKE_GH_LOG")]"
grep -q 'actions/runs/613/jobs' "$FAKE_GH_LOG" && fail "attempt-1 success run not fetched: [$(cat "$FAKE_GH_LOG")]"
[ "$(grep -c 'actions/jobs/811/logs' "$FAKE_GH_LOG")" = "1" ] || fail "rerun failed job logged once: [$(cat "$FAKE_GH_LOG")]"

# --- one lane twice: not a repeat at 2, a repeat at 1 ---# --- one lane twice: not a repeat at 2, a repeat at 1 ---
setup onelane
run_friction
[ "$CODE" = "0" ] || fail "one lane exits 0 (got $CODE): [$OUT]"
grep -q "no repeats" <<<"$OUT" || fail "quiet line: [$OUT]"
setup onelane
run_friction --min-lanes 1
[ "$CODE" = "1" ] || fail "min-lanes 1 exits 1 (got $CODE): [$OUT]"

# --- lanes from the branch lookup and the branch-name fallback ---
setup lanes
run_friction --json
[ "$CODE" = "1" ] || fail "lanes exits 1 (got $CODE): [$OUT]"
[ "$(jget "d['repeats'][0]['lanes']")" = "['#1402', 'sched/nightly']" ] \
  || fail "lookup and fallback lanes: [$OUT]"
grep -c 'pulls?state=all' "$FAKE_GH_LOG" | grep -q "^2$" \
  || fail "one lookup per branch: [$(cat "$FAKE_GH_LOG")]"

# --- logs and searches fetched once; open issues re-read ---
setup repeat
run_friction --json >/dev/null
run_friction --json >/dev/null
[ "$(grep -c 'actions/jobs/801/logs' "$FAKE_GH_LOG")" = "1" ] \
  || fail "log fetched once: [$(cat "$FAKE_GH_LOG")]"
[ "$(grep -c 'search/issues.*doors' "$FAKE_GH_LOG")" = "1" ] \
  || fail "search once per name: [$(cat "$FAKE_GH_LOG")]"
[ "$(grep -c 'issues/1386' "$FAKE_GH_LOG")" = "1" ] \
  || fail "cached open issue re-read: [$(cat "$FAKE_GH_LOG")]"
[ "$(grep -c 'actions/runs/601/jobs' "$FAKE_GH_LOG")" = "2" ] \
  || fail "runs re-listed each invocation: [$(cat "$FAKE_GH_LOG")]"

# --- --since pruning drops old state entries ---
setup repeat
mkdir -p "$HOME/.cache/switchyard"
python3 -c "import json; json.dump({'jobs': {'999': {'class': 'test-fail', 'detail': 'x', 'tests': ['old crate'], 'lane': '#1', 'os': 'linux-x64', 'completed_at': '2026-10-01T00:00:00Z'}}, 'issues': {}, 'branches': {}}, open('$HOME/.cache/switchyard/ci-friction.json', 'w'))"
run_friction --json >/dev/null
[ "$CODE" = "1" ] || fail "prune run exits 1 (got $CODE)"
python3 -c "import json; d=json.load(open('$HOME/.cache/switchyard/ci-friction.json')); assert '999' not in d['jobs'], d['jobs']" \
  || fail "old job pruned"
# corrupt state warns and still runs
echo "not json" >"$HOME/.cache/switchyard/ci-friction.json"
run_friction --json >/dev/null
grep -qi "state unreadable" "$T/stderr.txt" || fail "corrupt warning: [$(cat "$T/stderr.txt")]"

# --- no-log on 404: design cause, cached, exit 0 when alone ---
setup onelane
echo "HTTP 404 not found" >"$T/fail-log-811"
echo "HTTP 404 not found" >"$T/fail-log-812"
run_friction --json
[ "$CODE" = "0" ] || fail "no-log exits 0 (got $CODE): [$OUT]"
[ "$(jget "d['design']")" = "[{'cause': 'no-log', 'count': 2, 'lanes': ['#1405']}]" ] \
  || fail "no-log design: [$OUT]"

# --- #592: a cancelled job with no log (cancelled before start) is not no-log ---
setup onelane-cancel
echo "HTTP 404 not found" >"$T/fail-log-811"
echo "HTTP 404 not found" >"$T/fail-log-812"
run_friction --json
[ "$CODE" = "0" ] || fail "cancelled no-log exits 0 (got $CODE): [$OUT]"
[ "$(jget "d['design']")" = "[{'cause': 'no-log', 'count': 1, 'lanes': ['#1405']}]" ] \
  || fail "cancelled 404 job stays out of design: [$OUT]"

# --- 18f: SIGTERM/SIGKILL collateral never yields a test; panic lines do ---
setup signals
run_friction --min-lanes 1 --json
[ "$CODE" = "1" ] || fail "signals exits 1 (got $CODE): [$OUT]"
[ "$(jget "sorted(r['test'] for r in d['repeats'])")" = "['fiber-core base::works', 'fiber-core doors::boom']" ] \
  || fail "only FAIL and panic tests counted: [$OUT]"
grep -q "other::" <<<"$OUT" && fail "signal collateral excluded: [$OUT]"
[ "$(jget "d['design']")" = "[]" ] || fail "no design causes: [$OUT]"

# --- 18g: pre-fix sighting dropped, post-fix sighting kept (and recurs) ---
setup fixcommit
run_friction --min-lanes 1 --json
[ "$CODE" = "1" ] || fail "fixcommit exits 1 (got $CODE): [$OUT]"
[ "$(jget "[r['lanes'] for r in d['repeats']]")" = "[['#1502', 'main']]" ] \
  || fail "pre-fix lane dropped: [$OUT]"
[ "$(jget "d['recurred_after_close'][0]['issue']")" = "1470" ] || fail "recur issue: [$OUT]"
[ "$(jget "d['recurred_after_close'][0]['lanes']")" = "['#1502', 'main']" ] \
  || fail "recur lanes: [$OUT]"
setup fixcommit
run_friction --min-lanes 1 --json >/dev/null
run_friction --min-lanes 1 --json >/dev/null
[ "$(grep -c 'compare/ffffffff' "$FAKE_GH_LOG")" = "2" ] \
  || fail "one compare per pair, cached: [$(cat "$FAKE_GH_LOG")]"
[ "$(grep -c 'graphql' "$FAKE_GH_LOG")" = "1" ] \
  || fail "closer fetched once: [$(cat "$FAKE_GH_LOG")]"

# --- 224: no closer keeps every sighting on the closed_at fallback ---
setup nocloser
run_friction --min-lanes 1 --json
[ "$CODE" = "1" ] || fail "nocloser exits 1 (got $CODE): [$OUT]"
[ "$(jget "sorted(set(l for r in d['repeats'] for l in r['lanes']))")" = "['#1501', '#1502']" ] \
  || fail "no closer: pre-fix lane kept: [$OUT]"
grep -q "compare/" "$FAKE_GH_LOG" && fail "no closer: no compare: [$(cat "$FAKE_GH_LOG")]"

# --- 224: a null cached by an older version is looked up again ---
setup fixcommit
mkdir -p "$HOME/.cache/switchyard"
python3 -c "import json; json.dump({'jobs': {}, 'issues': {'fiber-core doors::watch': {'issue': 1470, 'issue_state': 'closed', 'closed_at': '2026-10-09T10:00:00Z', 'updated_at': '2026-10-09T10:00:00Z', 'fix_commit': None}}, 'branches': {}}, open('$HOME/.cache/switchyard/ci-friction.json', 'w'))"
run_friction --min-lanes 1 --json
[ "$(grep -c 'graphql' "$FAKE_GH_LOG")" = "1" ] || fail "stale null re-looked-up: [$(cat "$FAKE_GH_LOG")]"
[ "$(jget "[r['lanes'] for r in d['repeats']]")" = "[['#1502', 'main']]" ] \
  || fail "stale null recovered, pre-fix lane dropped: [$OUT]"

# --- 18g: post-fix sighting before closure is still a recurrence ---
setup fixlate
run_friction --json
[ "$CODE" = "1" ] || fail "fixlate exits 1 (got $CODE): [$OUT]"
[ "$(jget "[r['lanes'] for r in d['repeats']]")" = "[['#1502', 'main']]" ] || fail "post-fix lanes: [$OUT]"
[ "$(jget "d['recurred_after_close'][0]['issue']")" = "1471" ] || fail "recur issue: [$OUT]"
[ "$(jget "d['recurred_after_close'][0]['lanes']")" = "['#1502', 'main']" ] \
  || fail "recur lanes: [$OUT]"

# --- #320: one PR lane's failure after close is not a recurrence ---
setup pronly
run_friction --json
[ "$CODE" = "0" ] || fail "pronly exits 0 (got $CODE): [$OUT]"
[ "$(jget "[r['lanes'] for r in d['repeats']]")" = "[]" ] || fail "single lane is no repeat: [$OUT]"
[ "$(jget "d['recurred_after_close']")" = "[]" ] || fail "one PR lane after close is no recurrence: [$OUT]"

# --- jobs pagination: a failure on page 2 is still seen ---
setup paged
run_friction --min-lanes 1 --json
[ "$CODE" = "1" ] || fail "paged exits 1 (got $CODE): [$OUT]"
[ "$(jget "[r['test'] for r in d['repeats']]")" = "['fiber-core doors::far']" ] \
  || fail "page-2 failure seen: [$OUT]"
[ "$(grep -c 'actions/runs/601/jobs' "$FAKE_GH_LOG")" = "2" ] \
  || fail "full page plus the short one: [$(cat "$FAKE_GH_LOG")]"

# --- retries: a 502 on a jobs call is retried once, and a search rate limit waits then retries ---
setup repeat
: >"$T/once-jobs-601"
run_friction --json
[ "$CODE" = "1" ] || fail "502 then success exits 1 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
[ "$(grep -c 'actions/runs/601/jobs' "$FAKE_GH_LOG")" = "2" ] \
  || fail "502 retried once: [$(cat "$FAKE_GH_LOG")]"
[ "$(jget "d['repeats'][0]['test']")" = "fiber-core doors::watch" ] \
  || fail "502 retry keeps the repeat: [$OUT]"

setup repeat
: >"$T/once-ratelimit"
run_friction --json
[ "$CODE" = "1" ] || fail "rate limit then success exits 1 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
[ "$(grep -c 'search/issues.*doors' "$FAKE_GH_LOG")" = "2" ] \
  || fail "rate-limited search retried once: [$(cat "$FAKE_GH_LOG")]"
grep -q "rate_limit" "$FAKE_GH_LOG" || fail "rate limit reset read: [$(cat "$FAKE_GH_LOG")]"
[ "$(jget "d['repeats'][0]['issue']")" = "1386" ] || fail "rate-limited search linked: [$OUT]"

# --- stale no-issue cache: searched again once it is over 6 h old, and linked ---
setup repeat
mkdir -p "$HOME/.cache/switchyard"
python3 -c "import json; json.dump({'jobs': {}, 'issues': {'fiber-core doors::watch': {'issue': None, 'issue_state': None, 'closed_at': None, 'updated_at': None, 'searched_at': '2026-10-09T10:00:00Z'}}, 'branches': {}}, open('$HOME/.cache/switchyard/ci-friction.json', 'w'))"
run_friction --json
[ "$CODE" = "1" ] || fail "stale no-issue exits 1 (got $CODE): [$OUT]"
[ "$(grep -c 'search/issues.*doors' "$FAKE_GH_LOG")" = "1" ] || fail "stale no-issue searched: [$(cat "$FAKE_GH_LOG")]"
[ "$(jget "d['repeats'][0]['issue']")" = "1386" ] || fail "stale no-issue linked: [$OUT]"
# a no-issue entry searched under 6 h ago is not searched again
setup repeat
mkdir -p "$HOME/.cache/switchyard"
python3 -c "import json; json.dump({'jobs': {}, 'issues': {'fiber-core doors::watch': {'issue': None, 'issue_state': None, 'closed_at': None, 'updated_at': None, 'searched_at': '2026-10-09T17:00:00Z'}}, 'branches': {}}, open('$HOME/.cache/switchyard/ci-friction.json', 'w'))"
run_friction --json
[ "$(grep -c 'search/issues.*doors' "$FAKE_GH_LOG")" = "0" ] || fail "fresh no-issue not searched: [$(cat "$FAKE_GH_LOG")]"

# --- flaky: open "Flaky test:" issues; 2+ sightings exit 1 and print a line ---
# flaky: one uncached search; 1602 has 1 sighting, 1601 has 2, and the old and
# non-prefix titles are excluded
setup flaky
flake_scen flaky
cat >"$TSCEN/comments-1601.json" <<'EOF'
[{"id": 1, "user": {"login": "github-actions"}, "body": "The test `main::ci_flake_probe passes_only_on_a_retry` passed after a retry on ubuntu-24.04: https://github.com/O/N/actions/runs/9001.", "created_at": "2026-10-09T10:00:00Z"}, {"id": 2, "user": {"login": "github-actions"}, "body": "The test `main::ci_flake_probe passes_only_on_a_retry` passed after a retry on ubuntu-24.04: https://github.com/O/N/actions/runs/9003.", "created_at": "2026-10-09T11:00:00Z"}]
EOF
cat >"$TSCEN/comments-1602.json" <<'EOF'
[{"id": 3, "user": {"login": "github-actions"}, "body": "The test `fiber-core doors::slow` passed after a retry on ubuntu-24.04: https://github.com/O/N/actions/runs/9002.", "created_at": "2026-10-09T11:30:00Z"}]
EOF
run_friction --json
[ "$CODE" = "1" ] || fail "flaky 2+ exits 1 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
[ "$(jget "[(f['test'], f['issue'], f['sightings']) for f in d['flaky']]")" = \
  "[('fiber-core doors::slow', 1602, 1), ('main::ci_flake_probe passes_only_on_a_retry', 1601, 2)]" ] \
  || fail "flaky entries: [$OUT]"
[ "$(jget "[(f['issue'], f['runs']) for f in d['flaky']]")" = \
  "[(1602, ['https://github.com/O/N/actions/runs/9002']), (1601, ['https://github.com/O/N/actions/runs/9001', 'https://github.com/O/N/actions/runs/9003'])]" ] \
  || fail "flaky run urls: [$OUT]"
[ "$(grep -c 'Flaky' "$FAKE_GH_LOG")" = "1" ] || fail "one flaky search: [$(cat "$FAKE_GH_LOG")]"
[ "$(grep -c 'issues/1601/comments' "$FAKE_GH_LOG")" = "1" ] \
  || fail "one comments fetch per flaky issue: [$(cat "$FAKE_GH_LOG")]"
setup flaky
flake_scen flaky
cat >"$TSCEN/comments-1601.json" <<'EOF'
[{"id": 1, "user": {"login": "github-actions"}, "body": "The test `main::ci_flake_probe passes_only_on_a_retry` passed after a retry on ubuntu-24.04: https://github.com/O/N/actions/runs/9001.", "created_at": "2026-10-09T10:00:00Z"}, {"id": 2, "user": {"login": "github-actions"}, "body": "The test `main::ci_flake_probe passes_only_on_a_retry` passed after a retry on ubuntu-24.04: https://github.com/O/N/actions/runs/9003.", "created_at": "2026-10-09T11:00:00Z"}]
EOF
cat >"$TSCEN/comments-1602.json" <<'EOF'
[{"id": 3, "user": {"login": "github-actions"}, "body": "The test `fiber-core doors::slow` passed after a retry on ubuntu-24.04: https://github.com/O/N/actions/runs/9002.", "created_at": "2026-10-09T11:30:00Z"}]
EOF
run_friction
[ "$CODE" = "1" ] || fail "flaky text exits 1 (got $CODE): [$OUT]"
grep -qx "flaky: main::ci_flake_probe passes_only_on_a_retry issue #1601 sightings 2" <<<"$OUT" \
  || fail "flaky text line: [$OUT]"
grep -q "^flaky: fiber-core doors" <<<"$OUT" && fail "1-sighting flaky has no text line: [$OUT]"
grep -qx "  run: https://github.com/O/N/actions/runs/9001" <<<"$OUT" \
  || fail "flaky run url line: [$OUT]"
grep -q "no repeats" <<<"$OUT" && fail "a flaky finding is not quiet: [$OUT]"
# one sighting: listed in JSON, exit 0 when nothing else, no text line
setup flaky1
flake_scen flaky1
cat >"$TSCEN/comments-1602.json" <<'EOF'
[{"id": 3, "user": {"login": "github-actions"}, "body": "The test `fiber-core doors::slow` passed after a retry on ubuntu-24.04: https://github.com/O/N/actions/runs/9002.", "created_at": "2026-10-09T11:30:00Z"}]
EOF
run_friction --json
[ "$CODE" = "0" ] || fail "1-sighting flaky exits 0 (got $CODE): [$OUT]"
[ "$(jget "[(f['test'], f['sightings']) for f in d['flaky']]")" = "[('fiber-core doors::slow', 1)]" ] \
  || fail "1-sighting listed: [$OUT]"
setup flaky1
run_friction
[ "$CODE" = "0" ] || fail "1-sighting text exits 0 (got $CODE): [$OUT]"
grep -q "no repeats" <<<"$OUT" || fail "1-sighting quiet line: [$OUT]"
grep -q "^flaky:" <<<"$OUT" && fail "1-sighting no text line: [$OUT]"
# page 1 is full of old matches; the recent two-sighting issue on page 2 is listed
setup flakypage
flake_scen flakypage
cat >"$TSCEN/comments-1701.json" <<'EOF'
[{"id": 1, "user": {"login": "github-actions"}, "body": "The test `fiber-core late::one` passed after a retry on ubuntu-24.04: https://github.com/O/N/actions/runs/9101.", "created_at": "2026-10-09T12:00:00Z"}, {"id": 2, "user": {"login": "github-actions"}, "body": "The test `fiber-core late::one` passed after a retry on ubuntu-24.04: https://github.com/O/N/actions/runs/9102.", "created_at": "2026-10-09T13:00:00Z"}]
EOF
run_friction --json
[ "$CODE" = "1" ] || fail "flaky page 2 exits 1 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
[ "$(jget "[(f['test'], f['issue'], f['sightings']) for f in d['flaky']]")" = \
  "[('fiber-core late::one', 1701, 2)]" ] || fail "flaky page 2 listed: [$OUT]"
[ "$(grep -c 'Flaky' "$FAKE_GH_LOG")" = "2" ] || fail "two flaky pages: [$(cat "$FAKE_GH_LOG")]"
grep -q 'updated:>=2026-10-08T18:30:00Z' "$FAKE_GH_LOG" || fail "cutoff in query: [$(cat "$FAKE_GH_LOG")]"
# --- #344: sightings count only bot retry comments in the window ---
# 1650 has 1 bot sighting in window, 2 human triage comments (one quoting
# the retry phrase) and 1 bot sighting before the window: sightings 1, run printed.
setup flakyfilter
flake_scen onelane
cat >"$TSCEN/search/Flaky-test-.json" <<'EOF'
{"total_count": 1, "items": [{"number": 1650, "state": "open", "title": "Flaky test: fiber-core doors::slow", "updated_at": "2026-10-09T11:00:00Z", "comments": 99}]}
EOF
cat >"$TSCEN/comments-1650.json" <<'EOF'
[{"id": 1, "user": {"login": "github-actions"}, "body": "The test `fiber-core doors::slow` passed after a retry on ubuntu-24.04: https://github.com/O/N/actions/runs/9001.", "created_at": "2026-10-09T12:00:00Z"}, {"id": 2, "user": {"login": "alice"}, "body": "looking into this, seems related to #1600", "created_at": "2026-10-09T13:00:00Z"}, {"id": 3, "user": {"login": "bob"}, "body": "Quoting the bot (\"passed after a retry on ubuntu-24.04\")? same failure as https://github.com/O/N/actions/runs/9002?", "created_at": "2026-10-09T14:00:00Z"}, {"id": 4, "user": {"login": "github-actions"}, "body": "The test `fiber-core doors::slow` passed after a retry on ubuntu-24.04: https://github.com/O/N/actions/runs/8999.", "created_at": "2026-10-01T00:00:00Z"}]
EOF
run_friction --json
[ "$CODE" = "0" ] || fail "flakyfilter exits 0 (got $CODE): [$OUT]"
[ "$(jget "[(f['issue'], f['sightings'], f['runs']) for f in d['flaky']]")" = \
  "[(1650, 1, ['https://github.com/O/N/actions/runs/9001'])]" ] \
  || fail "only the in-window bot sighting counts: [$OUT]"
# the flaky search failing is exit 2
setup onelane
echo "HTTP 401 Unauthorized" >"$T/fail-flaky"
run_friction --json
[ "$CODE" = "2" ] || fail "flaky search failure exits 2 (got $CODE): [$OUT]"

# --- stale blocked: an open blocked issue whose named blockers are all closed ---
# cases: 501 Blocked by two closed; 502 waits for; 503 one open; 412 shape with
# an open owner-ruling ref and a cross-repo ref; 505 cross-repo closed while
# --repo's #206 is open; 506 names no blocker; 507 a lookup that fails; 508 a PR
setup stale
run_friction --json
[ "$CODE" = "1" ] || fail "stale exits 1 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
[ "$(jget "[(s['issue'], s['blockers']) for s in d['stale_blocked']]")" = \
  "[(501, ['#216', '#217']), (502, ['#218']), (505, ['aakshintala/switchyard#206'])]" ] \
  || fail "stale list: [$OUT]"
[ "$(jget "d['stale_blocked'][0]['title']")" = "Two closed blockers under Blocked by" ] \
  || fail "stale title: [$OUT]"
# a blocker named by several issues is looked up once; the cross-repo ref never
# touches --repo's own #206
[ "$(grep -c 'issues/216$' "$FAKE_GH_LOG")" = "1" ] || fail "blocker looked up once: [$(cat "$FAKE_GH_LOG")]"
[ "$(grep -c 'repos/O/N/issues/206$' "$FAKE_GH_LOG")" = "0" ] \
  || fail "cross-repo ref not resolved against --repo: [$(cat "$FAKE_GH_LOG")]"
[ "$(grep -c 'labels=blocked' "$FAKE_GH_LOG")" = "1" ] || fail "one blocked list: [$(cat "$FAKE_GH_LOG")]"
# a failed lookup is treated as open (not flagged) and warned about
grep -q "230" "$T/stderr.txt" || fail "failed lookup warned: [$(cat "$T/stderr.txt")]"
setup stale
run_friction
grep -qx "stale-blocked: issue #501, blockers #216, #217 all closed" <<<"$OUT" \
  || fail "stale text line: [$OUT]"
grep -Eq "issue #(503|412|506|507|508) " <<<"$OUT" && fail "unflagged issue in text: [$OUT]"
# none stale, other inputs clean: exit 0
setup stale-none
run_friction --json
[ "$CODE" = "0" ] || fail "no stale exits 0 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
[ "$(jget "d['stale_blocked']")" = "[]" ] || fail "no stale list: [$OUT]"
setup stale-none
run_friction
grep -q "no repeats" <<<"$OUT" || fail "no stale quiet line: [$OUT]"

# --- ATX headings: up to 3 leading spaces, closing hashes, indented next heading ends the section ---
# 601 indented "## Blocked by" opens; 602 "## Blocked by ##" opens; 603 an
# indented "  ## Notes" ends the section, so its open #219 is not counted
setup stale-indent
run_friction --json
[ "$CODE" = "1" ] || fail "stale-indent exits 1 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
[ "$(jget "[(s['issue'], s['blockers']) for s in d['stale_blocked']]")" = \
  "[(601, ['#216']), (602, ['#217']), (603, ['#218'])]" ] \
  || fail "ATX heading forms: [$OUT]"

# --- exits: 2 on usage and on listing failures, state still written ---
OUT="$(python3 "$FRICTION" --since 24h 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "missing repo exits 2 (got $CODE)"
OUT="$(python3 "$FRICTION" --repo O/N --min-lanes 0 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "min-lanes 0 exits 2 (got $CODE)"
OUT="$(python3 "$FRICTION" --repo O/N --since 5x 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "bad since exits 2 (got $CODE)"
setup repeat
echo "HTTP 401 Unauthorized" >"$T/fail-runs"
run_friction
[ "$CODE" = "2" ] || fail "runs 401 exits 2 (got $CODE): [$OUT]"
setup repeat
echo "HTTP 500 boom" >"$T/fail-jobs-601"
run_friction --json
[ "$CODE" = "2" ] || fail "jobs failure exits 2 (got $CODE): [$OUT]"
[ -e "$HOME/.cache/switchyard/ci-friction.json" ] || fail "state written before exit 2"
setup repeat
echo "HTTP 500 boom" >"$T/fail-log-801"
run_friction --json
[ "$CODE" = "2" ] || fail "log failure exits 2 (got $CODE): [$OUT]"

# --- #440: a superseded cancel is cancelled, not a timeout ---
# 731 runs 10 min of a 40 min Mutants bound with only the cancel line:
# cancelled, out of design[]. 732 runs 20 min, short of that bound: cancelled.
# 733 is short but names the maximum execution time: timeout.
setup timeout-cancel
TSCEN="$T/scen-timeout"; rm -rf "$TSCEN"; mkdir -p "$TSCEN/logs"
cat >"$TSCEN/runs.json" <<'EOF'
{"workflow_runs": [{"id": 730, "event": "pull_request", "conclusion": "cancelled", "status": "completed", "pull_requests": [{"number": 1405}], "head_branch": "feat/timeout", "head_sha": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "path": ".github/workflows/ci.yml", "created_at": "2026-10-09T17:20:00Z", "updated_at": "2026-10-09T17:20:00Z", "run_attempt": 1}]}
EOF
cat >"$TSCEN/jobs-730.json" <<'EOF'
{"total_count": 3, "jobs": [{"id": 731, "run_id": 730, "name": "Mutants (shard 9)", "labels": ["ubuntu-24.04"], "runner_name": "GitHub Actions 1", "status": "completed", "conclusion": "cancelled", "created_at": "2026-10-09T17:20:00Z", "started_at": "2026-10-09T17:20:10Z", "completed_at": "2026-10-09T17:30:10Z", "steps": []}, {"id": 732, "run_id": 730, "name": "Mutants (shard 9)", "labels": ["ubuntu-24.04"], "runner_name": "GitHub Actions 1", "status": "completed", "conclusion": "cancelled", "created_at": "2026-10-09T17:20:00Z", "started_at": "2026-10-09T17:10:00Z", "completed_at": "2026-10-09T17:30:00Z", "steps": []}, {"id": 733, "run_id": 730, "name": "Tests (ubuntu-24.04)", "labels": ["ubuntu-24.04"], "runner_name": "GitHub Actions 1", "status": "completed", "conclusion": "cancelled", "created_at": "2026-10-09T17:20:00Z", "started_at": "2026-10-09T17:25:00Z", "completed_at": "2026-10-09T17:30:00Z", "steps": []}]}
EOF
printf '2026-10-09T17:30:01Z The operation was canceled\n' >"$TSCEN/logs/731.txt"
printf '2026-10-09T17:30:01Z The operation was canceled\n' >"$TSCEN/logs/732.txt"
printf '2026-10-09T17:30:01Z Error: the job has exceeded the maximum execution time of 10 minutes\n' >"$TSCEN/logs/733.txt"
export FAKE_SCEN="$TSCEN"
run_friction --json
[ "$CODE" = "0" ] || fail "timeout-cancel exits 0 (got $CODE): [$OUT]"
[ "$(jget "[(c['cause'], c['count'], c['lanes']) for c in d['design']]")" = "[('timeout', 1, ['#1405'])]" ] \
  || fail "only the marker cancel is a timeout: [$OUT]"
STCLASS="$(python3 -c "import json; j=json.load(open('$HOME/.cache/switchyard/ci-friction.json'))['jobs']; print(j['731']['class'], j['732']['class'], j['733']['class'])")"
[ "$STCLASS" = "cancelled cancelled timeout" ] || fail "cancel classes: [$STCLASS]"

# --- #599: superseded cancels; the bound is fiber's ci.yml, not the old table ---
# 750 is a 16 min cancelled release job (bound 50 min). 741 is a newer run
# on the same branch and event, created before 750 completed.
#   rel-sup:    741 supersedes 750: cancelled "superseded by a newer run".
#   rel-alone:  no newer run, no marker: cancelled, not a timeout.
#   rel-marker: newer run and the maximum-execution-time line: timeout.
mk_release() { # mk_release <dir> <newer 0|1> <marker 0|1>
  local d="$1" newer="$2" marker="$3" extra=""
  rm -rf "$d"; mkdir -p "$d/logs"
  if [ "$newer" = 1 ]; then
    extra=',{"id": 741, "event": "pull_request", "conclusion": "success", "status": "completed", "pull_requests": [{"number": 1407}], "head_branch": "feat/sup", "head_sha": "gggggggggggggggggggggggggggggggggggggggg", "path": ".github/workflows/ci.yml", "created_at": "2026-10-09T17:10:00Z", "updated_at": "2026-10-09T17:12:00Z", "run_attempt": 1}'
  fi
  cat >"$d/runs.json" <<EOF
{"workflow_runs": [{"id": 740, "event": "pull_request", "conclusion": "cancelled", "status": "completed", "pull_requests": [{"number": 1407}], "head_branch": "feat/sup", "head_sha": "ffffffffffffffffffffffffffffffffffffffff", "path": ".github/workflows/ci.yml", "created_at": "2026-10-09T17:00:00Z", "updated_at": "2026-10-09T17:16:20Z", "run_attempt": 1}$extra]}
EOF
  cat >"$d/jobs-740.json" <<'EOF'
{"total_count": 1, "jobs": [{"id": 750, "run_id": 740, "name": "Release build and size (Linux x86_64)", "labels": ["ubuntu-24.04"], "runner_name": "GitHub Actions 2", "status": "completed", "conclusion": "cancelled", "created_at": "2026-10-09T17:00:00Z", "started_at": "2026-10-09T17:00:10Z", "completed_at": "2026-10-09T17:16:10Z", "steps": []}]}
EOF
  printf '2026-10-09T17:16:11Z The operation was canceled\n' >"$d/logs/750.txt"
  if [ "$marker" = 1 ]; then
    printf '2026-10-09T17:16:11Z Error: the job has exceeded the maximum execution time of 50 minutes\n' >"$d/logs/750.txt"
  fi
}
release_class() { # release_class: the class of job 750 in the state file
  python3 -c "import json; print(json.load(open('$HOME/.cache/switchyard/ci-friction.json'))['jobs']['750']['class'])"
}

setup release-sup
mk_release "$T/scen-rel-sup" 1 0
export FAKE_SCEN="$T/scen-rel-sup"
run_friction --json
[ "$CODE" = "0" ] || fail "release-sup exits 0 (got $CODE): [$OUT]"
[ "$(jget "d['design']")" = "[]" ] || fail "superseded cancel stays out of design: [$OUT]"
[ "$(release_class)" = "cancelled" ] || fail "superseded cancel class: [$(release_class)]"
[ "$(python3 -c "import json; print(json.load(open('$HOME/.cache/switchyard/ci-friction.json'))['jobs']['750']['detail'])")" = "superseded by a newer run" ] \
  || fail "superseded detail: [$OUT]"

setup release-alone
mk_release "$T/scen-rel-alone" 0 0
export FAKE_SCEN="$T/scen-rel-alone"
run_friction --json
[ "$CODE" = "0" ] || fail "release-alone exits 0 (got $CODE): [$OUT]"
[ "$(jget "d['design']")" = "[]" ] || fail "16 min cancel under the 50 min bound is not a timeout: [$OUT]"
[ "$(release_class)" = "cancelled" ] || fail "16 min cancel class: [$(release_class)]"

setup release-marker
mk_release "$T/scen-rel-marker" 1 1
export FAKE_SCEN="$T/scen-rel-marker"
run_friction --json
[ "$CODE" = "0" ] || fail "release-marker exits 0 (got $CODE): [$OUT]"
[ "$(jget "[(c['cause'], c['count']) for c in d['design']]")" = "[('timeout', 1)]" ] \
  || fail "the marker line wins over a newer run: [$OUT]"
[ "$(release_class)" = "timeout" ] || fail "marker class: [$(release_class)]"

# a state file at KEY_VERSION 2 holds 750 as a timeout: it is recomputed
setup release-stale
mk_release "$T/scen-rel-stale" 0 0
export FAKE_SCEN="$T/scen-rel-stale"
mkdir -p "$HOME/.cache/switchyard"
python3 -c "import json; json.dump({'key_version': 2, 'jobs': {'750': {'class': 'timeout', 'detail': 'job hit timeout-minutes', 'tests': [], 'lane': '#1407', 'os': 'Linux', 'completed_at': '2026-10-09T17:16:10Z', 'head_sha': 'ffffffffffffffffffffffffffffffffffffffff'}}, 'issues': {}, 'branches': {}}, open('$HOME/.cache/switchyard/ci-friction.json', 'w'))"
run_friction --json
[ "$CODE" = "0" ] || fail "release-stale exits 0 (got $CODE): [$OUT]"
[ "$(release_class)" = "cancelled" ] || fail "cached timeout reclassified: [$(release_class)]"

echo "ci-friction: all cases passed"

#!/usr/bin/env bash
# Tests for bin/red-main, using a stand-in gh serving fixture files
# (no network). Fake gh maps the api path to test/fixtures/red-main,
# logs its args (including `run rerun` calls), and serves one scenario
# per case. HOME and TMPDIR point at a temp dir (never a live cache).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RED="$SCRIPT_DIR/../bin/red-main"
FIX="$SCRIPT_DIR/fixtures/red-main"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-red-main.XXXXXX")"
export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# --- fake gh ---
cat >"$T/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
echo "gh $*" >>"$FAKE_GH_LOG"
scen="$FAKE_SCEN"
if [ "${1:-}" = "run" ] && [ "${2:-}" = "rerun" ]; then
  id="${3:-}"
  if [ -e "$T/fail-rerun-$id" ]; then cat "$T/fail-rerun-$id" >&2; exit 1; fi
  exit 0
fi
if [ "${1:-}" = "run" ] && [ "${2:-}" = "view" ]; then
  jid=""
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--job" ]; then jid="$a"; fi
    prev="$a"
  done
  if [ -e "$scen/failed-logs/$jid.txt" ]; then cat "$scen/failed-logs/$jid.txt";
  elif [ -e "$scen/logs/$jid.txt" ]; then cat "$scen/logs/$jid.txt"; fi
  exit 0
fi
path=""
for a in "$@"; do
  case "$a" in
    api|--allow-escape-sequences) continue;;
    -*) continue;;
    *) path="$a";;
  esac
done
[ -n "$path" ] || { echo "fake gh: no path" >&2; exit 2; }
case "$path" in
  *actions/runs\?branch=main*)
    case "$path" in *page=1*) cat "$scen/main-runs.json";; *) printf '{"workflow_runs":[]}';; esac;;
  *actions/runs/*/jobs*)
    rid="$(printf '%s' "$path" | sed -E 's/.*runs\/([0-9]+).*/\1/')"
    case "$path" in *page=1*)
      if [ -e "$scen/jobs-$rid.json" ]; then cat "$scen/jobs-$rid.json";
      else printf '{"total_count":0,"jobs":[]}'; fi;;
      *) printf '{"total_count":0,"jobs":[]}';;
    esac;;
  *actions/jobs/*/logs)
    jid="$(printf '%s' "$path" | sed -E 's/.*jobs\/([0-9]+).*/\1/')"
    if [ -e "$scen/logs/$jid.txt" ]; then cat "$scen/logs/$jid.txt"; fi;;
  *contents/*)
    if [ -e "$scen/workflow.json" ]; then cat "$scen/workflow.json";
    else echo "fake gh: no workflow fixture" >&2; exit 1; fi;;
  *issues?state=open*)
    cat "$scen/issues.json";;
  *) echo "fake gh: unknown path $path" >&2; exit 2;;
esac
FAKEGH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

OUT=""; CODE=0; INBOX=""
setup() { # setup <scenario>: fresh HOME, inbox and scenario fixtures
  export FAKE_SCEN="$FIX/$1"
  export FAKE_GH_LOG="$T/gh-args-$1.txt"
  : >"$FAKE_GH_LOG"
  rm -rf "$T/home" "$T/tmp" "$T"/fail-*
  mkdir -p "$T/home" "$T/tmp"
  export HOME="$T/home" TMPDIR="$T/tmp"
  INBOX="$T/inbox-$1"
  rm -rf "$INBOX"
  mkdir -p "$INBOX"
  export INBOX
}
run_red() {
  OUT="$(python3 "$RED" --repo O/N --inbox "$INBOX" 2>"$T/stderr.txt")"; CODE=$?
}
inbox_count() {
  shopt -s nullglob
  local files=("$INBOX"/*.md)
  shopt -u nullglob
  printf '%s' "${#files[@]}"
}
inbox_file() {
  shopt -s nullglob
  local files=("$INBOX"/*.md)
  shopt -u nullglob
  [ "${#files[@]}" -eq 1 ] || fail "one inbox file (got ${#files[@]})"
  printf '%s' "${files[0]}"
}
state_py() { # state_py <expr>: eval d=<state json>, print expr
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print('"$1"')' "$HOME/.cache/switchyard/red-main.json"
}
expect() { # expect <code>: exit code only
  [ "$CODE" = "$1" ] || fail "exit $1 (got $CODE): [$OUT] [$(cat "$T/stderr.txt")]"
}

# --- all-non-blocking ignored: Journey fails, CI needs list it nowhere ---
setup nonblocking
run_red
expect 0
[ "$(inbox_count)" = "0" ] || fail "non-blocking run writes no handoff"
grep -q "run rerun" "$FAKE_GH_LOG" && fail "non-blocking run reruns nothing"
[ "$(state_py "'301' in set(map(str, d['handled_ids']))")" = "True" ] || fail "handled run recorded: [$OUT]"

# --- infrastructure: setup step fails with no test failing; rerun once ---
setup infra
run_red
expect 0
[ "$(inbox_count)" = "0" ] || fail "infrastructure writes no handoff"
grep -q "run rerun 311" "$FAKE_GH_LOG" || fail "infrastructure reruns the run: [$(cat "$FAKE_GH_LOG")]"
run_red
expect 0
[ "$(grep -c "run rerun 311" "$FAKE_GH_LOG")" = "1" ] \
  || fail "rerun happens once across passes: [$(cat "$FAKE_GH_LOG")]"
[ "$(inbox_count)" = "0" ] || fail "second pass still writes no handoff"

# --- flake: the test passes on a later main head; a sighting, no handoff ---
setup flake-pass
run_red
expect 0
[ "$(inbox_count)" = "0" ] || fail "retry-passed flake writes no handoff"
grep -q "run rerun" "$FAKE_GH_LOG" && fail "flake reruns nothing"
[ "$(state_py "len(d['sightings'])")" = "1" ] || fail "flake sighting recorded: [$OUT]"
[ "$(state_py "d['sightings'][0]['job']")" = "Tests (ubuntu-24.04)" ] || fail "sighting job: [$OUT]"

# --- flake: the test matches an open flake ticket; a sighting, no handoff ---
setup flake-issue
run_red
expect 0
[ "$(inbox_count)" = "0" ] || fail "ticket-matched flake writes no handoff"
[ "$(state_py "len(d['sightings'])")" = "1" ] || fail "ticket flake sighting recorded: [$OUT]"
grep -q "issues?state=open" "$FAKE_GH_LOG" || fail "open issues consulted: [$(cat "$FAKE_GH_LOG")]"

# --- real: one inbox file with job, full SHA, first test, link and tail ---
setup real
run_red
expect 1
f="$(inbox_file)"
grep -q "Tests (ubuntu-24.04)" "$f" || fail "handoff names the job"
grep -q "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$f" || fail "handoff holds the full SHA"
grep -q "fiber-core doors::open" "$f" || fail "handoff names the first failing test"
grep -q "https://github.com/O/N/actions/runs/341" "$f" || fail "handoff holds the run link"
grep -q "REAL-TAIL-3412" "$f" || fail "handoff holds the log tail"
[ "$(state_py "len(d['open'])")" = "1" ] || fail "real failure stays open: [$OUT]"

# --- duplicate: two runs fail the same job and test; still one handoff ---
setup dup
run_red
expect 1
[ "$(inbox_count)" = "1" ] || fail "duplicate failure writes one handoff (got $(inbox_count))"
f="$(inbox_file)"
grep -q "1111111111111111111111111111111111111111" "$f" || fail "kept handoff is the first run"
[ "$(state_py "len(d['open'])")" = "1" ] || fail "duplicate shares one open key: [$OUT]"

# --- close: a later main run passing the job closes the open handoff ---
setup real
run_red
expect 1
[ "$(inbox_count)" = "1" ] || fail "close phase one opens a handoff"
export FAKE_SCEN="$FIX/close"
export FAKE_GH_LOG="$T/gh-args-close.txt"
: >"$FAKE_GH_LOG"
run_red
expect 0
[ "$(inbox_count)" = "1" ] || fail "closing pass sends nothing new (got $(inbox_count))"
[ "$(state_py "len(d['open'])")" = "0" ] || fail "passing job closes the handoff: [$OUT]"

# --- blocking set comes from the workflow file, never a fallback ---
setup blocking-error
run_red
expect 2
[ "$(inbox_count)" = "0" ] || fail "unreadable workflow writes no handoff"
grep -q "workflow" "$T/stderr.txt" || fail "unreadable workflow errors to stderr: [$(cat "$T/stderr.txt")]"
[ ! -e "$HOME/.cache/switchyard/red-main.json" ] || fail "errored run stays unhandled"
export FAKE_SCEN="$FIX/blocking-ok"
export FAKE_GH_LOG="$T/gh-args-blocking-ok.txt"
: >"$FAKE_GH_LOG"
run_red
expect 1
[ "$(inbox_count)" = "1" ] || fail "retry after workflow error hands off (got $(inbox_count))"
f="$(inbox_file)"
grep -q "7777777777777777777777777777777777777777" "$f" || fail "retried handoff holds the SHA"
grep -q "BLOCKING-TAIL-3612" "$f" || fail "retried handoff holds the tail"

# --- flake match needs the full test name, not the package name ---
setup flake-pkgname
run_red
expect 1
f="$(inbox_file)"
grep -q "fiber-core doors::open" "$f" || fail "doc-only issue does not suppress the handoff"

# --- cursor: an older run pending during a newer pass is still handled ---
setup cursor-a
run_red
expect 1
[ "$(inbox_count)" = "1" ] || fail "newer run handled while the older pends (got $(inbox_count))"
export FAKE_SCEN="$FIX/cursor-b"
export FAKE_GH_LOG="$T/gh-args-cursor-b.txt"
: >"$FAKE_GH_LOG"
run_red
expect 1
[ "$(inbox_count)" = "2" ] || fail "completed older run handed off too (got $(inbox_count))"
grep -q "3333333333333333333333333333333333333333" "$INBOX"/*.md || fail "older run handled after it completes"
grep -q "CURSOR-TAIL-3712" "$INBOX"/*.md || fail "older run handoff holds the tail"

# --- ordering: a pass closes the old handoff before the next failure reopens ---
setup reopen
python3 - "$HOME/.cache/switchyard/red-main.json" <<'EOF'
import json, os, sys
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
st = {"handled_ids": [], "reran": [],
      "open": {"Tests (ubuntu-24.04)\x1ffiber-core doors::open":
               {"job": "Tests (ubuntu-24.04)", "test": "fiber-core doors::open",
                "run": "380", "sha": "0000000000000000000000000000000000000000",
                "at": "2026-10-09T16:00:00Z"}},
      "sightings": []}
open(sys.argv[1], "w").write(json.dumps(st))
EOF
run_red
expect 1
[ "$(inbox_count)" = "1" ] || fail "reopened failure writes one handoff (got $(inbox_count))"
f="$(inbox_file)"
grep -q "6666666666666666666666666666666666666666" "$f" || fail "handoff reopened for the new run"
[ "$(state_py "len(d['open'])")" = "1" ] || fail "reopened handoff stays open: [$OUT]"

# --- log tail comes from the failed step only ---
setup failed-step
run_red
expect 1
f="$(inbox_file)"
grep -q "fiber-core doors::open" "$f" || fail "handoff names the first failing test"
grep -q "STEP-TAIL-3912" "$f" || fail "handoff holds the failed-step tail"
grep -q "CLEANUP-3912" "$f" && fail "handoff holds cleanup output after the failed step"

# --- exits: 2 on a missing inbox ---
OUT="$(python3 "$RED" --repo O/N 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "missing inbox exits 2 (got $CODE)"

echo "red-main: all cases passed"

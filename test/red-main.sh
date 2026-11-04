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
if [ "${1:-}" = "run" ] && [ "${2:-}" = "rerun" ]; then
  id="${3:-}"
  if [ -e "$T/fail-rerun-$id" ]; then cat "$T/fail-rerun-$id" >&2; exit 1; fi
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
scen="$FAKE_SCEN"
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
[ "$(state_py "d['last_handled_id']")" = "301" ] || fail "handled run recorded: [$OUT]"

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

# --- exits: 2 on a missing inbox ---
OUT="$(python3 "$RED" --repo O/N 2>"$T/stderr.txt")"; CODE=$?
[ "$CODE" = "2" ] || fail "missing inbox exits 2 (got $CODE)"

echo "red-main: all cases passed"

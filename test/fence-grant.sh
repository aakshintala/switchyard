#!/usr/bin/env bash
# Tests for bin/fence-grant. Exits non-zero on the first failed case.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FG="${FG:-$SCRIPT_DIR/../bin/fence-grant}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-fence-grant.XXXXXX")"
export T
PI_PID=""
cleanup() {
  if [ -n "$PI_PID" ]; then kill "$PI_PID" 2>/dev/null || true; fi
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/home" "$T/tmp" "$T/run" "$T/stubs" "$T/blobs" "$T/pr"
export HOME="$T/home" TMPDIR="$T/tmp" FW_RUN="$T/run" FW_GH="$T/stubs/gh" FW_CLAUDE="$T/stubs/claude" FW_SSH="$T/stubs/ssh" FW_DELEGATE="$T/stubs/delegate" FW_BOX_HOST=stub-box
export FW_TREE_CACHE="$T/tree-cache"
export GH_TREE="$T/tree.json" GH_PRLIST='[]' CLAUDE_JSON='[]' SSH_OUT

cat >"$FW_GH" <<'GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T/gh.log"
case "$1" in
  api)
    case "$2" in
      graphql)
        [ "${GH_TICKET_FAIL:-0}" != 1 ] || { echo 'ticket state stub failure' >&2; exit 1; }
        [ "${GH_TICKET_BAD:-0}" != 1 ] || { printf 'not graphql json'; exit 0; }
        [ "${GH_TICKET_MISSING:-0}" != 1 ] || { printf '{"data":{"repository":{}}}'; exit 0; }
        query=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -f|-F) case "${2:-}" in query=*) query="${2#query=}";; esac; shift 2;;
            *) shift;;
          esac
        done
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
        ;;
      repos/*/commits/main)
        [ "${GH_SHA_FAIL:-0}" = 1 ] && { echo "${GH_SHA_ERROR:-sha stub failure}" >&2; exit 1; }
        printf '%s\n' "$GH_TREE_SHA"
        ;;
      repos/*/git/trees/*\?recursive=1)
        [ "${GH_TREE_FAIL:-0}" = 1 ] && { printf 'partial tree'; echo "${GH_TREE_ERROR:-tree stub failure}" >&2; exit 1; }
        [ -n "${GH_TREE_JSON:-}" ] && { printf '%s' "$GH_TREE_JSON"; exit 0; }
        cat "$GH_TREE"
        ;;
      repos/*/contents/*\?ref=main)
        [ "${GH_BLOB_FAIL:-0}" = 1 ] && { echo 'blob stub failure' >&2; exit 1; }
        path="${2#*/contents/}"
        path="${path%\?ref=main}"
        [ -f "$T/blobs/$path" ] || { echo "missing blob: $path" >&2; exit 1; }
        cat "$T/blobs/$path"
        ;;
      *) echo "stub gh: unexpected: $*" >&2; exit 99;;
    esac
    ;;
  pr)
    case "$2" in
      list)
        [ "${GH_PRLIST_FAIL:-0}" = 1 ] && { echo 'pr list stub failure' >&2; exit 1; }
        [ -n "${GH_PRLIST_JSON:-}" ] && { printf '%s' "$GH_PRLIST_JSON"; exit 0; }
        printf '%s' "$GH_PRLIST"
        ;;
      diff)
        pr="$3"
        case " $* " in
          *' --name-only '*)
            [ "${GH_DIFFN_FAIL:-}" != "$pr" ] || { echo 'pr names stub failure' >&2; exit 1; }
            [ -f "$T/pr/$pr.names" ] && cat "$T/pr/$pr.names"
            ;;
          *' --allow-escape-sequences '*)
            [ "${GH_DIFF_FAIL:-}" != "$pr" ] || { echo 'pr diff stub failure' >&2; exit 1; }
            [ -f "$T/pr/$pr.diff" ] && cat "$T/pr/$pr.diff"
            ;;
          *) echo "stub gh: unexpected: $*" >&2; exit 99;;
        esac
        ;;
      *) echo "stub gh: unexpected: $*" >&2; exit 99;;
    esac
    ;;
  *) echo "stub gh: unexpected: $*" >&2; exit 99;;
esac
GH_STUB

cat >"$FW_CLAUDE" <<'CLAUDE_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T/claude.log"
[ "${CLAUDE_FAIL:-0}" != 1 ] || { echo 'claude stub failure' >&2; exit 1; }
printf '%s' "${CLAUDE_JSON:-[]}"
CLAUDE_STUB

cat >"$FW_DELEGATE" <<'DELEGATE_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T/delegate.log"
[ "$*" = 'session list --json' ] || { echo "stub delegate: unexpected: $*" >&2; exit 99; }
[ "${MAC_DELEGATE_FAIL:-0}" != 1 ] || { echo 'delegate stub failure' >&2; exit 1; }
printf '%s' "${MAC_DSESS_JSON:-}"
DELEGATE_STUB
cat >"$FW_SSH" <<'SSH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T/ssh.log"
[ "${SSH_FAIL:-0}" != 1 ] || { echo 'ssh stub failure' >&2; exit 1; }
if [ -n "${SSH_OUT:-}" ]; then printf '%s\n' "$SSH_OUT"; elif [[ "${2:-}" == *'echo FWSEC=UPTIME'* ]]; then
  printf '%s\n' 'FWSEC=UPTIME' 'FWSEC=AGENTS' '[]' 'FWSEC=DELEGATE' DELEGATEOK \
    'FWSEC=DSESS' "$DSESS_JSON"
  case "${2:-}" in
    *'&& echo DSESSJSONOK'*) [ "${DSESS_FULL_FAIL:-0}" != 1 ] && printf '%s\n' DSESSJSONOK;;
    *) printf '%s\n' DSESSJSONOK;;
  esac
  printf '%s\n' 'FWSEC=PILANES' PILANESOK 'FWSEC=END'
else
  printf '%s\n' "${DSESS_RETRY_JSON:-$DSESS_JSON}"
  [ "${DSESS_RETRY_FAIL:-0}" != 1 ] || exit 1
  printf '%s\n' DSESSJSONOK
fi
SSH_STUB
cat >"$T/stubs/file-claim" <<'FC_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T/file-claim.log"
case "$1" in
  reap)
    [ "${FILE_CLAIM_REAP_FAIL:-0}" != 1 ] || { echo 'stub file-claim reap: boom' >&2; exit 2; }
    exit 0
    ;;
  list)
    lane=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --lane) lane="$2"; shift 2;;
        *) shift;;
      esac
    done
    [ "${FILE_CLAIM_LIST_FAIL:-0}" != 1 ] || { echo 'stub file-claim list: boom' >&2; exit 2; }
    [ "${FILE_CLAIM_LIST_BAD:-0}" != 1 ] || { echo 'not a claims row'; exit 0; }
    if [ -f "$T/file-claim-claims" ]; then rows=$(cat "$T/file-claim-claims"); else rows=${FILE_CLAIM_LIST:-}; fi
    if [ -n "$lane" ]; then printf '%s' "$rows" | awk -F '\t' -v lane="$lane" '$2 == lane'; else printf '%s' "$rows"; fi
    exit 0
    ;;
  claim)
    original=("$@"); lane=""; kind="plan"; after=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --lane) lane="$2"; shift 2;;
        --grant) kind="grant"; shift;;
        --plan) kind="plan"; shift;;
        --ranges) echo 'usage: file-claim claim' >&2; exit 2;;
        --) after=1; shift; break;;
        *) shift;;
      esac
    done
    if [ "$after" = 1 ] && { [ "${FILE_CLAIM_MODE:-ok}" = ok ] || [ "${FILE_CLAIM_MODE:-ok}" = overlap ]; }; then
      for p in "$@"; do
        printf '%s\t%s\t%s\t0\tt:stub\t\n' "$p" "$lane" "$kind" >>"$T/file-claim-claims"
      done
    fi
    ;;
esac
case "${FILE_CLAIM_MODE:-ok}" in
  ok) exit 0;;
  overlap)
    after=0
    for a in "${original[@]}"; do
      case "$a" in --) after=1; continue;; esac
      if [ "$after" = 1 ]; then
        echo "OVERLAP $a lane:fiber-66"
        echo "GRANT $a new"
      fi
    done
    echo 'file-claim: 1 granted, 0 refused'
    exit 0;;
  cap)
    [ "${#original[@]}" -gt 0 ] || exit 0
    after=0
    for a in "${original[@]}"; do
      case "$a" in --) after=1; continue;; esac
      if [ "$after" = 1 ]; then echo "REFUSE $a cap"; fi
    done
    echo 'file-claim: no claims recorded; 1 refused, 0 unclaimed because the batch was refused'
    exit 1;;
  overlap-cap)
    after=0
    for a in "${original[@]}"; do
      case "$a" in --) after=1; continue;; esac
      if [ "$after" = 1 ]; then
        echo "OVERLAP $a lane:fiber-66"
        echo "REFUSE $a cap"
      fi
    done
    echo 'file-claim: no claims recorded; 1 refused, 0 unclaimed because the batch was refused'
    exit 1;;
  refuse)
    n=0; u=0; after=0
    for a in "${original[@]}"; do
      if [ "$after" = "1" ]; then
        if [ "$n" = 0 ]; then echo "REFUSE $a lane:fiber-77"; n=$((n + 1))
        else echo "UNCLAIMED $a batch-refused"; u=$((u + 1)); fi
      fi
      case "$a" in --) after=1;; esac
    done
    echo "file-claim: no claims recorded; $n refused, $u unclaimed because the batch was refused"
    exit 1;;
  error)
    echo 'stub file-claim: boom' >&2
    exit 2;;
esac
FC_STUB
chmod +x "$FW_GH" "$FW_CLAUDE" "$FW_SSH" "$FW_DELEGATE" "$T/stubs/file-claim"

reset_case() {
  rm -rf "$FW_RUN" "$T/blobs" "$T/pr" "$T/delegate-jobs" "$TMPDIR/delegate-jobs"
  mkdir -p "$FW_RUN" "$T/blobs" "$T/pr" "$T/delegate-jobs" "$TMPDIR/delegate-jobs" "$FW_TREE_CACHE"
  : >"$FW_RUN/roster"
  DSESS_JSON='{"ok":true,"sessions":[]}'
  DSESS_RETRY_JSON='' DSESS_RETRY_FAIL=0 DSESS_FULL_FAIL=0
  MAC_DSESS_JSON='{"ok":true,"sessions":[]}' MAC_DELEGATE_FAIL=0
  export DSESS_JSON DSESS_RETRY_JSON DSESS_RETRY_FAIL DSESS_FULL_FAIL MAC_DSESS_JSON MAC_DELEGATE_FAIL
  : >"$T/gh.log"
  : >"$T/claude.log"
  : >"$T/ssh.log"
  : >"$T/delegate.log"
  rm -f "$T/file-claim-claims"
  cat >"$GH_TREE" <<'TREE'
{"truncated":false,"tree":[
{"type":"blob","path":"docs/tui.md"},
{"type":"blob","path":"docs/events.md"},
{"type":"blob","path":"main_journeys.rs"},
{"type":"blob","path":"crates/tui/src/turn/group.rs"},
{"type":"blob","path":"crates/tui/src/turn/group_tests.rs"},
{"type":"blob","path":"crates/extensions/src/process/tests.rs"},
{"type":"blob","path":"crates/extensions/src/process_tests.rs"},
{"type":"blob","path":"crates/a/tests.rs"},
{"type":"blob","path":"crates/b/tests.rs"},
{"type":"blob","path":"crates/c/tests.rs"},
{"type":"blob","path":"crates/d/tests.rs"},
{"type":"blob","path":"crates/e/tests.rs"},
{"type":"blob","path":"crates/f/tests.rs"},
{"type":"blob","path":"bin/job-record"},
{"type":"blob","path":"src/new_dir/keep.rs"}
]}
TREE
  GH_TREE_SHA=aaaaaaaa GH_SHA_FAIL=0 GH_SHA_ERROR= GH_TREE_ERROR=
  export GH_TREE_SHA GH_SHA_FAIL GH_SHA_ERROR GH_TREE_ERROR
  GH_TREE_FAIL=0 GH_BLOB_FAIL=0 GH_PRLIST_FAIL=0 GH_DIFFN_FAIL= GH_DIFF_FAIL=
  GH_TREE_JSON= GH_PRLIST_JSON= GH_PRLIST='[]' CLAUDE_FAIL=0 CLAUDE_JSON='[]' SSH_FAIL=0 SSH_OUT=
  export GH_TREE_FAIL GH_BLOB_FAIL GH_PRLIST_FAIL GH_DIFFN_FAIL GH_DIFF_FAIL GH_TREE_JSON GH_PRLIST_JSON GH_PRLIST CLAUDE_FAIL CLAUDE_JSON SSH_FAIL SSH_OUT
  GH_TICKET_STATES= GH_TICKET_FAIL=0 GH_TICKET_BAD=0 GH_TICKET_MISSING=0 GH_TICKET_OMIT=
  export GH_TICKET_STATES GH_TICKET_FAIL GH_TICKET_BAD GH_TICKET_MISSING GH_TICKET_OMIT
  FW_DELEGATE_DIR="$T/delegate-jobs"
  export FW_DELEGATE_DIR
  FILE_CLAIM_MODE=ok FILE_CLAIM_LIST_FAIL=0 FILE_CLAIM_LIST_BAD=0 FILE_CLAIM_LIST=
  export FILE_CLAIM_MODE FILE_CLAIM_LIST_FAIL FILE_CLAIM_LIST_BAD FILE_CLAIM_LIST
  FW_FILE_CLAIM="$T/stubs/file-claim"
  export FW_FILE_CLAIM
  : >"$T/file-claim.log"
}

# Writes one delegate registry record: name, status, supervisor pid, worktree.
# The real registry writes one line of JSON whose first key is the status.
write_delegate_job() {
  _delegate_dir=${FW_DELEGATE_DIR:-${TMPDIR:-/tmp}/delegate-jobs}
  mkdir -p "$_delegate_dir"
  printf '{"status":"%s","result":null,"supervisorPid":%s,"resume":{"cwd":"%s"}}\n' \
    "$2" "$3" "$4" >"$_delegate_dir/$1.json"
}

run_fg() {
  bash "$FG" "$@" >"$T/out" 2>"$T/err"
  RC=$?
}

assert_rc() {
  [ "$RC" = "$1" ] || fail "$2: exit $RC, want $1; stdout=$(cat "$T/out"); stderr=$(cat "$T/err")"
}

assert_out() {
  [ "$(cat "$T/out")" = "$1" ] || fail "$2: stdout=$(cat "$T/out")"
}

assert_stderr() {
  [ "$(cat "$T/err")" = "$1" ] || fail "$2: stderr=$(cat "$T/err")"
}

assert_line() {
  grep -qxF "$1" "$T/out" || fail "$2: missing exact line [$1] in $(cat "$T/out")"
}

assert_contains() {
  grep -qF "$1" "$T/out" || fail "$2: missing [$1] in $(cat "$T/out")"
}

assert_not_contains() {
  ! grep -qF "$1" "$T/out" || fail "$2: unexpected [$1] in $(cat "$T/out")"
}

assert_no_grant() {
  [ ! -d "$FW_RUN" ] || [ -z "$(find "$FW_RUN" -name 'fiber-*-fence-grant*.md' -print)" ] || fail "$1: wrote grant file"
}

assert_no_probes() {
  [ ! -s "$T/gh.log" ] || fail "$1: called gh: $(cat "$T/gh.log")"
}

assert_no_ticket_state_probe() {
  ! grep -q '^api graphql ' "$T/gh.log" || fail "$1: made ticket-state lookup: $(grep '^api graphql ' "$T/gh.log")"
}

assert_usage() {
  assert_rc 2 "$1"
  assert_out '' "$1 stdout"
  assert_stderr "$(printf 'usage: fence-grant <ticket> --paths <comma list> [--ranges <file:start-end,...>] [--reads <comma list>] [--new <comma list>] [--expect <file:line:symbol,...>] [--repo <owner/name>] [--part <n>] [--ignore-pr <n>] [--ignore-ticket <n>] [--swept-to <comment id>] [--removes <symbol,...>] [--doc-heading <docs/file.md#heading> (review warning, not a grant)] [--pre-plan <path-shape>] [--dry] | --require <ticket> --phase plan|build|ship\n       non-sweep holds are advisory overlaps; sweep-* file claims remain exclusive')" "$1 usage"
  assert_no_probes "$1"
  assert_no_grant "$1"
}

assert_error() {
  assert_rc 3 "$1"
  assert_out "$2" "$1 output"
  assert_no_grant "$1"
}

write_blob() {
  mkdir -p "$T/blobs/${1%/*}"
  printf '%s' "$2" >"$T/blobs/$1"
}

set_pr() {
  number="$1"; branch="$2"; path="$3"
  GH_PRLIST="[{\"number\":$number,\"headRefName\":\"$branch\"}]"
  export GH_PRLIST
  printf '%s\n' "$path" >"$T/pr/$number.names"
  printf 'diff --git a/%s b/%s\nindex 1111111..2222222 100644\n' "$path" "$path" >"$T/pr/$number.diff"
}

# A real guard reaps before reading holders; dry runs remain read-only.
reset_case
run_fg 77 --paths docs/tui.md
assert_rc 0 'guard calls file-claim reap before checking holders'
[ "$(head -n 2 "$T/file-claim.log")" = "$(printf 'reap --repo aakshintala/fiber\nlist --repo aakshintala/fiber')" ] || fail 'reap precedes the guard holder list'

# Recursive trees are cached by immutable tree SHA across sweeps.
reset_case
rm -rf "$FW_TREE_CACHE"
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'tree cache miss'
[ "$(grep -c 'git/trees/' "$T/gh.log")" = 1 ] || fail 'cache miss fetches once'
[ -s "$FW_TREE_CACHE/aaaaaaaa.tree" ] || fail 'cache miss writes entry'
: >"$T/gh.log"
GH_TREE_FAIL=1
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'tree cache hit'
! grep -q 'git/trees/' "$T/gh.log" || fail 'cache hit fetches no tree'
GH_TREE_FAIL=0 GH_TREE_SHA=bbbbbbbb
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'new tree SHA'
grep -qF 'git/trees/bbbbbbbb?recursive=1' "$T/gh.log" || fail 'new SHA fetches its tree'
[ -s "$FW_TREE_CACHE/bbbbbbbb.tree" ] || fail 'new SHA writes entry'
GH_TREE_FAIL=1 GH_TREE_SHA=cccccccc
run_fg 88 --paths docs/tui.md --dry
assert_error 'failed fetch' 'ERROR gh trees main tree stub failure '
[ ! -e "$FW_TREE_CACHE/cccccccc.tree" ] || fail 'failed fetch leaves cache entry'

# Failed Mac delegate probes and refused JSON fail closed.
reset_case
MAC_DELEGATE_FAIL=1
export MAC_DELEGATE_FAIL
run_fg 77 --paths docs/tui.md
assert_error 'failed Mac delegate session command' 'ERROR mac delegate sessions: delegate session list failed, or the roster mapper refused the JSON'

reset_case
MAC_DSESS_JSON='not-json'
export MAC_DSESS_JSON
run_fg 77 --paths docs/tui.md
assert_error 'Mac delegate session mapper refuses JSON' 'ERROR mac delegate sessions: delegate session list failed, or the roster mapper refused the JSON'

# A live Mac delegate session maps to its ticket through the roster.
reset_case
printf '2026-11-06 launch\t1284\tmac\tfiber-1284-build\tabcdef12\n' >"$FW_RUN/roster"
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-1284\tgrant\t0\tt:stub\t\n')"
MAC_DSESS_JSON='{"ok":true,"sessions":[{"id":"abcdef123456","status":"running"}]}'
export FILE_CLAIM_LIST MAC_DSESS_JSON
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'live Mac session claim overlap is advisory'
assert_line 'OVERLAP docs/tui.md lane #1284' 'live Mac session claim overlap output'
assert_not_contains 'STALE docs/tui.md by fiber-1284' 'live Mac session claim is not stale'
assert_line 'WOULD-GRANT docs/tui.md' 'live Mac session overlap allows grant'

# A session's shared cwd carries no ticket: map its id through the roster.
reset_case
printf '2026-11-05 launch\t77\tbox\tfiber-77\tabcdef12\n' >"$FW_RUN/roster"
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
touch -t 202001010000 "$FW_RUN/fiber-77-fence-grant-1.md"
DSESS_JSON='{"ok":true,"sessions":[{"id":"abcdef123456","status":"running"}]}'
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'live roster grant overlap is advisory'
assert_line 'OVERLAP docs/tui.md lane #77' 'live roster overlap output'
assert_line 'WOULD-GRANT docs/tui.md' 'live roster overlap grants'

# Prefix matching also works when the roster has the longer id.
printf '2026-11-05 launch\t77\tbox\tfiber-77\tabcdef1234567890\n' >"$FW_RUN/roster"
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'longer roster lane overlap is advisory'
assert_line 'OVERLAP docs/tui.md lane #77' 'longer roster overlap output'
assert_line 'WOULD-GRANT docs/tui.md' 'longer roster overlap grants'

printf '2026-11-05 launch\t77\tbox\tprep-77\tabcdef12\n' >"$FW_RUN/roster"
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'prep session holds nothing'
assert_line 'WOULD-GRANT' 'prep session grant'

printf '2026-11-05 launch\t77\tbox\tfiber-77\tabcdef12\n' >"$FW_RUN/roster"
DSESS_JSON='{"ok":true,"sessions":[{"id":"abcdef123456","status":"stopped"}]}'
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'stopped session holds nothing'
assert_line 'WOULD-GRANT' 'stopped session grant'

reset_case
run_fg 77 --paths docs/tui.md
assert_rc 0 'valid box sessions need one probe'
[ "$(grep -cF 'echo FWSEC=UPTIME' "$T/ssh.log")" = 1 ] || fail "valid box sessions use one full probe: $(cat "$T/ssh.log")"
[ "$(wc -l <"$T/ssh.log" | tr -d ' ')" = 1 ] || fail "valid box sessions have no retry: $(cat "$T/ssh.log")"
grep -qF 'delegate session list --json 2>/dev/null && echo DSESSJSONOK' "$T/ssh.log" || fail "box marker is conditional on delegate success: $(cat "$T/ssh.log")"

reset_case
DSESS_FULL_FAIL=1
export DSESS_FULL_FAIL
run_fg 77 --paths docs/tui.md
assert_error 'failed box delegate command has no marker' 'ERROR box delegate sessions: no DSESSJSONOK marker, or the roster mapper refused the JSON'
[ "$(wc -l <"$T/ssh.log" | tr -d ' ')" = 1 ] || fail "failed box delegate command is not retried: $(cat "$T/ssh.log")"

reset_case
DSESS_JSON='{"ok":true,"sessions":[{"terminal":"'
DSESS_RETRY_JSON='{"ok":true,"sessions":[]}'
export DSESS_JSON DSESS_RETRY_JSON
run_fg 77 --paths docs/tui.md
assert_rc 0 'truncated box sessions recover on retry'
[ "$(grep -cF 'echo FWSEC=UPTIME' "$T/ssh.log")" = 1 ] || fail "truncated box sessions use one full probe: $(cat "$T/ssh.log")"
[ "$(wc -l <"$T/ssh.log" | tr -d ' ')" = 2 ] || fail "truncated box sessions use one retry: $(cat "$T/ssh.log")"
[ "$(grep -cF 'stub-box ~/.local/bin/delegate session list --json' "$T/ssh.log")" = 1 ] || fail "truncated box sessions retry only the session list: $(cat "$T/ssh.log")"

reset_case
DSESS_JSON='{"ok":true,"sessions":[{"terminal":"'
DSESS_RETRY_JSON="$DSESS_JSON"
export DSESS_JSON DSESS_RETRY_JSON
run_fg 77 --paths docs/tui.md
assert_error 'always-truncated box sessions fail closed' 'ERROR box delegate sessions: no DSESSJSONOK marker, or the roster mapper refused the JSON'
[ "$(grep -cF 'echo FWSEC=UPTIME' "$T/ssh.log")" = 1 ] || fail "always-truncated box sessions use one full probe: $(cat "$T/ssh.log")"
[ "$(wc -l <"$T/ssh.log" | tr -d ' ')" = 3 ] || fail "always-truncated box sessions use two retries: $(cat "$T/ssh.log")"
[ "$(grep -cF 'stub-box ~/.local/bin/delegate session list --json' "$T/ssh.log")" = 2 ] || fail "always-truncated box sessions retry only the session list: $(cat "$T/ssh.log")"

reset_case
SSH_OUT=$'FWSEC=UPTIME\nFWSEC=AGENTS\n[]\nFWSEC=DELEGATE\nDELEGATEOK\nFWSEC=DSESS\n{"ok":true,"sessions":[]}\nFWSEC=PILANES\nPILANESOK\nFWSEC=END'
run_fg 77 --paths docs/tui.md
assert_error 'session section missing marker' 'ERROR box delegate sessions: no DSESSJSONOK marker, or the roster mapper refused the JSON'

reset_case
DSESS_JSON='not-json'
run_fg 77 --paths docs/tui.md
assert_error 'session mapper refuses JSON' 'ERROR box delegate sessions: no DSESSJSONOK marker, or the roster mapper refused the JSON'

# --- Exit 0: free paths and grant-file writing --------------------------------
reset_case
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'free dry run'
! grep -q '^GRANT' "$T/out" || fail 'dry output has no actionable GRANT lines'
assert_line 'WOULD-GRANT docs/tui.md' 'dry path output'
assert_line 'WOULD-GRANT' 'dry closing output'
assert_out "$(printf 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/tui.md\nWOULD-GRANT')" 'free dry output'
assert_no_grant 'free dry run'

# Called through a relative symlink from a directory with no siblings (as
# flywheel's bin/fence-grant is), it finds file-claim and fw-sess-lanes beside
# its real path.
reset_case
mkdir -p "$T/realbin" "$T/realbin/lib" "$T/linkbin"
cp "$FG" "$T/realbin/fence-grant"
cp "$(dirname "$FG")/lib/lane-ticket.sh" "$T/realbin/lib/lane-ticket.sh"
cp "$T/stubs/file-claim" "$T/realbin/file-claim"
cp "$(dirname "$FG")/fw-sess-lanes" "$T/realbin/fw-sess-lanes"
ln -sf ../realbin/fence-grant "$T/linkbin/fence-grant"
(unset FW_FILE_CLAIM; bash "$T/linkbin/fence-grant" 77 --paths docs/tui.md --dry >"$T/out" 2>"$T/err"); RC=$?
assert_rc 0 'symlinked caller finds file-claim'
grep -q '^list' "$T/file-claim.log" || fail "symlinked caller: file-claim not called; log=$(cat "$T/file-claim.log")"

reset_case
run_fg 77 --paths docs/tui.md
assert_rc 0 'free grant file'
assert_line 'GRANT docs/tui.md' 'grant path output'
grep -qF "GRANT FILE host=$(hostname) path=$FW_RUN/fiber-77-fence-grant-1.md" "$T/err" \
  || fail "grant location identifies host and absolute file path: $(cat "$T/err")"
assert_out "$(printf 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nGRANT docs/tui.md\nGRANT')" 'free grant output'
[ -f "$FW_RUN/fiber-77-fence-grant-1.md" ] || fail 'first grant file exists'
grep -qxF 'Paths:' "$FW_RUN/fiber-77-fence-grant-1.md" || fail 'grant file has Paths section'
grep -qxF -- '- docs/tui.md' "$FW_RUN/fiber-77-fence-grant-1.md" || fail 'grant file records the path'
grep -qxF 'Ranges: none' "$FW_RUN/fiber-77-fence-grant-1.md" || fail 'grant file records no ranges'
[ ! -d "$FW_RUN/.fence-grant.lock" ] || fail 'grant lock removed'
run_fg 77 --paths docs/tui.md
assert_rc 0 'second grant file'
[ -f "$FW_RUN/fiber-77-fence-grant-2.md" ] || fail 'grant numbering increments'

reset_case
run_fg 77 --paths docs/tui.md,crates/new/file.rs --new crates/new/file.rs
assert_rc 0 'grant records declared new paths'
grant_file="$FW_RUN/fiber-77-fence-grant-1.md"
grep -qxF -- '- docs/tui.md' "$grant_file" || fail 'Paths section retains existing paths'
grep -qxF -- '- crates/new/file.rs' "$grant_file" || fail 'Paths section retains the new file as a held path'
grep -qxF '## New (do not exist on origin/main):' "$grant_file" || fail 'grant has a separate new-path section'
awk '
  $0 == "## New (do not exist on origin/main):" { in_new = 1; next }
  in_new && /^##([[:space:]]|$)/ { exit }
  in_new && $0 == "- crates/new/file.rs" { found = 1 }
  END { exit !found }
' "$grant_file" || fail 'new-path section lists the new file'
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'grant reader accepts new-path section'
assert_line 'OVERLAP docs/tui.md lane #77' 'Paths reader still sees existing paths'
run_fg --require 77 --phase build
assert_rc 0 '--require accepts a grant with a new-path section'

reset_case
run_fg 77 --paths docs/tui.md --swept-to 123456
assert_rc 0 'grant records swept-to comment'
grep -qxF 'Swept to comment 123456' "$FW_RUN/fiber-77-fence-grant-1.md" || fail 'grant records swept-to comment id'
grep -qxF '# The script owns grant numbering; hand-written grants take a letter suffix.' "$FG" || fail 'header explains grant numbering ownership'

reset_case
run_fg 77 --paths bin/job-record --dry
assert_rc 0 'matching docs are printed for a granted path'
assert_line 'DOC bin/job-record' 'DOC heading'
assert_contains 'docs/delegate-jobs.md:3:' 'DOC match includes doc location'

reset_case
run_fg 77 --paths docs/tui.md --removes assert_line --dry
assert_rc 0 'removed symbol test pin is a warning'
assert_line 'TEST assert_line' 'test-pin heading'
assert_contains 'suggested --paths test/fence-grant.sh' 'test-pin suggested path'

reset_case
write_blob docs/events.md $'## Delivery\n'
set_pr 11 fix/docs docs/events.md
cat >"$T/pr/11.diff" <<'DIFF'
diff --git a/docs/events.md b/docs/events.md
index 1111111..2222222 100644
--- a/docs/events.md
+++ b/docs/events.md
@@ -1,2 +1,2 @@ ## Delivery
-old body
+new body
DIFF
run_fg 77 --paths docs/tui.md --doc-heading 'docs/events.md#Delivery' --dry
assert_rc 0 'cited doc heading warning does not hold grant'
assert_line 'WARN PR #11 touches cited doc heading docs/events.md#Delivery' 'cited heading warning'
assert_line 'WOULD-GRANT docs/tui.md' 'heading warning keeps unrelated grant free'

reset_case
write_blob docs/events.md $'## `unsafe`\n'
set_pr 11 fix/docs docs/events.md
cat >"$T/pr/11.diff" <<'DIFF'
diff --git a/docs/events.md b/docs/events.md
index 1111111..2222222 100644
@@ -1,2 +1,2 @@
-## `unsafe`
+## `unsafe`
DIFF
run_fg 77 --paths docs/tui.md --doc-heading 'docs/events.md#unsafe' --dry
assert_rc 0 'backticked cited doc heading matches its anchor'
assert_line 'WARN PR #11 touches cited doc heading docs/events.md#unsafe' 'backticked heading warning'

reset_case
write_blob docs/events.md $'## intro\n'
run_fg 77 --paths docs/tui.md --doc-heading 'docs/events.md#unsafe' --dry
assert_rc 2 'missing cited doc heading'
assert_out 'ERROR doc heading not found: docs/events.md#unsafe' 'missing cited doc heading output'
assert_stderr '' 'missing cited doc heading stderr'
assert_no_grant 'missing cited doc heading'
! grep -q 'pr list' "$T/gh.log" || fail 'missing cited doc heading runs no PR or claim probes'
[ ! -s "$T/file-claim.log" ] || fail 'missing cited doc heading skips file-claim'
[ ! -s "$T/claude.log" ] || fail 'missing cited doc heading skips lane probes'
[ ! -s "$T/ssh.log" ] || fail 'missing cited doc heading skips box probes'

reset_case
GH_PRLIST='[{"number":11,"headRefName":"fix/one"},{"number":12,"headRefName":"fix/two"}]'
export GH_PRLIST
printf '%s\n' crates/main/src/a.rs crates/main/src/b.rs docs/tui.md >"$T/pr/11.names"
printf '%s\n' crates/tui/src/a.rs >"$T/pr/12.names"
run_fg 77 --pre-plan 'crates/main/**'
assert_rc 0 'pre-plan reports open PR path counts'
assert_line 'WARN PRE-PLAN PR #11: 2 files under crates/main/**' 'pre-plan matching PR count'
assert_line 'WARN PRE-PLAN PR #12: 0 files under crates/main/**' 'pre-plan zero count'
! grep -q 'git/trees/' "$T/gh.log" || fail 'pre-plan skips path existence probes'

reset_case
run_fg 77 --paths=docs/tui.md --dry
assert_rc 0 'paths equals form'
assert_out "$(printf 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/tui.md\nWOULD-GRANT')" 'paths equals output'

reset_case
run_fg 77 --paths='docs/{tui,tui}.md' --dry
assert_rc 0 'duplicate brace expansion'
assert_out "$(printf 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/tui.md\nWOULD-GRANT docs/tui.md\nWOULD-GRANT')" 'duplicate brace output'

reset_case
run_fg 77 --paths='crates/tui/src/turn/{group,group_tests}.rs' --dry
assert_rc 0 'multiple brace expansion'
assert_out "$(printf 'WIDE crates/tui/src/turn/group.rs is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWIDE crates/tui/src/turn/group_tests.rs is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT crates/tui/src/turn/group.rs\nWOULD-GRANT crates/tui/src/turn/group_tests.rs\nWOULD-GRANT')" 'multiple brace output'

reset_case
run_fg 77 --paths docs/tui.md --ranges 'docs/{tui,tui}.md:1-2' --dry
assert_rc 0 'ranges brace expansion'

reset_case
run_fg 77 --paths='crates/new/{one,two}.rs' '--new=crates/new/{one,two}.rs' --dry
assert_rc 0 'new paths brace expansion'
assert_out "$(printf 'WIDE crates/new/one.rs is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWIDE crates/new/two.rs is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT crates/new/one.rs\nWOULD-GRANT crates/new/two.rs\nWOULD-GRANT')" 'new path output'

reset_case
write_blob docs/tui.md 'needle\n'
set_pr 11 fix/other docs/tui.md
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/tui.md --ranges=docs/tui.md:1-5 --expect=docs/tui.md:1:needle --ignore-pr=11 --ignore-ticket=77
assert_rc 0 'combined equals forms'
assert_out "$(printf 'GRANT docs/tui.md\nGRANT')" 'combined equals forms output'
grep -qxF 'Ranges: docs/tui.md:1-5' "$FW_RUN/fiber-88-fence-grant-1.md" || fail 'equals ranges recorded'

reset_case
run_fg 77 --paths docs/tui.md --reads='docs/{x}.md' --dry
assert_rc 0 'reads equals form and literal braces'
assert_out "$(printf 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/tui.md\nREAD docs/{x}.md\nWOULD-GRANT')" 'reads brace stays literal'

reset_case
run_fg 77 --paths docs/tui.md --reads=docs/x.md
assert_rc 0 'reads writes grant file'
assert_out "$(printf 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nGRANT docs/tui.md\nREAD docs/x.md\nGRANT')" 'reads output order'
tail -n 2 "$FW_RUN/fiber-77-fence-grant-1.md" >"$T/reads-tail"
[ "$(cat "$T/reads-tail")" = "$(printf 'Reads:\n- docs/x.md')" ] || fail 'Reads is the final grant-file section'

# A read in a live lane grant stops the hold probe at the exact Reads: line.
reset_case
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/other.md\n\nReads:\n- docs/events.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/events.md --dry
assert_rc 0 'read path does not hold'
assert_out "$(printf 'WIDE docs/events.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/events.md\nWOULD-GRANT')" 'read path output'

reset_case
run_fg 77 --paths crates/tui/ --dry
assert_rc 0 'existing directory path'
assert_out "$(printf 'WIDE crates/tui/ is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT crates/tui/\nWOULD-GRANT')" 'directory path output'

# --- Exit 0: ordinary open-PR overlaps are advisory --------------------------
reset_case
set_pr 11 fix/other docs/tui.md
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'open PR overlap is advisory'
assert_out "$(printf 'OVERLAP docs/tui.md PR #11\nWIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/tui.md\nWOULD-GRANT')" 'open PR overlap output'
assert_no_grant 'open PR overlap dry run'

# --- Exit 1: exclusive sweep claim remains held -------------------------------
reset_case
FILE_CLAIM_LIST=$(printf 'docs/tui.md\tsweep-4226\tplan\t0\tt:stub\t\n')
export FILE_CLAIM_LIST
run_fg 77 --paths docs/tui.md --dry
assert_rc 1 'sweep claim remains exclusive'
assert_out 'HELD docs/tui.md by lane sweep-4226' 'sweep claim output'
log="$FW_RUN/fence-grant-refusals.tsv"
[ "$(wc -l <"$log" | tr -d ' ')" = 1 ] || fail 'dry refusal writes one log row'
IFS="$(printf '\t')" read -r logged_at logged_ticket logged_kind logged_path logged_holder logged_age <"$log"
[[ "$logged_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "refusal timestamp is UTC ISO 8601: $logged_at"
[ "$logged_ticket|$logged_kind|$logged_path|$logged_holder|$logged_age" = '77|DRY-REFUSE|docs/tui.md|lane sweep-4226|0' ] || fail 'dry refusal row fields'
assert_no_grant 'sweep claim'

reset_case
FILE_CLAIM_MODE=refuse
FILE_CLAIM_LIST=$(printf 'docs\tfiber-77\tplan\t17\tt:stub\t\n')
export FILE_CLAIM_MODE FILE_CLAIM_LIST
run_fg 77 --paths docs/tui.md
assert_rc 1 'file-claim refusal remains a refusal for child path'
assert_line 'HELD docs/tui.md by lane #77' 'file-claim refusal output'
[ "$(cut -f2- "$FW_RUN/fence-grant-refusals.tsv")" = "$(printf '77\tREFUSE\tdocs/tui.md\tlane #77\t17')" ] || fail 'directory claim age is logged for file-claim refusal'

reset_case
FILE_CLAIM_LIST=$(printf 'docs\tsweep-4226\tplan\t17\tt:stub\t\n')
export FILE_CLAIM_LIST
run_fg 77 --paths docs/tui.md --dry
assert_rc 1 'directory sweep claim remains exclusive for child path'
assert_out 'HELD docs/tui.md by lane sweep-4226' 'directory sweep claim output'
[ "$(cut -f2- "$FW_RUN/fence-grant-refusals.tsv")" = "$(printf '77\tDRY-REFUSE\tdocs/tui.md\tlane sweep-4226\t17')" ] || fail 'directory claim age is logged for held child path'

reset_case
FILE_CLAIM_LIST=$(printf 'docs/tui.md\tsweep-4226\tplan\t17\tt:stub\t\n')
export FILE_CLAIM_LIST
run_fg 77 --paths docs/tui.md
assert_rc 1 'non-dry sweep refusal stays held'
assert_out 'HELD docs/tui.md by lane sweep-4226' 'non-dry sweep refusal output'
[ "$(cut -f2- "$FW_RUN/fence-grant-refusals.tsv")" = "$(printf '77\tREFUSE\tdocs/tui.md\tlane sweep-4226\t17')" ] || fail 'non-dry refusal row and holder age'
assert_no_grant 'non-dry sweep refusal'

reset_case
FILE_CLAIM_LIST=$(printf 'docs/tui.md\tsweep-4226\tplan\t17\tt:stub\t\n')
export FILE_CLAIM_LIST
mkdir "$FW_RUN/fence-grant-refusals.tsv"
run_fg 77 --paths docs/tui.md --dry
assert_rc 1 'refusal log failure stays held'
assert_out 'HELD docs/tui.md by lane sweep-4226' 'refusal log failure output'
assert_no_grant 'refusal log failure'

reset_case
FILE_CLAIM_LIST=$(printf 'docs/tui.md\tsweep-4226\tplan\t0\tt:stub\t\n')
export FILE_CLAIM_LIST
run_fg 4226 --paths docs/tui.md --dry
assert_rc 1 'same-ticket sweep claim remains exclusive'
assert_out 'HELD docs/tui.md by lane sweep-4226' 'same-ticket sweep claim output'

reset_case
FILE_CLAIM_LIST=$(printf 'docs/tui.md\tsweep-4226\tplan\t0\tt:stub\t\n')
export FILE_CLAIM_LIST
run_fg 77 --paths docs/tui.md --ignore-ticket 4226 --dry
assert_rc 1 'ignored-ticket sweep claim remains exclusive'
assert_out 'HELD docs/tui.md by lane sweep-4226' 'ignored-ticket sweep claim output'

reset_case
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\nRanges: none\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'live lane overlap is advisory'
assert_line 'OVERLAP docs/tui.md lane #77' 'live lane overlap output'
assert_line 'WOULD-GRANT docs/tui.md' 'live lane overlap grants'

reset_case
printf 'Files granted: docs/tui.md\n' >"$FW_RUN/fiber-77-notes.md"
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'notes-only lane overlap is advisory'
assert_line 'OVERLAP docs/tui.md lane #77' 'notes overlap source'
assert_line 'WOULD-GRANT docs/tui.md' 'notes overlap grants'

reset_case
printf 'Files granted: docs/tui.md\n' >"$FW_RUN/fiber-77-notes.md"
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'matching note and grant overlap is advisory'
assert_line 'OVERLAP docs/tui.md lane #77' 'deduplicated ordinary lane overlap'
[ "$(grep -c '^OVERLAP docs/tui.md lane #77$' "$T/out")" = 1 ] || fail 'matching note and grant overlap prints once'
assert_line 'WOULD-GRANT docs/tui.md' 'matching note and grant grants'

reset_case
cat >"$FW_RUN/fiber-77-fence-grant-1.md" <<'GRANT'
Grant 1

Ticket: 77
Paths:
- crates/a/tests.rs
- crates/b/tests.rs
- crates/c/tests.rs
Ranges: none

## Ruling
The refused `crates/d/tests.rs` sits in `crates/`.
GRANT
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths crates/d/tests.rs --dry
assert_rc 0 'headed grant prose does not hold a refused file'

reset_case
printf 'Grant 1\n\nTicket: 77\nThis hand-written fence grants docs/tui.md.\n\nReads:\n- docs/events.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'hand-written grant overlap is advisory'
assert_line 'OVERLAP docs/tui.md lane #77' 'legacy grant overlap'
assert_line 'WOULD-GRANT docs/tui.md' 'legacy grant overlap grants'

reset_case
printf 'Grant 1\n\nTicket: 77\nPart: 1\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
printf 'Grant 2\n\nTicket: 77\nPart: 2\nPaths:\n- docs/events.md\n' >"$FW_RUN/fiber-77-fence-grant-2.md"
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'part-1 grant does not hold part-2 lane'
assert_out "$(printf 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/tui.md\nWOULD-GRANT')" 'part-specific grant output'

reset_case
run_fg 77 --paths docs/tui.md --part 2
assert_rc 0 'part-2 grant write'
grep -qxF 'Part: 2' "$FW_RUN/fiber-77-fence-grant-1.md" || fail 'grant file records its part'

reset_case
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\nRanges: docs/tui.md:3700-3710\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/tui.md --ranges docs/tui.md:192-200 --dry
assert_rc 0 'ranged grant frees outside window'
assert_out "$(printf 'WOULD-GRANT docs/tui.md\nWOULD-GRANT')" 'outside window output'

reset_case
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\nRanges: docs/tui.md:3700-3710\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/tui.md --ranges docs/tui.md:3705-3706 --dry
assert_rc 0 'ranged grant overlap is advisory'
assert_line 'OVERLAP docs/tui.md lane #77' 'overlapping window output'
assert_line 'WOULD-GRANT docs/tui.md' 'overlapping ranged grant grants'

reset_case
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'fresh orphan grant overlap is advisory'
assert_line 'OVERLAP docs/tui.md lane #77' 'fresh orphan overlap output'
assert_line 'WOULD-GRANT docs/tui.md' 'fresh orphan overlap grants'
assert_not_contains 'mv ' 'fresh orphan has no destructive remedy'
grep -qxF 'list --lane fiber-77 --repo aakshintala/fiber' "$T/file-claim.log" || fail 'orphan liveness checks lane claims'

reset_case
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
FILE_CLAIM_LIST=$(printf 'docs/events.md\tfiber-77\tplan\t0\tt:stub\t\n')
export FILE_CLAIM_LIST
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'orphan grant with claims is advisory'
assert_line 'OVERLAP docs/tui.md lane #77' 'orphan grant overlap output'
assert_line 'WOULD-GRANT docs/tui.md' 'orphan grant overlap grants'
assert_not_contains 'NO LIVE LANE' 'orphan grant with claims is not dead'

reset_case
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
touch -t 202001010000 "$FW_RUN/fiber-77-fence-grant-1.md"
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'old orphan grant expires'
assert_out "$(printf 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/tui.md\nWOULD-GRANT')" 'old orphan output'

reset_case
sleep 300 &
PI_PID=$!
printf '%s\n' "$PI_PID" >"$FW_RUN/fiber-77-pi.pid"
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'live Mac pi lane overlap is advisory'
assert_line 'OVERLAP docs/tui.md lane #77' 'Mac pi lane overlap output'
assert_line 'WOULD-GRANT docs/tui.md' 'Mac pi lane overlap grants'
kill "$PI_PID" 2>/dev/null || true
PI_PID=""

reset_case
printf 'Grant 1\n\nTicket: 88\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-88-fence-grant-1.md"
SSH_OUT=$'FWSEC=UPTIME\nFWSEC=AGENTS\n[]\nFWSEC=DELEGATE\nDELEGATEOK\nFWSEC=DSESS\n{"ok":true,"sessions":[]}\nDSESSJSONOK\nFWSEC=PILANES\nfiber-88\nPILANESOK\nFWSEC=END'
export SSH_OUT
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'live box pi lane overlap is advisory'
assert_line 'OVERLAP docs/tui.md lane #88' 'box pi lane overlap output'
assert_line 'WOULD-GRANT docs/tui.md' 'box pi lane overlap grants'

reset_case
sleep 300 &
DJ_PID=$!
write_delegate_job job-a RUNNING "$DJ_PID" /w/fiber-worktrees/tests/77-grid-read-ratchet
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
run_fg 88 --paths docs/tui.md --dry
kill "$DJ_PID" 2>/dev/null || true
assert_rc 0 'live Mac delegate lane overlap is advisory'
assert_line 'OVERLAP docs/tui.md lane #77' 'Mac delegate lane overlap output'
assert_line 'WOULD-GRANT docs/tui.md' 'Mac delegate lane overlap grants'

reset_case
unset FW_DELEGATE_DIR
sleep 300 &
DJ_PID=$!
write_delegate_job job-a RUNNING "$DJ_PID" /w/fiber-worktrees/tests/77-grid-read-ratchet
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-77\tgrant\t0\tt:stub\t\n')"
export FILE_CLAIM_LIST
run_fg 88 --paths docs/tui.md --dry
kill "$DJ_PID" 2>/dev/null || true
assert_rc 0 'Mac delegate probe reads under TMPDIR by default'
assert_line 'OVERLAP docs/tui.md lane #77' 'TMPDIR delegate lane overlap output'
assert_not_contains 'STALE' 'TMPDIR delegate claim is not stale'

reset_case
sleep 300 &
DJ_PID=$!
write_delegate_job job-a DONE "$DJ_PID" /w/fiber-worktrees/tests/77-grid-read-ratchet
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
touch -t 202001010000 "$FW_RUN/fiber-77-fence-grant-1.md"
run_fg 88 --paths docs/tui.md --dry
kill "$DJ_PID" 2>/dev/null || true
assert_rc 0 'finished delegate job holds nothing'
assert_out "$(printf 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/tui.md\nWOULD-GRANT')" 'finished delegate job output'

reset_case
sleep 300 &
DJ_PID=$!
write_delegate_job job-a RUNNING "$DJ_PID" /w/fiber-worktrees/tests/77-grid-read-ratchet
printf '%s\n' "$DJ_PID" >"$FW_RUN/fiber-77-pi.pid"
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
run_fg 88 --paths docs/tui.md --dry
kill "$DJ_PID" 2>/dev/null || true
assert_rc 0 'lane in both sources overlaps once'
assert_line 'OVERLAP docs/tui.md lane #77' 'deduplicated overlap output'
[ "$(grep -c '^OVERLAP docs/tui.md lane #77$' "$T/out")" = 1 ] || fail 'a lane in both sources prints one overlap'
assert_line 'WOULD-GRANT docs/tui.md' 'deduplicated overlap grants'

reset_case
write_delegate_job job-a RUNNING 2147483646 /w/fiber-worktrees/tests/77-grid-read-ratchet
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
touch -t 202001010000 "$FW_RUN/fiber-77-fence-grant-1.md"
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'dead delegate supervisor holds nothing'
assert_out "$(printf 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/tui.md\nWOULD-GRANT')" 'dead delegate supervisor output'

reset_case
printf 'Grant 1\n\nTicket: 88\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-88-fence-grant-1.md"
SSH_OUT=$'FWSEC=UPTIME\nFWSEC=AGENTS\n[]\nFWSEC=DELEGATE\nfiber-88\nDELEGATEOK\nFWSEC=DSESS\n{"ok":true,"sessions":[]}\nDSESSJSONOK\nFWSEC=PILANES\nPILANESOK\nFWSEC=END'
export SSH_OUT
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'live box delegate lane overlap is advisory'
assert_line 'OVERLAP docs/tui.md lane #88' 'box delegate lane overlap output'
assert_line 'WOULD-GRANT docs/tui.md' 'box delegate lane overlap grants'

reset_case
write_blob docs/tui.md $'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n'
set_pr 11 fix/other docs/tui.md
cat >"$T/pr/11.diff" <<'DIFF'
diff --git a/docs/tui.md b/docs/tui.md
index 1111111..2222222 100644
--- a/docs/tui.md
+++ b/docs/tui.md
@@ -3,2 +3,2 @@
-three
+THREE
@@ -8 +8 @@
-eight
+EIGHT
DIFF
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'whole-file PR overlap is advisory'
assert_line 'OVERLAP docs/tui.md PR #11' 'whole-file PR overlap line'
assert_line 'WOULD-GRANT docs/tui.md' 'whole-file PR overlap grants'

reset_case
set_pr 11 fix/other docs/tui.md
cat >"$T/pr/11.diff" <<'DIFF'
diff --git a/docs/tui.md b/docs/tui.md
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/docs/tui.md
@@ -0,0 +1,1 @@
+new
DIFF
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'PR-added file overlap is advisory'
assert_line 'OVERLAP docs/tui.md PR #11' 'PR-added file overlap line'
assert_line 'WOULD-GRANT docs/tui.md' 'PR-added file overlap grants'

reset_case
set_pr 11 fix/other docs/tui.md
cat >"$T/pr/11.diff" <<'DIFF'
diff --git a/docs/tui.md b/docs/tui.md
index 1111111..2222222 100644
--- a/docs/tui.md
+++ b/docs/tui.md
@@ -3,2 +3,2 @@
-three
+THREE
DIFF
run_fg 77 --paths docs/tui.md --ranges docs/tui.md:1-2 --dry
assert_rc 0 'requested range outside PR hunk'
assert_out "$(printf 'WOULD-GRANT docs/tui.md\nWOULD-GRANT')" 'non-overlap range output'
reset_case
set_pr 11 fix/other docs/tui.md
cat >"$T/pr/11.diff" <<'DIFF'
diff --git a/docs/tui.md b/docs/tui.md
index 1111111..2222222 100644
--- a/docs/tui.md
+++ b/docs/tui.md
@@ -3,2 +3,2 @@
-three
+THREE
DIFF
run_fg 77 --paths docs/tui.md --ranges docs/tui.md:3-4 --dry
assert_rc 0 'requested range may overlap PR hunk'
assert_line 'OVERLAP docs/tui.md PR #11' 'overlapping range overlap line'
assert_line 'WOULD-GRANT docs/tui.md' 'overlapping range grants'

reset_case
set_pr 11 fix/other docs/tui.md
run_fg 77 --paths docs/tui.md --ignore-pr 11 --dry
assert_rc 0 'ignore PR holder'
assert_out "$(printf 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/tui.md\nWOULD-GRANT')" 'ignore PR output'
reset_case
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/tui.md --ignore-ticket 77 --dry
assert_rc 0 'ignore ticket holder'
assert_out "$(printf 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/tui.md\nWOULD-GRANT')" 'ignore ticket output'
reset_case
printf 'Grant 1\n\nTicket: 66\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-66-fence-grant-1.md"
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
CLAUDE_JSON='[{"name":"fiber-66","status":"busy"},{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/tui.md --ignore-ticket 66 --ignore-ticket 77 --dry
assert_rc 0 'multiple ignored tickets'
assert_line 'WOULD-GRANT docs/tui.md' 'multiple ignored tickets output'

reset_case
set_pr 11 fix/other docs/tui.md
GH_PRLIST='[{"number":11,"headRefName":"fix/other"},{"number":12,"headRefName":"fix/another"}]'
export GH_PRLIST
printf '%s\n' docs/tui.md >"$T/pr/12.names"
printf 'diff --git a/docs/tui.md b/docs/tui.md\nindex 1111111..2222222 100644\n' >"$T/pr/12.diff"
run_fg 77 --paths docs/tui.md --ignore-pr 11 --ignore-pr 12 --dry
assert_rc 0 'multiple ignored PRs'
assert_line 'WOULD-GRANT docs/tui.md' 'multiple ignored PRs output'

reset_case
set_pr 11 x/77-slug docs/tui.md
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'own ticket PR skipped'
assert_out "$(printf 'OWN skipping PR #11: its branch names ticket 77\nWIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/tui.md\nWOULD-GRANT')" 'own PR output'
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'same PR overlap is advisory for another ticket'
assert_line 'OVERLAP docs/tui.md PR #11' 'other ticket sees PR overlap'
assert_line 'WOULD-GRANT docs/tui.md' 'other ticket gets grant'

reset_case
GH_PRLIST='[{"number":11}]'
export GH_PRLIST
printf '%s\n' docs/tui.md >"$T/pr/11.names"
printf 'diff --git a/docs/tui.md b/docs/tui.md\n' >"$T/pr/11.diff"
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'PR without branch name overlaps but is not own'
assert_line 'OVERLAP docs/tui.md PR #11' 'missing branch name overlap'

# A correct existing path and symbol still goes through the holder sweep.
reset_case
write_blob docs/tui.md 'needle\n'
set_pr 11 fix/other docs/tui.md
run_fg 77 --paths docs/tui.md --expect docs/tui.md:1:needle --dry
assert_rc 0 'valid expect still checks then grants an overlap'
assert_not_contains 'NOSYMBOL' 'valid expect accepted'
assert_line 'OVERLAP docs/tui.md PR #11' 'valid expect overlap'

# --- Exit 2: bad arguments -----------------------------------------------------
USAGE='usage: fence-grant <ticket> --paths <comma list> [--ranges <file:start-end,...>] [--reads <comma list>] [--new <comma list>] [--expect <file:line:symbol,...>] [--repo <owner/name>] [--part <n>] [--ignore-pr <n>] [--ignore-ticket <n>] [--swept-to <comment id>] [--removes <symbol,...>] [--doc-heading <docs/file.md#heading> (review warning, not a grant)] [--pre-plan <path-shape>] [--dry] | --require <ticket> --phase plan|build|ship
       non-sweep holds are advisory overlaps; sweep-* file claims remain exclusive'
reset_case
run_fg
assert_usage 'missing ticket'
reset_case
run_fg 12a --paths docs/tui.md
assert_usage 'non-digit ticket'
reset_case
run_fg 77 --dry
assert_usage 'missing paths'
reset_case
run_fg 77 --paths
assert_usage 'missing paths value'
reset_case
run_fg 77 --paths docs/tui.md --unknown
assert_usage 'unknown flag'
reset_case
run_fg 77 --paths docs/tui.md --part two
assert_usage 'non-numeric part'
reset_case
run_fg 77 --paths docs/tui.md --ignore-ticket nope
assert_usage 'non-numeric ignored ticket'
reset_case
run_fg 77 --paths docs/tui.md --ignore-pr nope
assert_usage 'non-numeric ignored PR'

reset_case
run_fg 77 --paths docs/tui.md --ranges docs/events.md:1-3
assert_rc 2 'range outside paths'
assert_out 'ERROR --ranges names docs/events.md which is not under --paths' 'range outside paths output'
assert_stderr '' 'range outside paths stderr'
assert_no_grant 'range outside paths'

reset_case
run_fg 77 --paths docs/tui.md:310-372 --dry
assert_rc 2 'paths with line range'
assert_out '' 'paths with line range stdout'
assert_stderr 'ERROR a line range belongs in --ranges, not --paths: docs/tui.md:310-372' 'paths with line range stderr'
assert_no_probes 'paths with line range'
assert_no_grant 'paths with line range'
reset_case
run_fg 77 --paths docs/tui.md --ranges docs/tui.md:one-3
assert_usage 'non-numeric range'
reset_case
run_fg 77 --paths docs/tui.md --ranges docs/tui.md:4-3
assert_usage 'reversed range'
reset_case
run_fg 77 --paths docs/tui.md --expect docs/tui.md:needle
assert_rc 2 'expect without line'
assert_out '' 'expect without line stdout'
assert_stderr "$USAGE" 'expect without line usage'
assert_no_grant 'expect without line'

for bad_repo in '' noslash a/b/c /x x/; do
  reset_case
  run_fg 77 --paths docs/tui.md --repo "$bad_repo"
  assert_usage "invalid repo $bad_repo"
done
reset_case
run_fg 77 --paths docs/tui.md --repo
assert_usage 'missing repo value'

# --- Exit 3: each failed or unparseable probe fails closed --------------------
reset_case
GH_SHA_FAIL=1
run_fg 77 --paths docs/tui.md
assert_error 'tree SHA lookup failure' 'ERROR gh tree SHA main sha stub failure '
! grep -q 'git/trees/' "$T/gh.log" || fail 'failed SHA lookup fetches no tree'

reset_case
GH_SHA_FAIL=1 GH_SHA_ERROR='API rate limit exceeded'
run_fg 77 --paths docs/tui.md
assert_error 'tree SHA rate limit' 'ERROR gh tree SHA main API rate limit exceeded '

reset_case
GH_TREE_FAIL=1 GH_TREE_ERROR='API rate limit exceeded'
rm -rf "$FW_TREE_CACHE"
run_fg 77 --paths docs/tui.md
assert_error 'tree fetch rate limit' 'ERROR gh trees main API rate limit exceeded '
[ ! -e "$FW_TREE_CACHE/aaaaaaaa.tree" ] || fail 'rate limited fetch leaves cache entry'

reset_case
GH_TREE_FAIL=1
export GH_TREE_FAIL
rm -rf "$FW_TREE_CACHE"
run_fg 77 --paths docs/tui.md
assert_error 'tree fetch failure' 'ERROR gh trees main tree stub failure '

reset_case
GH_TREE_JSON='not-json'
export GH_TREE_JSON
rm -rf "$FW_TREE_CACHE"
run_fg 77 --paths docs/tui.md
assert_error 'unparseable tree' 'ERROR tree of main unreadable or truncated'
[ ! -e "$FW_TREE_CACHE/aaaaaaaa.tree" ] || fail 'unparseable tree leaves cache entry'

reset_case
GH_TREE_JSON='{"truncated":true,"tree":[{"type":"blob","path":"docs/tui.md"}]}'
export GH_TREE_JSON
rm -rf "$FW_TREE_CACHE"
run_fg 77 --paths docs/tui.md
assert_error 'truncated tree' 'ERROR tree of main unreadable or truncated'
[ ! -e "$FW_TREE_CACHE/aaaaaaaa.tree" ] || fail 'truncated tree leaves cache entry'

reset_case
GH_TREE_JSON='{"truncated":false,"tree":[]}'
export GH_TREE_JSON
rm -rf "$FW_TREE_CACHE"
run_fg 77 --paths docs/tui.md
assert_error 'empty tree' 'ERROR tree of main is empty'

reset_case
write_blob docs/tui.md 'needle\n'
GH_BLOB_FAIL=1
export GH_BLOB_FAIL
run_fg 77 --paths docs/tui.md --expect docs/tui.md:1:needle
assert_error 'contents fetch failure' 'ERROR gh contents docs/tui.md blob stub failure '

reset_case
GH_PRLIST_FAIL=1
export GH_PRLIST_FAIL
run_fg 77 --paths docs/tui.md
assert_error 'PR list failure' 'ERROR gh pr list pr list stub failure '

reset_case
GH_PRLIST='not-json'
export GH_PRLIST
run_fg 77 --paths docs/tui.md
assert_error 'unparseable PR list' 'ERROR gh pr list '

reset_case
{
  printf '['
  i=1
  while [ "$i" -le 200 ]; do
    [ "$i" -eq 1 ] || printf ','
    printf '{"number":%s,"headRefName":"other"}' "$i"
    i=$((i + 1))
  done
  printf ']'
} >"$T/prlist-200.json"
GH_PRLIST_JSON="$(cat "$T/prlist-200.json")"
export GH_PRLIST_JSON
run_fg 77 --paths docs/tui.md
assert_error 'PR list reaches 200-entry limit' 'ERROR gh pr list truncated at 200'

reset_case
set_pr 11 fix/other docs/tui.md
GH_DIFFN_FAIL=11
export GH_DIFFN_FAIL
run_fg 77 --paths docs/tui.md
assert_error 'PR names fetch failure' 'ERROR gh pr diff 11 pr names stub failure '

reset_case
set_pr 11 fix/other docs/tui.md
GH_DIFF_FAIL=11
export GH_DIFF_FAIL
run_fg 77 --paths docs/tui.md
assert_error 'full PR diff fetch failure' 'ERROR gh pr diff 11 pr diff stub failure '

reset_case
printf '[{"number":11,"headRefName":"fix/other"}]' >"$T/prlist"
GH_PRLIST="$(cat "$T/prlist")"
export GH_PRLIST
printf '%s\n' docs/tui.md >"$T/pr/11.names"
run_fg 77 --paths docs/tui.md
assert_error 'empty full PR diff' 'ERROR gh pr diff 11 '

reset_case
CLAUDE_FAIL=1
export CLAUDE_FAIL
run_fg 77 --paths docs/tui.md
assert_error 'Claude command failure' 'ERROR claude agents claude stub failure '

reset_case
CLAUDE_JSON='not-json'
export CLAUDE_JSON
run_fg 77 --paths docs/tui.md
assert_error 'unparseable Claude output' 'ERROR claude agents '

reset_case
SSH_FAIL=1
export SSH_FAIL
run_fg 77 --paths docs/tui.md
assert_error 'ssh command failure' 'ERROR ssh box ssh stub failure '

reset_case
SSH_OUT='broken markers'
export SSH_OUT
run_fg 77 --paths docs/tui.md
assert_error 'ssh output missing markers' 'ERROR ssh box '

reset_case
SSH_OUT=$'FWSEC=UPTIME\nFWSEC=AGENTS\n[]\nFWSEC=DELEGATE\nDELEGATEOK\nFWSEC=DSESS\n{"ok":true,"sessions":[]}\nDSESSJSONOK\nFWSEC=PILANES\nfiber-88\nFWSEC=END'
export SSH_OUT
run_fg 77 --paths docs/tui.md
assert_error 'box pi section missing marker' 'ERROR box pi lanes: no PILANESOK marker'

reset_case
rm -rf "$FW_RUN"
run_fg 77 --paths docs/tui.md
assert_error 'Mac pi probe missing run directory' 'ERROR mac pi lanes: run directory missing'

reset_case
SSH_OUT=$'FWSEC=UPTIME\nFWSEC=AGENTS\n[]\nFWSEC=DELEGATE\nfiber-88\nFWSEC=DSESS\n{"ok":true,"sessions":[]}\nDSESSJSONOK\nFWSEC=PILANES\nPILANESOK\nFWSEC=END'
export SSH_OUT
run_fg 77 --paths docs/tui.md
assert_error 'box delegate section missing marker' 'ERROR box delegate lanes: no DELEGATEOK marker'

reset_case
rm -rf "$T/delegate-jobs"
run_fg 77 --paths docs/tui.md
assert_error 'Mac delegate probe missing registry' 'ERROR mac delegate lanes: registry directory missing'

reset_case
mkdir "$FW_RUN/.fence-grant.lock"
FW_LOCK_TRIES=1 FW_LOCK_POLL=0 run_fg 77 --paths docs/tui.md
assert_error 'grant lock timeout' "ERROR cannot lock $FW_RUN/.fence-grant.lock"
reset_case
mkdir "$FW_RUN/.fence-grant.lock"
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'dry run ignores held lock'
assert_out "$(printf 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/tui.md\nWOULD-GRANT')" 'dry run with held lock output'
assert_no_grant 'dry run with held lock'

reset_case
mkdir -p "$T/missing-parent"
ln -s "$T/missing-parent/no-such-dir/grant.md" "$FW_RUN/fiber-77-fence-grant-1.md"
run_fg 77 --paths docs/tui.md
assert_rc 3 'grant write failure'
assert_out "ERROR cannot write $FW_RUN/fiber-77-fence-grant-1.md" 'grant write failure output'
[ -z "$(find "$FW_RUN" -type f -name 'fiber-*-fence-grant*.md' -print)" ] || fail 'grant write failure: wrote regular grant file'
[ -L "$FW_RUN/fiber-77-fence-grant-1.md" ] || fail 'write failure symlink fixture remains'

# --- Exit 4: invalid grant meaning and suggestions ---------------------------
reset_case
run_fg 77 --paths crates/turn/src/group.rs,crates/turn/src/group_tests.rs --dry
assert_rc 4 'missing paths suggestions'
assert_out "$(printf 'MISSING crates/turn/src/group.rs\n  did you mean: crates/tui/src/turn/group.rs\nMISSING crates/turn/src/group_tests.rs\n  did you mean: crates/tui/src/turn/group_tests.rs\nNO PROBE: 2 paths missing, no hold check ran; move them to --new')" 'missing path suggestion output'
assert_no_grant 'missing paths suggestions'

reset_case
set_pr 11 fix/other docs/tui.md
run_fg 77 --paths crates/turn/src/new.rs,docs/tui.md --new crates/turn/src/new.rs --dry
assert_rc 0 'new path accepted before advisory PR overlap'
assert_not_contains 'MISSING' 'new path is not missing'
assert_line 'OVERLAP docs/tui.md PR #11' 'other path overlaps PR'
assert_line 'WOULD-GRANT docs/tui.md' 'other path is granted'

reset_case
GH_TREE_JSON='{"truncated":false,"tree":[{"type":"blob","path":"crates/extensions/src/process/tests.rs"},{"type":"blob","path":"crates/extensions/src/process_tests.rs"}]}'
export GH_TREE_JSON
rm -rf "$FW_TREE_CACHE"
write_blob crates/extensions/src/process/tests.rs "$(python3 -c 'print("quiet\n" * 3153 + "other\n", end="")')"
write_blob crates/extensions/src/process_tests.rs "$(python3 -c 'print("quiet\n" * 3153 + "envelope_line\n", end="")')"
run_fg 77 --paths crates/extensions/src/process/tests.rs --expect crates/extensions/src/process/tests.rs:3154:envelope_line --dry
assert_rc 4 'expected symbol absent'
assert_out "$(printf 'NOSYMBOL crates/extensions/src/process/tests.rs:3154 does not hold envelope_line\n  did you mean: crates/extensions/src/process_tests.rs:3154\nNO PROBE: 1 path or symbol missing, no hold check ran; correct missing --paths/--expect entries')" 'NOSYMBOL suggestion output'
grep -qF 'contents/crates/extensions/src/process/tests.rs?ref=main' "$T/gh.log" || fail 'original blob fetched'
grep -qF 'contents/crates/extensions/src/process_tests.rs?ref=main' "$T/gh.log" || fail 'alternate blob fetched'
! cmp -s "$T/blobs/crates/extensions/src/process/tests.rs" "$T/blobs/crates/extensions/src/process_tests.rs" || fail 'same-basename fixture contents differ'
assert_no_grant 'expected symbol absent'
rm -rf "$FW_TREE_CACHE"

reset_case
write_blob crates/extensions/src/process/tests.rs "$(python3 -c 'print("quiet\n" * 3153 + "other\n", end="")')"
write_blob crates/extensions/src/process_tests.rs "$(python3 -c 'print("quiet\n" * 3153 + "envelope_line\n", end="")')"
for f in a b c d e; do write_blob "crates/$f/tests.rs" "$(python3 -c 'print("quiet\n" * 3153 + "envelope_line\n", end="")')"; done
run_fg 77 --paths crates/extensions/src/process/tests.rs --expect crates/extensions/src/process/tests.rs:3154:envelope_line --dry
assert_rc 4 'alternate suggestion sorts first'
[ "$(grep '^  did you mean:' "$T/out" | head -n 1)" = '  did you mean: crates/extensions/src/process_tests.rs:3154' ] || fail "spelling alternate did not sort first: $(cat "$T/out")"

reset_case
run_fg 77 --paths docs/tui.md --expect docs/missing.md:1:needle --dry
assert_rc 4 'expect file absent from tree'
assert_out "$(printf 'MISSING docs/missing.md\nNO PROBE: 1 path or symbol missing, no hold check ran; correct missing --paths/--expect entries')" 'missing expect file output'

reset_case
write_blob docs/tui.md 'needle\n'
run_fg 77 --paths docs/tui.md --expect docs/tui.md:1:needle --dry
assert_rc 0 'expected symbol present'
assert_out "$(printf 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/tui.md\nWOULD-GRANT')" 'expected symbol present output'

# --repo routes every gh call, including the expected-symbol content read.
reset_case
rm -rf "$FW_TREE_CACHE"
write_blob docs/tui.md 'needle\n'
set_pr 11 fix/other docs/tui.md
cat >"$T/pr/11.diff" <<'DIFF'
diff --git a/docs/tui.md b/docs/tui.md
index 1111111..2222222 100644
--- a/docs/tui.md
+++ b/docs/tui.md
@@ -1,1 +1,1 @@
-needle
+changed
DIFF
run_fg 77 --paths docs/tui.md --expect docs/tui.md:1:needle --repo other/x --dry
assert_rc 0 'repo routing through an overlapping PR'
grep -qF 'api repos/other/x/git/trees/aaaaaaaa?recursive=1' "$T/gh.log" || fail 'tree query uses --repo'
[ "$(grep -cF 'api repos/other/x/contents/docs/tui.md?ref=main' "$T/gh.log")" = 1 ] || fail 'expected-symbol content fetch uses --repo'
grep -qF 'pr list -R other/x ' "$T/gh.log" || fail 'PR list uses --repo'
grep -qF 'pr diff 11 -R other/x --name-only' "$T/gh.log" || fail 'PR names use --repo'
grep -qF 'pr diff 11 -R other/x --allow-escape-sequences' "$T/gh.log" || fail 'PR diff uses --repo'

reset_case
rm -rf "$FW_TREE_CACHE"
run_fg 77 --paths=docs/tui.md --repo=other/x --dry
assert_rc 0 '--repo equals form'
grep -qF 'api repos/other/x/git/trees/aaaaaaaa?recursive=1' "$T/gh.log" || fail 'repo equals form uses requested repo'

# --- WIDE: a path granted whole without ranges warns, non-blocking ---
reset_case
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'whole-file grant warns'
assert_line 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.' 'whole-file WIDE line'
assert_line 'WOULD-GRANT docs/tui.md' 'whole-file grant line'

reset_case
run_fg 77 --paths docs/tui.md
assert_rc 0 'whole-file grant writes file'
assert_line 'WIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.' 'whole-file WIDE line with file'
assert_line 'GRANT docs/tui.md' 'whole-file grant line with file'
[ -f "$FW_RUN/fiber-77-fence-grant-1.md" ] || fail 'whole-file grant file exists'
grep -qxF 'Ranges: none' "$FW_RUN/fiber-77-fence-grant-1.md" || fail 'whole-file grant file records no ranges'
grep -qxF -- '- docs/tui.md' "$FW_RUN/fiber-77-fence-grant-1.md" || fail 'whole-file grant file records the path'
! grep -qF 'WIDE' "$FW_RUN/fiber-77-fence-grant-1.md" || fail 'whole-file grant file holds no WIDE line'

reset_case
run_fg 77 --paths docs/tui.md --ranges docs/tui.md:1-5 --dry
assert_rc 0 'ranged grant is quiet'
assert_not_contains 'WIDE' 'ranged grant prints no WIDE'
assert_line 'WOULD-GRANT docs/tui.md' 'ranged grant line'

# --- The grant performs its claim: one ledger both fences read (#1101) ------
reset_case
run_fg 77 --paths docs/tui.md
assert_rc 0 'grant performs the claim'
grep -qxF 'claim --lane fiber-77 --plan --repo aakshintala/fiber -- docs/tui.md' "$T/file-claim.log" || fail 'claim args hold the granted path'
[ -f "$FW_RUN/fiber-77-fence-grant-1.md" ] || fail 'grant file still written'

reset_case
run_fg 77 --paths docs/tui.md --reads docs/x.md
assert_rc 0 'reads ride along unclaimed'
grep -qxF 'claim --lane fiber-77 --plan --repo aakshintala/fiber -- docs/tui.md' "$T/file-claim.log" || fail 'claim args hold only the granted path'
! grep -qF 'docs/x.md' "$T/file-claim.log" || fail 'a read is never claimed'

reset_case
set_pr 11 fix/other docs/tui.md
run_fg 77 --paths docs/tui.md --ignore-pr 11
assert_rc 0 'ignored PR stays ignored in the claim'
grep -qxF 'claim --lane fiber-77 --plan --repo aakshintala/fiber --self-pr 11 -- docs/tui.md' "$T/file-claim.log" || fail 'claim skips the ignored PR'

reset_case
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'dry run probes only'
grep -qxF 'list --repo aakshintala/fiber' "$T/file-claim.log" || fail 'dry run reads claims'
! grep -q '^claim ' "$T/file-claim.log" || fail 'dry run claims nothing'

reset_case
FILE_CLAIM_MODE=overlap
export FILE_CLAIM_MODE
run_fg 88 --paths docs/tui.md
assert_rc 0 'ledger overlap still grants'
assert_line 'OVERLAP docs/tui.md lane #66' 'ledger overlap output'
assert_line 'GRANT docs/tui.md' 'ledger overlap grant'
grep -qxF 'overlap: docs/tui.md lane #66' "$FW_RUN/fiber-88-fence-grant-1.md" || fail 'ledger overlap is recorded in grant'
[ -f "$FW_RUN/fiber-88-fence-grant-1.md" ] || fail 'ledger overlap grant file exists'

reset_case
FILE_CLAIM_MODE=overlap
export FILE_CLAIM_MODE
run_fg 88 --paths docs/tui.md,docs/events.md
assert_rc 0 'file-claim overlap still grants the full set'
assert_line 'OVERLAP docs/tui.md lane #66' 'file-claim overlap first path'
assert_line 'OVERLAP docs/events.md lane #66' 'file-claim overlap second path'
[ "$(grep -c '^overlap:' "$FW_RUN/fiber-88-fence-grant-1.md")" = 2 ] || fail 'file-claim overlap set is recorded in grant'
assert_line 'GRANT docs/tui.md' 'first file-claim overlap grant'
assert_line 'GRANT docs/events.md' 'second file-claim overlap grant'

reset_case
FILE_CLAIM_MODE=overlap
export FILE_CLAIM_MODE
run_fg 88 --paths docs/tui.md --ignore-ticket 66
assert_rc 0 'ignored ticket overlap from final claim still grants'
assert_not_contains 'OVERLAP docs/tui.md lane #66' 'ignored ticket is suppressed in final claim output'
! grep -q '^overlap: docs/tui.md lane #66$' "$FW_RUN/fiber-88-fence-grant-1.md" || fail 'ignored ticket is not recorded as an overlap'

reset_case
FILE_CLAIM_MODE=overlap-cap
export FILE_CLAIM_MODE
run_fg 88 --paths docs/tui.md --ignore-ticket 66
assert_rc 1 'grant cap remains held with an ignored overlap'
assert_not_contains 'OVERLAP docs/tui.md lane #66' 'ignored ticket is suppressed beside a cap refusal'
assert_line 'HELD docs/tui.md by file-claim grant cap' 'cap refusal remains visible beside ignored overlap'
assert_no_grant 'ignored overlap with cap refusal'

reset_case
FILE_CLAIM_MODE=cap
export FILE_CLAIM_MODE
run_fg 88 --paths docs/tui.md
assert_rc 1 'file-claim grant cap stays held'
assert_out 'HELD docs/tui.md by file-claim grant cap' 'grant cap refusal output'
[ "$(cut -f2- "$FW_RUN/fence-grant-refusals.tsv")" = "$(printf '88\tREFUSE\tdocs/tui.md\t-\t-')" ] || fail 'file-claim cap refusal uses explicit unknown holder and age placeholders'
assert_no_grant 'grant cap refusal'

reset_case
FILE_CLAIM_MODE=error
export FILE_CLAIM_MODE
run_fg 88 --paths docs/tui.md
assert_rc 3 'broken claim probe fails closed'
assert_out 'ERROR file-claim claim stub file-claim: boom ' 'broken claim output'
assert_no_grant 'broken claim'

# --- Own-PR exemption reaches the claim (#1101 P2) ---------------------------
reset_case
set_pr 11 x/77-slug docs/tui.md
run_fg 77 --paths docs/tui.md
assert_rc 0 'own PR hold does not refuse the own lane claim'
assert_contains 'OWN skipping PR #11' 'own PR skip printed'
grep -qxF 'claim --lane fiber-77 --plan --repo aakshintala/fiber --self-pr 11 -- docs/tui.md' "$T/file-claim.log" || fail 'claim exempts the own PR'
[ -f "$FW_RUN/fiber-77-fence-grant-1.md" ] || fail 'own-PR grant file exists'

# --- A live claim holds the whole path, including ranged requests ------------
reset_case
set_pr 11 fix/other docs/tui.md
cat >"$T/pr/11.diff" <<'DIFF'
diff --git a/docs/tui.md b/docs/tui.md
index 1111111..2222222 100644
--- a/docs/tui.md
+++ b/docs/tui.md
@@ -3,2 +3,2 @@
-three
+THREE
DIFF
run_fg 77 --paths docs/tui.md --ranges docs/tui.md:1-2
assert_rc 0 'ranged grant survives the ledger despite the open PR'
assert_line 'GRANT docs/tui.md' 'ranged grant line'
grep -qxF 'claim --lane fiber-77 --plan --repo aakshintala/fiber --self-pr 11 -- docs/tui.md' "$T/file-claim.log" || fail 'whole-file claim uses the file-claim contract'
grep -qxF 'Ranges: docs/tui.md:1-2' "$FW_RUN/fiber-77-fence-grant-1.md" || fail 'ranged grant file records the range'
rm "$FW_RUN/fiber-77-fence-grant-1.md"
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/tui.md --ranges docs/tui.md:5-6 --dry
assert_rc 0 'live whole-file claim overlap is advisory'
assert_line 'OVERLAP docs/tui.md lane #77' 'whole-file claim overlap output'
assert_line 'WOULD-GRANT docs/tui.md' 'whole-file claim allows ranged request'

reset_case
FILE_CLAIM_LIST=$(printf 'main_journeys.rs\tfiber-4226\tgrant\t0\tt:stub\t\n')
export FILE_CLAIM_LIST
CLAUDE_JSON='[{"name":"fiber-4226","status":"busy"}]'
export CLAUDE_JSON
run_fg 4278 --paths main_journeys.rs --ranges main_journeys.rs:539-539
assert_rc 0 'ranged grant overlaps #4226 whole-file claim'
assert_line 'OVERLAP main_journeys.rs lane #4226' 'whole-file claim overlap output'
assert_line 'GRANT main_journeys.rs' 'ranged overlap is granted'
grep -qxF 'overlap: main_journeys.rs lane #4226' "$FW_RUN/fiber-4278-fence-grant-1.md" || fail '#4226 overlap is recorded in the grant file'
grep -qxF 'Ranges: main_journeys.rs:539-539' "$FW_RUN/fiber-4278-fence-grant-1.md" || fail 'fiber#4278 range is recorded'

# --- Closed-ticket claims are stale even when their lane is live (#1313) -----
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-66\tgrant\t0\tt:stub\t\n')"
CLAUDE_JSON='[{"name":"fiber-66","status":"busy"}]'
GH_TICKET_STATES='66:CLOSED'
export FILE_CLAIM_LIST CLAUDE_JSON GH_TICKET_STATES
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'closed fiber claim does not hold'
assert_line 'STALE docs/tui.md by fiber-66 (ticket #66 closed)' 'closed fiber claim is stale'
assert_not_contains 'OVERLAP docs/tui.md lane #66' 'closed fiber claim does not overlap'
assert_line 'WOULD-GRANT docs/tui.md' 'closed fiber claim releases path'
[ "$(grep -c '^api graphql ' "$T/gh.log")" = 1 ] || fail 'closed fiber claim uses one ticket-state lookup'

# A branch-shaped claim is keyed to its ticket, not its holder name.
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tarch/66-log-diag-leaf\tgrant\t0\tt:stub\t\n')"
CLAUDE_JSON='[{"name":"fiber-66","status":"idle"}]'
GH_TICKET_STATES='66:CLOSED'
export FILE_CLAIM_LIST CLAUDE_JSON GH_TICKET_STATES
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'closed branch claim does not hold'
assert_line 'STALE docs/tui.md by arch/66-log-diag-leaf (ticket #66 closed)' 'closed branch claim is stale'
assert_not_contains 'OVERLAP docs/tui.md lane #66' 'closed branch claim does not overlap'

# A phase-suffixed holder is keyed to its ticket too.
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-66-plan\tgrant\t0\tt:stub\t\n')"
CLAUDE_JSON='[{"name":"fiber-66-plan","status":"idle"}]'
GH_TICKET_STATES='66:CLOSED'
export FILE_CLAIM_LIST CLAUDE_JSON GH_TICKET_STATES
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'closed phase claim does not hold'
assert_line 'STALE docs/tui.md by fiber-66-plan (ticket #66 closed)' 'closed phase claim is stale'
assert_not_contains 'OVERLAP docs/tui.md lane #66' 'closed phase claim does not overlap'
grep -qF 'ticket_66: issueOrPullRequest(number: 66)' "$T/gh.log" || fail 'closed phase claim queries ticket #66'

# Merged pull requests are terminal in the same way as closed issues.
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-66\tgrant\t0\tt:stub\t\n')"
GH_TICKET_STATES='66:MERGED'
export FILE_CLAIM_LIST GH_TICKET_STATES
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'merged ticket claim does not hold'
assert_line 'STALE docs/tui.md by fiber-66 (ticket #66 closed)' 'merged ticket claim is stale'

# Open tickets still hold when their lane is live between phases.
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-66\tgrant\t0\tt:stub\t\n')"
CLAUDE_JSON='[{"name":"fiber-66","status":"idle"}]'
GH_TICKET_STATES='66:OPEN'
export FILE_CLAIM_LIST CLAUDE_JSON GH_TICKET_STATES
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'open ticket claim remains held'
assert_line 'OVERLAP docs/tui.md lane #66' 'open ticket live claim overlaps'
assert_not_contains 'STALE' 'open ticket claim is not stale'

# Sweep claims remain exclusive and do not need ticket-state lookups.
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tsweep-66\tplan\t0\tt:stub\t\n')"
GH_TICKET_STATES='66:CLOSED'
export FILE_CLAIM_LIST GH_TICKET_STATES
run_fg 88 --paths docs/tui.md --dry
assert_rc 1 'closed-ticket sweep claim remains held'
assert_out 'HELD docs/tui.md by lane sweep-66' 'closed-ticket sweep hold output'
assert_no_ticket_state_probe 'sweep-only claims'

# All non-sweep claim ticket states are fetched in one batched request.
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-66\tgrant\t0\tt:stub\t\ndocs/events.md\tarch/67-log-diag-leaf\tplan\t0\tt:stub\t\n')"
CLAUDE_JSON='[{"name":"fiber-66","status":"idle"},{"name":"fiber-67","status":"busy"}]'
GH_TICKET_STATES='66:OPEN,67:CLOSED'
export FILE_CLAIM_LIST CLAUDE_JSON GH_TICKET_STATES
run_fg 88 --paths docs/tui.md,docs/events.md --dry
assert_rc 0 'batched claim states keep open and close closed ticket claims'
assert_line 'OVERLAP docs/tui.md lane #66' 'batched open claim remains held'
assert_line 'STALE docs/events.md by arch/67-log-diag-leaf (ticket #67 closed)' 'batched closed claim is stale'
[ "$(grep -c '^api graphql ' "$T/gh.log")" = 1 ] || fail 'claim tickets use exactly one batched lookup'

# A ticket-state lookup failure holds claims for the live-lane check.
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-66\tgrant\t0\tt:stub\t\n')"
GH_TICKET_FAIL=1
CLAUDE_JSON='[{"name":"fiber-66","status":"busy"}]'
export FILE_CLAIM_LIST GH_TICKET_FAIL CLAUDE_JSON
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'ticket-state lookup failure defers to lane liveness'
assert_line 'WARN ticket state lookup ticket state stub failure; claims held by lane liveness' 'ticket-state lookup failure warning'
assert_line 'OVERLAP docs/tui.md lane #66' 'ticket-state lookup failure keeps live claim held'
assert_no_grant 'ticket-state lookup failure'

# No non-sweep claims means no ticket-state API call.
reset_case
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'no-claim dry run succeeds'
assert_no_ticket_state_probe 'no claims'

# An unreadable whole response leaves all claim states unknown.
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-66\tgrant\t0\tt:stub\t\n')"
GH_TICKET_BAD=1
CLAUDE_JSON='[{"name":"fiber-66","status":"idle"}]'
export FILE_CLAIM_LIST GH_TICKET_BAD CLAUDE_JSON
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'unreadable ticket-state response defers to lane liveness'
assert_line 'WARN ticket state lookup unreadable response; claims held by lane liveness' 'unreadable whole-response warning'
assert_line 'OVERLAP docs/tui.md lane #66' 'unreadable response keeps live claim held'

# A missing ticket in a readable response is unknown only for that ticket.
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-66\tgrant\t0\tt:stub\t\n')"
GH_TICKET_MISSING=1
CLAUDE_JSON='[{"name":"fiber-66","status":"busy"}]'
export FILE_CLAIM_LIST GH_TICKET_MISSING CLAUDE_JSON
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'missing ticket-state entry defers to lane liveness'
assert_line 'WARN ticket state lookup ticket #66 missing from response; claims held by lane liveness' 'missing ticket-state warning'
assert_line 'OVERLAP docs/tui.md lane #66' 'missing ticket-state entry keeps live claim held'

reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-66\tgrant\t0\tt:stub\t\n')"
GH_TICKET_STATES='66:UNKNOWN'
CLAUDE_JSON='[{"name":"fiber-66","status":"busy"}]'
export FILE_CLAIM_LIST GH_TICKET_STATES CLAUDE_JSON
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'unknown ticket state defers to lane liveness'
assert_line 'WARN ticket state lookup ticket #66 unknown state UNKNOWN; claims held by lane liveness' 'unknown ticket-state warning'
assert_line 'OVERLAP docs/tui.md lane #66' 'unknown ticket state keeps live claim held'

# A missing ticket is held while a closed ticket in the same batch stays stale.
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-66\tgrant\t0\tt:stub\t\ndocs/events.md\tfiber-67\tplan\t0\tt:stub\t\n')"
GH_TICKET_OMIT=66
GH_TICKET_STATES='67:CLOSED'
CLAUDE_JSON='[{"name":"fiber-66","status":"idle"},{"name":"fiber-67","status":"busy"}]'
export FILE_CLAIM_LIST GH_TICKET_OMIT GH_TICKET_STATES CLAUDE_JSON
run_fg 88 --paths docs/tui.md,docs/events.md --dry
assert_rc 0 'missing and closed tickets have independent state handling'
assert_line 'WARN ticket state lookup ticket #66 missing from response; claims held by lane liveness' 'partial response warns for missing ticket'
assert_line 'OVERLAP docs/tui.md lane #66' 'missing ticket remains held by live lane'
assert_line 'STALE docs/events.md by fiber-67 (ticket #67 closed)' 'closed ticket remains stale in partial response'
assert_not_contains 'OVERLAP docs/events.md lane #67' 'closed ticket does not overlap'

# --- Live plan and grant claims are holders ---------------------------------
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-66\tplan\t0\tt:stub\t\ndocs/events.md\tfiber-67\tgrant\t0\tt:stub\t\n')"
CLAUDE_JSON='[{"name":"fiber-66","status":"busy"},{"name":"fiber-67","status":"idle"}]'
export FILE_CLAIM_LIST CLAUDE_JSON
run_fg 88 --paths docs/tui.md,docs/events.md --dry
assert_rc 0 'live plan and grant claim overlaps are advisory'
assert_out "$(printf 'OVERLAP docs/tui.md lane #66\nOVERLAP docs/events.md lane #67\nWIDE docs/tui.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWIDE docs/events.md is granted whole (no --ranges): a lane needing one line of it will see an OVERLAP.\nWOULD-GRANT docs/tui.md\nWOULD-GRANT docs/events.md\nWOULD-GRANT')" 'live claim overlaps and grants'

# --- Claims match phase-suffixed live lane names -----------------------------
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-66\tgrant\t0\tt:stub\t\n')"
CLAUDE_JSON='[{"name":"fiber-66-plan","status":"busy"}]'
export FILE_CLAIM_LIST CLAUDE_JSON
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'phase-suffixed lane claim does not go stale'
assert_line 'OVERLAP docs/tui.md lane #66' 'phase-suffixed live claim overlap output'
assert_not_contains 'STALE' 'phase-suffixed live claim is not stale'

# --- Branch-named claims match their live ticket lane ------------------------
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tarch/66-some-slug\tgrant\t0\tt:stub\t\n')"
CLAUDE_JSON='[{"name":"fiber-66-plan","status":"busy"}]'
export FILE_CLAIM_LIST CLAUDE_JSON
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'branch-named claim does not go stale'
assert_line 'OVERLAP docs/tui.md lane #66' 'branch-named live claim overlap output'
assert_not_contains 'STALE' 'branch-named live claim is not stale'

# --- Branch-named claims still need a matching live lane ---------------------
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tarch/66-some-slug\tgrant\t0\tt:stub\t\n')"
export FILE_CLAIM_LIST
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'branch-named claim without a live lane does not hold'
assert_line 'STALE docs/tui.md by arch/66-some-slug' 'stale branch-named claim logged'

# --- Branch names use ticket numbers for own and ignored claim skips ---------
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tarch/77-own-claim\tgrant\t0\tt:stub\t\ndocs/events.md\ttests/66-ignored-claim\tgrant\t0\tt:stub\t\n')"
export FILE_CLAIM_LIST
run_fg 77 --paths docs/tui.md,docs/events.md --ignore-ticket 66 --dry
assert_rc 0 'branch-named own and ignored claims are skipped'
assert_not_contains 'STALE' 'branch-named own and ignored claims do not go stale'
assert_line 'WOULD-GRANT docs/tui.md' 'branch-named own claim does not hold requester'
assert_line 'WOULD-GRANT docs/events.md' 'branch-named ignored claim does not hold requester'
assert_no_ticket_state_probe 'own and ignored branch claims'

# --- A requester's own claim is not a holder or stale ------------------------
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-77\tgrant\t0\tt:stub\t\n')"
export FILE_CLAIM_LIST
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'requester own claim is ignored'
assert_not_contains 'STALE' 'own claim is not stale'
assert_line 'WOULD-GRANT docs/tui.md' 'own claim does not hold requester'
assert_no_ticket_state_probe 'requester own claim'

# --- Claims from a gone lane are logged and released -------------------------
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tfiber-66\tgrant\t0\tt:stub\t\n')"
export FILE_CLAIM_LIST
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'stale claim does not hold'
assert_line 'STALE docs/tui.md by fiber-66' 'stale claim logged'
[ "$(grep -c '^STALE docs/tui.md by fiber-66$' "$T/out")" = 1 ] || fail 'stale claim logs once'
assert_line 'WOULD-GRANT docs/tui.md' 'stale claim releases path'

# --- A non-fiber lane's claim is checked with no --ignore-ticket --------------
reset_case
FILE_CLAIM_LIST="$(printf 'docs/tui.md\tother-lane\tgrant\t0\tt:stub\t\n')"
export FILE_CLAIM_LIST
run_fg 88 --paths docs/tui.md --dry
assert_line 'STALE docs/tui.md by other-lane' 'non-fiber claim is not skipped'

# --- A failed or malformed claims read fails closed -------------------------
reset_case
FILE_CLAIM_LIST_FAIL=1
export FILE_CLAIM_LIST_FAIL
run_fg 88 --paths docs/tui.md --dry
assert_rc 3 'failed claims read fails closed'
assert_out 'ERROR file-claim list stub file-claim list: boom ' 'failed claims read output'
assert_no_grant 'failed claims read'

reset_case
FILE_CLAIM_LIST_BAD=1
export FILE_CLAIM_LIST_BAD
run_fg 88 --paths docs/tui.md --dry
assert_rc 3 'malformed claims read fails closed'
assert_out 'ERROR file-claim list unparseable claims' 'malformed claims read output'
assert_no_grant 'malformed claims read'

# --- Launch requirements are phase-aware -----------------------------------
reset_case
run_fg --require 77 --phase plan
assert_rc 2 'plan phase without a grant is refused'
expected_refusal="fence-grant: issue 77 needs a fence grant matching $FW_RUN/fiber-77*-fence-grant*.md on host $(hostname); a grant written on another machine is invisible here; create one or set FW_NO_FENCE=<reason>"
assert_stderr "$expected_refusal" 'plan requirement explains the searched host and path'
grep -qF "matching $FW_RUN/fiber-77*-fence-grant*.md on host $(hostname)" "$T/err" \
  || fail 'require refusal shows searched glob and host'
grep -qF 'a grant written on another machine is invisible here' "$T/err" \
  || fail 'require refusal explains host-local visibility'

printf 'grant\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
run_fg --require 77 --phase plan
assert_rc 0 'plan phase accepts a grant'
assert_out '' 'plan grant check is silent'
assert_stderr '' 'plan grant check has no error'
rm "$FW_RUN/fiber-77-fence-grant-1.md"

run_fg --require 77 --phase build
assert_rc 2 'build phase without a grant is refused'
assert_stderr "$expected_refusal" 'build requirement explains the searched host and path'

printf 'grant\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
run_fg --require 77 --phase build
assert_rc 0 'build phase accepts a grant'
assert_out '' 'existing grant check is silent'
assert_stderr '' 'existing grant check has no error'

rm "$FW_RUN/fiber-77-fence-grant-1.md"
run_fg --require 77 --phase build
assert_rc 2 'build phase remains guarded after grant removal'
FW_NO_FENCE='approved by flywheel'
export FW_NO_FENCE
run_fg --require 77 --phase ship
assert_rc 0 'ship phase accepts a reasoned override'
assert_out 'FW_NO_FENCE: approved by flywheel' 'override prints its reason'
unset FW_NO_FENCE

run_fg --require 77 --phase ship
assert_rc 2 'ship phase without a grant is refused'

echo 'fence-grant tests passed'

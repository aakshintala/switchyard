#!/usr/bin/env bash
# Tests bin/roles-restart with fake gh, claude and owner-ask commands.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/../bin/roles-restart"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-roles-restart.XXXXXX")"
trap 'rm -rf "$T"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

export HOME="$T/home"
STUBS="$T/stubs"
mkdir -p "$HOME" "$STUBS"
export GH_LOG="$T/gh.log" CLAUDE_LOG="$T/claude.log" OWNER_ASK_LOG="$T/owner-ask.log"

cat >"$STUBS/gh" <<'GH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$GH_LOG"
[ "${GH_ALWAYS_FAIL:-0}" != 1 ]
GH
cat >"$STUBS/claude" <<'CLAUDE'
#!/usr/bin/env bash
{
  printf 'cwd=%s\n' "$PWD"
  printf 'arg=%s\n' "$@"
  printf '\n'
} >>"$CLAUDE_LOG"
CLAUDE
cat >"$STUBS/owner-ask" <<'OWNER'
#!/usr/bin/env bash
printf 'owner-ask %s\n' "$*" >>"$OWNER_ASK_LOG"
OWNER
chmod +x "$STUBS/gh" "$STUBS/claude" "$STUBS/owner-ask"
export PATH="$STUBS:$PATH"

run_restart() {
  ROLES_RESTART_ROLES="$ROLE_TABLE" \
    ROLES_RESTART_JOBS_DIR="$JOBS" \
    ROLES_RESTART_LOCK_DIR="$LOCK" \
    ROLES_RESTART_LOG="$T/roles-restart.log" \
    ROLES_RESTART_WAIT_TIMEOUT="${WAIT_TIMEOUT:-2}" \
    bash "$BIN"
}

ROLE_HOME="$T/role-home"
HANDOFF="$T/handoff.md"
JOBS="$T/jobs"
LOCK="$T/roles-restart.lock"
mkdir -p "$ROLE_HOME" "$JOBS"
printf '## Crons\n- test cron\n' >"$HANDOFF"
ROLE_TABLE="test-role|$ROLE_HOME|$HANDOFF"
export ROLE_HOME HANDOFF JOBS LOCK ROLE_TABLE

# A missing role launches a fresh session from its home with a handoff-aware prompt.
: >"$CLAUDE_LOG"; : >"$OWNER_ASK_LOG"
run_restart >"$T/missing.out" 2>"$T/missing.err" || fail "missing role run failed: $(cat "$T/missing.err")"
grep -Fqx "cwd=$ROLE_HOME" "$CLAUDE_LOG" || fail "claude was not run from role home"
grep -Fqx 'arg=--bg' "$CLAUDE_LOG" || fail "fresh launch omitted --bg"
grep -Fqx 'arg=--agent' "$CLAUDE_LOG" || fail "fresh launch omitted --agent"
grep -Fqx 'arg=test-role' "$CLAUDE_LOG" || fail "fresh launch omitted role name"
grep -F "arg=Read your handoff at $HANDOFF" "$CLAUDE_LOG" >/dev/null || fail "prompt omitted handoff path"
grep -F '## Crons' "$CLAUDE_LOG" >/dev/null || fail "prompt omitted cron recreation instruction"
grep -F 'restart your inbox wait' "$CLAUDE_LOG" >/dev/null || fail "prompt omitted inbox wait instruction"
grep -F 'carry on' "$CLAUDE_LOG" >/dev/null || fail "prompt omitted carry-on instruction"
grep -F 'roles-restart relaunched test-role' "$T/roles-restart.log" >/dev/null || fail "relaunch was not written to local log"
grep -F 'owner-ask log --from switchyard --kind process --title roles-restart relaunched test-role' "$OWNER_ASK_LOG" >/dev/null \
  || fail "relaunch was not posted as a process line"

# A matching live job (role template and exact cwd) prevents a duplicate session.
: >"$CLAUDE_LOG"; : >"$OWNER_ASK_LOG"
mkdir -p "$JOBS/job-live"
printf '{"template":"test-role","cwd":"%s","state":"working"}\n' "$ROLE_HOME" >"$JOBS/job-live/state.json"
run_restart >"$T/live.out" 2>"$T/live.err" || fail "live role run failed: $(cat "$T/live.err")"
[ ! -s "$CLAUDE_LOG" ] || fail "live role was launched twice"
[ ! -s "$OWNER_ASK_LOG" ] || fail "live role emitted a relaunch line"

# A terminal job is not live and must not mask a needed restart.
printf '{"template":"test-role","cwd":"%s","state":"failed"}\n' "$ROLE_HOME" >"$JOBS/job-live/state.json"
run_restart >"$T/terminal.out" 2>"$T/terminal.err" || fail "terminal job restart failed: $(cat "$T/terminal.err")"
grep -Fqx "cwd=$ROLE_HOME" "$CLAUDE_LOG" || fail "terminal job incorrectly counted as live"

# A missing handoff is skipped, logged and recorded as an owner note.
: >"$CLAUDE_LOG"; : >"$OWNER_ASK_LOG"
ROLE_TABLE="no-handoff|$ROLE_HOME|$T/not-present.md"
export ROLE_TABLE
run_restart >"$T/handoff.out" 2>"$T/handoff.err" || fail "missing handoff run failed: $(cat "$T/handoff.err")"
[ ! -s "$CLAUDE_LOG" ] || fail "role with missing handoff was launched"
grep -F 'missing handoff' "$T/roles-restart.log" >/dev/null || fail "missing handoff was not logged"
grep -F 'owner-ask log --from switchyard --kind note --title roles-restart missing handoff no-handoff' "$OWNER_ASK_LOG" >/dev/null \
  || fail "missing handoff was not reported as a note"

# Holding the mkdir lock makes a second invocation a successful no-op.
: >"$CLAUDE_LOG"; : >"$OWNER_ASK_LOG"
mkdir "$LOCK"
run_restart >"$T/locked.out" 2>"$T/locked.err" || fail "locked run did not exit successfully"
[ ! -s "$CLAUDE_LOG" ] || fail "locked run launched a session"
[ ! -s "$OWNER_ASK_LOG" ] || fail "locked run posted a log line"
rmdir "$LOCK"

# gh auth is bounded; failure logs and exits non-zero without launching a role.
: >"$CLAUDE_LOG"; : >"$OWNER_ASK_LOG"
if GH_ALWAYS_FAIL=1 WAIT_TIMEOUT=1 run_restart >"$T/timeout.out" 2>"$T/timeout.err"; then
  fail "network/auth timeout unexpectedly succeeded"
else
  rc=$?
fi
[ "$rc" -ne 0 ] || fail "network/auth timeout exited zero"
grep -F 'timed out' "$T/roles-restart.log" >/dev/null || fail "network/auth timeout was not logged"
[ ! -s "$CLAUDE_LOG" ] || fail "role launched without network/auth"

printf 'roles-restart: all cases passed\n'

#!/usr/bin/env bash
# Tests bin/roles-restart with fake gh, claude and owner-ask commands.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/../bin/roles-restart"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-roles-restart.XXXXXX")"
trap 'rm -rf "$T"' EXIT
# macOS TMPDIR ends in /; normalise so paths match the $PWD that cd produces.
T="$(cd "$T" && pwd)"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

export HOME="$T/home"
STUBS="$T/stubs"
mkdir -p "$HOME" "$STUBS"
export GH_LOG="$T/gh.log" CLAUDE_LOG="$T/claude.log" OWNER_ASK_LOG="$T/owner-ask.log"
export CLAUDE_NAME_LOG="$T/claude-name.log" TEST_PID="$$"

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
# Record --name and register a live session under it, as claude agents --json would.
name=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --name ] && [ "$#" -gt 1 ]; then name="$2"; break; fi
  shift
done
if [ -n "$name" ]; then
  printf 'name=%s\n' "$name" >>"$CLAUDE_NAME_LOG"
  python3 -I -c '
import json, sys
path, name, pid = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(path) as f:
    rows = json.load(f)
rows.append({"pid": pid, "name": name, "state": "running"})
with open(path, "w") as f:
    json.dump(rows, f)
' "$AGENTS_JSON" "$name" "$TEST_PID"
fi
CLAUDE
cat >"$STUBS/owner-ask" <<'OWNER'
#!/usr/bin/env bash
printf 'owner-ask %s\n' "$*" >>"$OWNER_ASK_LOG"
OWNER
chmod +x "$STUBS/gh" "$STUBS/claude" "$STUBS/owner-ask"
export PATH="$STUBS:$PATH"

run_restart() {
  ROLES_RESTART_ROLES="$ROLE_TABLE" \
    ROLES_RESTART_AGENTS_JSON="$AGENTS_JSON" \
    ROLES_RESTART_LOCK_DIR="$LOCK" \
    ROLES_RESTART_LOG="$T/roles-restart.log" \
    ROLES_RESTART_WAIT_TIMEOUT="${WAIT_TIMEOUT:-2}" \
    bash "$BIN"
}

ROLE_HOME="$T/role-home"
HANDOFF="$T/handoff.md"
AGENTS_JSON="$T/agents.json"
LOCK="$T/roles-restart.lock"
mkdir -p "$ROLE_HOME/worktree"
printf '## Crons\n- test cron\n' >"$HANDOFF"
printf '[]\n' >"$AGENTS_JSON"
ROLE_TABLE="test-role|$ROLE_HOME|$HANDOFF"
export ROLE_HOME HANDOFF AGENTS_JSON LOCK ROLE_TABLE

# A done background session in a worktree is still live when its pid exists.
# Keep this first: the old state.json check relaunches it and fails this test.
: >"$CLAUDE_LOG"; : >"$OWNER_ASK_LOG"
printf '[{"pid":%s,"name":"test-role","cwd":"%s/worktree","state":"done"}]\n' "$$" "$ROLE_HOME" >"$AGENTS_JSON"
run_restart >"$T/live.out" 2>"$T/live.err" || fail "live role run failed: $(cat "$T/live.err")"
[ ! -s "$CLAUDE_LOG" ] || fail "live role was launched twice"
[ ! -s "$OWNER_ASK_LOG" ] || fail "live role emitted a relaunch line"

# A missing role launches a fresh session from its home with a handoff-aware prompt.
: >"$CLAUDE_LOG"; : >"$OWNER_ASK_LOG"
printf '[]\n' >"$AGENTS_JSON"
run_restart >"$T/missing.out" 2>"$T/missing.err" || fail "missing role run failed: $(cat "$T/missing.err")"
grep -Fqx "cwd=$ROLE_HOME" "$CLAUDE_LOG" || fail "claude was not run from role home"
grep -Fqx 'arg=--bg' "$CLAUDE_LOG" || fail "fresh launch omitted --bg"
grep -Fqx 'arg=--agent' "$CLAUDE_LOG" || fail "fresh launch omitted --agent"
grep -Fqx 'arg=test-role' "$CLAUDE_LOG" || fail "fresh launch omitted role name"
grep -F "arg=Read your handoff at $HANDOFF" "$CLAUDE_LOG" >/dev/null || fail "prompt omitted handoff path"
grep -F '## Crons' "$CLAUDE_LOG" >/dev/null || fail "prompt omitted cron recreation instruction"
grep -F 'restart your inbox wait' "$CLAUDE_LOG" >/dev/null || fail "prompt omitted inbox wait instruction"
grep -F 'carry on' "$CLAUDE_LOG" >/dev/null || fail "prompt omitted carry-on instruction"
grep -F 'If it has no ## Crons section, say so on owner-ask and carry on.' "$CLAUDE_LOG" >/dev/null \
  || fail "prompt omitted no-Crons instruction"
grep -F 'roles-restart relaunched test-role' "$T/roles-restart.log" >/dev/null || fail "relaunch was not written to local log"
grep -F 'owner-ask log --from switchyard --kind process --title roles-restart relaunched test-role' "$OWNER_ASK_LOG" >/dev/null \
  || fail "relaunch was not posted as a process line"

# A relaunched role is named after itself, so the next pass sees it live.
: >"$CLAUDE_LOG"; : >"$OWNER_ASK_LOG"; : >"$CLAUDE_NAME_LOG"
printf '[]\n' >"$AGENTS_JSON"
run_restart >"$T/named.out" 2>"$T/named.err" || fail "named launch run failed: $(cat "$T/named.err")"
grep -Fqx 'name=test-role' "$CLAUDE_NAME_LOG" || fail "relaunch did not pass --name test-role"
: >"$CLAUDE_LOG"; : >"$OWNER_ASK_LOG"
run_restart >"$T/named2.out" 2>"$T/named2.err" || fail "second named run failed: $(cat "$T/named2.err")"
[ ! -s "$CLAUDE_LOG" ] || fail "second pass relaunched a role the first pass started"

# A matching row whose pid is dead does not mask a needed restart.
: >"$CLAUDE_LOG"; : >"$OWNER_ASK_LOG"
sleep 0 &
dead_pid=$!
wait "$dead_pid"
printf '[{"pid":%s,"name":"test-role","cwd":"%s/worktree","state":"running"}]\n' "$dead_pid" "$ROLE_HOME" >"$AGENTS_JSON"
run_restart >"$T/dead.out" 2>"$T/dead.err" || fail "dead role restart failed: $(cat "$T/dead.err")"
grep -Fqx "cwd=$ROLE_HOME" "$CLAUDE_LOG" || fail "dead role was incorrectly counted as live"

# Fourth-column arguments are passed after --bg and before --agent.
: >"$CLAUDE_LOG"; : >"$OWNER_ASK_LOG"
printf '[]\n' >"$AGENTS_JSON"
ROLE_TABLE="test-role|$ROLE_HOME|$HANDOFF|--plugin-dir /x/role-inbox"
export ROLE_TABLE
run_restart >"$T/extra-args.out" 2>"$T/extra-args.err" || fail "extra-args run failed: $(cat "$T/extra-args.err")"
bg_line="$(grep -nF 'arg=--bg' "$CLAUDE_LOG" | cut -d: -f1)"
plugin_line="$(grep -nF 'arg=--plugin-dir' "$CLAUDE_LOG" | cut -d: -f1)"
plugin_path_line="$(grep -nF 'arg=/x/role-inbox' "$CLAUDE_LOG" | cut -d: -f1)"
agent_line="$(grep -nF 'arg=--agent' "$CLAUDE_LOG" | cut -d: -f1)"
[ -n "$bg_line" ] && [ -n "$plugin_line" ] && [ -n "$plugin_path_line" ] && [ -n "$agent_line" ] \
  || fail "extra arguments were not passed to claude"
[ "$bg_line" -lt "$plugin_line" ] && [ "$plugin_line" -lt "$plugin_path_line" ] \
  && [ "$plugin_path_line" -lt "$agent_line" ] \
  || fail "extra arguments did not appear after --bg and before --agent"

# Agent-list parse failures are logged and fail closed without launching.
: >"$CLAUDE_LOG"; : >"$OWNER_ASK_LOG"
printf '{not json\n' >"$AGENTS_JSON"
if run_restart >"$T/invalid-json.out" 2>"$T/invalid-json.err"; then
  fail "invalid agents JSON unexpectedly succeeded"
fi
[ ! -s "$CLAUDE_LOG" ] || fail "role launched after agents JSON parse failure"
grep -F 'agents' "$T/roles-restart.log" >/dev/null || fail "agents JSON parse failure was not logged"

# More than four columns is invalid and must not launch.
: >"$CLAUDE_LOG"; : >"$OWNER_ASK_LOG"
printf '[]\n' >"$AGENTS_JSON"
ROLE_TABLE="test-role|$ROLE_HOME|$HANDOFF|--plugin-dir /x|extra-column"
export ROLE_TABLE
if run_restart >"$T/invalid-row.out" 2>"$T/invalid-row.err"; then
  fail "role row with more than four columns unexpectedly succeeded"
fi
[ ! -s "$CLAUDE_LOG" ] || fail "invalid role row launched a session"
grep -F 'invalid role table row' "$T/roles-restart.log" >/dev/null || fail "invalid role row was not logged"

# Default rows pass the role-inbox plugin dir to all three roles.
: >"$CLAUDE_LOG"; : >"$OWNER_ASK_LOG"
printf '[]\n' >"$AGENTS_JSON"
for default_role in surveyor switchyard flywheel; do
  mkdir -p "$HOME/work/wiki/state"
  printf '## Crons\n' >"$HOME/work/wiki/state/$default_role.md"
done
mkdir -p "$HOME/work/fiber-worktrees/surveyor/home" "$HOME/work/sy-wt/main" "$HOME/work/fiber"
ROLE_TABLE=""
export ROLE_TABLE
run_restart >"$T/defaults.out" 2>"$T/defaults.err" || fail "default rows run failed: $(cat "$T/defaults.err")"
plugin_roles="$(awk 'BEGIN { RS = "" } {
  role = ""; plugin = 0
  n = split($0, lines, "\n")
  for (i = 1; i <= n; i++) {
    if (lines[i] == "arg=--agent") role = lines[i + 1]
    if (lines[i] == "arg=--plugin-dir" && lines[i + 1] == "arg=/Users/aakshintala/.agents/claude-code/plugins/role-inbox" && role == "") plugin = 1
  }
  print role ":" plugin
}' "$CLAUDE_LOG" | sort | tr '\n' ' ')"
[ "$plugin_roles" = "arg=flywheel:1 arg=surveyor:1 arg=switchyard:1 " ] \
  || fail "default rows plugin-dir mismatch: $plugin_roles"

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

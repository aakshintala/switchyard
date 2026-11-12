#!/usr/bin/env bash
# Hermetic timeout coverage for claude agents probes in lanecheck and ruled.sh.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
BIN="$here/../bin"
T=$(mktemp -d "${TMPDIR:-/tmp}/claude-agents-timeout.XXXXXX")
cleanup() {
  for pidfile in "$T"/*.pid; do
    [ -f "$pidfile" ] || continue
    pid=$(cat "$pidfile" 2>/dev/null || true)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  rm -rf "${T:?}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
rc=0
ok() { printf 'ok %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; rc=1; }

mkdir -p "$T/stub"
cat >"$T/stub/claude" <<'EOF'
#!/bin/bash
[ "${1:-}" = agents ] && [ "${2:-}" = --json ] || exit 2
if [ "${CLAUDE_MODE:-}" = sleep ]; then
  sleep 120 &
  child=$!
  printf '%s\n' "$child" >"${CLAUDE_PID_FILE:-$STUBD/claude-child.pid}"
  wait "$child"
  exit $?
fi
if [ "${CLAUDE_MODE:-}" = fail ]; then
  printf 'fake claude first error\nfake claude second error\n' >&2
  exit 17
fi
cat "$STUBD/cagents" 2>/dev/null || echo '[]'
EOF
cat >"$T/stub/ssh" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-p|-i|-l|-F|-J|-L|-R) shift 2;;
    -*) shift;;
    *) host=$1; shift; break;;
  esac
done
command=$*
case "$command" in
  *"claude agents --json"*)
    if [ "${SSH_CLAUDE_MODE:-}" = sleep ]; then
      sleep 120 &
      child=$!
      printf '%s\n' "$child" >"${CLAUDE_PID_FILE:-$STUBD/ssh-child.pid}"
      wait "$child"
      exit $?
    fi
    if [ "${SSH_CLAUDE_FAIL:-}" = 1 ]; then
      echo 'fake ssh probe failure' >&2
      exit 255
    fi
    cat "$STUBD/cagents" 2>/dev/null || echo '[]';;
  *"delegate session list --json"*) cat "$STUBD/dsess" 2>/dev/null || echo '{"sessions":[]}';;
  *"delegate session logs"*) cat "$STUBD/dlogs" 2>/dev/null || echo '{"lines":[]}';;
  *"ps -eo args="*) cat "$STUBD/pending" 2>/dev/null || true;;
  *"ps -A -o pid=,ppid=,etime=,args="*) cat "$STUBD/box-procs" 2>/dev/null || true;;
  *"ps -A -o pid="*) cat "$STUBD/box-procs" 2>/dev/null || true;;
  *"test -e"*) exit 0;;
  *"delegate-jobs"*) cat "$STUBD/asking" 2>/dev/null || true;;
  *) echo '[]';;
esac
EOF
cat >"$T/stub/delegate" <<'EOF'
#!/bin/bash
if [ "${1:-}" = session ] && [ "${2:-}" = list ]; then
  cat "$STUBD/mac-dsess" 2>/dev/null || echo '{"sessions":[]}'
  exit 0
fi
exit 2
EOF
cat >"$T/stub/watchers" <<'EOF'
#!/bin/bash
echo "NO-WATCHER ~/lane-inbox/${2##*/} unread=1"
EOF
cat >"$T/stub/scp" <<'EOF'
#!/bin/bash
exit 0
EOF
mkdir -p "$T/ruled-stub"
cat >"$T/ruled-stub/sleep" <<'EOF'
#!/bin/sh
if [ "${1:-}" = 2 ]; then exit 0; fi
exec /bin/sleep "$@"
EOF
chmod +x "$T/ruled-stub/sleep"
for stub in gh file-claim boxstale inbox-watchers; do
  cat >"$T/stub/$stub" <<'EOF'
#!/bin/bash
exit 0
EOF
done
chmod +x "$T/stub/"*
export STUBD=$T PATH="$T/stub:$PATH"
export BOX_SSH="$T/stub/ssh" FW_DELEGATE="$T/stub/delegate"
export FW_FILE_CLAIM="$T/stub/file-claim" FW_INBOX_WATCHERS="$T/stub/inbox-watchers"
export FW_BOXSTALE="$T/stub/boxstale" FW_SKIP_SAMPLER_CHECK=1 FW_LOCAL_BOX=0
# Margins hold under a loaded gate (#1643): the probe timeout leaves the stub
# time to start and record its child, and the wall cap (60s) stays below the
# stub's 120s sleep, so an unbounded probe still fails.
export PROBE_TIMEOUT=3
printf '[]\n' >"$T/cagents"
printf '{"sessions":[{"id":"sid-4802","status":"running","activeTurnId":"turn-4802","turnCount":1,"lastTurn":{"terminal":"completed","endedAt":1}}]}\n' >"$T/dsess"
printf '{"sessions":[]}\n' >"$T/mac-dsess"
printf '{"lines":[]}\n' >"$T/dlogs"
: >"$T/pending"; : >"$T/asking"; : >"$T/box-procs"

# An unreachable Claude host is UNKNOWN, its row cannot wake, and another
# host's live row still prints. Check probe cleanup, not elapsed wall time.
run="$T/lanecheck-run"
mkdir -p "$run/done"
: >"$run/roster"; : >"$run/roster-done"
printf '2020-01-01T00:00:00Z\t4801\tmac\tclaude-4801-build\t?\n' >>"$run/roster"
printf '2020-01-01T00:00:00Z\t4802\tmuse\tfiber-4802-build\tsid-4802\n' >>"$run/roster"
if python3 - "$BIN/lanecheck" "$run" "$T/lanecheck-timeout.out" "$T/claude-child.pid" <<'PY'
import os, subprocess, sys, time
script, run, output_path, pid_path = sys.argv[1:]
env = os.environ.copy()
env.update(FW_RUN=run, FW_CLAUDE_AGENTS_TIMEOUT=os.environ["PROBE_TIMEOUT"], CLAUDE_MODE="sleep",
           CLAUDE_PID_FILE=pid_path)
try:
    result = subprocess.run(["bash", script], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
except subprocess.TimeoutExpired:
    raise SystemExit("lanecheck exceeded timeout plus margin")
open(output_path, "w").write(result.stdout)
if result.returncode != 0:
    raise SystemExit(f"lanecheck exit {result.returncode}: {result.stdout}")
if not os.path.exists(pid_path):
    raise SystemExit("fake claude did not start")
pid = int(open(pid_path).read())
for _ in range(200):
    stat = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                          text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL).stdout.strip()
    if not stat or stat.startswith("Z"):
        break
    time.sleep(0.1)
else:
    raise SystemExit(f"fake claude child {pid} is still running (ps state {stat})")
PY
then
  out=$(cat "$T/lanecheck-timeout.out")
  if printf '%s\n' "$out" | grep -Fq "UNKNOWN mac — cannot list sessions: claude agents timed out after ${PROBE_TIMEOUT}s"; then
    ok lanecheck-timeout-is-unknown-with-reason
  else
    fail "lanecheck-timeout-is-unknown-with-reason ($out)"
  fi
  if printf '%s\n' "$out" | grep -q '^LIVE 4802 muse fiber-4802-build'; then
    ok lanecheck-timeout-keeps-other-host-row
  else
    fail "lanecheck-timeout-keeps-other-host-row ($out)"
  fi
  if ! printf '%s\n' "$out" | grep -Eq '^(WAKE|STALL|MISSING) 4801 '; then
    ok lanecheck-unknown-host-sends-no-wake
  else
    fail "lanecheck-unknown-host-sends-no-wake ($out)"
  fi
  ok lanecheck-timeout-kills-process-group
else
  fail 'lanecheck-timeout-returns-within-margin-and-kills-child'
fi

# A non-zero CLI exit uses stderr's first line, not a parser error or later line.
if CLAUDE_MODE=fail FW_CLAUDE_AGENTS_TIMEOUT=$PROBE_TIMEOUT FW_RUN="$run" bash "$BIN/lanecheck" >"$T/lanecheck-failure.out" 2>&1; then
  failure_rc=0
else
  failure_rc=$?
fi
out=$(cat "$T/lanecheck-failure.out")
if [ "$failure_rc" -eq 0 ] && printf '%s\n' "$out" | grep -Fq 'UNKNOWN mac — cannot list sessions: fake claude first error' \
   && ! printf '%s\n' "$out" | grep -Fq 'fake claude second error'; then
  ok lanecheck-nonzero-exit-uses-first-stderr-line
else
  fail "lanecheck-nonzero-exit-uses-first-stderr-line (rc=$failure_rc $out)"
fi

# Exercise both retirement-mode calls too: the local and remote probes must
# not bypass the shared bound merely because they run before the census rows.
run_done_timeout() {
  python3 - "$BIN/lanecheck" "$1" "$2" "$3" "$4" "$5" <<'PY'
import os, subprocess, sys, time
script, run, ticket, output_path, pid_path, mode = sys.argv[1:]
env = os.environ.copy()
env.update(FW_RUN=run, FW_CLAUDE_AGENTS_TIMEOUT=os.environ["PROBE_TIMEOUT"], CLAUDE_PID_FILE=pid_path)
if mode == "local":
    env["CLAUDE_MODE"] = "sleep"
else:
    env["SSH_CLAUDE_MODE"] = "sleep"
try:
    result = subprocess.run(["bash", script, "done", ticket], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
except subprocess.TimeoutExpired:
    raise SystemExit("lanecheck done exceeded timeout plus margin")
output = result.stdout
open(output_path, "w").write(output)
if result.returncode != 2:
    raise SystemExit(f"lanecheck done returned {result.returncode}: {output}")
if not os.path.exists(pid_path):
    raise SystemExit("fake probe process did not start")
pid = int(open(pid_path).read())
for _ in range(200):
    stat = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                          text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL).stdout.strip()
    if not stat or stat.startswith("Z"):
        break
    time.sleep(0.1)
else:
    raise SystemExit(f"fake probe child {pid} is still running (ps state {stat})")
PY
}
if run_done_timeout "$run" 4801 "$T/done-mac.out" "$T/done-mac.pid" local; then
  if grep -q 'cannot check Mac Claude sessions; no lane retired' "$T/done-mac.out"; then
    ok lanecheck-done-bounds-local-probe
  else
    fail "lanecheck-done-bounds-local-probe ($(cat "$T/done-mac.out"))"
  fi
else
  fail 'lanecheck-done-bounds-local-probe-times-out-and-cleans-up'
fi
box_run="$T/done-box-run"
mkdir -p "$box_run/done"
: >"$box_run/roster-done"
printf '2020-01-01T00:00:00Z\t4804\tbox\tfiber-4804-build\t?\n' >"$box_run/roster"
if run_done_timeout "$box_run" 4804 "$T/done-box.out" "$T/done-box.pid" remote; then
  if grep -q 'cannot check Box Claude sessions; no lane retired' "$T/done-box.out"; then
    ok lanecheck-done-bounds-remote-probe
  else
    fail "lanecheck-done-bounds-remote-probe ($(cat "$T/done-box.out"))"
  fi
else
  fail 'lanecheck-done-bounds-remote-probe-times-out-and-cleans-up'
fi

# ruled.sh also bounds the remote probe; a non-zero result takes its existing
# unknown-session branch rather than being treated as busy or idle.
ruling_run="$T/ruled-run"
mkdir -p "$ruling_run/inbox" "$ruling_run/rulings"
printf '2020-01-01T00:00:00Z\t4803\tbox\tfiber-4803-build\t?\n' >"$ruling_run/roster"
printf 'A ruling for the failed probe.\n' >"$T/ruling.md"
if SSH_CLAUDE_FAIL=1 FW_CLAUDE_AGENTS_TIMEOUT=$PROBE_TIMEOUT FW_RUN="$ruling_run" FW_NO_BOX_PUSH=1 \
   FW_INBOX_WATCHERS="$T/stub/watchers" BOX_SSH="$T/stub/ssh" \
   PATH="$T/ruled-stub:$PATH" \
   bash "$BIN/ruled.sh" 4803 "$T/ruling.md" >"$T/ruled.out" 2>&1; then
  ruled_rc=0
else
  ruled_rc=$?
fi
out=$(cat "$T/ruled.out")
if [ "$ruled_rc" -eq 4 ] && printf '%s\n' "$out" | grep -q 'session status unknown' \
   && ! printf '%s\n' "$out" | grep -q 'MID-TURN:\|STOPPED:'; then
  ok ruled-failed-probe-is-unreadable
else
  fail "ruled-failed-probe-is-unreadable (rc=$ruled_rc $out)"
fi

exit "$rc"

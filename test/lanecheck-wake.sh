#!/usr/bin/env bash
# Hermetic tests for lanecheck's delegate wake, process-tree and missed-steer paths.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
BIN="$here/../bin"
tmp_root=${TMPDIR:-/tmp}
T=$(mktemp -d "${tmp_root%/}/lanecheck-wake.XXXXXX")
trap 'rm -rf "${T:?}"' EXIT
trap 'exit 130' INT TERM
rc=0
ok() { printf 'ok %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; rc=1; }

mkdir -p "$T/stub"
cat >"$T/stub/ssh" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *"claude agents --json"*) cat "$STUBD/cagents" 2>/dev/null || echo '[]';;
  *"delegate session list --json"*) cat "$STUBD/dsess" 2>/dev/null || echo '{"ok":true,"sessions":[]}';;
  *"delegate session logs"*) cat "$STUBD/dlogs" 2>/dev/null || echo '{"ok":true,"lines":[]}';;
  *"delegate session send"*)
    printf '%s\n' "$*" >>"$STUBD/send-commands"
    cat >"$STUBD/last-send"
    cat "$STUBD/last-send" >>"$STUBD/sent-messages"
    printf '\n---END-SEND---\n' >>"$STUBD/sent-messages"
    echo '{"ok":true,"disposition":"started"}'
    ;;
  *"ps -eo args="*) cat "$STUBD/pending" 2>/dev/null || true;;
  *"ps -A -o pid="*) cat "$STUBD/box-procs" 2>/dev/null || true;;
  *"job-record"*)
    id=$(printf '%s\n' "$*" | sed -n 's/.*job-record" \([A-Za-z0-9-][A-Za-z0-9-]*\).*/\1/p')
    cat "$STUBD/jobs/$id.json" 2>/dev/null || exit 1
    ;;
  *"delegate-jobs"*) cat "$STUBD/asking" 2>/dev/null || true;;
  *) echo '[]';;
esac
exit 0
EOF
cat >"$T/stub/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = agents ] && [ "${2:-}" = --json ] || exit 2
cat "$STUBD/cagents" 2>/dev/null || echo '[]'
EOF
cat >"$T/stub/delegate" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = session ] && [ "${2:-}" = list ]; then
  cat "$STUBD/mac-dsess" 2>/dev/null || echo '{"ok":true,"sessions":[]}'
  exit 0
fi
exit 2
EOF
cat >"$T/stub/ps" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *"-A -o pid="*) cat "$STUBD/mac-procs" 2>/dev/null || true;;
  *) exec /bin/ps "$@";;
esac
EOF
for stub in gh file-claim inbox-watchers boxstale; do
  cat >"$T/stub/$stub" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
chmod +x "$T/stub"/*
export STUBD=$T PATH="$T/stub:$PATH"
export BOX_SSH=$T/stub/ssh FW_DELEGATE=$T/stub/delegate
export FW_FILE_CLAIM=$T/stub/file-claim FW_INBOX_WATCHERS=$T/stub/inbox-watchers
export FW_BOXSTALE=$T/stub/boxstale FW_SKIP_SAMPLER_CHECK=1
mkdir -p "$T/jobs"
export DELEGATE_JOBS_DIR="$T/jobs"
: >"$T/pending"
: >"$T/asking"
: >"$T/send-commands"
: >"$T/sent-messages"
printf '[]' >"$T/cagents"
printf '{"ok":true,"sessions":[]}' >"$T/mac-dsess"
printf '{"ok":true,"sessions":[]}' >"$T/dsess"
printf '{"ok":true,"lines":[]}' >"$T/dlogs"
: >"$T/box-procs"
: >"$T/mac-procs"

newrun() {
  r="$T/run-$1"
  rm -rf "$r"
  mkdir -p "$r/done"
  : >"$r/roster"
  : >"$r/roster-done"
  printf '%s\n' "$r"
}
lane() {
  printf '2020-01-01T00:00:00Z\t%s\tmuse\t%s\t%s\n' "$2" "$3" "$4" >>"$1/roster"
}
set_session() {
  local sid="$1" ticket="$2" turn="$3" terminal="$4" ended="$5"
  cat >"$T/dsess" <<EOF
{"ok":true,"sessions":[{"id":"$sid","status":"idle","turnCount":4,"hostPid":100,"supervisorPid":90,"lastTurn":{"turnId":"$turn","terminal":"$terminal","endedAt":$ended}}]}
EOF
}
set_logs() {
  local turn="$1" start="$2" end="$3" text="$4"
  python3 - "$T/dlogs" "$turn" "$start" "$end" "$text" <<'PY'
import json, sys
path, turn, start, end, text = sys.argv[1:]
data = {"ok": True, "lines": [
    {"kind": "turn.started", "turnId": turn, "at": int(start)},
    {"kind": "message", "turnId": turn, "text": text, "at": int(end) - 1},
    {"kind": "turn.completed", "turnId": turn, "terminal": "completed", "at": int(end)},
]}
json.dump(data, open(path, "w"))
PY
}
set_processes() {
  printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n' >"$T/box-procs"
}
run_lanecheck() {
  local run="$1" now="$2"
  FW_RUN="$run" FW_LANECHECK_NOW="$now" bash "$BIN/lanecheck" 2>&1
}

# Silent completed idle turn: the message must match the ticket's exact WAKE text.
r=$(newrun silent)
lane "$r" 1001 fiber-1001-build sid-1001
printf 'repo=aakshintala/fiber\nissue=1001\n' >"$r/fiber-1001.state"
set_session sid-1001 1001 turn-silent completed 1000000
set_logs turn-silent 900000 1000000 'Finished without a report.'
set_processes
out=$(run_lanecheck "$r" 1000); lrc=$?
expected="WAKE (lanecheck): your last turn ended with no STATUS line and no job running. Read $r/fiber-1001.state and your journal, take the next step your brief names, and end every turn with a STATUS line. Never background a wait: run tkt-* and delegate watch in the foreground."
if [ "$lrc" -eq 0 ] && grep -Fqx "$expected" "$T/last-send" \
   && printf '%s' "$out" | grep -q '^WAKE 1001 .*silent idle turn turn-silent (1/2 this rolling hour)'; then
  ok silent-idle-sends-exact-wake
else
  fail "silent-idle-sends-exact-wake (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# A live descendant seen on one tick is WAITING, then a gone descendant wakes
# the same idle delegate session using the command's recorded journal rc.
r=$(newrun tracked)
lane "$r" 2002 fiber-2002-build sid-2002
printf 'repo=aakshintala/fiber\nissue=2002\n' >"$r/fiber-2002.state"
printf '2026-11-09T00:00:00Z tkt-build DONE rc=7\n' >"$r/fiber-2002.journal"
set_session sid-2002 2002 turn-tracked completed 2000000
set_logs turn-tracked 1900000 2000000 'STATUS: BLOCKED on the job result'
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n101 100 00:12 bash /repo/bin/tkt-build %s/fiber-2002.state\n' "$r" >"$T/box-procs"
out=$(run_lanecheck "$r" 2000); lrc=$?
if [ "$lrc" -eq 0 ] && printf '%s' "$out" | grep -q '^WAITING 2002 .* tkt-build 12s' \
   && ! printf '%s' "$out" | grep -q '^STALL 2002'; then
  ok descendant-process-is-waiting
else
  fail "descendant-process-is-waiting (rc=$lrc out=$out)"
fi
cat >"$T/dsess" <<'EOF'
{"ok":true,"sessions":[{"id":"sid-2002","status":"running","activeTurnId":"turn-active","turnCount":5,"hostPid":100,"supervisorPid":90,"lastTurn":{"turnId":"turn-tracked","terminal":"completed","endedAt":2000000}}]}
EOF
out=$(run_lanecheck "$r" 2000); lrc=$?
if [ "$lrc" -eq 0 ] && printf '%s' "$out" | grep -q '^WAITING 2002 .* tkt-build 12s' \
   && ! printf '%s' "$out" | grep -q '^LIVE 2002\|^STALL 2002'; then
  ok descendant-process-is-waiting-during-active-turn
else
  fail "descendant-process-is-waiting-during-active-turn (rc=$lrc out=$out)"
fi
set_session sid-2002 2002 turn-tracked completed 2000000
set_processes
out=$(run_lanecheck "$r" 2001); lrc=$?
expected='WAKE (lanecheck): tkt-build finished (exit 7). Read its output and continue from your brief. End with STATUS.'
if [ "$lrc" -eq 0 ] && grep -Fqx "$expected" "$T/last-send" \
   && printf '%s' "$out" | grep -q '^WAKE 2002 .*tracked tkt-build finished (exit 7) (1/2 this rolling hour)'; then
  ok tracked-job-wakes-with-journal-exit
else
  fail "tracked-job-wakes-with-journal-exit (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# delegate watch records its gate exit code under result.gateResult.exitCode.
r=$(newrun delegate-watch-rc)
lane "$r" 2202 fiber-2202-build sid-2202
set_session sid-2202 2202 turn-watch completed 2200000
set_logs turn-watch 2100000 2200000 'STATUS: RUNNING'
printf '{"status":"DONE","result":{"gateResult":{"exitCode":23}}}\n' >"$T/jobs/job-watch.json"
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n101 100 00:12 bash /repo/bin/delegate watch job-watch\n' >"$T/box-procs"
out=$(run_lanecheck "$r" 2200)
set_processes
out=$(run_lanecheck "$r" 2201); lrc=$?
expected='WAKE (lanecheck): delegate watch finished (exit 23). Read its output and continue from your brief. End with STATUS.'
if [ "$lrc" -eq 0 ] && grep -Fqx "$expected" "$T/last-send"; then
  ok tracked-delegate-watch-uses-recorded-exit-code
else
  fail "tracked-delegate-watch-uses-recorded-exit-code (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# Claude agent PID roots use the same portable process-tree probe.
r=$(newrun claude-child)
printf '2020-01-01T00:00:00Z\t2203\tmac\tclaude-2203\t?\n' >>"$r/roster"
printf '[{"name":"claude-2203","status":"idle","pid":500}]' >"$T/cagents"
printf '500 1 00:10:00 claude --session claude-2203\n501 500 00:00:42 bash /repo/bin/tkt-plan /repo/fiber-2203.state\n' >"$T/mac-procs"
out=$(run_lanecheck "$r" 2202); lrc=$?
if [ "$lrc" -eq 0 ] && printf '%s' "$out" | grep -q '^WAITING 2203 mac claude-2203 tkt-plan 42s' \
   && ! printf '%s' "$out" | grep -q '^STALL 2203'; then
  ok claude-agent-pid-roots-process-tree
else
  fail "claude-agent-pid-roots-process-tree (rc=$lrc out=$out)"
fi
printf '[]' >"$T/cagents"
: >"$T/mac-procs"

# Unknown rc stays explicitly unknown; lanecheck never infers a status code.
r=$(newrun unknown-rc)
lane "$r" 2102 fiber-2102-build sid-2102
set_session sid-2102 2102 turn-unknown completed 3000000
set_logs turn-unknown 2900000 3000000 'STATUS: RUNNING'
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n101 100 00:12 bash /repo/bin/tkt-fix /missing/fiber-2102.state\n' >"$T/box-procs"
# Seed the process observation, then let the process disappear without a journal record.
out=$(run_lanecheck "$r" 3000)
set_processes
out=$(run_lanecheck "$r" 3001); lrc=$?
expected='WAKE (lanecheck): tkt-fix finished (exit unknown). Read its output and continue from your brief. End with STATUS.'
if [ "$lrc" -eq 0 ] && grep -Fqx "$expected" "$T/last-send"; then
  ok tracked-job-unknown-exit-is-not-guessed
else
  fail "tracked-job-unknown-exit-is-not-guessed (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# An archived ruling delivered while a turn ran is resent if the following
# STATUS line omits its ID; its complete archived contents are the new turn.
r=$(newrun missed-steer)
lane "$r" 3003 fiber-3003-build sid-3003
mkdir -p "$r/rulings"
cat >"$r/rulings/ruling-3003-RULING-3003-1.md" <<'EOF'
RULING-3003-1: continue with the amended plan.
<!-- answers-report: box-box-3003-report.md -->
EOF
python3 - "$r/rulings/ruling-3003-RULING-3003-1.md" <<'PY'
import os, sys
os.utime(sys.argv[1], (1900, 1900))
PY
set_session sid-3003 3003 turn-missed completed 2100000
python3 - "$T/dlogs" <<'PY'
import json, sys
json.dump({"ok": True, "lines": [
    {"kind": "turn.started", "turnId": "turn-missed", "at": 2000000},
    {"kind": "user", "turnId": "turn-missed", "text": "RULING-3003-1: continue with the amended plan.", "at": 2050000},
    {"kind": "message", "turnId": "turn-missed", "text": "STATUS: DONE — continuing without the ruling id", "at": 2099999},
    {"kind": "turn.completed", "turnId": "turn-missed", "terminal": "completed", "at": 2100000},
]}, open(sys.argv[1], "w"))
PY
set_processes
out=$(run_lanecheck "$r" 2100); lrc=$?
if [ "$lrc" -eq 0 ] && cmp -s "$r/rulings/ruling-3003-RULING-3003-1.md" "$T/last-send" \
   && printf '%s' "$out" | grep -q '^WAKE 3003 .*missed steer RULING-3003-1 (1/2 this rolling hour)'; then
  ok missed-steer-resends-archived-answer
else
  fail "missed-steer-resends-archived-answer (rc=$lrc out=$out)"
fi

r_missed="$r"

# A STATUS that predates the answer is not the lane's next STATUS.
r=$(newrun missed-steer-next-status)
lane "$r" 3005 fiber-3005-build sid-3005
mkdir -p "$r/rulings"
cat >"$r/rulings/ruling-3005-RULING-3005-1.md" <<'EOF'
RULING-3005-1: continue with the answer.
EOF
python3 - "$r/rulings/ruling-3005-RULING-3005-1.md" <<'PY'
import os, sys
os.utime(sys.argv[1], (4050, 4050))
PY
set_session sid-3005 3005 turn-3005 completed 4100000
python3 - "$T/dlogs" <<'PY'
import json, sys
json.dump({"ok": True, "lines": [
    {"kind": "turn.started", "turnId": "turn-3005", "at": 4000000},
    {"kind": "message", "turnId": "turn-3005", "text": "STATUS: RULING-3005-1 applied earlier", "at": 4010000},
    {"kind": "turn.completed", "turnId": "turn-3005", "terminal": "completed", "at": 4100000},
]}, open(sys.argv[1], "w"))
PY
set_processes
out=$(run_lanecheck "$r" 4100); lrc=$?
if [ "$lrc" -eq 0 ] && cmp -s "$r/rulings/ruling-3005-RULING-3005-1.md" "$T/last-send" \
   && printf '%s' "$out" | grep -q '^WAKE 3005 .*missed steer RULING-3005-1'; then
  ok missed-steer-ignores-a-status-before-the-answer
else
  fail "missed-steer-ignores-a-status-before-the-answer (rc=$lrc out=$out)"
fi

# A subsequent STATUS that mentions the ID is accepted and is not resent.
: >"$T/send-commands"
: >"$T/sent-messages"
set_logs turn-missed 2000000 2100000 'STATUS: DONE — RULING-3003-1 applied'
set_session sid-3003 3003 turn-missed completed 2100000
out=$(run_lanecheck "$r_missed" 2101); lrc=$?
if [ "$lrc" -eq 0 ] && [ ! -s "$T/send-commands" ]; then
  ok acknowledged-answer-is-not-resent
else
  fail "acknowledged-answer-is-not-resent (rc=$lrc out=$out)"
fi

# Silent wakes and missed-steer resends share the same persisted rolling cap.
r=$(newrun shared-cap)
lane "$r" 4004 fiber-4004-build sid-4004
mkdir -p "$r/rulings"
set_processes
: >"$T/send-commands"
: >"$T/sent-messages"
for turn in 1 2; do
  ended=$((turn * 1000000))
  set_session sid-4004 4004 "turn-cap-$turn" completed "$ended"
  set_logs "turn-cap-$turn" "$((ended - 100000))" "$ended" 'No status this turn'
  out=$(run_lanecheck "$r" "$((turn * 1000))")
done
cat >"$r/rulings/ruling-4004-RULING-4004-1.md" <<'EOF'
RULING-4004-1: apply this answer.
EOF
python3 - "$r/rulings/ruling-4004-RULING-4004-1.md" <<'PY'
import os, sys
os.utime(sys.argv[1], (2050, 2050))
PY
set_session sid-4004 4004 turn-cap-3 completed 3000000
set_logs turn-cap-3 2000000 3000000 'STATUS: DONE but answer was missed'
out=$(run_lanecheck "$r" 2500); lrc=$?
send_count=$(grep -c 'delegate session send' "$T/send-commands" || true)
if [ "$lrc" -eq 0 ] && [ "$send_count" -eq 2 ] \
   && printf '%s' "$out" | grep -q '^STALL 4004 .*missed steer RULING-4004-1; wake cap reached (2/2 this rolling hour)' \
   && [ -f "$r/lanecheck-wake.json" ]; then
  ok shared-cap-blocks-resend-after-two-wakes
else
  fail "shared-cap-blocks-resend-after-two-wakes (rc=$lrc sends=$send_count out=$out)"
fi
set_session sid-4004 4004 turn-cap-4 completed 4000000
set_logs turn-cap-4 3900000 4000000 'No status this turn'
out=$(run_lanecheck "$r" 6101); lrc=$?
send_count=$(grep -c 'delegate session send' "$T/send-commands" || true)
if [ "$lrc" -eq 0 ] && [ "$send_count" -eq 3 ] \
   && printf '%s' "$out" | grep -q '^WAKE 4004 .*silent idle turn turn-cap-4 (1/2 this rolling hour)'; then
  ok rolling-hour-cap-expires
else
  fail "rolling-hour-cap-expires (rc=$lrc sends=$send_count out=$out)"
fi

# The real #4177 shape: tkt-fix is visible to the ticket-wide pending probe,
# but its PPID has moved outside the session's process tree. It must be tracked
# by PID/cmd so the same lane gets a job-exit wake when that process disappears.
r=$(newrun reparented-tkt-fix)
lane "$r" 4177 fiber-4177 sid-4177
printf 'repo=aakshintala/fiber\nissue=4177\n' >"$r/fiber-4177.state"
set_session sid-4177 4177 turn-reparented completed 5000000
set_logs turn-reparented 4900000 5000000 'STATUS: PENDING fix job'
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n101 1 00:12 /bin/sh -c tkt-fix %s/fiber-4177.state --no-verify\n' "$r" >"$T/box-procs"
printf '/bin/sh -c tkt-fix %s/fiber-4177.state --no-verify\n' "$r" >"$T/pending"
: >"$T/send-commands"
: >"$T/sent-messages"
: >"$T/last-send"
out=$(run_lanecheck "$r" 5000); lrc=$?

if [ "$lrc" -eq 0 ] && printf '%s' "$out" | grep -q '^WAITING 4177 .* tkt-fix 12s' \
   && ! printf '%s' "$out" | grep -q '^ABANDONED 4177'; then
  ok reparented-pending-job-is-waiting
else
  fail "reparented-pending-job-is-waiting (rc=$lrc out=$out)"
fi
set_processes
: >"$T/pending"
: >"$T/last-send"
out=$(run_lanecheck "$r" 5001); lrc=$?

expected='WAKE (lanecheck): tkt-fix finished (exit unknown). Read its output and continue from your brief. End with STATUS.'
if [ "$lrc" -eq 0 ] && grep -Fqx "$expected" "$T/last-send" \
   && printf '%s' "$out" | grep -q '^WAKE 4177 .*tkt-fix finished (exit unknown) (1/2 this rolling hour)'; then
  ok reparented-pending-job-exit-wakes-lane
else
  fail "reparented-pending-job-exit-wakes-lane (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# The live #4054 ruling used the FW13 header and arrived in the archive during
# the turn, after its only STATUS. Its user steer is in the following turn.
r=$(newrun missed-fw-ruling)
lane "$r" 4054 fiber-4054 sid-4054
mkdir -p "$r/rulings"
cat >"$r/fiber-4054-report.md" <<'EOF'
STATUS: BLOCKED awaiting the ruling's plan grant.
EOF
cat >"$r/rulings/ruling-4054-ruling-13.md" <<'EOF'
RULING FW13 (flywheel, #4054): continue with the amended plan.
<!-- answers-report: fiber-4054-report.md -->
EOF
python3 - "$r/fiber-4054-report.md" "$r/rulings/ruling-4054-ruling-13.md" <<'PY'
import os, sys
os.utime(sys.argv[1], (1794253000.0, 1794253000.0))
os.utime(sys.argv[2], (1794253095.305, 1794253095.305))
PY
set_session sid-4054 4054 turn-fw13 completed 1794253103396
python3 - "$T/dlogs" <<'PY'
import json, sys
json.dump({"ok": True, "lines": [
    {"kind": "turn.started", "turnId": "turn-fw13", "at": 1794253055687},
    {"kind": "message", "turnId": "turn-fw13",
     "text": "STATUS: BLOCKED on the plan grant", "at": 1794253070166},
    {"kind": "turn.completed", "turnId": "turn-fw13", "terminal": "completed",
     "at": 1794253103396},
    {"kind": "turn.started", "turnId": "turn-after-fw13", "at": 1794253142760},
    {"kind": "user", "turnId": "turn-after-fw13",
     "text": "RULING FW13 (flywheel, #4054): continue with the amended plan.",
     "at": 1794253142760},
]}, open(sys.argv[1], "w"))
PY
set_processes
: >"$T/send-commands"
: >"$T/sent-messages"
: >"$T/last-send"
out=$(run_lanecheck "$r" 1794253200); lrc=$?

if [ "$lrc" -eq 0 ] && cmp -s "$r/rulings/ruling-4054-ruling-13.md" "$T/last-send" \
   && printf '%s' "$out" | grep -q '^WAKE 4054 .*missed steer FW13 (1/2 this rolling hour)'; then
  ok missed-fw-ruling-is-resent
else
  fail "missed-fw-ruling-is-resent (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

exit "$rc"

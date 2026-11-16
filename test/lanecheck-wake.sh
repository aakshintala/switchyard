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
  *"delegate session stop "*) printf '%s\n' "$*" >>"$STUBD/stop-commands"; echo '{"ok":true}';;
  *"delegate session logs"*) cat "$STUBD/dlogs" 2>/dev/null || echo '{"ok":true,"lines":[]}';;
  *"delegate session send"*)
    if [ -f "$STUBD/send-busy" ]; then
      cat >/dev/null
      echo 'session is busy' >&2
      exit 5
    fi
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
cat >"$T/stub/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  cat "$STUBD/pr-view-${3:-}" 2>/dev/null || exit 1
  exit 0
fi
exit 0
EOF
for stub in file-claim inbox-watchers boxstale; do
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
{"ok":true,"sessions":[{"id":"$sid","status":"idle","activeTurnId":null,"turnCount":4,"hostPid":100,"supervisorPid":90,"lastTurn":{"turnId":"$turn","terminal":"$terminal","endedAt":$ended}}]}
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

# A populated roster needs its retirement ledger. Without it, lanecheck must
# stop before reporting lanes or sending any wake, steer or resend.
r="$T/missing-retirement-ledger"
mkdir -p "$r"
printf '2026-01-01T00:00:00Z\t1722\tbox\tfiber-1722-build\tsid-1722\n' >"$r/roster"
rm -f "$r/roster-done"
: >"$T/send-commands"
: >"$T/sent-messages"
out=$(run_lanecheck "$r" 3000); lrc=$?
if [ "$lrc" -eq 2 ] \
    && printf '%s\n' "$out" | grep -Fqx "lanecheck: $r/roster-done missing; roster has rows, refusing to wake, steer or resend this run" \
    && [ ! -e "$r/roster-done" ] \
    && [ ! -s "$T/send-commands" ] && [ ! -s "$T/sent-messages" ]; then
  ok populated-roster-without-retirement-ledger-refuses-actions
else
  fail "populated-roster-without-retirement-ledger-refuses-actions (rc=$lrc out=$out commands=$(cat "$T/send-commands") messages=$(cat "$T/sent-messages"))"
fi
# `done` must not create the ledger either: one appended row would make the
# next run read every other retired lane as live.
out=$(FW_RUN="$r" FW_LANECHECK_NOW=3000 bash "$BIN/lanecheck" done 1722 2>&1); lrc=$?
if [ "$lrc" -eq 2 ] \
    && printf '%s\n' "$out" | grep -Fqx "lanecheck: $r/roster-done missing; roster has rows, refusing to retire lanes this run" \
    && [ ! -e "$r/roster-done" ] && [ ! -s "$T/send-commands" ]; then
  ok done-without-retirement-ledger-refuses
else
  fail "done-without-retirement-ledger-refuses (rc=$lrc out=$out)"
fi
# An existing empty ledger passes the guard, so the first retirement can fill it.
: >"$r/roster-done"
out=$(FW_RUN="$r" FW_LANECHECK_NOW=3000 bash "$BIN/lanecheck" done 1722 2>&1)
if ! printf '%s\n' "$out" | grep -Fq "refusing to retire lanes"; then
  ok done-with-empty-retirement-ledger-passes-guard
else
  fail "done-with-empty-retirement-ledger-passes-guard (out=$out)"
fi

# No roster remains a no-op, while an empty roster still gets an empty ledger.
r="$T/no-roster"
mkdir -p "$r"
out=$(run_lanecheck "$r" 3001); lrc=$?
if [ "$lrc" -eq 0 ] && printf '%s\n' "$out" | grep -Fqx "no roster at $r/roster" \
    && [ ! -e "$r/roster-done" ]; then
  ok missing-roster-remains-no-op
else
  fail "missing-roster-remains-no-op (rc=$lrc out=$out)"
fi
r="$T/empty-roster"
mkdir -p "$r"
: >"$r/roster"
rm -f "$r/roster-done"
out=$(run_lanecheck "$r" 3002); lrc=$?
if [ "$lrc" -eq 0 ] && [ -f "$r/roster-done" ] && [ ! -s "$r/roster-done" ]; then
  ok empty-roster-still-creates-empty-ledger
else
  fail "empty-roster-still-creates-empty-ledger (rc=$lrc out=$out)"
fi

# Silent completed idle turn: the message must match the ticket's exact WAKE text.
r=$(newrun silent)
lane "$r" 1001 fiber-1001-build sid-1001
printf 'repo=aakshintala/fiber\nissue=1001\n' >"$r/fiber-1001.state"
set_session sid-1001 1001 turn-silent completed 1000000
set_logs turn-silent 900000 1000000 'Finished without a report.'
set_processes
out=$(run_lanecheck "$r" 1000); lrc=$?
expected="WAKE (lanecheck): ticket #1001, session log turn turn-silent ended with no STATUS line and no job running. Read $r/fiber-1001.state and your journal, take the next step your brief names, and end every turn with a STATUS line. Never background a wait: run tkt-* and delegate watch in the foreground."
if [ "$lrc" -eq 0 ] && grep -Fqx "$expected" "$T/last-send" \
   && printf '%s' "$out" | grep -q '^WAKE 1001 .*silent idle turn turn-silent (1/2 this rolling hour)'; then
  ok silent-idle-sends-exact-wake
else
  fail "silent-idle-sends-exact-wake (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# A busy replay bridge must leave a wake action retryable, not consume it.
r=$(newrun busy-send-retry)
lane "$r" 1002 fiber-1002-build sid-1002
printf 'repo=aakshintala/fiber\nissue=1002\n' >"$r/fiber-1002.state"
set_session sid-1002 1002 turn-busy completed 1000000
set_logs turn-busy 900000 1000000 'Finished without a report.'
set_processes
touch "$T/send-busy"
out=$(run_lanecheck "$r" 1000); lrc=$?
if [ "$lrc" -eq 0 ] && printf '%s' "$out" | grep -q '^WAKE-DEFERRED 1002 .* action remains pending'; then
  ok busy-wake-remains-pending
else
  fail "busy-wake-remains-pending (rc=$lrc out=$out)"
fi
rm -f "$T/send-busy"
out=$(run_lanecheck "$r" 1000); lrc=$?
if [ "$lrc" -eq 0 ] && grep -Fqx 'WAKE (lanecheck): ticket #1002, session log turn turn-busy ended with no STATUS line and no job running. Read '"$r"'/fiber-1002.state and your journal, take the next step your brief names, and end every turn with a STATUS line. Never background a wait: run tkt-* and delegate watch in the foreground.' "$T/last-send" \
   && printf '%s' "$out" | grep -q '^WAKE 1002 .*silent idle turn turn-busy'; then
  ok busy-wake-retries-after-busy
else
  fail "busy-wake-retries-after-busy (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# A live descendant seen on one tick is WAITING, then a gone descendant wakes
# the same idle delegate session using the command's recorded journal rc.
r=$(newrun tracked)
lane "$r" 2002 fiber-2002-build sid-2002
printf 'repo=example/fiber\nissue=2002\njob.lane=job-2002\n' >"$r/fiber-2002.state"
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
expected='WAKE (lanecheck): ticket #2002, job job-2002 (tkt-build) finished (exit 7). Read job job-2002 output and continue from your brief. End with STATUS.'
if [ "$lrc" -eq 0 ] && grep -Fqx "$expected" "$T/last-send" \
   && printf '%s' "$out" | grep -q '^WAKE 2002 .*job job-2002 (tkt-build) finished (exit 7) (1/2 this rolling hour)'; then
  ok tracked-job-wakes-with-journal-exit
else
  fail "tracked-job-wakes-with-journal-exit (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# delegate watch records its gate exit code under result.gateResult.exitCode.
r=$(newrun delegate-watch-rc)
lane "$r" 2202 fiber-2202-build sid-2202
printf 'repo=example/fiber\nissue=2202\njob.lane=job-watch\n' >"$r/fiber-2202.state"
set_session sid-2202 2202 turn-watch completed 2200000
set_logs turn-watch 2100000 2200000 'STATUS: RUNNING'
printf '{"status":"DONE","result":{"gateResult":{"exitCode":23}}}\n' >"$T/jobs/job-watch.json"
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n101 100 00:12 bash /repo/bin/delegate watch job-watch\n' >"$T/box-procs"
out=$(run_lanecheck "$r" 2200)
set_processes
out=$(run_lanecheck "$r" 2201); lrc=$?
expected='WAKE (lanecheck): ticket #2202, job job-watch (delegate watch) finished (exit 23). Read job job-watch output and continue from your brief. End with STATUS.'
if [ "$lrc" -eq 0 ] && grep -Fqx "$expected" "$T/last-send"; then
  ok tracked-delegate-watch-uses-recorded-exit-code
else
  fail "tracked-delegate-watch-uses-recorded-exit-code (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# Claude agent PID roots use the same portable process-tree probe.
r=$(newrun claude-child)
printf '2020-01-01T00:00:00Z\t2203\tmac\tclaude-2203\t?\n' >>"$r/roster"
printf '[{"name":"claude-2203","status":"idle","pid":500}]' >"$T/cagents"
printf 'repo=example/switchyard\nissue=2203\n' >"$r/fiber-2203.state"
printf '500 1 00:10:00 claude --session claude-2203\n501 500 00:00:42 bash /repo/bin/tkt-plan %s/fiber-2203.state\n' "$r" >"$T/mac-procs"
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
printf 'repo=example/switchyard\nissue=2102\njob.fix1=job-2102\n' >"$r/fiber-2102.state"
set_session sid-2102 2102 turn-unknown completed 3000000
set_logs turn-unknown 2900000 3000000 'STATUS: RUNNING'
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n101 100 00:12 bash /repo/bin/tkt-fix %s/fiber-2102.state\n' "$r" >"$T/box-procs"
# Seed the process observation, then let the process disappear without a journal record.
out=$(run_lanecheck "$r" 3000)
set_processes
out=$(run_lanecheck "$r" 3001); lrc=$?
expected='WAKE (lanecheck): ticket #2102, job job-2102 (tkt-fix) finished (exit unknown). Read job job-2102 output and continue from your brief. End with STATUS.'
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
if [ "$lrc" -eq 0 ] && grep -Fq "ticket #3003, ruling path $r/rulings/ruling-3003-RULING-3003-1.md (missed steer RULING-3003-1)." "$T/last-send" \
   && tail -n +3 "$T/last-send" | cmp -s - "$r/rulings/ruling-3003-RULING-3003-1.md" \
   && printf '%s' "$out" | grep -q '^WAKE 3003 .*missed steer RULING-3003-1 (1/2 this rolling hour)'; then
  ok missed-steer-resends-archived-answer
else
  fail "missed-steer-resends-archived-answer (rc=$lrc out=$out)"
fi

r_missed="$r"

# An ID cited only in a later assistant message body is an acknowledgement,
# even when the STATUS line does not repeat it.
r=$(newrun missed-steer-body-ack)
lane "$r" 3004 fiber-3004-build sid-3004
mkdir -p "$r/rulings"
cat >"$r/rulings/ruling-3004-RULING-3004-1.md" <<'EOF'
RULING-3004-1: apply this answer.
EOF
python3 - "$r/rulings/ruling-3004-RULING-3004-1.md" <<'PY'
import os, sys
os.utime(sys.argv[1], (1900, 1900))
PY
set_session sid-3004 3004 turn-body-ack completed 2100000
python3 - "$T/dlogs" <<'PY'
import json, sys
json.dump({"ok": True, "lines": [
    {"kind": "turn.started", "turnId": "turn-body-ack", "at": 2000000},
    {"kind": "user", "turnId": "turn-body-ack", "text": "RULING-3004-1: apply this answer.", "at": 2050000},
    {"kind": "message", "turnId": "turn-body-ack", "text": "RULING-3004-1 was applied to the plan.", "at": 2099998},
    {"kind": "message", "turnId": "turn-body-ack", "text": "STATUS: DONE — plan updated", "at": 2099999},
    {"kind": "turn.completed", "turnId": "turn-body-ack", "terminal": "completed", "at": 2100000},
]}, open(sys.argv[1], "w"))
PY
set_processes
: >"$T/send-commands"
out=$(run_lanecheck "$r" 2101); lrc=$?
if [ "$lrc" -eq 0 ] && [ ! -s "$T/send-commands" ]; then
  ok missed-steer-body-citation-acknowledges
else
  fail "missed-steer-body-citation-acknowledges (rc=$lrc out=$out)"
fi

# An ACK line in a lane report received after delivery also acknowledges it.
r=$(newrun missed-steer-report-ack)
lane "$r" 3006 fiber-3006-build sid-3006
mkdir -p "$r/rulings" "$r/inbox"
cat >"$r/rulings/ruling-3006-admit.md" <<'EOF'
ADMIT-3006-4: proceed with the admitted plan.
EOF
cat >"$r/inbox/box-box-3006-report.md" <<'EOF'
STATUS: DONE — admitted plan implemented
ACK ADMIT-3006-4
EOF
python3 - "$r/inbox/box-box-3006-report.md" <<'PY'
import os, sys
os.utime(sys.argv[1], (2075, 2075))
PY
set_session sid-3006 3006 turn-report-ack completed 2100000
python3 - "$T/dlogs" <<'PY'
import json, sys
json.dump({"ok": True, "lines": [
    {"kind": "turn.started", "turnId": "turn-report-ack", "at": 2000000},
    {"kind": "user", "turnId": "turn-report-ack", "text": "ADMIT-3006-4: proceed with the admitted plan.", "at": 2050000},
    {"kind": "message", "turnId": "turn-report-ack", "text": "STATUS: DONE — work complete", "at": 2099999},
    {"kind": "turn.completed", "turnId": "turn-report-ack", "terminal": "completed", "at": 2100000},
]}, open(sys.argv[1], "w"))
PY
set_processes
: >"$T/send-commands"
out=$(run_lanecheck "$r" 2101); lrc=$?
if [ "$lrc" -eq 0 ] && [ ! -s "$T/send-commands" ]; then
  ok missed-steer-ack-line-in-inbox-report-acknowledges
else
  fail "missed-steer-ack-line-in-inbox-report-acknowledges (rc=$lrc out=$out)"
fi

# The archive glob accepts any ruling suffix, including -admit-diag.
r=$(newrun missed-steer-admit-diag)
lane "$r" 3007 fiber-3007-build sid-3007
mkdir -p "$r/rulings"
cat >"$r/rulings/ruling-3007-admit-diag.md" <<'EOF'
ADMIT-3007-2: continue with the diagnostic admission.
EOF
python3 - "$r/rulings/ruling-3007-admit-diag.md" <<'PY'
import os, sys
os.utime(sys.argv[1], (1900, 1900))
PY
set_session sid-3007 3007 turn-admit-diag completed 2100000
python3 - "$T/dlogs" <<'PY'
import json, sys
json.dump({"ok": True, "lines": [
    {"kind": "turn.started", "turnId": "turn-admit-diag", "at": 2000000},
    {"kind": "user", "turnId": "turn-admit-diag", "text": "ADMIT-3007-2: continue with the diagnostic admission.", "at": 2050000},
    {"kind": "message", "turnId": "turn-admit-diag", "text": "STATUS: DONE — diagnostic plan reviewed without citing its ID", "at": 2099999},
    {"kind": "turn.completed", "turnId": "turn-admit-diag", "terminal": "completed", "at": 2100000},
]}, open(sys.argv[1], "w"))
PY
set_processes
: >"$T/send-commands"
out=$(run_lanecheck "$r" 2101); lrc=$?
if [ "$lrc" -eq 0 ] && grep -Fq "ticket #3007, ruling path $r/rulings/ruling-3007-admit-diag.md (missed steer ADMIT-3007-2)." "$T/last-send" \
   && tail -n +3 "$T/last-send" | cmp -s - "$r/rulings/ruling-3007-admit-diag.md" \
   && printf '%s' "$out" | grep -q '^WAKE 3007 .*missed steer ADMIT-3007-2'; then
  ok missed-steer-finds-admit-diag-suffixed-ruling
else
  fail "missed-steer-finds-admit-diag-suffixed-ruling (rc=$lrc out=$out)"
fi

# Assistant text that predates delivery cannot acknowledge the answer.
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
if [ "$lrc" -eq 0 ] && grep -Fq "ticket #3005, ruling path $r/rulings/ruling-3005-RULING-3005-1.md (missed steer RULING-3005-1)." "$T/last-send" \
   && tail -n +3 "$T/last-send" | cmp -s - "$r/rulings/ruling-3005-RULING-3005-1.md" \
   && printf '%s' "$out" | grep -q '^WAKE 3005 .*missed steer RULING-3005-1'; then
  ok missed-steer-ignores-assistant-text-before-delivery
else
  fail "missed-steer-ignores-assistant-text-before-delivery (rc=$lrc out=$out)"
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
printf 'repo=example/fiber\nissue=4177\njob.fix1=job-4177\n' >"$r/fiber-4177.state"
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

expected='WAKE (lanecheck): ticket #4177, job job-4177 (tkt-fix) finished (exit unknown). Read job job-4177 output and continue from your brief. End with STATUS.'
if [ "$lrc" -eq 0 ] && grep -Fqx "$expected" "$T/last-send" \
   && printf '%s' "$out" | grep -q '^WAKE 4177 .*job job-4177 (tkt-fix) finished (exit unknown) (1/2 this rolling hour)'; then
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

if [ "$lrc" -eq 0 ] && grep -Fq "ticket #4054, ruling path $r/rulings/ruling-4054-ruling-13.md (missed steer FW13)." "$T/last-send" \
   && tail -n +3 "$T/last-send" | cmp -s - "$r/rulings/ruling-4054-ruling-13.md" \
   && printf '%s' "$out" | grep -q '^WAKE 4054 .*missed steer FW13 (1/2 this rolling hour)'; then
  ok missed-fw-ruling-is-resent
else
  fail "missed-fw-ruling-is-resent (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# A STATUS: HOLD report suppresses wake messages until a newer ruling arrives.
r=$(newrun hold-status)
lane "$r" 5101 fiber-5101-build sid-5101
mkdir -p "$r/rulings"
printf 'repo=example/switchyard\nissue=5101\njob.lane=job-5101\n' >"$r/fiber-5101.state"
set_session sid-5101 5101 turn-hold-status completed 3000000
set_logs turn-hold-status 2900000 3000000 'STATUS: DONE'
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n101 100 00:12 bash /repo/bin/tkt-build %s/fiber-5101.state\n' "$r" >"$T/box-procs"
: >"$T/send-commands"
out=$(run_lanecheck "$r" 3000)
set_processes
printf 'STATUS: HOLD — waiting for a ruling.\n' >"$r/fiber-5101-report.md"
python3 - "$r/fiber-5101-report.md" <<'PY'
import os, sys
os.utime(sys.argv[1], (1794253000, 1794253000))
PY
out=$(run_lanecheck "$r" 3000); lrc=$?
if [ "$lrc" -eq 0 ] && printf '%s\n' "$out" | grep -Fqx 'WAITING 5101 hold' \
   && [ ! -s "$T/send-commands" ]; then
  ok status-hold-waits-without-wake
else
  fail "status-hold-waits-without-wake (rc=$lrc out=$out commands=$(cat "$T/send-commands" 2>/dev/null))"
fi
cat >"$r/rulings/ruling-5101-RULING-5101-2.md" <<'EOF'
RULING-5101-2: continue with the next step.
EOF
python3 - "$r/rulings/ruling-5101-RULING-5101-2.md" <<'PY'
import os, sys
os.utime(sys.argv[1], (1794253010, 1794253010))
PY
set_processes
: >"$T/last-send"
out=$(run_lanecheck "$r" 3001); lrc=$?
if [ "$lrc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^WAKE 5101 .*job job-5101 (tkt-build) finished' \
   && grep -Fq 'ticket #5101, job job-5101 (tkt-build)' "$T/last-send"; then
  ok newer-ruling-clears-hold-and-normal-wake-fires
else
  fail "newer-ruling-clears-hold-and-normal-wake-fires (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# An ACK of an archived hold ruling suppresses wakes just like STATUS: HOLD.
r=$(newrun hold-ack)
lane "$r" 5102 fiber-5102-build sid-5102
printf 'repo=example/switchyard\nissue=5102\njob.fix1=job-5102\n' >"$r/fiber-5102.state"
mkdir -p "$r/rulings"
set_session sid-5102 5102 turn-hold-ack completed 3000000
set_logs turn-hold-ack 2900000 3000000 'STATUS: DONE'
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n101 100 00:12 bash /repo/bin/tkt-fix %s/fiber-5102.state\n' "$r" >"$T/box-procs"
: >"$T/send-commands"
out=$(run_lanecheck "$r" 3000)
set_processes
cat >"$r/rulings/ruling-5102-RULING-5102-1.md" <<'EOF'
RULING-5102-1: hold this lane until the next ruling.
hold: wait for an explicit go-ahead.
EOF
cat >"$r/fiber-5102-report.md" <<'EOF'
STATUS: DONE — work paused.
ACK RULING-5102-1
EOF
python3 - "$r/rulings/ruling-5102-RULING-5102-1.md" "$r/fiber-5102-report.md" <<'PY'
import os, sys
os.utime(sys.argv[1], (1794253000, 1794253000))
os.utime(sys.argv[2], (1794253001, 1794253001))
PY
: >"$T/send-commands"
out=$(run_lanecheck "$r" 3000); lrc=$?
if [ "$lrc" -eq 0 ] && printf '%s\n' "$out" | grep -Fqx 'WAITING 5102 hold' \
   && [ ! -s "$T/send-commands" ]; then
  ok ack-of-hold-ruling-waits-without-wake
else
  fail "ack-of-hold-ruling-waits-without-wake (rc=$lrc out=$out commands=$(cat "$T/send-commands" 2>/dev/null))"
fi

# A go ruling may mention a hold without marking itself as a hold.
r=$(newrun ack-of-go-ruling)
lane "$r" 5103 fiber-5103-build sid-5103
printf 'repo=example/switchyard\nissue=5103\njob.fix1=job-5103\n' >"$r/fiber-5103.state"
mkdir -p "$r/rulings"
set_session sid-5103 5103 turn-go-ack completed 3000000
set_logs turn-go-ack 2900000 3000000 'STATUS: DONE'
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n101 100 00:12 bash /repo/bin/tkt-fix %s/fiber-5103.state\n' "$r" >"$T/box-procs"
: >"$T/send-commands"
out=$(run_lanecheck "$r" 3000)
set_processes
cat >"$r/rulings/ruling-5103-RULING-5103-1.md" <<'EOF'
RULING-5103-1: proceed with the plan.
Go: the breaker hold ends.
Continue with the rest of the plan.
EOF
cat >"$r/fiber-5103-report.md" <<'EOF'
STATUS: DONE — work continues.
ACK RULING-5103-1
EOF
python3 - "$r/rulings/ruling-5103-RULING-5103-1.md" "$r/fiber-5103-report.md" <<'PY'
import os, sys
os.utime(sys.argv[1], (1794253000, 1794253000))
os.utime(sys.argv[2], (1794253001, 1794253001))
PY
: >"$T/last-send"
out=$(run_lanecheck "$r" 3000); lrc=$?
if [ "$lrc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^WAKE 5103 .*job job-5103 (tkt-fix) finished' \
   && grep -Fq 'ticket #5103, job job-5103 (tkt-fix)' "$T/last-send"; then
  ok acked-go-ruling-prose-hold-does-not-suppress-wake
else
  fail "acked-go-ruling-prose-hold-does-not-suppress-wake (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# A detached job's incidental args may mention another ticket; its state file
# is the owner. The job wakes only ticket A and names A's delegate job id.
r=$(newrun cross-ticket-job)
lane "$r" 6101 fiber-6101-build sid-6101
lane "$r" 6102 fiber-6102-build sid-6102
printf 'repo=example/switchyard\nissue=6101\njob.fix1=job-A-6101\n' >"$r/fiber-6101.state"
printf 'repo=example/switchyard\nissue=6102\n' >"$r/fiber-6102.state"
cat >"$T/dsess" <<'EOF'
{"ok":true,"sessions":[
 {"id":"sid-6101","status":"idle","turnCount":4,"hostPid":100,"supervisorPid":90,"lastTurn":{"turnId":"turn-cross","terminal":"completed","endedAt":3000000}},
 {"id":"sid-6102","status":"idle","turnCount":4,"hostPid":101,"supervisorPid":91,"lastTurn":{"turnId":"turn-cross","terminal":"completed","endedAt":3000000}}
]}
EOF
set_logs turn-cross 2900000 3000000 'STATUS: DONE'
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n91 1 01:00:00 delegate __supervise\n101 91 00:30 muse serve\n110 1 00:12 bash /repo/bin/tkt-fix %s/fiber-6101.state --note %s/fiber-6102-tkt-job.log\n' "$r" "$r" >"$T/box-procs"
: >"$T/send-commands"
: >"$T/sent-messages"
out=$(run_lanecheck "$r" 3000)
set_processes
: >"$T/last-send"
out=$(run_lanecheck "$r" 3001); lrc=$?
if [ "$lrc" -eq 0 ] && [ "$(grep -c 'delegate session send' "$T/send-commands" || true)" -eq 1 ] \
   && printf '%s\n' "$out" | grep -q '^WAKE 6101 .*job job-A-6101 (tkt-fix) finished' \
   && ! printf '%s\n' "$out" | grep -q '^WAKE 6102 ' \
   && grep -Fq 'ticket #6101, job job-A-6101 (tkt-fix)' "$T/last-send"; then
  ok finished-job-is-ticket-scoped-and-wake-names-job
else
  fail "finished-job-is-ticket-scoped-and-wake-names-job (rc=$lrc out=$out sends=$(cat "$T/send-commands" 2>/dev/null) message=$(cat "$T/last-send" 2>/dev/null))"
fi

# A newer fix slot must not replace the ID captured for the older process.
r=$(newrun older-finished-fix)
lane "$r" 6301 fiber-6301-build sid-6301
printf 'repo=example/switchyard\nissue=6301\nfixopen=1\njob.fix1=job-A-6301\n' >"$r/fiber-6301.state"
set_session sid-6301 6301 turn-older-fix completed 3000000
set_logs turn-older-fix 2900000 3000000 'STATUS: DONE'
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n101 100 00:12 bash /repo/bin/tkt-fix %s/fiber-6301.state\n' "$r" >"$T/box-procs"
: >"$T/send-commands"
out=$(run_lanecheck "$r" 3000)
printf 'repo=example/switchyard\nissue=6301\nfixopen=2\njob.fix1=job-A-6301\njob.fix2=job-B-6301\n' >"$r/fiber-6301.state"
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n102 100 00:10 bash /repo/bin/tkt-fix %s/fiber-6301.state\n' "$r" >"$T/box-procs"
out=$(run_lanecheck "$r" 3001)
set_processes
: >"$T/last-send"
out=$(run_lanecheck "$r" 3002); lrc=$?
if [ "$lrc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^WAKE 6301 .*job job-A-6301 (tkt-fix) finished' \
   && grep -Fq 'ticket #6301, job job-A-6301 (tkt-fix)' "$T/last-send"; then
  ok finished-older-job-wakes-with-its-own-id
else
  fail "finished-older-job-wakes-with-its-own-id (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# An open fix slot without its job ID must not borrow a unique other slot ID.
r=$(newrun fixopen-without-job-id)
lane "$r" 6302 fiber-6302-build sid-6302
printf 'repo=example/switchyard\nissue=6302\nfixopen=2\njob.preflight=job-preflight-6302\n' >"$r/fiber-6302.state"
set_session sid-6302 6302 turn-fixopen-missing completed 3000000
set_logs turn-fixopen-missing 2900000 3000000 'STATUS: DONE'
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n101 100 00:12 bash /repo/bin/tkt-fix %s/fiber-6302.state\n' "$r" >"$T/box-procs"
: >"$T/send-commands"
out=$(run_lanecheck "$r" 3000)
set_processes
: >"$T/last-send"
out=$(run_lanecheck "$r" 3001); lrc=$?
if [ "$lrc" -eq 0 ] && grep -Fq "ticket #6302, tkt-fix pid 101 (state $r/fiber-6302.state) finished (exit unknown)" "$T/last-send" \
   && ! grep -Fq 'job job-preflight-6302' "$T/last-send"; then
  ok fixopen-without-job-id-does-not-borrow-other-slot
else
  fail "fixopen-without-job-id-does-not-borrow-other-slot (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# A still-running fix process picks up its own ID after tkt-fix writes the slot.
r=$(newrun fixopen-job-id-arrives-later)
lane "$r" 6303 fiber-6303-build sid-6303
printf 'repo=example/switchyard\nissue=6303\nfixopen=2\njob.preflight=job-preflight-6303\n' >"$r/fiber-6303.state"
set_session sid-6303 6303 turn-fixopen-later completed 3000000
set_logs turn-fixopen-later 2900000 3000000 'STATUS: DONE'
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n101 100 00:12 bash /repo/bin/tkt-fix %s/fiber-6303.state\n' "$r" >"$T/box-procs"
: >"$T/send-commands"
out=$(run_lanecheck "$r" 3000)
printf 'repo=example/switchyard\nissue=6303\nfixopen=2\njob.preflight=job-preflight-6303\njob.fix2=job-fix2-6303\n' >"$r/fiber-6303.state"
out=$(run_lanecheck "$r" 3001)
set_processes
: >"$T/last-send"
out=$(run_lanecheck "$r" 3002); lrc=$?
if [ "$lrc" -eq 0 ] && printf '%s\n' "$out" | grep -Fq 'job job-fix2-6303 (tkt-fix) finished' \
   && grep -Fq 'ticket #6303, job job-fix2-6303 (tkt-fix)' "$T/last-send"; then
  ok running-fix-picks-up-later-slot-job-id
else
  fail "running-fix-picks-up-later-slot-job-id (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# An owned finished job without a unique ID wakes with process attribution.
r=$(newrun owned-job-without-id)
lane "$r" 6200 fiber-6200-build sid-6200
printf 'repo=example/switchyard\nissue=6200\njob.preflight=job-pre-6200\njob.build=job-build-6200\njob.fix1=job-fix-6200\n' >"$r/fiber-6200.state"
set_session sid-6200 6200 turn-owned-no-id completed 3000000
set_logs turn-owned-no-id 2900000 3000000 'STATUS: DONE'
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n101 100 00:12 bash /repo/bin/tkt-build %s/fiber-6200.state\n' "$r" >"$T/box-procs"
: >"$T/send-commands"
out=$(run_lanecheck "$r" 3000)
set_processes
: >"$T/last-send"
out=$(run_lanecheck "$r" 3001); lrc=$?
if [ "$lrc" -eq 0 ] && printf '%s\n' "$out" | grep -Fq "WAKE 6200 muse fiber-6200-build — tkt-build pid 101 (state $r/fiber-6200.state) finished (exit unknown)" \
   && grep -Fq "ticket #6200, tkt-build pid 101 (state $r/fiber-6200.state) finished (exit unknown)" "$T/last-send" \
   && grep -Fq 'Read its output and continue from your brief. End with STATUS.' "$T/last-send"; then
  ok finished-owned-job-without-id-still-wakes
else
  fail "finished-owned-job-without-id-still-wakes (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# An owned gh-ci wait with no state path also wakes by command and PID.
r=$(newrun owned-gh-ci-wait)
lane "$r" 6201 fiber-6201-build sid-6201
set_session sid-6201 6201 turn-gh-ci-wait completed 3000000
set_logs turn-gh-ci-wait 2900000 3000000 'STATUS: DONE'
printf '90 1 01:00:00 delegate __supervise\n100 90 00:30 muse serve\n101 100 00:12 bash /repo/bin/gh-ci wait 1953 --repo example/switchyard\n' >"$T/box-procs"
: >"$T/send-commands"
out=$(run_lanecheck "$r" 3000)
set_processes
: >"$T/last-send"
out=$(run_lanecheck "$r" 3001); lrc=$?
if [ "$lrc" -eq 0 ] && printf '%s\n' "$out" | grep -Fq 'gh-ci wait pid 101 finished (exit unknown)' \
   && grep -Fq 'ticket #6201, gh-ci wait pid 101 finished (exit unknown)' "$T/last-send" \
   && grep -Fq 'Read its output and continue from your brief. End with STATUS.' "$T/last-send"; then
  ok finished-owned-gh-ci-wait-without-id-still-wakes
else
  fail "finished-owned-gh-ci-wait-without-id-still-wakes (rc=$lrc out=$out sent=$(cat "$T/last-send" 2>/dev/null))"
fi

# A final RETIRE report plus a merged PR retires through lanecheck's existing
# roster/stop path and never wakes the finished session. Without a merged PR,
# the same report is not terminal and the idle session still gets its wake.
r=$(newrun retire-merged-report)
lane "$r" 8101 fiber-8101-build sid-8101
printf 'repo=example/switchyard\nissue=8101\npr=81\n' >"$r/fiber-8101.state"
printf 'RETIRE issue=8101\n' >"$r/fiber-8101-report.md"
printf '{"state":"MERGED","mergedAt":"2026-11-15T00:00:00Z"}\n' >"$T/pr-view-81"
set_session sid-8101 8101 turn-retire-merged completed 8100000
set_logs turn-retire-merged 8000000 8100000 'The ship is complete.'
set_processes
: >"$T/stop-commands"
: >"$T/send-commands"
out=$(run_lanecheck "$r" 8100); lrc=$?
if [ "$lrc" -eq 0 ] && [ ! -s "$T/send-commands" ] \
   && awk -F '\t' '$2 == "8101" { found=1 } END { exit !found }' "$r/roster-done" \
   && grep -Fq 'delegate session stop sid-8101' "$T/stop-commands"; then
  ok merged-retire-report-stops-without-wake
else
  fail "merged-retire-report-stops-without-wake (rc=$lrc out=$out retired=$(cat "$r/roster-done") stops=$(cat "$T/stop-commands") sends=$(cat "$T/send-commands"))"
fi

r=$(newrun retire-unmerged-report)
lane "$r" 8102 fiber-8102-build sid-8102
printf 'repo=example/switchyard\nissue=8102\npr=82\n' >"$r/fiber-8102.state"
printf 'RETIRE issue=8102\n' >"$r/fiber-8102-report.md"
printf '{"state":"OPEN","mergedAt":null}\n' >"$T/pr-view-82"
set_session sid-8102 8102 turn-retire-unmerged completed 8200000
set_logs turn-retire-unmerged 8100000 8200000 'The ship is complete.'
set_processes
: >"$T/send-commands"
out=$(run_lanecheck "$r" 8200); lrc=$?
if [ "$lrc" -eq 0 ] && [ "$(grep -c 'delegate session send' "$T/send-commands" || true)" -eq 1 ] \
   && printf '%s\n' "$out" | grep -q '^WAKE 8102 '; then
  ok unmerged-retire-report-still-wakes
else
  fail "unmerged-retire-report-still-wakes (rc=$lrc out=$out sends=$(cat "$T/send-commands"))"
fi

exit "$rc"

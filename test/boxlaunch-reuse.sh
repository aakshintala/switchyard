#!/usr/bin/env bash
# Hermetic tests for boxlaunch session reuse and lanecheck retirement.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
BIN=$here/../bin
T=$(mktemp -d "${TMPDIR:-/tmp}/boxlaunch-reuse.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub"

cat >"$T/stub/ssh" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -o|-p|-i|-l|-F|-J|-L|-R) shift 2;; -*) shift;; *) break;; esac
done
[ $# -gt 0 ] || exit 2
shift # host
cd "$HOME" || exit 1
export FW_TEST_HOST=box
export PATH="$STUBD/stub:$PATH"
exec bash -c "$*"
EOF
cat >"$T/stub/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  agents)
    [ "${2:-}" = --json ] || exit 2
    if [ "${FW_TEST_HOST:-mac}" = box ]; then cat "$BOX_AGENTS"; else cat "$MAC_AGENTS"; fi
    ;;
  stop)
    [ -n "${2:-}" ] || exit 2
    printf 'claude %s\n' "$2" >> "$STOP_LOG"
    echo "stopped $2"
    ;;
  --bg)
    [ "${FW_TEST_LAUNCH_FAIL:-0}" = 1 ] && { echo 'simulated launch failure'; exit 1; }
    [ -f "$FW_BOX_RUN/roster" ] || { echo 'missing box roster before lane start' >&2; exit 3; }
    name=""
    while [ $# -gt 0 ]; do
      if [ "$1" = -n ]; then name=$2; shift 2; else shift; fi
    done
    [ -n "$name" ] || exit 2
    printf '%s\n' "$name" >> "$LAUNCH_LOG"
    printf 'backgrounded session %s\n' "$NEW_SESSION_ID"
    ;;
  *) exit 2 ;;
esac
EOF
cat >"$T/stub/delegate" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = session ] && [ "${2:-}" = list ] && [ "${3:-}" = --json ]; then
  cat "$DELEGATE_JSON"
elif [ "${1:-}" = session ] && [ "${2:-}" = stop ] && [ -n "${3:-}" ]; then
  printf 'delegate %s\n' "$3" >> "$STOP_LOG"
  echo "stopped $3"
else
  exit 2
fi
EOF
cat >"$T/stub/mkdir" <<'EOF'
#!/bin/sh
if [ "${FW_TEST_HOST:-}" = box ]; then exit 0; fi
exec /bin/mkdir "$@"
EOF
cat >"$T/stub/git" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$T/stub/gh" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$T/stub/file-claim" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$T/stub/inbox-watchers" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$T/stub/lanecheck" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = done ]; then
  printf '%s\n' "$*" >>"$LANECHECK_DONE_LOG"
  if [ "${FW_TEST_RETIRE_FAIL:-0}" = 1 ]; then
    echo 'simulated lanecheck done failure' >&2
    exit 2
  fi
  exec env FW_FILE_CLAIM="$STUBD/stub/file-claim" \
    FW_REPO=aakshintala/switchyard bash "$TEST_LANECHECK" "$@"
fi
cat "$BOX_LANE_OUTPUT"
EOF
cat >"$T/stub/noop" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/stub/"*
cat >"$T/stub/gh-self-grant" <<'GH'
#!/usr/bin/env bash
cat "$SELF_GRANT_PLAN"
GH
cat >"$T/stub/fence-grant-self" <<'FG'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SELF_GRANT_LOG"
ticket=$1
empty=0
paths=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --empty) empty=1; shift;;
    --paths) paths=$2; shift 2;;
    *) shift;;
  esac
done
mkdir -p "$FW_RUN"
max=0
for grant in "$FW_RUN"/fiber-"$ticket"-fence-grant-*.md; do
  [ -f "$grant" ] || continue
  part="${grant##*-fence-grant-}"
  part="${part%.md}"
  case "$part" in ''|*[!0-9]*) continue;; esac
  [ "$part" -gt "$max" ] && max="$part"
done
part=$((max + 1))
grant="$FW_RUN/fiber-$ticket-fence-grant-$part.md"
if [ "$empty" -eq 1 ]; then
  printf 'Grant %s\n\nTicket: %s\nPart: %s\nPaths:\nRanges: none\n' \
    "$part" "$ticket" "$part" >"$grant"
else
  printf 'Grant %s\n\nTicket: %s\nPart: %s\nPaths:\n- %s\nRanges: none\n' \
    "$part" "$ticket" "$part" "$paths" >"$grant"
fi
FG
chmod +x "$T/stub/gh-self-grant" "$T/stub/fence-grant-self"

export STUBD=$T BOX_AGENTS="$T/box-agents.json" MAC_AGENTS="$T/mac-agents.json"
export SELF_GRANT_PLAN="$T/self-grant-plan.md" SELF_GRANT_LOG="$T/self-grant.log"
export TEST_LANECHECK="$BIN/lanecheck"
export DELEGATE_JSON="$T/delegate.json" STOP_LOG="$T/stops.log" LAUNCH_LOG="$T/launches.log"
export LANECHECK_DONE_LOG="$T/lanecheck-done.log"
export BOX_LANE_OUTPUT="$T/box-lanes.txt"
export NEW_SESSION_ID=launch-id-2465
export PATH="$T/stub:$PATH"
: >"$STOP_LOG"; : >"$LAUNCH_LOG"
printf '[]\n' >"$MAC_AGENTS"
printf '{"sessions":[]}\n' >"$DELEGATE_JSON"

prepare_run() {
  run=$T/$1-run
  boxhome=$T/$1-box
  boxrun=$boxhome/work/fiber-worktrees/flywheel/run
  mkdir -p "$T/mac-home" "$run/done" "$boxhome/work/fiber-worktrees/flywheel/run"
  printf '%s\n' '- State file /tmp/fixture-state.json' >"$run/fiber-2465-orchestrator-brief.md"
  : >"$run/fiber-2465-fence-grant-fixture.md"
  : >"$run/roster"
  : >"$run/roster-done"
  : >"$LANECHECK_DONE_LOG"
}
launch_box() {
  local phase=${1:-phase-plan}
  HOME="$T/mac-home" USER=fixture PATH="$T/stub:$PATH" \
    FW_RUN="$run" FW_BOX_RUN="$boxrun" FW_BOX_HOME="$boxhome" \
    FW_MAC_HOME="$T/mac-home" FW_BOX_HOST=fixture FW_LOCAL_BOX=0 \
    BOX_SSH="$T/stub/ssh" FW_AGENTS_FF="$T/stub/noop" \
    FW_BOXSTALE="$T/stub/noop" FW_BOX_LANECHECK="$T/stub/lanecheck" \
    FW_BOX_LANES="${FW_TEST_BOX_LANES:-12}" FW_GH="$T/stub/gh-self-grant" \
    FW_FENCE_GRANT="$T/stub/fence-grant-self" SELF_GRANT_LOG="$SELF_GRANT_LOG" \
    SELF_GRANT_PLAN="$SELF_GRANT_PLAN" \
    FW_NO_FENCE='fixture has no production fence' FW_NO_TMP_REAP="${FW_TEST_NO_TMP_REAP:-1}" NEWDISK=1 \
    bash "$BIN/boxlaunch.sh" 2465 sonnet "$phase"
}
check_run_roster() {
  HOME="$T/mac-home" PATH="$T/stub:$PATH" FW_RUN="$run" FW_SKIP_SAMPLER_CHECK=1 \
    FW_LOCAL_BOX=0 BOX_SSH="$T/stub/ssh" FW_DELEGATE="$T/stub/delegate" \
    FW_FILE_CLAIM="$T/stub/file-claim" FW_INBOX_WATCHERS="$T/stub/inbox-watchers" \
    FW_BOXSTALE="$T/stub/noop" FW_REPO=aakshintala/switchyard \
    bash "$BIN/lanecheck" 2>&1
}

rc=0
ok() { printf 'ok %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; rc=1; }

# An idle legacy name is stopped before the replacement starts. The generated
# launch name is recorded in column 4 and is the name lanecheck tells us to use.
prepare_run idle
printf '[{"id":"stale-id-2465","name":"fiber-2465-plan","state":"done","status":"idle"}]\n' >"$BOX_AGENTS"
if launch_box >"$T/launch.out" 2>&1; then :; else fail "idle-relaunch-command-succeeded ($(cat "$T/launch.out"))"; fi
if grep -Fxq 'claude stale-id-2465' "$STOP_LOG"; then ok idle-old-session-stopped; else fail idle-old-session-stopped; fi
if [ "$(wc -l <"$LAUNCH_LOG" | tr -d ' ')" = 1 ]; then ok idle-relaunch-started-once; else fail idle-relaunch-started-once; fi
session=$(tail -n 1 "$LAUNCH_LOG")
if [[ "$session" =~ ^fiber-2465-plan-[0-9a-f]{8}$ ]]; then ok launch-name-carries-eight-hex-id; else fail "launch-name-carries-eight-hex-id ($session)"; fi
IFS=$'\t' read -r _ ticket host roster_name session_id <"$run/roster"
if [ "$ticket" = 2465 ] && [ "$host" = box ] && [ "$roster_name" = "$session" ] && [ "$session_id" = "$NEW_SESSION_ID" ]; then
  ok roster-records-launch-name-and-session-id
else
  fail "roster-records-launch-name-and-session-id ($ticket $host $roster_name $session_id)"
fi
if cmp -s "$run/roster" "$boxrun/roster"; then
  ok roster-synced-to-box-run
else
  fail "roster-synced-to-box-run ($(cat "$boxrun/roster" 2>/dev/null))"
fi

# A plan-phase launch with no earlier grant records an empty grant before dispatch.
saved_run=$run saved_boxrun=$boxrun saved_boxhome=$boxhome
prepare_run plan-self-grant
rm "$run/fiber-2465-fence-grant-fixture.md"
: >"$SELF_GRANT_PLAN"
: >"$SELF_GRANT_LOG"
printf '[]\n' >"$BOX_AGENTS"
if launch_box phase-plan >"$T/plan-self-grant-launch.out" 2>&1; then :; else
  fail "plan phase self-grants before launch ($(cat "$T/plan-self-grant-launch.out"))"
fi
[ -f "$run/fiber-2465-fence-grant-1.md" ] || fail "plan phase writes a grant file"
grep -q '^2465 --empty$' "$SELF_GRANT_LOG" || fail "plan phase records an empty grant when no plan is posted"
grep -q '^Paths:$' "$run/fiber-2465-fence-grant-1.md" || fail "plan phase empty grant has a Paths block"
cat >"$SELF_GRANT_PLAN" <<'PLAN'
## Files

- `src/box-lane.c`
PLAN
: >"$SELF_GRANT_LOG"
if launch_box phase-build >"$T/build-self-grant-launch.out" 2>&1; then :; else
  fail "build phase refreshes the empty grant ($(cat "$T/build-self-grant-launch.out"))"
fi
[ -f "$run/fiber-2465-fence-grant-2.md" ] || fail "build phase writes the second grant"
grep -q '^Part: 2$' "$run/fiber-2465-fence-grant-2.md" || fail "build phase advances the grant part"
grep -q '^- src/box-lane.c$' "$run/fiber-2465-fence-grant-2.md" || fail "build phase grant includes the newly posted write path"
run=$saved_run boxrun=$saved_boxrun boxhome=$saved_boxhome

printf '[{"id":"%s","name":"%s","state":"done","status":"idle"}]\n' "$NEW_SESSION_ID" "$session" >"$BOX_AGENTS"
out=$(HOME="$T/mac-home" PATH="$T/stub:$PATH" FW_RUN="$run" FW_SKIP_SAMPLER_CHECK=1 \
  FW_LOCAL_BOX=0 BOX_SSH="$T/stub/ssh" FW_DELEGATE="$T/stub/delegate" \
  FW_FILE_CLAIM="$T/stub/file-claim" FW_INBOX_WATCHERS="$T/stub/inbox-watchers" \
  FW_BOXSTALE="$T/stub/noop" bash "$BIN/lanecheck" 2>&1)
if printf '%s\n' "$out" | grep -Fq "SendMessage to '$session'"; then
  ok lanecheck-messages-the-exact-launch-name
else
  fail "lanecheck-messages-the-exact-launch-name ($out)"
fi
: >"$STOP_LOG"
out=$(HOME="$T/mac-home" PATH="$T/stub:$PATH" FW_RUN="$run" FW_DONE_MIN=0 \
  FW_LOCAL_BOX=0 BOX_SSH="$T/stub/ssh" FW_FILE_CLAIM="$T/stub/file-claim" \
  FW_REPO=aakshintala/switchyard bash "$BIN/lanecheck" done "2465:$session" 2>&1) || rc_done=$?
rc_done=${rc_done:-0}
if [ "$rc_done" = 0 ] && grep -Fxq "claude $NEW_SESSION_ID" "$STOP_LOG" \
    && grep -Fq $'\t2465\t' "$run/roster-done"; then
  ok lanecheck-done-stops-retired-claude-session
else
  fail "lanecheck-done-stops-retired-claude-session (rc=$rc_done; $out; $(cat "$STOP_LOG"))"
fi

# A busy old name must refuse without stopping it or launching another session.
prepare_run busy
: >"$STOP_LOG"; : >"$LAUNCH_LOG"
printf '[{"id":"busy-id-2465","name":"fiber-2465-plan","state":"working","status":"busy"}]\n' >"$BOX_AGENTS"
if out=$(launch_box 2>&1); then launch_rc=0; else launch_rc=$?; fi
if [ "$launch_rc" = 2 ] && printf '%s\n' "$out" | grep -Fq 'busy-id-2465' \
    && [ ! -s "$STOP_LOG" ] && [ ! -s "$LAUNCH_LOG" ]; then
  ok busy-old-session-refuses-with-id
else
  fail "busy-old-session-refuses-with-id (rc=$launch_rc; $out)"
fi

# lanecheck done uses the same no-active-turn signal before stopping a Claude
# session, and uses activeTurnId for a muse/delegate session.
prepare_run done-busy
printf '2026-11-01T00:00:00Z\t2465\tbox\tfiber-2465-plan-deadbeef\tbusy-id-2465\n' >"$run/roster"
printf '[{"id":"busy-id-2465","name":"fiber-2465-plan-deadbeef","state":"working","status":"busy"}]\n' >"$BOX_AGENTS"
: >"$STOP_LOG"
if out=$(HOME="$T/mac-home" PATH="$T/stub:$PATH" FW_RUN="$run" FW_DONE_MIN=0 \
    FW_LOCAL_BOX=0 BOX_SSH="$T/stub/ssh" FW_FILE_CLAIM="$T/stub/file-claim" \
    FW_REPO=aakshintala/switchyard bash "$BIN/lanecheck" done 2465 2>&1); then done_rc=0; else done_rc=$?; fi
if [ "$done_rc" = 2 ] && printf '%s\n' "$out" | grep -Fq 'busy-id-2465' \
    && [ ! -s "$STOP_LOG" ] && [ ! -s "$run/roster-done" ]; then
  ok done-refuses-mid-turn-claude-session
else
  fail "done-refuses-mid-turn-claude-session (rc=$done_rc; $out)"
fi

prepare_run muse-busy
printf '2026-11-01T00:00:00Z\t2465\tmuse\tfiber-2465-muse\tmuse-id-2465\n' >"$run/roster"
printf '{"sessions":[{"id":"muse-id-2465","activeTurnId":"turn-1","status":"running"}]}\n' >"$DELEGATE_JSON"
: >"$STOP_LOG"
if out=$(HOME="$T/mac-home" PATH="$T/stub:$PATH" FW_RUN="$run" FW_DONE_MIN=0 \
    FW_LOCAL_BOX=0 BOX_SSH="$T/stub/ssh" FW_DELEGATE="$T/stub/delegate" \
    FW_FILE_CLAIM="$T/stub/file-claim" bash "$BIN/lanecheck" done 2465 2>&1); then done_rc=0; else done_rc=$?; fi
if [ "$done_rc" = 2 ] && printf '%s\n' "$out" | grep -Fq 'muse-id-2465' \
    && [ ! -s "$STOP_LOG" ] && [ ! -s "$run/roster-done" ]; then
  ok done-refuses-mid-turn-muse-session
else
  fail "done-refuses-mid-turn-muse-session (rc=$done_rc; $out)"
fi

prepare_run muse-idle
printf '2026-11-01T00:00:00Z\t2465\tmuse\tfiber-2465-muse\tmuse-id-2465\n' >"$run/roster"
printf '{"sessions":[{"id":"muse-id-2465","activeTurnId":null,"status":"idle"}]}\n' >"$DELEGATE_JSON"
: >"$STOP_LOG"
if out=$(HOME="$T/mac-home" PATH="$T/stub:$PATH" FW_RUN="$run" FW_DONE_MIN=0 \
    FW_LOCAL_BOX=0 BOX_SSH="$T/stub/ssh" FW_DELEGATE="$T/stub/delegate" \
    FW_FILE_CLAIM="$T/stub/file-claim" bash "$BIN/lanecheck" done 2465 2>&1); then done_rc=0; else done_rc=$?; fi
if [ "$done_rc" = 0 ] && grep -Fxq 'delegate muse-id-2465' "$STOP_LOG" \
    && awk -F'\t' '$2 == "2465" { found=1 } END { exit !found }' "$run/roster-done"; then
  ok done-stops-idle-muse-session
else
  fail "done-stops-idle-muse-session (rc=$done_rc; $out; $(cat "$STOP_LOG"))"
fi

# A short roster ID that matches multiple delegate sessions is ambiguous and
# must not be treated as an already-absent session.
prepare_run muse-ambiguous
printf '2026-11-01T00:00:00Z\t2465\tmuse\tfiber-2465-muse\tmuse-id\n' >"$run/roster"
printf '{"sessions":[{"id":"muse-id-2465","activeTurnId":null},{"id":"muse-id-9999","activeTurnId":null}]}\n' >"$DELEGATE_JSON"
: >"$STOP_LOG"
if out=$(HOME="$T/mac-home" PATH="$T/stub:$PATH" FW_RUN="$run" FW_DONE_MIN=0 \
    FW_LOCAL_BOX=0 BOX_SSH="$T/stub/ssh" FW_DELEGATE="$T/stub/delegate" \
    FW_FILE_CLAIM="$T/stub/file-claim" bash "$BIN/lanecheck" done 2465 2>&1); then done_rc=0; else done_rc=$?; fi
if [ "$done_rc" = 2 ] && printf '%s\n' "$out" | grep -Fq 'is ambiguous' \
    && [ ! -s "$STOP_LOG" ] && [ ! -s "$run/roster-done" ]; then
  ok done-refuses-ambiguous-delegate-id
else
  fail "done-refuses-ambiguous-delegate-id (rc=$done_rc; $out; $(cat "$STOP_LOG"))"
fi


# A phase launch retires only the latest roster entry from its immediately
# previous phase. Failed launches leave that entry visible to lanecheck.
phase_retirement_case() {
  local phase=$1 previous=$2 outcome=$3 label=$4
  local previous_session="fiber-2465-$previous-deadbeef" launch_rc=0 check_rc=0 out
  prepare_run "$label"
  printf '%s\t2465\tbox\t%s\tprevious-session-id\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$previous_session" >"$run/roster"
  printf '[]\n' >"$BOX_AGENTS"
  : >"$LAUNCH_LOG"
  if [ "$outcome" = success ] || [ "$outcome" = retirement-failure ]; then
    if FW_TEST_LAUNCH_FAIL=0 FW_TEST_RETIRE_FAIL="$([[ $outcome = retirement-failure ]] && echo 1 || echo 0)" \
        launch_box "$phase" >"$T/$label-launch.out" 2>&1; then :; else launch_rc=$?; fi
  else
    if FW_TEST_LAUNCH_FAIL=1 launch_box "$phase" >"$T/$label-launch.out" 2>&1; then launch_rc=0; else launch_rc=$?; fi
  fi
  if out=$(check_run_roster); then check_rc=0; else check_rc=$?; fi
  if [ "$outcome" = success ]; then
    local new_phase=${phase#phase-}
    if [ "$launch_rc" = 0 ] && ! printf '%s\n' "$out" | grep -Fq "$previous_session" \
        && printf '%s\n' "$out" | grep -Fq "fiber-2465-$new_phase-" \
        && awk -F'\t' -v session="$previous_session" '$2 == "2465" && $3 == session { found=1 } END { exit !found }' "$run/roster-done"; then
      ok "$label-launch-retires-previous-phase-in-lanecheck"
    else
      fail "$label-launch-retires-previous-phase-in-lanecheck (launch=$launch_rc check=$check_rc; $out; $(cat "$run/roster-done" 2>/dev/null))"
    fi
  elif [ "$outcome" = retirement-failure ] \
      && [ "$launch_rc" = 0 ] && printf '%s\n' "$out" | grep -Fq "$previous_session" \
      && grep -Fq 'WARNING could not retire' "$T/$label-launch.out" \
      && grep -Fq "manually run: FW_DONE_FORCE=1 FW_RUN='$run' bash '$T/stub/lanecheck' done '2465:$previous_session'" "$T/$label-launch.out"; then
    ok "$label-warns-but-launch-succeeds"
  elif [ "$launch_rc" != 0 ] && printf '%s\n' "$out" | grep -Fq "$previous_session" \
      && ! awk -F'\t' -v session="$previous_session" '$2 == "2465" && $3 == session { found=1 } END { exit !found }' "$run/roster-done"; then
    ok "$label-failed-launch-keeps-previous-phase-in-lanecheck"
  else
    fail "$label-failed-launch-keeps-previous-phase-in-lanecheck (launch=$launch_rc check=$check_rc; $out; $(cat "$run/roster-done" 2>/dev/null))"
  fi
}
phase_retirement_case phase-build plan success phase-build-success
phase_retirement_case phase-ship build success phase-ship-success
phase_retirement_case phase-build plan failed phase-build-failure
phase_retirement_case phase-ship build failed phase-ship-failure
phase_retirement_case phase-build plan retirement-failure phase-build-retirement-failure

# A relaunch still asks lanecheck to retire the previous phase. The real
# lanecheck reports that the existing retirement is a quiet no-op.
prepare_run phase-build-already-retired
previous_session=fiber-2465-plan-deadbeef
printf '2026-11-01T00:00:00Z\t2465\tbox\t%s\tprevious-session-id\n' "$previous_session" >"$run/roster"
printf '2026-11-02T00:00:00Z\t2465\t%s\n' "$previous_session" >"$run/roster-done"
printf '[]\n' >"$BOX_AGENTS"
if out=$(FW_TEST_LAUNCH_FAIL=0 launch_box phase-build 2>&1); then
  if grep -Fxq "done 2465:$previous_session" "$LANECHECK_DONE_LOG" \
      && printf '%s\n' "$out" | grep -Fq "already retired: #2465:$previous_session" \
      && ! printf '%s\n' "$out" | grep -Fq 'WARNING could not retire' \
      && [ "$(wc -l < "$run/roster-done" | tr -d ' ')" = 1 ]; then
    ok phase-build-relaunch-lanecheck-reports-already-retired
  else
    fail "phase-build-relaunch-lanecheck-reports-already-retired (called: $(cat "$LANECHECK_DONE_LOG"); $out)"
  fi
else
  fail "phase-build-relaunch-lanecheck-reports-already-retired (launch failed: $out)"
fi

# The launch cap includes LIVE Claude/delegate lanes on Box and muse, plus
# LIVE PI-BOX pidfile lanes. PI-MAC lanes do not consume Box capacity.
prepare_run cap-default
printf '[]\n' >"$BOX_AGENTS"
: >"$STOP_LOG"; : >"$LAUNCH_LOG"
{
  for i in $(seq 1 6); do printf 'LIVE %s box lane-%s working/busy\n' "$i" "$i"; done
  for i in $(seq 7 11); do printf 'LIVE %s muse lane-%s working/busy\n' "$i" "$i"; done
  printf '12 PI-BOX LIVE STATUS: RUNNING\n'
  printf '99 PI-MAC LIVE STATUS: RUNNING\n'
} >"$BOX_LANE_OUTPUT"
if out=$(launch_box 2>&1); then cap_rc=0; else cap_rc=$?; fi
if [ "$cap_rc" = 2 ] && printf '%s\n' "$out" | grep -Fq '12 box lanes are live' \
    && [ ! -s "$LAUNCH_LOG" ]; then
  ok cap-refuses-twelve-live-box-muse-and-pi-box-lanes
else
  fail "cap-refuses-twelve-live-box-muse-and-pi-box-lanes (rc=$cap_rc; $out)"
fi

prepare_run cap-raised
printf '[]\n' >"$BOX_AGENTS"
: >"$STOP_LOG"; : >"$LAUNCH_LOG"
{
  for i in $(seq 1 6); do printf 'LIVE %s box lane-%s working/busy\n' "$i" "$i"; done
  for i in $(seq 7 12); do printf 'LIVE %s muse lane-%s working/busy\n' "$i" "$i"; done
} >"$BOX_LANE_OUTPUT"
if out=$(FW_TEST_BOX_LANES=13 launch_box 2>&1); then raised_rc=0; else raised_rc=$?; fi
if [ "$raised_rc" = 0 ] && [ "$(wc -l <"$LAUNCH_LOG" | tr -d ' ')" = 1 ]; then
  ok cap-override-allows-twelve-under-thirteen
else
  fail "cap-override-allows-twelve-under-thirteen (rc=$raised_rc; $out)"
fi

prepare_run cap-eleven
printf '[]\n' >"$BOX_AGENTS"
: >"$STOP_LOG"; : >"$LAUNCH_LOG"
{
  for i in $(seq 1 6); do printf 'LIVE %s box lane-%s working/busy\n' "$i" "$i"; done
  for i in $(seq 7 11); do printf 'LIVE %s muse lane-%s working/busy\n' "$i" "$i"; done
} >"$BOX_LANE_OUTPUT"
if out=$(launch_box 2>&1); then eleven_rc=0; else eleven_rc=$?; fi
if [ "$eleven_rc" = 0 ] && [ "$(wc -l <"$LAUNCH_LOG" | tr -d ' ')" = 1 ]; then
  ok cap-allows-eleven-live-lanes
else
  fail "cap-allows-eleven-live-lanes (rc=$eleven_rc; $out)"
fi

# The default box-side reap command is issued after sync and its failure cannot
# prevent the lane session from starting.
prepare_run tmp-reap-failure
printf '[]\n' >"$BOX_AGENTS"
: >"$BOX_LANE_OUTPUT"; : >"$LAUNCH_LOG"
mkdir -p "$T/mac-home/.agents/bin"
export REAP_LOG="$T/reap.log"
cat >"$T/mac-home/.agents/bin/box-tmp-reap" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REAP_LOG"
echo 'simulated reap failure'
exit 19
EOF
chmod +x "$T/mac-home/.agents/bin/box-tmp-reap"
if FW_TEST_NO_TMP_REAP=0 launch_box >"$T/reap-launch.out" 2>&1; then
  reap_launch_rc=0
else
  reap_launch_rc=$?
fi
for _ in {1..50}; do
  if [ -s "$REAP_LOG" ] && grep -Fq 'boxlaunch: tmp reap: simulated reap failure' "$T/reap-launch.out"; then break; fi
  sleep .1
done
if [ "$reap_launch_rc" = 0 ] && [ "$(wc -l <"$LAUNCH_LOG" | tr -d ' ')" = 1 ] \
    && grep -Fxq '/srv/lanes/tmp /tmp' "$REAP_LOG" \
    && grep -Fq 'boxlaunch: tmp reap: simulated reap failure' "$T/reap-launch.out"; then
  ok tmp-reap-runs-on-box-and-failure-does-not-block-launch
else
  fail "tmp-reap-runs-on-box-and-failure-does-not-block-launch (rc=$reap_launch_rc; log=$(cat "$REAP_LOG" 2>/dev/null); out=$(cat "$T/reap-launch.out"))"
fi

exit "$rc"

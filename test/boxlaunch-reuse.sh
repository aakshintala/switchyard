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
cat >"$T/stub/noop" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/stub/"*

export STUBD=$T BOX_AGENTS="$T/box-agents.json" MAC_AGENTS="$T/mac-agents.json"
export DELEGATE_JSON="$T/delegate.json" STOP_LOG="$T/stops.log" LAUNCH_LOG="$T/launches.log"
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
}
launch_box() {
  HOME="$T/mac-home" USER=fixture PATH="$T/stub:$PATH" \
    FW_RUN="$run" FW_BOX_RUN="$boxrun" FW_BOX_HOME="$boxhome" \
    FW_MAC_HOME="$T/mac-home" FW_BOX_HOST=fixture FW_LOCAL_BOX=0 \
    BOX_SSH="$T/stub/ssh" FW_AGENTS_FF="$T/stub/noop" \
    FW_BOXSTALE="$T/stub/noop" FW_NO_FENCE='fixture has no production fence' NEWDISK=1 \
    bash "$BIN/boxlaunch.sh" 2465 sonnet phase-plan
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

exit "$rc"

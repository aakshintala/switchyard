#!/usr/bin/env bash
# Hermetic contract tests for lanecheck's Mac and Box pi pidfile lanes.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
BIN=$here/../bin
T=$(mktemp -d "${TMPDIR:-/tmp}/lanecheck-pi.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/macrun/inbox" "$T/macrun/inbox/read" \
  "$T/boxhome/work/fiber-worktrees/flywheel/run/inbox" \
  "$T/boxhome/work/fiber-worktrees/flywheel/run/inbox/read"
BOX_RUN=$T/boxhome/work/fiber-worktrees/flywheel/run

cat > "$T/stub/claude" <<'EOF'
#!/bin/sh
[ "${1:-}" = agents ] && [ "${2:-}" = --json ] || exit 2
cat "$STUBD/mac-agents"
EOF
cat > "$T/stub/delegate" <<'EOF'
#!/bin/sh
[ "${1:-}" = session ] && [ "${2:-}" = list ] || exit 2
printf '{"ok":true,"sessions":[]}\n'
EOF
cat > "$T/stub/ssh" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in -o|-p|-i|-l|-F|-J|-L|-R) shift 2;; -*) shift;; *) break;; esac
done
[ $# -gt 0 ] || exit 2
shift # host
command=$*
if [ "${SSH_BOOM:-0}" = 1 ]; then echo 'fixture host unreachable' >&2; exit 255; fi
case "$command" in
  *'claude agents --json'*) cat "$STUBD/box-agents" ;;
  *'delegate session list --json'*) printf '{"ok":true,"sessions":[]}\n' ;;
  *'python3 -'*) env -u FW_RUN -u RUN_DIR HOME="$BOX_HOME" python3 - ;;
  *'ps -eo args='*) exit 0 ;;
  *'python3 -c'*) exit 0 ;;
  *'bash -s'*) env -u FW_RUN -u RUN_DIR HOME="$BOX_HOME" PATH="$STUBD:$PATH" bash -c "$command" ;;
  *) exit 0 ;;
esac
EOF
cat > "$T/stub/gh" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$T/stub/file-claim" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$T/stub/inbox-watchers" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$T/stub/boxstale" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/stub/"*
: > "$T/mac-agents"
printf '[{"name":"fiber-1465-build","state":"working","status":"busy"}]\n' > "$T/box-agents"
mkdir -p "$T/macrun/done" "$BOX_RUN/done"
printf '%s\t1465\tbox\tfiber-1465-build\t-\n' \
  "$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))')" \
  > "$T/macrun/roster"
: > "$T/macrun/roster-done"

# Pid equal to this still-running test process is live from either host's PID
# namespace; a high unallocated pid is dead. No Claude session or remote host is used.
printf '%s\n' "$$" > "$T/macrun/fiber-1461-pi.pid"
printf '%s\n' 99999999 > "$T/macrun/fiber-1462-pi.pid"
printf '%s\n' "$$" > "$BOX_RUN/fiber-1463-pi.pid"
printf '%s\n' 99999999 > "$BOX_RUN/fiber-1464-pi.pid"
printf '%s\n' "$$" > "$T/macrun/fiber-1466.pid" # fiberlaunch, not a pi lane

printf 'STATUS: MAC-OLD-1461\n' > "$T/macrun/fiber-1461-report.md"
printf 'STATUS: MAC-LATEST-1461\n' > "$T/macrun/inbox/read/box-1461-latest.md"
printf 'STATUS: MAC-LATEST-1462\n' > "$T/macrun/fiber-1462-report.md"
printf 'STATUS: BOX-OLD-1463\n' > "$BOX_RUN/fiber-1463-report.md"
printf 'STATUS: BOX-LATEST-1463\n' > "$BOX_RUN/inbox/read/box-1463-latest.md"
printf 'STATUS: BOX-LATEST-1464\n' > "$BOX_RUN/fiber-1464-report.md"
python3 - "$T/macrun" "$BOX_RUN" <<'PY'
import os, sys, time
for root in sys.argv[1:]:
    for name, age in (("fiber-1461-report.md", 60), ("inbox/read/box-1461-latest.md", 1),
                      ("fiber-1463-report.md", 60), ("inbox/read/box-1463-latest.md", 1)):
        p = os.path.join(root, name)
        if os.path.exists(p):
            os.utime(p, (time.time() - age, time.time() - age))
PY

export STUBD="$T" STUB_PATH="$T/stub" BOX_HOME="$T/boxhome" BOX_RUN
export PATH="$T/stub:$PATH"
common=(FW_RUN="$T/macrun" FW_SKIP_SAMPLER_CHECK=1 FW_LOCAL_BOX=0
  BOX_SSH="$T/stub/ssh" FW_DELEGATE="$T/stub/delegate"
  FW_FILE_CLAIM="$T/stub/file-claim" FW_INBOX_WATCHERS="$T/stub/inbox-watchers"
  FW_BOXSTALE="$T/stub/boxstale")

out=$(env "${common[@]}" bash "$BIN/lanecheck" 2>&1)
rc=0
expect() {
  if printf '%s\n' "$out" | grep -Fq -- "$1"; then printf 'ok %s\n' "$2";
  else printf 'FAIL %s (missing: %s)\n' "$2" "$1" >&2; rc=1; fi
}
expect 'LIVE PI-MAC 1461 ' mac-live-pid-is-probed-locally
expect 'DEAD PI-MAC 1462 ' mac-dead-pid-is-probed-locally
expect 'MAC-LATEST-1461' mac-latest-report-is-shown
expect 'MAC-LATEST-1462' mac-dead-lane-report-is-shown
expect 'LIVE PI-BOX 1463 ' box-live-pid-is-probed-on-box
expect 'DEAD PI-BOX 1464 ' box-dead-pid-is-probed-on-box
expect 'BOX-LATEST-1463' box-latest-report-is-shown
expect 'BOX-LATEST-1464' box-dead-lane-report-is-shown
expect 'LIVE 1465 box fiber-1465-build' box-claude-roster-is-preserved
if printf '%s\n' "$out" | grep -Fq 'PI-MAC 1466'; then
  echo 'FAIL mac-fiberlaunch-is-not-a-pi-lane' >&2; rc=1
else
  echo 'ok mac-fiberlaunch-is-not-a-pi-lane'
fi

out=$(env "${common[@]}" SSH_BOOM=1 bash "$BIN/lanecheck" 2>&1)
expect 'UNREACHABLE PI-BOX' unreachable-box-is-not-reported-as-dead
if printf '%s\n' "$out" | grep -Fq 'DEAD PI-BOX'; then
  echo 'FAIL unreachable-box-pidfiles-are-not-marked-dead' >&2; rc=1
else
  echo 'ok unreachable-box-pidfiles-are-not-marked-dead'
fi
exit "$rc"

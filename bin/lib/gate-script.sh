# gate-script: shared gate-script writer, sourced by bin/tkt-job and bin/tkt-gate.
# Source it from beside the calling script:
#   gate_lib="$(cd "$(dirname "$0")" && pwd)/lib/gate-script.sh"
# Every function returns 0 unless stated, and is safe under `set -euo pipefail`.

# write_gate_script SCRIPT LOG ENV_PREFIX GATE_CMD NOTE: write SCRIPT, a bash
# script that runs GATE_CMD with ENV_PREFIX in a subshell with errexit inside
# one redirected block to LOG, then prints the last 20 log lines and GATE
# PASS (or GATE FAIL rc=<n>). A gate that runs zero tests (nextest's "no
# tests to run" at exit 0) is a failure too: the script promotes it to rc 4.
# The gate's exit code is captured before the tail and the verdict echo, so a
# gate that fails then echoes still exits non-zero; printf carries the gate
# literally, so nothing expands while the script is written. NOTE is the
# header comment naming the writer, e.g. `tkt-job: delegate runs it as the
# job-end gate`.
write_gate_script() {
  local script="$1" log="$2" env_prefix="$3" gate_cmd="$4" note="$5"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Written by %s.\n' "$note"
    printf 'log=%s\n' "$log"
    printf '( set -e; %s%s ) > "$log" 2>&1\n' "$env_prefix" "$gate_cmd"
    printf 'rc=$?\n'
    printf 'if [ "$rc" -eq 0 ] && grep -qiE "no tests (to run|ran)" "$log"; then rc=4; fi\n'
    printf 'tail -n 20 "$log"\n'
    printf 'if [ "$rc" -eq 0 ]; then echo "GATE PASS"; else echo "GATE FAIL rc=$rc"; fi\n'
    printf 'exit "$rc"\n'
  } >"$script"
}

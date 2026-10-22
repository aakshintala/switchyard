# gate-script: shared gate-script writer, sourced by bin/tkt-job and bin/tkt-gate.
# Source it from beside the calling script:
#   gate_lib="$(cd "$(dirname "$0")" && pwd)/lib/gate-script.sh"
# Every function returns 0 unless stated, and is safe under `set -euo pipefail`.

# gate_block_awk: the awk program that prints each failing nextest test's block
# from a gate log: a status line (FAIL, TIMEOUT, SIGABRT, SIGSEGV, LEAK) and the
# lines after it up to the next status line, a rule, or a warning, error or
# Summary line. A block is capped at 60 lines and the total at 200.
gate_block_awk='
function show(s) {
  if (total >= 200) { if (!cut) print "... truncated"; cut = 1; return }
  if (bn >= 60) { if (!bcut) print "... truncated"; bcut = 1; return }
  print s; bn++; total++
}
/^ +(TRY [0-9]+ )?(PASS|FAIL|TIMEOUT|SIGABRT|SIGSEGV|LEAK|SLOW|START|RETRY|TRYING) |^─|^warning:|^error:|^     Summary/ { inblock = 0 }
/^ +(TRY [0-9]+ )?(FAIL|TIMEOUT|SIGABRT|SIGSEGV|LEAK) / { inblock = 1; bn = 0; bcut = 0 }
inblock { show($0) }
'

# gate_failure_blocks LOG: print the failing test blocks in LOG, per gate_block_awk.
gate_failure_blocks() {
  awk "$gate_block_awk" "$1"
}

# write_gate_script SCRIPT LOG ENV_PREFIX GATE_CMD NOTE: write SCRIPT, a bash
# script that runs GATE_CMD with ENV_PREFIX in a subshell with errexit inside
# one redirected block to LOG. On failure it prints the log path and the failing
# test blocks, then the last 20 log lines, then GATE PASS (or GATE FAIL rc=<n>).
# A gate that runs zero tests (nextest's "no tests to run" at exit 0) is a
# failure too: the script promotes it to rc 4.
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
    printf 'if [ "$rc" -ne 0 ]; then\n'
    printf '  echo "gate log: $log"\n'
    printf '  awk '\''%s'\'' "$log"\n' "$gate_block_awk"
    printf 'fi\n'
    printf 'tail -n 20 "$log"\n'
    printf 'if [ "$rc" -eq 0 ]; then echo "GATE PASS"; else echo "GATE FAIL rc=$rc"; fi\n'
    printf 'exit "$rc"\n'
  } >"$script"
}

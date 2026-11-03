# plan-gate-args: the --script argument every tkt tool passes to plan-gate, so a
# Gate line is checked against the repo's gate.script on every read, not only
# at tkt-plan set. Sourced by bin/tkt-build, tkt-fix, tkt-gate, tkt-job and tkt-ship.
# Source it from beside the calling script:
#   plan_gate_lib="$(cd "$(dirname "$0")" && pwd)/lib/plan-gate-args.sh"
# Safe under `set -euo pipefail`.

# plan_gate_args READER: set the array plan_gate_argv to (--script SCRIPT) when
# the state key gate.script is set and non-empty, else to an empty array. READER
# is the caller's state function (tkt or t), called as READER get gate.script. A
# missing key is not an error. Expand the array as
#   ${plan_gate_argv[@]+"${plan_gate_argv[@]}"}
# so an empty array passes nothing under `set -u` on bash 3.2.
plan_gate_args() {
  local script
  script="$("$1" get gate.script 2>/dev/null || true)"
  plan_gate_argv=()
  [ -z "$script" ] || plan_gate_argv=(--script "$script")
}

# takeover_plan_gate SCRIPT PLAN STATE_GETTER: parse a takeover plan and load
# its required state gate. The getter is the caller's state function (tkt or t).
# Sets takeover, takeover_ref, takeover_gate, takeover_error and
# takeover_error_kind for the caller. Safe under `set -euo pipefail`.
# shellcheck shell=bash
# Result variables are consumed by the caller that sources this helper.
# shellcheck disable=SC2034
takeover_plan_gate() {
  local script="$1" plan_value="$2" state_getter="$3"
  takeover=0
  takeover_ref=""
  takeover_gate=""
  takeover_error=""
  takeover_error_kind=""

  if [ "$plan_value" != takeover ] && [[ $plan_value != "takeover "* ]]; then
    return 0
  fi

  takeover=1
  if [ "$plan_value" != takeover ]; then takeover_ref="${plan_value#takeover }"; fi
  if [ -z "${takeover_ref//[[:space:]]/}" ] || [[ $takeover_ref == *[[:space:]]* ]]; then
    takeover_error="$script: invalid takeover plan value: expected 'takeover <pr-or-branch>'"
    takeover_error_kind=invalid
    echo "$takeover_error" >&2
    return 1
  fi

  takeover_gate="$("$state_getter" get gate 2>/dev/null || true)"
  if [ -z "${takeover_gate//[[:space:]]/}" ]; then
    takeover_error="$script: takeover $takeover_ref has no gate command in state (key: gate)"
    takeover_error_kind=gate-missing
    echo "$takeover_error" >&2
    return 1
  fi
  return 0
}

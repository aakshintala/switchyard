#!/usr/bin/env bash
# gate-credit: verify a fix job's full-gate record before tkt-fix credits it.
# A credit hashes the exact command line tkt-gate would run, including the
# ticket's optional environment prefix.

gate_credit_hash() {
  local env_value="${1:-}" cmd="${2:-}"
  printf '%s' "${env_value:+$env_value }$cmd" | shasum -a 256 | awk '{print $1}'
}

gate_credit_refuse() {
  printf '%s\n' "$1" >&2
  return 1
}

# gate_credit_check RECORD JOURNAL JOBID EXPECTED_CMD ENV HEAD
# Prints one refusal reason to stderr and returns 1 unless the job record and
# the newest gate journal row for JOBID prove the expected full gate at HEAD.
gate_credit_check() {
  [ "$#" -eq 6 ] || gate_credit_refuse 'invalid gate-credit check arguments' || return 1
  local record="$1" journal="$2" jobid="$3" expected_cmd="$4" expected_env="$5" head="$6"
  local line payload rest recorded_id cmd64 env64 recorded_cmd recorded_env
  local journal_found=0

  [ -n "$expected_cmd" ] || { gate_credit_refuse 'expected gate command is empty'; return 1; }
  [ -n "$jobid" ] || { gate_credit_refuse 'job id is empty'; return 1; }
  [ -r "$record" ] || { gate_credit_refuse "job record is not readable: $jobid"; return 1; }
  jq -e . "$record" >/dev/null 2>&1 || { gate_credit_refuse "job record is not valid JSON: $jobid"; return 1; }
  if ! jq -e '
    .passed == true
    and .refused != true
    and .error == null
    and (.result.gateResult.exitCode | type) == "number"
    and .result.gateResult.exitCode == 0
  ' "$record" >/dev/null 2>&1; then
    gate_credit_refuse "job record does not prove an uninterrupted passing gate: $jobid"
    return 1
  fi

  [ -r "$journal" ] || { gate_credit_refuse "job gate journal is not readable: $jobid"; return 1; }
  recorded_cmd=""
  recorded_env=""
  while IFS= read -r line || [ -n "$line" ]; do
    payload="${line#* }"
    case "$payload" in
      'tkt-job gate slot='*) ;;
      *) continue ;;
    esac
    rest="${payload#tkt-job gate slot=}"
    case "$rest" in *' '*) ;; *) continue ;; esac
    rest="${rest#* }"
    case "$rest" in job=*) ;; *) continue ;; esac
    recorded_id="${rest#job=}"
    case "$recorded_id" in *' '*) recorded_id="${recorded_id%% *}"; rest="${rest#* }" ;; *) rest="" ;; esac
    [ "$recorded_id" = "$jobid" ] || continue

    # A later row for this id owns the match position even when malformed,
    # just as tkt-gate's --from-job parser treats the latest row as evidence.
    journal_found=1
    recorded_cmd=""
    recorded_env=""
    case "$rest" in cmd64=*) ;; *) continue ;; esac
    cmd64="${rest#cmd64=}"
    case "$cmd64" in *' '*) cmd64="${cmd64%% *}"; rest="${rest#* }" ;; *) rest="" ;; esac
    case "$rest" in env64=*) ;; *) continue ;; esac
    env64="${rest#env64=}"
    case "$env64" in *' '*) continue ;; esac
    recorded_cmd="$(printf '%s' "$cmd64" | jq -Rrs '@base64d' 2>/dev/null)" || {
      recorded_cmd=""
      continue
    }
    recorded_env="$(printf '%s' "$env64" | jq -Rrs '@base64d' 2>/dev/null)" || {
      recorded_cmd=""
      recorded_env=""
    }
  done <"$journal"
  [ "$journal_found" -eq 1 ] || { gate_credit_refuse "job gate journal line is missing: $jobid"; return 1; }
  [ "$recorded_cmd" = "$expected_cmd" ] || {
    gate_credit_refuse "job gate command does not match the plan Gate: $jobid"
    return 1
  }
  [ "$recorded_env" = "$expected_env" ] || {
    gate_credit_refuse "job gate environment does not match ticket env: $jobid"
    return 1
  }

  if ! jq -e --arg head "$head" '
    .result.changeSet.headAfter == $head
  ' "$record" >/dev/null 2>&1; then
    gate_credit_refuse "job head does not match the PR head: $jobid"
    return 1
  fi
  if ! jq -e '
    (.result.changeSet.dirtyAfter | type) == "boolean"
    and .result.changeSet.dirtyAfter == false
  ' "$record" >/dev/null 2>&1; then
    gate_credit_refuse "job record does not prove a clean worktree: $jobid"
    return 1
  fi
  return 0
}

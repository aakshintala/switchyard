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

# gate_credit_check RECORD JOURNAL JOB_CHAIN EXPECTED_CMD ENV HEAD
# JOB_CHAIN is newline-separated ids oldest to newest, as job_walk_superseded prints them.
# Prints one refusal reason to stderr and returns 1 unless the job record and
# the newest chain id's own gate journal row prove the expected full gate at HEAD.
# An older id's row never stands in for the newest: a resume outside tkt-job can
# change the gate and journal no row, so the record and the row must be one job's.
gate_credit_check() {
  [ "$#" -eq 6 ] || gate_credit_refuse 'invalid gate-credit check arguments' || return 1
  local record="$1" journal="$2" job_chain="$3" expected_cmd="$4" expected_env="$5" head="$6"
  local jobid="" chain_id recorded_cmd recorded_env
  local -a chain_ids=()
  [ -n "$expected_cmd" ] || { gate_credit_refuse 'expected gate command is empty'; return 1; }
  while IFS= read -r chain_id; do
    [ -n "$chain_id" ] || continue
    chain_ids+=("$chain_id")
    jobid="$chain_id"
  done <<<"$job_chain"
  [ -n "$jobid" ] || { gate_credit_refuse 'job id is empty'; return 1; }
  [ -r "$record" ] || { gate_credit_refuse "job record is not readable: $jobid"; return 1; }
  jq -e . "$record" >/dev/null 2>&1 || { gate_credit_refuse "job record is not valid JSON: $jobid"; return 1; }
  if ! jq -e '
    .result.gateResult.passed == true
    and .result.gateResult.refused != true
    and .result.gateResult.error == null
    and (.result.gateResult.exitCode | type) == "number"
    and .result.gateResult.exitCode == 0
  ' "$record" >/dev/null 2>&1; then
    gate_credit_refuse "job record does not prove an uninterrupted passing gate: $jobid"
    return 1
  fi

  [ -r "$journal" ] || { gate_credit_refuse "job gate journal is not readable: $jobid"; return 1; }
  job_gate_journal_match "$journal" "${chain_ids[@]}"
  [ "$job_gate_journal_found" -eq 1 ] || { gate_credit_refuse "job gate journal line is missing: $jobid"; return 1; }
  [ "$job_gate_journal_id" = "$jobid" ] || {
    gate_credit_refuse "newest job has no gate journal line of its own: $jobid (newest row is for $job_gate_journal_id)"
    return 1
  }
  recorded_cmd="$job_gate_journal_cmd"
  recorded_env="$job_gate_journal_env"
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

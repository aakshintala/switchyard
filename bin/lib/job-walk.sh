# job_walk: print id<TAB>record-path for a supersededBy chain, stopping on
# missing records and returning 1 on a cycle. Uses job-record's lookup order.
job_walk_superseded() {
  local id="$1" rec next seen='|'
  while [ -n "$id" ]; do
    case "$seen" in *"|$id|"*) return 1 ;; esac
    seen="$seen$id|"
    rec="$(bash "$script_dir/job-record" "$id" 2>/dev/null || true)"
    printf '%s\t%s\n' "$id" "$rec"
    [ -f "$rec" ] || return 0
    next="$(jq -r '.supersededBy // empty' "$rec" 2>/dev/null || true)"
    case "$next" in ''|*/*|.|..) return 0 ;; esac
    id="$next"
  done
}

# job_gate_journal_match JOURNAL ID... takes chain ids oldest to newest and
# stores the newest id with a tkt-job gate row in job_gate_journal_{found,id,cmd,env}.
# A malformed or pre-cmd64 row still owns that id's match with empty evidence.
job_gate_journal_match() {
  local journal="$1" line payload rest slot recorded_id recorded_cmd64 recorded_env64
  local recorded_cmd recorded_env index
  shift
  local -a ids=("$@") has_row=() commands=() environments=()
  job_gate_journal_found=0
  job_gate_journal_id=""
  job_gate_journal_cmd=""
  job_gate_journal_env=""
  for index in "${!ids[@]}"; do
    has_row[$index]=0
    commands[$index]=""
    environments[$index]=""
  done
  [ -r "$journal" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    payload="${line#* }"
    case "$payload" in "tkt-job gate slot="*) ;; *) continue ;; esac
    rest="${payload#tkt-job gate slot=}"
    case "$rest" in *" "*) ;; *) continue ;; esac
    slot="${rest%% *}"
    rest="${rest#* }"
    case "$rest" in job=*) ;; *) continue ;; esac
    recorded_id="${rest#job=}"
    case "$recorded_id" in *" "*) ;; *) continue ;; esac
    recorded_id="${recorded_id%% *}"
    [ -n "$slot" ] || continue

    for index in "${!ids[@]}"; do
      [ "$recorded_id" = "${ids[$index]}" ] || continue
      has_row[$index]=1
      commands[$index]=""
      environments[$index]=""
      rest="${rest#* }"
      case "$rest" in cmd64=*) ;; *) continue ;; esac
      recorded_cmd64="${rest#cmd64=}"
      case "$recorded_cmd64" in *" "*) recorded_cmd64="${recorded_cmd64%% *}" ;; *) continue ;; esac
      rest="${rest#* }"
      case "$rest" in env64=*) ;; *) continue ;; esac
      recorded_env64="${rest#env64=}"
      case "$recorded_env64" in *" "*) continue ;; esac
      recorded_cmd="$(printf '%s' "$recorded_cmd64" | jq -Rrs '@base64d' 2>/dev/null)" || continue
      recorded_env="$(printf '%s' "$recorded_env64" | jq -Rrs '@base64d' 2>/dev/null)" || continue
      # Rows tkt-job wrote at 903c98a journal 'bash <lib>/tkt-stray-run.sh <state> <run> && <Gate>'.
      # The step runs before the Gate, and && means the Gate ran too, so the row records the Gate.
      case "$recorded_cmd" in
        "bash "*"/lib/tkt-stray-run.sh "*" && "*)
          case "${recorded_cmd%% && *}" in
            "bash "*"/lib/tkt-stray-run.sh "*) recorded_cmd="${recorded_cmd#* && }" ;;
          esac
          ;;
      esac
      commands[$index]="$recorded_cmd"
      environments[$index]="$recorded_env"
      break
    done
  done <"$journal"

  for ((index=${#ids[@]} - 1; index >= 0; index--)); do
    [ "${has_row[$index]}" -eq 1 ] || continue
    job_gate_journal_found=1
    job_gate_journal_id="${ids[$index]}"
    job_gate_journal_cmd="${commands[$index]}"
    job_gate_journal_env="${environments[$index]}"
    return 0
  done
}

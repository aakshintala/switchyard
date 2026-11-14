# findings-history: preserve finding origins, closures and unverified rounds.
# Source after namebase.sh; callers provide state, run, namebase, part_suffix,
# findings, history_file, knum and t().

# Store every finding supplied to a scoped verify, with its origin and later
# closure, separately from the open-only file the next fix job consumes.
write_findings_history() {
  local action="$1" verify_output="${2:-}" round_list_file="${3:-}" history_source row base meta raised status unverified round_path round_no
  local rounds_csv="" rounds_seen="" earlier=0 label
  local i found new_raised
  local -a history_base=() history_raised=() history_status=() history_unverified=() verify_open=()
  history_add_row() {
    local mode="$1" default_raised="$2" row="$3" base meta parsed_raised parsed_status parsed_unverified raised status unverified i
    case "$row" in P1\ *|P2\ *|P3\ *) ;; *) return 0;; esac
    base="$row"; meta=""
    case "$row" in
      *" [tkt-history:"*)
        base="${row%% [tkt-history:*}"
        meta="${row#* [tkt-history: }"; meta="${meta%]}" ;;
    esac
    parsed_raised="$(sed -n 's/.*raised=\([^;]*\).*/\1/p' <<<"$meta")"
    parsed_status="$(sed -n 's/.*status=\([^;]*\).*/\1/p' <<<"$meta")"
    parsed_unverified="$(sed -n 's/.*unverified=\([^;]*\).*/\1/p' <<<"$meta")"
    case "$mode" in
      history)
        raised="${parsed_raised:-$default_raised}"
        status="${parsed_status:-open}"
        unverified="$parsed_unverified" ;;
      current)
        raised="$default_raised"; status=open; unverified="" ;;
      round)
        raised="$default_raised"
        status="${parsed_status:-open}"
        unverified="$parsed_unverified" ;;
    esac
    for i in "${!history_base[@]}"; do [ "${history_base[$i]}" = "$base" ] && return 0; done
    history_base+=("$base"); history_raised+=("$raised"); history_status+=("$status"); history_unverified+=("$unverified")
  }
  history_source="$(t get findings_history 2>/dev/null || true)"
  if [ -n "$history_source" ] && [ -r "$history_source" ]; then
    while IFS= read -r row; do history_add_row history unknown "$row"; done <"$history_source"
  fi
  # The first findings file is round 0's posted review. Later untracked input
  # is labelled unknown rather than being assigned a round without evidence.
  if [ "${#history_base[@]}" -eq 0 ] && { [ -z "$history_source" ] || [ ! -r "$history_source" ]; }; then new_raised="raised in review round 0"; else new_raised="raised in unknown round"; fi
  while IFS= read -r row; do history_add_row current "$new_raised" "$row"; done <"$findings"
  if [ -n "$round_list_file" ] && [ -r "$round_list_file" ]; then
    while IFS= read -r round_no; do
      case "$round_no" in ''|*[!0-9]*) continue;; esac
      if [ "$round_no" -lt "$knum" ]; then earlier=$((earlier + 1)); fi
      round_path="$(t get "fix_round.$round_no.findings" 2>/dev/null || true)"
      [ -n "$round_path" ] && [ -r "$round_path" ] || continue
      if [ "$round_no" -eq 1 ]; then raised="raised in review round 0"; else raised="raised in fix round $((round_no - 1))"; fi
      while IFS= read -r row; do history_add_row round "$raised" "$row"; done <"$round_path"
    done <"$round_list_file"
  fi
  if [ -n "$verify_output" ] && [ -r "$verify_output" ]; then
    while IFS= read -r row; do
      case "$row" in P1\ *|P2\ *|P3\ *) verify_open+=("$row");; esac
    done <"$verify_output"
  fi
  for i in "${!history_base[@]}"; do
    base="${history_base[$i]}"; status="${history_status[$i]}"; unverified="${history_unverified[$i]}"
    if [ "$action" = verified ] && [ "$status" = open ]; then
      found=0
      for row in "${verify_open[@]+${verify_open[@]}}"; do [ "$row" = "$base" ] && found=1 && break; done
      [ "$found" -eq 1 ] || history_status[$i]="closed in fix round $knum"
    elif [ "$action" = unverified ] && [ "$status" = open ]; then
      case ",$unverified," in *",fix round $knum,"*) ;; *) unverified="${unverified:+$unverified,}fix round $knum";; esac
      history_unverified[$i]="$unverified"
    fi
  done
  if [ "$action" = verified ]; then
    for row in "${verify_open[@]+${verify_open[@]}}"; do
      found=0
      for base in "${history_base[@]+${history_base[@]}}"; do [ "$base" = "$row" ] && found=1 && break; done
      if [ "$found" -eq 0 ]; then
        history_base+=("$row"); history_raised+=("raised in fix round $knum"); history_status+=(open); history_unverified+=("")
      fi
    done
  fi
  for raised in "${history_raised[@]+${history_raised[@]}}"; do
    case "$raised" in "raised in review round "*|"raised in fix round "*)
      label="${raised#raised in }"
      case ";$rounds_seen;" in *";$label;"*) ;; *) rounds_seen="${rounds_seen:+$rounds_seen; }$label";; esac ;;
    esac
  done
  if [ -n "$rounds_seen" ]; then rounds_csv="$rounds_seen"; else rounds_csv=unknown; fi
  if ! findings_write_allowed "$state" "$history_file"; then
    echo "tkt-fix: refusing to overwrite $history_file: history path is not owned by this ticket state" >&2
    exit 2
  fi
  {
    printf '# Findings history for scoped verification\n'
    printf 'Finding rounds held: %s.\n' "$rounds_csv"
    printf 'Earlier fix rounds in this diff: %s.\n' "$earlier"
    printf 'Current fix round: %s.\n\n' "$knum"
    if [ "${#history_base[@]}" -eq 0 ]; then printf 'no open findings\n'; fi
    for i in "${!history_base[@]}"; do
      printf '%s [tkt-history: raised=%s; status=%s; unverified=%s]\n' \
        "${history_base[$i]}" "${history_raised[$i]}" "${history_status[$i]}" "${history_unverified[$i]:-none}"
    done
  } >"$history_file"
  t journal "findings history write $history_file"
  t set findings_history "$history_file"
  t set "fix_round.$knum.history" "$history_file"
}

#!/usr/bin/env bash
# Print the ticket's canonical file-claim holder name.
claim_holder() {
  printf 'fiber-%s' "$1"
}

# Print the ticket number encoded in a file-claim lane id, or nothing.
lane_ticket_num() {
  local lane="$1"

  case "$lane" in
    fiber-*)
      lane="${lane#fiber-}"
      if [[ "$lane" =~ ^([0-9]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
      fi
      return
      ;;
    sweep-*)
      lane="${lane#sweep-}"
      if [[ "$lane" =~ ^([0-9]+)(-|$) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return
      fi
      ;;
  esac

  if [[ "$lane" =~ (^|/)([0-9]+)(-|$) ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
  fi
}

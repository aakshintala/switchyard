# namebase: shared ticket file stem, sourced by the tkt-* scripts.
# Source it from beside the calling script, with script_dir resolved through
# symlinks as bin/fill-brief does (check-pack refuses a bare dirname "$0"):
#   namebase_lib="$script_dir/lib/namebase.sh"
# Every function returns 0 unless stated, and is safe under `set -euo pipefail`.

# require_state_file SCRIPT STATE: exit 2 with a caller-specific diagnostic when
# STATE is missing. Check before probing its lock so a missing parent directory
# cannot be misreported as a held state lock.
require_state_file() {
  local caller="$1" state_path="$2"
  if [ ! -f "$state_path" ]; then
    printf '%s: no state file at %s\n' "$caller" "$state_path" >&2
    exit 2
  fi
}

# take_state_lock CALLER DIR: create DIR or report its holder and exit 2.
# On success, DIR remains held for the caller to release.
take_state_lock() {
  local caller="$1" lock_dir="$2" pid
  if mkdir "$lock_dir" 2>/dev/null; then
    return 0
  fi
  pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    printf '%s: state locked by pid %s\n' "$caller" "$pid" >&2
  else
    printf '%s: state locked\n' "$caller" >&2
  fi
  exit 2
}

# set_namebase REPO ISSUE: set $namebase to "<repo tail>-<issue>", the stem
# every tkt-* script builds its run, brief, gate and log paths from.
set_namebase() {
  namebase="${1##*/}-$2"
}

# part_findings_suffix PART: print "-part<N>" when PART is an integer of 2
# or more, else print nothing. Keeps single-part (no part key, or part 1)
# findings paths exactly as before.
part_findings_suffix() {
  case "$1" in ''|*[!0-9]*) return 0;; esac
  if [ "$1" -ge 2 ] 2>/dev/null; then printf '%s' "-part$1"; fi
}

# findings_write_allowed STATE DEST: return 0 when DEST may be written as
# this ticket's findings or findings_history file: it does not exist, the state
# points to it, or the journal holds the corresponding `findings write` line.
# Return 1 otherwise.
findings_write_allowed() {
  local st="$1" dest="$2" line journal rest
  [ -e "$dest" ] || return 0
  if [ -f "$st" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        findings=*|findings_history=*)
          [ "${line#*=}" = "$dest" ] && return 0
          ;;
      esac
    done <"$st"
  fi
  journal="${st%.state}.journal"
  [ -f "$journal" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    rest="${line#* }"
    [ "$rest" = "findings write $dest" ] || [ "$rest" = "findings history write $dest" ] && return 0
  done <"$journal"
  return 1
}

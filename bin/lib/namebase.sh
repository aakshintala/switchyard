# namebase: shared ticket file stem, sourced by the tkt-* scripts.
# Source it from beside the calling script, with script_dir resolved through
# symlinks as bin/fill-brief does (check-pack refuses a bare dirname "$0"):
#   namebase_lib="$script_dir/lib/namebase.sh"
# Every function returns 0 unless stated, and is safe under `set -euo pipefail`.

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

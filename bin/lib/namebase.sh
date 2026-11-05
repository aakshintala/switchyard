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

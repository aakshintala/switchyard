#!/usr/bin/env bash
# Move an untracked worktree-root run/ into the ticket state's run directory
# before delegate computes the job's change set.
set -euo pipefail

[ $# -eq 2 ] || {
  echo "tkt-stray-run: usage: tkt-stray-run <state> <state-run-dir>" >&2
  exit 2
}
state="$1"
run_dir="$2"
job_id="${DELEGATE_JOB_ID:-}"
if [ -z "$job_id" ]; then
  echo "tkt-stray-run: DELEGATE_JOB_ID is missing" >&2
  exit 1
fi

script_path="$0"
case "$script_path" in */*) ;; *) script_path="$(command -v "$script_path")" ;; esac
while [ -L "$script_path" ]; do
  link_dir="$(cd "$(dirname "$script_path")" && pwd)"
  link="$(readlink "$script_path")"
  case "$link" in /*) script_path="$link" ;; *) script_path="$link_dir/$link" ;; esac
done
script_dir="$(cd "$(dirname "$script_path")/.." && pwd)"
tkt_state="$script_dir/tkt-state"
worktree="$(git rev-parse --show-toplevel)"
stray_run="$worktree/run"
[ -d "$stray_run" ] && [ ! -L "$stray_run" ] || exit 0

tracked="$(git -C "$worktree" ls-files -- run)" || {
  echo "tkt-stray-run: cannot check tracked files under $stray_run" >&2
  exit 1
}
[ -z "$tracked" ] || exit 0

mkdir -p "$run_dir"
source_real="$(cd "$stray_run" && pwd -P)"
destination_real="$(cd "$run_dir" && pwd -P)"
case "$destination_real/" in
  "$source_real/"*)
    echo "tkt-stray-run: state run directory is inside the source run directory" >&2
    exit 1
    ;;
esac

exists_or_symlink() {
  [ -e "$1" ] || [ -L "$1" ]
}

move_one() {
  local source="$1" basename candidate source_rel source_q destination_q suffix=0
  basename="${source##*/}"
  source_rel="${source#"$stray_run"/}"
  while :; do
    if [ "$suffix" -eq 0 ]; then
      candidate="$run_dir/stray-$job_id-$basename"
    else
      candidate="$run_dir/stray-$job_id-$suffix-$basename"
    fi
    if exists_or_symlink "$candidate"; then
      suffix=$((suffix + 1))
      continue
    fi
    if mv -n "$source" "$candidate"; then
      if [ ! -e "$source" ] && [ ! -L "$source" ]; then
        printf -v source_q '%q' "run/$source_rel"
        printf -v destination_q '%q' "$candidate"
        if ! "$tkt_state" "$state" journal "tkt-build stray-run moved path=$source_q destination=$destination_q"; then
          echo "tkt-stray-run: moved $source but could not journal it" >&2
          return 1
        fi
        return 0
      fi
      if exists_or_symlink "$candidate"; then
        suffix=$((suffix + 1))
        continue
      fi
    fi
    echo "tkt-stray-run: could not move $source without overwriting a destination" >&2
    return 1
  done
}

while IFS= read -r -d '' source; do
  move_one "$source" || exit 1
done < <(find "$stray_run" \( -type f -o -type l \) -print0)
exit 0

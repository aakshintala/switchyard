#!/usr/bin/env bash
# box-push.sh <ticket> -- send a ticket's run/ files and the roster to the box.
#
# The box-side fence probe maps live delegate sessions through this roster, so
# refresh it whenever lane state is pushed.
#
# boxlaunch.sh copies these files once, at launch. Anything written after that
# -- an admit file, a grant from a mid-plan fence-grant run, a ruling, an added
# extra -- stays on the Mac, and the lane cannot see it. On 2026-11-06 #4201
# refused a bare ADMIT message because its brief says build nothing without an
# ADMITTED file, and it was right: the file existed here and nowhere else.
# Three of its five grants were in the same state.
#
# So the fix is not "remember to copy": it is this script, run after writing
# anything a live box lane must read, before the message that tells it to look.
# Same sed rewrite as boxlaunch.sh, so a Mac path inside a file still points
# somewhere real on the box.
set -euo pipefail
script_path=${BASH_SOURCE[0]}
while [ -L "$script_path" ]; do
  script_dir=$(cd "$(dirname "$script_path")" && pwd)
  link=$(readlink "$script_path")
  case "$link" in /*) script_path=$link;; *) script_path=$script_dir/$link;; esac
done
script_dir=$(cd "$(dirname "$script_path")" && pwd)
. "$script_dir/lib/fw-lib.sh"

n=${1:?usage: box-push.sh <ticket>}
if [ -z "${BOX_SSH:-}" ] && [ "$(uname -s)" != Darwin ]; then
  echo "box-push: no-op, run/ is the same directory for the flywheel and the box"
  exit 0
fi
ssh=${BOX_SSH:-ssh}
host=${FW_BOX_HOST:-roundhouse-7010-plus-1.local}
mac=${FW_MAC_HOME:-$HOME}; box=$(fw_box_home)
run=${FW_RUN:-${RUN_DIR:-$mac/work/fiber-worktrees/flywheel/run}}
dst=${FW_BOX_RUN:-$box/work/fiber-worktrees/flywheel/run}

sent=0
set +f
for f in \
  "$run/roster" \
  "$run/roster-done" \
  "$run/report-format.md" \
  "$run/fiber-$n-notes.md" \
  "$run/fiber-$n-"*-notes.md \
  "$run/fiber-$n-extra.md" \
  "$run/fiber-$n-spec.md" \
  "$run/fiber-$n-admit"*.md \
  "$run/fiber-$n-ruling"*.md \
  "$run/fiber-$n-fence-grant"*.md
do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  case "$name" in
    roster|roster-done) remote="cat > $dst/$name.tmp && mv $dst/$name.tmp $dst/$name";;
    *) remote="cat > $dst/$name";;
  esac
  sed "s|$mac|$box|g" "$f" | $ssh "$host" "$remote"
  echo "sent $name"
  sent=$((sent + 1))
done
set -f

[ "$sent" -gt 0 ] || { echo "box-push: no run/ files for $n -- nothing sent" >&2; exit 1; }
echo "box-push: $sent file(s) to $host"

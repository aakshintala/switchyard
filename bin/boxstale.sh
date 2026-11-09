#!/usr/bin/env bash
# boxstale.sh -- is the box's ~/.agents behind this Mac's?
#
# Prints one line and exits 0 when they match, 1 when the box is behind, 2 when
# it cannot tell. Never fails a launch by itself: boxlaunch calls it for the
# warning, because refusing to launch would cost more than the stale tools do.
#
# Why this exists, and why here. On 2026-11-06 the box had been running
# switchyard tools from 2e82427 for months: `ship-pr` fast-forwards ~/.agents
# on the machine it runs on and nowhere else (ship-pr:30), and nothing pulls
# the box. Every fix landed on the Mac, and a lane running the full gate on the
# box kept dying on a 30-minute idle window that had been fixed twice.
#
# Switchyard's own answer is a `tkt-job` check against origin -- but that is
# new code on the box, and new code on the box needs the pull it is meant to
# detect. A check that runs HERE needs nothing on the box: the Mac's SHA is a
# file read, and the box's is one ssh read. So the detection lives on this side
# of the wire, in flywheel's own bin, and works while the box is at any SHA.
#
# A read, never a write. The pull is the owner's (switchyard#1290): ~/.agents
# is switchyard's checkout and fixing it from here would hide the skew.
set -uo pipefail

script_path=${BASH_SOURCE[0]}
while [ -L "$script_path" ]; do
  script_dir=$(cd "$(dirname "$script_path")" && pwd)
  link=$(readlink "$script_path")
  case "$link" in /*) script_path=$link;; *) script_path=$script_dir/$link;; esac
done
script_dir=$(cd "$(dirname "$script_path")" && pwd)
ssh=${BOX_SSH:-}
if [ -z "$ssh" ]; then
  if [ "$(uname -s)" = Darwin ]; then ssh=ssh; else ssh=$script_dir/box-local.sh; fi
fi
host=${BOX_HOST:-roundhouse-7010-plus-1.local}
# On the Linux box the local checkout is the only ~/.agents; there is no remote
# copy to compare. An explicit BOX_SSH still enables the remote check in tests.
if [ -z "${BOX_SSH:-}" ] && [ "$(uname -s)" != Darwin ]; then
  echo "boxstale: no-op, the flywheel runs on the box and ~/.agents is the only copy"
  exit 0
fi
# Both overrides exist for bin/test-boxstale.sh and nothing else. The real
# value is the default: a test that had to patch this file to run would be
# testing a copy of the script rather than the script.
agents=${FW_AGENTS_DIR:-$HOME/.agents}
mac_head="$agents/.git/refs/heads/main"

# Ask git first, and fall back to the loose ref. Reading the loose ref alone was
# the original shape and it is a blind spot: `git pack-refs` (which `git gc`
# runs on its own) moves main into packed-refs and deletes the loose file, so
# the read would start failing with exit 2 on a repo that is perfectly healthy.
m="$(git -C "$agents" rev-parse HEAD 2>/dev/null | tr -d ' \n')"
[ -n "$m" ] || m="$(cat "$mac_head" 2>/dev/null | tr -d ' \n')"
[ -n "$m" ] || { echo "boxstale: cannot read the Mac's ~/.agents HEAD (rev-parse and the loose main ref both failed)"; exit 2; }

b="$($ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" 'git -C ~/.agents rev-parse HEAD' 2>/dev/null | tr -d ' \n')"
[ -n "$b" ] || { echo "boxstale: cannot read the box's ~/.agents HEAD (ssh or git failed)"; exit 2; }

if [ "$m" = "$b" ]; then
  echo "boxstale: box ~/.agents matches this Mac at ${m:0:8}"
  exit 0
fi

# The shas differ, and that is all we know yet. Until 2026-11-06T18:5xZ this
# line printed "BOX IS BEHIND" on any mismatch and then listed five hardcoded
# consequences, written when the box was months back at 2e82427. By this
# evening the box was ONE commit behind -- it already had the fixes for four of
# the five -- and the output still claimed all five. I read that block as live
# all day and cited it in filings and lane briefs, including #4312's launch.
#
# A constant cannot describe a varying gap. So: derive the direction from
# ancestry, and let the missing commits' own subject lines be the consequence
# list. Nothing to keep in sync, and no consequence claimed that is not in the
# gap. The one durable line survives below, because it is about how to READ the
# gap rather than what is in it.
#
# Direction matters on its own. A mismatch can mean this Mac is the stale one,
# and the old wording would have called that "BOX IS BEHIND" and sent the owner
# to pull a box that was ahead.
gap=""
if git -C "$agents" cat-file -e "${b}^{commit}" 2>/dev/null; then
  if git -C "$agents" merge-base --is-ancestor "$b" "$m" 2>/dev/null; then
    n="$(git -C "$agents" rev-list --count "$b..$m" 2>/dev/null)"
    echo "boxstale: BOX IS BEHIND by ${n:-?} -- box ${b:0:8}, Mac ${m:0:8}"
    gap="$(git -C "$agents" log --oneline --no-decorate "$b..$m" 2>/dev/null)"
  elif git -C "$agents" merge-base --is-ancestor "$m" "$b" 2>/dev/null; then
    n="$(git -C "$agents" rev-list --count "$m..$b" 2>/dev/null)"
    echo "boxstale: THIS MAC IS BEHIND by ${n:-?} -- box ${b:0:8}, Mac ${m:0:8}"
    echo "  The box is ahead. Do not send the owner to pull it; pull here instead."
    exit 1
  else
    echo "boxstale: DIVERGED -- box ${b:0:8}, Mac ${m:0:8}, neither contains the other"
    echo "  This is not a missed pull. Someone committed to ~/.agents on both hosts."
    exit 1
  fi
else
  echo "boxstale: BOX AT AN UNKNOWN COMMIT -- box ${b:0:8}, Mac ${m:0:8}"
  echo "  ${b:0:8} is not in this Mac's ~/.agents, so the direction cannot be read."
  echo "  Run: git -C $agents fetch --all, then rerun."
  exit 2
fi

echo "  Box lanes are missing exactly these, and nothing else:"
if [ -n "$gap" ]; then
  echo "$gap" | sed 's/^/    /'
else
  echo "    (the log came back empty, which contradicts the count above -- read it by hand)"
fi
# The one line worth keeping as a constant: it is advice about reading the gap,
# not a claim about what is in it, so it does not go stale as the box moves.
# Three filings in the week to 2026-11-06 traced to this host being behind
# rather than to a defect (switchyard#1305, the REFUSE-in-state note, #1314).
echo "  Before filing a box lane's tool defect, check it is not one of the above,"
echo "  and cite the box sha either way."
echo "  The fix is the owner's, at the top of run/owner-queue.md (switchyard#1290):"
echo "  ssh $host 'git -C ~/.agents pull -q --ff-only'"
exit 1

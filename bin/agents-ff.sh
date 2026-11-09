#!/usr/bin/env bash
# agents-ff.sh -- fast-forward the box's ~/.agents, then say where both hosts are.
#
# The Mac ships ~/.agents and the box only consumes it, so the box is always
# behind by however long since someone last pulled, and nothing on the box
# notices. On 2026-11-06 that gap reopened three times in six hours: a pull at
# 12:11Z closed it, a ship crossed the pull within the hour and reopened it at
# one commit, and a two-commit batch widened it again by 18:30Z. Each cycle
# cost a queue row, an owner ask or a grant-holder's sweep, and a round of shas
# compared by hand. switchyard #1319 settled the shape: the box's launch path
# pulls, rather than the drift being pinned and rediscovered one tool at a time.
#
# This is the write half; `boxstale.sh` stays a read (switchyard #1290). The
# pull used to be the owner's step because it was a bare interactive command
# with no declared caller. Here it has one: the launch path, where a stale tool
# does measurable damage, and where the action is an idempotent --ff-only that
# can only ever move the box onto a commit the Mac already has.
#
# Two properties, both of them the point:
#
#   1. A failed pull never blocks a launch. A lane that cannot start is strictly
#      worse than a lane starting on a slightly stale tool, so every failure
#      path here exits 0 after a WARN. Only `--strict` exits nonzero, for a
#      caller that wants to gate on it.
#   2. The WARN names both shas. "pull failed" alone leaves the reader doing the
#      comparison by hand, which is the cost this removes.
#
# Usage: bash bin/agents-ff.sh [--strict]
# FW_NO_AGENTS_FF=1 skips it entirely (offline, tests).
# FW_AGENTS_DIR, FW_BOX_HOST, BOX_SSH override the Mac dir, host and ssh.
set -uo pipefail

strict=0
[ "${1:-}" = --strict ] && strict=1

[ -n "${FW_NO_AGENTS_FF:-}" ] && {
    echo "agents-ff: skipped (FW_NO_AGENTS_FF=$FW_NO_AGENTS_FF)" >&2
    exit 0
}
if [ -z "${BOX_SSH:-}" ] && [ "$(uname -s)" != Darwin ]; then
    echo "agents-ff: no-op, the flywheel runs on the box and ~/.agents is the only copy" >&2
    exit 0
fi

agents=${FW_AGENTS_DIR:-$HOME/.agents}
host=${FW_BOX_HOST:-roundhouse-7010-plus-1.local}
ssh=${BOX_SSH:-ssh}

warn() {
    echo "WARN agents-ff: $1" >&2
    shift
    for line in "$@"; do echo "  $line" >&2; done
    echo "  the caller carries on: a lane that cannot start is worse than a stale tool." >&2
    [ "$strict" = 1 ] && exit 3
    exit 0
}

mac=$(git -C "$agents" rev-parse HEAD 2>/dev/null | tr -d ' \n')
# Fall back to the loose ref, the way boxstale.sh does: a worktree guard or a
# busy index can fail rev-parse while the ref file is perfectly readable.
[ -n "$mac" ] && [ ${#mac} -eq 40 ] || mac=$(tr -d ' \n' <"$agents/.git/refs/heads/main" 2>/dev/null)
[ -n "$mac" ] || warn "cannot read this Mac's ~/.agents HEAD" \
    "tried: git -C $agents rev-parse HEAD, and $agents/.git/refs/heads/main" \
    "nothing was pulled, because there is no target to compare against."

# One round trip: pull, report its exit code, then report where the box landed.
# The exit code is reported rather than relied on, because ssh's own exit code
# cannot distinguish "git failed" from "the box is unreachable" and those want
# different reading.
out=$($ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" \
    'git -C ~/.agents pull -q --ff-only >/dev/null 2>&1; echo "RC=$?"; git -C ~/.agents rev-parse HEAD 2>/dev/null' \
    2>/dev/null)
sshrc=$?

rc=$(printf '%s\n' "$out" | sed -n 's/^RC=//p' | head -1)
box=$(printf '%s\n' "$out" | sed -n 's/^\([0-9a-f]\{40\}\)$/\1/p' | head -1)

[ -n "$box" ] || warn "cannot read the box's ~/.agents HEAD after the pull" \
    "ssh exit $sshrc, pull exit ${rc:-no-answer}, host $host" \
    "mac=$mac box=unknown"

if [ "$box" = "$mac" ]; then
    printf 'agents-ff: box ~/.agents matches this Mac at %.8s\n' "$mac" >&2
    exit 0
fi

# A pull that exited 0 and still left a different sha is the interesting case:
# it means the box is ahead, or diverged, or its remote does not carry the
# Mac's commits yet. Say which, because the fix differs.
reason="the pull exited ${rc:-no-answer} and the shas still differ"
if [ "${rc:-1}" = 0 ] && git -C "$agents" cat-file -e "${box}^{commit}" 2>/dev/null; then
    if git -C "$agents" merge-base --is-ancestor "$mac" "$box" 2>/dev/null; then
        reason="the box is AHEAD of this Mac -- someone committed to ~/.agents there"
    else
        reason="the box's commit is not an ancestor or descendant of this Mac's -- the two have diverged"
    fi
fi

warn "box ~/.agents does not match this Mac" \
    "mac=$mac" \
    "box=$box" \
    "$reason" \
    "fix with: ssh $host 'git -C ~/.agents pull --ff-only'"

#!/usr/bin/env bash
# Newest report per ticket, with its STATUS line and age.
#
# Why this exists: a lane report that ends in a question is drained to read/ the
# moment it is read, so every later inbox check looks clean whether or not the
# question was answered. On 2026-11-03 #3890 idled 40 minutes that way. The
# watcher tells you a message arrived; nothing tells you an arrived message
# still wants something. This does.
#
# BLOCKED, READY or a trailing question mark means the report wanted something.
# The RULED column answers whether it got it: it holds the age of the newest
# ruling in run/rulings/ for that ticket, and "<-" marks a ruling newer than the
# report, which means the lane is working on an answer and its BLOCKED line is
# stale. A flagged row with no "<-" is a lane genuinely waiting on you.
#
# The RULED column is only as good as the archive, so deliver every ruling with
# bin/ruled.sh, which archives and scps in one step.
#
# Usage: bash bin/pending.sh [inbox-dir]   (default run/inbox)

set -uo pipefail

script_path=${BASH_SOURCE[0]}
while [ -L "$script_path" ]; do
    script_dir=$(cd "$(dirname "$script_path")" && pwd)
    link=$(readlink "$script_path")
    case "$link" in /*) script_path=$link;; *) script_path=$script_dir/$link;; esac
done
root=$(cd "$(dirname "$script_path")/.." && pwd)
R=${FW_RUN:-${RUN_DIR:-$HOME/work/fiber-worktrees/flywheel/run}}
inbox="${1:-$R/inbox}"
read_dir="$inbox/read"

[ -d "$read_dir" ] || { echo "no such directory: $read_dir" >&2; exit 1; }

now=$(date +%s)

# Newest file per ticket number, across read/ and any undrained reports.
# Report names look like box-box-<ticket>-<stamp>-<pid>-<n>.md; peers (surveyor,
# switchyard, flywheel) carry no ticket and are skipped.
for f in "$read_dir"/*.md "$inbox"/*.md; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    ticket=$(printf '%s\n' "$base" | sed -n 's/^[a-z]*-[a-z]*-\([0-9][0-9]*\)-.*/\1/p')
    [ -n "$ticket" ] || ticket=$(printf '%s\n' "$base" | sed -n 's/^box-\([0-9][0-9]*\)-.*/\1/p')
    [ -n "$ticket" ] || continue
    printf '%s\t%s\t%s\n' "$ticket" "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")" "$f"
done | sort -k1,1n -k2,2nr | awk -F'\t' '!seen[$1]++' > /tmp/pending-newest.$$

rulings="$R/rulings"

printf '%-6s %-7s %-9s %s\n' TICKET AGE RULED STATE
while IFS=$'\t' read -r ticket mtime file; do
    age_min=$(( (now - mtime) / 60 ))
    # Newest ruling for this ticket, and whether it postdates the report.
    ruled='-'
    newest=$(ls -t "$rulings"/ruling-"$ticket"-*.md 2>/dev/null | head -1)
    if [ -n "$newest" ]; then
        rmtime=$(stat -f %m "$newest" 2>/dev/null || stat -c %Y "$newest")
        ruled="$(( (now - rmtime) / 60 ))m"
        [ "$rmtime" -gt "$mtime" ] && ruled="$ruled<-"
    fi
    status=$(grep -h '^STATUS' "$file" | tail -1 | cut -c1-120)
    [ -n "$status" ] || status=$(tail -1 "$file" | cut -c1-120)
    # A report whose status names a block, a wait, or a question is the kind
    # that goes stale silently.
    flag=' '
    case "$status" in
        *BLOCKED*|*READY*|*AWAIT*|*await*|*\?*) flag='!' ;;
    esac
    printf '%s%-5s %5dm  %-9s %s\n' "$flag" "$ticket" "$age_min" "$ruled" "$status"
done < /tmp/pending-newest.$$

rm -f /tmp/pending-newest.$$

echo
echo "! = the report names a block, a wait or a question."
echo "RULED = age of the newest ruling for that ticket; <- means it postdates the report."
echo "So a '!' row with no '<-' is a lane genuinely waiting on you,"
echo "unless its ruling predates 2026-11-04 12:00Z: until then rulings were"
echo "often delivered by hand and never archived, so the column cannot tell"
echo "\"never ruled\" from \"ruled off-archive\". On 2026-11-04 #3696, #3890,"
echo "#3979 and #4155 all flagged that way while bin/lanecheck showed every one"
echo "of them LIVE and taking turns. For a ticket last ruled before that stamp,"
echo "confirm with bin/lanecheck before acting on this column."

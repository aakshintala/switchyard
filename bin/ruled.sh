#!/usr/bin/env bash
# Archive a ruling locally and deliver it to a box lane's inbox.
#
# Why this exists: a ruling written in a session's tmp dir and scp'd to the box
# leaves no durable local trace, so the next inbox check cannot tell a lane that
# is working on an answer from one still waiting for it. On 2026-11-03 that cost
# two ssh calls and a nearly-wasted ruling on #4086, whose BLOCKED report
# predated its answer by two minutes. The archive is also the only place a past
# ruling can be re-read once a job's tmp dir is gone.
#
# The host comes from the roster, not from a default. It used to default to the
# box unconditionally, which silently mis-delivered every mac lane's ruling:
# RULING-3954-34 and -35 both went to the box's lane-inbox/3954/ while the lane
# was a Mac Claude session with no such directory, so neither was ever read.
# A mac lane has no inbox at all — it is a Claude background session, reached
# with SendMessage — so this script archives the ruling and tells you that,
# rather than writing a file nothing reads.
#
# Usage: bash bin/ruled.sh <ticket> <ruling-file>
#   bash bin/ruled.sh 4029 /abs/path/ruling-4029-1.md
# INBOX_HOST overrides the roster lookup.

set -uo pipefail

script_path=${BASH_SOURCE[0]}
while [ -L "$script_path" ]; do
    script_dir=$(cd "$(dirname "$script_path")" && pwd)
    link=$(readlink "$script_path")
    case "$link" in /*) script_path=$link;; *) script_path=$script_dir/$link;; esac
done
script_dir=$(cd "$(dirname "$script_path")" && pwd)
root=$(cd "$script_dir/.." && pwd)
R=${FW_RUN:-${RUN_DIR:-$HOME/work/fiber-worktrees/flywheel/run}}
archive="$R/rulings"
. "$script_dir/lib/fw-lib.sh"

ticket="${1:-}"
src="${2:-}"

case "$ticket" in
    ''|*[!0-9]*) echo "usage: bash bin/ruled.sh <ticket> <ruling-file>" >&2; exit 2 ;;
esac
[ -s "$src" ] || { echo "no such ruling file, or empty: $src" >&2; exit 2; }

# The selftest refusal guard is deliberately not included in this moved slice.
# The archive has exactly one name shape, `ruling-<ticket>-<rest>.md`, because a
# reader globs for it: bin/lanecheck's NEEDS-RULING probe finds a lane's answers
# with `rulings/ruling-*.md` and reads the ticket out of the name. A ruling
# delivered from a file named anything else archived fine and was invisible to
# that glob, so the probe would call an answered lane unanswered. GRANT-4140-1
# (2026-11-04) was the first: delivered from run/fiber-4140-build-grant.md, it
# landed in the archive under that name and answered nothing as far as the probe
# could see. The name is derived here rather than left to whoever writes the
# file, because a convention I have to remember is the thing that just failed.
#
# A source already in the shape keeps its name — that is what the backfilled
# rulings have. Anything else is prefixed, dropping a leading `fiber-<ticket>-`
# so the ticket is not spelled twice.
mkdir -p "$archive" || exit 1
base="$(basename "$src")"
case "$base" in
    ruling-"$ticket"-*) ;;
    fiber-"$ticket"-*)  base="ruling-$ticket-${base#fiber-"$ticket"-}" ;;
    *)                  base="ruling-$ticket-$base" ;;
esac
dest="$archive/$base"
# A ruling written straight into the archive is already in place; cp would exit
# non-zero on "are identical" and report a failure that did not happen.
# -ef and not a string compare: the same file reached by a relative path and by
# an absolute one is still the same file, and that is how it is usually spelled.
if [ ! "$src" -ef "$dest" ]; then
    cp -p "$src" "$dest" || exit 1
fi
echo "archived: $dest"

# Stamp which report this ruling answers, so lanecheck can tell an answered ask
# from a newer, still-open one. Before this, lanecheck read "a ruling is newer
# than the report" as "the ask is answered" — a time proxy for identity. On
# 2026-11-05 #4131 reported at 16:04:33Z and RULING-4131-3 was archived at
# 16:08:37Z, four minutes later, answering an *earlier* question: the live ask
# read as settled and sat unseen while it held up PR #4205, and #3891 behind it.
#
# The newest report for the ticket at archive time is the one being answered.
# The race: a report landing between writing the ruling and running this script
# gets named instead, and the real ask reads as answered. That fails in the same
# direction as the time rule it replaces, no worse, and only inside that window.
#
# Session-named reports are excluded, because the glob cannot tell a ticket
# number from four hex digits inside a UUID -- and the group it collides with is
# the version field, which on a v4 UUID always starts with `4`. So every ticket
# numbered 4xxx matches names like
# `box-session-d0955307-c0d6-4272-9900-1da6643d3fc0-...`, which is the whole
# current range. Found on 2026-11-06 delivering RULING-4272-6: #4272's lane is a
# mac lane with no inbox file at all, and six Nov-3 session reports claimed the
# match, so the stamp would have named a report from another ticket entirely and
# lanecheck would have gone on calling the lane unanswered.
#
# A session-named report carries no ticket number by design -- the name is the
# delegate session id -- so dropping the whole shape loses nothing. There are 157
# of them here and not one names a ticket.
#
# A ruling and a grant are excluded for the same reason by a different route:
# they name the ticket on purpose, so the glob matches them exactly, and they
# are not reports. On 2026-11-06 RULING-4272-7 stamped
# `surveyor-20261106-ruling-4272-6.md` -- a relay of my own earlier ruling --
# as the report it answered, while the lane's real report sat in
# run/fiber-4272-report.md. lanecheck compares the stamp against the report it
# read, so a stamp naming a ruling never matches and the ask stays open
# forever: the exact failure the stamp was added to end.
#
# And run/fiber-<n>-report.md is a third source, because that is where a Mac
# lane's report lands -- it has no inbox to send to. lanecheck has scanned all
# three since #4040 cost nine hours; this one scanned two, so a Mac lane's
# ruling could not stamp the file lanecheck had just pointed me at.
answered=$(ls -t "$R"/inbox/*-"$ticket"-*.md \
                 "$R"/inbox/read/*-"$ticket"-*.md \
                 "$R"/fiber-"$ticket"-report.md 2>/dev/null \
             | grep -v '/[a-z-]*session-[0-9a-f]\{8\}-' \
             | grep -v -e '-ruling-' -e '-grant-' | head -1)
if [ -n "$answered" ]; then
    printf '\n<!-- answers-report: %s -->\n' "$(basename "$answered")" >> "$dest"
    echo "answers: $(basename "$answered")"
    # And move it out of the unread pile, because nothing else ever did. By
    # 2026-11-06 run/inbox/ held 49 files, 26 of them long answered, so the
    # count meant nothing and the live asks were invisible inside it -- which
    # is how #4250 sat blocked for five hours with its report in plain sight.
    # The glob above already searches read/, so a moved report still stamps.
    #
    # Only an inbox file moves. run/fiber-<n>-report.md is the path a Mac lane
    # writes its report to and rewrites on its next report, so it is the lane's
    # file, not a message in my pile -- filing it would move a file out from
    # under its writer to clear a pile it was never in.
    case "$answered" in
      */inbox/read/*) : ;;
      */inbox/*) mkdir -p "$R/inbox/read" && mv "$answered" "$R/inbox/read/" \
           && echo "filed: $(basename "$answered") -> run/inbox/read/" ;;
      *) : ;;
    esac
else
    echo "answers: no report found for $ticket — lanecheck falls back to mtime" >&2
fi

# The roster's last line for this ticket is the live lane: a relaunch appends,
# never rewrites, so reading the last one and not the first is what keeps a
# ruling off a retired session.
lane=$(awk -F'\t' -v t="$ticket" '$2 == t { h = $3; s = $4; j = $5 } END { print h "\t" s "\t" j }' "$R/roster")
lanehost=$(printf '%s' "$lane" | cut -f1)
lanesess=$(printf '%s' "$lane" | cut -f2)
# Column 5 is the delegate session id, which is how a muse lane is woken (see
# the muse branch of the BLIND advice below). Lines written before that column
# existed leave it empty, so the advice checks before printing a command.
lanejid=$(printf '%s' "$lane" | cut -f3)

case "${INBOX_HOST:-$lanehost}" in
    mac)
        # `mac` names two kinds of lane: bglaunch.sh starts a Claude session,
        # maclaunch.sh a muse delegate session. Only the local delegate store
        # can tell them apart, and calling every mac lane a Claude session sent
        # #4272's and #4273's rulings to a SendMessage address that does not
        # exist (switchyard #1069). Ask the store before deciding.
        if [ -n "$lanejid" ] && "${FW_DELEGATE:-$HOME/.local/bin/delegate}" \
                session list 2>/dev/null | grep -q "^$lanejid "; then
            send=$("${FW_DELEGATE:-$HOME/.local/bin/delegate}" \
                session send "$lanejid" - <"$dest" 2>&1)
            sendrc=$?
            # Same contract as the muse branch below: the exit code decides, not
            # the disposition word, so `steered` is not read as a failure.
            if [ "$sendrc" -eq 0 ]; then
                echo "delivered into the turn: $lanesess ($lanejid) on this mac — ${send:-ok}"
                exit 0
            fi
            echo "SEND FAILED for #$ticket ($lanejid, exit $sendrc): $send" >&2
            echo "  a mac lane has no lane-inbox to fall back to. Deliver it by hand and say so." >&2
            exit 3
        fi
        echo "lane $ticket is a mac Claude session ($lanesess), which has no inbox file to deliver to." >&2
        echo "  send it yourself: SendMessage to '$lanesess' with the ruling's text." >&2
        echo "  the archive copy above is the durable record." >&2
        exit 3
        ;;
    ''|box|muse)
        host=roundhouse-7010-plus-1.local
        ;;
    *)
        host="${INBOX_HOST:-$lanehost}"
        ;;
esac

if [ -z "$lanehost" ]; then
    echo "no roster line for #$ticket — assuming the box. Check bin/lanecheck." >&2
fi

# Push the ticket's run/ files to the box before the ruling that tells the lane
# to read them. A grant, an admit or an extra written after boxlaunch.sh ran
# exists only on this Mac, and the lane's own checks read the box: fence-grant
# --require resolves run/ on the box (fence-grant:49, :263-272), so a granted
# fence and an ungranted one are indistinguishable there. On 2026-11-06 that
# cost #4250 two round-trips and ~25 minutes idle after RULING-7 granted its
# fence -- the same failure box-push.sh's own header records against #4201.
# Remembering to run it by hand is what failed twice, so the script runs it.
# Advisory: a push failure is not a reason to withhold the ruling, and
# box-push.sh exits 1 when a ticket simply has no run/ files yet.
if [ "${FW_NO_BOX_PUSH:-}" = "" ]; then
    push=$(bash "${FW_BOX_PUSH:-$script_dir/box-push.sh}" "$ticket" 2>&1)
    pushrc=$?
    if [ "$pushrc" -eq 0 ]; then
        echo "box-push: $(printf '%s' "$push" | tail -1)"
    else
        echo "box-push did not run clean for #$ticket (exit $pushrc): $push" >&2
        echo "  delivering the ruling anyway; check the lane can see any file it names." >&2
    fi
fi

# A muse lane is delivered to by `delegate session send`, not by scp into
# lane-inbox/. The file route below is read only if a watcher happens to be
# armed, which is why it ends in a BLIND verdict more often than a delivery;
# a send puts the ruling in the lane's own turn and returns a disposition that
# says so. Confirmed live on #4091 and again on #4089 (2026-11-04).
#
# This branch exists because its absence was emptying the archive. Delivering a
# muse lane's ruling by hand was strictly better than this script's scp, so the
# script got bypassed -- and with it the `cp` above, which is the only thing that
# populates run/rulings/. On 2026-11-04 #4089 had rulings=0 in the archive with
# four rulings actually delivered, so pending.sh's RULED column, whose whole job
# is telling a lane working on an answer from one still waiting, read `-` for
# every ticket I had answered. The fix is to make the tool's delivery as good as
# the hand route rather than to resolve to stop using the hand route.
#
# One route, not both: the lane brief has lanes act on an in-turn message and
# drain lane-inbox/ at turn start, so delivering twice makes a lane act on one
# ruling twice. The scp is the fallback for when the send fails.
if [ "$lanehost" = muse ] && [ -n "$lanejid" ]; then
    send=$(fw_box_ssh -o BatchMode=yes "$host" \
        "cat | TMPDIR=/srv/lanes/tmp ~/.local/bin/delegate session send $lanejid -" \
        <"$dest" 2>&1)
    sendrc=$?
    # Branch on the exit code, not on the disposition word. The first version of
    # this matched `started|queued` and called everything else a failure, which
    # on its second real use (#3899 and #4152, 2026-11-04) read `steered` -- the
    # BEST outcome, the message folded into the lane's running turn -- as a send
    # failure, and then scp'd as well. Both lanes got the same ruling twice.
    # The set of disposition words is delegate's to extend and not mine to
    # enumerate; the exit code is the part it actually contracts.
    if [ "$sendrc" -eq 0 ]; then
        echo "delivered into the turn: $lanesess ($lanejid) — ${send:-ok}"
        exit 0
    fi
    # A failed send is not a reason to leave the ruling undelivered: fall through
    # to the file route, which at least survives until the lane's next turn, and
    # say plainly that the better route failed.
    echo "SEND FAILED for #$ticket ($lanejid, exit $sendrc): $send" >&2
    echo "  falling back to the lane-inbox file route; its BLIND verdict below is the real one." >&2
fi

if fw_box_is_local; then
    box_inbox="$HOME/lane-inbox/$ticket"
    mkdir -p "$box_inbox/read"
    copied="$box_inbox/$base"
    if cp -p -- "$dest" "$copied"; then copy_ok=1; else copy_ok=0; fi
else
    if scp -q "$dest" "$host:lane-inbox/$ticket/$base"; then copy_ok=1; else copy_ok=0; fi
fi
if [ "$copy_ok" = 1 ]; then
    # A file in place is read only while the lane has an inbox-wait armed, and
    # lanes forget to re-arm: RULING-4086-7 sat unread for an hour behind a
    # "delivered". Ask inbox-watchers; an unknown answer counts as blind, since
    # a false all-clear is the failure being fixed.
    if fw_box_is_local; then
        watch=$("${FW_INBOX_WATCHERS:-$HOME/.agents/bin/inbox-watchers}" "$box_inbox" 2>/dev/null)
    else
        watch=$("${FW_INBOX_WATCHERS:-$HOME/.agents/bin/inbox-watchers}" --host "$host" "~/lane-inbox/$ticket" 2>/dev/null)
    fi
    watchrc=$?
    # Empty output only means "watched" when the check itself ran clean.
    [ "$watchrc" -ne 0 ] && [ -z "$watch" ] && watch="WATCH-ERROR inbox-watchers exit $watchrc"
    # An armed inbox-wait exits the moment it sees the file (it polls every
    # 2 s on the box), so by the time inbox-watchers runs, a lane that read the
    # ruling shows no watcher (switchyard, 2026-11-08: 4301, 4187, 4261 all
    # read theirs behind a BLIND). A lane that read it moved the file out of
    # the inbox, so the file gone within a few seconds is a delivery. Only a
    # clean "not there" (test exit 1) counts; an ssh failure stays blind.
    if [ -n "$watch" ]; then
        for _ in 1 2 3 4; do
            sleep 2
            fw_box_ssh -o BatchMode=yes "$host" "test -e ~/lane-inbox/$ticket/$base" 2>/dev/null
            if [ $? -eq 1 ]; then
                watch=''
                break
            fi
        done
    fi
    case "$watch" in
        '')
            echo "delivered: $host:lane-inbox/$ticket/$base"
            ;;
        *)
            echo "BLIND $ticket — the file is in place but NOTHING IS WATCHING $host:lane-inbox/$ticket/, so the lane has NOT read this ruling." >&2
            case "$watch" in
                *WATCH-ERROR*) echo "  watcher state is unknown ($watch); treated as blind." >&2 ;;
                *) echo "  $watch" >&2 ;;
            esac
            # No armed watcher has two causes that want opposite actions: a lane
            # mid-turn drains its inbox at turn start and re-arms at the end, so
            # it has no watcher while it works and will read this at its next
            # turn start; a lane that stopped without re-arming never will. The
            # drain age separates them cheaply, and the verdict stays BLIND
            # either way, because a false all-clear is the failure being fixed.
            #
            # A muse lane is not a Claude session, so it never appears in
            # `claude agents --json` and that probe called every one of them
            # unknown-so-stopped. Its state lives in `delegate session list`,
            # which also separates a case the Claude probe cannot see: `dead`
            # wants a relaunch, where `idle` wants a send.
            if [ "$lanehost" = muse ] && [ -n "$lanejid" ]; then
                sess_status=$(fw_box_ssh -o BatchMode=yes "$host" "delegate session list --json" 2>/dev/null | python3 -I -c 'import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for s in (data.get("sessions") or []) if isinstance(data, dict) else []:
    if isinstance(s, dict) and s.get("id") == sys.argv[1]:
        st = s.get("status", "")
        print("busy" if st == "running" else st)
        break' "$lanejid" 2>/dev/null)
            else
                claude_agents_ssh=${BOX_SSH:-${FW_SSH:-}}
                if [ -z "$claude_agents_ssh" ]; then
                    if [ "$(uname -s)" = Darwin ]; then
                        claude_agents_ssh=ssh
                    else
                        claude_agents_ssh=${FW_BOX_LOCAL:-$script_dir/box-local.sh}
                    fi
                fi
                if sess_json=$(bash "$script_dir/claude-agents-timeout" \
                    "${FW_CLAUDE_AGENTS_TIMEOUT:-30}" "$claude_agents_ssh" \
                    -o BatchMode=yes "$host" "claude agents --json" 2>/dev/null); then
                    sess_status=$(printf '%s\n' "$sess_json" | python3 -I -c 'import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    sys.exit(0)
for a in data:
    if isinstance(a, dict) and a.get("name") == sys.argv[1]:
        print(a.get("status", ""))
        break' "$lanesess" 2>/dev/null)
                else
                    sess_status=''
                fi
            fi
            case "$sess_status" in
                busy)
                    echo "  MID-TURN: $lanesess is busy, so it is working and drains its inbox at the start of its next turn. Wake it only if it must act before that turn ends." >&2 ;;
                idle)
                    echo "  STOPPED: $lanesess is idle with nothing armed, so this file sits unread until you wake it." >&2 ;;
                dead)
                    echo "  DEAD: delegate session $lanejid is dead, so no send reaches it. Relaunch the lane and fold this ruling into the brief; a send would fail silently." >&2 ;;
                *)
                    echo "  session status unknown ($lanesess not in \`claude agents --json\`): treat it as stopped and wake it." >&2 ;;
            esac
            # A muse lane holds no SendMessage tool and its session name is not a
            # reachable agent, so the advice that works there is the one that
            # wakes it: `delegate session send`, run on the box. Confirmed live
            # on #4091 (session 0be7d5ba, 2026-11-03): piping the ruling in
            # returned disposition "started" and the lane took a fresh turn with
            # its context intact.
            if [ "$sess_status" = busy ]; then
                : # a busy lane needs no wake route: it reads the file itself
            elif [ "$sess_status" = dead ]; then
                : # the DEAD line above already says what to do; a send is not it
            elif [ "$lanehost" = muse ] && [ -n "$lanejid" ]; then
                if fw_box_is_local; then
                    echo "  wake it: delegate session send $lanejid - --json < $dest" >&2
                else
                    echo "  wake it: ssh -o BatchMode=yes $host \"delegate session send $lanejid - --json\" < $dest" >&2
                fi
                echo "  (a muse lane has no SendMessage. Do not relaunch: that starts a second session on the ticket.)" >&2
            else
                echo "  deliver it by SendMessage to '$lanesess' with the ruling's text. The archive copy above stands." >&2
            fi
            exit 4
            ;;
    esac
else
    echo "DELIVERY FAILED to $host:lane-inbox/$ticket/ — the archive copy stands" >&2
    exit 1
fi

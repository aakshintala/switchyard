#!/bin/bash
# boxlaunch.sh <n> [model, default haiku] [phase-plan|phase-build|phase-ship]: start the lane for issue <n> on the Linux box.
# A phase needs a state-mode brief (mkbrief with TKT=1); the session is fiber-<n>-<phase>. BOX_SSH overrides ssh and RUN_DIR the Mac run dir (tests).
# Run bin/mkbrief.sh first. Box lanes report by inbox-send; the flywheel answers by SendMessage (works) or a fiber-<n>-fence-grant.md.
# the brief is rewritten so a lane reports through ~/flywheel-inbox and stops when it needs a path outside its fence.
set -euo pipefail
script_path=$0
while [ -L "$script_path" ]; do
  script_dir=$(cd "$(dirname "$script_path")" && pwd)
  link=$(readlink "$script_path")
  case "$link" in /*) script_path=$link;; *) script_path=$script_dir/$link;; esac
done
script_dir=$(cd "$(dirname "$script_path")" && pwd)
. "$script_dir/lib/fw-lib.sh"
n=$1; model=${2:-haiku}; ph=${3:-}
# A provider-prefixed id (muse/..., openai/..., grok-...) is a `delegate` model,
# not a Claude Code session model. `claude --bg --model <that>` backgrounds
# successfully and then the session prints "There's an issue with the selected
# model" and does nothing, so the launch looks clean and the lane never runs:
# #4201 and #4258 sat idle for hours on 2026-11-05 at 0 tokens each, launched
# with muse/muse-spark-1.3-contributor as the session model. The session model
# is the orchestrator's; the planner and lane models are what it passes to
# `delegate` through --model ROLE=ID.
case "$model" in
  */*) echo "boxlaunch: '$model' is a delegate model id, not a Claude Code session model." >&2
       echo "  Pass haiku, sonnet or opus here, and give the delegate model to the lane with --model ROLE=ID." >&2
       exit 2;;
esac
boxssh=${BOX_SSH:-}
if [ -z "$boxssh" ]; then
  if [ "$(uname -s)" = Darwin ]; then boxssh=ssh; else boxssh=$script_dir/box-local.sh; fi
fi
host=${FW_BOX_HOST:-roundhouse-7010-plus-1.local}
mac=${FW_MAC_HOME:-$HOME}
box=${FW_BOX_HOME:-/home/${USER:-aakshintala}}
if fw_box_is_local; then box=$HOME; fi
boxrun=${FW_BOX_RUN:-$box/work/fiber-worktrees/flywheel/run}
run=${FW_RUN:-${RUN_DIR:-$mac/work/fiber-worktrees/flywheel/run}}
sync_roster() {
  fw_box_is_local && return 0
  # No roster yet means no lane has launched, so there is nothing to map; the
  # sync after this launch's roster row creates it on the box.
  [ -f "$run/roster" ] || return 0
  # Write then rename, so a box probe never reads a half-written roster.
  if ! $boxssh -o BatchMode=yes "$host" "cat > $boxrun/roster.tmp && mv $boxrun/roster.tmp $boxrun/roster" < "$run/roster"; then
    echo "boxlaunch: cannot sync run roster to $host" >&2
    return 1
  fi
}
b=$run/fiber-$n-orchestrator-brief.md
[ -f "$b" ] || { echo "no brief $b" >&2; exit 2; }
# Refuse when the Box is at capacity. Claude and delegate lanes use LIVE lines
# with the host in column 3; PI-BOX pidfile lanes use ticket, PI-BOX, LIVE.
# PI-MAC lanes do not run on this Box and do not consume its slots.
cap=${FW_BOX_LANES:-12}
lc_out=$(FW_RUN="$run" bash "${FW_BOX_LANECHECK:-$script_dir/lanecheck}" 2>/dev/null || true)
live_box=$(printf '%s\n' "$lc_out" | awk '
  ($1 == "LIVE" && ($3 == "box" || $3 == "muse")) ||
  ($2 == "PI-BOX" && $3 == "LIVE") { n++ }
  END { print n + 0 }
')
if [ "$live_box" -ge "$cap" ]; then
  echo "boxlaunch: $live_box box lanes are live, cap is $cap. Refusing." >&2
  echo "  Retire a finished lane first (bash bin/lanecheck done <ticket>), or raise it with FW_BOX_LANES=<n>." >&2
  exit 2
fi
# Say out loud when the box's toolchain is behind this Mac's. A warning, not a
# refusal: stale tools cost a lane some rounds, refusing every box launch costs
# the whole round. `|| true` because an unreachable box is boxstale's exit 2 and
# the launch below reports ssh trouble better than this check can.
#
# Run it through `bash`, not as a direct exec. 2026-11-06: this line printed
# "bin/boxstale.sh: Permission denied" on #4255's launch because boxstale.sh is
# mode 644, so the one launch that most needed the stale-box warning (the box
# was ten hours behind) was the one that did not get it. `bash <path>` does not
# care about the execute bit, and it is what `bin/lanecheck`'s footer already
# does -- a mode bit is lost by a copy or a tarball, an invocation convention
# is not. Fixed at the convention, so both callers agree.
# Close the drift before reporting it. The Mac ships ~/.agents and the box only
# consumes it, so the box is behind by however long since someone last pulled
# and nothing there notices: on 2026-11-06 the gap reopened three times in six
# hours, each cycle costing a queue row or an owner ask (switchyard #1319).
# This never blocks a launch -- agents-ff.sh exits 0 on every failure after a
# WARN naming both shas -- and boxstale.sh above still reports the gap it could
# not close, with the commit list.
bash "${FW_AGENTS_FF:-$script_dir/agents-ff.sh}" || true
bash "${FW_BOXSTALE:-$script_dir/boxstale.sh}" || true
# switchyard #1554: reap on each box launch, without making a failed sweep a launch failure.
if [ "${FW_NO_TMP_REAP:-0}" != 1 ]; then
  (
    { $boxssh -o BatchMode=yes "$host" "${FW_BOX_TMP_REAP:-bash ~/.agents/bin/box-tmp-reap /srv/lanes/tmp /tmp}" 2>&1 || true; } |
      sed 's/^/boxlaunch: tmp reap: /' >&2
  ) </dev/null &
fi
# In a build launch, an earlier empty plan-phase grant is not a write fence.
# Refresh it only when the current plan supplies writes; an unchanged empty
# plan keeps its existing grant. FW_NO_FENCE remains an explicit override.
needs_grant=0
if ! fw_has_grant_file "$n" "$run"; then
  needs_grant=1
elif [ "$ph" = phase-build ] && ! fw_has_nonempty_grant "$n" "$run"; then
  needs_grant=1
fi
if [ "$needs_grant" -eq 1 ]; then
  if fw_self_grant boxlaunch "$n" "$run" 1; then
    :
  elif [ -n "${FW_NO_FENCE:-}" ]; then
    echo "boxlaunch: no fence grant for #$n, launching anyway: $FW_NO_FENCE" >&2
  else
    echo "boxlaunch: no $run/fiber-$n-fence-grant*.md -- self-grant from the posted plan failed." >&2
    echo "  Post a plan with its Files paths, or pass FW_NO_FENCE='<why this ticket holds no path>'." >&2
    exit 2
  fi
fi
# The selftest refusal guard is deliberately excluded from this moved slice.
sess_base=fiber-$n; phase_line=""
case "$ph" in
  "") ;;
  phase-plan|phase-build|phase-ship)
    grep -q '^- State file ' "$b" || { echo "$ph: $b is not a state-mode brief (no '- State file ' line); build it with TKT=1 mkbrief.sh" >&2; exit 2; }
    sess_base=fiber-$n-${ph#phase-}
    case "$ph" in
      phase-plan) phase_line="PHASE: plan. Read tkt-state and the journal if they exist. Run tkt-start (which sets \`gate.script\` to \`scripts/check\` when the worktree has an executable \`scripts/check\`), then the planner (brief per Settings), then tkt-plan verify/confirm/post. That one state key is what makes tkt-plan set and post refuse a hand-expanded Gate line, through plan-gate --script (~/.agents f016d79); without it the check is inert and a bad Gate line is only the Verifier's to catch. It accepts \`scripts/check --base <sha>\`, a leading allowlisted env assignment and a \`bash \` prefix, so the line the planning skill asks for passes as written. End with the last tkt-plan verdict line and STATUS: PLANNED, or STATUS: BLOCKED with the question.";;
      phase-build) phase_line="PHASE: build. Read tkt-state and the journal first. Run tkt-build, then tkt-fix rounds until the review loop is done. End with the last verdict line, the pushed head, and STATUS: REVIEWED, or STATUS: BLOCKED.";;
      phase-ship) phase_line="PHASE: ship. Read tkt-state and the journal first. Run tkt-ship; on a red CI run follow its digest, with fix rounds through tkt-fix. End with the merge SHA, or STATUS: BLOCKED with the failing job.";;
    esac;;
  *) echo "unknown phase $ph (phase-plan|phase-build|phase-ship)" >&2; exit 2;;
esac
launch_id=$(python3 -c 'import uuid; print(uuid.uuid4().hex[:8])')
sess=$sess_base-$launch_id
tmp=$(mktemp)
trap 'rm -f "$tmp" "${tmp}.agents.json"' EXIT
disk_line=""
# Where a lane worktree lives, and whether to cut one, used to ride on NEWDISK
# together — and its probe tested the wrong disk. Leaving a fresh lane on /home
# put 332 GiB of lane target/ dirs on the 466 GiB root (89% full, owner noticed
# 2026-11-03) while the 1.9 TiB NVMe held under a gigabyte, so every lane now
# goes to /srv/lanes and the path rewrite below (`disk_rw`) is unconditional.
# The probe that remains decides cut-vs-resume only, and it has to ask about the
# rewritten path: asking /home, where no current lane lives, told every resuming
# lane it was fresh and defeated the guard that exists because a resuming
# branch may carry commits `git worktree add -b` from origin/main would strand
# (switchyard #1110). flywheel/run stays on /home either way. An explicit
# NEWDISK= still wins, and still means "cut fresh".
disk_rw="s|$box/work/fiber-worktrees/flywheel/|@@FWRUN@@|g; s|$box/work/fiber-worktrees/|/srv/lanes/fiber-worktrees/|g; s|@@FWRUN@@|$box/work/fiber-worktrees/flywheel/|g"
if [ -z "${NEWDISK:-}" ]; then
  wt=$(grep -m1 '^- Worktree `' "$b" | sed 's/^- Worktree `//; s/`.*$//; s|'"$mac"'|'"$box"'|')
  wtd=$(printf '%s' "$wt" | sed "$disk_rw")
  found=""
  # The remote ends `exit 0` so "neither directory exists" is an empty answer,
  # not a failure: without it `set -e` killed the launcher silently on exactly
  # the fresh-lane case this probe exists to detect. A nonzero exit now means
  # ssh itself failed, and then the answer is unknown, so refuse rather than
  # guess NEWDISK=1 and cut a worktree over a resuming branch.
  if [ -n "$wt" ]; then
    found=$($boxssh -o BatchMode=yes "$host" "test -d $wtd && echo srv; test -d $wt && echo home; exit 0" 2>/dev/null) ||
      { echo "boxlaunch: cannot reach $host to probe for an existing worktree. Fix ssh, or pass NEWDISK=0/1 explicitly." >&2; exit 2; }
  fi
  case "$found" in
    *srv*) NEWDISK=0; echo "boxlaunch: NEWDISK=0 (resuming existing worktree $wtd)" >&2 ;;
    # A worktree on /home and none on the NVMe is the one case that must not
    # launch: the brief points at the NVMe either way now, so the lane would cut
    # a fresh branch there and strand whatever is committed on /home.
    *home*) echo "boxlaunch: REFUSING — worktree exists at $wt but not at $wtd, and the brief points at $wtd. Move it there, or remove it once its branch has nothing unmerged." >&2; exit 2 ;;
    *) NEWDISK=1; echo "boxlaunch: NEWDISK=1 (no worktree at ${wtd:-unknown}; cutting it there)" >&2 ;;
  esac
fi
[ "${NEWDISK:-0}" = 1 ] && disk_line=" The Worktree path above is on /srv/lanes, the same NVMe: cut it there and nowhere else. Gate, once, right after you create it: df on its target/ parent and on \$TMPDIR must both print /srv/lanes; if either prints /home, stop and report BLOCKED."
xf="s|$mac|$box|g; $disk_rw"
# A PLAN ONLY stanza comes from the notes and belongs to the plan phase. Carried
# into a build or ship launch it contradicts the PHASE line appended below ("do
# not build, do not open a PR" against "PHASE: build") and the lane has to guess
# which wins; #3890 reported exactly that (2026-11-03). bglaunch.sh:35 already
# drops the line on a resume, so this is the same rule at the phase launchers.
strip='^REPORT TO PARENT:\|^CHECK-INS:\|^LAST STEP, every time\|^PHASE:'
case "$ph" in phase-build|phase-ship) strip="$strip\\|^PLAN ONLY";; esac
sed '/^BOX LANE: you run on the Linux box/,$d' "$b" | sed "$xf" | grep -v "$strip" > "$tmp"
cat >> "$tmp" <<EOT
BOX LANE: you run on the Linux box, not the Mac. There is no flywheel session you can reach: ignore every instruction above to SendMessage flywheel. Your report (the shape above) goes to the Mac with: \`printf '%s\n' "<report>" | bash ~/.agents/bin/inbox-send ~/flywheel-inbox box-$n\`, then end your turn. Do this for the final report and for a blocking question. Stay inside the notes' fence; if the ticket needs a path outside it, stop and report BLOCKED with the file and hunk range. The flywheel may answer with a SendMessage or a run/fiber-$n-fence-grant.md in this directory: both are real grants. Do not write a handoff for a flywheel resume; the report is the handoff. Repo is $box/work/fiber. DISK: TMPDIR is /srv/lanes/tmp in your environment, a 1.8T NVMe. Keep it, and pass it to every delegate job and scripts/check run; never set it back to /tmp.$disk_line Use cargo with CARGO_BUILD_JOBS=3.
INBOX: the flywheel can reach you while you are idle through \`$box/lane-inbox/$n\`. Right after you start, run \`bash ~/.agents/bin/inbox-wait ~/lane-inbox/$n; true\` with run_in_background (never a trailing \`&\`). When it completes, read every file in ~/lane-inbox/$n (not read/), move each to ~/lane-inbox/$n/read/, act on it as a flywheel message, and re-arm exactly one watcher. Before your final report, nothing else is needed.
ESCALATION: before you stop to ask, look for a line that settles the question — in the plan, the ticket, the notes, this brief, docs/workflow.md or the docs those name — read at your own head, not at origin/main. If one exists, quote it with path and line and carry on. Four calls are yours, and asking about one is itself the error. (a) A fence that widens inside the ticket's own area -- a path in a crate a task already names, or the test file beside the source you are changing: add it to the plan's Files and say so. (b) A plan item outside the ticket's verbatim Scope line, where the ticket's done condition does not need it: quote the line, search the open tickets, comment on a match or open the follow-up yourself, and link it in the report; where dropping the item would change what done means, that is an escalation instead. (c) A file an ordinary ticket's lane claims: that claim is advisory, not a dispatch veto, so read the claimant's PR diff, or its posted plan where it has no PR, then edit; whichever PR merges second rebases. A scripted sweep's claim stays exclusive, because a sweep edits mechanically across many files and a hand edit inside its range corrupts the result: build the rest and edit that file after the sweep merges. The REFUSE line tells you which you face -- a sweep lane's id begins sweep-, an ordinary ticket's fiber-, and no sweep runs under a fiber- id. file-claim has not caught up with the advisory half (switchyard#1258 is open), so it will refuse you there too: a REFUSE naming lane:fiber-<n> or a pr is expected and not a blocker, and because claims are all-or-nothing you drop that path, rerun to claim the rest, then edit the refused path anyway and say in your report that you edited it unclaimed and who holds it; a REFUSE naming lane:sweep-<n> is a stop for that path, so drop it, build the rest, and report the path you left alone; a REFUSE naming the cap IS a stop, because the cap is a slot question and slots are the flywheel's. (d) A second or later Verifier or review round -- the first round on a needs-plan ticket always runs: name the outcome of the next round that is not posting the plan, and where you cannot name one, skip it and post. Stop to ask only for: a gap no line covers, or two lines that conflict; a fence that crosses into a crate no task names; gate semantics; a plan that contradicts a ruling, an ADR or a wiki page; the Round limit in the planning skill reached without a plan you would dispatch -- read the limit there, never from a restated count -- which you report as split-it-or-rule-it and never as a question; or a refusal this brief gives no route for, with its text quoted. Gate semantics are surveyor's, not the flywheel's: post that question as a comment on the ticket addressed to surveyor, and to reach the surveyor directly write a file into /srv/lanes/fiber-worktrees/surveyor/run/inbox/ (the only surveyor inbox; never ~/surveyor-inbox), say in your report that you did, and keep working on everything it does not block. A report that stops to ask is at most 15 lines: model, head SHA, the blocker with the line it falls under, one question, STATUS. Longer evidence goes in a named file under $box/work/fiber-worktrees/flywheel/run/ and the report names it.
EOT
[ -z "$phase_line" ] || printf '%s\n' "$phase_line" >> "$tmp"
$boxssh -o BatchMode=yes "$host" "mkdir -p $boxrun $box/flywheel-inbox $box/lane-inbox/$n/read /srv/lanes/fiber-worktrees /srv/lanes/tmp && git -C $box/work/fiber fetch -q origin"
# Box delegate-session probes need this map before the new process can ask for
# a fence grant. Refresh it at launch; box-push.sh also refreshes it after
# later run-state changes.
sync_roster || exit 2
# `set -f` is still in force from the fence guard above, so the two globs in
# this list expand to nothing without `set +f` and `[ -f ]` skips them. That is
# how the fence grants went unsent until 2026-11-06: `fiber-<n>-fence-grant*.md`
# was in this list and never matched, grants were written on the Mac, and
# `fence-grant --require` reads the box run dir, so every box lane was going to
# fail at build with a missing grant. #4249 got there first.
set +f
for f in "$run/report-format.md" "$run/fiber-$n-notes.md" "$run/fiber-$n-"*-notes.md "$run/fiber-$n-extra.md" "$run/fiber-$n-spec.md" "$run/fiber-$n-fence-grant"*.md; do
  [ -f "$f" ] || continue
  dest=$boxrun/$(basename "$f")
  if [ -f "$dest" ] && [ "$f" -ef "$dest" ]; then continue; fi
  sed "s|$mac|$box|g" "$f" | $boxssh "$host" "cat > $dest"
done
set -f
$boxssh "$host" "cat > $boxrun/fiber-$n-orchestrator-brief.md" < "$tmp"
# A relaunch must not leave an old Remote Control session under this phase's
# name. Include both the legacy exact name and names made by this launcher.
if prior_agents=$($boxssh -o BatchMode=yes "$host" "claude agents --json" 2>&1); then
  printf '%s\n' "$prior_agents" >"${tmp}.agents.json"
else
  echo "boxlaunch: cannot list existing sessions on $host; refusing to launch." >&2
  printf '%s\n' "$prior_agents" | sed 's/^/  /' >&2
  exit 2
fi
if prior_sessions=$(python3 - "${tmp}.agents.json" "$sess_base" <<'PY'
import json, re, sys
path, base = sys.argv[1:]
try:
    data = json.load(open(path))
except Exception as exc:
    print(f"cannot parse claude agents --json: {exc}", file=sys.stderr)
    raise SystemExit(1)
rows = data if isinstance(data, list) else data.get("agents") or data.get("sessions") or []
pattern = re.compile(re.escape(base) + r"(?:-[0-9a-f]{8})?")
for row in rows:
    if not isinstance(row, dict) or not pattern.fullmatch(str(row.get("name") or "")):
        continue
    session_id = row.get("id") or row.get("sessionId") or ""
    status = row.get("status") or ""
    print(f"{session_id}\t{row['name']}\t{status}")
PY
); then
  :
else
  echo "boxlaunch: cannot interpret existing sessions on $host; refusing to launch." >&2
  exit 2
fi
old_ids=()
old_names=()
while IFS=$'\t' read -r old_id old_name old_status; do
  [ -n "$old_name" ] || continue
  case "$old_id" in
    ''|*[!A-Za-z0-9_-]*)
      echo "boxlaunch: REFUSING — existing session '$old_name' has no safe stop id." >&2
      exit 2;;
  esac
  if [ "$old_status" = busy ]; then
    echo "boxlaunch: REFUSING — existing session '$old_name' is mid-turn (id $old_id)." >&2
    exit 2
  fi
  [ -n "$old_status" ] || {
    echo "boxlaunch: REFUSING — existing session '$old_name' has no status to check (id $old_id)." >&2
    exit 2
  }
  old_ids+=("$old_id")
  old_names+=("$old_name")
done <<<"$prior_sessions"
for i in "${!old_ids[@]}"; do
  if ! $boxssh -o BatchMode=yes "$host" "claude stop ${old_ids[$i]}"; then
    echo "boxlaunch: could not stop old session ${old_ids[$i]} (${old_names[$i]}); refusing to launch." >&2
    exit 2
  fi
  echo "boxlaunch: stopped old session ${old_ids[$i]} (${old_names[$i]})" >&2
done
# Capture the launch, then filter it, in two steps. The one-liner this replaces
# ended its pipeline in `grep -o 'backgrounded.*'`, and a launch that prints no
# such line — a quota refusal, a model the harness rejects, an ssh error — made
# grep exit 1, which under `pipefail` and `set -e` killed the script at the
# assignment. With stderr already merged into the substitution, that failed in
# total silence: no report, no roster line, and the brief sitting on the box.
# (The same defect bit muselaunch.sh on its first real run, #4097.)
rc=0
raw=$($boxssh -o BatchMode=yes "$host" "cd $box/work && CARGO_BUILD_JOBS=3 TMPDIR=/srv/lanes/tmp GH_CI_REPO=aakshintala/fiber claude --bg -n $sess --model $model --agent ticket-orchestrator --permission-mode auto 'Read $boxrun/fiber-$n-orchestrator-brief.md and follow it.'" 2>&1) || rc=$?
launchout=$(printf '%s\n' "$raw" | grep -o 'backgrounded.*' | sed 's/\x1b\[[0-9;]*m//g') || true
jid=$(printf '%s' "$launchout" | awk '{print $3}')
if [ -z "$jid" ]; then
  echo "launch failed for #$n (claude exit $rc): no backgrounded session id in the output" >&2
  printf '%s\n' "$raw" | sed 's/^/  /' >&2
  echo "  the brief is already on the box, so relaunch the same command once the cause is clear." >&2
  echo "  check for a half-started session before relaunching: ssh $host claude list" >&2
  exit 1
fi
printf '%s\n' "$launchout"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$n" box "$sess" "$jid" >> "$run/roster"
# Once the next phase has a confirmed launch, retire the latest roster entry
# from the phase it replaces. lanecheck done needs the exact session name; phase
# launches include a unique suffix, so pass the name recorded in the roster.
previous_phase=""
case "$ph" in
  phase-build) previous_phase=plan;;
  phase-ship) previous_phase=build;;
esac
if [ -n "$previous_phase" ]; then
  previous_base=fiber-$n-$previous_phase
  previous_sess=$(awk -F'\t' -v ticket="$n" -v base="$previous_base" \
    '$2 == ticket && ($4 == base || index($4, base "-") == 1) { sess=$4 }
     END { print sess }' "$run/roster")
  if [ -n "$previous_sess" ]; then
    lanecheck=${FW_BOX_LANECHECK:-$script_dir/lanecheck}
    # The successful handoff confirms this phase is finished, even if its row
    # is young; lanecheck still refuses to stop a session with active work.
    if ! FW_RUN="$run" FW_DONE_FORCE=1 bash "$lanecheck" done "$n:$previous_sess"; then
      echo "boxlaunch: WARNING could not retire $previous_sess; manually run: FW_DONE_FORCE=1 FW_RUN='$run' bash '$lanecheck' done '$n:$previous_sess'" >&2
    fi
  fi
fi
# The lane is already running, so a failed sync must not read as a failed
# launch (a caller would relaunch). Name it and the command that repairs it.
sync_roster || echo "boxlaunch: WARNING roster not synced to $host; box fence-grant exits 3 until bash bin/box-push.sh $n succeeds" >&2

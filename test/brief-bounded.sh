#!/usr/bin/env bash
# Keep filled state-mode and pi lane briefs inside the deliberate bloat budget.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MKBRIEF="$ROOT/bin/mkbrief.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

fail_over_budget() {
  label="$1"
  value="$2"
  limit="$3"
  fail "tkt-brief-bounded: $label $value > $limit"
}

# The tkt ceiling and rebasing policy come from flywheel's
# tkt-brief-bounded budget in ~/work/fiber-worktrees/flywheel/bin/test-launch.sh:
# measured 2026-11-06 at 117 lines / 32994 bytes, allowing ~5% growth so a
# paragraph fits but a new section does not. Rebase only deliberately, with a
# new measurement written into that source comment. Tkt's 33280 B / 125-line
# ceilings are hard. Pi's original 1 KiB below the tkt byte ceiling was
# switchyard's choice, not flywheel's measurement.
# Real pi briefs include notes and EXTRA; fiber #4618's brief was 36313 B. This
# fixture bounds the filled template, not the full brief lanes read.
# Pi headroom is 256 B, not #1575's 1 KiB, by flywheel's peer-read ruling
# (https://github.com/aakshintala/switchyard/pull/1583#issuecomment-6786694697):
# "#1575's "no rule dropped" outranks its 1 KiB headroom. If restoring the
# rules leaves less than 1 KiB, find the bytes elsewhere without dropping a
# rule, or ship with whatever headroom is left and say so in the PR body."
# With every rule restored, the pi template left 256 B before #1731.
# Switchyard #1731 tightened wording (no rule dropped) to leave about 1 KiB under this cap.
BRIEF_MAX_BYTES=33280
BRIEF_MAX_LINES=125
PI_HEADROOM_BYTES=256
PI_MAX_BYTES=$((BRIEF_MAX_BYTES - PI_HEADROOM_BYTES))

within_budget() {
  [ "$1" -le "$2" ]
}

# Exercise the inclusive boundary and its immediate neighbors so reversing or
# changing the shared comparison cannot make the real brief checks vacuous.
for budget in "$BRIEF_MAX_LINES" "$BRIEF_MAX_BYTES"; do
  within_budget "$((budget - 1))" "$budget" || fail "budget comparison rejects just below $budget"
  within_budget "$budget" "$budget" || fail "budget comparison rejects the inclusive edge $budget"
  if within_budget "$((budget + 1))" "$budget"; then fail "budget comparison accepts just above $budget"; fi
done

# Fixed /tmp root, not the caller's TMPDIR: the filled brief embeds these
# paths, so a longer TMPDIR (test/run's) would change the measured bytes.
TMP_ROOT="$(mktemp -d /tmp/brief-bounded.XXXXXX)" || fail "create temporary directory"
# Both fills use the same lengths as flywheel's launch selftest inputs (#1852):
# its run dir is /tmp/<9 chars>.XXXXXX/runt, its HOME is 18 chars, and its
# worktree root is HOME/work/fiber-worktrees, the path the templates name.
# A tmp worktree root made mkbrief drop the worktree line's suffix, so the tkt
# fill measured 73 B under the launch fill (and pi 108 B, #1857) and template
# PRs passed here but broke launches.
TKT_ROOT="$(mktemp -d /tmp/brief-tkt.XXXXXX)" || fail "create temporary directory"
trap 'rm -rf "$TMP_ROOT" "$TKT_ROOT"' EXIT
mkdir -p "$TMP_ROOT/tmp" "$TKT_ROOT/runt" "$TKT_ROOT/runp" || fail "create test directories"
TMPDIR="$TMP_ROOT/tmp"
export TMPDIR
# An 18-char HOME, matching the launch host; it need not exist.
LAUNCH_HOME=/tmp/launch-home18
[ "${#LAUNCH_HOME}" -eq 18 ] || fail "LAUNCH_HOME is 18 chars"

# Match flywheel's measured mkbrief fixture: real issue/branch lengths, parent,
# closing line and notes; mkbrief itself performs the actual template filling.
ISSUE=99001
BRANCH=bin/99001-x
printf 'Notes line one.\nResolves #%s\n' "$ISSUE" >"$TMP_ROOT/notes.md"

build_brief() {
  kind="$1"
  template="$ROOT/bin/lib/template-$kind.md"
  # Both fills take the launch inputs. mkbrief names both briefs alike, so pi
  # gets its own run dir, the same length as runt.
  if [ "$kind" = pi ]; then
    pi=1 run_dir="$TKT_ROOT/runp"
  else
    pi=0 run_dir="$TKT_ROOT/runt"
  fi
  mkdir -p "$run_dir" || fail "create $kind run directory"
  # Pinned inputs, so a fill at one commit measures the same bytes on any host
  # (#1928): RUN_DIR, HOME and the worktree root (embedded paths, fixed
  # lengths); FW_PARENT, CLOSING, ISSUE, BRANCH, TAG and notes.md (embedded
  # text; mkbrief reads CLOSING from the caller otherwise). The pool line is
  # the checked-in pool.md. FW_REPO, TPL_DIR and POOL_FILE are checkout paths
  # used only to read files; none is written into the brief.
  # PR CI measures refs/pull/<n>/merge, the PR merged into main's tip, not the
  # head: on #1916, head aac3e578 filled 33262 B here and CI's merge 6f75899
  # filled 33308 B. Merge origin/main before measuring a near-ceiling change.
  HOME="$LAUNCH_HOME" CLOSING="Resolves #$ISSUE" FW_PARENT='flywheel [test00]' FW_RUN='' FW_REPO="$ROOT" \
    FW_WORKTREE_ROOT="$LAUNCH_HOME/work/fiber-worktrees" FW_LIB='' POOL_FILE="$ROOT/bin/lib/pool.md" \
    TPL_DIR="$ROOT/bin" RUN_DIR="$run_dir" TAG="$ISSUE" SKIP_PATHS=1 \
    TKT=1 PI="$pi" bash "$MKBRIEF" "$ISSUE" "$BRANCH" "$TMP_ROOT/notes.md" \
      >/dev/null 2>"$TMP_ROOT/$kind.err" || fail "mkbrief fills template-$kind.md: $(cat "$TMP_ROOT/$kind.err")"
  [ -r "$template" ] || fail "template-$kind.md exists"
  printf '%s\n' "$run_dir/fiber-$ISSUE-orchestrator-brief.md"
}

check_filled_budget() {
  kind="$1"
  brief="$2"
  lines="$(wc -l <"$brief" | tr -d '[:space:]')"
  bytes="$(wc -c <"$brief" | tr -d '[:space:]')"
  if ! within_budget "$lines" "$BRIEF_MAX_LINES"; then
    fail_over_budget "filled template-$kind.md" "$lines lines" "$BRIEF_MAX_LINES lines (brief-bloat budget from flywheel test-launch.sh tkt-brief-bounded, 2026-11-06; trim the brief)"
  fi
  if ! within_budget "$bytes" "$BRIEF_MAX_BYTES"; then
    fail_over_budget "filled template-$kind.md" "$bytes B" "$BRIEF_MAX_BYTES B (brief-bloat budget from flywheel test-launch.sh tkt-brief-bounded, 2026-11-06; trim the brief)"
  fi
  printf 'tkt-brief-bounded: template-%s.md %s/%s lines, %s/%s B\n' \
    "$kind" "$lines" "$BRIEF_MAX_LINES" "$bytes" "$BRIEF_MAX_BYTES"
}

pi_template="$ROOT/bin/lib/template-pi.md"
pi_raw_bytes="$(wc -c <"$pi_template" | tr -d '[:space:]')"

brief_tkt="$(build_brief tkt)"
brief_pi="$(build_brief pi)"
for kind in tkt pi; do
  eval "brief=\$brief_$kind"
  grep -qF -e "- Worktree \`$LAUNCH_HOME/work/fiber-worktrees/$BRANCH\` on branch \`$BRANCH\`, cut from origin/main. If it exists" "$brief" ||
    fail "$kind fill carries the worktree line's suffix, as the launch fill does"
done
check_filled_budget tkt "$brief_tkt"
check_filled_budget pi "$brief_pi"
if ! within_budget "$pi_raw_bytes" "$PI_MAX_BYTES"; then
  fail_over_budget "raw template-pi.md" "$pi_raw_bytes B" "$PI_MAX_BYTES B (requires $PI_HEADROOM_BYTES B headroom below the flywheel brief-bloat budget)"
fi
pi_filled_bytes="$(wc -c <"$brief_pi" | tr -d '[:space:]')"
if ! within_budget "$pi_filled_bytes" "$PI_MAX_BYTES"; then
  fail_over_budget "filled template-pi.md" "$pi_filled_bytes B" "$PI_MAX_BYTES B (requires $PI_HEADROOM_BYTES B headroom below the flywheel brief-bloat budget)"
fi

echo "tkt-brief-bounded: raw template-pi.md $pi_raw_bytes/$PI_MAX_BYTES B; filled template-pi.md $pi_filled_bytes/$PI_MAX_BYTES B"

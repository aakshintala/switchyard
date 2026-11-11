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

# The absolute budgets and rebasing policy come from flywheel's
# tkt-brief-bounded budget in /Users/aakshintala/work/fiber-worktrees/flywheel/bin/test-launch.sh:
# measured 2026-11-06 at 117 lines / 32994 bytes, allowing ~5% growth so a
# paragraph fits but a new section does not. Rebase only deliberately, with a
# new measurement written into that source comment.
BRIEF_MAX_BYTES=33280
BRIEF_MAX_LINES=125
PI_HEADROOM_BYTES=1024
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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/brief-bounded.XXXXXX")" || fail "create temporary directory"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/tmp" "$TMP_ROOT/worktrees" "$TMP_ROOT/run-tkt" "$TMP_ROOT/run-pi" || fail "create test directories"
TMPDIR="$TMP_ROOT/tmp"
export TMPDIR

# Match flywheel's measured mkbrief fixture: real issue/branch lengths, parent,
# closing line and notes; mkbrief itself performs the actual template filling.
ISSUE=99001
BRANCH=bin/99001-x
printf 'Notes line one.\nResolves #%s\n' "$ISSUE" >"$TMP_ROOT/notes.md"

build_brief() {
  kind="$1"
  run_dir="$TMP_ROOT/run-$kind"
  template="$ROOT/bin/lib/template-$kind.md"
  mkdir -p "$run_dir" || fail "create $kind run directory"
  if [ "$kind" = pi ]; then pi=1; else pi=0; fi
  FW_PARENT='flywheel [test00]' FW_RUN= FW_REPO="$ROOT" \
    FW_WORKTREE_ROOT="$TMP_ROOT/worktrees" FW_LIB= POOL_FILE="$ROOT/bin/lib/pool.md" \
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

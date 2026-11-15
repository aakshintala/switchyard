#!/usr/bin/env bash
# Direct behavior tests for bin/lib/tkt-stray-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STRAY_RUN_SCRIPT="${TKT_STRAY_RUN_SCRIPT:-$SCRIPT_DIR/../bin/lib/tkt-stray-run.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-tkt-stray-run.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

setup_case() {
  local name="$1"
  CASE="$T/$name"
  REPO="$CASE/repo"
  STATE_DIR="$CASE/state"
  STATE="$STATE_DIR/fiber-1912.state"
  JOURNAL="${STATE%.state}.journal"
  CASE_TMP="$(mktemp -d "$T/tmp-$name.XXXXXX")"
  mkdir -p "$REPO" "$STATE_DIR"
  git -C "$REPO" init -q || fail "$name: initialize fixture repository"
  printf 'ticket=1912\n' >"$STATE"
}

run_stray() {
  (cd "$REPO" && DELEGATE_JOB_ID=fixture-1 TMPDIR="$CASE_TMP" "$STRAY_RUN_SCRIPT" "$STATE" "$1")
}

run_tracked_case() {
  setup_case tracked
  mkdir -p "$REPO/run"
  printf 'tracked content\n' >"$REPO/run/tracked.txt"
  printf 'scratch content\n' >"$REPO/run/scratch.log"
  git -C "$REPO" add run/tracked.txt || fail 'tracked: stage fixture file'
  run_stray "$STATE_DIR/run" || fail 'tracked: script should leave tracked run alone'
  [ -f "$REPO/run/tracked.txt" ] || fail 'tracked: tracked file was removed'
  [ -f "$REPO/run/scratch.log" ] || fail 'tracked: scratch file moved'
  [ -z "$(find "$STATE_DIR/run" -name 'stray-*' -print -quit 2>/dev/null)" ] || fail 'tracked: scratch file moved'
  [ ! -e "$JOURNAL" ] || [ ! -s "$JOURNAL" ] || fail 'tracked: wrote a journal line'
  echo 'PASS: tracked run is left untouched'
}

run_collision_case() {
  setup_case collision
  mkdir -p "$REPO/run" "$STATE_DIR/run"
  printf 'scratch content\n' >"$REPO/run/fiber-77-one.log"
  printf 'keep existing\n' >"$STATE_DIR/run/stray-fixture-1-fiber-77-one.log"
  run_stray "$STATE_DIR/run" || fail 'collision: script failed to move scratch file'
  [ ! -e "$REPO/run/fiber-77-one.log" ] || fail 'collision: source file remains'
  grep -qx 'keep existing' "$STATE_DIR/run/stray-fixture-1-fiber-77-one.log" || fail 'collision: existing destination was overwritten'
  grep -qx 'scratch content' "$STATE_DIR/run/stray-fixture-1-fiber-77-one.log" 2>/dev/null && fail 'collision: scratch content replaced the existing file'
  grep -qx 'scratch content' "$STATE_DIR/run/stray-fixture-1-1-fiber-77-one.log" || fail 'collision: suffix destination missing'
  grep -Fq "tkt-build stray-run moved path=run/fiber-77-one.log destination=$STATE_DIR/run/stray-fixture-1-1-fiber-77-one.log" "$JOURNAL" || fail 'collision: move not journaled at suffix destination'
  echo 'PASS: destination collision gets a suffix without overwrite'
}

run_symlink_case() {
  setup_case symlink
  target="$CASE/target-run"
  mkdir -p "$target"
  printf 'symlink target content\n' >"$target/fiber-77-one.log"
  ln -s "$target" "$REPO/run"
  run_stray "$STATE_DIR/run" || fail 'symlink: script should ignore a symlinked root run'
  [ -L "$REPO/run" ] || fail 'symlink: root run link was replaced'
  [ -f "$target/fiber-77-one.log" ] || fail 'symlink: symlink target file moved'
  grep -qx 'symlink target content' "$target/fiber-77-one.log" || fail 'symlink: target file changed'
  [ ! -e "$STATE_DIR/run" ] || fail 'symlink: state run directory was created'
  [ ! -e "$STATE_DIR/run/stray-fixture-1-fiber-77-one.log" ] || fail 'symlink: destination was created'
  [ ! -e "$JOURNAL" ] || [ ! -s "$JOURNAL" ] || fail 'symlink: wrote a journal line'
  echo 'PASS: symlinked root run remains untouched without a move or journal'
}

run_nested_case() {
  setup_case nested
  mkdir -p "$REPO/run"
  printf 'source content\n' >"$REPO/run/fiber-77-one.log"
  run_dir="$REPO/run/state-run"
  if run_stray "$run_dir"; then
    fail 'nested: script did not refuse a state run directory inside source run'
  fi
  [ -f "$STATE" ] || fail 'nested: state file was deleted'
  grep -qx 'ticket=1912' "$STATE" || fail 'nested: state file changed'
  [ -f "$REPO/run/fiber-77-one.log" ] || fail 'nested: source file was moved or deleted'
  grep -qx 'source content' "$REPO/run/fiber-77-one.log" || fail 'nested: source file changed'
  [ -z "$(find "$REPO/run" -type f ! -path "$REPO/run/fiber-77-one.log" -print -quit)" ] || fail 'nested: a file was moved into state run'
  [ ! -e "$JOURNAL" ] || [ ! -s "$JOURNAL" ] || fail 'nested: wrote a journal line'
  echo 'PASS: nested state run is refused without moving or deleting files'
}

only="${1:-all}"
case "$only" in
  all|tracked|collision|symlink|nested) ;;
  *) fail 'usage: tkt-stray-run.sh [tracked|collision|symlink|nested]' ;;
esac

case "$only" in all|tracked) run_tracked_case ;; esac
case "$only" in all|collision) run_collision_case ;; esac
case "$only" in all|symlink) run_symlink_case ;; esac
case "$only" in all|nested) run_nested_case ;; esac

echo 'tkt-stray-run: all selected cases passed'

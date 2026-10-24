#!/usr/bin/env bash
# Tests for bin/job-record: print the winning <id>.json path across the three
# directories of the lookup order in docs/delegate-jobs.md:7-13
# (DELEGATE_JOBS_DIR, $TMPDIR/delegate-jobs, the system dir). Fixtures live
# under a temp dir; the real /tmp/delegate-jobs is never read or written.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REC="$SCRIPT_DIR/../bin/job-record"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

BASE="${TMPDIR:-/tmp}"
while [ "$BASE" != "/" ] && [ "${BASE%/}" != "$BASE" ]; do
  BASE="${BASE%/}"
done
T="$(mktemp -d "$BASE/test-job-record.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/override" "$T/tmp/delegate-jobs" "$T/sys" "$T/cwd" "$T/cwd/rel/dir"
export TMPDIR="$T/tmp"
export JOB_RECORD_SYSTEM_DIR="$T/sys"
unset DELEGATE_JOBS_DIR

# run_rec ID [ENV...]: run the helper, capture stdout in GOT and the exit in RC.
run_rec() {
  local id="$1"
  shift
  GOT="$(env "$@" bash "$REC" "$id" 2>"$T/stderr.txt")"
  RC=$?
}

# run_rec_args [ARGS...]: run with an explicit arg list (for arity cases).
run_rec_args() {
  GOT="$(bash "$REC" "$@" 2>"$T/stderr.txt")"
  RC=$?
}

plant() {
  printf '{}\n' >"$1"
}

# --- record only in each directory ---
plant "$T/override/only-over.json"
run_rec only-over "DELEGATE_JOBS_DIR=$T/override"
[ "$RC" -eq 0 ] || fail "override-only exits 0 (rc=$RC)"
[ "$GOT" = "$T/override/only-over.json" ] || fail "override-only path: $GOT"

plant "$T/tmp/delegate-jobs/only-tmp.json"
run_rec only-tmp "DELEGATE_JOBS_DIR=$T/override"
[ "$RC" -eq 0 ] || fail "tmp-only exits 0 (rc=$RC)"
[ "$GOT" = "$T/tmp/delegate-jobs/only-tmp.json" ] || fail "tmp-only path: $GOT"

plant "$T/sys/only-sys.json"
run_rec only-sys "DELEGATE_JOBS_DIR=$T/override"
[ "$RC" -eq 0 ] || fail "system-only exits 0 (rc=$RC)"
[ "$GOT" = "$T/sys/only-sys.json" ] || fail "system-only path: $GOT"

# --- none holds it ---
run_rec missing-id "DELEGATE_JOBS_DIR=$T/override"
[ "$RC" -eq 1 ] || fail "missing exits 1 (rc=$RC)"
[ -z "$GOT" ] || fail "missing prints nothing: $GOT"

# --- precedence (lookup order: docs/delegate-jobs.md:7-13) ---
plant "$T/override/all-three.json"
plant "$T/tmp/delegate-jobs/all-three.json"
plant "$T/sys/all-three.json"
run_rec all-three "DELEGATE_JOBS_DIR=$T/override"
[ "$RC" -eq 0 ] || fail "all-three exits 0"
[ "$GOT" = "$T/override/all-three.json" ] || fail "all-three wins override: $GOT"

plant "$T/override/over-tmp.json"
plant "$T/tmp/delegate-jobs/over-tmp.json"
run_rec over-tmp "DELEGATE_JOBS_DIR=$T/override"
[ "$GOT" = "$T/override/over-tmp.json" ] || fail "override beats tmp: $GOT"

plant "$T/tmp/delegate-jobs/tmp-sys.json"
plant "$T/sys/tmp-sys.json"
run_rec tmp-sys "DELEGATE_JOBS_DIR=$T/override"
[ "$GOT" = "$T/tmp/delegate-jobs/tmp-sys.json" ] || fail "tmp beats system: $GOT"

# --- empty DELEGATE_JOBS_DIR is ignored ---
plant "$T/tmp/delegate-jobs/empty-tmp.json"
run_rec empty-tmp "DELEGATE_JOBS_DIR="
[ "$RC" -eq 0 ] || fail "empty override falls back to tmp (rc=$RC)"
[ "$GOT" = "$T/tmp/delegate-jobs/empty-tmp.json" ] || fail "empty override tmp path: $GOT"

plant "$T/sys/empty-sys.json"
run_rec empty-sys "DELEGATE_JOBS_DIR="
[ "$RC" -eq 0 ] || fail "empty override falls back to system (rc=$RC)"
[ "$GOT" = "$T/sys/empty-sys.json" ] || fail "empty override system path: $GOT"

# --- relative override resolves against the caller's directory ---
plant "$T/cwd/rel/dir/rel-id.json"
plant "$T/tmp/delegate-jobs/rel-id.json"
GOT="$(cd "$T/cwd" && DELEGATE_JOBS_DIR=rel/dir bash "$REC" rel-id 2>"$T/stderr.txt")"
RC=$?
[ "$RC" -eq 0 ] || fail "relative override exits 0 (rc=$RC)"
[ "$GOT" = "$T/cwd/rel/dir/rel-id.json" ] || fail "relative override path: $GOT"

# --- duplicates collapse: override naming the tmp dir still reaches system ---
plant "$T/sys/dup-sys.json"
run_rec dup-sys "DELEGATE_JOBS_DIR=$T/tmp/delegate-jobs"
[ "$RC" -eq 0 ] || fail "duplicate dirs still reach system (rc=$RC)"
[ "$GOT" = "$T/sys/dup-sys.json" ] || fail "duplicate dirs system path: $GOT"

# --- an override naming a directory with a space skips no later directory ---
# (dedup compares whole directory strings, never space-delimited words).
mkdir -p "$T/with space"
plant "$T/tmp/delegate-jobs/space-id.json"
run_rec space-id "DELEGATE_JOBS_DIR=$T/with space $T/tmp/delegate-jobs"
[ "$RC" -eq 0 ] || fail "space-named override still reaches tmp (rc=$RC)"
[ "$GOT" = "$T/tmp/delegate-jobs/space-id.json" ] || fail "space-named override tmp path: $GOT"

# --- trailing slash on TMPDIR prints one slash ---
plant "$T/tmp/delegate-jobs/slash-id.json"
GOT="$(env TMPDIR="$T/tmp/" JOB_RECORD_SYSTEM_DIR="$T/sys" bash "$REC" slash-id 2>"$T/stderr.txt")"
RC=$?
[ "$RC" -eq 0 ] || fail "trailing-slash TMPDIR exits 0 (rc=$RC)"
[ "$GOT" = "$T/tmp/delegate-jobs/slash-id.json" ] || fail "trailing-slash path: $GOT"

# --- a directory named <id>.json is no hit ---
mkdir -p "$T/override/dir-id.json"
plant "$T/tmp/delegate-jobs/dir-id.json"
run_rec dir-id "DELEGATE_JOBS_DIR=$T/override"
[ "$RC" -eq 0 ] || fail "dir-named id skips to the file (rc=$RC)"
[ "$GOT" = "$T/tmp/delegate-jobs/dir-id.json" ] || fail "dir-named id path: $GOT"

# --- empty id and ids with a slash never reach a path join ---
mkdir -p "$T/override/a"
plant "$T/override/a/b.json"
run_rec "" "DELEGATE_JOBS_DIR=$T/override"
[ "$RC" -eq 1 ] || fail "empty id exits 1 (rc=$RC)"
[ -z "$GOT" ] || fail "empty id prints nothing: $GOT"
run_rec "a/b" "DELEGATE_JOBS_DIR=$T/override"
[ "$RC" -eq 1 ] || fail "slash id exits 1 (rc=$RC)"
[ -z "$GOT" ] || fail "slash id prints nothing: $GOT"

# --- arity other than one is usage on stderr, exit 2, empty stdout ---
run_rec_args
[ "$RC" -eq 2 ] || fail "zero args exits 2 (rc=$RC)"
[ -z "$GOT" ] || fail "zero args prints nothing: $GOT"
grep -q "usage" "$T/stderr.txt" || fail "zero args prints usage"

run_rec_args one two
[ "$RC" -eq 2 ] || fail "two args exits 2 (rc=$RC)"
[ -z "$GOT" ] || fail "two args prints nothing: $GOT"
grep -q "usage" "$T/stderr.txt" || fail "two args prints usage"

echo "job-record: all cases passed"

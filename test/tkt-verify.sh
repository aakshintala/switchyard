#!/usr/bin/env bash
# Tests for bin/tkt-verify: verify an already-pushed head without starting a fix job.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TKT="$SCRIPT_DIR/../bin/tkt-verify"
REAL_BIN="$SCRIPT_DIR/../bin"
TKT_STATE="$REAL_BIN/tkt-state"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-tkt-verify.XXXXXX")"
T="$(cd "$T" && pwd)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp" "$T/bin" "$T/cases"
export HOME="$T/home" TMPDIR="$T/tmp" XDG_CACHE_HOME="$T/cache" TKT_BIN="$T/bin"
export PATH="$T/bin:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME='Switchyard Test' GIT_AUTHOR_EMAIL='switchyard-test@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export T PR_HEAD

cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh|%s\n' "$*" >>"$T/calls.log"
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  head="$(cat "$PR_HEAD")" || exit 1
  jq -cn --arg head "$head" '{headRefOid:$head}'
  exit $?
fi
exit 2
EOF
chmod +x "$T/bin/gh"

cat >"$T/bin/review-pr" <<'EOF'
#!/usr/bin/env bash
printf 'review-pr|%s\n' "$*" >>"$T/calls.log"
verify_file=""; previous=""
for arg in "$@"; do
  if [ "$previous" = --verify ]; then verify_file="$arg"; fi
  previous="$arg"
done
[ -n "$verify_file" ] && cp "$verify_file" "$T/verify-input.md"
case "$(cat "$T/vermode")" in
  ok) printf 'FIX-OK\n';;
  incomplete) printf 'FIX-INCOMPLETE round=1\nP1 src/main.sh:1 — finding remains open\n';;
  fail) printf 'review-pr failed\n' >&2; exit 7;;
  no-verdict) printf 'review completed without a FIX verdict\n';;
  worktree-moves)
    printf 'moved during review\n' >"$WT/moved.txt"
    git -C "$WT" add moved.txt
    git -C "$WT" commit -qm 'test: move worktree head'
    printf 'FIX-OK\n';;
  origin-moves)
    git clone --quiet --branch "$BRANCH" "$BARE" "$T/origin-mover" || exit 8
    printf 'moved on origin\n' >"$T/origin-mover/origin-moved.txt"
    git -C "$T/origin-mover" add origin-moved.txt
    git -C "$T/origin-mover" commit -qm 'test: move origin head'
    git -C "$T/origin-mover" push --quiet origin "HEAD:$BRANCH" || exit 9
    printf 'FIX-OK\n';;
esac
EOF
chmod +x "$T/bin/review-pr"

setup_case() {
  CASE_DIR="$T/cases/$1"
  WT="$CASE_DIR/worktree"
  BARE="$CASE_DIR/origin.git"
  BRANCH='tkt-verify-1756'
  RUN="$CASE_DIR/run"
  S="$CASE_DIR/tkt.state"
  F="$CASE_DIR/findings.md"
  PR_HEAD="$CASE_DIR/pr-head"
  export WT BARE BRANCH PR_HEAD
  mkdir -p "$CASE_DIR" "$RUN"
  git init --quiet --bare "$BARE" || fail "init bare origin ($1)"
  git init --quiet -b "$BRANCH" "$WT" || fail "init worktree ($1)"
  git -C "$WT" config user.name "$GIT_AUTHOR_NAME"
  git -C "$WT" config user.email "$GIT_AUTHOR_EMAIL"
  git -C "$WT" remote add origin "$BARE"
  printf 'base\n' >"$WT/base.txt"
  git -C "$WT" add base.txt
  git -C "$WT" commit --quiet -m 'test: base'
  OLD="$(git -C "$WT" rev-parse HEAD)"
  printf 'reviewed change\n' >"$WT/change.txt"
  git -C "$WT" add change.txt
  git -C "$WT" commit --quiet -m 'test: reviewed change'
  HEAD="$(git -C "$WT" rev-parse HEAD)"
  git -C "$WT" push --quiet --set-upstream origin "$BRANCH" || fail "push fixture ($1)"
  git --git-dir="$BARE" symbolic-ref HEAD "refs/heads/$BRANCH"
  printf '%s\n' "$HEAD" >"$PR_HEAD"
  printf 'P1 src/main.sh:1 — initial finding\n' >"$F"
  {
    printf 'repo=%s\n' switchyard
    printf 'issue=%s\n' 1756
    printf 'pr=%s\n' 17
    printf 'branch=%s\n' "$BRANCH"
    printf 'worktree=%s\n' "$WT"
    printf 'run=%s\n' "$RUN"
    printf 'reviewed=%s\n' "$OLD"
    printf 'head=%s\n' "$HEAD"
    printf 'round=0\n'
    printf 'fixopen=0\n'
    printf 'model.verify=%s\n' state-verify-model
  } >"$S"
  printf 'ok\n' >"$T/vermode"
  : >"$T/calls.log"
}

read_state() { bash "$TKT_STATE" "$S" get "$1"; }
set_state() { bash "$TKT_STATE" "$S" set "$1" "$2" >/dev/null; }

run_verify() {
  local rc=0
  OUT="$(bash "$TKT" "$S" --findings "$F" 2>"$T/stderr")" || rc=$?
  RC="$rc"
}

run_verify_override() {
  local rc=0
  OUT="$(bash "$TKT" "$S" --findings "$F" --verify-model override-model 2>"$T/stderr")" || rc=$?
  RC="$rc"
}

assert_first_verdict() {
  grep -Eq "^TKT tkt-verify $1([[:space:]]|$)" <<<"$OUT" || fail "$2 verdict missing: $OUT"
}

assert_no_review() {
  ! grep -q '^review-pr|' "$T/calls.log" || fail "$1 called review-pr: $(cat "$T/calls.log")"
}

assert_no_slot() {
  ! grep -q '^fix_round\.' "$S" || fail "$1 wrote fix-round state before refusing: $(grep '^fix_round\.' "$S")"
  ! grep -q '^fixslot=' "$S" || fail "$1 wrote fixslot before refusing: $(grep '^fixslot=' "$S")"
}

# FIX-OK records the exact reviewed head and the command passes the findings delta.
setup_case fix-ok
run_verify
[ "$RC" = 0 ] || fail "FIX-OK exited $RC: $OUT $(cat "$T/stderr")"
assert_first_verdict FIX-OK 'FIX-OK'
grep -Fq "reviewed=$HEAD" <<<"$OUT" || fail "FIX-OK omitted reviewed SHA: $OUT"
[ "$(read_state reviewed)" = "$HEAD" ] || fail "FIX-OK did not advance reviewed to the exact head"
[ "$(read_state head)" = "$HEAD" ] || fail "FIX-OK did not advance head to the exact head"
[ "$(read_state round)" = 1 ] || fail "FIX-OK did not count the P-line findings round"
[ "$(read_state fix_round.1.start)" = "$OLD" ] || fail "FIX-OK did not record the slot start"
[ "$(read_state fix_round.1.head)" = "$HEAD" ] || fail "FIX-OK did not record the slot head"
[ "$(read_state fix_round.1.findings)" = "$F" ] || fail "FIX-OK did not record the input findings file"
[ "$(read_state fixslot)" = 1 ] || fail "FIX-OK did not close the fix-round slot"
[ -r "$(read_state findings_history)" ] || fail "FIX-OK did not write findings history"
[ "$(read_state fix_round.1.history)" = "$(read_state findings_history)" ] || fail "FIX-OK did not associate history with its slot"
grep -Fq -- "--head $HEAD --model state-verify-model --verify $F --since $OLD" "$T/calls.log" || fail "review-pr did not receive the expected head, model, findings and since"
grep -Fq "tkt-verify FIX-OK reviewed=$HEAD" "${S%.state}.journal" || fail "FIX-OK was not journalled"

# An explicit model replaces model.verify.
setup_case model-override
run_verify_override
[ "$RC" = 0 ] || fail "model override exited $RC: $OUT $(cat "$T/stderr")"
grep -Fq -- "--model override-model" "$T/calls.log" || fail "review-pr did not receive --verify-model"

# FIX-INCOMPLETE saves the output as current findings, but does not change reviewed.
setup_case incomplete
printf 'incomplete\n' >"$T/vermode"
run_verify
[ "$RC" = 1 ] || fail "FIX-INCOMPLETE exited $RC, want 1: $OUT"
assert_first_verdict FIX-INCOMPLETE 'FIX-INCOMPLETE'
[ "$(read_state reviewed)" = "$OLD" ] || fail "FIX-INCOMPLETE changed reviewed"
[ "$(read_state findings)" = "$RUN/switchyard-1756-tkt-verify-${HEAD:0:12}.md" ] || fail "FIX-INCOMPLETE did not store its verify output path"
grep -Fq 'P1 src/main.sh:1 — finding remains open' "$(read_state findings)" || fail "FIX-INCOMPLETE output file omitted open findings"
[ "$(read_state round)" = 1 ] || fail "FIX-INCOMPLETE did not count the P-line findings round"
[ "$(read_state fix_round.1.start)" = "$OLD" ] || fail "FIX-INCOMPLETE did not record the slot start"
[ "$(read_state fix_round.1.head)" = "$HEAD" ] || fail "FIX-INCOMPLETE did not record the slot head"
[ "$(read_state fix_round.1.findings)" = "$F" ] || fail "FIX-INCOMPLETE did not record the input findings file"
[ "$(read_state fixslot)" = 1 ] || fail "FIX-INCOMPLETE did not close the fix-round slot"
[ -r "$(read_state findings_history)" ] || fail "FIX-INCOMPLETE did not write findings history"

# VERIFY-FAIL paths never count a round, even with P-line input.
setup_case verify-fail
printf 'fail\n' >"$T/vermode"
run_verify
[ "$RC" = 1 ] || fail "non-zero review-pr exited $RC, want 1: $OUT"
assert_first_verdict VERIFY-FAIL 'non-zero review-pr'
[ "$(read_state reviewed)" = "$OLD" ] || fail "non-zero review-pr changed reviewed"
[ "$(read_state round)" = 0 ] || fail "non-zero review-pr counted a P-line round on VERIFY-FAIL"
setup_case no-verdict
printf 'no-verdict\n' >"$T/vermode"
run_verify
[ "$RC" = 1 ] || fail "missing FIX line exited $RC, want 1: $OUT"
assert_first_verdict VERIFY-FAIL 'missing FIX line'
[ "$(read_state reviewed)" = "$OLD" ] || fail "missing FIX line changed reviewed"
[ "$(read_state round)" = 0 ] || fail "missing FIX line counted a P-line round on VERIFY-FAIL"
# A worktree commit during review is not acknowledged as reviewed.
setup_case worktree-moves
printf 'worktree-moves\n' >"$T/vermode"
run_verify
[ "$RC" = 1 ] || fail "worktree move exited $RC, want 1: $OUT"
assert_first_verdict HEAD-MOVED 'worktree move'
[ "$(read_state reviewed)" = "$OLD" ] || fail "worktree move changed reviewed"
[ "$(read_state head)" = "$HEAD" ] || fail "worktree move changed state head"
[ "$(read_state round)" = 0 ] || fail "worktree move changed round state"
assert_no_slot 'worktree move'
[ "$(git -C "$WT" rev-parse HEAD)" != "$HEAD" ] || fail "review stub did not move the worktree"
[ "$(grep -c '^gh|' "$T/calls.log")" = 2 ] || fail "worktree-move path did not re-read the PR head after verify"
[ ! -e "${S%.state}.journal" ] || fail "worktree move wrote the state journal"

# A review-pr stub pushes to the bare origin while the local worktree stays put.
setup_case origin-moves
printf 'origin-moves\n' >"$T/vermode"
run_verify
[ "$RC" = 1 ] || fail "origin move exited $RC, want 1: $OUT"
assert_first_verdict HEAD-MOVED 'origin move'
[ "$(read_state reviewed)" = "$OLD" ] || fail "origin move changed reviewed"
[ "$(read_state head)" = "$HEAD" ] || fail "origin move changed state head"
[ "$(read_state round)" = 0 ] || fail "origin move changed round state"
assert_no_slot 'origin move'
[ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD" ] || fail "origin move also changed the worktree"
[ "$(git --git-dir="$BARE" rev-parse "refs/heads/$BRANCH")" != "$HEAD" ] || fail "review stub did not move bare origin"
[ "$(git -C "$WT" rev-parse "refs/remotes/origin/$BRANCH")" != "$HEAD" ] || fail "post-review fetch did not refresh origin/$BRANCH"
[ "$(grep -c '^gh|' "$T/calls.log")" = 2 ] || fail "origin-move path did not re-read the PR head after verify"
[ ! -e "${S%.state}.journal" ] || fail "origin move wrote the state journal"

# Pre-review refusal paths must not call review-pr or alter state.
setup_case not-pushed
printf 'unpushed\n' >"$WT/unpushed.txt"
git -C "$WT" add unpushed.txt
git -C "$WT" commit --quiet -m 'test: leave local head unpushed'
run_verify
[ "$RC" = 1 ] || fail "NOT-PUSHED exited $RC, want 1: $OUT"
assert_first_verdict NOT-PUSHED 'NOT-PUSHED'
assert_no_review NOT-PUSHED
assert_no_slot NOT-PUSHED
[ "$(read_state reviewed)" = "$OLD" ] || fail "NOT-PUSHED changed reviewed"

setup_case pr-head-mismatch
printf '%040d\n' 123 >"$PR_HEAD"
run_verify
[ "$RC" = 1 ] || fail "PR-HEAD-MISMATCH exited $RC, want 1: $OUT"
assert_first_verdict PR-HEAD-MISMATCH 'PR-HEAD-MISMATCH'
assert_no_review PR-HEAD-MISMATCH
assert_no_slot PR-HEAD-MISMATCH

setup_case fix-open
set_state fixopen 1
run_verify
[ "$RC" = 1 ] || fail "FIX-OPEN exited $RC, want 1: $OUT"
assert_first_verdict FIX-OPEN 'FIX-OPEN'
assert_no_review FIX-OPEN
assert_no_slot FIX-OPEN

setup_case nothing-to-verify
set_state reviewed "$HEAD"
run_verify
[ "$RC" = 1 ] || fail "NOTHING-TO-VERIFY exited $RC, want 1: $OUT"
assert_first_verdict NOTHING-TO-VERIFY 'NOTHING-TO-VERIFY'
assert_no_review NOTHING-TO-VERIFY
assert_no_slot NOTHING-TO-VERIFY

setup_case since-not-ancestor
set_state reviewed 0000000000000000000000000000000000000000
run_verify
[ "$RC" = 1 ] || fail "SINCE-NOT-ANCESTOR exited $RC, want 1: $OUT"
assert_first_verdict SINCE-NOT-ANCESTOR 'SINCE-NOT-ANCESTOR'
assert_no_review SINCE-NOT-ANCESTOR
assert_no_slot SINCE-NOT-ANCESTOR

setup_case round-limit
set_state round 2
run_verify
[ "$RC" = 1 ] || fail "ROUND-LIMIT exited $RC, want 1: $OUT"
assert_first_verdict ROUND-LIMIT 'ROUND-LIMIT'
assert_no_review ROUND-LIMIT
assert_no_slot ROUND-LIMIT

# A merge-only note does not count as another round even at round 2.
setup_case note-only
set_state round 2
printf 'merge-only review note\n' >"$F"
run_verify
[ "$RC" = 0 ] || fail "note-only findings exited $RC: $OUT $(cat "$T/stderr")"
assert_first_verdict FIX-OK 'note-only FIX-OK'
[ "$(read_state round)" = 2 ] || fail "note-only verify incremented round"

# Missing state keys, state model and a held lock fail before review-pr.
setup_case missing-key
grep -v '^repo=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
run_verify
[ "$RC" = 2 ] || fail "missing key exited $RC, want 2: $OUT $(cat "$T/stderr")"
grep -Fq 'missing key: repo' "$T/stderr" || fail "missing-key error did not name repo: $(cat "$T/stderr")"
assert_no_review 'missing key'

setup_case missing-model
grep -v '^model.verify=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
run_verify
[ "$RC" = 2 ] || fail "missing model exited $RC, want 2: $OUT $(cat "$T/stderr")"
grep -Fq 'missing key: model.verify' "$T/stderr" || fail "missing-model error did not name model.verify: $(cat "$T/stderr")"
assert_no_review 'missing model'

setup_case held-lock
mkdir "$S.lock"
printf 'fixture holder\n' >"$S.lock/pid"
run_verify
[ "$RC" = 2 ] || fail "held lock exited $RC, want 2: $OUT $(cat "$T/stderr")"
grep -Fq 'state locked' "$T/stderr" || fail "held-lock error missing: $(cat "$T/stderr")"
assert_no_review 'held lock'

echo 'tkt-verify: all cases passed'

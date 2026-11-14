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
if [ "${1:-}" = api ]; then
  case "${2:-}" in
    repos/switchyard/issues/comments/*)
      comment_id="${2##*/}"
      [ -r "$T/comment-$comment_id.json" ] || exit 1
      cat "$T/comment-$comment_id.json"
      exit 0;;
  esac
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
    printf 'verdict_at=%s\n' '2026-11-13T00:00:00Z'
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

run_verify_ruling() {
  local id="$1" rc=0
  OUT="$(bash "$TKT" "$S" --findings "$F" --ruling "$id" 2>"$T/stderr")" || rc=$?
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
  ! grep -q '^fix_round[.]' "$S" || fail "$1 wrote fix-round state before refusing: $(grep '^fix_round[.]' "$S")"
  ! grep -q '^fixslot=' "$S" || fail "$1 wrote fixslot before refusing: $(grep '^fixslot=' "$S")"
}

write_ruling_comment() {
  local id="$1" body="$2" author_association="${3:-OWNER}" issue_number="${4:-1756}" created_at="${5:-2026-11-14T00:00:00Z}"
  jq -n --arg body "$body" --arg author_association "$author_association" \
    --arg issue_url "https://api.github.com/repos/switchyard/issues/$issue_number" \
    --arg html_url "https://github.com/switchyard/switchyard/issues/$issue_number#issuecomment-$id" \
    --arg created_at "$created_at" \
    '{body:$body, author_association:$author_association, issue_url:$issue_url, html_url:$html_url, created_at:$created_at}' \
    >"$T/comment-$id.json"
}

assert_no_grant() {
  ! grep -q '^grant[.]' "$S" || fail "$1 wrote grant state: $(grep '^grant[.]' "$S")"
}

expect_grant_refused() {
  local name="$1" reason="$2" id="$3" initial_round="${4:-2}"
  run_verify_ruling "$id"
  [ "$RC" = 2 ] || fail "$name exited $RC, want 2: $OUT $(cat "$T/stderr")"
  grep -Fq "TKT tkt-verify RULING-REFUSED reason=$reason comment=$id" <<<"$OUT" || fail "$name refusal missing: $OUT"
  assert_no_review "$name"
  assert_no_slot "$name"
  assert_no_grant "$name"
  [ "$(read_state round)" = "$initial_round" ] || fail "$name changed round"
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
[ "$(read_state verdict_at)" != '2026-11-13T00:00:00Z' ] || fail "FIX-OK did not advance verdict_at"
grep -Eq '^verdict_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$S" || fail "FIX-OK verdict_at is not UTC"
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
[ "$(read_state verdict_at)" != '2026-11-13T00:00:00Z' ] || fail "FIX-INCOMPLETE did not advance verdict_at"
grep -Fq 'tkt-verify FIX-INCOMPLETE' "${S%.state}.journal" || fail "FIX-INCOMPLETE was not journalled"
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
[ "$(read_state fixslot)" = 1 ] || fail "non-zero review-pr did not record its fix-round slot"
[ "$(read_state fix_round.1.head)" = "$HEAD" ] || fail "non-zero review-pr did not record its fix-round head"
# Retrying the same reviewed..HEAD range reuses its slot rather than creating slot 2.
printf 'ok\n' >"$T/vermode"
run_verify
[ "$RC" = 0 ] || fail "same-range retry exited $RC: $OUT $(cat "$T/stderr")"
assert_first_verdict FIX-OK 'same-range retry'
[ "$(read_state fixslot)" = 1 ] || fail "same-range retry advanced fixslot"
[ "$(read_state fix_round.1.head)" = "$HEAD" ] || fail "same-range retry changed slot 1 head"
! grep -q '^fix_round\.2\.' "$S" || fail "same-range retry created slot 2: $(grep '^fix_round\.2\.' "$S")"
[ "$(read_state round)" = 1 ] || fail "same-range retry did not count the successful P-line review"

# A different head over the same reviewed start gets a new slot.
setup_case changed-head-retry
printf 'fail\n' >"$T/vermode"
run_verify
[ "$RC" = 1 ] || fail "initial changed-head retry setup exited $RC: $OUT"
[ "$(read_state fixslot)" = 1 ] || fail "initial changed-head retry did not record slot 1"
printf 'new change\n' >"$WT/new-change.txt"
git -C "$WT" add new-change.txt
git -C "$WT" commit --quiet -m 'test: change head before retry'
git -C "$WT" push --quiet origin "$BRANCH" || fail "push changed-head retry fixture"
NEW_HEAD="$(git -C "$WT" rev-parse HEAD)"
printf '%s\n' "$NEW_HEAD" >"$PR_HEAD"
run_verify
[ "$RC" = 1 ] || fail "changed-head retry exited $RC, want 1: $OUT"
[ "$(read_state fixslot)" = 2 ] || fail "changed-head retry did not allocate slot 2"
[ "$(read_state fix_round.2.start)" = "$OLD" ] || fail "changed-head retry recorded the wrong slot 2 start"
[ "$(read_state fix_round.2.head)" = "$NEW_HEAD" ] || fail "changed-head retry recorded the wrong slot 2 head"
[ "$(read_state round)" = 0 ] || fail "changed-head VERIFY-FAIL counted a P-line round"

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
[ "$(read_state round)" = 1 ] || fail "worktree move did not count the P-line findings round"
[ "$(read_state fix_round.1.head)" = "$HEAD" ] || fail "worktree move did not keep the slot it recorded"
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
[ "$(read_state round)" = 1 ] || fail "origin move did not count the P-line findings round"
[ "$(read_state fix_round.1.head)" = "$HEAD" ] || fail "origin move did not keep the slot it recorded"
[ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD" ] || fail "origin move also changed the worktree"
[ "$(git --git-dir="$BARE" rev-parse "refs/heads/$BRANCH")" != "$HEAD" ] || fail "review stub did not move bare origin"
[ "$(git -C "$WT" rev-parse "refs/remotes/origin/$BRANCH")" != "$HEAD" ] || fail "post-review fetch did not refresh origin/$BRANCH"
[ "$(grep -c '^gh|' "$T/calls.log")" = 2 ] || fail "origin-move path did not re-read the PR head after verify"
[ ! -e "${S%.state}.journal" ] || fail "origin move wrote the state journal"

# A HEAD-MOVED review with only notes does not count a round.
setup_case worktree-moves-note-only
printf 'merge-only review note\n' >"$F"
printf 'worktree-moves\n' >"$T/vermode"
run_verify
[ "$RC" = 1 ] || fail "note-only worktree move exited $RC, want 1: $OUT"
assert_first_verdict HEAD-MOVED 'note-only worktree move'
[ "$(read_state reviewed)" = "$OLD" ] || fail "note-only worktree move changed reviewed"
[ "$(read_state head)" = "$HEAD" ] || fail "note-only worktree move changed state head"
[ "$(read_state round)" = 0 ] || fail "note-only worktree move changed round state"
[ "$(read_state fix_round.1.head)" = "$HEAD" ] || fail "note-only worktree move did not keep the slot it recorded"
[ "$(git -C "$WT" rev-parse HEAD)" != "$HEAD" ] || fail "review stub did not move the note-only worktree"
[ "$(grep -c '^gh|' "$T/calls.log")" = 2 ] || fail "note-only worktree-move path did not re-read the PR head after verify"
[ ! -e "${S%.state}.journal" ] || fail "note-only worktree move wrote the state journal"

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
assert_no_grant ROUND-LIMIT

# A grant runs one P-line review past the cap and becomes a body requirement.
if [ -z "${CASE:-}" ] || [ "$CASE" = grant-one-round ]; then
setup_case grant-one-round
set_state round 2
write_ruling_comment 900 $'context\ngrants: round 3'
printf 'incomplete\n' >"$T/vermode"
run_verify_ruling 900
[ "$RC" = 1 ] || fail "grant-one-round exited $RC, want FIX-INCOMPLETE: $OUT $(cat "$T/stderr")"
assert_first_verdict FIX-INCOMPLETE 'granted FIX-INCOMPLETE'
[ "$(read_state round)" = 3 ] || fail "grant did not count round 3"
[ "$(read_state grant.3)" = '900 https://github.com/switchyard/switchyard/issues/1756#issuecomment-900' ] || fail "grant.3 was not recorded"
grep -Fq 'ruling https://github.com/switchyard/switchyard/issues/1756#issuecomment-900 grants round 3' "${S%.state}.journal" || fail "grant journal omitted URL and round"
grep -Fq 'body_has=Recorded ruling: https://github.com/switchyard/switchyard/issues/1756#issuecomment-900' "$S" || fail "grant body requirement was not recorded"
grep -Fq 'Recorded ruling: https://github.com/switchyard/switchyard/issues/1756#issuecomment-900' <<<"$OUT" || fail "grant output omitted PR body line"
grep -Fq 'add this line to the PR body' <<<"$OUT" || fail "grant output omitted body instruction"
: >"$T/calls.log"
run_verify_ruling 900
[ "$RC" = 2 ] || fail "reuse exited $RC, want 2: $OUT"
grep -Fq 'RULING-REFUSED reason=reused comment=900' <<<"$OUT" || fail "reuse was not refused as reused: $OUT"
assert_no_review reuse
: >"$T/calls.log"
run_verify
[ "$RC" = 1 ] || fail "next round without a grant exited $RC, want ROUND-LIMIT: $OUT"
assert_first_verdict ROUND-LIMIT 'next round without grant'
grep -Fq 'round=3' <<<"$OUT" || fail "next round hint omitted the current round: $OUT"
assert_no_review 'next round without grant'
fi

# VERIFY-FAIL leaves the counted slot and grant available for a retry.
if [ -z "${CASE:-}" ] || [ "$CASE" = grant-retry ]; then
setup_case grant-retry
set_state round 2
write_ruling_comment 901 'grants: round 3'
printf 'fail\n' >"$T/vermode"
run_verify_ruling 901
[ "$RC" = 1 ] || fail "grant retry first run exited $RC, want VERIFY-FAIL: $OUT"
assert_first_verdict VERIFY-FAIL 'grant retry first run'
[ "$(read_state round)" = 2 ] || fail "VERIFY-FAIL counted the granted round"
[ "$(read_state grant.3)" != '' ] || fail "VERIFY-FAIL lost grant.3"
printf 'incomplete\n' >"$T/vermode"
run_verify_ruling 901
[ "$RC" = 1 ] || fail "grant retry second run exited $RC: $OUT"
assert_first_verdict FIX-INCOMPLETE 'grant retry second run'
[ "$(read_state round)" = 3 ] || fail "grant retry did not count round 3"
[ "$(grep -c '^body_has=Recorded ruling:' "$S")" = 1 ] || fail "grant retry repeated the body requirement"
fi

# The shared grant refusals do not reserve a round or dispatch a review.
if [ -z "${CASE:-}" ] || [ "$CASE" = grant-refusals ]; then
setup_case grant-stale
set_state round 2
write_ruling_comment 910 'grants: round 3' OWNER 1756 '2026-11-12T00:00:00Z'
expect_grant_refused stale stale 910

setup_case grant-author
set_state round 2
write_ruling_comment 911 'grants: round 3' NONE
expect_grant_refused author author 911

setup_case grant-issue
set_state round 2
write_ruling_comment 912 'grants: round 3' OWNER 18
expect_grant_refused issue issue 912

setup_case grant-bad-form
set_state round 2
write_ruling_comment 913 'grants: round 2'
expect_grant_refused bad-grant bad-grant 913

setup_case grant-not-limited
set_state round 1
write_ruling_comment 914 'grants: round 2'
expect_grant_refused not-limited not-limited 914 1

setup_case grant-multiple-lines
set_state round 2
write_ruling_comment 915 $'grants: round 3\ngrants: round 3'
expect_grant_refused multiple-lines bad-grant 915
fi

# A grant can be attached to the PR, and CRLF line endings are accepted.
if [ -z "${CASE:-}" ] || [ "$CASE" = grant-on-pr ]; then
setup_case grant-on-pr
set_state round 2
write_ruling_comment 916 $'grants: round 3\r' OWNER 17
printf 'incomplete\n' >"$T/vermode"
run_verify_ruling 916
[ "$RC" = 1 ] || fail "PR grant exited $RC: $OUT $(cat "$T/stderr")"
assert_first_verdict FIX-INCOMPLETE 'PR grant'
[ "$(read_state round)" = 3 ] || fail "PR grant did not count round 3"

setup_case grant-no-state-issue
set_state round 2
grep -v '^issue=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
write_ruling_comment 919 'grants: round 3' OWNER 17
printf 'incomplete\n' >"$T/vermode"
run_verify_ruling 919
[ "$RC" = 1 ] || fail "PR grant without state issue exited $RC: $OUT $(cat "$T/stderr")"
assert_first_verdict FIX-INCOMPLETE 'PR grant without state issue'
[ "$(read_state round)" = 3 ] || fail "PR grant without state issue did not count round 3"
fi

# Legacy state falls back to its latest journaled review verdict.
if [ -z "${CASE:-}" ] || [ "$CASE" = grant-legacy-fallback ]; then
setup_case grant-legacy-fallback
set_state round 2
grep -v '^verdict_at=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
printf '%s tkt-fix FIX-INCOMPLETE round=2\n' '2026-11-13T00:00:00Z' >"${S%.state}.journal"
write_ruling_comment 917 'grants: round 3' OWNER 1756 '2026-11-12T23:59:59Z'
expect_grant_refused legacy-stale stale 917
write_ruling_comment 918 'grants: round 3' OWNER 1756 '2026-11-13T00:00:01Z'
printf 'incomplete\n' >"$T/vermode"
run_verify_ruling 918
[ "$RC" = 1 ] || fail "legacy fresh grant exited $RC: $OUT $(cat "$T/stderr")"
assert_first_verdict FIX-INCOMPLETE 'legacy fresh grant'
fi

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

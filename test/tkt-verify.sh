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
  if [[ " $* " == *" --json body "* ]]; then
    [ ! -f "$T/body-fail" ] || { echo 'gh: PR body unavailable' >&2; exit 4; }
    cat "$PR_BODY"
    exit $?
  fi
  head="$(cat "$PR_HEAD")" || exit 1
  jq -cn --arg head "$head" '{headRefOid:$head}'
  exit $?
fi
if [ "${1:-}" = api ]; then
  case "${2:-}" in
    --paginate)
      endpoint="${3:-}"
      [ "$endpoint" = repos/switchyard/issues/17/comments ] || exit 2
      [ -r "$T/comments.json" ] || { printf '[]\n'; exit 0; }
      cat "$T/comments.json"
      exit 0;;
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
verify_file=""; previous=""; model=""; model_ruling=""
for arg in "$@"; do
  if [ "$previous" = --verify ]; then verify_file="$arg"; fi
  if [ "$previous" = --model ]; then model="$arg"; fi
  if [ "$previous" = --model-ruling ]; then model_ruling="$arg"; fi
  if [ "$previous" = --context ]; then cp "$arg" "$T/context-$(basename "$arg")"; fi
  previous="$arg"
done
if [ "$model" = claude-sonnet-5-5 ] && [ -z "$model_ruling" ]; then
  echo 'delegate: claude-sonnet-5-5 is not in the allowed pool; pass --model-ruling <comment URL>' >&2
  exit 2
fi
[ -n "$verify_file" ] && cp "$verify_file" "$T/verify-input.md"
case "$(cat "$T/vermode")" in
  ok) printf 'FIX-OK\n';;
  incomplete) printf 'FIX-INCOMPLETE round=1\nP1 src/main.sh:1 — finding remains open\n';;
  bullet-incomplete) printf 'FIX-INCOMPLETE round=1\n- **P3 `src/main.sh:3` — non-blocking finding.**\n';;
  p3-incomplete) printf 'FIX-INCOMPLETE round=1\nP3 src/main.sh:3 — non-blocking finding\n';;
  p2-incomplete) printf 'FIX-INCOMPLETE round=1\nP3 src/main.sh:3 — non-blocking finding\nP2 src/main.sh:2 — blocking finding\n';;
  p2-fixed-p3-incomplete) printf 'FIX-INCOMPLETE round=1\n## Fixed\nP2 src/main.sh:2: fixed.\n## Open\nP3 src/main.sh:3 — non-blocking finding\n';;
  p2-open-under-fixed) printf 'FIX-INCOMPLETE round=1\n## Fixed\nP2 src/main.sh:1: fixed.\nP2 src/main.sh:2 — still broken\n';;
  p0-p3-incomplete) printf 'FIX-INCOMPLETE round=1\nP0 src/main.sh:0 — critical finding\nP3 src/main.sh:3 — non-blocking finding\n';;
  p0-only-incomplete) printf 'FIX-INCOMPLETE round=1\nP0 src/main.sh:0 — critical finding\n';;
  fail) printf 'review-pr failed\n' >&2; exit 7;;
  behind)
    refusal_head="$(cat "$REFUSAL_HEAD")"
    echo "review-pr: --since $OLD is behind FIX-OK verify at head $refusal_head; pass --since $refusal_head instead" >&2
    exit 2;;
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
  rm -f "$T/body-fail"
  CASE_DIR="$T/cases/$1"
  WT="$CASE_DIR/worktree"
  BARE="$CASE_DIR/origin.git"
  BRANCH='tkt-verify-1756'
  RUN="$CASE_DIR/run"
  S="$CASE_DIR/tkt.state"
  F="$CASE_DIR/findings.md"
  PR_HEAD="$CASE_DIR/pr-head"
  PR_BODY="$CASE_DIR/pr-body"
  REFUSAL_HEAD="$CASE_DIR/refusal-head"
  export WT BARE BRANCH PR_HEAD PR_BODY REFUSAL_HEAD OLD HEAD
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
  git -C "$WT" update-ref refs/remotes/origin/main "$OLD"
  printf '%s\n' "$HEAD" >"$PR_HEAD"
  printf 'initial PR body\n' >"$PR_BODY"
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

run_verify_rulings() {
  local rc=0
  local -a ruling_args=()
  while [ "$#" -gt 0 ]; do
    ruling_args+=(--ruling "$1")
    shift
  done
  OUT="$(bash "$TKT" "$S" --findings "$F" "${ruling_args[@]}" 2>"$T/stderr")" || rc=$?
  RC="$rc"
}

run_verify_ruling() {
  run_verify_rulings "$1"
}

run_verify_override() {
  local rc=0
  OUT="$(bash "$TKT" "$S" --findings "$F" --verify-model override-model 2>"$T/stderr")" || rc=$?
  RC="$rc"
}

run_reverify() {
  local rc=0
  OUT="$(bash "$TKT" "$S" --reverify --verify-model "${1:-openai/gpt-6.1-sol}" 2>"$T/stderr")" || rc=$?
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

write_ruling_comment() {
  local id="$1" body="$2" author_association="${3:-OWNER}" issue_number="${4:-1756}" created_at="${5:-2026-11-14T00:00:00Z}"
  jq -n --arg body "$body" --arg author_association "$author_association" \
    --arg issue_url "https://api.github.com/repos/switchyard/issues/$issue_number" \
    --arg html_url "https://github.com/switchyard/switchyard/issues/$issue_number#issuecomment-$id" \
    --arg created_at "$created_at" \
    '{body:$body, author_association:$author_association, issue_url:$issue_url, html_url:$html_url, created_at:$created_at}' \
    >"$T/comment-$id.json"
}

install_delegate_probe() {
  cat >"$T/bin/delegate" <<'EOF'
#!/usr/bin/env bash
printf 'delegate|%s\n' "$*" >>"$T/calls.log"
exit 99
EOF
  chmod +x "$T/bin/delegate"
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

write_review_comment() {
  local id="$1" patch_id="$2" comment_head="$3" comment_since="$4" verdict="$5" association="${6:-OWNER}"
  local header
  if [ "$comment_since" = none ]; then
    header="review-pr: patch-id $patch_id, head $comment_head"
  else
    header="review-pr: patch-id $patch_id, head $comment_head, since $comment_since"
  fi
  jq -n --argjson id "$id" --arg header "$header" --arg verdict "$verdict" \
    --arg assoc "$association" \
    '[{id:$id,created_at:"2026-11-14T00:00:00Z",author_association:$assoc,body:($header + "\n\n## verify (test)\n\n" + $verdict)}]' \
    >"$T/comments.json"
}

append_review_comment() {
  local id="$1" patch_id="$2" comment_head="$3" comment_since="$4" verdict="$5"
  local header="review-pr: patch-id $patch_id, head $comment_head, since $comment_since"
  jq --argjson id "$id" --arg header "$header" --arg verdict "$verdict" \
    '. + [{id:$id,created_at:"2026-11-14T00:00:01Z",author_association:"OWNER",body:($header + "\n\n## verify (test)\n\n" + $verdict)}]' \
    "$T/comments.json" >"$T/comments.next.json"
  mv "$T/comments.next.json" "$T/comments.json"
}

run_ruling_refutes_reviewed_all() {
  local history_file history journal ship_command
  setup_case ruling-refutes-reviewed-all
  install_delegate_probe
  set_state reviewed "$HEAD"
  printf 'P1 src/main.sh:1 — initial finding\nP2 src/worker.sh:2 — another finding\n' >"$F"
  set_state findings "$F"
  history_file="$CASE_DIR/findings-history.md"
  printf '# Findings history\nP3 src/old.sh:3 — posted finding [tkt-history: raised=review round 0; status=open; unverified=none]\n' >"$history_file"
  set_state findings_history "$history_file"
  write_ruling_comment 930 'refutes: P1 src/main.sh:1'
  write_ruling_comment 931 $'refutes: P2 src/worker.sh:2\nrefutes: P3 src/old.sh:3'

  run_verify_rulings 930 931
  [ "$RC" = 0 ] || fail "ruling-refutes-reviewed-all exited $RC, want 0: $OUT $(cat "$T/stderr")"
  grep -Fxq "TKT tkt-verify RULED unverified head=$HEAD" <<<"$(head -n 1 <<<"$OUT")" || fail "ruling-refutes-reviewed-all omitted reviewed head: $OUT"
  grep -Fxq "tkt-ship $S" <<<"$OUT" || fail "ruling-refutes-reviewed-all omitted ship command: $OUT"
  [ "$(read_state unverified)" = "$F" ] || fail "ruling-refutes-reviewed-all did not set unverified to findings"
  [ "$(read_state round)" = 0 ] || fail "ruling-refutes-reviewed-all incremented round"
  assert_no_review 'ruling-refutes-reviewed-all'
  assert_no_slot 'ruling-refutes-reviewed-all'
  ! grep -q '^delegate|' "$T/calls.log" || fail "ruling-refutes-reviewed-all dispatched delegate: $(cat "$T/calls.log")"

  journal="${S%.state}.journal"
  grep -Fq 'ruling https://github.com/switchyard/switchyard/issues/1756#issuecomment-930 refutes P1 src/main.sh:1' "$journal" || fail "ruling-refutes-reviewed-all did not journal comment 930"
  grep -Fq 'ruling https://github.com/switchyard/switchyard/issues/1756#issuecomment-931 refutes P2 src/worker.sh:2' "$journal" || fail "ruling-refutes-reviewed-all did not journal comment 931's P2 refutation"
  grep -Fq 'ruling https://github.com/switchyard/switchyard/issues/1756#issuecomment-931 refutes P3 src/old.sh:3' "$journal" || fail "ruling-refutes-reviewed-all did not journal comment 931's history refutation"
  history="$(read_state findings_history)"
  [ -n "$history" ] && [ -r "$history" ] || fail "ruling-refutes-reviewed-all did not write findings history"
  grep -Fq 'P1 src/main.sh:1 — initial finding' "$history" || fail "ruling-refutes-reviewed-all omitted current findings from history"
  grep -Fq 'P3 src/old.sh:3 — posted finding [tkt-history: raised=review round 0; status=open; unverified=' "$history" || fail "ruling-refutes-reviewed-all did not write unverified history"
}

run_ruling_refutes_reviewed_partial() {
  setup_case ruling-refutes-reviewed-partial
  set_state reviewed "$HEAD"
  printf 'P1 src/main.sh:1 — initial finding\nP2 src/worker.sh:2 — another finding\n' >"$F"
  set_state findings "$F"
  write_ruling_comment 932 'refutes: P1 src/main.sh:1'

  run_verify_ruling 932
  [ "$RC" = 1 ] || fail "ruling-refutes-reviewed-partial exited $RC, want 1: $OUT $(cat "$T/stderr")"
  assert_first_verdict NOTHING-TO-VERIFY 'ruling-refutes-reviewed-partial'
  assert_no_review 'ruling-refutes-reviewed-partial'
  assert_no_slot 'ruling-refutes-reviewed-partial'
  [ "$(read_state reviewed)" = "$HEAD" ] || fail "ruling-refutes-reviewed-partial changed reviewed"
  [ "$(bash "$TKT_STATE" "$S" get unverified 2>/dev/null || true)" = '' ] || fail "ruling-refutes-reviewed-partial set unverified"
  ! grep -Fq 'ruling https://github.com/switchyard/switchyard/issues/1756#issuecomment-932' "${S%.state}.journal" 2>/dev/null \
    || fail "ruling-refutes-reviewed-partial journalled a partial ruling"
}

run_ruling_refutes_reviewed_narrowed() {
  local state_findings rc=0 journal
  setup_case ruling-refutes-reviewed-narrowed
  install_delegate_probe
  set_state reviewed "$HEAD"
  state_findings="$CASE_DIR/state-findings.md"
  printf 'P1 src/main.sh:1 — initial finding\nP2 src/worker.sh:2 — another finding\n' >"$state_findings"
  printf 'P1 src/main.sh:1 — initial finding\n' >"$F"
  set_state findings "$state_findings"
  write_ruling_comment 933 'refutes: P1 src/main.sh:1'

  OUT="$(bash "$TKT" "$S" --findings "$F" --ruling 933 2>"$T/stderr")" || rc=$?
  RC="$rc"
  [ "$RC" = 2 ] || fail "ruling-refutes-reviewed-narrowed exited $RC, want refusal 2: $OUT $(cat "$T/stderr")"
  grep -Fq 'TKT tkt-verify RULING-REFUSED reason=findings-mismatch comment=933' <<<"$OUT" \
    || fail "ruling-refutes-reviewed-narrowed did not refuse the narrowed findings: $OUT"
  grep -Fq "$state_findings" <<<"$OUT" \
    || fail "ruling-refutes-reviewed-narrowed omitted the state findings path: $OUT"
  [ "$(bash "$TKT_STATE" "$S" get unverified 2>/dev/null || true)" = '' ] \
    || fail "ruling-refutes-reviewed-narrowed set unverified"
  journal="${S%.state}.journal"
  ! grep -q 'ruling .* refutes ' "$journal" 2>/dev/null \
    || fail "ruling-refutes-reviewed-narrowed journalled a refutation"
  assert_no_review 'ruling-refutes-reviewed-narrowed'
  ! grep -q '^delegate|' "$T/calls.log" \
    || fail "ruling-refutes-reviewed-narrowed called delegate: $(cat "$T/calls.log")"
}

run_ruling_refutes_reviewed_spent_grant() {
  local journal
  setup_case ruling-refutes-reviewed-spent-grant
  install_delegate_probe
  set_state reviewed "$HEAD"
  set_state findings "$F"
  set_state round 2
  set_state grant.1 '934 https://github.com/switchyard/switchyard/issues/1756#issuecomment-934'
  write_ruling_comment 934 $'refutes: P1 src/main.sh:1\ngrants: round 3'

  run_verify_ruling 934
  [ "$RC" = 0 ] || fail "ruling-refutes-reviewed-spent-grant exited $RC, want 0: $OUT $(cat "$T/stderr")"
  assert_first_verdict 'RULED unverified' 'ruling-refutes-reviewed-spent-grant'
  [ "$(read_state unverified)" = "$F" ] \
    || fail "ruling-refutes-reviewed-spent-grant did not set unverified to findings"
  [ "$(read_state round)" = 2 ] \
    || fail "ruling-refutes-reviewed-spent-grant changed round"
  [ "$(read_state grant.1)" = '934 https://github.com/switchyard/switchyard/issues/1756#issuecomment-934' ] \
    || fail "ruling-refutes-reviewed-spent-grant changed the consumed grant"
  [ "$(read_state grant.3 2>/dev/null || true)" = '' ] \
    || fail "ruling-refutes-reviewed-spent-grant recorded a new grant"
  assert_no_review 'ruling-refutes-reviewed-spent-grant'
  ! grep -q '^delegate|' "$T/calls.log" \
    || fail "ruling-refutes-reviewed-spent-grant called delegate: $(cat "$T/calls.log")"
  journal="${S%.state}.journal"
  grep -Fq 'ruling https://github.com/switchyard/switchyard/issues/1756#issuecomment-934 refutes P1 src/main.sh:1' "$journal" \
    || fail "ruling-refutes-reviewed-spent-grant did not journal its refutation"
}

if [ -n "${CASE:-}" ]; then
  case "$CASE" in
    ruling-refutes-reviewed-all) run_ruling_refutes_reviewed_all; exit 0 ;;
    ruling-refutes-reviewed-partial) run_ruling_refutes_reviewed_partial; exit 0 ;;
    ruling-refutes-reviewed-narrowed) run_ruling_refutes_reviewed_narrowed; exit 0 ;;
    ruling-refutes-reviewed-spent-grant) run_ruling_refutes_reviewed_spent_grant; exit 0 ;;
  esac
fi

# Verification never fetches the PR body or records body provenance.
setup_case body-read-failure
: >"$T/body-fail"
run_verify
[ "$RC" = 0 ] || fail "body-read-failure exited $RC, want FIX-OK: $OUT $(cat "$T/stderr")"
assert_first_verdict FIX-OK 'body-read-failure'
grep -q '^review-pr|' "$T/calls.log" || fail "body-read-failure did not run review-pr: $(cat "$T/calls.log")"
! grep -q -- '--json body' "$T/calls.log" || fail "body-read-failure queried the PR body"
! grep -q '^verify.body_hash=' "$S" || fail "body-read-failure recorded obsolete body provenance"

# FIX-OK records the exact reviewed head and passes the findings delta.
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

# An existing, proven FIX-OK at the exact head is adopted through normal bookkeeping.
setup_case adopt-fix-ok
printf 'behind\n' >"$T/vermode"
write_review_comment 500 "$(git -C "$WT" diff "origin/main...$HEAD" | git patch-id --stable | awk '{print $1}')" "$HEAD" "$OLD" 'FIX-OK all findings repaired'
printf '%s\n' "$HEAD" >"$REFUSAL_HEAD"
run_verify
[ "$RC" = 0 ] || fail "adopted FIX-OK exited $RC: $OUT $(cat "$T/stderr")"
assert_first_verdict FIX-OK 'adopted FIX-OK'
[ "$(read_state reviewed)" = "$HEAD" ] || fail "adoption did not advance reviewed"
[ "$(read_state head)" = "$HEAD" ] || fail "adoption did not preserve exact head"
[ "$(read_state round)" = 1 ] || fail "adoption did not count the P-line round"
[ "$(read_state fixslot)" = 1 ] || fail "adoption did not close the fix-round slot"
[ "$(read_state fix_round.1.start)" = "$OLD" ] || fail "adoption recorded the wrong slot start"
[ "$(read_state fix_round.1.head)" = "$HEAD" ] || fail "adoption recorded the wrong slot head"
[ "$(read_state fix_round.1.findings)" = "$F" ] || fail "adoption recorded the wrong findings file"
[ -r "$(read_state findings_history)" ] || fail "adoption did not write findings history"
grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z tkt-verify ADOPT FIX-OK head=$HEAD since=$OLD comment=500$" "${S%.state}.journal" || fail "adoption journal line differs from the required format"
[ "$(grep -Fc 'tkt-verify ADOPT FIX-OK ' "${S%.state}.journal")" = 1 ] || fail "adoption wrote more than one ADOPT journal line"

# A since-base from an earlier recorded verdict is valid even when it is not `reviewed`.
setup_case adopt-recorded-since
recorded_base="$(git -C "$WT" rev-list --max-parents=0 HEAD)"
set_state reviewed "$recorded_base"
set_state fixslot 1
set_state fix_round.1.head "$OLD"
set_state fix_round.1.history "$RUN/prior-history.md"
printf 'prior verified findings\n' >"$RUN/prior-history.md"
printf 'behind\n' >"$T/vermode"
actual_pid="$(git -C "$WT" diff "origin/main...$HEAD" | git patch-id --stable | awk '{print $1}')"
write_review_comment 506 "$actual_pid" "$HEAD" "$OLD" 'FIX-OK all findings repaired'
printf '%s\n' "$HEAD" >"$REFUSAL_HEAD"
run_verify
[ "$RC" = 0 ] || fail "FIX-OK with a recorded fix-round since-base exited $RC: $OUT $(cat "$T/stderr")"
[ "$(read_state reviewed)" = "$HEAD" ] || fail "recorded since-base adoption did not advance reviewed"
[ "$(read_state fixslot)" = 2 ] || fail "recorded since-base adoption did not allocate the next slot"
grep -Fq "tkt-verify ADOPT FIX-OK head=$HEAD since=$OLD comment=506" "${S%.state}.journal" || fail "recorded since-base adoption journal is missing"

# A granted adoption still consumes the granted round like an ordinary FIX-OK.
setup_case adopt-granted
set_state round 2
write_ruling_comment 980 'grants: round 3'
printf 'behind\n' >"$T/vermode"
actual_pid="$(git -C "$WT" diff "origin/main...$HEAD" | git patch-id --stable | awk '{print $1}')"
write_review_comment 507 "$actual_pid" "$HEAD" "$OLD" 'FIX-OK all findings repaired'
printf '%s\n' "$HEAD" >"$REFUSAL_HEAD"
run_verify_ruling 980
[ "$RC" = 0 ] || fail "granted adoption exited $RC: $OUT $(cat "$T/stderr")"
[ "$(read_state round)" = 3 ] || fail "granted adoption did not count round 3"
[ "$(read_state grant.3)" = '980 https://github.com/switchyard/switchyard/issues/1756#issuecomment-980' ] || fail "granted adoption did not record grant.3"
grep -Fq "tkt-verify ADOPT FIX-OK head=$HEAD since=$OLD comment=507" "${S%.state}.journal" || fail "granted adoption journal is missing"

expect_adoption_refused() {
  local name="$1" detail="$2"
  run_verify
  [ "$RC" = 1 ] || fail "$name exited $RC, want VERIFY-FAIL: $OUT $(cat "$T/stderr")"
  assert_first_verdict 'VERIFY-FAIL rc=2' "$name"
  grep -Fq "failed check: $detail" <<<"$OUT" || fail "$name did not name failed proof $detail: $OUT"
  grep -Fq 'next command:' <<<"$OUT" || fail "$name did not give a next command: $OUT"
  [ "$(read_state reviewed)" = "$OLD" ] || fail "$name changed reviewed"
  [ "$(read_state round)" = 0 ] || fail "$name counted a failed adoption"
}

# Adoption refuses a different comment head, wrong patch-id, non-FIX-OK, bad base and legacy header.
setup_case adopt-newer-verdict-after-legacy
printf 'behind\n' >"$T/vermode"
actual_pid="$(git -C "$WT" diff "origin/main...$HEAD" | git patch-id --stable | awk '{print $1}')"
write_review_comment 508 "$actual_pid" "$HEAD" none 'FIX-OK legacy approval'
append_review_comment 509 "$actual_pid" "$HEAD" "$OLD" 'VERDICT spec: CHANGES'
printf '%s\n' "$HEAD" >"$REFUSAL_HEAD"
run_verify
[ "$RC" = 1 ] || fail "newer CHANGES after legacy FIX-OK exited $RC: $OUT $(cat "$T/stderr")"
grep -Fq 'failed check: newer verdict at head:' <<<"$OUT" || fail "newer CHANGES after legacy FIX-OK did not name newer verdict: $OUT"
[ "$(read_state reviewed)" = "$OLD" ] || fail "newer CHANGES after legacy FIX-OK advanced reviewed"

setup_case adopt-newer-incomplete
printf 'behind\n' >"$T/vermode"
actual_pid="$(git -C "$WT" diff "origin/main...$HEAD" | git patch-id --stable | awk '{print $1}')"
write_review_comment 510 "$actual_pid" "$HEAD" "$OLD" 'FIX-OK all repaired'
append_review_comment 511 "$actual_pid" "$HEAD" "$OLD" 'FIX-INCOMPLETE findings remain'
printf '%s\n' "$HEAD" >"$REFUSAL_HEAD"
run_verify
[ "$RC" = 1 ] || fail "newer FIX-INCOMPLETE after FIX-OK exited $RC: $OUT $(cat "$T/stderr")"
grep -Fq 'failed check: newer verdict at head:' <<<"$OUT" || fail "newer FIX-INCOMPLETE did not name newer verdict: $OUT"
[ "$(read_state reviewed)" = "$OLD" ] || fail "newer FIX-INCOMPLETE after FIX-OK advanced reviewed"

setup_case adopt-head-mismatch
printf 'behind\n' >"$T/vermode"
write_review_comment 501 "$(git -C "$WT" diff "origin/main...$OLD" | git patch-id --stable | awk '{print $1}')" "$OLD" "$OLD" 'FIX-OK all repaired'
printf '%s\n' "$OLD" >"$REFUSAL_HEAD"
expect_adoption_refused head-mismatch 'header head'

setup_case adopt-patch-mismatch
printf 'behind\n' >"$T/vermode"
write_review_comment 502 'ffffffffffffffffffffffffffffffffffffffff' "$HEAD" "$OLD" 'FIX-OK all repaired'
printf '%s\n' "$HEAD" >"$REFUSAL_HEAD"
expect_adoption_refused patch-id-mismatch 'patch-id mismatch'

setup_case adopt-non-fix-ok
printf 'behind\n' >"$T/vermode"
actual_pid="$(git -C "$WT" diff "origin/main...$HEAD" | git patch-id --stable | awk '{print $1}')"
write_review_comment 503 "$actual_pid" "$HEAD" "$OLD" 'FIX-INCOMPLETE findings remain'
printf '%s\n' "$HEAD" >"$REFUSAL_HEAD"
expect_adoption_refused non-fix-ok 'non-FIX-OK verdict'

setup_case adopt-since-gap
printf 'behind\n' >"$T/vermode"
actual_pid="$(git -C "$WT" diff "origin/main...$HEAD" | git patch-id --stable | awk '{print $1}')"
write_review_comment 504 "$actual_pid" "$HEAD" "$HEAD" 'FIX-OK all repaired'
printf '%s\n' "$HEAD" >"$REFUSAL_HEAD"
expect_adoption_refused since-gap 'since-base gap'

setup_case adopt-legacy-no-since
printf 'behind\n' >"$T/vermode"
actual_pid="$(git -C "$WT" diff "origin/main...$HEAD" | git patch-id --stable | awk '{print $1}')"
write_review_comment 505 "$actual_pid" "$HEAD" none 'FIX-OK all repaired'
printf '%s\n' "$HEAD" >"$REFUSAL_HEAD"
expect_adoption_refused legacy-no-since 'header has no since'

# An explicit model replaces model.verify.
setup_case model-override
run_verify_override
[ "$RC" = 0 ] || fail "model override exited $RC: $OUT $(cat "$T/stderr")"
grep -Fq -- "--model override-model" "$T/calls.log" || fail "review-pr did not receive --verify-model"

# A P1 FIX-INCOMPLETE leaves reviewed unchanged, but records the usable open findings.
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

# Bullet-formatted findings are not usable bare rows: fail without persisting output.
setup_case bullet-incomplete
printf 'bullet-incomplete\n' >"$T/vermode"
set_state findings "$F"
run_verify
[ "$RC" = 1 ] || fail "bullet-incomplete exited $RC, want 1: $OUT"
assert_first_verdict 'VERIFY-FAIL reason=no-finding-rows' 'bullet-incomplete'
output_file="$RUN/switchyard-1756-tkt-verify-${HEAD:0:12}.md"
[ ! -e "$output_file" ] || fail "bullet-incomplete wrote a findings file: $(cat "$output_file")"
[ "$(read_state findings)" = "$F" ] || fail "bullet-incomplete changed the findings state key"

# P3-only FIX-INCOMPLETE advances reviewed to the verified head.
setup_case p3-incomplete
printf 'p3-incomplete\n' >"$T/vermode"
run_verify
[ "$RC" = 1 ] || fail "P3-only FIX-INCOMPLETE exited $RC, want 1: $OUT"
assert_first_verdict FIX-INCOMPLETE 'P3-only FIX-INCOMPLETE'
[ "$(read_state reviewed)" = "$HEAD" ] || fail "P3-only FIX-INCOMPLETE did not advance reviewed"
[ "$(read_state findings)" = "$RUN/switchyard-1756-tkt-verify-${HEAD:0:12}.md" ] \
  || fail "P3-only FIX-INCOMPLETE did not store its verify output path"
grep -Fq 'P3 src/main.sh:3 — non-blocking finding' "$(read_state findings)" \
  || fail "P3-only FIX-INCOMPLETE lost its bare P3 row"

# An open P2 beside a P3 keeps reviewed at the prior head.
setup_case p2-incomplete
printf 'p2-incomplete\n' >"$T/vermode"
run_verify
[ "$RC" = 1 ] || fail "P2 FIX-INCOMPLETE exited $RC, want 1: $OUT"
assert_first_verdict FIX-INCOMPLETE 'P2 FIX-INCOMPLETE'
[ "$(read_state reviewed)" = "$OLD" ] || fail "P2 FIX-INCOMPLETE changed reviewed"

# A fixed P2 under a Fixed heading does not block reviewed from advancing, even
# when review-pr's digest has no ## verify heading.
setup_case p2-fixed-p3-incomplete
printf 'p2-fixed-p3-incomplete\n' >"$T/vermode"
run_verify
[ "$RC" = 1 ] || fail "fixed-P2 FIX-INCOMPLETE exited $RC, want 1: $OUT"
assert_first_verdict FIX-INCOMPLETE 'fixed-P2 FIX-INCOMPLETE'
[ "$(read_state reviewed)" = "$HEAD" ] || fail "fixed P2 prevented reviewed from advancing"
fixed_p2_file="$RUN/switchyard-1756-tkt-verify-${HEAD:0:12}.md"
grep -Fq 'P2 src/main.sh:2: fixed.' "$fixed_p2_file" || fail "fixed P2 row was not preserved"
grep -Fq 'P3 src/main.sh:3 — non-blocking finding' "$fixed_p2_file" || fail "open P3 row was not preserved"

# An open P2 under a Fixed heading, with no `: fixed.` suffix, still holds reviewed.
setup_case p2-open-under-fixed
printf 'p2-open-under-fixed\n' >"$T/vermode"
run_verify
[ "$RC" = 1 ] || fail "open-P2-under-Fixed exited $RC, want 1: $OUT"
assert_first_verdict FIX-INCOMPLETE 'open-P2-under-Fixed FIX-INCOMPLETE'
[ "$(read_state reviewed)" = "$OLD" ] || fail "open P2 under a Fixed heading advanced reviewed"

# P0 plus P3 remains incomplete and leaves reviewed unchanged; both rows persist.
setup_case p0-p3-incomplete
printf 'p0-p3-incomplete\n' >"$T/vermode"
run_verify
[ "$RC" = 1 ] || fail "P0+P3 FIX-INCOMPLETE exited $RC, want 1: $OUT"
assert_first_verdict FIX-INCOMPLETE 'P0+P3 FIX-INCOMPLETE'
[ "$(read_state reviewed)" = "$OLD" ] || fail "P0+P3 FIX-INCOMPLETE changed reviewed"
grep -Fq 'P0 src/main.sh:0 — critical finding' <<<"$OUT" || fail "P0 digest row missing: $OUT"
p0_p3_file="$RUN/switchyard-1756-tkt-verify-${HEAD:0:12}.md"
grep -Fq 'P0 src/main.sh:0 — critical finding' "$p0_p3_file" || fail "P0+P3 findings file lost the P0 row"

# P0-only FIX-INCOMPLETE is recorded, not rejected as missing bare finding rows.
setup_case p0-only-incomplete
printf 'p0-only-incomplete\n' >"$T/vermode"
run_verify
[ "$RC" = 1 ] || fail "P0-only FIX-INCOMPLETE exited $RC, want 1: $OUT"
assert_first_verdict FIX-INCOMPLETE 'P0-only FIX-INCOMPLETE'
[ "$(read_state reviewed)" = "$OLD" ] || fail "P0-only FIX-INCOMPLETE changed reviewed"
p0_only_file="$RUN/switchyard-1756-tkt-verify-${HEAD:0:12}.md"
[ "$(read_state findings)" = "$p0_only_file" ] || fail "P0-only FIX-INCOMPLETE did not store findings"
grep -Fq 'P0 src/main.sh:0 — critical finding' "$p0_only_file" || fail "P0-only findings file lost the P0 row"
grep -Fq 'P0 src/main.sh:0 — critical finding' <<<"$OUT" || fail "P0-only digest row missing: $OUT"

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

if [ -z "${CASE:-}" ]; then
  run_ruling_refutes_reviewed_all
  run_ruling_refutes_reviewed_partial
  run_ruling_refutes_reviewed_narrowed
  run_ruling_refutes_reviewed_spent_grant
fi

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

# Reverify cannot bypass the round cap when the recorded findings still have open P-lines.
setup_case reverify-round-limit
set_state reviewed "$HEAD"
set_state round 2
set_state verify.head "$HEAD"
set_state verify.findings "$F"
set_state verify.since "$OLD"
set_state verify.body_hash prior-body-hash
set_state verify.model state-verify-model
set_state verify.slot 1
run_reverify openai/gpt-6.1-sol
[ "$RC" = 1 ] || fail "reverify-round-limit exited $RC, want 1: $OUT $(cat "$T/stderr")"
assert_first_verdict ROUND-LIMIT 'reverify-round-limit'
assert_no_review 'reverify-round-limit'
[ "$(read_state round)" = 2 ] || fail "reverify-round-limit changed the round"

# A grant records its round in state and journal, never as a PR-body requirement.
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
grep -Fq 'Recorded round grant: https://github.com/switchyard/switchyard/issues/1756#issuecomment-900 (round 3)' <<<"$OUT" || fail "grant output omitted the state-backed round grant"
! grep -Fq 'add this line to the PR body' <<<"$OUT" || fail "grant output still asks for a PR-body edit"
: >"$T/calls.log"
run_verify_ruling 900
[ "$RC" = 2 ] || fail "reuse exited $RC, want 2: $OUT"
grep -Fq 'RULING-REFUSED reason=reused comment=900' <<<"$OUT" || fail "reuse was not refused as reused: $OUT"
grep -Fq 'grant comment 900 has already been consumed; post a new ruling comment' <<<"$OUT" || fail "reuse did not explain that a new ruling comment is needed: $OUT"
assert_no_review reuse
: >"$T/calls.log"
run_verify
[ "$RC" = 1 ] || fail "next round without a grant exited $RC, want ROUND-LIMIT: $OUT"
assert_first_verdict ROUND-LIMIT 'next round without grant'
grep -Fq 'round=3' <<<"$OUT" || fail "next round hint omitted the current round: $OUT"
assert_no_review 'next round without grant'
fi

# A separate refutes comment is staged with a valid round grant and marks only
# the copied findings file passed to review-pr. The grant-only path above stays
# unchanged, including its round count and journal record.
setup_case grant-with-separate-refutes
set_state round 2
write_ruling_comment 920 $'context\ngrants: round 3'
write_ruling_comment 921 'refutes: P1 src/main.sh:1'
printf 'incomplete\n' >"$T/vermode"
run_verify_rulings 920 921
[ "$RC" = 1 ] || fail "grant plus separate refutes exited $RC, want FIX-INCOMPLETE: $OUT $(cat "$T/stderr")"
assert_first_verdict FIX-INCOMPLETE 'grant plus separate refutes'
awk '/^P1 src\/main.sh:1 — initial finding$/ { if (getline <= 0 || $0 !~ /^refuted: recorded ruling https:\/\/github.com\/switchyard\/switchyard\/issues\/1756#issuecomment-921 \(refutes: P1 src\/main.sh:1\); text in \.review-context\/ruling-921\.md$/) exit 1; found=1 } END { exit !found }' \
  "$T/verify-input.md" || fail "separate refutes ruling did not mark its open row"
grep -Fq -- "--context $T/tmp/tkt-verify." "$T/calls.log" || fail "separate refutes ruling was not passed with --context"
grep -Fq 'refutes: P1 src/main.sh:1' "$T/context-ruling-921.md" || fail "separate refutes body was not staged as ruling-921.md"
! grep -q '^refuted:' "$F" || fail "tkt-verify modified the caller's findings file"
[ "$(read_state round)" = 3 ] || fail "separate refutes grant did not count round 3"
[ "$(read_state grant.3)" = '920 https://github.com/switchyard/switchyard/issues/1756#issuecomment-920' ] || fail "separate refutes grant was not recorded"
grep -Fq 'ruling https://github.com/switchyard/switchyard/issues/1756#issuecomment-921 refutes P1 src/main.sh:1' "${S%.state}.journal" || fail "separate refutes ruling was not journalled"

# A PR-body finding stays filtered when a separate finding is refuted.
setup_case ruling-refutes-body-finding
printf 'P2 .review-context/pr-body.md:2 — generated text\nP1 src/main.sh:1 — initial finding\n' >"$F"
write_ruling_comment 923 'refutes: P1 src/main.sh:1'
run_verify_ruling 923
[ "$RC" = 0 ] || fail "ruling-refutes-body-finding exited $RC, want 0: $OUT $(cat "$T/stderr")"
! grep -Fq '.review-context/pr-body.md' "$T/verify-input.md" || fail "ruling-refutes-body-finding passed a body-only finding to verify"
grep -Fxq 'P1 src/main.sh:1 — initial finding' "$T/verify-input.md" \
  || fail "ruling-refutes-body-finding dropped the code finding"
grep -Fq 'refuted: recorded ruling https://github.com/switchyard/switchyard/issues/1756#issuecomment-923' "$T/verify-input.md" \
  || fail "ruling-refutes-body-finding did not mark the code finding"

# A legacy body-only refutation becomes a no-op instead of blocking verify.
setup_case ruling-refutes-body-only
printf 'P2 PR-body:2 — generated text\n' >"$F"
write_ruling_comment 924 'refutes: P2 PR-body:2'
run_verify_ruling 924
[ "$RC" = 0 ] || fail "ruling-refutes-body-only exited $RC, want 0: $OUT $(cat "$T/stderr")"
! grep -Fq 'RULING-REFUSED' <<<"$OUT" || fail "ruling-refutes-body-only refused a dropped body finding: $OUT"
grep -Fxq 'no open findings' "$T/verify-input.md" \
  || fail "ruling-refutes-body-only did not verify with no open findings"

# A valid-shaped refutes prefix with no finding is refused before review.
setup_case ruling-refutes-no-match
write_ruling_comment 922 'refutes: P2 absent.sh:9'
run_verify_rulings 922
[ "$RC" = 2 ] || fail "ruling-refutes-no-match exited $RC, want 2: $OUT"
assert_first_verdict 'RULING-REFUSED reason=no-match comment=922' 'ruling-refutes-no-match'
grep -Fq "Use a column-0 \`refutes: <row prefix>\` line; the prefix starts with \`P<n> \`, ends where the row has a space, a \`:\`, or a \`,\`, \`.\` or \`;\` followed by a space or the row's end, and matches exactly one open row. Put any reason on the next line." <<<"$OUT" || fail "ruling-refutes-no-match form hint is missing: $OUT"
assert_no_review 'ruling-refutes-no-match'
assert_no_slot 'ruling-refutes-no-match'
! grep -q '^refuted:' "$F" || fail "ruling-refutes-no-match modified the caller's findings file"

# An open history-only row is not valid evidence for verify, which marks only --findings.
setup_case ruling-refutes-history-only
write_ruling_comment 925 'refutes: P2 history-only.sh:9'
history_file="$CASE_DIR/findings-history.md"
printf '# Findings history\nP2 history-only.sh:9 — old finding [tkt-history: raised=review round 0; status=open; unverified=none]\n' >"$history_file"
set_state findings_history "$history_file"
run_verify_rulings 925
[ "$RC" = 2 ] || fail "ruling-refutes-history-only exited $RC, want 2: $OUT"
assert_first_verdict 'RULING-REFUSED reason=no-match comment=925' 'ruling-refutes-history-only'
assert_no_review 'ruling-refutes-history-only'
assert_no_slot 'ruling-refutes-history-only'
! grep -q '^refuted:' "$F" || fail "ruling-refutes-history-only modified the caller's findings file"

# Trailing reason prose is not part of a row prefix, so validation refuses before review.
setup_case ruling-refutes-trailing-prose
write_ruling_comment 924 'refutes: P1 src/main.sh:1 — initial finding because it is safe'
run_verify_ruling 924
[ "$RC" = 2 ] || fail "ruling-refutes-trailing-prose exited $RC, want 2: $OUT"
assert_first_verdict 'RULING-REFUSED reason=no-match comment=924' 'ruling-refutes-trailing-prose'
grep -Fq "Use a column-0 \`refutes: <row prefix>\` line; the prefix starts with \`P<n> \`, ends where the row has a space, a \`:\`, or a \`,\`, \`.\` or \`;\` followed by a space or the row's end, and matches exactly one open row. Put any reason on the next line." <<<"$OUT" || fail "ruling-refutes-trailing-prose form hint is missing: $OUT"
assert_no_review 'ruling-refutes-trailing-prose'
assert_no_slot 'ruling-refutes-trailing-prose'

# Invalid refutes syntax keeps the same refusal as tkt-fix.
setup_case ruling-bad-refutes
write_ruling_comment 923 'refutes: P2'
run_verify_rulings 923
[ "$RC" = 2 ] || fail "ruling-bad-refutes exited $RC, want 2: $OUT"
assert_first_verdict 'RULING-REFUSED reason=bad-refutes comment=923' 'ruling-bad-refutes'
assert_no_review 'ruling-bad-refutes'
assert_no_slot 'ruling-bad-refutes'

# Resetting grant keys opens a fresh review cycle: the old comment is stale,
# rounds 1 and 2 run again, and a new round-3 grant can be consumed.
if [ -z "${CASE:-}" ] || [ "$CASE" = grant-cycle-reset ]; then
setup_case grant-cycle-reset
set_state round 2
set_state verdict_at '2026-11-10T00:00:00Z'
write_ruling_comment 940 'grants: round 3' OWNER 1756 '2026-11-11T00:00:00Z'
printf 'incomplete\n' >"$T/vermode"
run_verify_ruling 940
[ "$RC" = 1 ] || fail "grant-cycle-reset initial grant exited $RC: $OUT"
assert_first_verdict FIX-INCOMPLETE 'grant-cycle-reset initial grant'
[ "$(read_state round)" = 3 ] || fail "grant-cycle-reset initial grant did not count round 3"
[ "$(read_state grant.3)" != '' ] || fail "grant-cycle-reset initial grant was not stored"

bash "$TKT_STATE" "$S" unset grants || fail "grant-cycle-reset clears previous grant keys"
set_state round 0
set_state verdict_at '2026-11-15T00:00:00Z'
assert_no_grant 'grant-cycle-reset after reset'
grep -Fq 'ruling https://github.com/switchyard/switchyard/issues/1756#issuecomment-940 grants round 3' "${S%.state}.journal" || fail "grant-cycle-reset did not retain the grant journal record"
run_verify
[ "$RC" = 1 ] || fail "grant-cycle-reset round 1 exited $RC: $OUT"
assert_first_verdict FIX-INCOMPLETE 'grant-cycle-reset round 1'
[ "$(read_state round)" = 1 ] || fail "grant-cycle-reset did not count round 1"
run_verify
[ "$RC" = 1 ] || fail "grant-cycle-reset round 2 exited $RC: $OUT"
assert_first_verdict FIX-INCOMPLETE 'grant-cycle-reset round 2'
[ "$(read_state round)" = 2 ] || fail "grant-cycle-reset did not count round 2"
set_state verdict_at '2026-11-15T00:00:00Z'
: >"$T/calls.log"
run_verify_ruling 940
[ "$RC" = 2 ] || fail "grant-cycle-reset old grant after reset exited $RC, want 2: $OUT"
grep -Fq 'RULING-REFUSED reason=stale comment=940' <<<"$OUT" || fail "grant-cycle-reset old grant after reset was not stale: $OUT"
grep -Fq 'post a new ruling comment with `grants: round 3`' <<<"$OUT" || fail "grant-cycle-reset stale refusal did not say a new ruling comment is needed: $OUT"
assert_no_review 'grant-cycle-reset old grant after reset'
[ "$(read_state round)" = 2 ] || fail "grant-cycle-reset old grant after reset changed round"
write_ruling_comment 941 'grants: round 3' OWNER 1756 '2026-11-16T00:00:00Z'
printf 'incomplete\n' >"$T/vermode"
run_verify_ruling 941
[ "$RC" = 1 ] || fail "grant-cycle-reset fresh grant exited $RC: $OUT $(cat "$T/stderr")"
assert_first_verdict FIX-INCOMPLETE 'grant-cycle-reset fresh grant'
[ "$(read_state round)" = 3 ] || fail "grant-cycle-reset fresh grant did not count round 3"
[ "$(read_state grant.3)" = '941 https://github.com/switchyard/switchyard/issues/1756#issuecomment-941' ] || fail "grant-cycle-reset fresh grant did not replace grant.3"
: >"$T/calls.log"
run_verify_ruling 940
[ "$RC" = 2 ] || fail "grant-cycle-reset old grant after fresh acceptance exited $RC, want 2: $OUT"
grep -Fq 'RULING-REFUSED reason=stale comment=940' <<<"$OUT" || fail "grant-cycle-reset old grant after fresh acceptance was not stale: $OUT"
assert_no_review 'grant-cycle-reset old grant after fresh acceptance'
[ "$(read_state round)" = 3 ] || fail "grant-cycle-reset old grant changed round after fresh acceptance"
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
[ "$(grep -c ' grants round 3$' "${S%.state}.journal")" = 1 ] || fail "grant retry repeated the grant journal record"
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
grep -Fq 'state round=2; this grant must read `grants: round 3` on a single line' <<<"$OUT" || fail "grant-bad-form hint is missing: $OUT"

setup_case grant-not-limited
set_state round 1
write_ruling_comment 914 'grants: round 2'
expect_grant_refused not-limited not-limited 914 1

setup_case grant-multiple-lines
set_state round 2
write_ruling_comment 915 $'grants: round 3\ngrants: round 3'
expect_grant_refused multiple-lines bad-grant 915
grep -Fq 'state round=2; this grant must read `grants: round 3` on a single line' <<<"$OUT" || fail "grant-multiple-lines hint is missing: $OUT"

setup_case grant-multiple-comments
set_state round 2
write_ruling_comment 950 'grants: round 3'
write_ruling_comment 951 'grants: round 3'
run_verify_rulings 950 951
[ "$RC" = 2 ] || fail "multiple grant rulings exited $RC, want 2: $OUT"
grep -Fq 'RULING-REFUSED reason=bad-grant comment=950' <<<"$OUT" || fail "multiple grant rulings did not refuse bad-grant: $OUT"
grep -Fq 'only one grants-bearing ruling per run' <<<"$OUT" || fail "multiple grant rulings did not explain the one-grant limit: $OUT"
assert_no_review 'multiple grant rulings'
assert_no_grant 'multiple grant rulings'
[ "$(read_state round)" = 2 ] || fail "multiple grant rulings changed round"
fi

# A PR-body edit or an unavailable body does not constrain re-verification.
setup_case reverify-body-only
set_state model.fix claude/claude-sonnet-5-5
run_verify
[ "$RC" = 0 ] || fail "reverify-body-only initial FIX-OK exited $RC: $OUT $(cat "$T/stderr")"
[ "$(read_state round)" = 1 ] || fail "reverify-body-only initial verify did not count its round"
recorded_findings="$(read_state verify.findings 2>/dev/null || true)"
[ -n "$recorded_findings" ] && [ -r "$recorded_findings" ] \
  || fail "reverify-body-only initial verify did not save its findings"
cmp -s "$F" "$recorded_findings" \
  || fail "reverify-body-only saved findings differ from the initial verify input"
printf 'updated body with a P3 disposition\n' >"$PR_BODY"
grep -v '^verify[.]body_hash=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
touch "$T/body-fail"
printf 'p3-incomplete\n' >"$T/vermode"
run_reverify
[ "$RC" = 1 ] || fail "reverify-body-only exited $RC, want FIX-INCOMPLETE: $OUT $(cat "$T/stderr")"
assert_first_verdict FIX-INCOMPLETE 'reverify-body-only'
[ "$(read_state reviewed)" = "$HEAD" ] || fail "reverify-body-only changed the reviewed head"
[ "$(read_state round)" = 1 ] || fail "reverify-body-only changed the round count"
[ "$(read_state verify.findings)" = "$recorded_findings" ] || fail "reverify-body-only did not reuse the last findings file"
[ "$(read_state verify.since)" = "$OLD" ] || fail "reverify-body-only did not reuse the last --since"
[ "$(read_state verify.head)" = "$HEAD" ] || fail "reverify-body-only did not record the reviewed head"
[ "$(read_state verify.model)" = openai/gpt-6.1-sol ] || fail "reverify-body-only did not record the new model"
! grep -q '^verify.body_hash=' "$S" || fail "reverify-body-only recreated obsolete body provenance"
grep -Fq -- "--head $HEAD --model openai/gpt-6.1-sol --verify $recorded_findings --since $OLD" "$T/calls.log" \
  || fail "reverify-body-only did not use the recorded head, findings and since: $(cat "$T/calls.log")"
journal="${S%.state}.journal"
! grep -Fq 'reason=body' "$journal" || fail "reverify-body-only journal treated a body change as process"
! grep -q -- '--json body' "$T/calls.log" || fail "reverify-body-only queried the PR body"
verify_pid="$(git -C "$WT" diff "origin/main...$HEAD" | git patch-id --stable | awk '{print $1}')"
write_review_comment 700 "$verify_pid" "$HEAD" "$OLD" 'FIX-OK all findings repaired'
append_review_comment 701 "$verify_pid" "$HEAD" "$OLD" $'FIX-INCOMPLETE round=1\nP3 src/main.sh:3 — non-blocking body finding'
# Ship and adoption consume the newest trusted verify comment for this patch.
. "$REAL_BIN/lib/verify-section.sh"
. "$REAL_BIN/lib/review-verdict.sh"
ship_verdict="$(review_verdict switchyard 17 "$verify_pid")"
case "$ship_verdict" in incomplete-p3*) ;; *) fail "reverify-body-only newest FIX-INCOMPLETE did not supersede FIX-OK: $ship_verdict" ;; esac

# A reverify does not need a PR-body read or body provenance.
printf 'ok\n' >"$T/vermode"
run_reverify
[ "$RC" = 0 ] || fail "reverify-ok exited $RC, want FIX-OK: $OUT $(cat "$T/stderr")"
assert_first_verdict FIX-OK 'reverify-ok'
[ "$(read_state round)" = 1 ] || fail "reverify-ok changed the round count"
tail -n 1 "$journal" | grep -Eq " tkt-verify REVERIFY from=openai/gpt-6\.1-sol to=openai/gpt-6\.1-sol$" \
  || fail "reverify-ok journal line wrong: $(cat "$journal")"

# A reverify model in the implementer's family is refused before dispatch.
: >"$T/calls.log"
run_reverify claude-haiku-5-5
[ "$RC" = 2 ] || fail "reverify-family exited $RC, want 2: $OUT $(cat "$T/stderr")"
assert_first_verdict 'PRECONDITION model-family=claude' 'reverify-family'
assert_no_review 'reverify-family'

# Reverify refuses a head other than the one already reviewed.
setup_case reverify-head-mismatch
run_reverify
[ "$RC" = 2 ] || fail "reverify-head-mismatch exited $RC, want 2: $OUT $(cat "$T/stderr")"
assert_first_verdict 'PRECONDITION reverify=head-mismatch' 'reverify-head-mismatch'
assert_no_review 'reverify-head-mismatch'

# Same-family verification dispatch is refused for a pre-guard synthetic state.
setup_case model-family-dispatch
set_state model.lane openai/gpt-6.1-sol
set_state model.verify codex/gpt-6-luna:medium
run_verify
[ "$RC" = 2 ] || fail "model-family-dispatch exited $RC, want 2: $OUT $(cat "$T/stderr")"
assert_first_verdict 'PRECONDITION model-family=codex' 'model-family-dispatch'
grep -Fq 'model.verify=codex/gpt-6-luna:medium' <<<"$OUT" || fail "model-family-dispatch omitted verify model id: $OUT"
grep -Fq 'model.lane=openai/gpt-6.1-sol' <<<"$OUT" || fail "model-family-dispatch omitted lane model id: $OUT"
assert_no_review 'model-family-dispatch'
assert_no_slot 'model-family-dispatch'

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

# An unruled Sonnet verify passes its ruling through to delegate.
SONNET_RULING='https://github.com/example/repo/issues/1#issuecomment-1'
setup_case sonnet-ruling
set_state model.verify claude-sonnet-5-5
set_state ruling.verify "$SONNET_RULING"
run_verify
[ "$RC" = 0 ] || fail "ruled Sonnet verify exited $RC: $OUT $(cat "$T/stderr")"
grep -Fq -- "--model claude-sonnet-5-5" "$T/calls.log" || fail "Sonnet verify model reaches review-pr"
grep -Fq -- "--model-ruling $SONNET_RULING" "$T/calls.log" || fail "ruling.verify reaches review-pr"
! grep -Fq "$SONNET_RULING" "${S%.state}.journal" || fail "verify ruling is not journalled"

# Without ruling.verify, review-pr's refusal reaches tkt-verify.
setup_case sonnet-ruling-refusal
set_state model.verify claude-sonnet-5-5
set_state ruling.review "$SONNET_RULING"
run_verify
[ "$RC" = 1 ] || fail "unruled Sonnet verify returns VERIFY-FAIL (rc=$RC)"
assert_first_verdict VERIFY-FAIL 'unruled Sonnet verify'
grep -Fq -- '--model-ruling <comment URL>' "$T/stderr" || fail "unruled Sonnet verify surfaces the remedy"
[ ! -e "${S%.state}.journal" ] || ! grep -Fq "$SONNET_RULING" "${S%.state}.journal" || fail "wrong-slot verify ruling is not journalled"

echo 'tkt-verify: all cases passed'

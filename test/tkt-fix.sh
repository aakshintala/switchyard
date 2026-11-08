#!/usr/bin/env bash
# Tests for bin/tkt-fix: one review-loop fix round.
# Stubs tkt-job, gh-ci and review-pr on a temp TKT_BIN; symlinks there reach
# the real tkt-gate, tkt-state and lib/. The stub tkt-job makes the fix
# commit itself in the worktree (like a real job), so the drift check at
# tkt-fix start sees a clean entry. A stub gh serves the worktree HEAD for
# the gate's PR-head check. Real git on throwaway repos with a bare origin,
# so the push step runs for real. HOME and TMPDIR point at temp dirs;
# nothing reads the real $HOME/.agents and no test touches the network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TKT="$SCRIPT_DIR/../bin/tkt-fix"
REAL_BIN="$SCRIPT_DIR/../bin"
TKT_STATE="$REAL_BIN/tkt-state"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-tkt-fix.XXXXXX")"
T="$(cd "$T" && pwd)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp" "$T/bin" "$T/cases"
export HOME="$T/home" TMPDIR="$T/tmp" XDG_CACHE_HOME="$T/cache" TKT_BIN="$T/bin"
export PATH="$T/bin:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

ln -s "$REAL_BIN/tkt-gate" "$T/bin/tkt-gate" || fail "symlink tkt-gate"
ln -s "$REAL_BIN/plan-gate" "$T/bin/plan-gate" || fail "symlink plan-gate"
ln -s "$REAL_BIN/fill-brief" "$T/bin/fill-brief" || fail "symlink fill-brief"
ln -s "$REAL_BIN/tkt-state" "$T/bin/tkt-state" || fail "symlink tkt-state"
ln -s "$REAL_BIN/lib" "$T/bin/lib" || fail "symlink lib"
ln -s "$REAL_BIN/fence-grant" "$T/bin/fence-grant" || fail "symlink fence-grant"
# Lane and fix slots need a fence grant (test/tkt-job.sh covers that); these cases test the fix flow.
export FW_NO_FENCE="test/tkt-fix.sh exercises the fix flow, not the fence"

# Stub tkt-job: $T/jobmode holds done (commit fix.txt with "fixed-<n>", a
# per-call counter, exit 0), pushed (exit 0, no commit: the job pushed
# itself), no-commits (exit 1), evil (commit evil.txt, exit 0), ask (exit 1),
# partial (commit fix.txt with "partial", exit 1) or unknown (exit 3).
# Records job.<slot>=j1 in state at dispatch, like the real tkt-job. Logs its
# full argument list for slot assertions.
printf 'done' >"$T/jobmode"
printf '0' >"$T/jobcount"
cat >"$T/bin/tkt-job" <<EOF
#!/usr/bin/env bash
printf 'job|%s\n' "\$*" >>"$T/calls.log"
state="\$1"
slot=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "--slot" ]; then slot="\$a"; fi
  prev="\$a"
done
[ -n "\$slot" ] && "$TKT_STATE" "\$state" set "job.\$slot" j1 >/dev/null
wt="\$("$TKT_STATE" "\$state" get worktree)"
commit_as_job() {
  printf '%s' "\$2" >"\$wt/\$1"
  git -C "\$wt" add "\$1"
  git -C "\$wt" -c user.email=t@t -c user.name=t commit -qm "fix: \$1"
}
case "\$(cat "$T/jobmode")" in
  done)
    n="\$((\$(cat "$T/jobcount") + 1))"
    printf '%s' "\$n" >"$T/jobcount"
    commit_as_job fix.txt "fixed-\$n"
    echo "TKT tkt-job DONE id=j1 head=h commits=1 gate=PASS log=x";;
  stalled)
    commit_as_job fix.txt "stalled"
    echo "TKT tkt-job NEEDS_CONTEXT id=j1 log=x"
    exit 1;;
  pushed) echo "TKT tkt-job DONE id=j1 head=h commits=1 gate=PASS log=x";;
  no-commits)
    echo "TKT tkt-job NO-COMMITS id=j1 gate=PASS log=x"
    exit 1;;
  evil) commit_as_job evil.txt "outside"; echo "TKT tkt-job DONE id=j1 head=h commits=1 gate=PASS log=x";;
  ask)
    echo "TKT tkt-job ASK id=j1 log=x"
    echo "which design rules the retry?"
    exit 1;;
  partial)
    commit_as_job fix.txt "partial"
    # Like the real tkt-job: the concerns file is saved and keyed by slot.
    cf="\$("$TKT_STATE" "\$state" get run)/switchyard-529-concerns-\$slot.md"
    printf 'fix job is unsure about X\n' >"\$cf"
    "$TKT_STATE" "\$state" set "concerns.\$slot" "\$cf" >/dev/null
    echo "TKT tkt-job CONCERNS id=j1 log=x"
    exit 1;;
  unknown)
    echo "TKT tkt-job UNKNOWN id=j1 log=x"
    exit 3;;
  stale-resume)
    echo "delegate resume j1: unknown job j1 (record missing)" >&2
    exit 2;;
  stderr-only)
    echo 'tkt-job refused: missing required context' >&2
    exit 3;;
  no-output) exit 3;;
esac
exit 0
EOF
chmod +x "$T/bin/tkt-job"
cp "$T/bin/tkt-job" "$T/tkt-job-stub"

# Stub gh-ci: $T/cimode holds the wait exit (0 or 1); $T/ciout holds stdout.
printf '0' >"$T/cimode"
: >"$T/ciout"
cat >"$T/bin/gh-ci" <<EOF
#!/usr/bin/env bash
printf 'gh-ci|%s\n' "\$*" >>"$T/calls.log"
if [ "\${1:-}" = "wait" ]; then cat "$T/ciout"; exit "\$(cat "$T/cimode")"; fi
exit 0
EOF
chmod +x "$T/bin/gh-ci"

# Stub review-pr: $T/vermode holds ok (FIX-OK), incomplete or history outputs.
printf 'ok' >"$T/vermode"
printf '0' >"$T/verify-count"
cat >"$T/bin/review-pr" <<EOF
#!/usr/bin/env bash
printf 'review-pr|%s\n' "\$*" >>"$T/calls.log"
verify_file=""; previous=""
for arg in "\$@"; do
  if [ "\$previous" = "--verify" ]; then verify_file="\$arg"; fi
  previous="\$arg"
done
if [ -n "\$verify_file" ]; then
  n="\$((\$(cat "$T/verify-count") + 1))"
  printf '%s' "\$n" >"$T/verify-count"
  cp "\$verify_file" "$T/verify-input-\$n.md"
fi
case "\$(cat "$T/vermode")" in
  ok|history-two) printf 'FIX-OK\n';;
  incomplete)
    printf 'FIX-INCOMPLETE round=2\nP1 open finding in fix.txt\nP2 second finding\n';;
  history-one)
    printf 'FIX-INCOMPLETE round=1\nP1 finding raised in round 1\n';;
esac
exit 0
EOF
chmod +x "$T/bin/review-pr"

# Stub gh: $T/prhead holds WT:<dir> (serve that worktree's HEAD) or
# ORIGIN:<gitdir>:<ref> (serve that ref, tracking pushes) for the PR-head
# drift checks in tkt-fix and the gate.
cat >"$T/bin/gh" <<EOF
#!/usr/bin/env bash
printf 'gh|%s\n' "\$*" >>"$T/calls.log"
case " \$* " in *" pr list "*)
  cat "$T/prlist"
  exit "\$(cat "$T/prlistrc")";;
  *" headRefOid "*)
  content="\$(cat "$T/prhead")"
  case "\$content" in
    WT:*) git -C "\${content#WT:}" rev-parse HEAD;;
    ORIGIN:*) rest="\${content#ORIGIN:}"; git --git-dir="\${rest%:*}" rev-parse --verify "\${rest##*:}";;
    *) printf '%s' "\$content";;
  esac;;
esac
exit 0
EOF
chmod +x "$T/bin/gh"

reset_stubs() {
  printf 'done' >"$T/jobmode"
  printf '0' >"$T/jobcount"
  printf '0' >"$T/cimode"
  : >"$T/ciout"
  printf 'ok' >"$T/vermode"
  printf '0' >"$T/verify-count"
  printf '[]' >"$T/prlist"
  printf '0' >"$T/prlistrc"
  : >"$T/calls.log"
}

# New case: a bare origin, a seed main, and a clone worktree on branch
# tkt-529 pushed to the origin, with plan, findings and base state. Sets
# CDIR, WT, S. $1 is the case name.
setup_case() {
  cp "$T/tkt-job-stub" "$T/bin/tkt-job"
  unset JOB_RECORD_SYSTEM_DIR DELEGATE_JOBS_DIR
  CDIR="$T/cases/$1"
  mkdir -p "$CDIR/run"
  git init -q --bare "$CDIR/origin.git"
  git --git-dir="$CDIR/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q "$CDIR/seed"
  git -C "$CDIR/seed" symbolic-ref HEAD refs/heads/main
  git -C "$CDIR/seed" config user.email t@t
  git -C "$CDIR/seed" config user.name t
  printf 'base\n' >"$CDIR/seed/base.txt"
  git -C "$CDIR/seed" add base.txt
  git -C "$CDIR/seed" commit -qm init
  git -C "$CDIR/seed" remote add origin "$CDIR/origin.git"
  git -C "$CDIR/seed" push -q origin main
  WT="$CDIR/wt"
  git clone -q "$CDIR/origin.git" "$WT"
  git -C "$WT" config user.email t@t
  git -C "$WT" config user.name t
  git -C "$WT" checkout -qb tkt-529
  git -C "$WT" push -q origin tkt-529
  cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `base.txt`
- `fix.txt`

## Gate

`true`
EOF
  printf 'P1 heading from review\n' >"$CDIR/findings.md"
  OLD="$(git -C "$WT" rev-parse HEAD)"
  S="$CDIR/tkt.state"
  {
    printf 'repo=%s\n' switchyard
    printf 'issue=%s\n' 529
    printf 'pr=%s\n' 7
    printf 'branch=%s\n' tkt-529
    printf 'worktree=%s\n' "$WT"
    printf 'run=%s\n' "$CDIR/run"
    printf 'plan=%s\n' "$CDIR/plan.md"
    printf 'findings=%s\n' "$CDIR/findings.md"
    printf 'reviewed=%s\n' "$OLD"
    printf 'head=%s\n' "$OLD"
    printf 'round=%s\n' 0
    printf 'model.fix=%s\n' fix-model
    printf 'model.verify=%s\n' verify-model
  } >"$S"
  printf 'WT:%s' "$WT" >"$T/prhead"
  reset_stubs
}

expect_slot() {
  grep -q "job|.*--slot $1" "$T/calls.log" || fail "expected tkt-job slot $1 (log: $(cat "$T/calls.log"))"
}

drop_state_key() {
  grep -v "^$1=" "$S" >"$S.tmp" && mv "$S.tmp" "$S"
}

record_test_round() {
  local n="$1" head="$2" part suffix="" source path start=""
  part="$(bash "$TKT_STATE" "$S" get part 2>/dev/null || true)"
  case "$part" in ''|*[!0-9]*) ;; *) [ "$part" -ge 2 ] && suffix="-part$part";; esac
  source="$(bash "$TKT_STATE" "$S" get findings)"
  path="$CDIR/run/switchyard-529$suffix-fix-round-$n-findings.md"
  cp "$source" "$path" || fail "record test round findings"
  if [ "$n" -gt 1 ]; then start="$(bash "$TKT_STATE" "$S" get "fix_round.$((n - 1)).head" 2>/dev/null || true)"; fi
  [ -n "$start" ] || start="$OLD"
  bash "$TKT_STATE" "$S" set "fix_round.$n.start" "$start" >/dev/null
  bash "$TKT_STATE" "$S" set "fix_round.$n.findings" "$path" >/dev/null
  bash "$TKT_STATE" "$S" set "fix_round.$n.head" "$head" >/dev/null
}

# Selector for the new cases below: empty or unset runs all of them.
want() { [ -z "${CASE:-}" ] || [ "$CASE" = "$1" ]; }

# History: a later verify receives round 0's finding with its original round
# label, alongside findings raised by the first verify round.
if want history; then
setup_case history
printf 'P1 round 0 original finding\n' >"$CDIR/findings.md"
printf 'history-one' >"$T/vermode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "history round 1 incomplete exited 0"
rc=$?; [ "$rc" = "1" ] || fail "history round 1 exited $rc, want 1"
grep -q 'FIX-INCOMPLETE round=1' <<<"$out" || fail "history round 1 verdict missing"
printf 'history-two' >"$T/vermode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "history round 2 exited $?"
grep -q 'FIX-OK' <<<"$out" || fail "history round 2 did not verify"
input="$T/verify-input-2.md"
grep -Fq 'P1 round 0 original finding' "$input" || fail "round 2 verify input lost round 0's finding"
grep -Fq 'raised in review round 0' "$input" || fail "round 2 verify input does not label round 0"
grep -Fq 'P1 finding raised in round 1' "$input" || fail "round 2 verify input lost round 1's finding"
grep -Fq 'status=closed in fix round 1' "$input" || fail "round 2 verify input lost round 0's closure round"
grep -Fq 'Earlier fix rounds in this diff: 1' "$input" || fail "round 2 verify input does not state earlier-round coverage"

setup_case history-unverified
out="$(bash "$TKT" "$S" --no-verify 2>"$T/stderr")" || fail "history no-verify exited $?"
history="$(bash "$TKT_STATE" "$S" get findings_history)"
round_findings="$(bash "$TKT_STATE" "$S" get fix_round.1.findings)"
round_head="$(bash "$TKT_STATE" "$S" get fix_round.1.head)"
round_start="$(bash "$TKT_STATE" "$S" get fix_round.1.start)"
[ "$round_start" = "$OLD" ] || fail "no-verify round start was not recorded"
[ -r "$round_findings" ] || fail "no-verify round findings were not recorded"
[ "$round_head" = "$(git -C "$WT" rev-parse HEAD)" ] || fail "no-verify round head was not recorded"
grep -Fq 'raised=raised in review round 0' "$history" || fail "no-verify history lost round 0 finding label"
grep -Fq 'unverified=fix round 1' "$history" || fail "no-verify history did not label its round"
printf 'history-two' >"$T/vermode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "verify after no-verify exited $?"
grep -Fq 'unverified=fix round 1' "$T/verify-input-1.md" || fail "verify after no-verify lost the unverified round label"

setup_case missing-round-findings
printf 'round one fix\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
  git -C "$WT" commit -qm 'fix: round one'
git -C "$WT" push -q origin tkt-529
ROUND1_HEAD="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$ROUND1_HEAD" >/dev/null
bash "$TKT_STATE" "$S" set round 1 >/dev/null
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
bash "$TKT_STATE" "$S" set fix_round.1.start "$OLD" >/dev/null
bash "$TKT_STATE" "$S" set fix_round.1.head "$ROUND1_HEAD" >/dev/null
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "missing-round-findings exited 0"
rc=$?; [ "$rc" = "1" ] || fail "missing-round-findings exited $rc, want 1"
grep -Fq "FINDINGS-UNACCOUNTED commits=$ROUND1_HEAD" <<<"$out" || fail "missing-round-findings did not list its commit: $(head -n 1 <<<"$out")"
grep -Fq "tkt-state $S set fix_round.1.findings $CDIR/run/switchyard-529-fix-round-1-findings.md && tkt-fix $S --verify --since $OLD" <<<"$out" || fail "missing-round-findings omitted repair command: $(tail -n +2 <<<"$out")"
grep -q '^review-pr|' "$T/calls.log" && fail "missing-round-findings ran review-pr"
fi

if want round-ownership; then
setup_case round-ownership
# A prior commit is in the verify range, but round 1 has no ownership record.
# The round-2 head must not make that earlier commit look like round 2's work.
printf 'earlier round fix\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm 'fix: unrecorded earlier round'
git -C "$WT" push -q origin tkt-529
EARLIER_HEAD="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$EARLIER_HEAD" >/dev/null
bash "$TKT_STATE" "$S" set round 1 >/dev/null
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
[ -z "$(bash "$TKT_STATE" "$S" get fix_round.1.head 2>/dev/null || true)" ] || fail "round-ownership: round 1 unexpectedly has a head record"
[ -z "$(bash "$TKT_STATE" "$S" get fix_round.1.findings 2>/dev/null || true)" ] || fail "round-ownership: round 1 unexpectedly has findings"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" -ne 0 ] || fail "round-ownership accepted an earlier commit with no round-1 record: $out"
[ "$run_rc" = "1" ] || fail "round-ownership exited $run_rc, want 1"
grep -Fq "FINDINGS-UNACCOUNTED commits=$EARLIER_HEAD" <<<"$out" || fail "round-ownership did not refuse the earlier commit: $out"
grep -q '^review-pr|' "$T/calls.log" && fail "round-ownership ran review-pr on uncovered commits"
fi

# 1. Verify OK on an already-pushed head: no CI wait, slot fix1, reviewed set.
setup_case ok
printf 'fixed\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "fix: fix.txt"
git -C "$WT" push -q origin tkt-529
NEW="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$NEW" >/dev/null
record_test_round 1 "$NEW"
printf 'pushed' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "verify OK exited $?"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=$NEW" || fail "bad verdict: $(head -n 1 <<<"$out")"
expect_slot fix1
grep -q "gh-ci|" "$T/calls.log" && fail "gh-ci wait ran on a pushed head"
[ "$(bash "$TKT_STATE" "$S" get reviewed)" = "$NEW" ] || fail "reviewed not set"
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "round not 1"
fr="$CDIR/run/switchyard-529-findings-r1.md"
[ -f "$fr" ] || fail "findings-r1.md missing"
grep -q "no open findings" "$fr" || fail "findings-r1.md should hold the no-findings line"
grep -q -- "--model verify-model" "$T/calls.log" || fail "verify model not passed to review-pr"
grep -q "FINDINGS=@$CDIR/findings.md" "$T/calls.log" || fail "FINDINGS not passed to tkt-job"

# 2. Incomplete at round 2: slot fix2 (not a re-printed fix1), STOP-AT-TWO.
setup_case round2
bash "$TKT_STATE" "$S" set round 1 >/dev/null
printf 'incomplete' >"$T/vermode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "incomplete at round 2 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "incomplete at round 2 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-INCOMPLETE round=2 STOP-AT-TWO" || fail "bad verdict: $(head -n 1 <<<"$out")"
expect_slot fix2
grep -q "P1 open finding" <<<"$out" || fail "finding headlines missing from digest"
[ "$(bash "$TKT_STATE" "$S" get round)" = "2" ] || fail "round not 2"
fr="$CDIR/run/switchyard-529-findings-r2.md"
grep -q "P1 open finding in fix.txt" "$fr" || fail "findings-r2.md missing the open lines"

# 3. Ready, not pushed: CI wait runs, the push lands, failed jobs reach the digest.
setup_case unpushed
printf '1' >"$T/cimode"
printf 'failing: nightly\n' >"$T/ciout"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "unpushed exited $?"
grep -q "gh-ci|wait 7" "$T/calls.log" || fail "gh-ci wait did not run"
grep -q "gh-ci|wait 7 --repo switchyard" "$T/calls.log" || fail "gh-ci wait missed --repo switchyard"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$(git -C "$WT" rev-parse HEAD)" ] || fail "push did not land"
grep -q "failing: nightly" <<<"$out" || fail "failed CI jobs missing from digest"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK" || fail "bad verdict: $(head -n 1 <<<"$out")"

# 4. Fence breach after the fix passes through with the gate's verdict.
setup_case fence
printf 'evil' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "fence breach exited 0"
rc=$?; [ "$rc" = "1" ] || fail "fence breach exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FENCE n=1" || fail "bad verdict: $(head -n 1 <<<"$out")"

# 5. No-verify closes the round and records the findings file.
setup_case noverify
out="$(bash "$TKT" "$S" --no-verify 2>"$T/stderr")" || fail "no-verify exited $?"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix PUSHED unverified" || fail "bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get unverified)" = "$CDIR/findings.md" ] || fail "unverified not set"
grep -q "review-pr|" "$T/calls.log" && fail "review-pr ran under --no-verify"

# 6. A fix job ASK passes through; nothing downstream runs.
setup_case ask
printf 'ask' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "ASK exited 0"
rc=$?; [ "$rc" = "1" ] || fail "ASK exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ASK id=j1" || fail "bad verdict: $(head -n 1 <<<"$out")"
grep -q "which design rules the retry?" <<<"$out" || fail "ASK question missing from digest"
grep -q "gh-ci|" "$T/calls.log" && fail "push ran after ASK"
[ "$(bash "$TKT_STATE" "$S" get round)" = "0" ] || fail "round moved after ASK"

# 7. Resume forwards the job id and prompt; usage errors exit 2.
setup_case resume
printf 'resume brief\n' >"$CDIR/prompt.md"
out="$(bash "$TKT" "$S" --verify --resume j9 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" || fail "resume exited $?"
grep -q "job|.*--resume j9.*--prompt $CDIR/prompt.md.*--gate-from-plan" "$T/calls.log" || fail "resume args not forwarded with --gate-from-plan"

# 7b. With gate.script set, a resume whose plan Gate line skips the script stops before dispatch.
setup_case resume-gate-script
printf 'gate.script=%s\n' scripts/check >>"$S"
printf 'resume brief\n' >"$CDIR/prompt.md"
bash "$TKT" "$S" --verify --resume j9 --prompt "$CDIR/prompt.md" >/dev/null 2>"$T/stderr" && fail "resume-gate-script exited 0"
grep -q "job|" "$T/calls.log" && fail "resume-gate-script dispatched a job"
bash "$TKT" "$S" 2>/dev/null && fail "bare flags exited 0"
rc=$?; [ "$rc" = "2" ] || fail "bare flags exited $rc, want 2"
# 7a. Round 2 refuses a fresh fix before any slot or dispatch; --resume still runs.
setup_case round-limit
bash "$TKT_STATE" "$S" set round 2 >/dev/null
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "round 2 fix exited 0"
rc=$?; [ "$rc" = "1" ] || fail "round 2 fix exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ROUND-LIMIT round=2" || fail "bad verdict: $(head -n 1 <<<"$out")"
grep -q "tkt-fix .*--resume <job id> --prompt <file>" <<<"$out" || fail "ROUND-LIMIT names the resume command and prompt"
grep -q "works with no open slot" <<<"$out" || fail "ROUND-LIMIT says resume needs no open slot"
grep -q "job|" "$T/calls.log" && fail "round 2 fix dispatched a job"
[ "$(bash "$TKT_STATE" "$S" get round)" = "2" ] || fail "round moved on ROUND-LIMIT"
setup_case round-resume
bash "$TKT_STATE" "$S" set round 2 >/dev/null
printf 'resume brief\n' >"$CDIR/prompt.md"
out="$(bash "$TKT" "$S" --verify --resume j9 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" || true
head -n 1 <<<"$out" | grep -q "ROUND-LIMIT" && fail "resume at round 2 is refused"
grep -q "job|.*--slot fix3.*--resume j9" "$T/calls.log" || fail "resume at round 2 does not dispatch on fix3"
bash "$TKT" "$S" --verify --resume j9 2>/dev/null && fail "resume without prompt exited 0"
rc=$?; [ "$rc" = "2" ] || fail "resume without prompt exited $rc, want 2"

# 7b. The fix brief gets the plan gate as GATE (fix.md fills __GATE__).
setup_case gatefill
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "gatefill exited $?"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=" || fail "gatefill bad verdict: $(head -n 1 <<<"$out")"
grep -F -q "GATE=true" "$T/calls.log" || fail "gatefill: GATE=true not passed to tkt-job"

# 7c. A gate-failed round counts: the fix job breaks the fence (gate grc 1),
# round goes to 1 and the next call dispatches fix2, not RECOVER on fix1.
setup_case gatefail
printf 'evil' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "gatefail exited 0"
rc=$?; [ "$rc" = "1" ] || fail "gatefail exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FENCE n=1" || fail "gatefail bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "gatefail round not 1"
printf 'done' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")"
grep -q "RECOVER" <<<"$out" && fail "second call printed RECOVER"
expect_slot fix2

# 8. DRIFT A: forward worktree commit with no job recorded exits 3.
setup_case drifta
printf 'outside\n' >"$WT/evil.txt"
git -C "$WT" add evil.txt
git -C "$WT" commit -qm "outside: evil.txt"
NEW="$(git -C "$WT" rev-parse HEAD)"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "drift-a exited 0"
rc=$?; [ "$rc" = "3" ] || fail "drift-a exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "bad verdict: $(head -n 1 <<<"$out")"
grep -q "state head=$OLD" <<<"$out" || fail "state head missing from DRIFT digest"
grep -q "PR head=$NEW" <<<"$out" || fail "PR head missing from DRIFT digest"
grep -q "worktree HEAD=$NEW" <<<"$out" || fail "worktree sha missing from DRIFT digest"
grep -q "job|" "$T/calls.log" && fail "fix job dispatched on DRIFT A"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$OLD" ] || fail "drift-a commit was pushed"
# 9. RECOVER: a stored job for this round's slot exits 3, no dispatch, no push.
setup_case recover
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "recover exited 0"
rc=$?; [ "$rc" = "3" ] || fail "recover exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix RECOVER" || fail "bad verdict: $(head -n 1 <<<"$out")"
grep -q "job=j1" <<<"$out" || fail "job id missing from RECOVER digest"
grep -q "slot=fix1" <<<"$out" || fail "slot missing from RECOVER digest"
grep -q "job|" "$T/calls.log" && fail "fix job dispatched on RECOVER"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$OLD" ] || fail "recover pushed"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "head moved on RECOVER"
# 10. DRIFT B: PR head rewound to an ancestor of state head exits 3.
setup_case driftb
printf 'fixed\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "fix: fix.txt"
git -C "$WT" push -q origin tkt-529
NEW="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$NEW" >/dev/null
printf '%s' "$OLD" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "drift-b exited 0"
rc=$?; [ "$rc" = "3" ] || fail "drift-b exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "bad verdict: $(head -n 1 <<<"$out")"
grep -q "state head=$NEW" <<<"$out" || fail "state head missing from DRIFT digest"
grep -q "PR head=$OLD" <<<"$out" || fail "PR head missing from DRIFT digest"
grep -q "worktree HEAD=$NEW" <<<"$out" || fail "worktree sha missing from DRIFT digest"
grep -q "job|" "$T/calls.log" && fail "fix job dispatched on DRIFT B"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$NEW" ] || fail "drift-b moved origin"

# A. After an abnormal (ASK) exit, the next fresh call advances to fix2.
if want A; then
setup_case a
printf 'ask' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "A call 1 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "A call 1 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ASK id=j1" || fail "A bad verdict: $(head -n 1 <<<"$out")"
grep -q "job|.*--slot fix1" "$T/calls.log" || fail "A call 1 did not dispatch fix1"
[ "$(bash "$TKT_STATE" "$S" get round)" = "0" ] || fail "A round moved after ASK"
: >"$T/calls.log"
printf 'done' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "A call 2 exited $?"
grep -q "RECOVER" <<<"$out" && fail "A call 2 printed RECOVER"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK" || fail "A bad verdict: $(head -n 1 <<<"$out")"
expect_slot fix2
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "A round not 1"
[ "$(bash "$TKT_STATE" "$S" get fixslot)" = "2" ] || fail "A fixslot not 2"
[ "$(bash "$TKT_STATE" "$S" get job.fix1)" = "j1" ] || fail "A job.fix1 lost"
fi

# A2. A resume after ASK stays on the slot that owns the id.
if want A2; then
setup_case a2
printf 'ask' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "A2 call 1 exited 0"
printf 'done' >"$T/jobmode"
printf 'resume brief\n' >"$CDIR/prompt.md"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify --resume j1 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" || fail "A2 resume exited $?"
grep -q "job|.*--slot fix1.*--resume j1" "$T/calls.log" || fail "A2 resume did not dispatch fix1 (log: $(cat "$T/calls.log"))"
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "A2 round not 1"
fi

# A3. Resume slot lookup follows supersededBy, ends on a cycle, and exits 2
# on an id that is not a job id at all.
if want A3; then
rm -f "$TMPDIR/delegate-jobs"/j1.json "$TMPDIR/delegate-jobs"/j2.json
setup_case a3walk
bash "$TKT_STATE" "$S" set round 1 >/dev/null
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 j2 >/dev/null
mkdir -p "$TMPDIR/delegate-jobs"
printf '{"supersededBy":"j2"}' >"$TMPDIR/delegate-jobs/j1.json"
printf 'resume brief\n' >"$CDIR/prompt.md"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify --resume j1 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" || fail "A3 walk exited $?"
grep -q "job|.*--slot fix1" "$T/calls.log" || fail "A3 walk: resume j1 did not dispatch fix1"
setup_case a3cycle
bash "$TKT_STATE" "$S" set round 1 >/dev/null
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 j3 >/dev/null
printf '{"supersededBy":"j2"}' >"$TMPDIR/delegate-jobs/j1.json"
printf '{"supersededBy":"j1"}' >"$TMPDIR/delegate-jobs/j2.json"
printf 'resume brief\n' >"$CDIR/prompt.md"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify --resume j1 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" || fail "A3 cycle exited $?"
grep -q "job|.*--slot fix2" "$T/calls.log" || fail "A3 cycle: resume j1 did not fall back to fix2"
setup_case a3zz
bash "$TKT_STATE" "$S" set round 1 >/dev/null
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 j2 >/dev/null
rm -f "$TMPDIR/delegate-jobs"/j1.json "$TMPDIR/delegate-jobs"/j2.json
printf 'resume brief\n' >"$CDIR/prompt.md"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify --resume zz --prompt "$CDIR/prompt.md" 2>"$T/stderr")" && fail "A3 zz exited 0"
rc=$?; [ "$rc" = "2" ] || fail "A3 zz exited $rc, want 2"
grep -q "zz" "$T/stderr" || fail "A3 zz: stderr does not name zz"
grep -q "job|" "$T/calls.log" && fail "A3 zz dispatched a job"
fi

if want STALE-RESUME; then
# STALE-RESUME: when delegate cannot find a resumed record and its locator
# points at a deleted target, tkt-fix refuses with triage guidance. It does not
# turn the owned slot into permission to start a fresh job.
setup_case stale-resume
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
mkdir -p "$XDG_CACHE_HOME/delegate/locators"
printf '%s\n' "$CDIR/deleted-jobs/j1.json" >"$XDG_CACHE_HOME/delegate/locators/j1"
printf 'resume brief\n' >"$CDIR/prompt.md"
printf 'stale-resume' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify --resume j1 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" && fail "stale resume exited 0"
rc=$?; [ "$rc" = "3" ] || fail "stale resume exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix UNKNOWN" || fail "stale resume verdict: $(head -n 1 <<<"$out")"
grep -qi "triage" <<<"$out" || fail "stale resume does not name triage recovery: $out"
grep -q "slot fix1" <<<"$out" || fail "stale resume does not preserve owned slot: $out"
grep -q "job|.*--slot fix1.*--resume j1" "$T/calls.log" || fail "stale resume did not stay on the owned slot"
grep -q "unknown job j1 (record missing)" <<<"$out" && fail "stale resume exposed the bare delegate error"
fi

# UNKNOWN verdicts preserve stderr from a sub-tool that writes no TKT line;
# completely silent tools get an explicit detail instead of blank lines.
if want STDERR; then
setup_case stderr-only
printf 'stderr-only' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "stderr-only sub-tool exited 0"
rc=$?; [ "$rc" = "3" ] || fail "stderr-only sub-tool exited $rc, want 3"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix UNKNOWN tool=tkt-job' || fail "stderr-only UNKNOWN verdict: $(head -n 1 <<<"$out")"
grep -qx 'tkt-job refused: missing required context' <<<"$out" || fail "sub-tool stderr did not reach lane output: [$out]"

setup_case no-output
printf 'no-output' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "silent sub-tool exited 0"
rc=$?; [ "$rc" = "3" ] || fail "silent sub-tool exited $rc, want 3"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix UNKNOWN tool=tkt-job' || fail "silent UNKNOWN verdict: $(head -n 1 <<<"$out")"
grep -qx 'tkt-job wrote no output' <<<"$out" || fail "silent sub-tool detail missing: [$out]"
fi

# A4. An UNKNOWN (exit 3) close keeps RECOVER: the slot does not advance.
if want A4; then
setup_case a4
printf 'unknown' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "A4 call 1 exited 0"
rc=$?; [ "$rc" = "3" ] || fail "A4 call 1 exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix UNKNOWN" || fail "A4 bad verdict: $(head -n 1 <<<"$out")"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "A4 call 2 exited 0"
rc=$?; [ "$rc" = "3" ] || fail "A4 call 2 exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix RECOVER" || fail "A4 bad verdict: $(head -n 1 <<<"$out")"
grep -q "slot=fix1" <<<"$out" || fail "A4 slot missing from RECOVER digest"
grep -q "job|" "$T/calls.log" && fail "A4 call 2 dispatched a job"
fi

# A5. Abnormal exits consume no round: ASK, incomplete, incomplete reaches
# round 2 and STOP-AT-TWO, and the next fresh call hits ROUND-LIMIT.
if want A5; then
setup_case a5
printf 'ask' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "A5 call 1 exited 0"
printf 'done' >"$T/jobmode"
printf 'incomplete' >"$T/vermode"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "A5 call 2 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "A5 call 2 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-INCOMPLETE round=1" || fail "A5 bad verdict: $(head -n 1 <<<"$out")"
grep -q "STOP-AT-TWO" <<<"$out" && fail "A5 call 2 printed STOP-AT-TWO"
expect_slot fix2
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "A5 round not 1"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "A5 call 3 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "A5 call 3 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-INCOMPLETE round=2 STOP-AT-TWO" || fail "A5 bad verdict: $(head -n 1 <<<"$out")"
expect_slot fix3
[ "$(bash "$TKT_STATE" "$S" get round)" = "2" ] || fail "A5 round not 2"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "A5 call 4 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "A5 call 4 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ROUND-LIMIT round=2" || fail "A5 bad verdict: $(head -n 1 <<<"$out")"
grep -q "job|" "$T/calls.log" && fail "A5 call 4 dispatched a job"
fi

# A6. A resume of a slot below round still adds a round when it verifies.
if want A6; then
setup_case a6
printf 'ask' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "A6 call 1 exited 0"
printf 'done' >"$T/jobmode"
printf 'incomplete' >"$T/vermode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "A6 call 2 exited 0"
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "A6 round not 1"
printf 'ok' >"$T/vermode"
printf 'resume brief\n' >"$CDIR/prompt.md"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify --resume j1 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" || fail "A6 resume exited $?"
grep -q "job|.*--slot fix1" "$T/calls.log" || fail "A6 resume did not dispatch fix1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK" || fail "A6 bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get round)" = "2" ] || fail "A6 round not 2"
fi

# B. Drift the fix job's own push caused is accepted: the job commits, ends
# abnormally, and pushes; the next call proceeds on fix2 instead of DRIFT.
if want B; then
setup_case b
printf 'stalled' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "B call 1 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "B call 1 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix NEEDS_CONTEXT id=j1" || fail "B bad verdict: $(head -n 1 <<<"$out")"
git -C "$WT" push -q origin tkt-529
: >"$T/calls.log"
printf 'done' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "B call 2 exited $?"
grep -q "DRIFT" <<<"$out" && fail "B call 2 printed DRIFT"
grep -q "RECOVER" <<<"$out" && fail "B call 2 printed RECOVER"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK" || fail "B bad verdict: $(head -n 1 <<<"$out")"
expect_slot fix2
[ "$(bash "$TKT_STATE" "$S" get head)" = "$(git -C "$WT" rev-parse HEAD)" ] || fail "B head not the worktree HEAD"
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "B round not 1"
fi

# B1. A fix job CONCERNS continues to the gate and the verify, which gets the
# concerns file as --context; the digest names the file. Nothing stops, no drift.
if want B1; then
setup_case concerns-fix
printf 'partial' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "B1 exited $? (want 0): $(head -n 1 <<<"$out")"
CF="$CDIR/run/switchyard-529-concerns-fix1.md"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=" || fail "B1 bad verdict: $(head -n 1 <<<"$out")"
grep -q "DRIFT" <<<"$out" && fail "B1 printed DRIFT"
expect_slot fix1
[ "$(bash "$TKT_STATE" "$S" get head)" = "$(git -C "$WT" rev-parse HEAD)" ] || fail "B1 head not the worktree HEAD"
[ "$(sed -n '2p' <<<"$out")" = "head=$(git -C "$WT" rev-parse HEAD)" ] || fail "B1 digest line 2 is not head="
grep -qxF "concerns=$CF" <<<"$out" || fail "B1 digest lacks concerns=$CF: $out"
[ "$(bash "$TKT_STATE" "$S" get concerns.fix1)" = "$CF" ] || fail "B1 concerns.fix1 not stored"
printf 'fix job is unsure about X\n' | cmp - "$CF" || fail "B1 concerns file text"
grep -qF -- "--context $CF" "$T/calls.log" || fail "B1 verify got no --context: $(cat "$T/calls.log")"
grep -q "review-pr|run 7" "$T/calls.log" || fail "B1 verify did not run: $(cat "$T/calls.log")"
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "B1 round not 1"
fi

# B2. A later clean round carries no stale context: the verify has no --context.
if want B2; then
setup_case concerns-then-clean
printf 'partial' >"$T/jobmode"
bash "$TKT" "$S" --verify >/dev/null 2>"$T/stderr" || fail "B2 first round exited $?"
: >"$T/calls.log"
printf 'P1 later round finding\n' >"$CDIR/round2-findings.md"
bash "$TKT_STATE" "$S" set findings "$CDIR/round2-findings.md" >/dev/null
printf 'done' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "B2 clean round exited $?: $(cat "$T/stderr")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK" || fail "B2 bad verdict: $(head -n 1 <<<"$out")"
grep -q -- "--context" "$T/calls.log" && fail "B2 clean round sent stale context: $(cat "$T/calls.log")"
grep -q "concerns=" <<<"$out" && fail "B2 clean round digest names stale concerns"
expect_slot fix2
fi

# B3. A concerns round whose verify is incomplete still names the concerns file.
if want B3; then
setup_case concerns-incomplete
printf 'partial' >"$T/jobmode"
printf 'incomplete' >"$T/vermode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "B3 incomplete exited 0"
rc=$?; [ "$rc" = "1" ] || fail "B3 incomplete exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-INCOMPLETE round=1" || fail "B3 bad verdict: $(head -n 1 <<<"$out")"
grep -qxF "concerns=$CDIR/run/switchyard-529-concerns-fix1.md" <<<"$out" || fail "B3 digest lacks concerns line"
fi

# B4. NO-COMMITS checks the pushed head and verifies the findings.
if want B4; then
setup_case no-commits
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `base.txt`
- `fix.txt`

## Gate

`false`
EOF
printf 'no-commits' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "B4 exited $? (want gate/verify verdict 0): $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=$OLD" || fail "B4 bad verdict: $(head -n 1 <<<"$out")"
grep -q "tkt-gate PASS" "$CDIR/tkt.journal" || fail "B4 checks-only gate did not run"
grep -q "review-pr|run 7" "$T/calls.log" || fail "B4 scoped verify did not run"
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "B4 round not 1"
grep -q '^.*tkt-fix round=1 no commits$' "$CDIR/tkt.journal" || fail "B4 no-commits round was not journaled"
grep -qxF "no commits" <<<"$(tail -n +2 <<<"$out")" || fail "B4 digest lacks no-commits line: $out"
fi

# C1. A PR head that does not descend from the state head still exits DRIFT.
if want C1; then
setup_case c1
printf 'sibling\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "sibling: fix.txt"
SIB="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" reset -q --hard "$OLD"
printf 'other\n' >"$WT/evil.txt"
git -C "$WT" add evil.txt
git -C "$WT" commit -qm "other: evil.txt"
OTHER="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$SIB" >/dev/null
bash "$TKT_STATE" "$S" set fixopen 1 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
printf '%s' "$OTHER" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "C1 exited 0"
rc=$?; [ "$rc" = "3" ] || fail "C1 exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "C1 bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$SIB" ] || fail "C1 head moved"
grep -q "job|" "$T/calls.log" && fail "C1 dispatched a job"
fi

# D. A no-commit abnormal close clears the open slot, so a later unrelated
# commit still exits DRIFT instead of passing as the job's own drift.
if want D; then
setup_case d
printf 'ask' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "D call 1 exited 0"
printf 'outside\n' >"$WT/evil.txt"
git -C "$WT" add evil.txt
git -C "$WT" commit -qm "outside: evil.txt"
NEW="$(git -C "$WT" rev-parse HEAD)"
: >"$T/calls.log"
printf 'done' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "D call 2 exited 0"
rc=$?; [ "$rc" = "3" ] || fail "D call 2 exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "D bad verdict: $(head -n 1 <<<"$out")"
grep -q "PR head=$NEW" <<<"$out" || fail "D PR head missing from DRIFT digest"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "D head moved"
grep -q "job|" "$T/calls.log" && fail "D call 2 dispatched a job"
fi

# C2. A worktree behind the PR head still exits DRIFT.
if want C2; then
setup_case c2
printf 'one\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "fix: fix.txt"
ONE="$(git -C "$WT" rev-parse HEAD)"
printf 'two\n' >>"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "fix: fix.txt again"
TWO="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" reset -q --hard "$ONE"
bash "$TKT_STATE" "$S" set fixopen 1 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
printf '%s' "$TWO" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "C2 exited 0"
rc=$?; [ "$rc" = "3" ] || fail "C2 exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "C2 bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "C2 head moved"
grep -q "job|" "$T/calls.log" && fail "C2 dispatched a job"
fi

# E. A worktree ahead of the PR head by the open fix job's own unpushed
# commits is not drift: the state and PR heads agree at the old head, the
# worktree descends from it, the job's delegate record owns the worktree
# HEAD, and the next call carries the state head forward to it and then
# stops at RECOVER for that slot instead of stopping at DRIFT.
if want E; then
setup_case e
printf 'fix work\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "fix: fix.txt"
NEW="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set fixopen 1 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
mkdir -p "$TMPDIR/delegate-jobs"
jq -n --arg ha "$NEW" '{status:"NEEDS_CONTEXT",result:{status:"NEEDS_CONTEXT",text:"which design rules the retry?",changeSet:{headBefore:"x",headAfter:$ha,newCommits:[$ha],uncommittedFiles:[],filesChanged:[],diffstat:"",dirtyAfter:false}},supervisorPid:1}' >"$TMPDIR/delegate-jobs/j1.json" || fail "E record write"
printf '%s' "$OLD" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "E exited 0"
rc=$?; [ "$rc" = "3" ] || fail "E exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix RECOVER" || fail "E bad verdict: $(head -n 1 <<<"$out")"
grep -q "job=j1" <<<"$out" || fail "E job id missing from RECOVER digest"
grep -q "slot=fix1" <<<"$out" || fail "E slot missing from RECOVER digest"
grep -q "job|" "$T/calls.log" && fail "E dispatched a job"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$OLD" ] || fail "E pushed"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$NEW" ] || fail "E head not carried to the worktree HEAD"
[ "$(bash "$TKT_STATE" "$S" get fixopen)" = "1" ] || fail "E fixopen changed"
grep -q "tkt-fix: worktree is ahead of the PR head by open fix job fix1's unpushed commits" "$T/stderr" || fail "E stderr line missing: $(cat "$T/stderr")"
fi

# 10a. Missing PR and head are filled from the branch's open PR before dispatch.
setup_case fill-both-ask
drop_state_key pr
drop_state_key head
printf '[{"number":7,"headRefOid":"%s"}]' "$OLD" >"$T/prlist"
printf 'ask' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "fill-both ASK exited 0"
rc=$?; [ "$rc" = "1" ] || fail "fill-both ASK exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ASK id=j1" || fail "fill-both bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get pr)" = "7" ] || fail "fill-both did not store PR number"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "fill-both did not store PR head"
grep -Fx "gh|pr list --head tkt-529 --repo switchyard --state open --json number,headRefOid" "$T/calls.log" >/dev/null || fail "fill-both lookup args differ"

# 10b. A filled PR and head work through a pushed fix round.
setup_case fill-both-done
printf 'fixed\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "fix: fix.txt"
git -C "$WT" push -q origin tkt-529
NEW="$(git -C "$WT" rev-parse HEAD)"
drop_state_key pr
drop_state_key head
record_test_round 1 "$NEW"
printf '[{"number":7,"headRefOid":"%s"}]' "$NEW" >"$T/prlist"
printf 'pushed' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "fill-both pushed round exited $?"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=$NEW" || fail "fill-both pushed round bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get pr)" = "7" ] || fail "fill-both pushed round lost PR number"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$NEW" ] || fail "fill-both pushed round lost head"

# 10c. Stored PR and head values suppress lookup and remain unchanged.
setup_case fill-both-stored
printf '[{"number":99,"headRefOid":"different"}]' >"$T/prlist"
printf 'ask' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "stored-values ASK exited 0"
rc=$?; [ "$rc" = "1" ] || fail "stored-values ASK exited $rc, want 1"
[ "$(bash "$TKT_STATE" "$S" get pr)" = "7" ] || fail "stored-values PR changed"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "stored-values head changed"
grep -q '^gh|pr list ' "$T/calls.log" && fail "stored values still triggered PR lookup"

# 10d. A stored PR selects its matching entry, not the first entry.
setup_case fill-head-by-pr
drop_state_key head
printf '[{"number":99,"headRefOid":"other"},{"number":7,"headRefOid":"%s"}]' "$OLD" >"$T/prlist"
printf 'ask' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "head-by-PR ASK exited 0"
rc=$?; [ "$rc" = "1" ] || fail "head-by-PR ASK exited $rc, want 1"
[ "$(bash "$TKT_STATE" "$S" get pr)" = "7" ] || fail "head-by-PR changed stored PR"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "head-by-PR selected the wrong PR"

# 10e. A missing PR is filled from the first entry without replacing head.
setup_case fill-pr-by-head
drop_state_key pr
printf '[{"number":11,"headRefOid":"%s"},{"number":7,"headRefOid":"other"}]' "$OLD" >"$T/prlist"
printf 'ask' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "PR-by-head ASK exited 0"
rc=$?; [ "$rc" = "1" ] || fail "PR-by-head ASK exited $rc, want 1"
[ "$(bash "$TKT_STATE" "$S" get pr)" = "11" ] || fail "PR-by-head did not select first PR"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "PR-by-head replaced stored head"

# 10f. No open PR fails before dispatch or fixopen writes.
setup_case fill-empty
drop_state_key pr
drop_state_key head
printf '[]' >"$T/prlist"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "empty PR list exited 0"
rc=$?; [ "$rc" = "2" ] || fail "empty PR list exited $rc, want 2"
grep -q 'PRECONDITION missing=pr: no open PR for branch tkt-529 in switchyard' "$T/stderr" || fail "empty PR list error missing: $(cat "$T/stderr")"
grep -q '^job|' "$T/calls.log" && fail "empty PR list dispatched a job"
if bash "$TKT_STATE" "$S" get fixopen >/dev/null 2>&1; then fail "empty PR list wrote fixopen"; fi

# 10g. A failed gh lookup is distinguished from an empty list.
setup_case fill-gh-fail
drop_state_key pr
drop_state_key head
printf '[{"number":7,"headRefOid":"%s"}]' "$OLD" >"$T/prlist"
printf '1' >"$T/prlistrc"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "failed PR lookup exited 0"
rc=$?; [ "$rc" = "2" ] || fail "failed PR lookup exited $rc, want 2"
grep -q 'PRECONDITION missing=pr: cannot list PRs for branch tkt-529' "$T/stderr" || fail "failed PR lookup error missing: $(cat "$T/stderr")"
grep -q '^job|' "$T/calls.log" && fail "failed PR lookup dispatched a job"

# 10h. Invalid JSON is a failed lookup, not an empty PR list.
setup_case fill-invalid-json
drop_state_key pr
drop_state_key head
printf 'not-json' >"$T/prlist"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "invalid PR JSON exited 0"
rc=$?; [ "$rc" = "2" ] || fail "invalid PR JSON exited $rc, want 2"
grep -q 'PRECONDITION missing=pr: cannot list PRs for branch tkt-529' "$T/stderr" || fail "invalid PR JSON error missing: $(cat "$T/stderr")"
grep -q '^job|' "$T/calls.log" && fail "invalid PR JSON dispatched a job"

# 10i. A stored PR missing from the open list fails before dispatch.
setup_case fill-no-match
drop_state_key head
printf '[{"number":99,"headRefOid":"other"}]' >"$T/prlist"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "non-matching PR list exited 0"
rc=$?; [ "$rc" = "2" ] || fail "non-matching PR list exited $rc, want 2"
grep -q '^job|' "$T/calls.log" && fail "non-matching PR list dispatched a job"

# 10j. A matching entry with no head fails before dispatch.
setup_case fill-empty-head
drop_state_key head
printf '[{"number":7,"headRefOid":""}]' >"$T/prlist"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "empty PR head exited 0"
rc=$?; [ "$rc" = "2" ] || fail "empty PR head exited $rc, want 2"
grep -q 'PRECONDITION missing=head:' "$T/stderr" || fail "empty PR head error missing: $(cat "$T/stderr")"
grep -q '^job|' "$T/calls.log" && fail "empty PR head dispatched a job"

# part-2 findings name: a part-2 state writes the -part2- file and leaves
# the part-1 file of the old name byte-identical.
setup_case part2-findings
printf 'fixed\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "fix: fix.txt"
git -C "$WT" push -q origin tkt-529
NEW="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$NEW" >/dev/null
bash "$TKT_STATE" "$S" set part 2 >/dev/null
record_test_round 1 "$NEW"
printf 'PART1-FINDINGS\n' >"$CDIR/run/switchyard-529-findings-r1.md"
cp "$CDIR/run/switchyard-529-findings-r1.md" "$T/part1-copy.md"
printf 'pushed' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "part2-findings exited $?"
fr="$CDIR/run/switchyard-529-part2-findings-r1.md"
[ -f "$fr" ] || fail "part2-findings: part2 findings file missing"
[ "$(bash "$TKT_STATE" "$S" get findings)" = "$fr" ] || fail "part2-findings: findings key is [$(bash "$TKT_STATE" "$S" get findings)]"
cmp -s "$CDIR/run/switchyard-529-findings-r1.md" "$T/part1-copy.md" || fail "part2-findings: part-1 findings file changed"
grep -q "no open findings" "$fr" || fail "part2-findings: part2 file should hold the no-findings line"

# findings-overwrite guard: an existing destination the state did not write
# is refused with exit 2 and left byte-identical.
setup_case findings-refuse
printf 'fixed\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "fix: fix.txt"
git -C "$WT" push -q origin tkt-529
NEW="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$NEW" >/dev/null
record_test_round 1 "$NEW"
printf 'UNRELATED-CONTENT\n' >"$CDIR/run/switchyard-529-findings-r1.md"
cp "$CDIR/run/switchyard-529-findings-r1.md" "$T/findings-refuse-copy.md"
printf 'pushed' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "findings-refuse exited 0"
rc=$?; [ "$rc" = "2" ] || fail "findings-refuse exited $rc, want 2"
grep -F -q "tkt-fix: refusing to overwrite $CDIR/run/switchyard-529-findings-r1.md: switchyard-529-findings-r1.md names are reserved for this ticket's own findings output; write hand-kept notes to switchyard-529-dispositions-r1.md instead" "$T/stderr" || fail "findings-refuse stderr missing refusal: $(cat "$T/stderr")"
cmp -s "$CDIR/run/switchyard-529-findings-r1.md" "$T/findings-refuse-copy.md" || fail "findings-refuse: existing file changed"

# findings-rerun: a destination the state recorded is rewritten.
setup_case findings-rerun
printf 'fixed\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "fix: fix.txt"
git -C "$WT" push -q origin tkt-529
NEW="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$NEW" >/dev/null
printf 'P1 STALE\n' >"$CDIR/run/switchyard-529-findings-r1.md"
bash "$TKT_STATE" "$S" set findings "$CDIR/run/switchyard-529-findings-r1.md" >/dev/null
bash "$TKT_STATE" "$S" journal "findings write $CDIR/run/switchyard-529-findings-r1.md" >/dev/null
record_test_round 1 "$NEW"
printf 'pushed' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "findings-rerun exited $?: $(cat "$T/stderr")"
grep -q "no open findings" "$CDIR/run/switchyard-529-findings-r1.md" || fail "findings-rerun: file not rewritten"
grep -q "STALE" "$CDIR/run/switchyard-529-findings-r1.md" && fail "findings-rerun: stale content remains"

# F1/F2/F3 run the real bin/tkt-job behind a logging wrapper, with a stub
# delegate that really commits in the worktree and mints delegate records,
# so the ahead-recovery path dispatches through tkt-job's head-drift guard
# instead of stopping at RECOVER. The PR head tracks origin/tkt-529 (stale
# until the push lands), and the fix brief comes from a temp-HOME copy of
# the real fix.md. These blocks sit last so the wrapper cannot leak into
# the stub-based cases above.
setup_ahead_dispatch() {
  setup_case "$1"
  printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
  mkdir -p "$T/home/.agents/skills/review-loop/briefs"
  cp "$SCRIPT_DIR/../skills/review-loop/briefs/fix.md" "$T/home/.agents/skills/review-loop/briefs/fix.md" || fail "copy fix brief"
  bash "$TKT_STATE" "$S" set workflow_doc "docs/workflow.md" >/dev/null || fail "set workflow_doc"
  mkdir -p "$T/no-system-jobs"
  export JOB_RECORD_SYSTEM_DIR="$T/no-system-jobs"
  cat >"$T/bin/tkt-job" <<EOF
#!/usr/bin/env bash
printf 'job|%s\n' "\$*" >>"$T/calls.log"
exec "$REAL_BIN/tkt-job" "\$@"
EOF
  chmod +x "$T/bin/tkt-job"
  printf 'ask' >"$T/delegate-mode"
  printf '0' >"$T/dcounter"
  cat >"$T/bin/delegate" <<EOF
#!/usr/bin/env bash
set -uo pipefail
jobsdir="\${DELEGATE_JOBS_DIR:-\${TMPDIR:-/tmp}/delegate-jobs}"
mode="\$(cat "$T/delegate-mode")"
cmd="\${1:-}"; shift || true
mint_record() {
  if [ "\$4" = "1" ]; then comms="[\"\$3\"]"; else comms="[]"; fi
  jq -n --arg status "\$1" --arg text "\$2" --arg ha "\$3" --argjson comms "\$comms" \
    '{status: \$status, result: {status: \$status, text: \$text, gateResult: {passed: true, command: "true", exitCode: 0, outputTail: "ok", outputPath: "/tmp/g.log"}, changeSet: {headBefore: "0", headAfter: \$ha, newCommits: \$comms, uncommittedFiles: [], filesChanged: [], diffstat: "", dirtyAfter: false}, concerns: null}, supervisorPid: 1}' \
    >"\$jobsdir/\$5.json" || exit 1
}
commit_fix() {
  printf 'fixed-%s\n' "\$2" >"\$1/fix.txt"
  git -C "\$1" add fix.txt
  git -C "\$1" -c user.email=t@t -c user.name=t commit -qm "fix: fix.txt"
  git -C "\$1" rev-parse HEAD
}
case "\$cmd" in
  run)
    cwd=""; prompt=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --cwd) cwd="\$2"; shift 2 ;;
        --prompt-file) prompt="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    n="\$((\$(cat "$T/dcounter") + 1))"
    printf '%s' "\$n" >"$T/dcounter"
    id="stub-\$n"
    printf 'delegate|run|new=%s|cwd=%s|prompt=%s\n' "\$id" "\$cwd" "\$prompt" >>"$T/calls.log"
    printf '%s' "\$cwd" >"$T/dcwd"
    mkdir -p "\$jobsdir"
    head="\$(commit_fix "\$cwd" "\$n")"
    if [ "\$mode" = "ask" ]; then mint_record NEEDS_CONTEXT "which design rules the retry?" "\$head" 1 "\$id"
    else mint_record DONE "\$(printf 'done\nSTATUS: DONE')" "\$head" 1 "\$id"; fi
    printf '%s\n' "\$id"
    ;;
  resume)
    from="\${1:-}"; shift || true
    prompt=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --prompt-file) prompt="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    n="\$((\$(cat "$T/dcounter") + 1))"
    printf '%s' "\$n" >"$T/dcounter"
    id="stub-\$n"
    printf 'delegate|resume|from=%s|new=%s|prompt=%s\n' "\$from" "\$id" "\$prompt" >>"$T/calls.log"
    mkdir -p "\$jobsdir"
    cwd="\$(cat "$T/dcwd")"
    head="\$(git -C "\$cwd" rev-parse HEAD)"
    if [ "\$mode" = "ask" ]; then mint_record NEEDS_CONTEXT "which design rules the retry?" "\$head" 0 "\$id"
    else mint_record DONE "\$(printf 'done\nSTATUS: DONE')" "\$head" 0 "\$id"; fi
    printf '%s\n' "\$id"
    ;;
  watch)
    printf 'watch|%s\n' "\$*" >>"$T/calls.log"
    ;;
  *)
    echo "stub delegate: unknown \$cmd" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$T/bin/delegate"
}

# F1 (P1). A fix job commits, then ends on ASK. The next
# tkt-fix --resume <id> --prompt <file> dispatches through the real tkt-job:
# the fake delegate sees the resume, and the run reaches push/verify with
# no head drift; the push carries the recovered commit.
if want F1; then
setup_ahead_dispatch f1
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "F1 call 1 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "F1 call 1 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ASK id=stub-1" || fail "F1 bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get fixopen)" = "1" ] || fail "F1 fixopen not 1 after ASK"
RECHEAD="$(git -C "$WT" rev-parse HEAD)"
[ "$(bash "$TKT_STATE" "$S" get fix_round.1.head)" = "$RECHEAD" ] || fail "F1 aborted round head was not recorded"
[ "$(bash "$TKT_STATE" "$S" get fix_round.1.start)" = "$OLD" ] || fail "F1 aborted round start was not recorded"
[ -r "$(bash "$TKT_STATE" "$S" get fix_round.1.findings)" ] || fail "F1 aborted round findings were not recorded"
printf 'P1 replacement input\n' >"$CDIR/replacement-findings.md"
bash "$TKT_STATE" "$S" set findings "$CDIR/replacement-findings.md" >/dev/null
printf 'done' >"$T/delegate-mode"
printf 'resume brief\n' >"$CDIR/prompt.md"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify --resume stub-1 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" || fail "F1 resume exited $?: $(head -n 1 <<<"$out"): $(cat "$T/stderr")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=$RECHEAD" || fail "F1 bad verdict: $(head -n 1 <<<"$out")"
grep -q "delegate|resume|from=stub-1" "$T/calls.log" || fail "F1 delegate saw no resume of stub-1: $(cat "$T/calls.log")"
grep -Fq 'P1 heading from review' "$T/verify-input-1.md" || fail "F1 verify lost aborted round findings"
grep -Fq 'P1 replacement input' "$T/verify-input-1.md" || fail "F1 verify lost current findings input"
grep -Fq 'raised in review round 0' "$T/verify-input-1.md" || fail "F1 verify did not label the aborted round findings"
grep -qi "head drift" <<<"$out" && fail "F1 verdict names head drift"
grep -qi "head drift" "$T/stderr" && fail "F1 stderr names head drift: $(cat "$T/stderr")"
grep -q "UNKNOWN" <<<"$out" && fail "F1 verdict is UNKNOWN"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$RECHEAD" ] || fail "F1 push did not carry the recovered commit"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$RECHEAD" ] || fail "F1 head not the worktree HEAD"
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "F1 round not 1"
fi

# F2 (P1). The same recovery, but a fresh call (no --resume) after the ASK
# closed fix1 dispatches fix2 through the real tkt-job and verifies.
if want F2; then
setup_ahead_dispatch f2
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "F2 call 1 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "F2 call 1 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ASK id=stub-1" || fail "F2 bad verdict: $(head -n 1 <<<"$out")"
printf 'done' >"$T/delegate-mode"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "F2 call 2 exited $?: $(head -n 1 <<<"$out"): $(cat "$T/stderr")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=" || fail "F2 bad verdict: $(head -n 1 <<<"$out")"
grep -q "job|.*--slot fix2" "$T/calls.log" || fail "F2 call 2 did not dispatch fix2: $(cat "$T/calls.log")"
grep -q "delegate|run|" "$T/calls.log" || fail "F2 delegate saw no run"
grep -q "delegate|resume|" "$T/calls.log" && fail "F2 call 2 resumed"
grep -qi "head drift" <<<"$out" && fail "F2 verdict names head drift"
grep -qi "head drift" "$T/stderr" && fail "F2 stderr names head drift: $(cat "$T/stderr")"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$(git -C "$WT" rev-parse HEAD)" ] || fail "F2 push did not land"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$(git -C "$WT" rev-parse HEAD)" ] || fail "F2 head not the worktree HEAD"
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "F2 round not 1"
fi

# F3 (P2). A fix job commits and ends on ASK, then an extra outside commit
# lands on top. The next call exits DRIFT and dispatches nothing: the
# worktree HEAD no longer equals the job record's headAfter.
if want F3; then
setup_ahead_dispatch f3
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "F3 call 1 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "F3 call 1 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ASK id=stub-1" || fail "F3 bad verdict: $(head -n 1 <<<"$out")"
printf 'outside\n' >"$WT/evil.txt"
git -C "$WT" add evil.txt
git -C "$WT" commit -qm "outside: evil.txt"
OUTHEAD="$(git -C "$WT" rev-parse HEAD)"
printf 'done' >"$T/delegate-mode"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "F3 call 2 exited 0"
rc=$?; [ "$rc" = "3" ] || fail "F3 call 2 exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "F3 bad verdict: $(head -n 1 <<<"$out")"
grep -q "worktree HEAD=$OUTHEAD" <<<"$out" || fail "F3 worktree sha missing from DRIFT digest"
grep -q "delegate|" "$T/calls.log" && fail "F3 dispatched a job"
grep -q "job|" "$T/calls.log" && fail "F3 dispatched a job"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "F3 head moved"
[ "$(bash "$TKT_STATE" "$S" get fixopen)" = "1" ] || fail "F3 fixopen changed"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$OLD" ] || fail "F3 pushed"
fi

# F4 (P1). RECOVER followed by the instructed resume dispatches through the
# real tkt-job: the first call carries the state head to the worktree HEAD
# and stops at RECOVER; the resume then reaches FIX-OK with no DRIFT and
# no head drift, and the push carries the recovered commit.
if want F4; then
setup_ahead_dispatch f4
printf 'fix work\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "fix: fix.txt"
NEW="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set fixopen 1 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
mkdir -p "$TMPDIR/delegate-jobs"
jq -n --arg ha "$NEW" '{status:"NEEDS_CONTEXT",result:{status:"NEEDS_CONTEXT",text:"which design rules the retry?",changeSet:{headBefore:"x",headAfter:$ha,newCommits:[$ha],uncommittedFiles:[],filesChanged:[],diffstat:"",dirtyAfter:false}},supervisorPid:1}' >"$TMPDIR/delegate-jobs/j1.json" || fail "F4 record write"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "F4 call 1 exited 0"
rc=$?; [ "$rc" = "3" ] || fail "F4 call 1 exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix RECOVER" || fail "F4 bad verdict: $(head -n 1 <<<"$out")"
grep -q "job=j1" <<<"$out" || fail "F4 job id missing from RECOVER digest"
grep -q "slot=fix1" <<<"$out" || fail "F4 slot missing from RECOVER digest"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$NEW" ] || fail "F4 head not carried to the worktree HEAD"
[ "$(bash "$TKT_STATE" "$S" get fixopen)" = "1" ] || fail "F4 fixopen changed"
printf 'done' >"$T/delegate-mode"
printf 'resume brief\n' >"$CDIR/prompt.md"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify --resume j1 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" || fail "F4 resume exited $?: $(head -n 1 <<<"$out"): $(cat "$T/stderr")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=$NEW" || fail "F4 bad verdict: $(head -n 1 <<<"$out")"
grep -q "DRIFT" <<<"$out" && fail "F4 verdict names DRIFT"
grep -qi "head drift" <<<"$out" && fail "F4 verdict names head drift"
grep -qi "head drift" "$T/stderr" && fail "F4 stderr names head drift: $(cat "$T/stderr")"
grep -q "job|.*--slot fix1.*--resume j1" "$T/calls.log" || fail "F4 resume did not dispatch fix1 through tkt-job: $(cat "$T/calls.log")"
grep -q "delegate|resume|from=j1" "$T/calls.log" || fail "F4 delegate saw no resume of j1: $(cat "$T/calls.log")"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$NEW" ] || fail "F4 push did not carry the recovered commit"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$NEW" ] || fail "F4 head not the worktree HEAD"
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "F4 round not 1"
fi

# G. A closed fix job's clean, unpublished commit is gated before it is pushed,
# then the same call continues through the scoped verify without dispatching a
# new fix job.
if want G; then
setup_case g
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
printf 'stalled' >"$T/jobmode"
first_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || first_rc=$?
[ "$first_rc" = "1" ] || fail "G first call exited $first_rc, want 1: $(head -n 1 <<<"$out"): $(cat "$T/stderr")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix NEEDS_CONTEXT id=j1" || fail "G first call bad verdict: $(head -n 1 <<<"$out")"
bash "$TKT_STATE" "$S" set fixopen 0 >/dev/null
NEW="$(git -C "$WT" rev-parse HEAD)"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "G recovery exited $?: $(head -n 1 <<<"$out"): $(cat "$T/stderr")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=$NEW" || fail "G recovery bad verdict: $(head -n 1 <<<"$out")"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$NEW" ] || fail "G recovery did not push the stalled commit"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$NEW" ] || fail "G recovery did not store the pushed head"
[ "$(bash "$TKT_STATE" "$S" get fixopen)" = "0" ] || fail "G recovery left fixopen set"
grep -q "job|" "$T/calls.log" && fail "G recovery dispatched a new fix job"
grep -q "review-pr|run 7" "$T/calls.log" || fail "G recovery did not verify"
grep -q "tkt-fix: pushed unpushed fix job head $OLD -> $NEW" "$T/stderr" || fail "G recovery stderr missing old and new heads: $(cat "$T/stderr")"
fi

# G2. A failed gate on a closed job's unpublished commit exits with the gate
# verdict and leaves the remote branch untouched.
if want G2; then
setup_case g2
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
printf 'stalled' >"$T/jobmode"
first_rc=0; bash "$TKT" "$S" --verify >/dev/null 2>"$T/stderr" || first_rc=$?
[ "$first_rc" = "1" ] || fail "G2 first call exited $first_rc, want 1"
bash "$TKT_STATE" "$S" set fixopen 0 >/dev/null
NEW="$(git -C "$WT" rev-parse HEAD)"
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `base.txt`
- `fix.txt`

## Gate

`false`
EOF
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "G2 recovery exited 0"
rc=$?; [ "$rc" = "1" ] || fail "G2 recovery exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FAIL rc=1" || fail "G2 bad gate verdict: $(head -n 1 <<<"$out")"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$OLD" ] || fail "G2 pushed after a failed gate"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "G2 moved state head after a failed gate"
[ "$(git -C "$WT" rev-parse HEAD)" = "$NEW" ] || fail "G2 moved the worktree head"
grep -q "job|" "$T/calls.log" && fail "G2 dispatched a new fix job"
grep -q "review-pr|" "$T/calls.log" && fail "G2 verified after the failed gate"
fi

# G3. An unpublished commit with a dirty worktree still exits DRIFT.
if want G3; then
setup_case g3
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
printf 'stalled' >"$T/jobmode"
first_rc=0; bash "$TKT" "$S" --verify >/dev/null 2>"$T/stderr" || first_rc=$?
[ "$first_rc" = "1" ] || fail "G3 first call exited $first_rc, want 1"
bash "$TKT_STATE" "$S" set fixopen 0 >/dev/null
printf 'untracked\n' >"$WT/untracked.txt"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "G3 recovery exited 0"
rc=$?; [ "$rc" = "3" ] || fail "G3 recovery exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "G3 bad verdict: $(head -n 1 <<<"$out")"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$OLD" ] || fail "G3 pushed a dirty worktree"
grep -q "job|" "$T/calls.log" && fail "G3 dispatched a new fix job"
fi

# G4. An unpublished commit that does not descend from the PR head still exits DRIFT.
if want G4; then
setup_case g4
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
printf 'stalled' >"$T/jobmode"
first_rc=0; bash "$TKT" "$S" --verify >/dev/null 2>"$T/stderr" || first_rc=$?
[ "$first_rc" = "1" ] || fail "G4 first call exited $first_rc, want 1"
bash "$TKT_STATE" "$S" set fixopen 0 >/dev/null
git -C "$WT" push -q origin tkt-529
PRHEAD="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" reset -q --hard "$OLD"
printf 'sibling\n' >"$WT/sibling.txt"
git -C "$WT" add sibling.txt
git -C "$WT" commit -qm "outside: sibling"
: >"$T/calls.log"
recovery_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || recovery_rc=$?
[ "$recovery_rc" = "3" ] || fail "G4 recovery exited $recovery_rc, want 3: $(head -n 1 <<<"$out"): $(cat "$T/stderr")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "G4 bad verdict: $(head -n 1 <<<"$out")"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$PRHEAD" ] || fail "G4 pushed a non-fast-forward worktree"
grep -q "job|" "$T/calls.log" && fail "G4 dispatched a new fix job"
fi
# 10k. No open PR with job.lane set names the lane resume command.
setup_case prepr-lane
drop_state_key pr
drop_state_key head
bash "$TKT_STATE" "$S" set job.lane lane-job-1 >/dev/null || fail "prepr-lane: set job.lane"
printf '[]' >"$T/prlist"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "prepr-lane exited 0"
rc=$?; [ "$rc" = "2" ] || fail "prepr-lane exited $rc, want 2"
grep -q 'PRECONDITION missing=pr: no open PR for branch tkt-529 in switchyard' "$T/stderr" || fail "prepr-lane first line missing: $(cat "$T/stderr")"
grep -F -q "tkt-fix: a lane blocked before its PR resumes with: tkt-job $S --slot lane --resume lane-job-1 --prompt <answer file> --gate-from-plan --expect-commits; then tkt-build $S --from gate" "$T/stderr" || fail "prepr-lane resume line missing: $(cat "$T/stderr")"
grep -q '^job|' "$T/calls.log" && fail "prepr-lane dispatched a job"

# 10l. No open PR without job.lane names --from lane.
setup_case prepr-nolane
drop_state_key pr
drop_state_key head
printf '[]' >"$T/prlist"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "prepr-nolane exited 0"
rc=$?; [ "$rc" = "2" ] || fail "prepr-nolane exited $rc, want 2"
grep -q 'PRECONDITION missing=pr: no open PR for branch tkt-529 in switchyard' "$T/stderr" || fail "prepr-nolane first line missing: $(cat "$T/stderr")"
grep -F -q "tkt-build $S --from lane" "$T/stderr" || fail "prepr-nolane lane line missing: $(cat "$T/stderr")"
grep -q '^job|' "$T/calls.log" && fail "prepr-nolane dispatched a job"

# --since supplies the reviewed head when reviews ran outside tkt-build.
setup_case since-missing-reviewed
drop_state_key reviewed
out="$(bash "$TKT" "$S" --verify --since "${OLD:0:8}" 2>"$T/stderr")" || fail "since-missing-reviewed exited $?: $(cat "$T/stderr")"
NEW="$(git -C "$WT" rev-parse HEAD)"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=$NEW" || fail "since-missing-reviewed bad verdict: $(head -n 1 <<<"$out")"
grep -F -q "review-pr|run 7 --repo switchyard --cwd $WT --head $NEW --model verify-model --verify $CDIR/run/switchyard-529-findings-history-r1.md --since $OLD" "$T/calls.log" || fail "since-missing-reviewed did not pass the full since sha: $(cat "$T/calls.log")"
[ "$(bash "$TKT_STATE" "$S" get reviewed)" = "$NEW" ] || fail "since-missing-reviewed did not update reviewed after FIX-OK"

# Without either source for the reviewed head, fail with a useful instruction.
setup_case since-missing
drop_state_key reviewed
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "since-missing exited 0"
rc=$?; [ "$rc" = "2" ] || fail "since-missing exited $rc, want 2"
grep -F -q 'tkt-fix: missing key: reviewed; pass --since <sha of the head the reviews covered>' "$T/stderr" || fail "since-missing message missing: $(cat "$T/stderr")"
grep -q '^job|' "$T/calls.log" && fail "since-missing dispatched a job"

# An explicit since must agree with an existing reviewed commit.
setup_case since-mismatch
printf 'other\n' >"$WT/other.txt"
git -C "$WT" add other.txt
git -C "$WT" commit -qm 'outside: another commit'
OTHER="$(git -C "$WT" rev-parse HEAD)"
out="$(bash "$TKT" "$S" --verify --since "$OTHER" 2>"$T/stderr")" && fail "since-mismatch exited 0"
rc=$?; [ "$rc" = "2" ] || fail "since-mismatch exited $rc, want 2"
grep -F -q "$OLD" "$T/stderr" || fail "since-mismatch message omitted reviewed sha $OLD: $(cat "$T/stderr")"
grep -F -q "$OTHER" "$T/stderr" || fail "since-mismatch message omitted --since sha $OTHER: $(cat "$T/stderr")"
grep -q '^job|' "$T/calls.log" && fail "since-mismatch dispatched a job"

# The matching explicit since proceeds and scopes the verify to that commit.
setup_case since-matching
out="$(bash "$TKT" "$S" --verify --since "$OLD" 2>"$T/stderr")" || fail "since-matching exited $?: $(cat "$T/stderr")"
NEW="$(git -C "$WT" rev-parse HEAD)"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=$NEW" || fail "since-matching bad verdict: $(head -n 1 <<<"$out")"
grep -F -q -- "--since $OLD" "$T/calls.log" || fail "since-matching did not pass --since $OLD: $(cat "$T/calls.log")"

# --since is only valid for a verifying fix round.
setup_case since-noverify
out="$(bash "$TKT" "$S" --no-verify --since "$OLD" 2>"$T/stderr")" && fail "since-noverify exited 0"
rc=$?; [ "$rc" = "2" ] || fail "since-noverify exited $rc, want 2"
grep -F -q 'usage: tkt-fix ' "$T/stderr" || fail "since-noverify did not report usage: $(cat "$T/stderr")"

# Reject an unresolvable commit before dispatching a fix job.
setup_case since-invalid
out="$(bash "$TKT" "$S" --verify --since not-a-commit 2>"$T/stderr")" && fail "since-invalid exited 0"
rc=$?; [ "$rc" = "2" ] || fail "since-invalid exited $rc, want 2"
grep -F -q 'tkt-fix: --since does not resolve to a commit in worktree: not-a-commit' "$T/stderr" || fail "since-invalid message missing: $(cat "$T/stderr")"
grep -q '^job|' "$T/calls.log" && fail "since-invalid dispatched a job"

echo "tkt-fix assertions passed"

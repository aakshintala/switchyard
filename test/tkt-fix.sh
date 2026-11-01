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
mkdir -p "$T/home" "$T/tmp" "$T/cache" "$T/no-system-jobs" "$T/bin" "$T/cases"
export HOME="$T/home" TMPDIR="$T/tmp" XDG_CACHE_HOME="$T/cache" JOB_RECORD_SYSTEM_DIR="$T/no-system-jobs" TKT_BIN="$T/bin"
export PATH="$T/bin:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

ln -s "$REAL_BIN/tkt-gate" "$T/bin/tkt-gate" || fail "symlink tkt-gate"
ln -s "$REAL_BIN/plan-gate" "$T/bin/plan-gate" || fail "symlink plan-gate"
ln -s "$REAL_BIN/tkt-state" "$T/bin/tkt-state" || fail "symlink tkt-state"
ln -s "$REAL_BIN/lib" "$T/bin/lib" || fail "symlink lib"

# Stub tkt-job: $T/jobmode holds done (commit fix.txt with "fixed-<n>", a
# per-call counter, exit 0), pushed (exit 0, no commit: the job pushed
# itself), evil (commit evil.txt, exit 0), ask (exit 1), partial (commit
# fix.txt with "partial", exit 1) or unknown (exit 3). Records job.<slot>=j1
# in state at dispatch, like the real tkt-job. Logs its full argument list
# for slot assertions.
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
  pushed) echo "TKT tkt-job DONE id=j1 head=h commits=1 gate=PASS log=x";;
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
esac
exit 0
EOF
chmod +x "$T/bin/tkt-job"

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

# Stub review-pr: $T/vermode holds ok (FIX-OK) or incomplete (FIX-INCOMPLETE).
printf 'ok' >"$T/vermode"
cat >"$T/bin/review-pr" <<EOF
#!/usr/bin/env bash
printf 'review-pr|%s\n' "\$*" >>"$T/calls.log"
case "\$(cat "$T/vermode")" in
  ok) printf 'FIX-OK\n';;
  incomplete)
    printf 'FIX-INCOMPLETE round=2\nP1 open finding in fix.txt\nP2 second finding\n';;
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
  printf '[]' >"$T/prlist"
  printf '0' >"$T/prlistrc"
  : >"$T/calls.log"
}

# New case: a bare origin, a seed main, and a clone worktree on branch
# tkt-529 pushed to the origin, with plan, findings and base state. Sets
# CDIR, WT, S. $1 is the case name.
setup_case() {
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

# Selector for the new cases below: empty or unset runs all of them.
want() { [ -z "${CASE:-}" ] || [ "$CASE" = "$1" ]; }

# 1. Verify OK on an already-pushed head: no CI wait, slot fix1, reviewed set.
setup_case ok
printf 'fixed\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "fix: fix.txt"
git -C "$WT" push -q origin tkt-529
NEW="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$NEW" >/dev/null
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
[ "$?" = "1" ] || fail "incomplete at round 2 exited $?, want 1"
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
[ "$?" = "1" ] || fail "fence breach exited $?, want 1"
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
[ "$?" = "1" ] || fail "ASK exited $?, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ASK id=j1" || fail "bad verdict: $(head -n 1 <<<"$out")"
grep -q "which design rules the retry?" <<<"$out" || fail "ASK question missing from digest"
grep -q "gh-ci|" "$T/calls.log" && fail "push ran after ASK"
[ "$(bash "$TKT_STATE" "$S" get round)" = "0" ] || fail "round moved after ASK"

# 7. Resume forwards the job id and prompt; usage errors exit 2.
setup_case resume
printf 'resume brief\n' >"$CDIR/prompt.md"
out="$(bash "$TKT" "$S" --verify --resume j9 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" || fail "resume exited $?"
grep -q "job|.*--resume j9.*--prompt $CDIR/prompt.md" "$T/calls.log" || fail "resume args not forwarded"
bash "$TKT" "$S" 2>/dev/null && fail "bare flags exited 0"
[ "$?" = "2" ] || fail "bare flags exited $?, want 2"
# 7a. Round 2 refuses a fresh fix before any slot or dispatch; --resume still runs.
setup_case round-limit
bash "$TKT_STATE" "$S" set round 2 >/dev/null
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "round 2 fix exited 0"
[ "$?" = "1" ] || fail "round 2 fix exited $?, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ROUND-LIMIT round=2" || fail "bad verdict: $(head -n 1 <<<"$out")"
grep -q "send the open findings to triage" <<<"$out" || fail "ROUND-LIMIT digest names triage"
grep -q "job|" "$T/calls.log" && fail "round 2 fix dispatched a job"
[ "$(bash "$TKT_STATE" "$S" get round)" = "2" ] || fail "round moved on ROUND-LIMIT"
setup_case round-resume
bash "$TKT_STATE" "$S" set round 2 >/dev/null
printf 'resume brief\n' >"$CDIR/prompt.md"
out="$(bash "$TKT" "$S" --verify --resume j9 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" || true
head -n 1 <<<"$out" | grep -q "ROUND-LIMIT" && fail "resume at round 2 is refused"
grep -q "job|.*--slot fix3.*--resume j9" "$T/calls.log" || fail "resume at round 2 does not dispatch on fix3"
bash "$TKT" "$S" --verify --resume j9 2>/dev/null && fail "resume without prompt exited 0"
[ "$?" = "2" ] || fail "resume without prompt exited $?, want 2"

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
[ "$?" = "1" ] || fail "gatefail exited $?, want 1"
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
[ "$?" = "3" ] || fail "drift-a exited $?, want 3"
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
[ "$?" = "3" ] || fail "recover exited $?, want 3"
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
[ "$?" = "3" ] || fail "drift-b exited $?, want 3"
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
[ "$?" = "1" ] || fail "A call 1 exited $?, want 1"
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
[ "$?" = "2" ] || fail "A3 zz exited $?, want 2"
grep -q "zz" "$T/stderr" || fail "A3 zz: stderr does not name zz"
grep -q "job|" "$T/calls.log" && fail "A3 zz dispatched a job"
fi

# A4. An UNKNOWN (exit 3) close keeps RECOVER: the slot does not advance.
if want A4; then
setup_case a4
printf 'unknown' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "A4 call 1 exited 0"
[ "$?" = "3" ] || fail "A4 call 1 exited $?, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix UNKNOWN" || fail "A4 bad verdict: $(head -n 1 <<<"$out")"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "A4 call 2 exited 0"
[ "$?" = "3" ] || fail "A4 call 2 exited $?, want 3"
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
[ "$?" = "1" ] || fail "A5 call 2 exited $?, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-INCOMPLETE round=1" || fail "A5 bad verdict: $(head -n 1 <<<"$out")"
grep -q "STOP-AT-TWO" <<<"$out" && fail "A5 call 2 printed STOP-AT-TWO"
expect_slot fix2
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "A5 round not 1"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "A5 call 3 exited 0"
[ "$?" = "1" ] || fail "A5 call 3 exited $?, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-INCOMPLETE round=2 STOP-AT-TWO" || fail "A5 bad verdict: $(head -n 1 <<<"$out")"
expect_slot fix3
[ "$(bash "$TKT_STATE" "$S" get round)" = "2" ] || fail "A5 round not 2"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "A5 call 4 exited 0"
[ "$?" = "1" ] || fail "A5 call 4 exited $?, want 1"
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
printf 'done' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "B2 clean round exited $?"
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
[ "$?" = "1" ] || fail "B3 incomplete exited $?, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-INCOMPLETE round=1" || fail "B3 bad verdict: $(head -n 1 <<<"$out")"
grep -qxF "concerns=$CDIR/run/switchyard-529-concerns-fix1.md" <<<"$out" || fail "B3 digest lacks concerns line"
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
[ "$?" = "3" ] || fail "C1 exited $?, want 3"
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
[ "$?" = "3" ] || fail "D call 2 exited $?, want 3"
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
[ "$?" = "3" ] || fail "C2 exited $?, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "C2 bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "C2 head moved"
grep -q "job|" "$T/calls.log" && fail "C2 dispatched a job"
fi

# 10a. Missing PR and head are filled from the branch's open PR before dispatch.
setup_case fill-both-ask
drop_state_key pr
drop_state_key head
printf '[{"number":7,"headRefOid":"%s"}]' "$OLD" >"$T/prlist"
printf 'ask' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "fill-both ASK exited 0"
[ "$?" = "1" ] || fail "fill-both ASK exited $?, want 1"
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
[ "$?" = "1" ] || fail "stored-values ASK exited $?, want 1"
[ "$(bash "$TKT_STATE" "$S" get pr)" = "7" ] || fail "stored-values PR changed"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "stored-values head changed"
grep -q '^gh|pr list ' "$T/calls.log" && fail "stored values still triggered PR lookup"

# 10d. A stored PR selects its matching entry, not the first entry.
setup_case fill-head-by-pr
drop_state_key head
printf '[{"number":99,"headRefOid":"other"},{"number":7,"headRefOid":"%s"}]' "$OLD" >"$T/prlist"
printf 'ask' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "head-by-PR ASK exited 0"
[ "$?" = "1" ] || fail "head-by-PR ASK exited $?, want 1"
[ "$(bash "$TKT_STATE" "$S" get pr)" = "7" ] || fail "head-by-PR changed stored PR"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "head-by-PR selected the wrong PR"

# 10e. A missing PR is filled from the first entry without replacing head.
setup_case fill-pr-by-head
drop_state_key pr
printf '[{"number":11,"headRefOid":"%s"},{"number":7,"headRefOid":"other"}]' "$OLD" >"$T/prlist"
printf 'ask' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "PR-by-head ASK exited 0"
[ "$?" = "1" ] || fail "PR-by-head ASK exited $?, want 1"
[ "$(bash "$TKT_STATE" "$S" get pr)" = "11" ] || fail "PR-by-head did not select first PR"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "PR-by-head replaced stored head"

# 10f. No open PR fails before dispatch or fixopen writes.
setup_case fill-empty
drop_state_key pr
drop_state_key head
printf '[]' >"$T/prlist"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "empty PR list exited 0"
[ "$?" = "2" ] || fail "empty PR list exited $?, want 2"
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
[ "$?" = "2" ] || fail "failed PR lookup exited $?, want 2"
grep -q 'PRECONDITION missing=pr: cannot list PRs for branch tkt-529' "$T/stderr" || fail "failed PR lookup error missing: $(cat "$T/stderr")"
grep -q '^job|' "$T/calls.log" && fail "failed PR lookup dispatched a job"

# 10h. Invalid JSON is a failed lookup, not an empty PR list.
setup_case fill-invalid-json
drop_state_key pr
drop_state_key head
printf 'not-json' >"$T/prlist"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "invalid PR JSON exited 0"
[ "$?" = "2" ] || fail "invalid PR JSON exited $?, want 2"
grep -q 'PRECONDITION missing=pr: cannot list PRs for branch tkt-529' "$T/stderr" || fail "invalid PR JSON error missing: $(cat "$T/stderr")"
grep -q '^job|' "$T/calls.log" && fail "invalid PR JSON dispatched a job"

# 10i. A stored PR missing from the open list fails before dispatch.
setup_case fill-no-match
drop_state_key head
printf '[{"number":99,"headRefOid":"other"}]' >"$T/prlist"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "non-matching PR list exited 0"
[ "$?" = "2" ] || fail "non-matching PR list exited $?, want 2"
grep -q '^job|' "$T/calls.log" && fail "non-matching PR list dispatched a job"

# 10j. A matching entry with no head fails before dispatch.
setup_case fill-empty-head
drop_state_key head
printf '[{"number":7,"headRefOid":""}]' >"$T/prlist"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "empty PR head exited 0"
[ "$?" = "2" ] || fail "empty PR head exited $?, want 2"
grep -q 'PRECONDITION missing=head:' "$T/stderr" || fail "empty PR head error missing: $(cat "$T/stderr")"
grep -q '^job|' "$T/calls.log" && fail "empty PR head dispatched a job"

echo "tkt-fix assertions passed"

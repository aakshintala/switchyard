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
export HOME="$T/home" TMPDIR="$T/tmp" TKT_BIN="$T/bin"
export PATH="$T/bin:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

ln -s "$REAL_BIN/tkt-gate" "$T/bin/tkt-gate" || fail "symlink tkt-gate"
ln -s "$REAL_BIN/tkt-state" "$T/bin/tkt-state" || fail "symlink tkt-state"
ln -s "$REAL_BIN/lib" "$T/bin/lib" || fail "symlink lib"

# Stub tkt-job: $T/jobmode holds done (commit fix.txt, exit 0), pushed (exit
# 0, no commit: the job pushed itself), evil (commit evil.txt, exit 0) or
# ask (exit 1). Logs its full argument list for slot assertions.
printf 'done' >"$T/jobmode"
cat >"$T/bin/tkt-job" <<EOF
#!/usr/bin/env bash
printf 'job|%s\n' "\$*" >>"$T/calls.log"
state="\$1"
wt="\$("$TKT_STATE" "\$state" get worktree)"
commit_as_job() {
  printf '%s' "\$2" >"\$wt/\$1"
  git -C "\$wt" add "\$1"
  git -C "\$wt" -c user.email=t@t -c user.name=t commit -qm "fix: \$1"
}
case "\$(cat "$T/jobmode")" in
  done) commit_as_job fix.txt "fixed"; echo "TKT tkt-job DONE id=j1 head=h commits=1 gate=PASS log=x";;
  pushed) echo "TKT tkt-job DONE id=j1 head=h commits=1 gate=PASS log=x";;
  evil) commit_as_job evil.txt "outside"; echo "TKT tkt-job DONE id=j1 head=h commits=1 gate=PASS log=x";;
  ask)
    echo "TKT tkt-job ASK id=j1 log=x"
    echo "which design rules the retry?"
    exit 1;;
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
case " \$* " in *" headRefOid "*)
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
  printf '0' >"$T/cimode"
  : >"$T/ciout"
  printf 'ok' >"$T/vermode"
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
bash "$TKT" "$S" --verify --resume j9 2>/dev/null && fail "resume without prompt exited 0"
[ "$?" = "2" ] || fail "resume without prompt exited $?, want 2"

# 8. A remotely advanced PR exits 3 before dispatching a second job.
setup_case prdrift
printf '0000000000000000000000000000000000000001' >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "pr drift exited 0"
[ "$?" = "3" ] || fail "pr drift exited $?, want 3"
grep -q "head drift" "$T/stderr" || fail "drift message missing from stderr"
grep -q "job|" "$T/calls.log" && fail "fix job dispatched despite PR drift"

# 9. Crash before the push: the stored fix job's commits are adopted.
setup_case crashunpushed
printf 'fixed\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "fix: fix.txt"
NEW="$(git -C "$WT" rev-parse HEAD)"
printf 'ORIGIN:%s:tkt-529' "$CDIR/origin.git" >"$T/prhead"
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
bash "$TKT_STATE" "$S" set try.fix1 "$OLD" >/dev/null
printf 'pushed' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "crash rerun exited $?"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK" || fail "bad verdict: $(head -n 1 <<<"$out")"
expect_slot fix1
[ "$(bash "$TKT_STATE" "$S" get head)" = "$NEW" ] || fail "crash head not adopted"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$NEW" ] || fail "crash push did not land"

# 10. Crash after the push: the rerun skips the wait, keeps the head.
setup_case crashpushed
printf 'fixed\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "fix: fix.txt"
git -C "$WT" push -q origin tkt-529
NEW="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
bash "$TKT_STATE" "$S" set try.fix1 "$OLD" >/dev/null
printf 'pushed' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "pushed crash rerun exited $?"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK" || fail "bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$NEW" ] || fail "pushed crash head not adopted"
grep -q "gh-ci|" "$T/calls.log" && fail "gh-ci wait ran on a pushed head"

# 11. A failed CI wait still persists the job's head for the rerun.
setup_case ciwaitfail
printf '2' >"$T/cimode"
printf 'wait broke\n' >"$T/ciout"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "ci-wait-fail exited 0"
[ "$?" = "1" ] || fail "ci-wait-fail exited $?, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix CI-WAIT rc=2" || fail "bad verdict: $(head -n 1 <<<"$out")"
NEW="$(git -C "$WT" rev-parse HEAD)"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$NEW" ] || fail "head not persisted on CI-WAIT"

# 12. Head persisted with the push pending: the rerun pushes, not drifts.
setup_case pushpending
printf 'fixed\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "fix: fix.txt"
NEW="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$NEW" >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
printf 'ORIGIN:%s:tkt-529' "$CDIR/origin.git" >"$T/prhead"
printf 'pushed' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "push-pending rerun exited $?"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK" || fail "bad verdict: $(head -n 1 <<<"$out")"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$NEW" ] || fail "pending push did not land"

# 13. An unrelated commit with only a stored job id exits 3: no dispatch, no push.
setup_case stranger
printf 'outside\n' >"$WT/evil.txt"
git -C "$WT" add evil.txt
git -C "$WT" commit -qm "outside: evil.txt"
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
printf 'pushed' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "stranger commit exited 0"
[ "$?" = "3" ] || fail "stranger commit exited $?, want 3"
grep -q "head drift" "$T/stderr" || fail "drift message missing from stderr"
grep -q "job|" "$T/calls.log" && fail "fix job dispatched for an unattributed commit"
[ "$(git -C "$WT" rev-parse "origin/tkt-529")" = "$OLD" ] || fail "stranger commit was pushed"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "head moved on a rejected entry"

# 14. A rewound remote with no pending fix job exits 3 instead of dispatching.
setup_case rewind
printf 'fixed\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm "fix: fix.txt"
NEW="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$NEW" >/dev/null
printf '%s' "$OLD" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "rewind exited 0"
[ "$?" = "3" ] || fail "rewind exited $?, want 3"
grep -q "head drift" "$T/stderr" || fail "drift message missing from stderr"
grep -q "job|" "$T/calls.log" && fail "fix job dispatched after a remote rewind"

# 15. Phase progress without the stored job still exits 3 on forward drift.
setup_case tryonly
printf 'outside\n' >"$WT/evil.txt"
git -C "$WT" add evil.txt
git -C "$WT" commit -qm "outside: evil.txt"
bash "$TKT_STATE" "$S" set try.fix1 "$OLD" >/dev/null
printf 'pushed' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "try-only entry exited 0"
[ "$?" = "3" ] || fail "try-only entry exited $?, want 3"
grep -q "job|" "$T/calls.log" && fail "fix job dispatched without a stored job id"

echo "tkt-fix assertions passed"

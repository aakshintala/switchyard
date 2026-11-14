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

ln -s "$REAL_BIN/plan-gate" "$T/bin/plan-gate" || fail "symlink plan-gate"
printf '0' >"$T/gatemode"
cat >"$T/bin/tkt-gate" <<EOF
#!/usr/bin/env bash
printf 'tkt-gate|%s\\n' "\$*" >>"$T/calls.log"
if [[ " \$* " == *" --checks-only "* ]] && [ "\$(cat "$T/gatemode")" = "2" ]; then
  printf '0' >"$T/gatemode"
  printf 'TKT tkt-gate UNKNOWN check fixture\\n'
  exit 2
fi
exec "$REAL_BIN/tkt-gate" "\$@"
EOF
chmod +x "$T/bin/tkt-gate"
ln -s "$REAL_BIN/fill-brief" "$T/bin/fill-brief" || fail "symlink fill-brief"
ln -s "$REAL_BIN/tkt-state" "$T/bin/tkt-state" || fail "symlink tkt-state"
ln -s "$REAL_BIN/tkt-fix" "$T/bin/tkt-fix" || fail "symlink tkt-fix"
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
slot=""; jobid="j1"; prev=""
for a in "\$@"; do
  if [ "\$prev" = "--slot" ]; then slot="\$a"; fi
  if [ "\$prev" = "--resume" ]; then jobid="\$a"; fi
  prev="\$a"
done
[ -n "\$slot" ] && "$TKT_STATE" "\$state" set "job.\$slot" "\$jobid" >/dev/null
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
  stop-list)
    mkdir -p "\$wt/docs"
    printf 'outside' >"\$wt/docs/outside.md"
    git -C "\$wt" add docs/outside.md
    git -C "\$wt" -c user.email=t@t -c user.name=t commit -qm "fix: docs/outside.md"
    echo "TKT tkt-job DONE id=j1 head=h commits=1 gate=PASS log=x";;
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
  backend-refusal)
    echo 'cannot resume j9: model requested-model uses backend "anthropic", but stored-model ran on backend "openai"' >&2
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

# Stub gh-ci: $T/cimode holds the wait exit (0, 1 or 2); $T/ciout holds stdout.
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
cat >"$T/bin/file-claim" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FILE_CLAIM_CALLS"
case " $* " in
  *' --diff '*)
    printf 'OVERLAP fix.txt lane:fiber-999\n'
    exit 0;;
  *) exit 0;;
esac
EOF
chmod +x "$T/bin/file-claim"
export FW_FILE_CLAIM="$T/bin/file-claim" FILE_CLAIM_CALLS="$T/file-claim.log"

reset_stubs() {
  printf 'done' >"$T/jobmode"
  printf '0' >"$T/jobcount"
  printf '0' >"$T/cimode"
  printf '0' >"$T/gatemode"
  : >"$T/ciout"
  printf 'ok' >"$T/vermode"
  printf '0' >"$T/verify-count"
  printf '[]' >"$T/prlist"
  printf '0' >"$T/prlistrc"
  : >"$T/calls.log"
  : >"$T/file-claim.log"
}

# Build the identical local git fixture once. Each case gets a private copy,
# including its own bare origin, so the real fetch/push paths remain exercised.
TEMPLATE="$T/case-template"
mkdir -p "$TEMPLATE"
git init -q --bare "$TEMPLATE/origin.git"
git --git-dir="$TEMPLATE/origin.git" symbolic-ref HEAD refs/heads/main
git init -q "$TEMPLATE/seed"
git -C "$TEMPLATE/seed" symbolic-ref HEAD refs/heads/main
git -C "$TEMPLATE/seed" config user.email t@t
git -C "$TEMPLATE/seed" config user.name t
printf 'base\n' >"$TEMPLATE/seed/base.txt"
git -C "$TEMPLATE/seed" add base.txt
git -C "$TEMPLATE/seed" commit -qm init
git -C "$TEMPLATE/seed" remote add origin "$TEMPLATE/origin.git"
git -C "$TEMPLATE/seed" push -q origin main
git clone -q "$TEMPLATE/origin.git" "$TEMPLATE/wt"
git -C "$TEMPLATE/wt" config user.email t@t
git -C "$TEMPLATE/wt" config user.name t
git -C "$TEMPLATE/wt" checkout -qb tkt-529
git -C "$TEMPLATE/wt" push -q origin tkt-529
git -C "$TEMPLATE/wt" remote set-url origin ../origin.git
rm -rf "$TEMPLATE/seed"

# New case: a private copy of the bare origin and worktree. Sets CDIR, WT, S.
# $1 is the case name.
setup_case() {
  cp "$T/tkt-job-stub" "$T/bin/tkt-job"
  unset JOB_RECORD_SYSTEM_DIR DELEGATE_JOBS_DIR
  CDIR="$T/cases/$1"
  mkdir -p "$CDIR"
  cp -R "$TEMPLATE/." "$CDIR/"
  mkdir -p "$CDIR/run"
  WT="$CDIR/wt"
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

fixture_commit() {
  local file="$1" contents="$2" message="$3"
  printf '%s\n' "$contents" >"$WT/$file"
  git -C "$WT" add "$file"
  git -C "$WT" -c user.email=t@t -c user.name=t commit -qm "$message"
}

set_closed_round() {
  local n="$1"
  bash "$TKT_STATE" "$S" set round "$n" >/dev/null
  bash "$TKT_STATE" "$S" set fixslot 2 >/dev/null
  bash "$TKT_STATE" "$S" set fixopen 0 >/dev/null
}

write_job_record() {
  local id="$1" before="$2" after="$3" resumed_from="${4:-}" record
  mkdir -p "$TMPDIR/delegate-jobs"
  record="$TMPDIR/delegate-jobs/$id.json"
  jq -n --arg hb "$before" --arg ha "$after" \
    '{status:"NEEDS_CONTEXT",result:{status:"NEEDS_CONTEXT",text:"recorded fix",changeSet:{headBefore:$hb,headAfter:$ha,newCommits:[$ha],uncommittedFiles:[],filesChanged:[],diffstat:"",dirtyAfter:false}},supervisorPid:1}' \
    >"$record" || fail "write $id record"
  if [ -n "$resumed_from" ]; then
    jq --arg id "$resumed_from" '. + {resumedFrom:$id}' "$record" >"$record.tmp" \
      && mv "$record.tmp" "$record" || fail "write $id resumedFrom"
  fi
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
fi

if want findings-overwrite-repair; then
setup_case findings-overwrite-repair
FINDINGS_PATH="$CDIR/run/switchyard-529-fix-round-1-findings.md"
printf 'existing findings\n' >"$FINDINGS_PATH"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>&1)" || run_rc=$?
[ "$run_rc" = "2" ] || fail "findings-overwrite-repair exited $run_rc, want 2: $out"
grep -Fq 'refusing to overwrite unrecorded round findings' <<<"$out" || fail "findings-overwrite-repair did not refuse overwrite: $out"
grep -Fq "tkt-state $S set fix_round.1.findings $FINDINGS_PATH" <<<"$out" || fail "findings-overwrite-repair omitted concrete re-record command: $out"
fi

if want missing-round-findings; then
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
FIX_ROUND_FINDINGS="$CDIR/run/switchyard-529-fix-round-1-findings.md"
REPAIR_PROMPT="$CDIR/missing-round-findings-prompt.md"
printf 'verify only the repaired round delta\n' >"$REPAIR_PROMPT"
bash "$TKT_STATE" "$S" set job.fix2 j1 >/dev/null
run_rc=0; out="$(bash "$TKT" "$S" --verify --resume j1 --prompt "$REPAIR_PROMPT" 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "1" ] || fail "missing-round-findings exited $run_rc, want 1: $out $(cat "$T/stderr")"
grep -Fq "FINDINGS-UNACCOUNTED commits=$ROUND1_HEAD" <<<"$out" || fail "missing-round-findings did not list its commit: $(head -n 1 <<<"$out")"
grep -Fq "rounds missing findings=1" <<<"$out" || fail "missing-round-findings did not name round 1: $out"
repair_command="$(sed -n 's/^repair command: //p' <<<"$out")"
[ -n "$repair_command" ] || fail "missing-round-findings omitted repair command: $out"
grep -Fq -- "--resume j1 --prompt $REPAIR_PROMPT" <<<"$repair_command" || fail "missing-round-findings repair did not retain its supplied prompt: $repair_command"
printf 'P1 fix.txt:1 — round one finding\n' >"$FIX_ROUND_FINDINGS"
repair_out="$(eval "$repair_command" 2>"$T/stderr")" || fail "printed missing-round-findings repair failed: $(head -n 3 <<<"$repair_out") $(cat "$T/stderr")"
head -n 1 <<<"$repair_out" | grep -q 'TKT tkt-fix FIX-OK' || fail "printed missing-round-findings repair did not pass coverage: $(head -n 1 <<<"$repair_out")"
[ "$(bash "$TKT_STATE" "$S" get fix_round.1.findings)" = "$FIX_ROUND_FINDINGS" ] || fail "missing-round-findings repair did not record the restored file"
grep -q '^review-pr|' "$T/calls.log" || fail "missing-round-findings repair did not reach review-pr"
fi

if want no-p-round-findings; then
setup_case no-p-round-findings
printf 'round one fix\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm 'fix: round one'
ROUND1_HEAD="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" push -q origin tkt-529
bash "$TKT_STATE" "$S" set head "$ROUND1_HEAD" >/dev/null
bash "$TKT_STATE" "$S" set round 1 >/dev/null
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
bash "$TKT_STATE" "$S" set fix_round.1.start "$OLD" >/dev/null
bash "$TKT_STATE" "$S" set fix_round.1.head "$ROUND1_HEAD" >/dev/null
ROUND1_FINDINGS="$CDIR/run/switchyard-529-fix-round-1-findings.md"
printf 'no open findings\n' >"$ROUND1_FINDINGS"
bash "$TKT_STATE" "$S" set fix_round.1.findings "$ROUND1_FINDINGS" >/dev/null
REPAIR_PROMPT="$CDIR/no-p-round-findings-prompt.md"
printf 'verify only the repaired round delta\n' >"$REPAIR_PROMPT"
bash "$TKT_STATE" "$S" set job.fix2 j1 >/dev/null
run_rc=0; out="$(bash "$TKT" "$S" --verify --resume j1 --prompt "$REPAIR_PROMPT" 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "1" ] || fail "no-p-round-findings exited $run_rc, want 1: $out $(cat "$T/stderr")"
grep -Fq "FINDINGS-UNACCOUNTED commits=$ROUND1_HEAD" <<<"$out" || fail "no-p-round-findings did not leave the commit unaccounted: $out"
grep -Fq "round 1 findings file has no column-0 P1/P2/P3 lines: $ROUND1_FINDINGS" <<<"$out" || fail "no-p-round-findings did not name the file: $out"
grep -Fq 'round 1 findings must be written as column-0 P<n> <path>:<line> — ... lines' <<<"$out" || fail "no-p-round-findings omitted the required format: $out"
grep -Fq 'write a NEW findings file' <<<"$out" || fail "no-p-round-findings did not require a new append-only file: $out"
new_path="$(sed -n 's/^write a NEW findings file for round 1 (originals are append-only; do not edit): //p' <<<"$out")"
[ -n "$new_path" ] || fail "no-p-round-findings omitted a new file path: $out"
[ "$new_path" != "$ROUND1_FINDINGS" ] || fail "no-p-round-findings proposed editing the original findings file"
repair_command="$(sed -n 's/^repair command: //p' <<<"$out")"
grep -Fq "tkt-state $S set fix_round.1.findings $new_path" <<<"$repair_command" || fail "no-p-round-findings repair command did not record the new file: $repair_command"
grep -Fq -- "--resume j1 --prompt $REPAIR_PROMPT" <<<"$repair_command" || fail "no-p-round-findings repair did not retain its supplied prompt: $repair_command"
printf 'P1 fix.txt:1 — replacement finding\n' >"$new_path"
repair_out="$(eval "$repair_command" 2>"$T/stderr")" || fail "printed no-p-round-findings repair failed: $(head -n 3 <<<"$repair_out") $(cat "$T/stderr")"
head -n 1 <<<"$repair_out" | grep -q 'TKT tkt-fix FIX-OK' || fail "printed no-p-round-findings repair did not pass coverage: $(head -n 1 <<<"$repair_out")"
[ "$(cat "$ROUND1_FINDINGS")" = 'no open findings' ] || fail "no-p-round-findings modified the append-only original"
fi

if want no-p-round-findings-many-commits; then
setup_case no-p-round-findings-many-commits
ROUND1_FINDINGS="$CDIR/run/switchyard-529-fix-round-1-findings.md"
printf 'no open findings\n' >"$ROUND1_FINDINGS"
for ((n=1; n<=22; n++)); do
  printf 'commit %s\n' "$n" >"$WT/fix.txt"
  git -C "$WT" add fix.txt
  git -C "$WT" commit -qm "fix: commit $n"
done
ROUND1_HEAD="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" push -q origin tkt-529
bash "$TKT_STATE" "$S" set head "$ROUND1_HEAD" >/dev/null
bash "$TKT_STATE" "$S" set round 1 >/dev/null
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
bash "$TKT_STATE" "$S" set fix_round.1.start "$OLD" >/dev/null
bash "$TKT_STATE" "$S" set fix_round.1.head "$ROUND1_HEAD" >/dev/null
bash "$TKT_STATE" "$S" set fix_round.1.findings "$ROUND1_FINDINGS" >/dev/null
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "1" ] || fail "no-p-round-findings-many-commits exited $run_rc, want 1: $out $(cat "$T/stderr")"
[ "$(grep -F -c "round 1 findings file has no column-0 P1/P2/P3 lines: $ROUND1_FINDINGS" <<<"$out" || true)" = "1" ] || fail "no-p-round-findings-many-commits did not dedupe the invalid-file note: $out"
[ "$(grep -F -c 'round 1 findings must be written as column-0 P<n> <path>:<line> — ... lines' <<<"$out" || true)" = "1" ] || fail "no-p-round-findings-many-commits did not dedupe the format note: $out"
repair_command="$(sed -n 's/^repair command: //p' <<<"$out")"
[ -n "$repair_command" ] || fail "no-p-round-findings-many-commits lost its repair command: $out"
[ "$(tail -n 1 <<<"$out")" = "repair command: $repair_command" ] || fail "no-p-round-findings-many-commits did not leave the repair command last: $out"
fi

if want since-not-ancestor; then
setup_case since-not-ancestor
# The reviews covered a lane commit, then the branch was rewritten onto main.
printf 'reviewed lane\n' >>"$WT/base.txt"
git -C "$WT" add base.txt
git -C "$WT" commit -qm 'lane: reviewed head'
OLD="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set reviewed "$OLD" >/dev/null
bash "$TKT_STATE" "$S" set head "$OLD" >/dev/null
git -C "$WT" checkout -q main
git -C "$WT" checkout -q -B tkt-529 main
printf 'rebased lane\n' >>"$WT/base.txt"
git -C "$WT" add base.txt
git -C "$WT" commit -qm 'lane: rebased head'
REBASED_HEAD="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$REBASED_HEAD" >/dev/null
printf 'done' >"$T/jobmode"
run_rc=0; out="$(bash "$TKT" "$S" --verify --since "$OLD" 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "1" ] || fail "since-not-ancestor exited $run_rc, want 1: $out $(cat "$T/stderr")"
grep -Fq "SINCE-NOT-ANCESTOR since=$OLD head=" <<<"$out" || fail "since-not-ancestor verdict missing: $out"
grep -Fq 'FINDINGS-UNACCOUNTED' <<<"$out" && fail "since-not-ancestor reported unaccounted findings: $out"
grep -Fq 'branch history was rewritten after the review' <<<"$out" || fail "since-not-ancestor did not explain the rewrite: $out"
grep -Fq 're-review the head' <<<"$out" || fail "since-not-ancestor omitted its recovery route: $out"
fi

if want unknown-gap-repair; then
setup_case unknown-gap-repair
# This hand commit landed after review but before round 1's recorded start.
printf 'hand commit\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm 'hand: between review and round start'
HAND_HEAD="$(git -C "$WT" rev-parse HEAD)"
printf 'round start marker\n' >>"$WT/base.txt"
git -C "$WT" add base.txt
git -C "$WT" commit -qm 'round: start marker'
ROUND_START="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" merge-base --is-ancestor "$HAND_HEAD" "$ROUND_START" || fail "unknown-gap-repair hand commit is not before round start"
git -C "$WT" push -q origin tkt-529
bash "$TKT_STATE" "$S" set head "$ROUND_START" >/dev/null
bash "$TKT_STATE" "$S" set fix_round.1.start "$ROUND_START" >/dev/null
printf 'done' >"$T/jobmode"
run_rc=0; out="$(bash "$TKT" "$S" --verify --since "$OLD" 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "1" ] || fail "unknown-gap-repair exited $run_rc, want 1: $out $(cat "$T/stderr")"
grep -Fq 'FINDINGS-UNACCOUNTED' <<<"$out" || fail "unknown-gap-repair did not report uncovered hand work: $out"
grep -Fq "tkt-state $S set fix_round.1.start $OLD && tkt-fix $S --verify --since $OLD" <<<"$out" || fail "unknown-gap-repair omitted concrete command: $out"
[[ "$out" != *'<'* ]] || fail "unknown-gap-repair left a placeholder in output: $out"
[ -n "$HAND_HEAD" ] || fail "unknown-gap-repair fixture did not make its hand commit"
fi

if want unknown-gap-round2; then
setup_case unknown-gap-round2
printf 'round one fix\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm 'fix: round one'
ROUND1_HEAD="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" push -q origin tkt-529
bash "$TKT_STATE" "$S" set head "$ROUND1_HEAD" >/dev/null
bash "$TKT_STATE" "$S" set round 1 >/dev/null
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
record_test_round 1 "$ROUND1_HEAD"
printf 'hand commit\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm 'hand: before round two start'
HAND_HEAD="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" push -q origin tkt-529
bash "$TKT_STATE" "$S" set head "$HAND_HEAD" >/dev/null
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "1" ] || fail "unknown-gap-round2 no-prompt exited $run_rc, want 1: $out $(cat "$T/stderr")"
grep -Fq "FINDINGS-UNACCOUNTED commits=$HAND_HEAD" <<<"$out" || fail "unknown-gap-round2 did not report its hand commit: $out"
repair_command="$(sed -n 's/^repair command: //p' <<<"$out")"
grep -Fq -- "tkt-fix $S --verify --since $OLD --resume j1 --prompt <file>" <<<"$repair_command" || fail "unknown-gap-round2 no-prompt repair omitted the literal prompt placeholder: $repair_command"
grep -Fq "write a prompt scoping the verify to the round's delta" <<<"$out" || fail "unknown-gap-round2 no-prompt omitted its scoped prompt note: $out"
[[ "$repair_command" != *"$HOME/.agents/skills/review-loop/briefs/fix.md"* ]] || fail "unknown-gap-round2 no-prompt used the fix brief as its verify prompt: $repair_command"
# A supplied prompt must survive the refusal and appear in the printed repair.
REPAIR_PROMPT="$CDIR/round-two-delta.md"
printf 'verify only the round two delta\n' >"$REPAIR_PROMPT"
run_rc=0; out="$(bash "$TKT" "$S" --verify --resume j1 --prompt "$REPAIR_PROMPT" 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "1" ] || fail "unknown-gap-round2 supplied-prompt exited $run_rc, want 1: $out $(cat "$T/stderr")"
repair_command="$(sed -n 's/^repair command: //p' <<<"$out")"
grep -Fq -- "tkt-fix $S --verify --since $OLD --resume j1 --prompt $REPAIR_PROMPT" <<<"$repair_command" || fail "unknown-gap-round2 repair omitted the supplied prompt: $repair_command"
# The repair note asks for ownership metadata. Once recorded, the printed
# command must be executable and move past coverage.
ROUND2_HEAD="$(bash "$TKT_STATE" "$S" get fix_round.2.head)"
bash "$TKT_STATE" "$S" set fix_round.2.start "$ROUND1_HEAD" >/dev/null
repair_out="$(eval "$repair_command" 2>"$T/stderr")" || fail "printed unknown-gap-round2 repair failed: $(head -n 3 <<<"$repair_out") $(cat "$T/stderr")"
head -n 1 <<<"$repair_out" | grep -q 'TKT tkt-fix FIX-OK' || fail "printed unknown-gap-round2 repair did not pass coverage: $(head -n 1 <<<"$repair_out")"
[ -n "$ROUND2_HEAD" ] || fail "unknown-gap-round2 had no recorded round head"
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

# Merging main into the branch brings main's own commits into since..head.
# Coverage walks the branch's first-parent chain, so clean main merges before
# a round need the exemption while merges with hand edits need an owner.

# Advance main by one commit, push it, and merge main into the branch.
# Sets MAIN_COMMIT and MERGE.
merge_main() {
  git -C "$WT" checkout -q main
  printf 'main moved\n' >>"$WT/main.txt"
  git -C "$WT" add main.txt
  git -C "$WT" commit -qm 'main: unrelated commit'
  MAIN_COMMIT="$(git -C "$WT" rev-parse HEAD)"
  git -C "$WT" push -q origin main
  git -C "$WT" checkout -q tkt-529
  git -C "$WT" merge -q --no-edit main
  if [ "${1:-}" = hand-edit ]; then
    printf 'manual merge edit\n' >>"$WT/main.txt"
    git -C "$WT" add main.txt
    git -C "$WT" commit --amend -q --no-edit
  fi
  MERGE="$(git -C "$WT" rev-parse HEAD)"
  git -C "$WT" push -q origin tkt-529
}

# $1 is the case name; $2 is "in" (round 1 ends at the merge) or "after"
# (round 1 ends before it). Optional $3 creates a hand-edited merge.
# Sets ROUND1_FIX, MAIN_COMMIT, MERGE.
setup_main_merge() {
  setup_case "$1"
  # A lane commit, so the reviewed head (and round 1's start) is on the
  # branch and main's later commit does not descend from it.
  printf 'lane\n' >>"$WT/base.txt"
  git -C "$WT" add base.txt
  git -C "$WT" commit -qm 'lane: work'
  OLD="$(git -C "$WT" rev-parse HEAD)"
  bash "$TKT_STATE" "$S" set reviewed "$OLD" >/dev/null
  printf 'round one fix\n' >"$WT/fix.txt"
  git -C "$WT" add fix.txt
  git -C "$WT" commit -qm 'fix: round one'
  ROUND1_FIX="$(git -C "$WT" rev-parse HEAD)"
  merge_main "${3:-}"
  bash "$TKT_STATE" "$S" set head "$MERGE" >/dev/null
  bash "$TKT_STATE" "$S" set round 1 >/dev/null
  bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
  if [ "$2" = in ]; then record_test_round 1 "$MERGE"; else record_test_round 1 "$ROUND1_FIX"; fi
}

if want main-merge-before-round; then
setup_case main-merge-before-round
# A clean main merge landed after review and before round 1 began.
printf 'lane\n' >>"$WT/base.txt"
git -C "$WT" add base.txt
git -C "$WT" commit -qm 'lane: work'
OLD="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set reviewed "$OLD" >/dev/null
merge_main
printf 'round one fix\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm 'fix: round one'
ROUND1_FIX="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" push -q origin tkt-529
bash "$TKT_STATE" "$S" set head "$ROUND1_FIX" >/dev/null
bash "$TKT_STATE" "$S" set round 1 >/dev/null
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
record_test_round 1 "$ROUND1_FIX"
bash "$TKT_STATE" "$S" set fix_round.1.start "$MERGE" >/dev/null
AUTO_TREE="$(git -C "$WT" merge-tree --write-tree "$MERGE^1" "$MERGE^2")" || fail "main-merge-before-round could not compute automatic merge tree"
[ "$(git -C "$WT" rev-parse "$MERGE^{tree}")" = "$AUTO_TREE" ] || fail "main-merge-before-round merge tree is not clean"
git -C "$WT" merge-base --is-ancestor "$MERGE^2" origin/main || fail "main-merge-before-round second parent is not on origin/main"
out="$(bash "$TKT" "$S" --verify --since "$OLD" 2>"$T/stderr")" || fail "main-merge-before-round exited $?: $(head -n 3 <<<"$out") $(cat "$T/stderr")"
grep -Fq 'FINDINGS-UNACCOUNTED' <<<"$out" && fail "main-merge-before-round reported unowned clean merge: $out"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix FIX-OK' || fail "main-merge-before-round bad verdict: $(head -n 1 <<<"$out")"
fi

if want main-merge; then
setup_main_merge main-merge in
out="$(bash "$TKT" "$S" --verify --since "$OLD" 2>"$T/stderr")" || fail "main-merge exited $?: $(head -n 3 <<<"$out") $(cat "$T/stderr")"
grep -Fq "$MAIN_COMMIT" <<<"$out" && fail "main-merge reported main's commit: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix FIX-OK' || fail "main-merge bad verdict: $(head -n 1 <<<"$out")"

setup_main_merge main-merge-unowned after hand-edit
run_rc=0; out="$(bash "$TKT" "$S" --verify --since "$OLD" 2>"$T/stderr")" || run_rc=$?
AUTO_TREE="$(git -C "$WT" merge-tree --write-tree "$MERGE^1" "$MERGE^2")" || fail "main-merge-unowned could not compute automatic merge tree"
[ "$(git -C "$WT" rev-parse "$MERGE^{tree}")" != "$AUTO_TREE" ] || fail "main-merge-unowned merge tree has no hand edit"
[ "$run_rc" = "1" ] || fail "main-merge-unowned exited $run_rc, want 1: $out"
grep -Fq "FINDINGS-UNACCOUNTED commits=$MERGE" <<<"$out" || fail "main-merge-unowned did not report only the merge: $(head -n 1 <<<"$out")"
grep -Fq "$MAIN_COMMIT" <<<"$out" && fail "main-merge-unowned reported main's commit: $(head -n 1 <<<"$out")"
grep -q '^review-pr|' "$T/calls.log" && fail "main-merge-unowned ran review-pr on uncovered commits"
fi

if want main-merge-multi; then
# Two main merges with a fix commit between them, across two rounds:
# round 1 is fix, merge; round 2 is fix, merge.
setup_main_merge main-merge-multi in
MAIN1="$MAIN_COMMIT"
printf 'round two fix\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm 'fix: round two'
merge_main
MAIN2="$MAIN_COMMIT"
bash "$TKT_STATE" "$S" set head "$MERGE" >/dev/null
# round counts verify rounds; 1 keeps this run under the two-round limit.
bash "$TKT_STATE" "$S" set fixslot 2 >/dev/null
record_test_round 2 "$MERGE"
out="$(bash "$TKT" "$S" --verify --since "$OLD" 2>"$T/stderr")" || fail "main-merge-multi exited $?: $(head -n 3 <<<"$out") $(cat "$T/stderr")"
grep -Fq "$MAIN1" <<<"$out" && fail "main-merge-multi reported main's first commit: $(head -n 1 <<<"$out")"
grep -Fq "$MAIN2" <<<"$out" && fail "main-merge-multi reported main's second commit: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix FIX-OK' || fail "main-merge-multi bad verdict: $(head -n 1 <<<"$out")"
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
grep -F -q "claim --lane fiber-529 --diff $WT" "$T/file-claim.log" || fail "successful push records changed hunks"
grep -F -q 'OVERLAP fix.txt lane:fiber-999' "$T/stderr" || fail "overlapping claim is reported after push"
grep -q "failing: nightly" <<<"$out" || fail "failed CI jobs missing from digest"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK" || fail "bad verdict: $(head -n 1 <<<"$out")"

# 4. A stop-list breach after the fix passes through with the gate's verdict.
setup_case fence
printf 'stop-list' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "stop-list breach exited 0"
rc=$?; [ "$rc" = "1" ] || fail "stop-list breach exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix STOP-LIST n=1" || fail "bad verdict: $(head -n 1 <<<"$out")"
grep -Fq 'docs/outside.md — contract change: ask first' <<<"$out" || fail "stop-list path and reason missing from digest: $out"

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
grep -q 'job|.*--model' "$T/calls.log" && fail "resume without --fix-model passed a model"

# A plan-declared Fix gate substitutes the pre-fix HEAD for <since> and is
# passed as both the job gate and the fresh fix brief's GATE value.
if want fix-gate; then
setup_case fix-gate
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `base.txt`
- `fix.txt`

## Gate

`true`

## Fix gate

`bash test/run --since <since> && bash bin/check-pack`
EOF
bash "$TKT_STATE" "$S" set env 'FOO=1 BAR=2' >/dev/null
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "fix-gate exited $?: $(cat "$T/stderr")"
expected_gate="bash test/run --since $OLD && bash bin/check-pack"
grep -Fq -- "--gate FOO=1 BAR=2 $expected_gate" "$T/calls.log" || fail "fix-gate job gate was not substituted with env: $(cat "$T/calls.log")"
! grep -Fq -- '--gate-from-plan' "$T/calls.log" || fail "fix-gate passed --gate-from-plan: $(cat "$T/calls.log")"
grep -Fq "GATE=$expected_gate" "$T/calls.log" || fail "fix-gate brief did not name substituted gate: $(cat "$T/calls.log")"
fi

# A resumed fix job also receives its plan-declared gate with the round-start SHA.
if want fix-gate-resume; then
setup_case fix-gate-resume
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `base.txt`
- `fix.txt`

## Gate

`true`

## Fix gate

`bash test/run --since <since> && bash bin/check-pack`
EOF
printf 'pre-resume fix\n' >"$WT/fix.txt"
git -C "$WT" add fix.txt
git -C "$WT" commit -qm 'fix: pre-resume change'
git -C "$WT" push -q origin tkt-529
PRE_JOB_HEAD="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$PRE_JOB_HEAD" >/dev/null
bash "$TKT_STATE" "$S" set reviewed "$PRE_JOB_HEAD" >/dev/null
bash "$TKT_STATE" "$S" set fix_round.1.start "$OLD" >/dev/null
bash "$TKT_STATE" "$S" set env 'FOO=1' >/dev/null
printf 'resume brief\n' >"$CDIR/prompt.md"
out="$(bash "$TKT" "$S" --verify --resume j9 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" || fail "fix-gate-resume exited $?: $(cat "$T/stderr")"
expected_gate="bash test/run --since $OLD && bash bin/check-pack"
grep -Fq -- "--gate FOO=1 $expected_gate" "$T/calls.log" || fail "fix-gate-resume did not pass substituted gate with env: $(cat "$T/calls.log")"
! grep -Fq -- '--gate-from-plan' "$T/calls.log" || fail "fix-gate-resume passed --gate-from-plan: $(cat "$T/calls.log")"
fi

# Without a Fix gate the fresh job keeps --gate-from-plan and GATE is the full Gate.
if want fix-gate-fallback; then
setup_case fix-gate-fallback
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "fix-gate-fallback exited $?: $(cat "$T/stderr")"
grep -Fq -- '--gate-from-plan' "$T/calls.log" || fail "fix-gate-fallback did not pass --gate-from-plan: $(cat "$T/calls.log")"
grep -Fq 'GATE=true' "$T/calls.log" || fail "fix-gate-fallback brief did not retain full gate: $(cat "$T/calls.log")"
! grep -Fq 'Fix gate' "$T/stderr" || fail "fix-gate-fallback printed plan-gate's missing-heading note: $(cat "$T/stderr")"
fi

# --fix-model overrides the stored model for a resume.
if want RESUME-MODEL; then
setup_case resume-model
printf 'resume brief\n' >"$CDIR/prompt.md"
out="$(bash "$TKT" "$S" --verify --resume j9 --prompt "$CDIR/prompt.md" --fix-model requested-model 2>"$T/stderr")" || fail "resume-model exited $?"
grep -q "job|.*--resume j9.*--prompt $CDIR/prompt.md.*--model requested-model.*--gate-from-plan" "$T/calls.log" || fail "resume-model did not forward --fix-model to tkt-job: $(cat "$T/calls.log")"
fi

# A backend switch refusal keeps delegate's message and points to a fresh fix job.
if want RESUME-BACKEND-REFUSAL; then
setup_case resume-backend-refusal
printf 'resume brief\n' >"$CDIR/prompt.md"
printf 'backend-refusal' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify --resume j9 --prompt "$CDIR/prompt.md" --fix-model requested-model 2>"$T/stderr")" && fail "resume backend refusal exited 0"
rc=$?; [ "$rc" = "3" ] || fail "resume backend refusal exited $rc, want 3"
grep -Fq 'cannot resume j9: model requested-model uses backend "anthropic", but stored-model ran on backend "openai"' "$T/stderr" || fail "delegate backend refusal missing from stderr: $(cat "$T/stderr")"
grep -Fq 'tkt-fix: start a fresh fix job (drop --resume) with --fix-model requested-model' "$T/stderr" || fail "backend refusal fresh-job hint missing: $(cat "$T/stderr")"
grep -q 'job|.*--model requested-model' "$T/calls.log" || fail "backend refusal did not pass requested model to tkt-job"
fi

# 7b. With gate.script set, a resume whose plan Gate line skips the script stops before dispatch.
setup_case resume-gate-script
printf 'gate.script=%s\n' scripts/check >>"$S"
printf 'resume brief\n' >"$CDIR/prompt.md"
bash "$TKT" "$S" --verify --resume j9 --prompt "$CDIR/prompt.md" >/dev/null 2>"$T/stderr" && fail "resume-gate-script exited 0"
grep -q "job|" "$T/calls.log" && fail "resume-gate-script dispatched a job"
bash "$TKT" "$S" 2>"$T/stderr" && fail "bare flags exited 0"
rc=$?; [ "$rc" = "2" ] || fail "bare flags exited $rc, want 2"
grep -Fq -- '--fix-model <id> overrides the stored model on --resume' "$T/stderr" || fail "usage does not explain --fix-model on resume: $(cat "$T/stderr")"
# 7a. Round 2 refuses a fresh fix before any slot or dispatch; --resume still runs.
if want R2; then
setup_case round-limit
bash "$TKT_STATE" "$S" set round 2 >/dev/null
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "round 2 fix exited 0"
rc=$?; [ "$rc" = "1" ] || fail "round 2 fix exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ROUND-LIMIT round=2" || fail "bad verdict: $(head -n 1 <<<"$out")"
grep -q "tkt-fix .*--resume <job id> --prompt <file>" <<<"$out" || fail "ROUND-LIMIT names the resume command and prompt"
grep -q "works with no open slot" <<<"$out" || fail "ROUND-LIMIT says resume needs no open slot"
grep -q "job|" "$T/calls.log" && fail "round 2 fix dispatched a job"
[ "$(bash "$TKT_STATE" "$S" get round)" = "2" ] || fail "round moved on ROUND-LIMIT"
fi
if want R6; then
setup_case round-resume
bash "$TKT_STATE" "$S" set round 2 >/dev/null
printf 'resume brief\n' >"$CDIR/prompt.md"
out="$(bash "$TKT" "$S" --verify --resume j9 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" || true
head -n 1 <<<"$out" | grep -q "ROUND-LIMIT" && fail "resume at round 2 is refused"
grep -q "job|.*--slot fix3.*--resume j9" "$T/calls.log" || fail "resume at round 2 does not dispatch on fix3"
bash "$TKT" "$S" --verify --resume j9 2>/dev/null && fail "resume without prompt exited 0"
rc=$?; [ "$rc" = "2" ] || fail "resume without prompt exited $rc, want 2"
fi

# R1: round 2 recovers and pushes a closed-slot commit owned by its job record.
if want R1; then
setup_case r1
set_closed_round 2
fixture_commit fix.txt "round two fix" "fix: round two"
A="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set job.fix2 j2 >/dev/null
write_job_record j2 "$OLD" "$A"
record_test_round 2 "$A"
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "R1 exited $?: $(head -n 1 <<<"$out"): $(cat "$T/stderr")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=$A" || fail "R1 bad verdict: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q "ROUND-LIMIT" && fail "R1 was blocked by ROUND-LIMIT"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$A" ] || fail "R1 state head did not advance"
[ "$(bash "$TKT_STATE" "$S" get fixopen)" = "0" ] || fail "R1 left fixopen set"
[ "$(bash "$TKT_STATE" "$S" get round)" = "3" ] || fail "R1 round did not advance from 2 to 3"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$A" ] || fail "R1 did not push the recovery commit"
grep -q "job|" "$T/calls.log" && fail "R1 dispatched a fix job"
fi

# R3: a round-2 open-slot recovery remains behind ROUND-LIMIT.
if want R3; then
setup_case r3
set_closed_round 2
fixture_commit fix.txt "open round two fix" "fix: open round two"
A="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set fixopen 1 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
write_job_record j1 "$OLD" "$A"
printf '%s' "$OLD" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "R3 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "R3 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ROUND-LIMIT round=2" || fail "R3 bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "R3 state head changed"
[ "$(bash "$TKT_STATE" "$S" get fixopen)" = "1" ] || fail "R3 fixopen changed"
[ "$(bash "$TKT_STATE" "$S" get round)" = "2" ] || fail "R3 round changed"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "R3 pushed"
grep -q "job|" "$T/calls.log" && fail "R3 dispatched a fix job"
fi

# R4: round-2 drift that cannot recover keeps the ROUND-LIMIT verdict.
if want R4; then
setup_case r4
set_closed_round 2
fixture_commit fix.txt "state-only head" "fix: state-only head"
SHEAD="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$SHEAD" >/dev/null
printf '%s' "$OLD" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "R4 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "R4 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ROUND-LIMIT round=2" || fail "R4 bad verdict: $(head -n 1 <<<"$out")"
grep -q "TKT tkt-fix DRIFT" <<<"$out" && fail "R4 returned DRIFT instead of ROUND-LIMIT"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$SHEAD" ] || fail "R4 state head changed"
grep -q "job|" "$T/calls.log" && fail "R4 dispatched a fix job"
fi

# R5: a dirty closed-slot recovery remains behind ROUND-LIMIT.
if want R5; then
setup_case r5
set_closed_round 2
fixture_commit fix.txt "dirty round two fix" "fix: dirty round two"
printf 'untracked\n' >"$WT/untracked.txt"
printf '%s' "$OLD" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "R5 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "R5 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ROUND-LIMIT round=2" || fail "R5 bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "R5 state head changed"
[ -f "$WT/untracked.txt" ] || fail "R5 dirty worktree changed"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "R5 pushed"
grep -q "job|" "$T/calls.log" && fail "R5 dispatched a fix job"
fi

# R7: round 3 remains at ROUND-LIMIT even when the heads agree.
if want R7; then
setup_case r7
bash "$TKT_STATE" "$S" set round 3 >/dev/null
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "R7 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "R7 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ROUND-LIMIT round=3" || fail "R7 bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "R7 state head changed"
[ "$(bash "$TKT_STATE" "$S" get round)" = "3" ] || fail "R7 round changed"
grep -q "job|" "$T/calls.log" && fail "R7 dispatched a fix job"
fi

# R8: round 3 refuses the same closed-slot recovery accepted at round 2.
if want R8; then
setup_case r8
set_closed_round 3
fixture_commit fix.txt "round three fix" "fix: round three"
A="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set job.fix2 j2 >/dev/null
write_job_record j2 "$OLD" "$A"
printf '%s' "$OLD" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "R8 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "R8 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ROUND-LIMIT round=3" || fail "R8 bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "R8 state head changed"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "R8 pushed"
grep -q "job|" "$T/calls.log" && fail "R8 dispatched a fix job"
fi

# R9: a round-2 outside commit above the recorded head is not recoverable.
if want R9; then
setup_case r9
set_closed_round 2
fixture_commit fix.txt "round two own fix" "fix: round two own"
A="$(git -C "$WT" rev-parse HEAD)"
fixture_commit outside.txt "outside commit" "outside: round two"
bash "$TKT_STATE" "$S" set job.fix2 j2 >/dev/null
write_job_record j2 "$OLD" "$A"
printf '%s' "$OLD" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "R9 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "R9 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ROUND-LIMIT round=2" || fail "R9 bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "R9 state head changed"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "R9 pushed"
grep -q "job|" "$T/calls.log" && fail "R9 dispatched a fix job"
fi

# R10: round-2 closed-slot recovery without a job record remains limited.
if want R10; then
setup_case r10
set_closed_round 2
rm -f "$TMPDIR/delegate-jobs/j2.json"
fixture_commit fix.txt "round two unrecorded fix" "fix: round two unrecorded"
bash "$TKT_STATE" "$S" set job.fix2 j2 >/dev/null
printf '%s' "$OLD" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "R10 exited 0"
rc=$?; [ "$rc" = "1" ] || fail "R10 exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ROUND-LIMIT round=2" || fail "R10 bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "R10 state head changed"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "R10 pushed"
grep -q "job|" "$T/calls.log" && fail "R10 dispatched a fix job"
fi

# H1: state-owned closed-slot commits recover at round 0 with a matching record.
if want H1; then
setup_case h1
set_closed_round 0
fixture_commit fix.txt "first owned fix" "fix: first owned"
A1="$(git -C "$WT" rev-parse HEAD)"
fixture_commit fix.txt "second owned fix" "fix: second owned"
A2="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$A2" >/dev/null
bash "$TKT_STATE" "$S" set fixslot 3 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
bash "$TKT_STATE" "$S" set job.fix2 j2 >/dev/null
bash "$TKT_STATE" "$S" set job.fix3 j3 >/dev/null
write_job_record j1 "$OLD" "$A1"
write_job_record j2 "$A1" "$A2"
write_job_record j3 "$A2" "$A2"
record_test_round 3 "$A2"
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "H1 exited $?: $(head -n 1 <<<"$out"): $(cat "$T/stderr")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=$A2" || fail "H1 bad verdict: $(head -n 1 <<<"$out")"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$A2" ] || fail "H1 did not push the recovery commits"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$A2" ] || fail "H1 state head did not advance"
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "H1 round did not advance to 1"
grep -q "job|" "$T/calls.log" && fail "H1 dispatched a fix job"
fi

# H2: a mismatched headAfter does not prove ownership of state-owned commits.
if want H2; then
setup_case h2
set_closed_round 0
fixture_commit fix.txt "first owned fix" "fix: first owned"
A1="$(git -C "$WT" rev-parse HEAD)"
fixture_commit fix.txt "second owned fix" "fix: second owned"
A2="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$A2" >/dev/null
bash "$TKT_STATE" "$S" set fixslot 3 >/dev/null
bash "$TKT_STATE" "$S" set job.fix3 j3 >/dev/null
write_job_record j3 "$A2" "$A1"
record_test_round 3 "$A2"
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "3" ] || fail "H2 exited $run_rc, want DRIFT 3: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "H2 bad verdict: $(head -n 1 <<<"$out")"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "H2 pushed without ownership"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$A2" ] || fail "H2 changed state head"
grep -q "job|" "$T/calls.log" && fail "H2 dispatched a fix job"
fi

# H3: a missing job record does not prove ownership of state-owned commits.
if want H3; then
setup_case h3
set_closed_round 0
fixture_commit fix.txt "first owned fix" "fix: first owned"
A1="$(git -C "$WT" rev-parse HEAD)"
fixture_commit fix.txt "second owned fix" "fix: second owned"
A2="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$A2" >/dev/null
bash "$TKT_STATE" "$S" set fixslot 3 >/dev/null
bash "$TKT_STATE" "$S" set job.fix3 j3 >/dev/null
rm -f "$TMPDIR/delegate-jobs/j3.json"
record_test_round 3 "$A2"
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "3" ] || fail "H3 exited $run_rc, want DRIFT 3: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "H3 bad verdict: $(head -n 1 <<<"$out")"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "H3 pushed without a job record"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$A2" ] || fail "H3 changed state head"
grep -q "job|" "$T/calls.log" && fail "H3 dispatched a fix job"
fi

# H4: owned state-head recovery remains exempt at round 2 and advances to 3.
if want H4; then
setup_case h4
set_closed_round 2
fixture_commit fix.txt "first owned fix" "fix: first owned"
A1="$(git -C "$WT" rev-parse HEAD)"
fixture_commit fix.txt "second owned fix" "fix: second owned"
A2="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$A2" >/dev/null
bash "$TKT_STATE" "$S" set fixslot 3 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
bash "$TKT_STATE" "$S" set job.fix2 j2 >/dev/null
bash "$TKT_STATE" "$S" set job.fix3 j3 >/dev/null
write_job_record j1 "$OLD" "$A1"
write_job_record j2 "$A1" "$A2"
write_job_record j3 "$A2" "$A2"
record_test_round 3 "$A2"
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "H4 exited $?: $(head -n 1 <<<"$out"): $(cat "$T/stderr")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=$A2" || fail "H4 bad verdict: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q "ROUND-LIMIT" && fail "H4 was blocked by ROUND-LIMIT"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$A2" ] || fail "H4 did not push the recovery commits"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$A2" ] || fail "H4 state head did not advance"
[ "$(bash "$TKT_STATE" "$S" get round)" = "3" ] || fail "H4 round did not advance from 2 to 3"
grep -q "job|" "$T/calls.log" && fail "H4 dispatched a fix job"
fi

# H5: round-2 state-head recovery without its job record remains limited.
if want H5; then
setup_case h5
set_closed_round 2
fixture_commit fix.txt "first owned fix" "fix: first owned"
A1="$(git -C "$WT" rev-parse HEAD)"
fixture_commit fix.txt "second owned fix" "fix: second owned"
A2="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$A2" >/dev/null
bash "$TKT_STATE" "$S" set fixslot 3 >/dev/null
bash "$TKT_STATE" "$S" set job.fix3 j3 >/dev/null
rm -f "$TMPDIR/delegate-jobs/j3.json"
record_test_round 3 "$A2"
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "1" ] || fail "H5 exited $run_rc, want ROUND-LIMIT: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix ROUND-LIMIT round=2" || fail "H5 bad verdict: $(head -n 1 <<<"$out")"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "H5 pushed without a job record"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$A2" ] || fail "H5 changed state head"
[ "$(bash "$TKT_STATE" "$S" get round)" = "2" ] || fail "H5 changed the round"
grep -q "job|" "$T/calls.log" && fail "H5 dispatched a fix job"
fi

# H6: state ownership does not recover when the PR head is a sibling commit.
if want H6; then
setup_case h6
set_closed_round 0
fixture_commit sibling.txt "sibling PR head" "pr: sibling head"
PPR="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" push -q origin HEAD:pr-head
git -C "$WT" reset -q --hard "$OLD"
fixture_commit fix.txt "state-owned sibling" "fix: state-owned sibling"
A="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$A" >/dev/null
bash "$TKT_STATE" "$S" set fixslot 3 >/dev/null
bash "$TKT_STATE" "$S" set job.fix3 j3 >/dev/null
write_job_record j3 "$A" "$A"
record_test_round 3 "$A"
printf 'ORIGIN:%s:refs/heads/pr-head' "$CDIR/origin.git" >"$T/prhead"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "3" ] || fail "H6 exited $run_rc, want DRIFT 3: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "H6 bad verdict: $(head -n 1 <<<"$out")"
[ "$(git --git-dir="$CDIR/origin.git" rev-parse refs/heads/pr-head)" = "$PPR" ] || fail "H6 PR head changed"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "H6 pushed a non-descendant"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$A" ] || fail "H6 changed state head"
grep -q "job|" "$T/calls.log" && fail "H6 dispatched a fix job"
fi

# H7: the H1 state on a dirty tree drifts; arm 2 still requires a clean tree.
if want H7; then
setup_case h7
set_closed_round 0
fixture_commit fix.txt "first owned fix" "fix: first owned"
fixture_commit fix.txt "second owned fix" "fix: second owned"
A2="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$A2" >/dev/null
bash "$TKT_STATE" "$S" set fixslot 3 >/dev/null
bash "$TKT_STATE" "$S" set job.fix3 j3 >/dev/null
write_job_record j3 "$A2" "$A2"
record_test_round 3 "$A2"
printf 'untracked\n' >"$WT/untracked.txt"
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "3" ] || fail "H7 exited $run_rc, want DRIFT 3: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "H7 bad verdict: $(head -n 1 <<<"$out")"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "H7 pushed from a dirty tree"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$A2" ] || fail "H7 changed state head"
[ -f "$WT/untracked.txt" ] || fail "H7 dirty worktree changed"
grep -q "job|" "$T/calls.log" && fail "H7 dispatched a fix job"
fi

# 7b. A takeover uses its recorded gate without a plan file.
setup_case takeover
rm -f "$CDIR/plan.md"
drop_state_key plan
bash "$TKT_STATE" "$S" set plan 'takeover #123' >/dev/null
bash "$TKT_STATE" "$S" set gate 'bash test/run && bash bin/check-pack' >/dev/null
bash "$TKT_STATE" "$S" add fence fix.txt >/dev/null
bash "$TKT_STATE" "$S" set env 'FOO=1 BAR=2' >/dev/null
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "takeover exited $? (stderr: $(cat "$T/stderr"); calls: $(cat "$T/calls.log"))"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=" || fail "takeover bad verdict: $(head -n 1 <<<"$out")"
grep -F -q 'GATE=bash test/run && bash bin/check-pack' "$T/calls.log" || fail "takeover gate not passed to fix brief"
grep -F -q -- '--gate FOO=1 BAR=2 bash test/run && bash bin/check-pack' "$T/calls.log" || fail "takeover gate not passed to tkt-job with state env"

setup_case takeover-resume
rm -f "$CDIR/plan.md"
drop_state_key plan
bash "$TKT_STATE" "$S" set plan 'takeover #123' >/dev/null
bash "$TKT_STATE" "$S" set gate 'bash test/run && bash bin/check-pack' >/dev/null
bash "$TKT_STATE" "$S" add fence fix.txt >/dev/null
bash "$TKT_STATE" "$S" set env 'FOO=1 BAR=2' >/dev/null
printf 'resume brief\n' >"$CDIR/prompt.md"
out="$(bash "$TKT" "$S" --verify --resume j9 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" || fail "takeover resume exited $? (stderr: $(cat "$T/stderr"))"
grep -F -q -- "--resume j9 --prompt $CDIR/prompt.md --gate FOO=1 BAR=2 bash test/run && bash bin/check-pack" "$T/calls.log" || fail "takeover resume did not pass the stored gate directly with state env"
grep -q 'job|.*--gate-from-plan' "$T/calls.log" && fail "takeover resume requested a nonexistent plan gate"

# Ordinary states without a plan, bare takeover values, and takeover without a
# gate remain refusals before a fix job is dispatched.
setup_case no-plan
rm -f "$CDIR/plan.md"
drop_state_key plan
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "ordinary missing plan exited 0"
rc=$?; [ "$rc" = "2" ] || fail "ordinary missing plan exited $rc, want 2"
grep -q 'missing key: plan' "$T/stderr" || fail "ordinary missing plan did not name plan"
grep -q 'job|' "$T/calls.log" && fail "ordinary missing plan dispatched a job"

setup_case bare-takeover
rm -f "$CDIR/plan.md"
drop_state_key plan
bash "$TKT_STATE" "$S" set plan takeover >/dev/null
bash "$TKT_STATE" "$S" set gate 'bash test/run' >/dev/null
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "bare takeover exited 0"
rc=$?; [ "$rc" = "2" ] || fail "bare takeover exited $rc, want 2"
grep -Fq 'invalid takeover plan value' "$T/stderr" || fail "bare takeover refusal did not identify its invalid value"
grep -q 'job|' "$T/calls.log" && fail "bare takeover dispatched a job"

setup_case takeover-no-gate
rm -f "$CDIR/plan.md"
drop_state_key plan
bash "$TKT_STATE" "$S" set plan 'takeover #123' >/dev/null
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "takeover without gate exited 0"
rc=$?; [ "$rc" = "2" ] || fail "takeover without gate exited $rc, want 2"
grep -qi 'takeover.*gate\|missing.*gate' "$T/stderr" || fail "takeover without gate did not name its missing gate"
grep -q 'job|' "$T/calls.log" && fail "takeover without gate dispatched a job"

# The fix brief gets the plan gate as GATE (fix.md fills __GATE__).
setup_case gatefill
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "gatefill exited $?"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=" || fail "gatefill bad verdict: $(head -n 1 <<<"$out")"
grep -F -q "GATE=true" "$T/calls.log" || fail "gatefill: GATE=true not passed to tkt-job"

# 7c. A STOP-LIST stop closes its slot without counting a round; the next call
# dispatches fix2, not RECOVER on fix1.
setup_case gatefail
printf 'stop-list' >"$T/jobmode"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "gatefail exited 0"
rc=$?; [ "$rc" = "1" ] || fail "gatefail exited $rc, want 1"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix STOP-LIST n=1" || fail "bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get round)" = "0" ] || fail "STOP-LIST changed round"
[ "$(bash "$TKT_STATE" "$S" get fixslot)" = "1" ] || fail "STOP-LIST did not close its slot"
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
grep -qF "after a rebase or main merge, run: tkt-state $S set head $NEW" <<<"$out" || fail "set-head route missing from DRIFT A digest"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "head moved on DRIFT A"
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
grep -q "set head" <<<"$out" && fail "set-head route printed on DRIFT B"
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
jq -n --arg hb "$OLD" --arg ha "$NEW" '{status:"NEEDS_CONTEXT",result:{status:"NEEDS_CONTEXT",text:"which design rules the retry?",changeSet:{headBefore:$hb,headAfter:$ha,newCommits:[$ha],uncommittedFiles:[],filesChanged:[],diffstat:"",dirtyAfter:false}},supervisorPid:1}' >"$TMPDIR/delegate-jobs/j1.json" || fail "E record write"
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

# C-a. The open job's record proves a chain from the intermediate stored head.
if want C-a; then
setup_case c-a
fixture_commit fix.txt "first unpushed fix" "fix: first unpushed"
SHEAD="$(git -C "$WT" rev-parse HEAD)"
fixture_commit fix.txt "second unpushed fix" "fix: second unpushed"
A="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$SHEAD" >/dev/null
bash "$TKT_STATE" "$S" set round 1 >/dev/null
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
bash "$TKT_STATE" "$S" set fixopen 2 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
write_job_record j1 "$OLD" "$SHEAD"
bash "$TKT_STATE" "$S" set job.fix2 j2 >/dev/null
write_job_record j2 "$SHEAD" "$A"
printf '%s' "$OLD" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "C-a exited 0"
rc=$?; [ "$rc" = "3" ] || fail "C-a exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix RECOVER" || fail "C-a bad verdict: $(head -n 1 <<<"$out")"
grep -q "job=j2" <<<"$out" || fail "C-a job id missing from RECOVER digest"
grep -q "slot=fix2" <<<"$out" || fail "C-a slot missing from RECOVER digest"
grep -q "DRIFT" <<<"$out" && fail "C-a returned DRIFT"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$A" ] || fail "C-a state head did not advance"
[ "$(bash "$TKT_STATE" "$S" get fixopen)" = "2" ] || fail "C-a fixopen changed"
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "C-a round changed"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "C-a pushed"
grep -q "job|" "$T/calls.log" && fail "C-a dispatched a fix job"
grep -q "tkt-fix: worktree is ahead of the PR head by open fix job fix2's unpushed commits" "$T/stderr" || fail "C-a stderr line missing: $(cat "$T/stderr")"
fi

# PUSH-FAIL leaves a closed fix job's commit recoverable on the next run.
if want recover-push-fail; then
setup_case recover-push-fail
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
cat >"$CDIR/origin.git/hooks/pre-receive" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$CDIR/origin.git/hooks/pre-receive"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "1" ] || fail "recover-push-fail first run exited $run_rc, want PUSH-FAIL 1: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix PUSH-FAIL' || fail "recover-push-fail first verdict missing: $(head -n 1 <<<"$out")"
NEW="$(git -C "$WT" rev-parse HEAD)"
write_job_record j1 "$OLD" "$NEW"
rm "$CDIR/origin.git/hooks/pre-receive"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "recover-push-fail recovery exited $?: $(head -n 1 <<<"$out"): $(cat "$T/stderr")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix FIX-OK' || fail "recover-push-fail recovery verdict missing: $(head -n 1 <<<"$out")"
grep -q 'DRIFT\|RECOVER' <<<"$out" && fail "recover-push-fail recovery reported drift or RECOVER: $out"
[ "$(git --git-dir="$CDIR/origin.git" rev-parse refs/heads/tkt-529)" = "$NEW" ] || fail "recover-push-fail did not push NEW to origin"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$NEW" ] || fail "recover-push-fail state head is not NEW"
[ "$(bash "$TKT_STATE" "$S" get fixslot)" = "1" ] || fail "recover-push-fail did not close fix1"
grep -q '^job|' "$T/calls.log" && fail "recover-push-fail dispatched another fix job"
fi

# CI-WAIT rc=2 leaves the same closed fix job recoverable without another wait failure.
if want recover-ci-wait-2; then
setup_case recover-ci-wait-2
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
printf '2' >"$T/cimode"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "1" ] || fail "recover-ci-wait-2 first run exited $run_rc, want CI-WAIT 1: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix CI-WAIT rc=2' || fail "recover-ci-wait-2 first verdict missing: $(head -n 1 <<<"$out")"
grep -q 'gh-ci|wait 7 --repo switchyard' "$T/calls.log" || fail "recover-ci-wait-2 did not wait for CI"
NEW="$(git -C "$WT" rev-parse HEAD)"
write_job_record j1 "$OLD" "$NEW"
printf '0' >"$T/cimode"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "recover-ci-wait-2 recovery exited $?: $(head -n 1 <<<"$out"): $(cat "$T/stderr")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix FIX-OK' || fail "recover-ci-wait-2 recovery verdict missing: $(head -n 1 <<<"$out")"
grep -q 'DRIFT\|RECOVER' <<<"$out" && fail "recover-ci-wait-2 recovery reported drift or RECOVER: $out"
[ "$(git --git-dir="$CDIR/origin.git" rev-parse refs/heads/tkt-529)" = "$NEW" ] || fail "recover-ci-wait-2 did not push NEW to origin"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$NEW" ] || fail "recover-ci-wait-2 state head is not NEW"
[ "$(bash "$TKT_STATE" "$S" get fixslot)" = "1" ] || fail "recover-ci-wait-2 did not close fix1"
grep -q '^job|' "$T/calls.log" && fail "recover-ci-wait-2 dispatched another fix job"
fi

# A skipped slot is recovered by scanning from fresh slot 5 down, not from fixslot 3.
if want recover-skipped-slot; then
setup_case recover-skipped-slot
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
bash "$TKT_STATE" "$S" set round 4 >/dev/null
bash "$TKT_STATE" "$S" set fixslot 3 >/dev/null
printf 'resume slot five\\n' >"$CDIR/prompt.md"
cat >"$CDIR/origin.git/hooks/pre-receive" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$CDIR/origin.git/hooks/pre-receive"
run_rc=0; out="$(bash "$TKT" "$S" --verify --resume j1 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "1" ] || fail "recover-skipped-slot first run exited $run_rc, want PUSH-FAIL 1: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix PUSH-FAIL' || fail "recover-skipped-slot first verdict missing: $(head -n 1 <<<"$out")"
grep -q 'job|.*--slot fix5' "$T/calls.log" || fail "recover-skipped-slot did not dispatch fix5"
NEW="$(git -C "$WT" rev-parse HEAD)"
write_job_record j1 "$OLD" "$NEW"
rm "$CDIR/origin.git/hooks/pre-receive"
printf 'resume recovered job\n' >"$CDIR/prompt.md"
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify --resume j1 --prompt "$CDIR/prompt.md" 2>"$T/stderr")" || fail "recover-skipped-slot recovery exited $?: $(head -n 1 <<<"$out"): $(cat "$T/stderr")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix FIX-OK' || fail "recover-skipped-slot recovery verdict missing: $(head -n 1 <<<"$out")"
grep -q 'DRIFT\|RECOVER' <<<"$out" && fail "recover-skipped-slot recovery reported drift or RECOVER: $out"
[ "$(git --git-dir="$CDIR/origin.git" rev-parse refs/heads/tkt-529)" = "$NEW" ] || fail "recover-skipped-slot did not push NEW to origin"
[ "$(bash "$TKT_STATE" "$S" get fixslot)" = "5" ] || fail "recover-skipped-slot did not close fix5"
grep -q '^job|' "$T/calls.log" && fail "recover-skipped-slot dispatched another fix job"
fi

# A recovery-gate FAIL closes slot 1; the following recovery must write history for slot 1, not fresh slot 2.
if want recover-history-slot; then
setup_case recover-history-slot
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
fixture_commit fix.txt "unpublished fix" "fix: unpushed fix"
NEW="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$NEW" >/dev/null
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
bash "$TKT_STATE" "$S" set fixopen 0 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
write_job_record j1 "$OLD" "$NEW"
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `base.txt`
- `fix.txt`

## Gate

`false`
EOF
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "1" ] || fail "recover-history-slot failed-gate run exited $run_rc, want 1: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix FAIL rc=1' || fail "recover-history-slot did not fail its recovery gate: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get round)" = "1" ] || fail "recover-history-slot gate failure did not bump round"
[ "$(bash "$TKT_STATE" "$S" get fixslot)" = "1" ] || fail "recover-history-slot gate failure did not close fix1"
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `base.txt`
- `fix.txt`

## Gate

`true`
EOF
: >"$T/calls.log"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "recover-history-slot second recovery exited $?: $(head -n 1 <<<"$out"): $(cat "$T/stderr")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix FIX-OK' || fail "recover-history-slot second recovery verdict missing: $(head -n 1 <<<"$out")"
[ -f "$CDIR/run/switchyard-529-findings-history-r1.md" ] || fail "recover-history-slot did not write findings-history-r1.md"
[ ! -e "$CDIR/run/switchyard-529-findings-history-r2.md" ] || fail "recover-history-slot wrote history for fresh slot r2 instead of recovered slot r1"
[ "$(git --git-dir="$CDIR/origin.git" rev-parse refs/heads/tkt-529)" = "$NEW" ] || fail "recover-history-slot did not push NEW to origin"
grep -q '^job|' "$T/calls.log" && fail "recover-history-slot dispatched another fix job"
fi

# A checks-only gate rc=2 after a pushed fix leaves the same slot at RECOVER.
if want recover-checks-only-2; then
setup_case recover-checks-only-2
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
printf '2' >"$T/gatemode"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "2" ] || fail "recover-checks-only-2 first run exited $run_rc, want 2: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix UNKNOWN' || fail "recover-checks-only-2 first verdict missing: $(head -n 1 <<<"$out")"
NEW="$(git -C "$WT" rev-parse HEAD)"
[ "$(git --git-dir="$CDIR/origin.git" rev-parse refs/heads/tkt-529)" = "$NEW" ] || fail "recover-checks-only-2 first run did not push its fix"
[ "$(bash "$TKT_STATE" "$S" get fixslot 2>/dev/null || printf '0')" = "0" ] || fail "recover-checks-only-2 gate error advanced fixslot"
: >"$T/calls.log"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "3" ] || fail "recover-checks-only-2 second run exited $run_rc, want RECOVER 3: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix RECOVER' || fail "recover-checks-only-2 second verdict missing: $(head -n 1 <<<"$out")"
grep -q 'slot=fix1' <<<"$out" || fail "recover-checks-only-2 did not RECOVER on slot fix1"
grep -q '^job|' "$T/calls.log" && fail "recover-checks-only-2 dispatched another fix job"
fi

# C-b. A headBefore that differs from the stored intermediate head is rejected.
if want C-b; then
setup_case c-b
fixture_commit fix.txt "first unpushed fix" "fix: first unpushed"
SHEAD="$(git -C "$WT" rev-parse HEAD)"
fixture_commit fix.txt "second unpushed fix" "fix: second unpushed"
A="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$SHEAD" >/dev/null
bash "$TKT_STATE" "$S" set round 1 >/dev/null
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
bash "$TKT_STATE" "$S" set fixopen 2 >/dev/null
bash "$TKT_STATE" "$S" set job.fix2 j2 >/dev/null
write_job_record j2 "$OLD" "$A"
printf '%s' "$OLD" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "C-b exited 0"
rc=$?; [ "$rc" = "3" ] || fail "C-b exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "C-b bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$SHEAD" ] || fail "C-b state head moved"
[ "$(bash "$TKT_STATE" "$S" get fixopen)" = "2" ] || fail "C-b fixopen changed"
grep -q "job|" "$T/calls.log" && fail "C-b dispatched a fix job"
fi

# C-c. An outside commit above the job's headAfter is rejected.
if want C-c; then
setup_case c-c
fixture_commit fix.txt "first unpushed fix" "fix: first unpushed"
SHEAD="$(git -C "$WT" rev-parse HEAD)"
fixture_commit fix.txt "second unpushed fix" "fix: second unpushed"
A="$(git -C "$WT" rev-parse HEAD)"
fixture_commit outside.txt "outside commit" "outside: on top"
OUTHEAD="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$SHEAD" >/dev/null
bash "$TKT_STATE" "$S" set round 1 >/dev/null
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
bash "$TKT_STATE" "$S" set fixopen 2 >/dev/null
bash "$TKT_STATE" "$S" set job.fix2 j2 >/dev/null
write_job_record j2 "$SHEAD" "$A"
printf '%s' "$OLD" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "C-c exited 0"
rc=$?; [ "$rc" = "3" ] || fail "C-c exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "C-c bad verdict: $(head -n 1 <<<"$out")"
grep -q "worktree HEAD=$OUTHEAD" <<<"$out" || fail "C-c DRIFT digest omits outside HEAD"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$SHEAD" ] || fail "C-c state head moved"
[ "$(bash "$TKT_STATE" "$S" get fixopen)" = "2" ] || fail "C-c fixopen changed"
grep -q "job|" "$T/calls.log" && fail "C-c dispatched a fix job"
fi

# C-d. A moved PR head outside the stored-head chain is rejected.
if want C-d; then
setup_case c-d
fixture_commit fix.txt "first unpushed fix" "fix: first unpushed"
SHEAD="$(git -C "$WT" rev-parse HEAD)"
fixture_commit fix.txt "second unpushed fix" "fix: second unpushed"
A="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" checkout -q --detach "$OLD"
fixture_commit other.txt "moved PR branch" "other: moved PR head"
Q="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" checkout -q tkt-529
bash "$TKT_STATE" "$S" set head "$SHEAD" >/dev/null
bash "$TKT_STATE" "$S" set round 1 >/dev/null
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
bash "$TKT_STATE" "$S" set fixopen 2 >/dev/null
bash "$TKT_STATE" "$S" set job.fix2 j2 >/dev/null
write_job_record j2 "$SHEAD" "$A"
printf '%s' "$Q" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" && fail "C-d exited 0"
rc=$?; [ "$rc" = "3" ] || fail "C-d exited $rc, want 3"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix DRIFT" || fail "C-d bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$SHEAD" ] || fail "C-d state head moved"
[ "$(bash "$TKT_STATE" "$S" get fixopen)" = "2" ] || fail "C-d fixopen changed"
grep -q "job|" "$T/calls.log" && fail "C-d dispatched a fix job"
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
  if [ "\$5" = "1" ]; then comms="[\"\$4\"]"; else comms="[]"; fi
  jq -n --arg status "\$1" --arg text "\$2" --arg hb "\$3" --arg ha "\$4" --argjson comms "\$comms" --arg resumed "\$7" \
    '{status: \$status, result: {status: \$status, text: \$text, gateResult: {passed: true, command: "true", exitCode: 0, outputTail: "ok", outputPath: "/tmp/g.log"}, changeSet: {headBefore: \$hb, headAfter: \$ha, newCommits: \$comms, uncommittedFiles: [], filesChanged: [], diffstat: "", dirtyAfter: false}, concerns: null}, supervisorPid: 1, resumedFrom: \$resumed}' \
    >"\$jobsdir/\$6.json" || exit 1
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
    head_before="\$(git -C "\$cwd" rev-parse HEAD)"
    head="\$(commit_fix "\$cwd" "\$n")"
    if [ "\$mode" = "ask" ]; then mint_record NEEDS_CONTEXT "which design rules the retry?" "\$head_before" "\$head" 1 "\$id" ""
    else mint_record DONE "\$(printf 'done\nSTATUS: DONE')" "\$head_before" "\$head" 1 "\$id" ""; fi
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
    head_before="\$(git -C "\$cwd" rev-parse HEAD)"
    if [ "\$mode" = "ask" ]; then mint_record NEEDS_CONTEXT "which design rules the retry?" "\$head_before" "\$head_before" 0 "\$id" "\$from"
    else mint_record DONE "\$(printf 'done\nSTATUS: DONE')" "\$head_before" "\$head_before" 0 "\$id" "\$from"; fi
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
write_job_record j1 "$OLD" "$NEW"
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
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
write_job_record j1 "$OLD" "$NEW"
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
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
write_job_record j1 "$OLD" "$NEW"
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
NEW="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
write_job_record j1 "$OLD" "$NEW"
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
STALLED_HEAD="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set job.fix1 j1 >/dev/null
write_job_record j1 "$OLD" "$STALLED_HEAD"
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

# K1: the #4598 three-slot chain proves ownership on the open-slot path,
# including a no-op final job, then reports RECOVER with the carried head.
if want K1; then
setup_case K1
fixture_commit fix.txt "first fix" "fix: first"
A1="$(git -C "$WT" rev-parse HEAD)"
fixture_commit fix.txt "second fix" "fix: second"
A2="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set fixopen 3 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 k1a >/dev/null
bash "$TKT_STATE" "$S" set job.fix2 k1b >/dev/null
bash "$TKT_STATE" "$S" set job.fix3 k1c >/dev/null
write_job_record k1a "$OLD" "$A1"
write_job_record k1b "$A1" "$A2"
write_job_record k1c "$A2" "$A2"
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "3" ] || fail "K1 exited $run_rc, want RECOVER 3: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix RECOVER' || fail "K1 bad verdict: $(head -n 1 <<<"$out")"
grep -q 'job=k1a' <<<"$out" || fail "K1 missing job digest: $out"
grep -q 'slot=fix1' <<<"$out" || fail "K1 missing slot digest: $out"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$A2" ] || fail "K1 state head did not advance"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "K1 pushed"
fi

# K2: a no-op job cannot claim a hand commit, at round 0 or under ROUND-LIMIT.
if want K2; then
setup_case K2
fixture_commit fix.txt "hand commit" "outside: hand commit"
A="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 k2a >/dev/null
write_job_record k2a "$A" "$A"
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "3" ] || fail "K2 round 0 exited $run_rc, want DRIFT 3: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix DRIFT' || fail "K2 round 0 bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "K2 round 0 changed state head"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "K2 round 0 pushed"

setup_case K2-round2
fixture_commit fix.txt "hand commit" "outside: hand commit"
A="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set round 2 >/dev/null
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 k2b >/dev/null
write_job_record k2b "$A" "$A"
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "1" ] || fail "K2 round 2 exited $run_rc, want ROUND-LIMIT 1: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix ROUND-LIMIT round=2' || fail "K2 round 2 bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD" ] || fail "K2 round 2 changed state head"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "K2 round 2 pushed"
fi

# K3: a hand commit between two recorded jobs leaves a gap in ownership.
if want K3; then
setup_case K3
fixture_commit fix.txt "first fix" "fix: first"
A1="$(git -C "$WT" rev-parse HEAD)"
fixture_commit outside.txt "hand commit" "outside: gap"
A2="$(git -C "$WT" rev-parse HEAD)"
fixture_commit fix.txt "second fix" "fix: second"
A3="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set fixslot 2 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 k3a >/dev/null
bash "$TKT_STATE" "$S" set job.fix2 k3b >/dev/null
write_job_record k3a "$OLD" "$A1"
write_job_record k3b "$A2" "$A3"
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "3" ] || fail "K3 exited $run_rc, want DRIFT 3: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix DRIFT' || fail "K3 bad verdict: $(head -n 1 <<<"$out")"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "K3 pushed"
fi

# K4: a declared slot with no record breaks the chain even if older and newer
# records otherwise point toward the worktree head.
if want K4; then
setup_case K4
fixture_commit fix.txt "first fix" "fix: first"
A1="$(git -C "$WT" rev-parse HEAD)"
fixture_commit outside.txt "middle hand commit" "outside: middle"
A2="$(git -C "$WT" rev-parse HEAD)"
fixture_commit fix.txt "third fix" "fix: third"
A3="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set fixslot 3 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 k4a >/dev/null
bash "$TKT_STATE" "$S" set job.fix2 k4missing >/dev/null
bash "$TKT_STATE" "$S" set job.fix3 k4c >/dev/null
write_job_record k4a "$OLD" "$A1"
write_job_record k4c "$A2" "$A3"
rm -f "$TMPDIR/delegate-jobs/k4missing.json"
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "3" ] || fail "K4 exited $run_rc, want DRIFT 3: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix DRIFT' || fail "K4 bad verdict: $(head -n 1 <<<"$out")"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "K4 pushed"
fi

# K5: a resume within fix1 follows resumedFrom and proves its predecessor.
if want K5; then
setup_case K5
fixture_commit fix.txt "first fix" "fix: first"
A1="$(git -C "$WT" rev-parse HEAD)"
fixture_commit fix.txt "resumed fix" "fix: resumed"
A2="$(git -C "$WT" rev-parse HEAD)"
write_job_record k5a "$OLD" "$A1"
j1_record="$TMPDIR/delegate-jobs/k5a.json"
jq '. + {supersededBy:"k5b"}' "$j1_record" >"$j1_record.tmp" && mv "$j1_record.tmp" "$j1_record" || fail "K5 supersededBy write"
write_job_record k5b "$A1" "$A2" k5a
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 k5b >/dev/null
record_test_round 1 "$A2"
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || fail "K5 exited $?: $(head -n 1 <<<"$out"): $(cat "$T/stderr")"
head -n 1 <<<"$out" | grep -q "TKT tkt-fix FIX-OK reviewed=$A2" || fail "K5 bad verdict: $(head -n 1 <<<"$out")"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$A2" ] || fail "K5 did not push the recovered chain"
fi

# K6: the open-slot stored-head == actual shortcut still needs a full chain.
if want K6; then
setup_case K6
fixture_commit fix.txt "hand commit" "outside: hand commit"
A="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$A" >/dev/null
bash "$TKT_STATE" "$S" set fixopen 1 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 k6a >/dev/null
write_job_record k6a "$A" "$A"
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "3" ] || fail "K6 exited $run_rc, want DRIFT 3: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix DRIFT' || fail "K6 bad verdict: $(head -n 1 <<<"$out")"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$A" ] || fail "K6 changed state head"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "K6 pushed"
fi

# K7: a resumedFrom cycle is rejected without hanging.
if want K7; then
setup_case K7
fixture_commit fix.txt "first commit" "fix: first"
A1="$(git -C "$WT" rev-parse HEAD)"
fixture_commit fix.txt "second commit" "fix: second"
A2="$(git -C "$WT" rev-parse HEAD)"
write_job_record k7a "$A1" "$A1" k7b
write_job_record k7b "$A1" "$A2" k7a
bash "$TKT_STATE" "$S" set fixslot 1 >/dev/null
bash "$TKT_STATE" "$S" set job.fix1 k7b >/dev/null
printf 'ORIGIN:%s:refs/heads/tkt-529' "$CDIR/origin.git" >"$T/prhead"
run_rc=0; out="$(bash "$TKT" "$S" --verify 2>"$T/stderr")" || run_rc=$?
[ "$run_rc" = "3" ] || fail "K7 exited $run_rc, want DRIFT 3: $(head -n 1 <<<"$out")"
head -n 1 <<<"$out" | grep -q 'TKT tkt-fix DRIFT' || fail "K7 bad verdict: $(head -n 1 <<<"$out")"
[ "$(git -C "$WT" rev-parse origin/tkt-529)" = "$OLD" ] || fail "K7 pushed"
fi

echo "tkt-fix assertions passed"

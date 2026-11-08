#!/usr/bin/env bash
# Tests for bin/tkt-build: lane, gate, mutant list, review beside the map job,
# one merged findings file. Stubs on a temp TKT_BIN: delegate (mints DONE/ASK
# records), gh (pr list/view, run list/view), gh-ci (wait, with a separate
# run-wait code) and review-pr (canned start/collect), plus mutant-verdicts
# (canned verdict rows). Real tkt-job and tkt-gate run behind logging
# wrappers; symlinks reach the real tkt-state, fill-brief, plan-gate and lib.
# Real git on throwaway repos (a bare origin plus a clone). HOME and TMPDIR
# point at temp dirs; nothing touches the network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$SCRIPT_DIR/../bin/tkt-build"
TKT_STATE="$SCRIPT_DIR/../bin/tkt-state"
REAL_BIN="$SCRIPT_DIR/../bin"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-tkt-build.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp" "$T/bin" "$T/cases"
export HOME="$T/home" TMPDIR="$T/tmp" TKT_BIN="$T/bin"
export PATH="$T/bin:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export JOB_RECORD_SYSTEM_DIR="$T/no-system-jobs"
unset DELEGATE_JOBS_DIR

[ -x "$REAL_BIN/tkt-job" ] || fail "real tkt-job missing"
[ -x "$REAL_BIN/tkt-gate" ] || fail "real tkt-gate missing"
[ -x "$REAL_BIN/fill-brief" ] || fail "real fill-brief missing"
# Tooling calls use local fixtures only; no QuotaBar request reaches the host feed.
ln -s "$REAL_BIN/quota" "$T/bin/quota" || fail "symlink quota"
cat >"$T/quota.json" <<'EOF'
{"providers":[
  {"id":"claude","status":"healthy","quotas":[{"key":"weekly","label":"Weekly","percentRemaining":69}]},
  {"id":"codex","status":"healthy","quotas":[{"key":"weekly","label":"Weekly","percentRemaining":80}]},
  {"id":"cursor","status":"healthy","quotas":[{"key":"weekly","label":"Weekly","percentRemaining":80}]},
  {"id":"opencode-go","status":"healthy","quotas":[{"key":"weekly","label":"Weekly","percentRemaining":80}]},
  {"id":"muse","status":"healthy","quotas":[{"key":"weekly","label":"Weekly","percentRemaining":80}]}
]}
EOF
cp "$T/quota.json" "$T/quota-healthy.json"
export QUOTA_FEED="file://$T/quota.json"

# Logging wrappers: record the call, then run the real command.
cat >"$T/bin/tkt-job" <<EOF
#!/usr/bin/env bash
printf 'job|%s\n' "\$*" >>"$T/calls.log"
exec "$REAL_BIN/tkt-job" "\$@"
EOF
cat >"$T/bin/tkt-gate" <<EOF
#!/usr/bin/env bash
printf 'gate|%s\n' "\$*" >>"$T/calls.log"
exec "$REAL_BIN/tkt-gate" "\$@"
EOF
chmod +x "$T/bin/tkt-job" "$T/bin/tkt-gate"
ln -s "$REAL_BIN/tkt-state" "$T/bin/tkt-state" || fail "symlink tkt-state"
ln -s "$REAL_BIN/fill-brief" "$T/bin/fill-brief" || fail "symlink fill-brief"
ln -s "$REAL_BIN/plan-gate" "$T/bin/plan-gate" || fail "symlink plan-gate"
ln -s "$REAL_BIN/lib" "$T/bin/lib" || fail "symlink lib"
ln -s "$REAL_BIN/job-record" "$T/bin/job-record" || fail "symlink job-record"
ln -s "$REAL_BIN/fence-grant" "$T/bin/fence-grant" || fail "symlink fence-grant"
# Lane and fix slots need a fence grant (test/tkt-job.sh covers that); these cases test the build flow.
export FW_NO_FENCE="test/tkt-build.sh exercises the build flow, not the fence"

# Stub delegate: run mints a DONE record at once (lane carries one commit for
# --expect-commits; map carries $T/map-text); ask modes mint NEEDS_CONTEXT.
# Watch only logs: every record already exists, so one watch covers all ids.
printf '0' >"$T/dcounter"
printf '0' >"$T/rcounter"
cat >"$T/bin/delegate" <<EOF
#!/usr/bin/env bash
set -uo pipefail
jobsdir="\${DELEGATE_JOBS_DIR:-\${TMPDIR:-/tmp}/delegate-jobs}"
mode="\$(cat "$T/delegate-mode")"
cmd="\${1:-}"; shift || true
case "\$cmd" in
  run)
    model=""; prompt=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --model) model="\$2"; shift 2 ;;
        --prompt-file) prompt="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    n="\$((\$(cat "$T/dcounter") + 1))"
    printf '%s' "\$n" >"$T/dcounter"
    id="stub-\$n"
    printf 'run|id=%s|model=%s|prompt=%s\n' "\$id" "\$model" "\$prompt" >>"$T/calls.log"
    slot="other"
    case "\$prompt" in *-lane-*) slot="lane" ;; *-map-*) slot="map" ;; esac
    status="DONE"
    commits='["deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"]'
    concerns='null'
    if [ "\$slot" = "map" ]; then
      text="\$(cat "$T/map-text")"
      commits='[]'
    else
      text="lane done
STATUS: DONE"
    fi
    if [ "\$mode" = "concerns-lane" ] && [ "\$slot" = "lane" ]; then
      status="DONE_WITH_CONCERNS"
      concerns='"lane is unsure about X"'
    fi
    if [ "\$mode" = "verify-ok" ] && [ "\$slot" = "other" ]; then
      text="PLAN OK
held: every invariant survived its breaking input"
    fi
    if { [ "\$mode" = "ask-lane" ] && [ "\$slot" = "lane" ]; } || { [ "\$mode" = "ask-map" ] && [ "\$slot" = "map" ]; }; then
      status="NEEDS_CONTEXT"
      text="\$(cat "$T/ask-text")"
      commits='[]'
    fi
    mkdir -p "\$jobsdir"
    jq -n --arg status "\$status" --arg text "\$text" --argjson commits "\$commits" --argjson concerns "\$concerns" \
      '{status: \$status, result: {status: \$status, text: \$text, gateResult: {passed: true, command: "true", exitCode: 0, outputTail: "ok", outputPath: "/tmp/g.log"}, changeSet: {headBefore: "a", headAfter: "b", newCommits: \$commits, uncommittedFiles: [], filesChanged: [], diffstat: "", dirtyAfter: false}, concerns: \$concerns}, supervisorPid: 1}' \
      >"\$jobsdir/\$id.json"
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

# Stub gh: the PR list and head from $T/prnum and $T/prhead (empty with
# $T/empty-pr, failing pr view with $T/noview); one run holding the mutant job;
# the job log from $T/mutant-log (failing with $T/log-fail, cause in
# $T/log-err); jobs from $T/jobs-json when present (failing with
# $T/jobs-fail, cause in $T/jobs-err); artifacts from $T/artifacts-json
# (failing with $T/artifacts-fail, cause in $T/artifacts-err).
cat >"$T/bin/gh" <<EOF
#!/usr/bin/env bash
printf 'gh|%s\n' "\$*" >>"$T/calls.log"
case " \$* " in
  *" pr view "*)
    if [ -f "$T/noview" ]; then exit 1; fi
    # Real gh cannot view an empty pr number: fail like it does, so a
    # missing pr never views as the caller's branch.
    prev=""
    for a in "\$@"; do
      if [ "\$prev" = "view" ] && [ -z "\$a" ]; then exit 1; fi
      prev="\$a"
    done
    ;;
esac
case " \$* " in
  *" pr list "*)
    if [ -f "$T/empty-pr" ]; then printf '[]\n'; else printf '[{"number":%s,"headRefOid":"%s"}]\n' "\$(cat "$T/prnum")" "\$(cat "$T/prhead")"; fi
    ;;
  *" headRefOid "*)
    cat "$T/prhead"
    ;;
  *" run list "*)
    if [ -f "$T/no-runs" ]; then printf '[]\n'; else printf '[{"databaseId":101}]\n'; fi
    ;;
  *"artifacts"*)
    if [ -f "$T/artifacts-fail" ]; then
      if [ -f "$T/artifacts-err" ]; then cat "$T/artifacts-err" >&2; fi
      exit 1
    fi
    cat "$T/artifacts-json"
    ;;
  *" --job "*)
    if [ -f "$T/log-fail" ]; then
      if [ -f "$T/log-err" ]; then cat "$T/log-err" >&2; fi
      exit 1
    fi
    cat "$T/mutant-log"
    ;;
  *" --json jobs "*)
    if [ -f "$T/jobs-fail" ] && [ -f "$T/jobs-first-done" ]; then
      if [ -f "$T/jobs-err" ]; then cat "$T/jobs-err" >&2; fi
      exit 1
    fi
    if [ -f "$T/jobs-first-done" ] && [ -f "$T/jobs-json2" ]; then
      cat "$T/jobs-json2"
    else
      if [ -f "$T/jobs-json" ]; then cat "$T/jobs-json"; else printf '{"jobs":[{"databaseId":201,"name":"%s"}]}\n' "\$(cat "$T/mutant-job")"; fi
    fi
    touch "$T/jobs-first-done"
    ;;
  *)
    printf '{}\n'
    ;;
esac
exit 0
EOF
chmod +x "$T/bin/gh"

# Stub gh-ci: wait only, logging its args. A `--run` wait exits the run-wait
# code; every other wait exits the listing code. A $T/ghci-err file, when
# present, goes to stderr (the first line is the wait's failure cause).
cat >"$T/bin/gh-ci" <<EOF
#!/usr/bin/env bash
printf 'ghci|%s\n' "\$*" >>"$T/calls.log"
rc="\$(cat "$T/ghci-rc")"
case " \$* " in
  *" --run "*) rc="\$(cat "$T/ghci-run-rc")" ;;
esac
if [ -f "$T/ghci-err" ]; then cat "$T/ghci-err" >&2; fi
exit "\$rc"
EOF
chmod +x "$T/bin/gh-ci"

# Stub mutant-verdicts: stdout from $T/verdicts, stderr from $T/verdicts-err,
# exit from $T/verdicts-rc; logs its args.
cat >"$T/bin/mutant-verdicts" <<EOF
#!/usr/bin/env bash
printf 'mverd|%s\n' "\$*" >>"$T/calls.log"
cat "$T/verdicts"
if [ -f "$T/verdicts-err" ]; then cat "$T/verdicts-err" >&2; fi
exit "\$(cat "$T/verdicts-rc")"
EOF
chmod +x "$T/bin/mutant-verdicts"

# Stub review-pr: start launches one id per requested axis (--axes, default all
# three); tkt-build persists each id as it launches. collect copies $T/findings-src
# to --findings-out, prints $T/collect-out and exits $T/collect-rc. With a
# $T/collect-nowrite flag file present, collect prints and exits without
# writing --findings-out, like an early RUNNING exit.
cat >"$T/bin/review-pr" <<EOF
#!/usr/bin/env bash
sub="\${1:-}"; shift || true
if [ "\$sub" = "start" ]; then
  printf 'review-start|%s\n' "\$*" >>"$T/calls.log"
  mode="\$(cat "$T/review-mode")"
  if [ "\$mode" = "startfail" ]; then
    echo "review-pr: cannot start reviews" >&2
    exit 1
  fi
  axes="standards,spec,overbuild"
  prev=""
  for a in "\$@"; do
    if [ "\$prev" = "--axes" ]; then axes="\$a"; fi
    prev="\$a"
  done
  axes="\$(printf '%s' "\$axes" | tr ',' ' ')"
  for ax in \$axes; do
    case " \$ax " in " standards "|" spec "|" overbuild "*) ;;
      *) echo "stub review-pr: unknown axis \$ax" >&2; exit 2;; esac
    if [ "\$mode" = "die-after-one" ] && [ "\$ax" = "spec" ]; then
      echo "review-pr: died after one launch" >&2
      exit 1
    fi
    n="\$((\$(cat "$T/rcounter") + 1))"
    printf '%s' "\$n" >"$T/rcounter"
    printf '%s r%s\n' "\$ax" "\$n"
  done
  exit 0
fi
if [ "\$sub" = "collect" ]; then
  printf 'review-collect|%s\n' "\$*" >>"$T/calls.log"
  out=""
  while [ \$# -gt 0 ]; do
    case "\$1" in
      --findings-out) out="\$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ ! -f "$T/collect-nowrite" ]; then cp "$T/findings-src" "\$out"; fi
  cat "$T/collect-out"
  exit "\$(cat "$T/collect-rc")"
fi
echo "stub review-pr: unknown \$sub" >&2
exit 2
EOF
chmod +x "$T/bin/review-pr"

# Briefs under the temp HOME, with the same tokens the real ones carry.
mkdir -p "$T/home/.agents/skills/planning/briefs" "$T/home/.agents/skills/review-loop/briefs"
cat >"$T/home/.agents/skills/planning/briefs/lane.md" <<'EOF'
Implement issue #__ISSUE__ in __REPO__ in worktree `__WORKTREE__` on branch `__BRANCH__`, starting from __BASE__.

The project's workflow doc is __WORKFLOW_DOC__; it wins where it speaks.

Read the plan at `__PLAN__` before anything else.

Push the branch. The body starts with `__CLOSING__` and holds `__ATTRIBUTION__`.

Implemented by: __LANE_MODEL__

The gate passes: `__GATE__`.
__EXTRA__
EOF
cat >"$T/home/.agents/skills/review-loop/briefs/mutant-map.md" <<'EOF'
Map every mutant CI listed for PR #__PR__ (issue #__ISSUE__) in __REPO__, in worktree `__WORKTREE__`.

__MUTANTS__
EOF

# Build the common local Git history once. Each case copies its own origin and
# worktree so fetch/push and mutation checks still run against isolated repos.
CASE_TEMPLATE="$T/case-template"
mkdir -p "$CASE_TEMPLATE"
git init -q --bare "$CASE_TEMPLATE/origin.git"
git --git-dir="$CASE_TEMPLATE/origin.git" symbolic-ref HEAD refs/heads/main
git init -q "$CASE_TEMPLATE/seed"
git -C "$CASE_TEMPLATE/seed" symbolic-ref HEAD refs/heads/main
git -C "$CASE_TEMPLATE/seed" config user.email t@t
git -C "$CASE_TEMPLATE/seed" config user.name t
printf 'base\n' >"$CASE_TEMPLATE/seed/base.txt"
git -C "$CASE_TEMPLATE/seed" add base.txt
git -C "$CASE_TEMPLATE/seed" commit -qm init
git -C "$CASE_TEMPLATE/seed" push -q "$CASE_TEMPLATE/origin.git" main
git -C "$CASE_TEMPLATE/seed" remote add origin ../origin.git
git -C "$CASE_TEMPLATE/seed" rev-parse HEAD >"$CASE_TEMPLATE/main0"
git clone -q "$CASE_TEMPLATE/origin.git" "$CASE_TEMPLATE/wt"
git -C "$CASE_TEMPLATE/wt" config user.email t@t
git -C "$CASE_TEMPLATE/wt" config user.name t
git -C "$CASE_TEMPLATE/wt" checkout -qb tkt-528
mkdir -p "$CASE_TEMPLATE/wt/src"
printf 'a\n' >"$CASE_TEMPLATE/wt/src/a.txt"
git -C "$CASE_TEMPLATE/wt" add src/a.txt
git -C "$CASE_TEMPLATE/wt" commit -qm change
git -C "$CASE_TEMPLATE/wt" push -q origin tkt-528
git -C "$CASE_TEMPLATE/wt" remote set-url origin ../origin.git

# New case: private copies of the bare origin, seed repo and tkt-528 worktree.
# Sets CDIR, WT, S and H.
setup_case() {
  CDIR="$T/cases/$1"
  mkdir -p "$CDIR"
  cp -R "$CASE_TEMPLATE/." "$CDIR/"
  mkdir -p "$CDIR/run"
  WT="$CDIR/wt"
  H="$(git -C "$WT" rev-parse HEAD)"
  printf '%s' "$H" >"$T/prhead"
  printf '7' >"$T/prnum"
  printf 'Selection' >"$T/mutant-job"
  cat >"$CDIR/plan.md" <<EOF
Base: $H

## Files

- \`src/a.txt\`

## Gate

\`true\`
EOF
  S="$CDIR/tkt.state"
  {
    printf 'repo=%s\n' switchyard
    printf 'issue=%s\n' 528
    printf 'branch=%s\n' tkt-528
    printf 'worktree=%s\n' "$WT"
    printf 'run=%s\n' "$CDIR/run"
    printf 'plan=%s\n' "$CDIR/plan.md"
    printf 'closing=%s\n' 'Resolves #528'
    printf 'workflow_doc=%s\n' docs/agents/workflow.md
    printf 'model.lane=%s\n' codex/test-model
    printf 'model.review=%s\n' rm
    printf 'model.overbuild=%s\n' om
    printf 'model.map=%s\n' mm
    printf 'extra=%s\n' "$CDIR/extra.md"
    printf 'body_has=%s\n' 'Resolves #528' 'Co-authored with Test <t@t>'
    printf 'plan_verdict=%s\n' ok
    printf 'plan_verdict_base=%s\n' "$H"
  } >"$S"
  printf 'extra words\n' >"$CDIR/extra.md"
  printf 'done' >"$T/delegate-mode"
  printf 'ok' >"$T/review-mode"
  printf '0' >"$T/collect-rc"
  printf '0' >"$T/ghci-rc"
  printf '0' >"$T/ghci-run-rc"
  printf '0' >"$T/verdicts-rc"
  printf 'src/c.rs:5:6: MISSED\tcaught\n' >"$T/verdicts"
  printf '{"artifacts":[]}\n' >"$T/artifacts-json"
  rm -f "$T/empty-pr" "$T/no-runs" "$T/noview" "$T/ghci-err" "$T/verdicts-err" "$T/jobs-json" "$T/jobs-json2" "$T/jobs-first-done" "$T/jobs-fail" "$T/jobs-err" "$T/artifacts-fail" "$T/artifacts-err" "$T/log-fail" "$T/log-err" "$T/collect-nowrite"
  printf '0' >"$T/dcounter"
  printf '0' >"$T/rcounter"
  : >"$T/calls.log"
  cat >"$T/collect-out" <<'EOF'
patch-id deadbeef
VERDICT standards: APPROVE
VERDICT spec: APPROVE
VERDICT overbuild: APPROVE
CI deadbeef pass
EOF
  printf 'no open findings\n' >"$T/findings-src"
  cat >"$T/map-text" <<'EOF'
src/a.rs:10:20: MISSED => needs-test: bounds check unpinned
src/b.rs:3:4: TIMEOUT => removed: helper gone at head
src/c.rs:5:6: MISSED => caught by test/foo::bar
src/d.rs:7:8: MISSED => unviable
src/e.rs:1:1: MISSED => exempted: covered elsewhere
EOF
  cat >"$T/mutant-log" <<'EOF'
waiting for logs
src/a.rs:10:20: MISSED
noise without a location
mutants in the diff: 2
src/b.rs:3:4: TIMEOUT
EOF
  printf 'which scope rules the retry?\n' >"$T/ask-text"
}

# Run tkt-build on the current case state; sets OUT and RC, stderr kept in file.
run_build() {
  OUT="$(bash "$BUILD" "$S" "$@" 2>"$CDIR/stderr.txt")"; RC=$?
}

set_plan_base() {
  local new_base="$1"
  { printf 'Base: %s\n' "$new_base"; tail -n +2 "$CDIR/plan.md"; } >"$CDIR/plan.tmp"
  mv "$CDIR/plan.tmp" "$CDIR/plan.md"
}

advance_build_head() {
  git -C "$WT" push -q origin tkt-528
  H="$(git -C "$WT" rev-parse HEAD)"
  printf '%s' "$H" >"$T/prhead"
  bash "$TKT_STATE" "$S" set head "$H" || fail "advance build head state"
}

first_line() {
  head -n 1 <<<"$OUT"
}

expect_verdict() {
  case "$(first_line)" in
    $1) ;;
    *) fail "$2: verdict [$(first_line)] rc=$RC: $(cat "$CDIR/stderr.txt")" ;;
  esac
}

expect_state() {
  v="$(bash "$TKT_STATE" "$S" get "$1" 2>/dev/null || true)"
  [ "$v" = "$2" ] || fail "$3: state $1 is [$v], wants [$2]"
}

# --- happy path: no mutants, every axis APPROVE ---
setup_case happy
run_build --lane-model codex/test-model --review-model rrm --overbuild-model oom
[ "$RC" -eq 0 ] || fail "happy exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "happy"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -le 41 ] || fail "happy: over 40 digest lines"
grep -q "^job|.*--slot lane.*--template .*lane.md.*--gate-from-plan.*--expect-commits" "$T/calls.log" || fail "happy: lane runs through tkt-job"
grep -q '^concerns=' <<<"$OUT" && fail "happy: no empty concerns digest line"
grep -q "BASE=$H" "$T/calls.log" || fail "happy: BASE reaches the lane"
grep -q "GATE=true" "$T/calls.log" || fail "happy: GATE reaches the lane"
grep -q "CLOSING=Resolves #528" "$T/calls.log" || fail "happy: CLOSING reaches the lane"
grep -q "ATTRIBUTION=Co-authored with Test" "$T/calls.log" || fail "happy: ATTRIBUTION reaches the lane"
grep -q "^run|id=stub-1|model=codex/test-model|prompt=.*-lane-1.md$" "$T/calls.log" || fail "happy: --lane-model wins"
grep -q '^quota: provider=codex status=healthy$' <<<"$OUT" || fail "happy: quota pick is reported"
brief="$(grep '^run|' "$T/calls.log" | sed 's/.*prompt=//')"
grep -q "$H" "$brief" || fail "happy: the filled brief holds the base"
grep -q "Resolves #528" "$brief" || fail "happy: the filled brief holds CLOSING"
grep -q "Co-authored with Test" "$brief" || fail "happy: the filled brief holds ATTRIBUTION"
grep -q "^gate|.*--expect-head $H$" "$T/calls.log" || fail "happy: the gate checks the lane head"
grep -q "^review-start|7 --repo switchyard --cwd $WT --head $H --issue 528 --model rrm --overbuild-model oom --axes standards --full-rereview tkt-build round-0 full review$" "$T/calls.log" || fail "happy: standards starts with state and flag values"
grep -q "^review-start|7 --repo switchyard --cwd $WT --head $H --issue 528 --model rrm --overbuild-model oom --axes spec --full-rereview tkt-build round-0 full review$" "$T/calls.log" || fail "happy: spec starts per axis"
grep -q "^review-start|7 --repo switchyard --cwd $WT --head $H --issue 528 --model rrm --overbuild-model oom --axes overbuild --full-rereview tkt-build round-0 full review$" "$T/calls.log" || fail "happy: overbuild starts per axis"
[ "$(grep -c '^review-start|' "$T/calls.log")" -eq 3 ] || fail "happy: one start per axis"
rvh="$(bash "$TKT_STATE" "$S" get review_ids)"; [ "$(printf '%s' "$rvh" | wc -w | tr -d ' ')" -eq 3 ] || fail "happy: three review ids persisted"
grep -q "^watch|r1 r2 r3$" "$T/calls.log" || fail "happy: one delegate watch covers the review ids"
[ "$(grep -c '^watch|' "$T/calls.log")" -eq 2 ] || fail "happy: the lane watch plus one build watch"
grep -q "^ghci|" "$T/calls.log" && fail "happy: no mutant wait without mutant_job"
grep -q "prompt=.*-map-" "$T/calls.log" && fail "happy: no map job without mutants"
[ -e "$CDIR/run/switchyard-528-mutants-${H:0:12}.txt" ] && fail "happy: no mutants file without mutant_job"
expect_state reviewed "$H" happy
expect_state review_status done happy
[ -f "$(bash "$TKT_STATE" "$S" get findings)" ] || fail "happy: findings file exists"
expect_state round 0 happy
grep -q "tkt-build APPROVE" "$CDIR/tkt.journal" || fail "happy: the verdict is journaled"
logpath="${OUT%%$'\n'*}"; logpath="${logpath##*log=}"
[ -f "$logpath" ] || fail "happy: the run log exists"

# --- the real lane brief fills and carries the second-patch stop rule (#982) ---
setup_case real-lane-brief
cp "$T/home/.agents/skills/planning/briefs/lane.md" "$T/lane-stub.md" || fail "real-lane-brief: keep the stub lane brief"
cp "$SCRIPT_DIR/../skills/planning/briefs/lane.md" "$T/home/.agents/skills/planning/briefs/lane.md" || fail "real-lane-brief: install the real lane brief"
run_build --lane-model codex/test-model --review-model rrm --overbuild-model oom
[ "$RC" -eq 0 ] || fail "real-lane-brief exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
brief="$(grep '^run|id=stub-1|' "$T/calls.log" | sed 's/.*prompt=//')"
cp "$T/lane-stub.md" "$T/home/.agents/skills/planning/briefs/lane.md" || fail "real-lane-brief: restore the stub lane brief"
grep -q 'second patch' "$brief" || fail "real-lane-brief: the filled brief carries the second-patch stop rule"
grep -q 'STATUS: BLOCKED' "$brief" || fail "real-lane-brief: the filled brief names the BLOCKED stop"

# --- body_ends wins over body_has for the lane ATTRIBUTION ---
setup_case attr-ends
bash "$TKT_STATE" "$S" set body_has 'Resolves #528' || fail "attr-ends: set body_has"
bash "$TKT_STATE" "$S" set body_ends 'Co-authored with Ends' || fail "attr-ends: set body_ends"
run_build --lane-model codex/test-model --review-model rrm --overbuild-model oom
[ "$RC" -eq 0 ] || fail "attr-ends exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -q "ATTRIBUTION=Co-authored with Ends" "$T/calls.log" || fail "attr-ends: ATTRIBUTION reaches the lane"

# --- with no body_ends, a body_has co-author reaches the lane ---
setup_case attr-body
bash "$TKT_STATE" "$S" set body_has 'Co-authored with Body' || fail "attr-body: set body_has"
run_build --lane-model codex/test-model --review-model rrm --overbuild-model oom
[ "$RC" -eq 0 ] || fail "attr-body exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -q "ATTRIBUTION=Co-authored with Body" "$T/calls.log" || fail "attr-body: ATTRIBUTION reaches the lane"

# --- when both keys are set, body_ends wins ---
setup_case attr-both
bash "$TKT_STATE" "$S" set body_has 'Co-authored with Body' || fail "attr-both: set body_has"
bash "$TKT_STATE" "$S" set body_ends 'Co-authored with Ends' || fail "attr-both: set body_ends"
run_build --lane-model codex/test-model --review-model rrm --overbuild-model oom
[ "$RC" -eq 0 ] || fail "attr-both exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -q "ATTRIBUTION=Co-authored with Ends" "$T/calls.log" || fail "attr-both: ATTRIBUTION reaches the lane"

# --- with neither key, the ATTRIBUTION slot stays empty ---
setup_case attr-empty
bash "$TKT_STATE" "$S" set body_has 'Resolves #528' || fail "attr-empty: set body_has"
run_build --lane-model codex/test-model --review-model rrm --overbuild-model oom
[ "$RC" -eq 0 ] || fail "attr-empty exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -q "ATTRIBUTION= LANE_MODEL=" "$T/calls.log" || fail "attr-empty: ATTRIBUTION stays empty"

# --- mutants present: the map runs beside review, needs-test and removed merge ---
setup_case mutants
printf 'mutant_job=%s\n' Selection >>"$S"
printf 'P1 open null check\nP3 docs note\n' >"$T/findings-src"
run_build
[ "$RC" -eq 1 ] || fail "mutants exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=1 p2=2 p3=1 mutants=2 findings=* log=*" "mutants"
run_build
[ "$RC" -eq 1 ] || fail "mutants rerun exits 1 (rc=$RC)"
expect_verdict "TKT tkt-build ROUND-LIMIT round=0 log=*" "mutants rerun"
[ "$(grep -c '^run|id=stub-2' "$T/calls.log")" -eq 1 ] || fail "mutants rerun: no second map job"
grep -Fxq "ghci|wait 7 --job Selection --timeout 600 --repo switchyard" "$T/calls.log" || fail "mutants: gh-ci waits on the mutant job with the 600 s bound"
mfile="$CDIR/run/switchyard-528-mutants-${H:0:12}.txt"
[ "$(grep -c . "$mfile")" -eq 3 ] || fail "mutants: three log lines match"
grep -q "^run|id=stub-1|model=codex/test-model|" "$T/calls.log" || fail "mutants: the lane defaults to model.lane"
grep -q "^run|id=stub-2|model=mm|prompt=.*-map-1.md$" "$T/calls.log" || fail "mutants: the map job dispatches once"
grep -q "^review-start|.*--model rm --overbuild-model om" "$T/calls.log" || fail "mutants: review defaults to state models"
grep -q "^watch|r1 r2 r3 stub-2$" "$T/calls.log" || fail "mutants: one watch covers review and map ids"
mapbrief="$(grep '^run|id=stub-2' "$T/calls.log" | sed 's/.*prompt=//')"
grep -q "src/a.rs:10:20" "$mapbrief" || fail "mutants: MUTANTS reaches the map brief"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -qx "P1 open null check" "$ffile" || fail "mutants: review findings stay first"
grep -qx "P3 docs note" "$ffile" || fail "mutants: P3 findings stay listed"
grep -qx "P2 src/a.rs:10:20: MISSED => needs-test: bounds check unpinned \\[mutants $mfile\\]" "$ffile" || fail "mutants: the needs-test line merges"
grep -qx "P2 src/b.rs:3:4: TIMEOUT => removed: helper gone at head \\[mutants $mfile\\]" "$ffile" || fail "mutants: the removed line merges"
grep -q "caught by" "$ffile" && fail "mutants: caught lines stay out"
grep -q "unviable" "$ffile" && fail "mutants: unviable lines stay out"
grep -q "exempted" "$ffile" && fail "mutants: exempted lines stay out"
expect_state reviewed "$H" mutants
expect_state round 0 mutants

# --- the mutant map reads through the lookup: an override record merges ---
setup_case mutants-override
rm -rf "$T/tmp/delegate-jobs" "$T/override"
printf 'mutant_job=%s\n' Selection >>"$S"
printf 'P1 open null check\nP3 docs note\n' >"$T/findings-src"
DELEGATE_JOBS_DIR="$T/override" run_build
[ "$RC" -eq 1 ] || fail "mutants-override exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=* p2=* p3=* mutants=* findings=* log=*" "mutants-override"
grep -q "map failed" <<<"$OUT" && fail "mutants-override: no map failed note"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -q "needs-test: bounds check unpinned" "$ffile" || fail "mutants-override: the override map record merges"
grep -q "removed: helper gone at head" "$ffile" || fail "mutants-override: the removed line merges"
[ -e "$T/tmp/delegate-jobs/stub-2.json" ] && fail "mutants-override: the map record stays out of the tmp dir"

# --- a CHANGES axis with clean findings still reports CHANGES ---
setup_case changes-clean
cat >"$T/collect-out" <<'EOF'
patch-id deadbeef
VERDICT standards: APPROVE
VERDICT spec: CHANGES
VERDICT overbuild: APPROVE
P2 fixed already
CI deadbeef pass
EOF
run_build
[ "$RC" -eq 1 ] || fail "changes-clean exits 1 (rc=$RC)"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=0 p3=0 mutants=0 findings=* log=*" "changes-clean"

# --- an unfinished collect stops the build with its rerun line ---
setup_case incomplete
printf '1' >"$T/collect-rc"
cat >"$T/collect-out" <<'EOF'
patch-id deadbeef
VERDICT standards: APPROVE
UNFINISHED spec RUNNING gate=none /tmp/x.json
RUNNING spec r2: wait with delegate watch r1 r2 r3
CI deadbeef pending
EOF
run_build
[ "$RC" -eq 1 ] || fail "incomplete exits 1 (rc=$RC)"
expect_verdict "TKT tkt-build REVIEW-INCOMPLETE log=*" "incomplete"
grep -q "wait with delegate watch r1 r2 r3" <<<"$OUT" || fail "incomplete: the digest holds the rerun line"

# --- a review that never starts stops the build the same way ---
setup_case startfail
printf 'startfail' >"$T/review-mode"
run_build
[ "$RC" -eq 1 ] || fail "startfail exits 1 (rc=$RC)"
expect_verdict "TKT tkt-build REVIEW-INCOMPLETE log=*" "startfail"
grep -q "cannot start reviews" <<<"$OUT" || fail "startfail: the digest holds the cause"

# --- a non-CONCERNS lane ASK still forwards and starts nothing after it ---
setup_case ask
printf 'ask-lane' >"$T/delegate-mode"
run_build
[ "$RC" -eq 1 ] || fail "ask exits 1 (rc=$RC)"
expect_verdict "TKT tkt-build ASK id=stub-1 log=*" "ask"
grep -q "which scope rules the retry?" <<<"$OUT" || fail "ask: the digest holds the question"
grep -q "^gate|" "$T/calls.log" && fail "ask: the gate never runs"
grep -q "^review-start|" "$T/calls.log" && fail "ask: review never starts"
bash "$TKT_STATE" "$S" get head >/dev/null 2>&1 && fail "ask: pr and head stay unset"

# --- a CONCERNS lane continues through the gate and passes its file to reviews ---
setup_case concerns-lane
printf 'concerns-lane' >"$T/delegate-mode"
run_build
[ "$RC" -eq 0 ] || fail "concerns-lane exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "concerns-lane"
concerns_file="$CDIR/run/switchyard-528-concerns-lane.md"
expect_state concerns.lane "$concerns_file" concerns-lane
printf 'lane is unsure about X\n' | cmp - "$concerns_file" || fail "concerns-lane: concerns file keeps the lane text"
[ "$(grep -c '^gate|' "$T/calls.log")" -eq 1 ] || fail "concerns-lane: gate runs once"
[ "$(grep -c '^review-start|' "$T/calls.log")" -eq 3 ] || fail "concerns-lane: review pair starts"
[ "$(grep '^review-start|' "$T/calls.log" | grep -F -c -- "--context $concerns_file")" -eq 3 ] || fail "concerns-lane: every review start receives its context file"
grep -q '^review-collect|' "$T/calls.log" || fail "concerns-lane: reviews are collected"
[ "$(sed -n '2p' <<<"$OUT")" = "concerns=$concerns_file" ] || fail "concerns-lane: digest starts with the concerns path"

# --- a concerns path leads a long CHANGES digest instead of being truncated ---
setup_case concerns-changes
printf 'concerns-lane' >"$T/delegate-mode"
cat >"$T/collect-out" <<'EOF'
patch-id deadbeef
VERDICT standards: APPROVE
VERDICT spec: CHANGES
VERDICT overbuild: APPROVE
CI deadbeef pass
EOF
: >"$T/findings-src"
i=1
while [ "$i" -le 60 ]; do printf 'P1 finding %s\n' "$i" >>"$T/findings-src"; i=$((i + 1)); done
run_build
[ "$RC" -eq 1 ] || fail "concerns-changes exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=* p2=* p3=* mutants=* findings=* log=*" "concerns-changes"
concerns_file="$CDIR/run/switchyard-528-concerns-lane.md"
[ "$(sed -n '2p' <<<"$OUT")" = "concerns=$concerns_file" ] || fail "concerns-changes: digest starts with the concerns path"
grep -qx "concerns=$concerns_file" <<<"$OUT" || fail "concerns-changes: digest keeps concerns ahead of truncated findings"

# --- CONCERNS then DONE clears context before a from-gate review ---
setup_case cleared-concerns
lane_brief="$CDIR/run/switchyard-528-lane-1.md"
printf 'lane brief\n' >"$lane_brief"
printf 'concerns-lane' >"$T/delegate-mode"
OUT="$("$T/bin/tkt-job" "$S" --slot lane --brief "$lane_brief" --model lane-m --expect-commits 2>"$CDIR/lane-stderr.txt")"; RC=$?
[ "$RC" -eq 1 ] || fail "cleared-concerns initial CONCERNS exits 1 (rc=$RC)"
expect_verdict "TKT tkt-job CONCERNS id=stub-1 log=*" "cleared-concerns initial CONCERNS"
concerns_file="$CDIR/run/switchyard-528-concerns-lane.md"
expect_state concerns.lane "$concerns_file" cleared-concerns initial
printf 'done' >"$T/delegate-mode"
bash "$TKT_STATE" "$S" set job.lane '' || fail "cleared-concerns resets the lane job id"
OUT="$("$T/bin/tkt-job" "$S" --slot lane --brief "$lane_brief" --model lane-m --expect-commits 2>"$CDIR/lane-stderr.txt")"; RC=$?
[ "$RC" -eq 0 ] || fail "cleared-concerns follow-up DONE exits 0 (rc=$RC)"
expect_verdict "TKT tkt-job DONE id=stub-2 head=b commits=1 gate=PASS log=*" "cleared-concerns follow-up DONE"
expect_state concerns.lane "" cleared-concerns follow-up
run_build --from gate
[ "$RC" -eq 0 ] || fail "cleared-concerns from gate exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "cleared-concerns from gate"
[ "$(grep -c '^review-start|' "$T/calls.log")" -eq 3 ] || fail "cleared-concerns: every review starts"
grep '^review-start|' "$T/calls.log" | grep -q -- '--context' && fail "cleared-concerns: review starts have no context"
grep -q '^concerns=' <<<"$OUT" && fail "cleared-concerns: digest has no concerns line"

# --- a lane with no model is refused before dispatch, never a LANE-ERROR ---
setup_case lane-error
grep -v '^model\.lane=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
run_build
[ "$RC" -eq 2 ] || fail "lane-error exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION missing=model.lane log=*" "lane-error"
grep -q "model.lane" <<<"$OUT" || fail "lane-error: the digest names the key"
grep -q "model.lane" "$CDIR/stderr.txt" || fail "lane-error: stderr names the key"
grep -q -- "-lane-" "$T/calls.log" && fail "lane-error: the lane never dispatches"

# --- the lane brief carries the state lane model, never unknown ---
setup_case lane-model
run_build
[ "$RC" -eq 0 ] || fail "lane-model exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "lane-model"
grep -q "^run|id=stub-1|model=codex/test-model|" "$T/calls.log" || fail "lane-model: the lane runs on model.lane"
brief="$(grep '^run|' "$T/calls.log" | sed 's/.*prompt=//')"
case "$brief" in "$CDIR/run/"*) ;; *) fail "lane-model: the brief is written under \$CDIR/run";; esac
impl="$(grep '^Implemented by:' "$brief")"
[ "$impl" = "Implemented by: codex/test-model" ] || fail "lane-model: the brief holds [$impl]"
case "$impl" in *unknown*) fail "lane-model: the Implemented by line never holds unknown";; esac

# --- mapped provider refusals name their provider and stop before dispatch ---
quota_refusal_case() {
  local case_name="$1" model="$2" provider="$3"
  setup_case "$case_name"
  jq --arg provider "$provider" '.providers |= map(if .id == $provider then .status = "warning" else . end)' \
    "$T/quota-healthy.json" >"$T/quota.json" || fail "$case_name: build warning feed"
  run_build --lane-model "$model"
  [ "$RC" -eq 2 ] || fail "$case_name exits 2 (rc=$RC): $(cat "$CDIR/stderr.txt")"
  expect_verdict "TKT tkt-build PRECONDITION quota=refused log=*" "$case_name"
  grep -q "provider=$provider status=warning" <<<"$OUT" || fail "$case_name: refusal names provider and status"
  ! grep -q '^run|id=stub-' "$T/calls.log" || fail "$case_name: refused lane was dispatched"
}
quota_refusal_case quota-codex codex/test-model codex
quota_refusal_case quota-openai openai/test-model codex
quota_refusal_case quota-cursor fiber/cursor/test-model cursor
quota_refusal_case quota-opencode fiber/opencode-go/test-model opencode-go
quota_refusal_case quota-muse fiber/muse/test-model muse
quota_refusal_case quota-claude-prefix fiber/claude/test-model claude
quota_refusal_case quota-bare-config composer-2.5 cursor

# --- provider missing from the feed and a non-answer both refuse pre-dispatch ---
setup_case quota-missing-provider
jq '.providers |= map(select(.id != "opencode-go"))' "$T/quota-healthy.json" >"$T/quota.json"
run_build --lane-model opencode-go/test-model
[ "$RC" -eq 2 ] || fail "quota-missing-provider exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION quota=missing log=*" "quota-missing-provider"
grep -q 'provider=opencode-go status=missing' <<<"$OUT" || fail "quota-missing-provider: provider and missing status are named"
! grep -q '^run|id=stub-' "$T/calls.log" || fail "quota-missing-provider: lane was dispatched"

setup_case quota-no-answer
export QUOTA_FEED="file://$T/no-quota-feed.json"
run_build --lane-model codex/test-model
[ "$RC" -eq 2 ] || fail "quota-no-answer exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION quota=unavailable log=*" "quota-no-answer"
grep -q 'provider=codex status=unavailable' <<<"$OUT" || fail "quota-no-answer: provider and unavailable status are named"
! grep -q '^run|id=stub-' "$T/calls.log" || fail "quota-no-answer: lane was dispatched"
export QUOTA_FEED="file://$T/quota.json"

# --- Claude's 40% weekly floor refuses 39%, while a healthy pick is reported ---
setup_case quota-claude-low
jq '.providers |= map(if .id == "claude" then .quotas[0].percentRemaining = 39 else . end)' \
  "$T/quota-healthy.json" >"$T/quota.json"
run_build --lane-model claude-sonnet-5
[ "$RC" -eq 2 ] || fail "quota-claude-low exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION quota=refused log=*" "quota-claude-low"
grep -q 'provider=claude status=healthy weekly=39% floor=40%' <<<"$OUT" || fail "quota-claude-low: refusal reports weekly percent and floor"
! grep -q '^run|id=stub-' "$T/calls.log" || fail "quota-claude-low: lane was dispatched"

setup_case quota-claude-healthy
cp "$T/quota-healthy.json" "$T/quota.json"
run_build --lane-model claude-sonnet-5
[ "$RC" -eq 0 ] || fail "quota-claude-healthy exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -q '^quota: provider=claude status=healthy weekly=69% floor=40%$' <<<"$OUT" || fail "quota-claude-healthy: launch report shows the pick and floor"

# --- an unmappable model id is refused with the id before dispatch ---
setup_case quota-unmapped
run_build --lane-model unregistered/model-x
[ "$RC" -eq 2 ] || fail "quota-unmapped exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION quota=unmapped log=*" "quota-unmapped"
grep -q 'model=unregistered/model-x provider=unknown status=unmapped' <<<"$OUT" || fail "quota-unmapped: refusal names the unmapped id"
! grep -q '^run|id=stub-' "$T/calls.log" || fail "quota-unmapped: lane was dispatched"

# --- no PR for the branch stops the build before the gate ---
setup_case prempty
touch "$T/empty-pr"
run_build
[ "$RC" -eq 2 ] || fail "prempty exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION missing=pr log=*" "prempty"
grep -q "^gate|" "$T/calls.log" && fail "prempty: the gate never runs"

# --- a failing gate stops the build, which passes its verdict through ---
setup_case gate-fail
{
  printf 'Base: %s\n' "$H"
  printf '\n## Files\n\n- `src/a.txt`\n\n## Gate\n\n`false`\n'
} >"$CDIR/plan.md"
run_build
[ "$RC" -eq 1 ] || fail "gate-fail exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build FAIL rc=1 log=*" "gate-fail"

# --- an unpushed commit after the lane head stops the gate with no verdict line ---
setup_case gate-unpushed
printf 'local\n' >>"$WT/src/a.txt"
git -C "$WT" -c user.email=t@t -c user.name=t commit -qam local
run_build
[ "$RC" -eq 3 ] || fail "gate-unpushed exits 3 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build GATE-ERROR log=*" "gate-unpushed"
grep -q "drift" <<<"$OUT" || fail "gate-unpushed: the digest names the drift"

# --- an unmarked Files entry is a write and stales when main moves it ---
setup_case stale
mkdir -p "$CDIR/seed/src"
printf 'main change\n' >"$CDIR/seed/src/a.txt"
git -C "$CDIR/seed" add src/a.txt
git -C "$CDIR/seed" -c user.email=t@t -c user.name=t commit -qm "main moves"
git -C "$CDIR/seed" push -q origin main
git -C "$WT" fetch -q origin
{
  printf 'Base: %s\n' "$(cat "$CDIR/main0")"
  printf '\n## Files\n\n- `src/a.txt`\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
bash "$TKT_STATE" "$S" set plan_verdict_base "$(cat "$CDIR/main0")" || fail "stale: seed matching verdict base"
run_build
[ "$RC" -eq 1 ] || fail "stale exits 1 (rc=$RC)"
expect_verdict "TKT tkt-build STALE n=1 base=* log=*" "stale"
grep -q "src/a.txt" <<<"$OUT" || fail "stale: the digest names the changed file"
grep -q "^run|" "$T/calls.log" && fail "stale: the lane never dispatches"

# --- a read-marked Files entry can move on main without staling the build ---
setup_case stale-read
printf 'main change\n' >"$CDIR/seed/base.txt"
git -C "$CDIR/seed" add base.txt
git -C "$CDIR/seed" -c user.email=t@t -c user.name=t commit -qm "main moves read path"
git -C "$CDIR/seed" push -q origin main
git -C "$WT" fetch -q origin
{
  printf 'Base: %s\n' "$(cat "$CDIR/main0")"
  printf '\n## Files\n\n- `src/a.txt`\n- `base.txt` (read)\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
bash "$TKT_STATE" "$S" set plan_verdict_base "$(cat "$CDIR/main0")" || fail "stale-read: seed matching verdict base"
run_build
[ "$RC" -eq 0 ] || fail "stale-read exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "stale-read"

# --- only a Files line's first backticked token is a pathspec: a later
# non-path token (/reload) must not fail git, and the changed path still counts ---
setup_case files-column
mkdir -p "$CDIR/seed/src"
printf 'main change\n' >"$CDIR/seed/src/a.txt"
git -C "$CDIR/seed" add src/a.txt
git -C "$CDIR/seed" -c user.email=t@t -c user.name=t commit -qm "main moves"
git -C "$CDIR/seed" push -q origin main
git -C "$WT" fetch -q origin
{
  printf 'Base: %s\n' "$(cat "$CDIR/main0")"
  printf '\n## Files\n\n- `src/a.txt` reads `src/b.txt` and `/reload`\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
bash "$TKT_STATE" "$S" set plan_verdict_base "$(cat "$CDIR/main0")" || fail "files-column: seed matching verdict base"
run_build
[ "$RC" -eq 1 ] || fail "files-column exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build STALE n=1 base=* log=*" "files-column"

# --- a later backticked token that changes on main is not a stale path ---
setup_case files-second
mkdir -p "$CDIR/seed/src"
printf 'main change\n' >"$CDIR/seed/src/b.txt"
git -C "$CDIR/seed" add src/b.txt
git -C "$CDIR/seed" -c user.email=t@t -c user.name=t commit -qm "main moves b"
git -C "$CDIR/seed" push -q origin main
git -C "$WT" fetch -q origin
{
  printf 'Base: %s\n' "$(cat "$CDIR/main0")"
  printf '\n## Files\n\n- `src/a.txt` reads `src/b.txt`\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
bash "$TKT_STATE" "$S" set plan_verdict_base "$(cat "$CDIR/main0")" || fail "files-second: seed matching verdict base"
run_build
case "$(first_line)" in "TKT tkt-build STALE"*) fail "files-second: a later token is not a pathspec: $(first_line)";; esac

# --- a plan without Files skips the stale check ---
setup_case nofiles
git -C "$WT" reset -q --hard origin/main
git -C "$WT" push -q -f origin tkt-528
H="$(git -C "$WT" rev-parse HEAD)"
printf '%s' "$H" >"$T/prhead"
{
  printf 'Base: %s\n' "$H"
  printf '\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
bash "$TKT_STATE" "$S" set plan_verdict_base "$H" || fail "nofiles: seed matching verdict base"
run_build
[ "$RC" -eq 0 ] || fail "nofiles exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "nofiles"

# --- a backticked Base line is read as the bare SHA ---
setup_case basetick
git -C "$WT" reset -q --hard origin/main
git -C "$WT" push -q -f origin tkt-528
H="$(git -C "$WT" rev-parse HEAD)"
printf '%s' "$H" >"$T/prhead"
{
  printf 'Base: `%s`\n' "$H"
  printf '\n## Files\n\n- `src/a.txt`\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
bash "$TKT_STATE" "$S" set plan_verdict_base "$H" || fail "basetick: seed matching verdict base"
run_build
[ "$RC" -eq 0 ] || fail "basetick exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "basetick"

# --- a spec file path in state never reaches review-pr; review reads --issue ---
setup_case spec-path
printf 'ticket body\n' >"$CDIR/spec.md"
bash "$TKT_STATE" "$S" set spec "$CDIR/spec.md" || fail "spec-path: set spec"
run_build --lane-model codex/test-model --review-model rrm --overbuild-model oom
[ "$RC" -eq 0 ] || fail "spec-path exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "spec-path"
[ "$(grep -c '^review-start|' "$T/calls.log")" -eq 3 ] || fail "spec-path: one start per axis"
grep -q "^review-start|.*--issue 528 " "$T/calls.log" || fail "spec-path: review-start carries --issue 528"
grep -q "^review-start|.*--spec" "$T/calls.log" && fail "spec-path: review-start never carries --spec"
grep -q "$CDIR/spec.md" "$T/calls.log" && fail "spec-path: the spec path reaches no review-pr call"

# --- a spec issue is passed to every review start without passing the spec path ---
setup_case spec-issue
printf 'ticket body\n' >"$CDIR/spec.md"
bash "$TKT_STATE" "$S" set spec "$CDIR/spec.md" || fail "spec-issue: set spec path"
bash "$TKT_STATE" "$S" set spec_issue 445 || fail "spec-issue: set spec issue"
run_build --lane-model codex/test-model --review-model rrm --overbuild-model oom
[ "$RC" -eq 0 ] || fail "spec-issue exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "spec-issue"
[ "$(grep -c '^review-start|' "$T/calls.log")" -eq 3 ] || fail "spec-issue: one start per axis"
[ "$(grep -c -- '--spec 445' "$T/calls.log")" -eq 3 ] || fail "spec-issue: all review starts carry --spec 445"
grep -qF -- "$CDIR/spec.md" "$T/calls.log" && fail "spec-issue: spec path reaches no review-pr call"

# --- an unset spec_issue and spec key add no --spec argument ---
setup_case no-spec-issue
run_build --lane-model codex/test-model --review-model rrm --overbuild-model oom
[ "$RC" -eq 0 ] || fail "no-spec-issue exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "no-spec-issue"
[ "$(grep -c '^review-start|' "$T/calls.log")" -eq 3 ] || fail "no-spec-issue: one start per axis"
grep '^review-start|' "$T/calls.log" | grep -q -- '--spec' && fail "no-spec-issue: no review start carries --spec"

# --- a missing state key names itself ---
setup_case missingkey
grep -v '^plan=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
run_build
[ "$RC" -eq 2 ] || fail "missingkey exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION missing=plan log=*" "missingkey"
grep -q 'missing key: plan' "$CDIR/stderr.txt" || fail "missingkey: stderr names plan"
grep -Fq "tkt-plan $S set <plan-path>" <<<"$OUT" || fail "missingkey: refusal names the plan repair command"

# --- a plan without a Base line stops the build ---
setup_case basemissing
printf '## Files\n\n- `src/a.txt`\n' >"$CDIR/plan.md"
run_build
[ "$RC" -eq 2 ] || fail "basemissing exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION missing=base log=*" "basemissing"

# --- an unreadable base stops the build ---
setup_case gitfail
{
  printf 'Base: %s\n' 0000000000000000000000000000000000000000
  printf '\n## Files\n\n- `src/a.txt`\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
bash "$TKT_STATE" "$S" set plan_verdict_base 0000000000000000000000000000000000000000 || fail "gitfail: seed matching verdict base"
run_build
[ "$RC" -eq 2 ] || fail "gitfail exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION git=failed log=*" "gitfail"

# --- a plan without a Gate section stops the lane ---
setup_case gateless
{
  printf 'Base: %s\n' "$H"
  printf '\n## Files\n\n- `src/a.txt`\n'
} >"$CDIR/plan.md"
run_build
[ "$RC" -eq 2 ] || fail "gateless exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION missing=gate log=*" "gateless"
grep -q "^run|" "$T/calls.log" && fail "gateless: the lane never dispatches"

# --- a resumed lane's Gate line must run gate.script, not expand it by hand ---
setup_case gate-script-hand
bash "$TKT_STATE" "$S" set gate.script scripts/check || fail "gate-script-hand: seed gate.script"
{
  printf 'Base: %s\n' "$H"
  printf '\n## Files\n\n- `src/a.txt`\n\n## Gate\n\n`cargo fmt --check && cargo test`\n'
} >"$CDIR/plan.md"
run_build
[ "$RC" -eq 2 ] || fail "gate-script-hand exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION missing=gate log=*" "gate-script-hand"
grep -q "gate script scripts/check" <<<"$OUT" || fail "gate-script-hand: the digest names gate.script"
grep -q "^run|" "$T/calls.log" && fail "gate-script-hand: the lane never dispatches"

# --- the same state with a Gate line that runs gate.script proceeds ---
setup_case gate-script-run
bash "$TKT_STATE" "$S" set gate.script scripts/check || fail "gate-script-run: seed gate.script"
mkdir -p "$WT/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WT/scripts/check"
chmod +x "$WT/scripts/check"
{
  printf 'Base: %s\n' "$H"
  printf '\n## Files\n\n- `src/a.txt`\n\n## Gate\n\n`scripts/check`\n'
} >"$CDIR/plan.md"
run_build
[ "$RC" -eq 0 ] || fail "gate-script-run exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "gate-script-run"
grep -q "GATE=scripts/check" "$T/calls.log" || fail "gate-script-run: the lane gets the gate script"

# --- usage arms ---
setup_case usage
run_build --from bogus
[ "$RC" -eq 2 ] || fail "bad --from exits 2"
run_build --bogus
[ "$RC" -eq 2 ] || fail "a bad flag exits 2"
OUT="$(bash "$BUILD" 2>/dev/null)"; RC=$?
[ "$RC" -eq 2 ] || fail "no state exits 2"
OUT="$(bash "$BUILD" "$S" --help 2>/dev/null)"; RC=$?
[ "$RC" -eq 2 ] || fail "--help exits 2"

# --- a held lock names its holder and runs nothing ---
setup_case locked
mkdir "$S.lock"
printf '424242\n' >"$S.lock/pid"
run_build
[ "$RC" -eq 2 ] || fail "locked exits 2 (rc=$RC)"
grep -q "424242" "$CDIR/stderr.txt" || fail "locked: stderr names the pid"
grep -q "^run|" "$T/calls.log" && fail "locked: nothing dispatches"
rm -rf "$S.lock"
setup_case lock-nopid
mkdir "$S.lock"
run_build
[ "$RC" -eq 2 ] || fail "lock-nopid exits 2 (rc=$RC)"
grep -q "state locked" "$CDIR/stderr.txt" || fail "lock-nopid: stderr says locked"
rm -rf "$S.lock"

# --- head drift stops the run before it acts ---
setup_case drift
bash "$TKT_STATE" "$S" set head 0000000000000000000000000000000000000000 || fail "set fake head"
run_build
[ "$RC" -eq 3 ] || fail "drift exits 3 (rc=$RC)"
expect_verdict "TKT tkt-build DRIFT state=0000000000000000000000000000000000000000 worktree=$H pr=* log=*" "drift"
grep -q "$H" "$CDIR/stderr.txt" || fail "drift: stderr names the worktree HEAD"
grep -q "^run|" "$T/calls.log" && fail "drift: the lane never dispatches"

# --- --from gate skips the lane; --from review skips the lane and the gate ---
setup_case from-gate
run_build --from gate
[ "$RC" -eq 0 ] || fail "from-gate exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "from-gate"
grep -q "^run|" "$T/calls.log" && fail "from-gate: no delegated job dispatches"
grep -q "^gate|" "$T/calls.log" || fail "from-gate: the gate still runs"
expect_state pr 7 from-gate
expect_state head "$H" from-gate

setup_case from-review
bash "$TKT_STATE" "$S" set pr 7 || fail "set pr"
bash "$TKT_STATE" "$S" set head "$H" || fail "set head"
run_build --from review
[ "$RC" -eq 0 ] || fail "from-review exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "from-review"
grep -q "^run|" "$T/calls.log" && fail "from-review: no delegated job dispatches"
grep -q "^gate|" "$T/calls.log" && fail "from-review: the gate never runs"
grep -q "pr list" "$T/calls.log" && fail "from-review: the PR list is never read"
grep -q "^review-start|" "$T/calls.log" || fail "from-review: review still starts"

# --- a gate-stopped no-verifier build records that review is still blocked ---
setup_case gate-stopped-no-verifier
bash "$TKT_STATE" "$S" set plan_verdict skipped >/dev/null || fail "gate-stopped: seed no-verifier skip"
bash "$TKT_STATE" "$S" set plan_verdict_base "$H" >/dev/null || fail "gate-stopped: seed no-verifier base"
sed 's/`true`/`false`/' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
run_build --from gate --no-verifier
[ "$RC" -ne 0 ] || fail "gate-stopped: failing gate must stop build"
expect_state review_status gate-failed "gate-stopped"

# --- --from review without pr and head derives them from the branch PR ---
setup_case review-derives-pr
[ -z "$(bash "$TKT_STATE" "$S" get pr 2>/dev/null || true)" ] || fail "review-derives-pr: PR key starts absent"
[ -z "$(bash "$TKT_STATE" "$S" get head 2>/dev/null || true)" ] || fail "review-derives-pr: head key starts absent"
run_build --from review
[ "$RC" -eq 0 ] || fail "review-derives-pr exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "review-derives-pr"
expect_state pr 7 review-derives-pr
expect_state head "$H" review-derives-pr
grep -Fq "gh|pr list --head tkt-528 --repo switchyard --json number,headRefOid" "$T/calls.log" || fail "review-derives-pr: missing PR keys are recovered by branch lookup"
grep -q "^review-start|" "$T/calls.log" || fail "review-derives-pr: review still starts"

# --- --from review with head set but pr unset derives pr and proceeds ---
setup_case review-head-only
bash "$TKT_STATE" "$S" set head "$H" || fail "set head"
run_build --from review
[ "$RC" -eq 0 ] || fail "review-head-only exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "review-head-only"
expect_state pr 7 review-head-only
expect_state head "$H" review-head-only
grep -q "pr list" "$T/calls.log" || fail "review-head-only: the branch PR is looked up"
grep -q "^review-start|" "$T/calls.log" || fail "review-head-only: review still starts"

# --- --from review with pr unset and a stale stored head reports DRIFT ---
setup_case review-stale-head
bash "$TKT_STATE" "$S" set head 0000000000000000000000000000000000000000 || fail "set stale head"
run_build --from review
[ "$RC" -eq 3 ] || fail "review-stale-head exits 3 (rc=$RC)"
expect_verdict "TKT tkt-build DRIFT state=0000000000000000000000000000000000000000 worktree=$H pr=$H log=*" "review-stale-head"
expect_state head 0000000000000000000000000000000000000000 review-stale-head
grep -q "^review-start|" "$T/calls.log" && fail "review-stale-head: review never starts"

# --- --from review without pr and head and no PR names the missing key ---
setup_case review-missing-pr
touch "$T/empty-pr"
run_build --from review
[ "$RC" -eq 2 ] || fail "review-missing-pr exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION missing=pr log=*" "review-missing-pr"
grep -q "^gate|" "$T/calls.log" && fail "review-missing-pr: the gate never runs"

# --- --from review with a moved PR head reports the drift ---
setup_case review-drift
bash "$TKT_STATE" "$S" set pr 7 || fail "set pr"
bash "$TKT_STATE" "$S" set head "$H" || fail "set head"
printf '%s' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$T/prhead"
run_build --from review
[ "$RC" -eq 3 ] || fail "review-drift exits 3 (rc=$RC)"
expect_verdict "TKT tkt-build DRIFT state=$H worktree=$H pr=aaa* log=*" "review-drift"

# --- --from review with an unreadable PR head reports the drift ---
setup_case review-noprhead
bash "$TKT_STATE" "$S" set pr 7 || fail "set pr"
bash "$TKT_STATE" "$S" set head "$H" || fail "set head"
touch "$T/noview"
run_build --from review
[ "$RC" -eq 3 ] || fail "review-noprhead exits 3 (rc=$RC)"
expect_verdict "TKT tkt-build DRIFT state=$H worktree=$H pr=unreadable log=*" "review-noprhead"

# --- missing review models name the missing key ---
setup_case missing-model
grep -v '^model\.review=' "$S" | grep -v '^model\.overbuild=' >"$S.tmp" && mv "$S.tmp" "$S"
run_build
[ "$RC" -eq 2 ] || fail "missing-model exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION missing=model.review log=*" "missing-model"

# --- a rerun after the lane finished starts no second lane ---
setup_case rerun
run_build
[ "$RC" -eq 0 ] || fail "rerun first exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "rerun first"
run_build
[ "$RC" -eq 1 ] || fail "rerun second exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build ROUND-LIMIT round=0 log=*" "rerun second"
[ "$(grep -c '^run|' "$T/calls.log")" -eq 1 ] || fail "rerun: one lane dispatch across both runs"
[ "$(grep -c '^watch|' "$T/calls.log")" -eq 2 ] || fail "rerun: the first build watches twice, the second watches nothing"

# --- a zero fix-round count without a completed first review does not block build ---
setup_case round-zero-unreviewed
bash "$TKT_STATE" "$S" set round 0 >/dev/null || fail "round-zero-unreviewed: seed zero counter"
run_build --from gate
[ "$RC" -eq 0 ] || fail "round-zero-unreviewed build proceeds (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "round-zero-unreviewed build"
expect_state round 0 "round-zero-unreviewed retains zero as the spent fix count"
expect_state reviewed "$H" "round-zero-unreviewed completes the first review"

# --- a round-1 gate fix without a completed review can resume at either phase ---
setup_case round-one-unreviewed-review
bash "$TKT_STATE" "$S" set round 1 >/dev/null || fail "round-one-unreviewed-review: seed round"
bash "$TKT_STATE" "$S" set pr 7 >/dev/null || fail "round-one-unreviewed-review: seed PR"
bash "$TKT_STATE" "$S" set head "$H" >/dev/null || fail "round-one-unreviewed-review: seed head"
run_build --from review
[ "$RC" -eq 0 ] || fail "round-one-unreviewed-review proceeds (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "round-one-unreviewed-review"
grep -q "^review-start|" "$T/calls.log" || fail "round-one-unreviewed-review starts review"

setup_case round-one-unreviewed-gate
bash "$TKT_STATE" "$S" set round 1 >/dev/null || fail "round-one-unreviewed-gate: seed round"
run_build --from gate
[ "$RC" -eq 0 ] || fail "round-one-unreviewed-gate proceeds (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "round-one-unreviewed-gate"
grep -q "^gate|" "$T/calls.log" || fail "round-one-unreviewed-gate runs gate"

# --- a state with round already set and a completed review is refused ---
setup_case round-set
bash "$TKT_STATE" "$S" set round 1 >/dev/null || fail "seed round"
bash "$TKT_STATE" "$S" set reviewed "$H" >/dev/null || fail "seed reviewed head"
run_build
[ "$RC" -eq 1 ] || fail "round-set build exits 1 (rc=$RC)"
expect_verdict "TKT tkt-build ROUND-LIMIT round=1 log=*" "round-set build"
grep -q "wrong phase after the first round" <<<"$OUT" || fail "round-set build says this is the wrong phase"
grep -q "tkt-fix .*--verify" <<<"$OUT" || fail "round-set build names tkt-fix"
grep -q "tkt-ship" <<<"$OUT" || fail "round-set build names tkt-ship"
grep -q "not the round limit" <<<"$OUT" || fail "round-set build distinguishes the round limit"
[ ! -s "$T/calls.log" ] || fail "round-set build dispatches nothing: $(cat "$T/calls.log")"

# --- an incomplete map never approves, but stays in the digest ---
setup_case mapfail
printf 'mutant_job=%s\n' Selection >>"$S"
printf 'ask-map' >"$T/delegate-mode"
printf 'which mutant matters?\n' >"$T/ask-text"
run_build
[ "$RC" -eq 1 ] || fail "mapfail exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=0 p3=0 mutants=0 findings=* log=*" "mapfail"
grep -q "map failed" <<<"$OUT" || fail "mapfail: the digest notes the map stop"

# --- a map-only tooling note leaves the build state re-runnable ---
setup_case map-note-only
printf 'mutant_job=%s\n' Selection >>"$S"
grep -v '^model\.map=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
run_build
[ "$RC" -eq 1 ] || fail "map-note-only exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=0 p3=0 mutants=0 findings=* log=*" "map-note-only"
grep -q "map failed: missing model.map" <<<"$OUT" || fail "map-note-only: the digest notes the map stop"
for key in reviewed findings round; do
  if bash "$TKT_STATE" "$S" get "$key" >/dev/null 2>&1; then
    fail "map-note-only: state $key should remain unset"
  fi
done
bash "$TKT_STATE" "$S" set model.map mm || fail "map-note-only: restore map model"
run_build
[ "$RC" -eq 1 ] || fail "map-note-only retry exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=2 p3=0 mutants=2 findings=* log=*" "map-note-only retry"
expect_state reviewed "$H" "map-note-only retry"
expect_state round 0 "map-note-only retry with findings"

# --- a mutant job with no such job name lists no mutants and skips the map ---
setup_case mutants-nojob
printf 'mutant_job=%s\n' Other >>"$S"
run_build
[ "$RC" -eq 0 ] || fail "mutants-nojob exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "mutants-nojob"
grep -q "prompt=.*-map-" "$T/calls.log" && fail "mutants-nojob: no map job dispatches"
[ -e "$CDIR/run/switchyard-528-mutants-${H:0:12}.txt" ] || fail "mutants-nojob: the empty mutants file exists"
[ -s "$CDIR/run/switchyard-528-mutants-${H:0:12}.txt" ] && fail "mutants-nojob: the mutants file is empty"

# --- P1: transport-prefixed mutant log lines still list mutants ---
setup_case prefixed-log
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
Selection Build 2026-10-17T00:00:00Z src/a.rs:10:20: MISSED
Selection Build 2026-10-17T00:00:00Z noise without a location
Selection Build 2026-10-17T00:00:00Z mutants in the diff: 2
Selection Build 2026-10-17T00:00:00Z src/b.rs:3:4: TIMEOUT
EOF
run_build
[ "$RC" -eq 1 ] || fail "prefixed-log exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=2 p3=0 mutants=2 findings=* log=*" "prefixed-log"
mfile="$CDIR/run/switchyard-528-mutants-${H:0:12}.txt"
[ "$(grep -c . "$mfile")" -eq 3 ] || fail "prefixed-log: three stripped lines match"
grep -q "^src/a.rs:10:20:" "$mfile" || fail "prefixed-log: prefixes stripped"

# --- an incomplete map does not APPROVE ---
setup_case map-incomplete
printf 'mutant_job=%s\n' Selection >>"$S"
printf 'ask-map' >"$T/delegate-mode"
printf 'which mutant matters?\n' >"$T/ask-text"
run_build
[ "$RC" -eq 1 ] || fail "map-incomplete exits 1 (rc=$RC)"
case "$(first_line)" in "TKT tkt-build APPROVE"*) fail "map-incomplete: incomplete map must not APPROVE";; esac
grep -q "map failed" <<<"$OUT" || fail "map-incomplete: the digest notes the map stop"

# --- a rerun reuses the persisted review ids ---
setup_case review-reuse
run_build
[ "$RC" -eq 0 ] || fail "review-reuse first exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
run_build
[ "$RC" -eq 1 ] || fail "review-reuse second exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build ROUND-LIMIT round=0 log=*" "review-reuse second"
[ "$(grep -c '^review-start|' "$T/calls.log")" -eq 3 ] || fail "review-reuse: three axis starts across both runs"
rv="$(bash "$TKT_STATE" "$S" get review_ids)"; [ -n "$rv" ] || fail "review-reuse: review_ids persisted"
[ "$(bash "$TKT_STATE" "$S" get review_head)" = "$H" ] || fail "review-reuse: review_head is the head"

# --- a missing mutant verdict fails the map ---
setup_case map-missing
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
src/a.rs:10:20: MISSED
mutants in the diff: 2
src/b.rs:3:4: TIMEOUT
EOF
cat >"$T/map-text" <<'EOF'
src/a.rs:10:20: MISSED => needs-test: bounds check unpinned
EOF
run_build
[ "$RC" -eq 1 ] || fail "map-missing exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
case "$(first_line)" in "TKT tkt-build APPROVE"*) fail "map-missing: missing verdict must not APPROVE";; esac
expect_verdict "TKT tkt-build CHANGES p1=0 p2=0 p3=0 mutants=0 findings=* log=*" "map-missing"
grep -q "map failed: no verdict for src/b.rs:3:4: TIMEOUT" <<<"$OUT" || fail "map-missing: the digest names the missing mutant"

# --- a short location never covers its longer prefix sibling ---
setup_case map-prefix
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
foo.rs:1:1: MISSED
mutants in the diff: 2
foo.rs:1:12: MISSED
EOF
cat >"$T/map-text" <<'EOF'
foo.rs:1:12: MISSED => needs-test: long line only
EOF
run_build
[ "$RC" -eq 1 ] || fail "map-prefix exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
case "$(first_line)" in "TKT tkt-build APPROVE"*) fail "map-prefix: prefix cover must not APPROVE";; esac
grep -q "map failed: no verdict for foo.rs:1:1: MISSED" <<<"$OUT" || fail "map-prefix: the short mutant stays uncovered"

# --- needs-test without the colon fails the map ---
setup_case map-nocolon
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
src/a.rs:10:20: MISSED
mutants in the diff: 1
EOF
cat >"$T/map-text" <<'EOF'
src/a.rs:10:20: MISSED => needs-test bounds missing
EOF
run_build
[ "$RC" -eq 1 ] || fail "map-nocolon exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
case "$(first_line)" in "TKT tkt-build APPROVE"*) fail "map-nocolon: colonless verdict must not APPROVE";; esac
grep -q "map failed: bad verdict for src/a.rs:10:20: MISSED" <<<"$OUT" || fail "map-nocolon: the digest names the off-grammar mutant"

# --- a duplicate verdict fails the map ---
setup_case map-duplicate
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
src/a.rs:10:20: MISSED
mutants in the diff: 1
EOF
cat >"$T/map-text" <<'EOF'
src/a.rs:10:20: MISSED => needs-test: first claim
src/a.rs:10:20: MISSED => removed: second claim
EOF
run_build
[ "$RC" -eq 1 ] || fail "map-duplicate exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
case "$(first_line)" in "TKT tkt-build APPROVE"*) fail "map-duplicate: duplicate verdict must not APPROVE";; esac
grep -q "map failed: duplicate verdict for src/a.rs:10:20: MISSED" <<<"$OUT" || fail "map-duplicate: the digest names the duplicated mutant"

# --- a valid needs-test line merges exactly one P2 finding ---
setup_case map-valid-oneneeds
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
src/a.rs:10:20: MISSED
mutants in the diff: 1
EOF
cat >"$T/map-text" <<'EOF'
src/a.rs:10:20: MISSED => needs-test: bounds check unpinned
EOF
run_build
[ "$RC" -eq 1 ] || fail "map-valid-oneneeds exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=1 p3=0 mutants=1 findings=* log=*" "map-valid-oneneeds"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
[ "$(grep -c '^P2 ' "$ffile")" -eq 1 ] || fail "map-valid-oneneeds: exactly one P2 finding"
grep -qx "P2 src/a.rs:10:20: MISSED => needs-test: bounds check unpinned \\[mutants $CDIR/run/switchyard-528-mutants-${H:0:12}.txt\\]" "$ffile" || fail "map-valid-oneneeds: the P2 line merges"

# --- a dispatch that dies after one review launch reuses that id on rerun ---
setup_case review-partial
printf 'die-after-one' >"$T/review-mode"
run_build
[ "$RC" -eq 1 ] || fail "review-partial first exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build REVIEW-INCOMPLETE log=*" "review-partial first"
first_id="$(bash "$TKT_STATE" "$S" get review_ids)"; [ "$first_id" = "r1" ] || fail "review-partial: one id persisted after the death, got [$first_id]"
[ "$(bash "$TKT_STATE" "$S" get review_head)" = "$H" ] || fail "review-partial: review_head persisted with the partial ids"
printf 'ok' >"$T/review-mode"
run_build
[ "$RC" -eq 0 ] || fail "review-partial second exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "review-partial second"
[ "$(grep -c -- ' --axes standards' "$T/calls.log")" -eq 1 ] || fail "review-partial: standards launched once across both runs"
rv2="$(bash "$TKT_STATE" "$S" get review_ids)"; case " $rv2 " in " r1 "*|" r1"|*" r1"*) ;; *) fail "review-partial: first id reused, got [$rv2]";; esac
[ "$(printf '%s' "$rv2" | wc -w | tr -d ' ')" -eq 3 ] || fail "review-partial: three ids after recovery, got [$rv2]"

# --- a BAD-VERDICT axis restarts on the rerun; valid axes keep their ids ---
setup_case bad-verdict-rerun
cat >"$T/collect-out" <<'EOF'
patch-id deadbeef
VERDICT standards: APPROVE
BAD-VERDICT spec VERDICT spec: PASS
VERDICT overbuild: APPROVE
CI deadbeef pass
EOF
printf '1' >"$T/collect-rc"
run_build
[ "$RC" -eq 1 ] || fail "bad-verdict-rerun first exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build REVIEW-INCOMPLETE log=*" "bad-verdict-rerun first"
rv="$(bash "$TKT_STATE" "$S" get review_ids)"; [ "$rv" = "r1 RESTART r3" ] || fail "bad-verdict-rerun: the spec id restarts, the others stay, got [$rv]"
[ "$(bash "$TKT_STATE" "$S" get review_head)" = "$H" ] || fail "bad-verdict-rerun: review_head stays on the head"
cat >"$T/collect-out" <<'EOF'
patch-id deadbeef
VERDICT standards: APPROVE
VERDICT spec: APPROVE
VERDICT overbuild: APPROVE
CI deadbeef pass
EOF
printf '0' >"$T/collect-rc"
run_build
[ "$RC" -eq 0 ] || fail "bad-verdict-rerun second exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "bad-verdict-rerun second"
[ "$(grep -c -- '--axes standards' "$T/calls.log")" -eq 1 ] || fail "bad-verdict-rerun: standards starts once across both runs"
[ "$(grep -c -- '--axes spec' "$T/calls.log")" -eq 2 ] || fail "bad-verdict-rerun: spec starts again on the rerun"
[ "$(grep -c -- '--axes overbuild' "$T/calls.log")" -eq 1 ] || fail "bad-verdict-rerun: overbuild starts once across both runs"
rv2="$(bash "$TKT_STATE" "$S" get review_ids)"; [ "$rv2" = "r1 r4 r3" ] || fail "bad-verdict-rerun: valid ids kept, spec renewed, got [$rv2]"

# --- a collect without one axis's verdict is REVIEW-INCOMPLETE, not CHANGES ---
setup_case missing-axis-verdict
cat >"$T/collect-out" <<'EOF'
patch-id deadbeef
VERDICT standards: APPROVE
VERDICT overbuild: APPROVE
CI deadbeef pass
EOF
printf '0' >"$T/collect-rc"
run_build
[ "$RC" -eq 1 ] || fail "missing-axis-verdict exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build REVIEW-INCOMPLETE log=*" "missing-axis-verdict"
grep -q "spec" <<<"$OUT" || fail "missing-axis-verdict: the digest names spec"
case "$(first_line)" in "TKT tkt-build CHANGES"*|"TKT tkt-build APPROVE"*) fail "missing-axis-verdict: no CHANGES or APPROVE without every verdict";; esac
rv="$(bash "$TKT_STATE" "$S" get review_ids)"; [ "$rv" = "r1 RESTART r3" ] || fail "missing-axis-verdict: the spec id restarts, got [$rv]"
if bash "$TKT_STATE" "$S" get round >/dev/null 2>&1; then fail "missing-axis-verdict: round stays unset so the rerun can proceed"; fi

# --- a moved PR head is rejected before state writes ---
setup_case moved-head
bash "$TKT_STATE" "$S" set pr 7 || fail "set pr"
bash "$TKT_STATE" "$S" set head "$H" || fail "set head"
printf '%s' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$T/prhead"
run_build
[ "$RC" -eq 3 ] || fail "moved-head exits 3 (rc=$RC)"
expect_verdict "TKT tkt-build DRIFT state=$H worktree=$H pr=aaa* log=*" "moved-head"
expect_state head "$H" moved-head
grep -q "^run|" "$T/calls.log" && fail "moved-head: the lane never dispatches"

# --- one delegate watch covers review and map ids ---
setup_case single-watch
printf 'mutant_job=%s\n' Selection >>"$S"
run_build
[ "$RC" -eq 1 ] || fail "single-watch exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -q "^watch|r1 r2 r3 stub-2$" "$T/calls.log" || fail "single-watch: one watch covers all ids"
[ "$(grep -c '^watch|' "$T/calls.log")" -eq 2 ] || fail "single-watch: lane plus one build watch"
grep -q "^watch|stub-2$" "$T/calls.log" && fail "single-watch: no solo map watch"

# --- --help and -h print usage and exit 0, running nothing ---
out="$(bash "$BUILD" --help 2>"$T/help-err.txt")"; [ "$?" -eq 0 ] || fail "--help exits 0"
[ ! -s "$T/help-err.txt" ] || fail "--help prints nothing on stderr"
case "$out" in "usage: tkt-build <state>"*) ;; *) fail "--help prints usage: [$out]" ;; esac
out="$(bash "$BUILD" -h 2>"$T/help-err.txt")"; [ "$?" -eq 0 ] || fail "-h exits 0"
[ ! -s "$T/help-err.txt" ] || fail "-h prints nothing on stderr"
case "$out" in "usage: tkt-build <state>"*) ;; *) fail "-h prints usage: [$out]" ;; esac

# --- tkt-build passes --full-rereview on every start, so a prior review at a
# different patch-id does not refuse the round-0 pair ---
setup_case full-rereview-flag
run_build
[ "$RC" -eq 0 ] || fail "full-rereview-flag exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "full-rereview-flag"
for ax in standards spec overbuild; do
  grep -q -- "--axes $ax --full-rereview tkt-build round-0 full review" "$T/calls.log" || fail "full-rereview-flag: $ax starts with the override"
done
[ "$(grep -c -- '--full-rereview tkt-build round-0 full review' "$T/calls.log")" -eq 3 ] || fail "full-rereview-flag: one override per axis"

# --- shard survivors merge into the round-0 findings: mapped survivors stay
# single, a survivor the map called caught gains a CI P2, rows outside the
# diff and non-surviving rows stay out ---
setup_case shards-survivors
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
src/a.rs:10:20: MISSED
mutants in the diff: 4
src/b.rs:3:4: TIMEOUT
src/c.rs:5:6: MISSED
src/d.rs:7:8: MISSED
EOF
printf 'src/a.rs:10:20: MISSED\tmissed\nsrc/b.rs:3:4: TIMEOUT\ttimeout\nsrc/c.rs:5:6: MISSED\tmissed\nsrc/z.rs:9:9: X\tmissed\nsrc/e.rs:1:1: MISSED\tcaught\nsrc/d.rs:7:8: MISSED\tunviable\n' >"$T/verdicts"
run_build
[ "$RC" -eq 1 ] || fail "shards-survivors exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=3 p3=0 mutants=3 findings=* log=*" "shards-survivors"
grep -Fxq "ghci|wait 7 --job Selection --timeout 600 --repo switchyard" "$T/calls.log" || fail "shards-survivors: the listing wait carries --timeout 600"
grep -Fxq "ghci|wait --run 101 --pr 7 --timeout 2400 --repo switchyard" "$T/calls.log" || fail "shards-survivors: the shard wait names the run, the pr and 2400"
grep -Fxq "mverd|101 --repo switchyard" "$T/calls.log" || fail "shards-survivors: the verdicts read the waited run"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
[ "$(grep -cF 'P2 src/a.rs:10:20: MISSED => ' "$ffile")" -eq 1 ] || fail "shards-survivors: the mapped missed survivor is not duplicated"
[ "$(grep -cF 'P2 src/b.rs:3:4: TIMEOUT => ' "$ffile")" -eq 1 ] || fail "shards-survivors: the mapped timeout survivor is not duplicated"
grep -Fxq "P2 src/c.rs:5:6: MISSED => survived in CI (missed) [mutants-ci run 101 head ${H:0:12}]" "$ffile" || fail "shards-survivors: the survivor the map called caught becomes a CI P2"
grep -q "z.rs" "$ffile" && fail "shards-survivors: a survivor outside the diff stays out"
grep -Fq "src/e.rs" "$ffile" && fail "shards-survivors: a caught row stays out"
grep -Fq "src/d.rs" "$ffile" && fail "shards-survivors: an unviable row stays out"
grep -q "mutant shards unread" "$ffile" && fail "shards-survivors: a clean read reports no unread shards"

# --- a survivor the map exempted stays out of the findings ---
setup_case shards-exempted
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
src/a.rs:10:20: MISSED
mutants in the diff: 1
EOF
cat >"$T/map-text" <<'EOF'
src/a.rs:10:20: MISSED => exempted: covered elsewhere
EOF
printf 'src/a.rs:10:20: MISSED\tmissed\n' >"$T/verdicts"
run_build
[ "$RC" -eq 0 ] || fail "shards-exempted exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "shards-exempted"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -Fq "src/a.rs" "$ffile" && fail "shards-exempted: an exempted survivor stays out"
grep -q "mutant shards unread" "$ffile" && fail "shards-exempted: a clean read reports no unread shards"

# --- when the map failed, every in-diff survivor becomes a CI P2 ---
setup_case shards-mapfailed
printf 'mutant_job=%s\n' Selection >>"$S"
grep -v '^model\.map=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
printf 'src/a.rs:10:20: MISSED\tmissed\nsrc/b.rs:3:4: TIMEOUT\ttimeout\n' >"$T/verdicts"
run_build
[ "$RC" -eq 1 ] || fail "shards-mapfailed exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=2 p3=0 mutants=2 findings=* log=*" "shards-mapfailed"
grep -q "map failed" <<<"$OUT" || fail "shards-mapfailed: the digest notes the map stop"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -Fxq "P2 src/a.rs:10:20: MISSED => survived in CI (missed) [mutants-ci run 101 head ${H:0:12}]" "$ffile" || fail "shards-mapfailed: the missed survivor becomes a P2 without the map"
grep -Fxq "P2 src/b.rs:3:4: TIMEOUT => survived in CI (timeout) [mutants-ci run 101 head ${H:0:12}]" "$ffile" || fail "shards-mapfailed: the timeout survivor becomes a P2 without the map"

# --- a run-wait timeout reports the shards unread and reads no verdicts ---
setup_case shards-unread-timeout
printf 'mutant_job=%s\n' Selection >>"$S"
printf '124' >"$T/ghci-run-rc"
printf 'P1 open null check\nP3 docs note\n' >"$T/findings-src"
run_build
[ "$RC" -eq 1 ] || fail "shards-unread-timeout exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=1 p2=2 p3=2 mutants=2 findings=* log=*" "shards-unread-timeout"
grep -q '^mverd|' "$T/calls.log" && fail "shards-unread-timeout: verdicts never read after a timeout"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -q "survived in CI" "$ffile" && fail "shards-unread-timeout: no survivor P2 without verdicts"
grep -Fxq "P3 mutant shards unread: run 101 head ${H:0:12}: timeout after 2400s" "$ffile" || fail "shards-unread-timeout: the timeout is reported unread"
grep -q "mutant shards unread" <<<"$OUT" || fail "shards-unread-timeout: the digest carries the unread note"

# --- a failed run-wait reports its first stderr line as the cause ---
setup_case shards-unread-waitfail
printf 'mutant_job=%s\n' Selection >>"$S"
printf '2' >"$T/ghci-run-rc"
printf 'gh-ci: cannot watch runs here\nsecond line stays out\n' >"$T/ghci-err"
run_build
[ "$RC" -eq 1 ] || fail "shards-unread-waitfail exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=2 p3=1 mutants=2 findings=* log=*" "shards-unread-waitfail"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -Fxq "P3 mutant shards unread: run 101 head ${H:0:12}: gh-ci: cannot watch runs here" "$ffile" || fail "shards-unread-waitfail: the wait's cause is reported unread"
grep -q "second line stays out" "$ffile" && fail "shards-unread-waitfail: only the first stderr line is kept"

# --- a failed run-wait with silent stderr still names its exit ---
setup_case shards-unread-waitsilent
printf 'mutant_job=%s\n' Selection >>"$S"
printf '2' >"$T/ghci-run-rc"
run_build
[ "$RC" -eq 1 ] || fail "shards-unread-waitsilent exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=2 p3=1 mutants=2 findings=* log=*" "shards-unread-waitsilent"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -Fxq "P3 mutant shards unread: run 101 head ${H:0:12}: gh-ci wait --run failed with exit 2" "$ffile" || fail "shards-unread-waitsilent: the wait's exit is reported unread"

# --- failed verdicts report their first stderr line as the cause ---
setup_case shards-unread-verdicts
printf 'mutant_job=%s\n' Selection >>"$S"
printf '1' >"$T/verdicts-rc"
printf 'mutant-verdicts: run 101 is in_progress, not completed\nsecond line stays out\n' >"$T/verdicts-err"
run_build
[ "$RC" -eq 1 ] || fail "shards-unread-verdicts exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=2 p3=1 mutants=2 findings=* log=*" "shards-unread-verdicts"
grep -Fxq "mverd|101 --repo switchyard" "$T/calls.log" || fail "shards-unread-verdicts: the verdicts are read before reporting unread"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -Fxq "P3 mutant shards unread: run 101 head ${H:0:12}: mutant-verdicts: run 101 is in_progress, not completed" "$ffile" || fail "shards-unread-verdicts: the verdicts cause is reported unread"
grep -q "second line stays out" "$ffile" && fail "shards-unread-verdicts: only the first stderr line is kept"

# --- failed verdicts with silent stderr still name the run ---
setup_case shards-unread-verdictssilent
printf 'mutant_job=%s\n' Selection >>"$S"
printf '1' >"$T/verdicts-rc"
run_build
[ "$RC" -eq 1 ] || fail "shards-unread-verdictssilent exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=2 p3=1 mutants=2 findings=* log=*" "shards-unread-verdictssilent"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -Fxq "P3 mutant shards unread: run 101 head ${H:0:12}: mutant-verdicts failed for run 101" "$ffile" || fail "shards-unread-verdictssilent: the verdicts failure is reported unread"

# --- no run holding the mutant job reports the shards unread ---
setup_case shards-unread-norun
printf 'mutant_job=%s\n' Selection >>"$S"
touch "$T/no-runs"
run_build
[ "$RC" -eq 0 ] || fail "shards-unread-norun exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "shards-unread-norun"
grep -q -- '--run' "$T/calls.log" && fail "shards-unread-norun: nothing waited on without a run"
grep -q '^mverd|' "$T/calls.log" && fail "shards-unread-norun: verdicts never read without a run"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -Fxq "P3 mutant shards unread: run none head ${H:0:12}: no run with Selection on head" "$ffile" || fail "shards-unread-norun: the missing run is reported unread"
grep -q "mutant shards unread" <<<"$OUT" || fail "shards-unread-norun: the digest carries the unread note"

# --- without mutant_job, no run waits and no verdicts read ---
setup_case shards-nojob
run_build
[ "$RC" -eq 0 ] || fail "shards-nojob exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -q -- '--run' "$T/calls.log" && fail "shards-nojob: no run wait without mutant_job"
grep -q '^mverd|' "$T/calls.log" && fail "shards-nojob: no verdicts read without mutant_job"

# --- with an empty diff list, no run waits and no verdicts read ---
setup_case shards-emptydiff
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
log noise without any mutant location
more noise
EOF
run_build
[ "$RC" -eq 0 ] || fail "shards-emptydiff exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "shards-emptydiff"
grep -q -- '--run' "$T/calls.log" && fail "shards-emptydiff: no run wait for an empty diff list"
grep -q '^mverd|' "$T/calls.log" && fail "shards-emptydiff: no verdicts read for an empty diff list"
grep -q "prompt=.*-map-" "$T/calls.log" && fail "shards-emptydiff: no map job without mutants"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -q "mutant shards unread" "$ffile" && fail "shards-emptydiff: an empty diff list stays silent"

# --- a rerun reads no shard verdicts twice ---
setup_case shards-rerun
printf 'mutant_job=%s\n' Selection >>"$S"
run_build
[ "$RC" -eq 1 ] || fail "shards-rerun first exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
run_build
[ "$RC" -eq 1 ] || fail "shards-rerun second exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build ROUND-LIMIT round=0 log=*" "shards-rerun second"
[ "$(grep -c -- '--run' "$T/calls.log")" -eq 1 ] || fail "shards-rerun: one run wait across both runs"
[ "$(grep -c '^mverd|' "$T/calls.log")" -eq 1 ] || fail "shards-rerun: one verdicts read across both runs"

# --- a listing wait failure reports unread with its cause and reads no verdicts ---
setup_case listing-unread
printf 'mutant_job=%s\n' Selection >>"$S"
printf '2' >"$T/ghci-rc"
printf 'gh-ci: listing blew up\nsecond line stays out\n' >"$T/ghci-err"
run_build
[ "$RC" -eq 1 ] || fail "listing-unread exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=2 p3=1 mutants=2 findings=* log=*" "listing-unread"
grep -q '^mverd|' "$T/calls.log" && fail "listing-unread: verdicts never read when the list is unread"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -Fxq "P3 mutant shards unread: run 101 head ${H:0:12}: gh-ci: listing blew up" "$ffile" || fail "listing-unread: the listing cause is reported unread"
grep -q "second line stays out" "$ffile" && fail "listing-unread: only the first stderr line is kept"
grep -q "mutant shards unread" <<<"$OUT" || fail "listing-unread: the digest carries the unread note"

# --- a failed log read reports unread even when the count is zero ---
setup_case logread-unread
printf 'mutant_job=%s\n' Selection >>"$S"
touch "$T/log-fail"
printf 'cannot fetch job log\nsecond line stays out\n' >"$T/log-err"
printf 'no open findings\n' >"$T/findings-src"
run_build
[ "$RC" -eq 0 ] || fail "logread-unread exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "logread-unread"
grep -q '^mverd|' "$T/calls.log" && fail "logread-unread: verdicts never read when the log read fails"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -Fxq "P3 mutant shards unread: run 101 head ${H:0:12}: cannot fetch job log" "$ffile" || fail "logread-unread: the log cause is reported unread"
grep -q "second line stays out" "$ffile" && fail "logread-unread: only the first stderr line is kept"
grep -q "mutant shards unread" <<<"$OUT" || fail "logread-unread: the digest carries the unread note"

# --- CR and ANSI bytes in the log are stripped before the map reads them ---
setup_case cr-ansi
printf 'mutant_job=%s\n' Selection >>"$S"
printf 'src/a.rs:10:20: MISSED\r\n\x1b[31msrc/b.rs:3:4: TIMEOUT\x1b[0m\nmutants in the diff: 2\n' >"$T/mutant-log"
run_build
[ "$RC" -eq 1 ] || fail "cr-ansi exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=2 p3=0 mutants=2 findings=* log=*" "cr-ansi"
mfile="$CDIR/run/switchyard-528-mutants-${H:0:12}.txt"
grep -q "$(printf '\r')" "$mfile" && fail "cr-ansi: the mutants file holds no CR"
grep -q "$(printf '\033')" "$mfile" && fail "cr-ansi: the mutants file holds no ANSI"
grep -q "map failed" <<<"$OUT" && fail "cr-ansi: stripped lines map cleanly"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -qx "P2 src/a.rs:10:20: MISSED => needs-test: bounds check unpinned \\[mutants $mfile\\]" "$ffile" || fail "cr-ansi: the stripped needs-test line merges"

# --- shards all skipped hold no survivors and report no unread ---
setup_case shards-skipped-all
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
src/a.rs:10:20: MISSED
mutants in the diff: 1
EOF
cat >"$T/map-text" <<'EOF'
src/a.rs:10:20: MISSED => needs-test: bounds check unpinned
EOF
printf '1' >"$T/verdicts-rc"
printf 'mutant-verdicts: no mutants-* artifacts for run 101\n' >"$T/verdicts-err"
printf '{"jobs":[{"databaseId":201,"name":"Selection","conclusion":"success"},{"databaseId":301,"name":"Mutants (shard 1)","conclusion":"skipped"},{"databaseId":302,"name":"Mutants (shard 2)","conclusion":"skipped"}]}\n' >"$T/jobs-json"
printf '{"artifacts":[]}\n' >"$T/artifacts-json"
run_build
[ "$RC" -eq 1 ] || fail "shards-skipped-all exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=1 p3=0 mutants=1 findings=* log=*" "shards-skipped-all"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -q "mutant shards unread" "$ffile" && fail "shards-skipped-all: skipped shards report no unread"
grep -q "survived in CI" "$ffile" && fail "shards-skipped-all: skipped shards hold no survivors"

# --- fewer artifacts than non-skipped shards report N of M unread ---
setup_case shards-partial
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
src/a.rs:10:20: MISSED
mutants in the diff: 1
EOF
cat >"$T/map-text" <<'EOF'
src/a.rs:10:20: MISSED => needs-test: bounds check unpinned
EOF
printf 'src/a.rs:10:20: MISSED\tmissed\n' >"$T/verdicts"
printf '{"jobs":[{"databaseId":201,"name":"Selection","conclusion":"success"},{"databaseId":301,"name":"Mutants (shard 1)","conclusion":"success"},{"databaseId":302,"name":"Mutants (shard 2)","conclusion":"success"},{"databaseId":303,"name":"Mutants (shard 3)","conclusion":"success"}]}\n' >"$T/jobs-json"
printf '{"artifacts":[{"name":"mutants-a"},{"name":"mutants-b"}]}\n' >"$T/artifacts-json"
run_build
[ "$RC" -eq 1 ] || fail "shards-partial exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=1 p3=1 mutants=1 findings=* log=*" "shards-partial"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -Fxq "P3 mutant shards unread: run 101 head ${H:0:12}: only 2 of 3 shard artifacts present for run 101" "$ffile" || fail "shards-partial: the N of M count is reported unread"
grep -q "survived in CI" "$ffile" && fail "shards-partial: no survivor P2 without full artifacts"
grep -q "mutant shards unread" <<<"$OUT" || fail "shards-partial: the digest carries the unread note"

# --- paginated artifacts sum across pages: two pages of one artifact each
# count as two, so two of three expected shards still report unread ---
setup_case shards-paginated-partial
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
src/a.rs:10:20: MISSED
mutants in the diff: 1
EOF
cat >"$T/map-text" <<'EOF'
src/a.rs:10:20: MISSED => needs-test: bounds check unpinned
EOF
printf 'src/a.rs:10:20: MISSED\tmissed\n' >"$T/verdicts"
printf '{"jobs":[{"databaseId":201,"name":"Selection","conclusion":"success"},{"databaseId":301,"name":"Mutants (shard 1)","conclusion":"success"},{"databaseId":302,"name":"Mutants (shard 2)","conclusion":"success"},{"databaseId":303,"name":"Mutants (shard 3)","conclusion":"success"}]}\n' >"$T/jobs-json"
printf '{"artifacts":[{"name":"mutants-a"}]}\n{"artifacts":[{"name":"mutants-b"}]}\n' >"$T/artifacts-json"
run_build
[ "$RC" -eq 1 ] || fail "shards-paginated-partial exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=1 p3=1 mutants=1 findings=* log=*" "shards-paginated-partial"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -Fxq "P3 mutant shards unread: run 101 head ${H:0:12}: only 2 of 3 shard artifacts present for run 101" "$ffile" || fail "shards-paginated-partial: paginated pages sum to 2 of 3 unread"
grep -q "survived in CI" "$ffile" && fail "shards-paginated-partial: no survivor P2 without full artifacts"
grep -q "mutant shards unread" <<<"$OUT" || fail "shards-paginated-partial: the digest carries the unread note"

# --- a failed shard-jobs request reports unread with its cause and reads no survivors ---
setup_case shards-unread-jobsfail
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
src/a.rs:10:20: MISSED
mutants in the diff: 1
EOF
cat >"$T/map-text" <<'EOF'
src/a.rs:10:20: MISSED => needs-test: bounds check unpinned
EOF
printf 'src/a.rs:10:20: MISSED\tmissed\n' >"$T/verdicts"
printf '{"jobs":[{"databaseId":201,"name":"Selection","conclusion":"success"},{"databaseId":301,"name":"Mutants (shard 1)","conclusion":"success"},{"databaseId":302,"name":"Mutants (shard 2)","conclusion":"success"}]}\n' >"$T/jobs-json"
printf '{"artifacts":[{"name":"mutants-a"},{"name":"mutants-b"}]}\n' >"$T/artifacts-json"
touch "$T/jobs-fail"
printf 'gh: jobs blew up\nsecond line stays out\n' >"$T/jobs-err"
run_build
[ "$RC" -eq 1 ] || fail "shards-unread-jobsfail exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=1 p3=1 mutants=1 findings=* log=*" "shards-unread-jobsfail"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -Fxq "P3 mutant shards unread: run 101 head ${H:0:12}: gh: jobs blew up" "$ffile" || fail "shards-unread-jobsfail: the jobs cause is reported unread"
grep -q "second line stays out" "$ffile" && fail "shards-unread-jobsfail: only the first stderr line is kept"
grep -q "survived in CI" "$ffile" && fail "shards-unread-jobsfail: no survivor P2 without a jobs count"
grep -q "mutant shards unread" <<<"$OUT" || fail "shards-unread-jobsfail: the digest carries the unread note"

# --- a failed artifacts request reports unread with its cause and reads no survivors ---
setup_case shards-unread-artifactsfail
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
src/a.rs:10:20: MISSED
mutants in the diff: 1
EOF
cat >"$T/map-text" <<'EOF'
src/a.rs:10:20: MISSED => needs-test: bounds check unpinned
EOF
printf 'src/a.rs:10:20: MISSED\tmissed\n' >"$T/verdicts"
printf '{"jobs":[{"databaseId":201,"name":"Selection","conclusion":"success"},{"databaseId":301,"name":"Mutants (shard 1)","conclusion":"success"},{"databaseId":302,"name":"Mutants (shard 2)","conclusion":"success"}]}\n' >"$T/jobs-json"
printf '{"artifacts":[{"name":"mutants-a"},{"name":"mutants-b"}]}\n' >"$T/artifacts-json"
touch "$T/artifacts-fail"
printf 'gh: artifacts blew up\nsecond line stays out\n' >"$T/artifacts-err"
run_build
[ "$RC" -eq 1 ] || fail "shards-unread-artifactsfail exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=1 p3=1 mutants=1 findings=* log=*" "shards-unread-artifactsfail"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -Fxq "P3 mutant shards unread: run 101 head ${H:0:12}: gh: artifacts blew up" "$ffile" || fail "shards-unread-artifactsfail: the artifacts cause is reported unread"
grep -q "second line stays out" "$ffile" && fail "shards-unread-artifactsfail: only the first stderr line is kept"
grep -q "survived in CI" "$ffile" && fail "shards-unread-artifactsfail: no survivor P2 without an artifacts count"
grep -q "mutant shards unread" <<<"$OUT" || fail "shards-unread-artifactsfail: the digest carries the unread note"

# --- an unparsable shard-jobs count reports unread and reads no survivors ---
setup_case shards-unread-jobscount
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
src/a.rs:10:20: MISSED
mutants in the diff: 1
EOF
cat >"$T/map-text" <<'EOF'
src/a.rs:10:20: MISSED => needs-test: bounds check unpinned
EOF
printf 'src/a.rs:10:20: MISSED\tmissed\n' >"$T/verdicts"
printf '{"jobs":[{"databaseId":201,"name":"Selection","conclusion":"success"},{"databaseId":301,"name":"Mutants (shard 1)","conclusion":"success"},{"databaseId":302,"name":"Mutants (shard 2)","conclusion":"success"}]}\n' >"$T/jobs-json"
: >"$T/jobs-json2"
printf '{"artifacts":[{"name":"mutants-a"},{"name":"mutants-b"}]}\n' >"$T/artifacts-json"
run_build
[ "$RC" -eq 1 ] || fail "shards-unread-jobscount exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=1 p3=1 mutants=1 findings=* log=*" "shards-unread-jobscount"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -Fxq "P3 mutant shards unread: run 101 head ${H:0:12}: could not count shard jobs for run 101" "$ffile" || fail "shards-unread-jobscount: the jobs parse failure is reported unread"
grep -q "survived in CI" "$ffile" && fail "shards-unread-jobscount: no survivor P2 without a jobs count"
grep -q "mutant shards unread" <<<"$OUT" || fail "shards-unread-jobscount: the digest carries the unread note"

# --- an unparsable artifacts page reports unread and reads no survivors ---
setup_case shards-unread-artifactscount
printf 'mutant_job=%s\n' Selection >>"$S"
cat >"$T/mutant-log" <<'EOF'
src/a.rs:10:20: MISSED
mutants in the diff: 1
EOF
cat >"$T/map-text" <<'EOF'
src/a.rs:10:20: MISSED => needs-test: bounds check unpinned
EOF
printf 'src/a.rs:10:20: MISSED\tmissed\n' >"$T/verdicts"
printf '{"jobs":[{"databaseId":201,"name":"Selection","conclusion":"success"},{"databaseId":301,"name":"Mutants (shard 1)","conclusion":"success"},{"databaseId":302,"name":"Mutants (shard 2)","conclusion":"success"}]}\n' >"$T/jobs-json"
printf 'not json\n' >"$T/artifacts-json"
run_build
[ "$RC" -eq 1 ] || fail "shards-unread-artifactscount exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build CHANGES p1=0 p2=1 p3=1 mutants=1 findings=* log=*" "shards-unread-artifactscount"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
grep -Fq "P3 mutant shards unread: run 101 head ${H:0:12}: " "$ffile" || fail "shards-unread-artifactscount: the artifacts parse failure is reported unread"
grep -q "survived in CI" "$ffile" && fail "shards-unread-artifactscount: no survivor P2 without an artifacts count"
grep -q "mutant shards unread" <<<"$OUT" || fail "shards-unread-artifactscount: the digest carries the unread note"

# --- the stored verdict blocks a build before any job dispatch ---
setup_case verdict-lines
bash "$TKT_STATE" "$S" set plan_verdict lines || fail "seed LINES verdict"
run_build
[ "$RC" -eq 1 ] || fail "LINES verdict refusal exits 1 (rc=$RC)"
expect_verdict "TKT tkt-build VERDICT-REFUSED verdict=lines log=*" "LINES verdict refusal"
grep -q '^job|' "$T/calls.log" && fail "LINES verdict refusal dispatches no tkt-job"
expect_state plan_verdict lines "LINES verdict refusal"
expect_state plan_verdict_base "$H" "LINES verdict refusal"

# --- PLAN OK and the fast-path skipped verdict both permit the build ---
setup_case verdict-ok
run_build
[ "$RC" -eq 0 ] || fail "PLAN OK verdict proceeds (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "PLAN OK verdict proceeds"
setup_case verdict-skipped
bash "$TKT_STATE" "$S" set plan_verdict skipped || fail "seed skipped verdict"
run_build
[ "$RC" -eq 0 ] || fail "skipped verdict proceeds (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "skipped verdict proceeds"
setup_case verdict-triaged
bash "$TKT_STATE" "$S" set plan_verdict triaged || fail "seed triaged verdict"
run_build
[ "$RC" -eq 0 ] || fail "triaged verdict proceeds (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "triaged verdict proceeds"

# --- a missing verdict refuses; --no-verifier records or refreshes skipped ---
setup_case verdict-none
bash "$TKT_STATE" "$S" set plan_verdict "" || fail "clear plan verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base "" || fail "clear plan verdict base"
run_build
[ "$RC" -eq 1 ] || fail "missing verdict refusal exits 1"
expect_verdict "TKT tkt-build VERDICT-REFUSED verdict=none log=*" "missing verdict refusal"
grep -q '^job|' "$T/calls.log" && fail "missing verdict refusal dispatches no tkt-job"
setup_case verdict-no-verifier
bash "$TKT_STATE" "$S" set plan_verdict "" || fail "clear no-verifier verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base "" || fail "clear no-verifier verdict base"
run_build --no-verifier
[ "$RC" -eq 0 ] || fail "--no-verifier with an empty verdict proceeds (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "--no-verifier with an empty verdict"
expect_state plan_verdict skipped "--no-verifier stores skipped"
expect_state plan_verdict_base "$H" "--no-verifier stores the base"
setup_case verdict-no-verifier-lines
bash "$TKT_STATE" "$S" set plan_verdict lines || fail "seed no-verifier LINES verdict"
run_build --no-verifier
[ "$RC" -eq 1 ] || fail "--no-verifier cannot replace LINES"
expect_verdict "TKT tkt-build VERDICT-REFUSED verdict=lines log=*" "--no-verifier preserves LINES"
grep -q '^job|' "$T/calls.log" && fail "--no-verifier over LINES dispatches no tkt-job"
expect_state plan_verdict lines "--no-verifier preserves stored verdict"
expect_state plan_verdict_base "$H" "--no-verifier preserves rejection base"

# --- changing the plan text invalidates LINES; --no-verifier can then build ---
setup_case verdict-no-verifier-edited-lines
bash "$TKT_STATE" "$S" set plan_verdict lines || fail "seed edited-plan LINES verdict"
bash "$TKT_STATE" "$S" set plan_verdict_hash "$(git hash-object "$CDIR/plan.md")" || fail "seed edited-plan verdict hash"
awk '/^## Gate$/ { print "All plan lines are closed."; print "" } { print }' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
run_build --no-verifier
[ "$RC" -eq 0 ] || fail "--no-verifier replaces an edited-plan LINES verdict (rc=$RC): $(first_line) $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "edited-plan --no-verifier build"
expect_state plan_verdict skipped "edited-plan --no-verifier stores skipped"
expect_state plan_verdict_hash "$(git hash-object "$CDIR/plan.md")" "edited-plan --no-verifier stores current hash"

# --- accepted verdicts require the exact current plan base ---
setup_case verdict-stale
bash "$TKT_STATE" "$S" set plan_verdict_base 0000000000000000000000000000000000000000 || fail "seed mismatched verdict base"
run_build
[ "$RC" -eq 1 ] || fail "mismatched verdict base exits 1"
expect_verdict "TKT tkt-build VERDICT-REFUSED verdict=stale log=*" "mismatched verdict base"
grep -q '^job|' "$T/calls.log" && fail "stale verdict dispatches no tkt-job"
setup_case verdict-triaged-stale
bash "$TKT_STATE" "$S" set plan_verdict triaged || fail "seed triaged stale verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base 0000000000000000000000000000000000000000 || fail "seed mismatched triaged base"
run_build
[ "$RC" -eq 1 ] || fail "triaged verdict at a changed Base exits 1"
expect_verdict "TKT tkt-build VERDICT-REFUSED verdict=stale log=*" "triaged verdict at a changed Base"
grep -q '^job|' "$T/calls.log" && fail "stale triaged verdict dispatches no tkt-job"
setup_case verdict-stale-flag
bash "$TKT_STATE" "$S" set plan_verdict_base 0000000000000000000000000000000000000000 || fail "seed flagged mismatched verdict base"
run_build --no-verifier
[ "$RC" -eq 1 ] || fail "--no-verifier does not replace a stale pair"
expect_verdict "TKT tkt-build VERDICT-REFUSED verdict=stale log=*" "--no-verifier with stale verdict"
expect_state plan_verdict ok "--no-verifier preserves stale verdict"
expect_state plan_verdict_base 0000000000000000000000000000000000000000 "--no-verifier preserves stale verdict base"

# --- verdict-ok-ancestor-unchanged: a descendant Base with no Files diff proceeds ---
setup_case verdict-ok-ancestor-unchanged
git -C "$WT" commit --allow-empty -qm unrelated
advance_build_head
set_plan_base "$H"
run_build
[ "$RC" -eq 0 ] || fail "ancestor-unchanged: descendant base with unchanged Files proceeds (rc=$RC): $(first_line) $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "ancestor-unchanged"
grep -q '^job|' "$T/calls.log" || fail "ancestor-unchanged: build dispatches tkt-job"

# --- verdict-ok-ancestor-files-changed: a changed Files path on a descendant Base is stale ---
setup_case verdict-ok-ancestor-files-changed
printf 'changed\n' >"$WT/src/a.txt"
git -C "$WT" add src/a.txt
git -C "$WT" commit -qm changed-file
advance_build_head
set_plan_base "$H"
run_build
[ "$RC" -eq 1 ] || fail "ancestor-files-changed: changed Files path is refused"
expect_verdict "TKT tkt-build VERDICT-REFUSED verdict=stale log=*" "ancestor-files-changed"
grep -q '^job|' "$T/calls.log" && fail "ancestor-files-changed: stale verdict dispatches no tkt-job"

# --- verdict-ok-sibling-base: a sibling current Base is stale ---
setup_case verdict-ok-sibling-base
git -C "$WT" checkout -q --detach "$(cat "$CDIR/main0")"
printf 'sibling\n' >"$WT/sibling.txt"
git -C "$WT" add sibling.txt
git -C "$WT" commit -qm sibling
current_base="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" checkout -q "$H"
set_plan_base "$current_base"
run_build
[ "$RC" -eq 1 ] || fail "sibling-base: non-descendant base is refused"
expect_verdict "TKT tkt-build VERDICT-REFUSED verdict=stale log=*" "sibling-base"
grep -q '^job|' "$T/calls.log" && fail "sibling-base: stale verdict dispatches no tkt-job"

# --- a skipped verdict at an old base stays stale without the flag ---
setup_case verdict-skipped-stale-no-flag
old_base="$(cat "$CDIR/main0")"
bash "$TKT_STATE" "$S" set plan_verdict skipped || fail "seed old skipped verdict without flag"
bash "$TKT_STATE" "$S" set plan_verdict_base "$old_base" || fail "seed old skipped base without flag"
run_build
[ "$RC" -eq 1 ] || fail "skipped verdict at an old base refuses without --no-verifier"
expect_verdict "TKT tkt-build VERDICT-REFUSED verdict=stale log=*" "old skipped verdict without flag"
expect_state plan_verdict skipped "old skipped verdict without flag"
expect_state plan_verdict_base "$old_base" "old skipped base without flag"

# --- the verdict check runs before either --from lane split ---
setup_case verdict-from-gate
bash "$TKT_STATE" "$S" set plan_verdict lines || fail "seed --from gate LINES"
run_build --from gate
[ "$RC" -eq 1 ] || fail "--from gate verdict refusal exits 1"
expect_verdict "TKT tkt-build VERDICT-REFUSED verdict=lines log=*" "--from gate verdict refusal"
grep -q '^job|' "$T/calls.log" && fail "--from gate refusal dispatches no tkt-job"
setup_case verdict-from-review
bash "$TKT_STATE" "$S" set pr 7 || fail "seed review PR"
bash "$TKT_STATE" "$S" set head "$H" || fail "seed review head"
bash "$TKT_STATE" "$S" set plan_verdict lines || fail "seed --from review LINES"
run_build --from review
[ "$RC" -eq 1 ] || fail "--from review verdict refusal exits 1"
expect_verdict "TKT tkt-build VERDICT-REFUSED verdict=lines log=*" "--from review verdict refusal"
grep -q '^job|' "$T/calls.log" && fail "--from review refusal dispatches no tkt-job"

# --- --no-verifier refreshes a stored skipped verdict at the current base ---
setup_case verdict-skipped-stale-flag
old_base="$(cat "$CDIR/main0")"
bash "$TKT_STATE" "$S" set plan_verdict skipped || fail "seed old skipped verdict with flag"
bash "$TKT_STATE" "$S" set plan_verdict_base "$old_base" || fail "seed old skipped base with flag"
run_build --no-verifier
[ "$RC" -eq 0 ] || fail "--no-verifier refreshes an old skipped verdict (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "old skipped verdict with flag"
expect_state plan_verdict skipped "old skipped verdict with flag"
expect_state plan_verdict_base "$H" "old skipped base refreshes with flag"

# --- a plan with Outcome: measurement runs the gate, skips the PR, review
# and CI steps, and ends MEASURED with exit 0 and no gh pr list call ---
setup_case measured
{
  printf 'Base: %s\nOutcome: measurement\n' "$H"
  printf '\n## Files\n\n- `src/a.txt`\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
run_build
[ "$RC" -eq 0 ] || fail "measured exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build MEASURED* log=*" "measured"
grep -q "pr list" "$T/calls.log" && fail "measured: no gh pr list call"
grep -q "^gate|" "$T/calls.log" || fail "measured: the gate still runs"
grep -q "^review-start|" "$T/calls.log" && fail "measured: review never starts"
grep -q "^review-collect|" "$T/calls.log" && fail "measured: reviews never collect"
grep -q "prompt=.*-map-" "$T/calls.log" && fail "measured: no map job dispatches"
grep -q "^ghci|" "$T/calls.log" && fail "measured: no CI wait runs"
expect_state reviewed "$H" measured
expect_state round 0 measured
grep -q "tkt-build MEASURED" "$CDIR/tkt.journal" || fail "measured: the verdict is journaled"

# --- a plan without the Outcome line still needs a PR when none exists ---
setup_case outcome-default
touch "$T/empty-pr"
run_build
[ "$RC" -eq 2 ] || fail "outcome-default exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION missing=pr log=*" "outcome-default"
grep -q "^gate|" "$T/calls.log" && fail "outcome-default: the gate never runs"

# --- a measurement plan with a stored head and no PR still ends MEASURED ---
setup_case measured-stored-head
{
  printf 'Base: %s\nOutcome: measurement\n' "$H"
  printf '\n## Files\n\n- `src/a.txt`\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
bash "$TKT_STATE" "$S" set head "$H" || fail "seed stored head"
touch "$T/empty-pr"
run_build
[ "$RC" -eq 0 ] || fail "measured stored head exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build MEASURED* log=*" "measured stored head"
grep -q "pr list" "$T/calls.log" && fail "measured stored head: no gh pr list call"
grep -q "^gate|" "$T/calls.log" || fail "measured stored head: the gate still runs"

# --- a measurement plan with --from review still runs the gate ---
setup_case measured-from-review
{
  printf 'Base: %s\nOutcome: measurement\n' "$H"
  printf '\n## Files\n\n- `src/a.txt`\n\n## Gate\n\n`false`\n'
} >"$CDIR/plan.md"
run_build --from review
[ "$RC" -eq 1 ] || fail "measured from-review with a failing gate exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build FAIL rc=1 log=*" "measured from-review gate"
grep -q "^gate|" "$T/calls.log" || fail "measured from-review: the gate still runs"

# --- round-0 findings use the repo tail as the ticket stem ---
setup_case owner-qualified-findings
bash "$TKT_STATE" "$S" set repo owner/name || fail "owner-qualified-findings: set repo"
run_build
[ "$RC" -eq 0 ] || fail "owner-qualified-findings exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
[ "$ffile" = "$CDIR/run/name-528-findings-r0.md" ] || fail "owner-qualified-findings: findings key is [$ffile]"
[ -f "$ffile" ] || fail "owner-qualified-findings: findings file missing"

# --- part 2 writes -part2- findings and leaves the part-1 file byte-identical ---
setup_case part2-findings
bash "$TKT_STATE" "$S" set part 2 || fail "part2-findings: set part"
printf 'PART1-FINDINGS\n' >"$CDIR/run/switchyard-528-findings-r0.md"
cp "$CDIR/run/switchyard-528-findings-r0.md" "$T/part1-copy.md"
run_build
[ "$RC" -eq 0 ] || fail "part2-findings exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "part2-findings"
ffile="$(bash "$TKT_STATE" "$S" get findings)"
[ "$ffile" = "$CDIR/run/switchyard-528-part2-findings-r0.md" ] || fail "part2-findings: findings key is [$ffile]"
[ -f "$ffile" ] || fail "part2-findings: part2 findings file missing"
cmp -s "$CDIR/run/switchyard-528-findings-r0.md" "$T/part1-copy.md" || fail "part2-findings: part-1 findings file changed"

# --- findings-overwrite guard: an existing destination the state did not
# write is refused with exit 2 and left byte-identical, before collect runs ---
setup_case findings-refuse
printf 'UNRELATED-CONTENT\n' >"$CDIR/run/switchyard-528-findings-r0.md"
cp "$CDIR/run/switchyard-528-findings-r0.md" "$T/findings-refuse-copy.md"
run_build
[ "$RC" -eq 2 ] || fail "findings-refuse exits 2 (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -F -q "tkt-build: refusing to overwrite $CDIR/run/switchyard-528-findings-r0.md: switchyard-528-findings-r0.md names are reserved for this ticket's own findings output; write hand-kept notes to switchyard-528-dispositions-r0.md instead" "$CDIR/stderr.txt" || fail "findings-refuse stderr missing refusal: $(cat "$CDIR/stderr.txt")"
cmp -s "$CDIR/run/switchyard-528-findings-r0.md" "$T/findings-refuse-copy.md" || fail "findings-refuse: existing file changed"
grep -q "^review-collect|" "$T/calls.log" && fail "findings-refuse: collect ran despite refusal"

# --- findings-rerun: a destination the state recorded is rewritten ---
setup_case findings-rerun
printf 'STALE\n' >"$CDIR/run/switchyard-528-findings-r0.md"
bash "$TKT_STATE" "$S" set findings "$CDIR/run/switchyard-528-findings-r0.md" || fail "findings-rerun: set findings"
bash "$TKT_STATE" "$S" journal "findings write $CDIR/run/switchyard-528-findings-r0.md" || fail "findings-rerun: journal"
run_build
[ "$RC" -eq 0 ] || fail "findings-rerun exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -q "STALE" "$CDIR/run/switchyard-528-findings-r0.md" && fail "findings-rerun: stale content remains"
grep -q "no open findings" "$CDIR/run/switchyard-528-findings-r0.md" || fail "findings-rerun: file not rewritten"

# --- findings-failed-collect: a collect that exits early without writing
# journals no ownership, so unrelated content later at the destination is refused ---
setup_case findings-failed-collect
touch "$T/collect-nowrite"
printf '1' >"$T/collect-rc"
cat >"$T/collect-out" <<'EOF'
patch-id deadbeef
RUNNING standards r1: wait with delegate watch r1 r2 r3
RUNNING spec r2: wait with delegate watch r1 r2 r3
RUNNING overbuild r3: wait with delegate watch r1 r2 r3
CI deadbeef pending
EOF
run_build
[ "$RC" -eq 1 ] || fail "findings-failed-collect exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build REVIEW-INCOMPLETE log=*" "findings-failed-collect"
[ ! -e "$CDIR/run/switchyard-528-findings-r0.md" ] || fail "findings-failed-collect: no findings file after a collect that wrote nothing"
[ -f "$CDIR/tkt.journal" ] && grep -q "findings write" "$CDIR/tkt.journal" && fail "findings-failed-collect: no findings write journal after a collect that wrote nothing"
rm -f "$T/collect-nowrite"
printf 'UNRELATED-CONTENT\n' >"$CDIR/run/switchyard-528-findings-r0.md"
cp "$CDIR/run/switchyard-528-findings-r0.md" "$T/findings-failed-collect-copy.md"
run_build
[ "$RC" -eq 2 ] || fail "findings-failed-collect rerun exits 2 (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -F -q "tkt-build: refusing to overwrite $CDIR/run/switchyard-528-findings-r0.md: switchyard-528-findings-r0.md names are reserved for this ticket's own findings output; write hand-kept notes to switchyard-528-dispositions-r0.md instead" "$CDIR/stderr.txt" || fail "findings-failed-collect rerun stderr missing refusal: $(cat "$CDIR/stderr.txt")"
cmp -s "$CDIR/run/switchyard-528-findings-r0.md" "$T/findings-failed-collect-copy.md" || fail "findings-failed-collect rerun: existing file changed"

# --- --from gate with main moved on a planned file but a clean merge continues ---
setup_case gate-clean-merge
printf 'main change\n' >"$CDIR/seed/base.txt"
git -C "$CDIR/seed" add base.txt
git -C "$CDIR/seed" -c user.email=t@t -c user.name=t commit -qm "main moves base"
git -C "$CDIR/seed" push -q origin main
git -C "$WT" fetch -q origin
{
  printf 'Base: %s\n' "$(cat "$CDIR/main0")"
  printf '\n## Files\n\n- `src/a.txt`\n- `base.txt`\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
bash "$TKT_STATE" "$S" set plan_verdict_base "$(cat "$CDIR/main0")" || fail "gate-clean-merge: seed matching verdict base"
run_build --from gate
[ "$RC" -eq 0 ] || fail "gate-clean-merge exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "gate-clean-merge"
grep -F -q "tkt-build: plan Base $(cat "$CDIR/main0") is behind origin/main on 1 planned files; the branch merges cleanly, continuing" "$CDIR/stderr.txt" || fail "gate-clean-merge: clean-merge stderr line missing: $(cat "$CDIR/stderr.txt")"

# --- --from gate with a conflicting move still exits STALE with the rerun line ---
setup_case gate-conflict
mkdir -p "$CDIR/seed/src"
printf 'main change\n' >"$CDIR/seed/src/a.txt"
git -C "$CDIR/seed" add src/a.txt
git -C "$CDIR/seed" -c user.email=t@t -c user.name=t commit -qm "main moves"
git -C "$CDIR/seed" push -q origin main
git -C "$WT" fetch -q origin
{
  printf 'Base: %s\n' "$(cat "$CDIR/main0")"
  printf '\n## Files\n\n- `src/a.txt`\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
bash "$TKT_STATE" "$S" set plan_verdict_base "$(cat "$CDIR/main0")" || fail "gate-conflict: seed matching verdict base"
run_build --from gate
[ "$RC" -eq 1 ] || fail "gate-conflict exits 1 (rc=$RC)"
expect_verdict "TKT tkt-build STALE n=1 base=* log=*" "gate-conflict"
grep -F -q "1. git -C $WT rebase origin/main" <<<"$OUT" || fail "gate-conflict: step 1 rebases the worktree: $OUT"
grep -F -q "2. git -C $WT push --force-with-lease origin tkt-528" <<<"$OUT" || fail "gate-conflict: step 2 pushes the rebased branch: $OUT"
grep -F -q "3. set the Base: line in $CDIR/plan.md to Base: $(git -C "$WT" rev-parse origin/main)" <<<"$OUT" || fail "gate-conflict: step 3 names the plan Base edit with the new sha: $OUT"
grep -F -q "4. tkt-plan $S verify" <<<"$OUT" || fail "gate-conflict: step 4 re-verifies the plan: $OUT"
grep -F -q "5. tkt-build $S --from gate" <<<"$OUT" || fail "gate-conflict: step 5 reruns the build: $OUT"
grep -F -q "tkt-state $S set head" <<<"$OUT" && fail "gate-conflict: no stored head, so no head step: $OUT"
grep -q "^gate|" "$T/calls.log" && fail "gate-conflict: the gate never runs"

# --- a conflicting STALE prints numbered recovery steps that reach APPROVE ---
# The digest's numbered commands run in order with the harness stubs (the
# Verifier returns PLAN OK): rebase, the Base edit it names, the stored-head
# refresh, a fresh verify, and the rerun. Step 2 is the file edit the digest
# names, applied here the way a follower of the hint applies it.
setup_case gate-conflict-recover
mkdir -p "$CDIR/seed/src"
printf 'main change\n' >"$CDIR/seed/src/a.txt"
git -C "$CDIR/seed" add src/a.txt
git -C "$CDIR/seed" -c user.email=t@t -c user.name=t commit -qm "main moves"
git -C "$CDIR/seed" push -q origin main
git -C "$WT" fetch -q origin
{
  printf 'Base: %s\n' "$(cat "$CDIR/main0")"
  printf '\n## Files\n\n- `src/a.txt`\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
bash "$TKT_STATE" "$S" set plan_verdict_base "$(cat "$CDIR/main0")" || fail "gate-conflict-recover: seed matching verdict base"
bash "$TKT_STATE" "$S" set pr 7 || fail "gate-conflict-recover: set pr"
bash "$TKT_STATE" "$S" set head "$H" || fail "gate-conflict-recover: set head"
run_build --from gate
[ "$RC" -eq 1 ] || fail "gate-conflict-recover exits 1 (rc=$RC)"
expect_verdict "TKT tkt-build STALE n=1 base=* log=*" "gate-conflict-recover"
grep -F -q "1. git -C $WT rebase origin/main" <<<"$OUT" || fail "gate-conflict-recover: step 1 rebases the worktree: $OUT"
grep -F -q "2. git -C $WT push --force-with-lease origin tkt-528" <<<"$OUT" || fail "gate-conflict-recover: step 2 pushes the rebased branch: $OUT"
grep -F -q "3. set the Base: line in $CDIR/plan.md to Base: " <<<"$OUT" || fail "gate-conflict-recover: step 3 names the plan Base edit: $OUT"
grep -F -q "4. tkt-state $S set head <new-head-sha>" <<<"$OUT" || fail "gate-conflict-recover: step 4 refreshes the stored head: $OUT"
grep -F -q "5. tkt-plan $S verify" <<<"$OUT" || fail "gate-conflict-recover: step 5 re-verifies the plan: $OUT"
grep -F -q "then run git -C $WT rebase --continue before step 2" <<<"$OUT" || fail "gate-conflict-recover: the continue step targets the worktree: $OUT"
grep -F -q "6. tkt-build $S --from gate" <<<"$OUT" || fail "gate-conflict-recover: step 6 reruns the build: $OUT"
git -C "$WT" rebase origin/main >/dev/null 2>&1 || true
printf 'resolved\n' >"$WT/src/a.txt"
git -C "$WT" add src/a.txt
GIT_EDITOR=true git -C "$WT" rebase --continue || fail "gate-conflict-recover: rebase --continue"
H2="$(git -C "$WT" rev-parse HEAD)"
printf '%s' "$H2" >"$T/prhead"
git -C "$WT" push -q --force-with-lease origin tkt-528 || fail "gate-conflict-recover: step 2 pushes the rebased branch"
newbase="$(git -C "$WT" rev-parse origin/main)"
grep -F -q "3. set the Base: line in $CDIR/plan.md to Base: $newbase" <<<"$OUT" || fail "gate-conflict-recover: step 3 fills in the new origin/main sha: $OUT"
{ printf 'Base: %s\n' "$newbase"; tail -n +2 "$CDIR/plan.md"; } >"$CDIR/plan.tmp"
mv "$CDIR/plan.tmp" "$CDIR/plan.md"
bash "$TKT_STATE" "$S" set head "$H2" || fail "gate-conflict-recover: step 4 sets the rebased head"
cp "$SCRIPT_DIR/../skills/planning/briefs/verifier.md" "$T/home/.agents/skills/planning/briefs/verifier.md" || fail "gate-conflict-recover: install the verifier brief"
printf 'pack\n' >"$CDIR/pack.md"
bash "$TKT_STATE" "$S" set pack "$CDIR/pack.md" || fail "gate-conflict-recover: set pack"
bash "$TKT_STATE" "$S" set model.verifier vm || fail "gate-conflict-recover: set model.verifier"
ln -sf "$REAL_BIN/plan-check" "$T/bin/plan-check" || fail "gate-conflict-recover: link plan-check"
printf 'verify-ok' >"$T/delegate-mode"
bash "$SCRIPT_DIR/../bin/tkt-plan" "$S" verify >"$CDIR/verify-out.txt" 2>"$CDIR/verify-stderr.txt" || fail "gate-conflict-recover: step 4 verify: $(cat "$CDIR/verify-stderr.txt")"
printf 'done' >"$T/delegate-mode"
grep -q "^TKT tkt-plan PLAN-OK " "$CDIR/verify-out.txt" || fail "gate-conflict-recover: verify records PLAN-OK: $(cat "$CDIR/verify-out.txt")"
run_build --from gate
[ "$RC" -eq 0 ] || fail "gate-conflict-recover rerun exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H2 findings=* log=*" "gate-conflict-recover rerun"

# --- --from lane with the same clean move still exits STALE ---
setup_case lane-clean-stale
printf 'main change\n' >"$CDIR/seed/base.txt"
git -C "$CDIR/seed" add base.txt
git -C "$CDIR/seed" -c user.email=t@t -c user.name=t commit -qm "main moves base"
git -C "$CDIR/seed" push -q origin main
git -C "$WT" fetch -q origin
{
  printf 'Base: %s\n' "$(cat "$CDIR/main0")"
  printf '\n## Files\n\n- `src/a.txt`\n- `base.txt`\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
bash "$TKT_STATE" "$S" set plan_verdict_base "$(cat "$CDIR/main0")" || fail "lane-clean-stale: seed matching verdict base"
run_build
[ "$RC" -eq 1 ] || fail "lane-clean-stale exits 1 (rc=$RC)"
expect_verdict "TKT tkt-build STALE n=1 base=* log=*" "lane-clean-stale"
grep -q "merges cleanly" "$CDIR/stderr.txt" && fail "lane-clean-stale: lane must not continue cleanly"
grep -q "merges cleanly" <<<"$OUT" && fail "lane-clean-stale: lane must not continue cleanly"
grep -q "^run|" "$T/calls.log" && fail "lane-clean-stale: the lane never dispatches"

echo "tkt-build: all cases passed"

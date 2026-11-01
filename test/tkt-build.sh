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
[ -x "$REAL_BIN/plan-gate" ] || fail "real plan-gate missing"

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
# to --findings-out, prints $T/collect-out and exits $T/collect-rc.
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
  cp "$T/findings-src" "\$out"
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

# New case: a bare origin, a seed main, and a clone worktree on branch tkt-528
# with one pushed commit covered by the plan's Files. Sets CDIR, WT, S and H.
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
  git -C "$CDIR/seed" rev-parse HEAD >"$CDIR/main0"
  WT="$CDIR/wt"
  git clone -q "$CDIR/origin.git" "$WT"
  git -C "$WT" config user.email t@t
  git -C "$WT" config user.name t
  git -C "$WT" checkout -qb tkt-528
  mkdir -p "$WT/src"
  printf 'a\n' >"$WT/src/a.txt"
  git -C "$WT" add src/a.txt
  git -C "$WT" commit -qm change
  git -C "$WT" push -q origin tkt-528
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
    printf 'model.lane=%s\n' lane-m
    printf 'model.review=%s\n' rm
    printf 'model.overbuild=%s\n' om
    printf 'model.map=%s\n' mm
    printf 'extra=%s\n' "$CDIR/extra.md"
    printf 'body_has=%s\n' 'Resolves #528' 'Co-authored with Test <t@t>'
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
  rm -f "$T/empty-pr" "$T/no-runs" "$T/noview" "$T/ghci-err" "$T/verdicts-err" "$T/jobs-json" "$T/jobs-json2" "$T/jobs-first-done" "$T/jobs-fail" "$T/jobs-err" "$T/artifacts-fail" "$T/artifacts-err" "$T/log-fail" "$T/log-err"
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
run_build --lane-model lm --review-model rrm --overbuild-model oom
[ "$RC" -eq 0 ] || fail "happy exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "happy"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -le 41 ] || fail "happy: over 40 digest lines"
grep -q "^job|.*--slot lane.*--template .*lane.md.*--gate-from-plan.*--expect-commits" "$T/calls.log" || fail "happy: lane runs through tkt-job"
grep -q '^concerns=' <<<"$OUT" && fail "happy: no empty concerns digest line"
grep -q "BASE=$H" "$T/calls.log" || fail "happy: BASE reaches the lane"
grep -q "GATE=true" "$T/calls.log" || fail "happy: GATE reaches the lane"
grep -q "CLOSING=Resolves #528" "$T/calls.log" || fail "happy: CLOSING reaches the lane"
grep -q "ATTRIBUTION=Co-authored with Test" "$T/calls.log" || fail "happy: ATTRIBUTION reaches the lane"
grep -q "^run|id=stub-1|model=lm|prompt=.*-lane-1.md$" "$T/calls.log" || fail "happy: --lane-model wins"
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
[ -f "$(bash "$TKT_STATE" "$S" get findings)" ] || fail "happy: findings file exists"
expect_state round 0 happy
grep -q "tkt-build APPROVE" "$CDIR/tkt.journal" || fail "happy: the verdict is journaled"
logpath="${OUT%%$'\n'*}"; logpath="${logpath##*log=}"
[ -f "$logpath" ] || fail "happy: the run log exists"

# --- body_ends wins over body_has for the lane ATTRIBUTION ---
setup_case attr-ends
bash "$TKT_STATE" "$S" set body_has 'Resolves #528' || fail "attr-ends: set body_has"
bash "$TKT_STATE" "$S" set body_ends 'Co-authored with Ends' || fail "attr-ends: set body_ends"
run_build --lane-model lm --review-model rrm --overbuild-model oom
[ "$RC" -eq 0 ] || fail "attr-ends exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -q "ATTRIBUTION=Co-authored with Ends" "$T/calls.log" || fail "attr-ends: ATTRIBUTION reaches the lane"

# --- with no body_ends, a body_has co-author reaches the lane ---
setup_case attr-body
bash "$TKT_STATE" "$S" set body_has 'Co-authored with Body' || fail "attr-body: set body_has"
run_build --lane-model lm --review-model rrm --overbuild-model oom
[ "$RC" -eq 0 ] || fail "attr-body exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -q "ATTRIBUTION=Co-authored with Body" "$T/calls.log" || fail "attr-body: ATTRIBUTION reaches the lane"

# --- when both keys are set, body_ends wins ---
setup_case attr-both
bash "$TKT_STATE" "$S" set body_has 'Co-authored with Body' || fail "attr-both: set body_has"
bash "$TKT_STATE" "$S" set body_ends 'Co-authored with Ends' || fail "attr-both: set body_ends"
run_build --lane-model lm --review-model rrm --overbuild-model oom
[ "$RC" -eq 0 ] || fail "attr-both exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -q "ATTRIBUTION=Co-authored with Ends" "$T/calls.log" || fail "attr-both: ATTRIBUTION reaches the lane"

# --- with neither key, the ATTRIBUTION slot stays empty ---
setup_case attr-empty
bash "$TKT_STATE" "$S" set body_has 'Resolves #528' || fail "attr-empty: set body_has"
run_build --lane-model lm --review-model rrm --overbuild-model oom
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
grep -q "^run|id=stub-1|model=lane-m|" "$T/calls.log" || fail "mutants: the lane defaults to model.lane"
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
grep -q "^run|id=stub-1|model=lane-m|" "$T/calls.log" || fail "lane-model: the lane runs on model.lane"
brief="$(grep '^run|' "$T/calls.log" | sed 's/.*prompt=//')"
case "$brief" in "$CDIR/run/"*) ;; *) fail "lane-model: the brief is written under \$CDIR/run";; esac
impl="$(grep '^Implemented by:' "$brief")"
[ "$impl" = "Implemented by: lane-m" ] || fail "lane-model: the brief holds [$impl]"
case "$impl" in *unknown*) fail "lane-model: the Implemented by line never holds unknown";; esac

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

# --- a stale plan stops the build before the lane ---
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
run_build
[ "$RC" -eq 1 ] || fail "stale exits 1 (rc=$RC)"
expect_verdict "TKT tkt-build STALE n=1 base=* log=*" "stale"
grep -q "src/a.txt" <<<"$OUT" || fail "stale: the digest names the changed file"
grep -q "^run|" "$T/calls.log" && fail "stale: the lane never dispatches"

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
run_build
[ "$RC" -eq 0 ] || fail "basetick exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "basetick"

# --- a spec file path in state never reaches review-pr; review reads --issue ---
setup_case spec-path
printf 'ticket body\n' >"$CDIR/spec.md"
bash "$TKT_STATE" "$S" set spec "$CDIR/spec.md" || fail "spec-path: set spec"
run_build --lane-model lm --review-model rrm --overbuild-model oom
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
run_build --lane-model lm --review-model rrm --overbuild-model oom
[ "$RC" -eq 0 ] || fail "spec-issue exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-build APPROVE pr=7 head=$H findings=* log=*" "spec-issue"
[ "$(grep -c '^review-start|' "$T/calls.log")" -eq 3 ] || fail "spec-issue: one start per axis"
[ "$(grep -c -- '--spec 445' "$T/calls.log")" -eq 3 ] || fail "spec-issue: all review starts carry --spec 445"
grep -qF -- "$CDIR/spec.md" "$T/calls.log" && fail "spec-issue: spec path reaches no review-pr call"

# --- an unset spec_issue and spec key add no --spec argument ---
setup_case no-spec-issue
run_build --lane-model lm --review-model rrm --overbuild-model oom
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

# --- --from review without pr and head names the missing key ---
setup_case review-missing-pr
run_build --from review
[ "$RC" -eq 2 ] || fail "review-missing-pr exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION missing=pr log=*" "review-missing-pr"

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

# --- a state with round already set is refused before any job or gate ---
setup_case round-set
bash "$TKT_STATE" "$S" set round 1 >/dev/null || fail "seed round"
run_build
[ "$RC" -eq 1 ] || fail "round-set build exits 1 (rc=$RC)"
expect_verdict "TKT tkt-build ROUND-LIMIT round=1 log=*" "round-set build"
grep -q "continue with tkt-fix or tkt-ship" <<<"$OUT" || fail "round-set build names tkt-fix and tkt-ship"
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

echo "tkt-build: all cases passed"

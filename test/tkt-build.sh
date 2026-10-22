#!/usr/bin/env bash
# Tests for bin/tkt-build: lane, gate, mutant list, review beside the map job,
# one merged findings file. Stubs on a temp TKT_BIN: delegate (mints DONE/ASK
# records), gh (pr list/view, run list/view), gh-ci (wait) and review-pr
# (canned start/collect). Real tkt-job and tkt-gate run behind logging
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

# Stub delegate: run mints a DONE record at once (lane carries one commit for
# --expect-commits; map carries $T/map-text); ask modes mint NEEDS_CONTEXT.
# Watch only logs: every record already exists, so one watch covers all ids.
printf '0' >"$T/dcounter"
printf '0' >"$T/rcounter"
cat >"$T/bin/delegate" <<EOF
#!/usr/bin/env bash
set -uo pipefail
jobsdir="\${TMPDIR:-/tmp}/delegate-jobs"
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
    if [ "\$slot" = "map" ]; then
      text="\$(cat "$T/map-text")"
      commits='[]'
    else
      text="lane done
STATUS: DONE"
    fi
    if { [ "\$mode" = "ask-lane" ] && [ "\$slot" = "lane" ]; } || { [ "\$mode" = "ask-map" ] && [ "\$slot" = "map" ]; }; then
      status="NEEDS_CONTEXT"
      text="\$(cat "$T/ask-text")"
      commits='[]'
    fi
    mkdir -p "\$jobsdir"
    jq -n --arg status "\$status" --arg text "\$text" --argjson commits "\$commits" \
      '{status: \$status, result: {status: \$status, text: \$text, gateResult: {passed: true, command: "true", exitCode: 0, outputTail: "ok", outputPath: "/tmp/g.log"}, changeSet: {headBefore: "a", headAfter: "b", newCommits: \$commits, uncommittedFiles: [], filesChanged: [], diffstat: "", dirtyAfter: false}, concerns: null}, supervisorPid: 1}' \
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
# the job log from $T/mutant-log.
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
  *" --job "*)
    cat "$T/mutant-log"
    ;;
  *" --json jobs "*)
    printf '{"jobs":[{"databaseId":201,"name":"%s"}]}\n' "\$(cat "$T/mutant-job")"
    ;;
  *)
    printf '{}\n'
    ;;
esac
exit 0
EOF
chmod +x "$T/bin/gh"

# Stub gh-ci: wait only, logging its args and exiting the canned code.
cat >"$T/bin/gh-ci" <<EOF
#!/usr/bin/env bash
printf 'ghci|%s\n' "\$*" >>"$T/calls.log"
exit "\$(cat "$T/ghci-rc")"
EOF
chmod +x "$T/bin/gh-ci"

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
    printf 'spec=%s\n' 5
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
  rm -f "$T/empty-pr" "$T/no-runs" "$T/noview"
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
grep -q "^review-start|7 --repo switchyard --cwd $WT --head $H --issue 528 --spec 5 --model rrm --overbuild-model oom --axes standards$" "$T/calls.log" || fail "happy: standards starts with state and flag values"
grep -q "^review-start|7 --repo switchyard --cwd $WT --head $H --issue 528 --spec 5 --model rrm --overbuild-model oom --axes spec$" "$T/calls.log" || fail "happy: spec starts per axis"
grep -q "^review-start|7 --repo switchyard --cwd $WT --head $H --issue 528 --spec 5 --model rrm --overbuild-model oom --axes overbuild$" "$T/calls.log" || fail "happy: overbuild starts per axis"
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
grep -q "^ghci|wait 7 --job Selection --repo switchyard$" "$T/calls.log" || fail "mutants: gh-ci waits on the mutant job"
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

# --- a lane ASK passes through and starts nothing after it ---
setup_case ask
printf 'ask-lane' >"$T/delegate-mode"
run_build
[ "$RC" -eq 1 ] || fail "ask exits 1 (rc=$RC)"
expect_verdict "TKT tkt-build ASK id=stub-1 log=*" "ask"
grep -q "which scope rules the retry?" <<<"$OUT" || fail "ask: the digest holds the question"
grep -q "^gate|" "$T/calls.log" && fail "ask: the gate never runs"
grep -q "^review-start|" "$T/calls.log" && fail "ask: review never starts"
bash "$TKT_STATE" "$S" get head >/dev/null 2>&1 && fail "ask: pr and head stay unset"

# --- a lane usage error (no verdict line) becomes a LANE-ERROR ---
setup_case lane-error
grep -v '^model\.lane=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
run_build
[ "$RC" -eq 2 ] || fail "lane-error exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build LANE-ERROR log=*" "lane-error"
grep -q "model.lane" <<<"$OUT" || fail "lane-error: the digest names the key"
grep -q "model.lane" "$CDIR/stderr.txt" || fail "lane-error: stderr names the key"

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

# --- a missing state key names itself ---
setup_case missingkey
grep -v '^spec=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
run_build
[ "$RC" -eq 2 ] || fail "missingkey exits 2 (rc=$RC)"
expect_verdict "TKT tkt-build PRECONDITION missing=spec log=*" "missingkey"
grep -q 'missing key: spec' "$CDIR/stderr.txt" || fail "missingkey: stderr names spec"

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

echo "tkt-build: all cases passed"

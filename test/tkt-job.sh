#!/usr/bin/env bash
# Tests for bin/tkt-job: fill a brief, run one delegated job, wait and digest it.
# A stub delegate on a temp TKT_BIN records its calls and serves canned records;
# symlinks there reach the real fill-brief and plan-gate. Real git on throwaway
# repos. Never starts a real job.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TKT="$SCRIPT_DIR/../bin/tkt-job"
TKT_STATE="$SCRIPT_DIR/../bin/tkt-state"
REAL_BIN="$SCRIPT_DIR/../bin"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-tkt-job.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp" "$T/bin" "$T/records" "$T/cases"
export HOME="$T/home" TMPDIR="$T/tmp" TKT_BIN="$T/bin"
export STUB_JOBSDIR="$T/tmp/delegate-jobs"

[ -x "$REAL_BIN/fill-brief" ] || fail "real fill-brief missing"
[ -x "$REAL_BIN/plan-gate" ] || fail "real plan-gate missing"
ln -s "$REAL_BIN/fill-brief" "$T/bin/fill-brief" || fail "symlink fill-brief"
ln -s "$REAL_BIN/plan-gate" "$T/bin/plan-gate" || fail "symlink plan-gate"

# Stub delegate: run/resume print a fresh job id and log the call; watch copies
# each canned record into the jobs dir. The id counter resets per case.
printf '0' >"$T/counter"
: >"$T/stub.log"
cat >"$T/bin/delegate" <<EOF
#!/usr/bin/env bash
set -uo pipefail
log="$T/stub.log"
recs="$T/records"
cmd="\${1:-}"; shift || true
case "\$cmd" in
  run)
    model=""; cwd=""; gate=""; prompt=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --model) model="\$2"; shift 2 ;;
        --cwd) cwd="\$2"; shift 2 ;;
        --gate) gate="\$2"; shift 2 ;;
        --prompt-file) prompt="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    n="\$((\$(cat "$T/counter") + 1))"
    printf '%s' "\$n" >"$T/counter"
    printf 'run|model=%s|cwd=%s|gate=%s|prompt=%s\n' "\$model" "\$cwd" "\$gate" "\$prompt" >>"\$log"
    printf 'stub-%s\n' "\$n"
    ;;
  resume)
    id="\${1:-}"; shift || true
    prompt=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --prompt-file) prompt="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    n="\$((\$(cat "$T/counter") + 1))"
    printf '%s' "\$n" >"$T/counter"
    printf 'resume|id=%s|prompt=%s|new=stub-%s\n' "\$id" "\$prompt" "\$n" >>"\$log"
    printf 'stub-%s\n' "\$n"
    ;;
  watch)
    printf 'watch|%s\n' "\$*" >>"\$log"
    mkdir -p "\$TMPDIR/delegate-jobs"
    for wid in "\$@"; do
      if [ -f "\$recs/\$wid.json" ]; then
        cp "\$recs/\$wid.json" "\$TMPDIR/delegate-jobs/\$wid.json"
      fi
    done
    ;;
  *)
    echo "stub delegate: unknown command \$cmd" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$T/bin/delegate"

# Fresh git worktree with one commit; prints its HEAD.
fresh_tree() {
  mkdir -p "$1"
  git init -q "$1"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$1" rev-parse HEAD
}

# New case directory with a worktree, run dir and base state file.
# Sets CDIR, WT, H, S.
setup_case() {
  CDIR="$T/cases/$1"
  mkdir -p "$CDIR/run"
  H="$(fresh_tree "$CDIR/wt")"
  WT="$CDIR/wt"
  S="$CDIR/tkt.state"
  {
    printf 'repo=%s\n' switchyard
    printf 'issue=%s\n' 502
    printf 'run=%s\n' "$CDIR/run"
    printf 'worktree=%s\n' "$WT"
    printf 'branch=%s\n' tkt-job
    printf 'head=%s\n' "$H"
    printf 'model.lane=%s\n' test-model
  } >"$S"
}

# Reset the stub between cases: fresh ids, an empty call log, no job records.
reset_stub() {
  printf '0' >"$T/counter"
  : >"$T/stub.log"
  rm -rf "$T/tmp/delegate-jobs"
}

# Canned record: make_record ID STATUS GATE NCOMMITS NTEXT NTAIL [CONCERNS] [SUP] [NUNCOMMITTED]
# GATE is an exit code or "none" (no gateResult). CONCERNS "none" means null.
make_record() {
  local id="$1" status="$2" gate="$3" ncommits="$4" ntext="$5" ntail="$6"
  local concerns="${7:-none}" sup="${8:-}" nuncomm="${9:-0}"
  local i text="" tail="" comms="" dirt=""
  for ((i = 1; i <= ntext; i++)); do text="${text}result line ${i}
"; done
  for ((i = 1; i <= ntail; i++)); do tail="${tail}gate log line ${i}
"; done
  for ((i = 1; i <= ncommits; i++)); do comms="${comms}111111111111111111111111111111111111111${i} "; done
  for ((i = 1; i <= nuncomm; i++)); do dirt="${dirt}dirty${i}.txt "; done
  jq -n \
    --arg status "$status" \
    --arg text "$text" \
    --arg tail "$tail" \
    --arg gate "$gate" \
    --arg comms "$comms" \
    --arg dirt "$dirt" \
    --arg concerns "$concerns" \
    --arg sup "$sup" \
    '($comms | split(" ") | map(select(length > 0))) as $nc
     | ($dirt | split(" ") | map(select(length > 0))) as $uf
     | (if $gate == "none" then null
        else {passed: ($gate == "0"), command: "bash gate.sh",
              exitCode: ($gate | tonumber), outputTail: $tail,
              outputPath: "/tmp/gate-test.log"} end) as $g
     | (if $concerns == "none" then null else $concerns end) as $c
     | {status: $status,
        result: {status: $status, text: $text, gateResult: $g,
                 changeSet: {headBefore: "aaaa", headAfter: "bbbb",
                             newCommits: $nc, uncommittedFiles: $uf,
                             filesChanged: [], diffstat: "", dirtyAfter: false},
                 concerns: $c},
        supervisorPid: 1}
       + (if $sup == "" then {} else {supersededBy: $sup} end)' \
    >"$T/records/$id.json" || fail "make_record $id"
}

# Run tkt-job on the current case state; sets OUT and RC, keeps stderr in file.
run_job() {
  OUT="$(bash "$TKT" "$S" "$@" 2>"$CDIR/stderr.txt")"; RC=$?
}

first_line() {
  head -n 1 <<<"$OUT"
}

expect_verdict() {
  case "$(first_line)" in
    $1) ;;
    *) fail "$2: verdict $(first_line) (rc=$RC): $(cat "$CDIR/stderr.txt")" ;;
  esac
}

# Templates and fixtures.
cat >"$T/tmpl-basic.md" <<'EOF'
Issue __ISSUE__ in __REPO__ at __WORKTREE__ on __BRANCH__.
EOF
cat >"$T/tmpl-full.md" <<'EOF'
Issue __ISSUE__ in __REPO__.
Extra words: __EXTRA__
Fence:
__FENCE__
EOF
cat >"$T/tmpl-missing.md" <<'EOF'
This template needs __NOPE__.
EOF
cat >"$T/plan.md" <<'EOF'
# Plan

## Files

- bin/tkt-job
- test/tkt-job.sh

## Gate

`true`
EOF
cat >"$T/plan-fail.md" <<'EOF'
# Plan

## Files

- bin/tkt-job

## Gate

`bash -c 'echo hi; exit 3'`
EOF
printf 'extra words here\n' >"$T/extra.md"
printf 'do the thing\n' >"$T/brief.md"
printf 'resume prompt\n' >"$T/resume-prompt.md"

# --- DONE with a passed gate and commits, under --expect-commits ---
setup_case done-pass
reset_stub
make_record stub-1 DONE 0 2 30 15
run_job --slot lane --template "$T/tmpl-basic.md" --expect-commits
[ "$RC" -eq 0 ] || fail "DONE exits 0 (rc=$RC)"
expect_verdict "TKT tkt-job DONE id=stub-1 head=bbbb commits=2 gate=PASS log=*" "DONE"
# The digest keeps the last 25 result lines and the last 10 gate lines.
grep -qx "result line 6" <<<"$OUT" || fail "DONE digest keeps 25 text lines"
grep -qx "result line 5" <<<"$OUT" && fail "DONE digest drops older text lines"
grep -qx "gate log line 6" <<<"$OUT" || fail "DONE digest keeps 10 gate lines"
grep -qx "gate log line 5" <<<"$OUT" && fail "DONE digest drops older gate lines"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -le 41 ] || fail "DONE stdout is at most 41 lines"
grep -q "|model=test-model|" "$T/stub.log" || fail "DONE passes the state model"
grep -q "prompt=$CDIR/run/switchyard-502-lane-1.md" "$T/stub.log" || fail "DONE writes brief -lane-1.md"
[ "$(bash "$TKT_STATE" "$S" get job.lane)" = "stub-1" ] || fail "DONE stores job.lane"
grep -q "dispatch slot=lane id=stub-1" "$CDIR/tkt.journal" || fail "DONE journals the dispatch"
grep -q "DONE id=stub-1" "$CDIR/tkt.journal" || fail "DONE journals the verdict"
# A second call re-prints the same verdict without a new dispatch.
run_job --slot lane --template "$T/tmpl-basic.md" --expect-commits
[ "$RC" -eq 0 ] || fail "re-print exits 0"
expect_verdict "TKT tkt-job DONE id=stub-1 head=bbbb commits=2 gate=PASS reused=stub-1 log=*" "re-print"
[ "$(grep -c '^run|' "$T/stub.log")" -eq 1 ] || fail "re-print dispatches nothing new"

# --- DONE with no gate and no commits, without --expect-commits ---
setup_case done-plain
reset_stub
make_record stub-1 DONE none 0 3 0
run_job --slot lane --template "$T/tmpl-basic.md"
[ "$RC" -eq 0 ] || fail "plain DONE exits 0"
expect_verdict "TKT tkt-job DONE id=stub-1 head=bbbb commits=0 gate=none log=*" "plain DONE"

# --- DONE_WITH_CONCERNS with a failed gate ---
setup_case gate-fail
reset_stub
make_record stub-1 DONE_WITH_CONCERNS 3 1 3 4 "reviewer is uneasy"
run_job --slot lane --template "$T/tmpl-basic.md" --expect-commits
[ "$RC" -eq 1 ] || fail "GATE-FAIL exits 1"
expect_verdict "TKT tkt-job GATE-FAIL rc=3 gatelog=/tmp/gate-test.log log=*" "GATE-FAIL"
grep -q "reviewer is uneasy" <<<"$OUT" || fail "GATE-FAIL digest carries concerns"

# --- DONE with a failed gate is a GATE-FAIL too: the script exit rules ---
setup_case done-badgate
reset_stub
make_record stub-1 DONE 1 1 2 0
run_job --slot lane --template "$T/tmpl-basic.md"
[ "$RC" -eq 1 ] || fail "DONE with failed gate exits 1"
expect_verdict "TKT tkt-job GATE-FAIL rc=1 gatelog=/tmp/gate-test.log log=*" "DONE failed gate"

# --- DONE_WITH_CONCERNS with a passed gate, commits, and --expect-commits ---
setup_case concerns
reset_stub
make_record stub-1 DONE_WITH_CONCERNS 0 2 3 0
run_job --slot lane --template "$T/tmpl-basic.md" --expect-commits
[ "$RC" -eq 1 ] || fail "CONCERNS exits 1"
expect_verdict "TKT tkt-job CONCERNS id=stub-1 log=*" "CONCERNS"

# --- NEEDS_CONTEXT with --out-file writes the full report ---
setup_case ask
reset_stub
make_record stub-1 NEEDS_CONTEXT none 0 3 0
run_job --slot lane --template "$T/tmpl-basic.md" --out-file "$CDIR/report.md"
[ "$RC" -eq 1 ] || fail "ASK exits 1"
expect_verdict "TKT tkt-job ASK id=stub-1 report=result\\ line\\ 1 log=*" "ASK"
grep -q "result line 2" <<<"$OUT" || fail "ASK digest carries the question"
cmp "$CDIR/report.md" <(jq -j -r '.result.text' "$T/tmp/delegate-jobs/stub-1.json") || fail "--out-file writes result.text in full"

# --- BLOCKED ---
setup_case blocked
reset_stub
make_record stub-1 BLOCKED none 0 2 0
run_job --slot lane --template "$T/tmpl-basic.md"
[ "$RC" -eq 1 ] || fail "BLOCKED exits 1"
expect_verdict "TKT tkt-job BLOCKED id=stub-1 log=*" "BLOCKED"

# --- DONE with no commits under --expect-commits ---
setup_case no-commits
reset_stub
make_record stub-1 DONE 0 0 2 0
run_job --slot lane --template "$T/tmpl-basic.md" --expect-commits
[ "$RC" -eq 1 ] || fail "NO-COMMITS exits 1"
expect_verdict "TKT tkt-job NO-COMMITS id=stub-1 gate=PASS log=*" "NO-COMMITS"

# --- ERROR and STALLED ---
setup_case job-error
reset_stub
make_record stub-1 ERROR none 0 2 0
run_job --slot lane --template "$T/tmpl-basic.md"
[ "$RC" -eq 1 ] || fail "JOB-ERROR exits 1"
expect_verdict "TKT tkt-job JOB-ERROR status=ERROR id=stub-1 log=*" "JOB-ERROR"
setup_case job-stalled
reset_stub
make_record stub-1 STALLED none 0 2 0
run_job --slot lane --template "$T/tmpl-basic.md"
[ "$RC" -eq 1 ] || fail "STALLED exits 1"
expect_verdict "TKT tkt-job JOB-ERROR status=STALLED id=stub-1 log=*" "STALLED"

# --- an unknown status, and no record at all ---
setup_case unknown-status
reset_stub
make_record stub-1 WEIRD none 0 2 0
run_job --slot lane --template "$T/tmpl-basic.md"
[ "$RC" -eq 3 ] || fail "unknown status exits 3"
expect_verdict "TKT tkt-job UNKNOWN * log=*" "UNKNOWN status"
setup_case no-record
reset_stub
printf 'job.lane=%s\n' ghost-1 >>"$S"
run_job --slot lane
[ "$RC" -eq 3 ] || fail "no record exits 3"
expect_verdict "TKT tkt-job UNKNOWN id=ghost-1 reused=ghost-1 log=*" "no record"
grep -q "^watch|ghost-1$" "$T/stub.log" || fail "no record still watches"
grep -q "^run|" "$T/stub.log" && fail "no record dispatches nothing"

# --- the resume chain: stub-1 is superseded by stub-2 ---
setup_case chain
reset_stub
make_record stub-1 DONE 0 1 2 0 none stub-2
make_record stub-2 DONE 0 1 2 0
mkdir -p "$T/tmp/delegate-jobs"
cp "$T/records/stub-2.json" "$T/tmp/delegate-jobs/stub-2.json"
run_job --slot lane --template "$T/tmpl-basic.md"
[ "$RC" -eq 0 ] || fail "chain exits 0"
expect_verdict "TKT tkt-job DONE id=stub-2 head=bbbb commits=1 gate=PASS log=*" "chain"

# --- --resume dispatches a resume and stores the new id ---
setup_case resume
reset_stub
make_record old-9 BLOCKED none 0 2 0 none stub-1
make_record stub-1 DONE 0 1 2 0
run_job --slot lane --resume old-9 --prompt "$T/resume-prompt.md"
[ "$RC" -eq 0 ] || fail "resume exits 0"
expect_verdict "TKT tkt-job DONE id=stub-1 head=bbbb commits=1 gate=PASS log=*" "resume"
grep -q "^resume|id=old-9|prompt=$T/resume-prompt.md|new=stub-1$" "$T/stub.log" || fail "resume calls delegate resume"
[ "$(bash "$TKT_STATE" "$S" get job.lane)" = "stub-1" ] || fail "resume stores the new id"

# --- crash-rerun: a stored live id watches only ---
setup_case rerun
reset_stub
make_record seeded-9 DONE 0 1 2 0
printf 'job.lane=%s\n' seeded-9 >>"$S"
run_job --slot lane
[ "$RC" -eq 0 ] || fail "rerun exits 0"
expect_verdict "TKT tkt-job DONE id=seeded-9 head=bbbb commits=1 gate=PASS reused=seeded-9 log=*" "rerun"
grep -q "^watch|seeded-9$" "$T/stub.log" || fail "rerun watches the stored id"
grep -q "^run|" "$T/stub.log" && fail "rerun starts no second run"

# --- a supersededBy self-loop is unrecognised, never a hang ---
setup_case cycle
reset_stub
make_record loop-1 DONE 0 1 2 0 none loop-1
printf 'job.lane=%s\n' loop-1 >>"$S"
run_job --slot lane
[ "$RC" -eq 3 ] || fail "a supersededBy cycle exits 3"
expect_verdict "TKT tkt-job UNKNOWN id=loop-1 reused=loop-1 log=*" "cycle"

# --- a template key from neither flags nor state exits 2 naming it ---
setup_case missing-key
reset_stub
run_job --slot lane --template "$T/tmpl-missing.md"
[ "$RC" -eq 2 ] || fail "missing key exits 2"
grep -q "NOPE" "$CDIR/stderr.txt" || fail "missing key names NOPE"
grep -q "^run|" "$T/stub.log" && fail "missing key dispatches nothing"

# --- flags fill first, and only keys the template has are passed ---
setup_case flag-wins
reset_stub
make_record stub-1 DONE none 0 1 0
run_job --slot lane --template "$T/tmpl-basic.md" ISSUE=999 FOO=bar
[ "$RC" -eq 0 ] || fail "extra flags exit 0"
brief="$(grep '^run|' "$T/stub.log" | sed 's/.*|prompt=//')"
grep -q "Issue 999" "$brief" || fail "a flag beats the state value"
grep -q "Issue 502" "$brief" && fail "the state value loses to the flag"

# --- EXTRA comes from the state file, FENCE from the plan's Files ---
setup_case fills
reset_stub
make_record stub-1 DONE none 0 1 0
printf 'extra=%s\n' "$T/extra.md" >>"$S"
printf 'plan=%s\n' "$T/plan.md" >>"$S"
run_job --slot lane --template "$T/tmpl-full.md"
[ "$RC" -eq 0 ] || fail "fills exit 0"
brief="$(grep '^run|' "$T/stub.log" | sed 's/.*|prompt=//')"
grep -q "extra words here" "$brief" || fail "EXTRA reads the state file"
grep -q "bin/tkt-job" "$brief" || fail "FENCE reads the plan Files"
grep -q "test/tkt-job.sh" "$brief" || fail "FENCE reads every plan file"
setup_case fills-flag
reset_stub
make_record stub-1 DONE none 0 1 0
printf 'extra=%s\n' "$T/extra.md" >>"$S"
printf 'plan=%s\n' "$T/plan.md" >>"$S"
run_job --slot lane --template "$T/tmpl-full.md" FENCE=custom
[ "$RC" -eq 0 ] || fail "FENCE flag exits 0"
brief="$(grep '^run|' "$T/stub.log" | sed 's/.*|prompt=//')"
grep -q "custom" "$brief" || fail "a FENCE flag beats the plan"

# --- a second dispatch for one slot takes a fresh brief number ---
setup_case fresh-k
reset_stub
make_record stub-1 DONE none 0 1 0
run_job --slot lane --template "$T/tmpl-basic.md"
[ "$RC" -eq 0 ] || fail "first dispatch exits 0"
bash "$TKT_STATE" "$S" set job.lane "" || fail "clear job.lane"
make_record stub-2 DONE none 0 1 0
run_job --slot lane --template "$T/tmpl-basic.md"
[ "$RC" -eq 0 ] || fail "second dispatch exits 0"
grep -q "prompt=$CDIR/run/switchyard-502-lane-2.md" "$T/stub.log" || fail "second dispatch writes brief -lane-2.md"

# --- --brief passes a file through untouched ---
setup_case brief
reset_stub
make_record stub-1 DONE none 0 1 0
run_job --slot lane --brief "$T/brief.md"
[ "$RC" -eq 0 ] || fail "--brief exits 0"
grep -q "prompt=$T/brief.md" "$T/stub.log" || fail "--brief reaches delegate"

# --- with TKT_BIN unset, delegate comes from PATH ---
setup_case path-delegate
reset_stub
mkdir -p "$T/pathbin"
ln -s "$T/bin/delegate" "$T/pathbin/delegate" || fail "symlink delegate onto PATH"
make_record stub-1 DONE none 0 1 0
OUT="$(env -u TKT_BIN PATH="$T/pathbin:$PATH" bash "$TKT" "$S" --slot lane --brief "$T/brief.md" --model test-model 2>"$CDIR/stderr.txt")"; RC=$?
[ "$RC" -eq 0 ] || fail "PATH delegate exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-job DONE id=stub-1 head=bbbb commits=0 gate=none log=*" "PATH delegate"
grep -q "^run|model=test-model|" "$T/stub.log" || fail "PATH delegate dispatches through the PATH stub"

# --- --gate-from-plan writes the gate script; its exit rules, not its echo ---
setup_case gate-script
reset_stub
make_record stub-1 DONE none 0 1 0
printf 'plan=%s\n' "$T/plan-fail.md" >>"$S"
run_job --slot lane --template "$T/tmpl-basic.md" --gate-from-plan
[ "$RC" -eq 0 ] || fail "gate dispatch exits 0"
gate_sh="$CDIR/run/switchyard-502-gate.sh"
[ -f "$gate_sh" ] || fail "the gate script is written"
grep -q "gate=bash $gate_sh" "$T/stub.log" || fail "delegate gets --gate 'bash <script>'"
gout="$(bash "$gate_sh" 2>&1)"; grc=$?
[ "$grc" -eq 3 ] || fail "a failing gate script exits 3 (rc=$grc)"
grep -q "GATE FAIL rc=3" <<<"$gout" || fail "a failing gate script prints GATE FAIL rc=3"
setup_case gate-pass
reset_stub
make_record stub-1 DONE none 0 1 0
printf 'plan=%s\n' "$T/plan.md" >>"$S"
run_job --slot lane --template "$T/tmpl-basic.md" --gate-from-plan
[ "$RC" -eq 0 ] || fail "passing gate dispatch exits 0"
gout="$(bash "$CDIR/run/switchyard-502-gate.sh" 2>&1)"; grc=$?
[ "$grc" -eq 0 ] || fail "a passing gate script exits 0"
grep -q "GATE PASS" <<<"$gout" || fail "a passing gate script prints GATE PASS"

# --- usage and preconditions exit 2 ---
setup_case both-gates
reset_stub
run_job --slot lane --template "$T/tmpl-basic.md" --gate true --gate-from-plan
[ "$RC" -eq 2 ] || fail "--gate with --gate-from-plan exits 2"
setup_case resume-no-prompt
reset_stub
run_job --slot lane --resume old-9
[ "$RC" -eq 2 ] || fail "--resume without --prompt exits 2"
setup_case resume-template
reset_stub
run_job --slot lane --resume old-9 --prompt "$T/resume-prompt.md" --template "$T/tmpl-basic.md"
[ "$RC" -eq 2 ] || fail "--resume with --template exits 2"
setup_case no-model
reset_stub
grep -v '^model\.lane=' "$S" >"$CDIR/nomodel.state"
S="$CDIR/nomodel.state"
run_job --slot lane --template "$T/tmpl-basic.md"
[ "$RC" -eq 2 ] || fail "a missing model exits 2"
grep -q "model.lane" "$CDIR/stderr.txt" || fail "a missing model names model.lane"
setup_case flag-model
reset_stub
grep -v '^model\.lane=' "$S" >"$CDIR/nomodel.state"
S="$CDIR/nomodel.state"
make_record stub-1 DONE none 0 1 0
run_job --slot lane --template "$T/tmpl-basic.md" --model flag-model
[ "$RC" -eq 0 ] || fail "--model exits 0"
grep -q "|model=flag-model|" "$T/stub.log" || fail "--model beats the state"

# --- a held lock exits 2 naming the pid, and dispatches nothing ---
setup_case locked
reset_stub
mkdir "$S.lock"
printf '424242\n' >"$S.lock/pid"
run_job --slot lane --template "$T/tmpl-basic.md"
[ "$RC" -eq 2 ] || fail "a held lock exits 2"
grep -q "424242" "$CDIR/stderr.txt" || fail "a held lock names the pid"
grep -q "^run|" "$T/stub.log" && fail "a held lock dispatches nothing"
rm -rf "$S.lock"

# --- head drift exits 3 naming the stored head and the worktree HEAD ---
setup_case drift
reset_stub
bash "$TKT_STATE" "$S" set head 0000000000000000000000000000000000000000 || fail "set fake head"
run_job --slot lane --template "$T/tmpl-basic.md"
[ "$RC" -eq 3 ] || fail "drift exits 3"
grep -q "0000000000000000000000000000000000000000" "$CDIR/stderr.txt" || fail "drift names the stored head"
grep -q "$H" "$CDIR/stderr.txt" || fail "drift names the worktree HEAD"
grep -q "$WT" "$CDIR/stderr.txt" || fail "drift names the worktree"
grep -q "^run|" "$T/stub.log" && fail "drift dispatches nothing"

# --- remaining usage and precondition arms, each exits 2 without dispatch ---
setup_case usage-misc
reset_stub
run_job --template "$T/tmpl-basic.md"
[ "$RC" -eq 2 ] || fail "a missing --slot exits 2"
run_job --slot lane --template "$T/tmpl-basic.md" --bogus
[ "$RC" -eq 2 ] || fail "an unknown flag exits 2"
run_job --slot lane --template "$T/tmpl-basic.md" --brief "$T/brief.md"
[ "$RC" -eq 2 ] || fail "--template with --brief exits 2"
run_job --slot lane
[ "$RC" -eq 2 ] || fail "no brief source exits 2"
run_job --slot lane --brief "$T/brief.md" --prompt "$T/resume-prompt.md"
[ "$RC" -eq 2 ] || fail "--prompt without --resume exits 2"
run_job --slot lane --template "$T/tmpl-basic.md" --resume old-9 --prompt "$T/resume-prompt.md"
[ "$RC" -eq 2 ] || fail "--resume tested above with --template exits 2"
run_job --slot lane --template "$T/no-such-template.md"
[ "$RC" -eq 2 ] || fail "an unreadable template exits 2"
run_job --slot lane --brief "$T/no-such-brief.md"
[ "$RC" -eq 2 ] || fail "an unreadable brief exits 2"
grep -q "^run|" "$T/stub.log" && fail "usage errors dispatch nothing"
[ "$(grep -c "^watch|" "$T/stub.log")" -eq 0 ] || fail "usage errors watch nothing"

# --- --gate-from-plan without a plan names the key and the setter on one line ---
setup_case gate-no-plan-msg
reset_stub
run_job --slot lane --template "$T/tmpl-basic.md" --gate-from-plan
[ "$RC" -eq 2 ] || fail "missing plan gate exits 2"
[ "$(wc -l <"$CDIR/stderr.txt" | tr -d ' ')" -eq 1 ] || fail "missing plan gate is one line: $(cat "$CDIR/stderr.txt")"
grep -q "missing key: plan" "$CDIR/stderr.txt" || fail "missing plan gate names the plan key"
grep -q "tkt-plan $S set" "$CDIR/stderr.txt" || fail "missing plan gate names the setter"
[ -z "$(grep '^run|' "$T/stub.log" || true)" ] || fail "missing plan gate dispatches nothing"

# --- --gate-from-plan with a gateless plan names the gate and the setter ---
setup_case gate-no-gate-section
reset_stub
printf '# Plan\n\n## Files\n\n- bin/x\n' >"$CDIR/plan.md"
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
run_job --slot lane --template "$T/tmpl-basic.md" --gate-from-plan
[ "$RC" -eq 2 ] || fail "gateless plan exits 2"
[ "$(wc -l <"$CDIR/stderr.txt" | tr -d ' ')" -eq 1 ] || fail "gateless plan error is one line: $(cat "$CDIR/stderr.txt")"
grep -q "tkt-plan $S set" "$CDIR/stderr.txt" || fail "gateless plan error names the setter"
grep -q "[Gg]ate" "$CDIR/stderr.txt" || fail "gateless plan error names the gate"
[ -z "$(grep '^run|' "$T/stub.log" || true)" ] || fail "gateless plan dispatches nothing"

# --- --gate-from-plan with a gateless plan prints plan-gate's reason ---
setup_case gate-reason
reset_stub
printf '# Plan\n\n## Notes\n\nnothing here\n' >"$CDIR/plan.md"
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
run_job --slot lane --template "$T/tmpl-basic.md" --gate-from-plan
[ "$RC" -eq 2 ] || fail "gateless reason exits 2"
grep -q "no '## Gate' heading" "$CDIR/stderr.txt" || fail "gateless reason prints plan-gate's reason: $(cat "$CDIR/stderr.txt")"
[ -z "$(grep '^run|' "$T/stub.log" || true)" ] || fail "gateless reason dispatches nothing"

# --- --gate-from-plan without a plan key exits 2 naming it ---
setup_case gate-no-plan
reset_stub
run_job --slot lane --template "$T/tmpl-basic.md" --gate-from-plan
[ "$RC" -eq 2 ] || fail "--gate-from-plan without plan exits 2"
grep -q "plan" "$CDIR/stderr.txt" || fail "--gate-from-plan without plan names plan"

# --- a pid-less lock still blocks with exit 2 ---
setup_case lock-no-pid
reset_stub
mkdir "$S.lock"
run_job --slot lane --template "$T/tmpl-basic.md"
[ "$RC" -eq 2 ] || fail "a pid-less lock exits 2"
grep -q "^run|" "$T/stub.log" && fail "a pid-less lock dispatches nothing"
rm -rf "$S.lock"

# --- DONE_WITH_CONCERNS with no gate is still CONCERNS ---
setup_case concerns-nogate
reset_stub
make_record stub-1 DONE_WITH_CONCERNS none 1 2 0
run_job --slot lane --template "$T/tmpl-basic.md"
[ "$RC" -eq 1 ] || fail "gateless CONCERNS exits 1"
expect_verdict "TKT tkt-job CONCERNS id=stub-1 log=*" "gateless CONCERNS"

# --- empty result text writes an empty report and no report key ---
setup_case empty-text
reset_stub
make_record stub-1 DONE none 0 0 0
run_job --slot lane --template "$T/tmpl-basic.md" --out-file "$CDIR/report.md"
[ "$RC" -eq 0 ] || fail "empty text exits 0"
[ ! -s "$CDIR/report.md" ] || fail "empty text writes an empty report"
case "$(first_line)" in *report=*) fail "empty text adds no report key";; esac

# --- no stored head and an unreadable worktree HEAD still logs ---
setup_case no-head-key
reset_stub
grep -v '^head=' "$S" | sed 's|^worktree=.*|worktree=/tmp/does-not-exist|' >"$CDIR/nohead.state"
S="$CDIR/nohead.state"
make_record stub-1 DONE none 0 1 0
run_job --slot lane --template "$T/tmpl-basic.md"
[ "$RC" -eq 0 ] || fail "missing git HEAD exits 0"
case "$(first_line)" in *nohead*) ;; *) fail "missing git HEAD logs under nohead";; esac

# --- repo as owner/name still lands brief, gate script and log directly in run ---
setup_case repo-slash
reset_stub
make_record stub-1 DONE none 0 1 0
bash "$TKT_STATE" "$S" set repo owner/name || fail "set repo owner/name"
printf 'plan=%s\n' "$T/plan.md" >>"$S"
run_job --slot lane --template "$T/tmpl-basic.md" --gate-from-plan
[ "$RC" -eq 0 ] || fail "owner/name repo exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
[ -f "$CDIR/run/name-502-lane-1.md" ] || fail "owner/name repo writes brief directly in run"
[ -f "$CDIR/run/name-502-gate.sh" ] || fail "owner/name repo writes gate script directly in run"
ls "$CDIR"/run/name-502-tkt-job-*.log >/dev/null 2>&1 || fail "owner/name repo writes log directly in run"
[ -z "$(find "$CDIR/run" -mindepth 1 -type d)" ] || fail "owner/name repo creates no subdirectory"

echo "tkt-job: all cases passed"

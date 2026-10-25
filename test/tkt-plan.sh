#!/usr/bin/env bash
# Tests for bin/tkt-plan: one Verifier round, post and plan-path set per call.
# Stub plan-check, post-plan, plan-sweep and tkt-job on a temp TKT_BIN; a symlink there
# reaches the real plan-gate. Real git on throwaway repos for the stale check.
# Never starts a real job. Never reads the real $HOME/.agents.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TKT="$SCRIPT_DIR/../bin/tkt-plan"
TKT_STATE="$SCRIPT_DIR/../bin/tkt-state"
REAL_BIN="$SCRIPT_DIR/../bin"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-tkt-plan.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp" "$T/bin" "$T/cases"
export HOME="$T/home" TMPDIR="$T/tmp" TKT_BIN="$T/bin"

[ -x "$REAL_BIN/plan-gate" ] || fail "real plan-gate missing"
ln -s "$REAL_BIN/plan-gate" "$T/bin/plan-gate" || fail "symlink plan-gate"

# Stub plan-check: mode file holds "ok" (exit 0) or "lines" (exit 1, two lines).
printf 'ok' >"$T/pcmode"
cat >"$T/bin/plan-check" <<EOF
#!/usr/bin/env bash
set -uo pipefail
printf 'check|%s\n' "\$*" >>"$T/stub.log"
if [ "\$(cat "$T/pcmode")" = lines ]; then
  printf 'missing path: bin/ghost (line 9): correct it, or mark the line new or removed\noutside Files: test/ghost (line 12): add it to Files, or mark the line reads\n'
  exit 1
fi
exit 0
EOF
chmod +x "$T/bin/plan-check"

# Stub tkt-job: mode file holds "ok" (PLAN OK report, exit 0), "lines" (three
# finding lines, exit 0) or "ask" (no report, exit 1). Writes --out-file.
printf 'ok' >"$T/mode"
cat >"$T/bin/tkt-job" <<EOF
#!/usr/bin/env bash
set -uo pipefail
slot=""; out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --slot) slot="\$2"; shift 2 ;;
    --template) tmpl="\$2"; shift 2 ;;
    --out-file) out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'job|slot=%s|tmpl=%s|out=%s|rest=%s\n' "\$slot" "\$tmpl" "\$out" "\$*" >>"$T/stub.log"
case "\$(cat "$T/mode")" in
  ok)
    printf 'PLAN OK\nheld: every invariant survived its breaking input\n' >"\$out"
    echo "TKT tkt-job DONE id=j1 head=h commits=0 gate=none report=PLAN OK log=x"
    ;;
  lines)
    printf '1. Rulings miss a contradiction in bin/x\n2. Files leaves out test/x\n3. Gate skips package y\n' >"\$out"
    echo "TKT tkt-job DONE id=j1 head=h commits=0 gate=none report=1. Rulings log=x"
    ;;
  ask)
    echo "TKT tkt-job ASK id=j1 log=x"
    echo "which design rules the retry?"
    exit 1
    ;;
  concerns)
    printf 'PLAN OK\nheld: every invariant survived its breaking input\n' >"\$out"
    echo "TKT tkt-job CONCERNS id=j1 log=x"
    echo "reviewer is uneasy about one edge"
    exit 1
    ;;
  concerns-noise)
    printf 'PLAN OK\nheld: every invariant survived its breaking input\n' >"\$out"
    echo "watch noise" >&2
    echo >&2
    echo "TKT tkt-job CONCERNS id=j1 log=x"
    echo "reviewer is uneasy about one edge"
    exit 1
    ;;
  blocked)
    echo "TKT tkt-job BLOCKED id=j1 log=x"
    exit 1
    ;;
esac
EOF
chmod +x "$T/bin/tkt-job"

# Stub post-plan: two comment URLs on stdout.
cat >"$T/bin/post-plan" <<EOF
#!/usr/bin/env bash
set -uo pipefail
printf 'post|%s\n' "\$*" >>"$T/stub.log"
printf 'https://github.com/o/r/issues/1#issuecomment-11\nhttps://github.com/o/r/issues/1#issuecomment-12\n'
EOF
chmod +x "$T/bin/post-plan"

# Stub plan-sweep: prints the PACK line for --out.
cat >"$T/bin/plan-sweep" <<EOF
#!/usr/bin/env bash
set -uo pipefail
printf 'sweep|%s\n' "\$*" >>"$T/stub.log"
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --out) out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'PACK %s symbols=0 files=0 outside=0\n' "\$out"
EOF
chmod +x "$T/bin/plan-sweep"

# Commit FILE with CONTENT in the repo at DIR; prints nothing.
wcommit() {
  printf '%s' "$3" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" -c user.email=t@t -c user.name=t commit -qm "$2"
}

# New case: a repo whose file f.txt changed since BASE_TAG, plan at that base,
# and a base state file. Sets CDIR, WT, S. $1 is the case name.
setup_case() {
  CDIR="$T/cases/$1"
  mkdir -p "$CDIR/run"
  git init -q "$CDIR/wt"
  wcommit "$CDIR/wt" f.txt "v1"
  git -C "$CDIR/wt" rev-parse HEAD >"$CDIR/base"
  wcommit "$CDIR/wt" f.txt "v2"
  git -C "$CDIR/wt" update-ref refs/remotes/origin/main HEAD
  WT="$CDIR/wt"
  {
    printf 'Base: %s\n' "$(cat "$CDIR/base")"
    printf '\n## Files\n\n- `f.txt`\n\n## Gate\n\n`true`\n'
  } >"$CDIR/plan.md"
  S="$CDIR/tkt.state"
  {
    printf 'repo=%s\n' switchyard
    printf 'issue=%s\n' 518
    printf 'run=%s\n' "$CDIR/run"
    printf 'worktree=%s\n' "$WT"
    printf 'branch=%s\n' tkt-plan
    printf 'plan=%s\n' "$CDIR/plan.md"
    printf 'model.verifier=%s\n' test-model
  } >"$S"
}

# Point the case plan at the current HEAD, so the stale check passes.
rebase_plan() {
  git -C "$WT" rev-parse HEAD >"$CDIR/base"
  {
    printf 'Base: %s\n' "$(cat "$CDIR/base")"
    printf '\n## Files\n\n- `f.txt`\n\n## Gate\n\n`true`\n'
  } >"$CDIR/plan.md"
}

# Run tkt-plan on the current case state; sets OUT and RC, stderr kept in file.
run_plan() {
  OUT="$(bash "$TKT" "$S" "$@" 2>"$CDIR/stderr.txt")"; RC=$?
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

: >"$T/stub.log"

# --- a stale plan stops before plan-check ---
setup_case stale
run_plan verify
[ "$RC" -eq 1 ] || fail "STALE exits 1 (rc=$RC)"
expect_verdict "TKT tkt-plan STALE n=1 base=* log=*" "STALE"
grep -q "f.txt" <<<"$OUT" || fail "STALE digest names the changed file"
grep -q "^check|" "$T/stub.log" && fail "STALE runs before plan-check"
grep -q "STALE" "$CDIR/tkt.journal" || fail "STALE is journaled"

# --- only a Files line's first backticked token is a pathspec ---
# f.txt changed; it is the second token on the line, so the plan is not stale.
setup_case prose-b
printf 'Base: %s\n\n## Files\n\n- `g.txt` reads `f.txt` and `/reload`\n\n## Gate\n\n`true`\n' "$(cat "$CDIR/base")" >"$CDIR/plan.md"
run_plan verify
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "prose-b"
# f.txt changed and is the first token: STALE n=1, the trailing tokens add nothing.
setup_case prose-a
printf 'Base: %s\n\n## Files\n\n- `f.txt` reads `g.txt` and `/reload`\n\n## Gate\n\n`true`\n' "$(cat "$CDIR/base")" >"$CDIR/plan.md"
run_plan verify
expect_verdict "TKT tkt-plan STALE n=1 base=* log=*" "prose-a"
# A prose line under ## Files names f.txt (changed on main) and `crates`: no pathspec from it, so not stale.
setup_case prose-line
printf 'Base: %s\n\n## Files\n\n- `g.txt`\nSweep run over `f.txt` and `crates`\n\n## Gate\n\n`true`\n' "$(cat "$CDIR/base")" >"$CDIR/plan.md"
run_plan verify
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "prose-line"
# Prose before a list item's first backticked token adds no pathspec: f.txt is not the path.
setup_case prose-item
printf 'Base: %s\n\n## Files\n\n- Sweep run over `f.txt`\n- `g.txt`\n\n## Gate\n\n`true`\n' "$(cat "$CDIR/base")" >"$CDIR/plan.md"
run_plan verify
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "prose-item"
# A list item whose path is a bare directory that changed on main: STALE names the Files line.
setup_case bare-dir
mkdir -p "$CDIR/wt/crates" && wcommit "$CDIR/wt" crates/c.txt "c1" && git -C "$CDIR/wt" update-ref refs/remotes/origin/main HEAD
printf 'Base: %s\n\n## Files\n\n- `g.txt`\n- `crates`\n\n## Gate\n\n`true`\n' "$(cat "$CDIR/base")" >"$CDIR/plan.md"
run_plan verify
expect_verdict "TKT tkt-plan STALE n=1 base=* log=*" "bare-dir"
grep -q 'Files line 6: `crates` is a bare directory' <<<"$OUT" || fail "bare-dir names the Files line"
: >"$T/stub.log"

# --- plan-check lines block the round ---
setup_case check
rebase_plan
printf 'lines' >"$T/pcmode"
run_plan verify
[ "$RC" -eq 1 ] || fail "PLAN-CHECK exits 1"
expect_verdict "TKT tkt-plan PLAN-CHECK n=2 log=*" "PLAN-CHECK"
grep -q "missing path: bin/ghost" <<<"$OUT" || fail "PLAN-CHECK lists the first line"
grep -q "outside Files: test/ghost" <<<"$OUT" || fail "PLAN-CHECK lists the second line"
grep -q "^job|" "$T/stub.log" && fail "PLAN-CHECK starts no job"
printf 'ok' >"$T/pcmode"

# --- LINES, then PLAN-OK, then the round limit ---
setup_case rounds
rebase_plan
printf 'lines' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "LINES exits 1"
expect_verdict "TKT tkt-plan LINES n=3 out=* log=*" "LINES"
grep -q "Files leaves out test/x" <<<"$OUT" || fail "LINES digest carries the report"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "1" ] || fail "LINES counts the round"
grep -q "verifier-out-r1.md" "$T/stub.log" || fail "round 1 writes verifier-out-r1.md"
grep -q "slot=verifier-r1" "$T/stub.log" || fail "round 1 uses slot verifier-r1"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "PLAN-OK exits 0"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "PLAN-OK"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "2" ] || fail "PLAN-OK counts the round"
grep -q "slot=verifier-r2" "$T/stub.log" || fail "round 2 dispatches a new job on slot verifier-r2"
grep -q "verifier.md" "$T/stub.log" || fail "verify fills the verifier brief"
run_plan verify
[ "$RC" -eq 1 ] || fail "ROUND-LIMIT exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 log=*" "ROUND-LIMIT"
[ "$(grep -c '^job|' "$T/stub.log")" -eq 2 ] || fail "ROUND-LIMIT starts no third job"

# --- confirm is the final pass: it records the round, then verify stops ---
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "confirm PLAN-OK exits 0"
expect_verdict "TKT tkt-plan PLAN-OK out=*confirm-out.md log=*" "confirm"
[ "$(bash "$TKT_STATE" "$S" get confirmed_for)" = "2" ] || fail "confirm records the round it covers"
grep -q "slot=confirm" "$T/stub.log" || fail "confirm runs the confirm slot"
grep -q "confirm.md" "$T/stub.log" || fail "confirm fills the confirm brief"
jobs_before="$(grep -c '^job|' "$T/stub.log")"
run_plan verify
[ "$RC" -eq 1 ] || fail "verify after confirm exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "verify after confirm"
[ "$(grep -c '^job|' "$T/stub.log")" = "$jobs_before" ] || fail "verify after confirm starts no job"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "a second confirm exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT confirm=done log=*" "second confirm"
[ "$(grep -c '^job|' "$T/stub.log")" = "$jobs_before" ] || fail "a second confirm starts no job"

# --- a LINES confirm still spends the one confirm round ---
setup_case confirm-lines
rebase_plan
printf 'lines' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "confirm-lines round 1 exits 1"
run_plan verify
[ "$RC" -eq 1 ] || fail "confirm-lines round 2 exits 1"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "confirm LINES exits 1"
expect_verdict "TKT tkt-plan LINES n=* out=*confirm-out.md log=*" "confirm LINES"
run_plan verify
[ "$RC" -eq 1 ] || fail "verify after a LINES confirm exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "verify after LINES confirm"
printf 'ok' >"$T/mode"

# --- a Verifier ASK passes through with its digest ---
setup_case ask
rebase_plan
printf 'ask' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "ASK exits 1"
expect_verdict "TKT tkt-plan ASK id=j1 log=*" "ASK passthrough"
grep -q "which design rules the retry?" <<<"$OUT" || fail "ASK digest carries the question"
[ "$(bash "$TKT_STATE" "$S" get verifier_round 2>/dev/null || printf '0')" = "0" ] || fail "ASK counts no round"
printf 'ok' >"$T/mode"

# --- post runs post-plan behind a real plan-gate check ---
setup_case post
run_plan post
[ "$RC" -eq 0 ] || fail "POSTED exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan POSTED urls=*issuecomment-11* log=*" "POSTED"
grep -q "issuecomment-12" <<<"$OUT" || fail "POSTED lists every URL"
grep -q "post|518.*--repo switchyard" "$T/stub.log" || fail "post passes issue and repo to post-plan"
run_plan post --part P3
[ "$RC" -eq 0 ] || fail "--part post exits 0"
grep -q "post|.*--part P3" "$T/stub.log" || fail "--part reaches post-plan"

# --- set stores the plan path and resets the rounds ---
setup_case set
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed round"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "seed confirm"
bash "$TKT_STATE" "$S" set job.verifier-r1 j-old-1 || fail "seed round 1 job"
bash "$TKT_STATE" "$S" set job.verifier-r2 j-old-2 || fail "seed round 2 job"
bash "$TKT_STATE" "$S" set job.confirm j-old-c || fail "seed confirm job"
bash "$TKT_STATE" "$S" set job.lane j-old-lane || fail "seed lane job"
bash "$TKT_STATE" "$S" set job.fix1 j-old-fix1 || fail "seed fix1 job"
bash "$TKT_STATE" "$S" set job.fix2 j-old-fix2 || fail "seed fix2 job"
bash "$TKT_STATE" "$S" set job.fix3 j-old-fix3 || fail "seed fix3 job"
printf '# another plan\n' >"$CDIR/other.md"
{
  printf 'Base: %s\n' "$(cat "$CDIR/base")"
  printf '\n## Files\n\n- `f.txt`\n'
} >"$CDIR/other.md"
run_plan set "$CDIR/other.md"
[ "$RC" -eq 0 ] || fail "SET exits 0"
expect_verdict "TKT tkt-plan SET plan=$CDIR/other.md log=*" "SET"
[ "$(bash "$TKT_STATE" "$S" get plan)" = "$CDIR/other.md" ] || fail "SET stores the plan path"
[ "$(bash "$TKT_STATE" "$S" get pack)" = "$CDIR/run/switchyard-518-pack.md" ] || fail "SET stores the pack path"
grep -q "sweep|.*--plan $CDIR/other.md" "$T/stub.log" || fail "SET refreshes the pack for the plan"
grep -q "sweep|.*--cwd $WT" "$T/stub.log" || fail "SET sweeps the worktree"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "0" ] || fail "SET resets the round counter"
[ -z "$(bash "$TKT_STATE" "$S" get confirmed_for)" ] || fail "SET clears the confirm record"
[ -z "$(bash "$TKT_STATE" "$S" get job.verifier-r1)" ] || fail "SET retires the round 1 job"
[ -z "$(bash "$TKT_STATE" "$S" get job.verifier-r2)" ] || fail "SET retires the round 2 job"
[ -z "$(bash "$TKT_STATE" "$S" get job.confirm)" ] || fail "SET retires the confirm job"
[ -z "$(bash "$TKT_STATE" "$S" get job.lane)" ] || fail "SET retires the lane job"
[ -z "$(bash "$TKT_STATE" "$S" get job.fix1)" ] || fail "SET retires the fix1 job"
[ -z "$(bash "$TKT_STATE" "$S" get job.fix2)" ] || fail "SET retires the fix2 job"
[ -z "$(bash "$TKT_STATE" "$S" get job.fix3)" ] || fail "SET retires the fix3 job"

# --- a re-set of the same plan keeps the rounds and the job slots ---
setup_case reset-same
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed round"
bash "$TKT_STATE" "$S" set job.verifier-r1 j-keep || fail "seed job"
run_plan set "$CDIR/plan.md"
[ "$RC" -eq 0 ] || fail "same-path SET exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan SET plan=$CDIR/plan.md log=*" "same-path SET"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "2" ] || fail "same-path SET keeps the round counter"
[ "$(bash "$TKT_STATE" "$S" get job.verifier-r1)" = "j-keep" ] || fail "same-path SET keeps the job slots"
grep -q "sweep|.*--plan $CDIR/plan.md" "$T/stub.log" || fail "same-path SET still refreshes the pack"
# A verify after two counted rounds, with no confirm, stops before any job.
jobs_before="$(grep -c '^job|' "$T/stub.log")"
run_plan verify
[ "$RC" -eq 1 ] || fail "verify at round 2 exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 log=*" "verify at round 2"
[ "$(grep -c '^job|' "$T/stub.log")" = "$jobs_before" ] || fail "verify at round 2 starts no job"

# --- a backticked Base line is read as the bare SHA ---
setup_case basetick
printf 'Base: `%s`\n\n## Files\n\n- `f.txt`\n' "$(cat "$CDIR/base")" >"$CDIR/tick.md"
run_plan set "$CDIR/tick.md"
[ "$RC" -eq 0 ] || fail "a backticked Base: SET exits 0 (rc=$RC: $(cat "$CDIR/stderr.txt"))"
expect_verdict "TKT tkt-plan SET plan=$CDIR/tick.md log=*" "a backticked Base"
grep -q "sweep|.*--base $(cat "$CDIR/base") --plan $CDIR/tick.md" "$T/stub.log" || fail "a backticked Base: SET sweeps with the bare SHA"

# --- a missing plan key exits 2 and names it ---
setup_case missing-key
grep -v '^plan=' "$S" >"$CDIR/noplan.state"
S="$CDIR/noplan.state"
run_plan verify
[ "$RC" -eq 2 ] || fail "a missing plan key exits 2"
grep -q "plan" "$CDIR/stderr.txt" || fail "a missing plan key names plan"

# --- usage errors exit 2 ---
setup_case usage
run_plan bogus-sub
[ "$RC" -eq 2 ] || fail "an unknown subcommand exits 2"
run_plan verify --bogus
[ "$RC" -eq 2 ] || fail "an unknown flag exits 2"
run_plan confirm
[ "$RC" -eq 2 ] || fail "confirm without --edits exits 2"
run_plan set
[ "$RC" -eq 2 ] || fail "set without a file exits 2"
OUT="$(bash "$TKT" 2>"$T/err-u.txt")"; [ "$?" = "2" ] || fail "no args exits 2"
grep -q "usage" "$T/err-u.txt" || fail "no args prints usage"

# --- a held lock exits 2 naming the pid, and runs nothing ---
setup_case locked
mkdir "$S.lock"
printf '424242\n' >"$S.lock/pid"
run_plan verify
[ "$RC" -eq 2 ] || fail "a held lock exits 2"
grep -q "424242" "$CDIR/stderr.txt" || fail "a held lock names the pid"
rm -rf "$S.lock"

# --- head drift exits 3 naming the stored head and the worktree HEAD ---
setup_case drift
H="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head 0000000000000000000000000000000000000000 || fail "set fake head"
run_plan verify
[ "$RC" -eq 3 ] || fail "drift exits 3"
grep -q "0000000000000000000000000000000000000000" "$CDIR/stderr.txt" || fail "drift names the stored head"
grep -q "$H" "$CDIR/stderr.txt" || fail "drift names the worktree HEAD"
grep -q "tkt-state" "$CDIR/stderr.txt" || fail "drift names tkt-state"
grep -q "set head" "$CDIR/stderr.txt" || fail "drift names set head"

# --- verify with no --model resolves model.verifier through the real tkt-job ---
mkdir -p "$T/realbin" "$T/home/.agents/skills/planning/briefs"
for b in plan-check plan-gate post-plan plan-sweep; do ln -s "$T/bin/$b" "$T/realbin/$b" || fail "symlink $b"; done
ln -s "$REAL_BIN/tkt-job" "$T/realbin/tkt-job" || fail "symlink real tkt-job"
ln -s "$REAL_BIN/tkt-state" "$T/realbin/tkt-state" || fail "symlink real tkt-state"
ln -s "$REAL_BIN/fill-brief" "$T/realbin/fill-brief" || fail "symlink real fill-brief"
ln -s "$REAL_BIN/lib" "$T/realbin/lib" || fail "symlink real lib"
ln -s "$REAL_BIN/job-record" "$T/realbin/job-record" || fail "symlink real job-record"
cat >"$T/realbin/delegate" <<EOF
#!/usr/bin/env bash
set -uo pipefail
printf 'delegate|%s\n' "\$*" >>"$T/stub.log"
cmd="\${1:-}"; shift || true
case "\$cmd" in
  run)
    model=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --model) model="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'run|model=%s\n' "\$model" >>"$T/stub.log"
    mkdir -p "\$TMPDIR/delegate-jobs"
    printf '%s' '{"result":{"status":"DONE","text":"PLAN OK\\nholds: every check ran\\n","changeSet":{}}}' >"\$TMPDIR/delegate-jobs/rmodel1.json"
    printf 'rmodel1\n'
    ;;
  watch) exit 0 ;;
  *) echo "stub delegate: unknown command \$cmd" >&2; exit 2 ;;
esac
EOF
chmod +x "$T/realbin/delegate"
printf 'Verify the plan.\n\nPlan: __PLAN__\nBase: __BASE__\n' >"$T/home/.agents/skills/planning/briefs/verifier.md"

setup_case realmodel
rebase_plan
TKT_BIN="$T/realbin" run_plan verify
[ "$RC" -eq 0 ] || fail "real tkt-job PLAN-OK exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "real tkt-job"
grep -q "run|model=test-model" "$T/stub.log" || fail "real tkt-job dispatches with model.verifier"
[ "$(bash "$TKT_STATE" "$S" get job.verifier-r1)" = "rmodel1" ] || fail "real tkt-job stores the round 1 job id"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "1" ] || fail "real tkt-job counts the round"

# --- verify without model.verifier and without --model names the missing key ---
grep -v '^model.verifier=' "$S" >"$CDIR/nomodel.state"
S="$CDIR/nomodel.state"
TKT_BIN="$T/realbin" run_plan verify
[ "$RC" -eq 2 ] || fail "a missing model.verifier exits 2"
grep -q "model.verifier" "$CDIR/stderr.txt" || fail "a missing model.verifier names the key"
[ "$(grep -c '^run|' "$T/stub.log")" -eq 1 ] || fail "a missing model.verifier dispatches no job"

# --- a stale verifier job id never replays: verify resets the round slot ---
setup_case verifier-stale
rebase_plan
printf 'ok' >"$T/pcmode"
bash "$TKT_STATE" "$S" set job.verifier-r1 j-stale || fail "seed stale job"
runs_before="$(grep -c '^run|' "$T/stub.log")"
TKT_BIN="$T/realbin" run_plan verify
[ "$RC" -eq 0 ] || fail "stale verify exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "stale verify"
[ "$(grep -c '^run|' "$T/stub.log")" = "$((runs_before + 1))" ] || fail "stale verify dispatches a fresh job"
[ "$(bash "$TKT_STATE" "$S" get job.verifier-r1)" != "j-stale" ] || fail "stale verify retires the stale job id"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "1" ] || fail "stale verify counts the round"

# --- DONE_WITH_CONCERNS: the report is the product, so the round stands ---
setup_case concerns
rebase_plan
printf 'ok' >"$T/pcmode"
printf 'concerns' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "CONCERNS verify exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "CONCERNS verify"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "1" ] || fail "CONCERNS verify counts the round"

# --- stray stderr lines before the verdict do not hide DONE_WITH_CONCERNS ---
setup_case concerns-noise
rebase_plan
printf 'ok' >"$T/pcmode"
printf 'concerns-noise' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "concerns-noise verify exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "concerns-noise verify"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "1" ] || fail "concerns-noise verify counts the round"

# --- BLOCKED still fails the verify, and the round is not counted ---
setup_case blocked
rebase_plan
printf 'blocked' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "BLOCKED verify exits 1"
expect_verdict "TKT tkt-plan BLOCKED id=j1 log=*" "BLOCKED verify"
[ "$(bash "$TKT_STATE" "$S" get verifier_round 2>/dev/null)" != "1" ] || fail "BLOCKED verify must not count the round"

# --- replan clears the stale slots, keeping verifier counts ---
setup_case replan
bash "$TKT_STATE" "$S" set round 2 || fail "seed round"
bash "$TKT_STATE" "$S" set job.lane j-lane || fail "seed lane"
bash "$TKT_STATE" "$S" set job.fix1 j-fix1 || fail "seed fix1"
bash "$TKT_STATE" "$S" set job.fix2 j-fix2 || fail "seed fix2"
bash "$TKT_STATE" "$S" set job.fix3 j-fix3 || fail "seed fix3"
bash "$TKT_STATE" "$S" set job.preflight j-pre || fail "seed preflight"
bash "$TKT_STATE" "$S" set findings /tmp/old-findings.md || fail "seed findings"
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed verifier_round"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "seed confirmed_for"
bash "$TKT_STATE" "$S" set job.verifier-r1 j-v1 || fail "seed verifier job"
run_plan replan
[ "$RC" -eq 0 ] || fail "replan exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan REPLAN cleared=round,job.lane,job.fix1,job.fix2,job.fix3,job.preflight,findings log=*" "replan"
[ -z "$(bash "$TKT_STATE" "$S" get round 2>/dev/null || true)" ] || fail "replan clears round"
[ -z "$(bash "$TKT_STATE" "$S" get job.lane 2>/dev/null || true)" ] || fail "replan clears job.lane"
[ -z "$(bash "$TKT_STATE" "$S" get job.fix1 2>/dev/null || true)" ] || fail "replan clears job.fix1"
[ -z "$(bash "$TKT_STATE" "$S" get job.fix2 2>/dev/null || true)" ] || fail "replan clears job.fix2"
[ -z "$(bash "$TKT_STATE" "$S" get job.fix3 2>/dev/null || true)" ] || fail "replan clears job.fix3"
[ -z "$(bash "$TKT_STATE" "$S" get job.preflight 2>/dev/null || true)" ] || fail "replan clears job.preflight"
[ -z "$(bash "$TKT_STATE" "$S" get findings 2>/dev/null || true)" ] || fail "replan clears findings"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "2" ] || fail "replan keeps verifier_round"
[ "$(bash "$TKT_STATE" "$S" get confirmed_for)" = "2" ] || fail "replan keeps confirmed_for"
[ "$(bash "$TKT_STATE" "$S" get job.verifier-r1)" = "j-v1" ] || fail "replan keeps verifier jobs"
run_plan replan
[ "$RC" -eq 0 ] || fail "replan twice exits 0"
run_plan replan extra
[ "$RC" -eq 2 ] || fail "replan with an argument exits 2"
setup_case replan-noplan
bash "$TKT_STATE" "$S" set job.lane j-keep || fail "seed lane"
bash "$TKT_STATE" "$S" set round 2 || fail "seed round"
grep -v '^plan=' "$S" >"$CDIR/noplan.state"
S="$CDIR/noplan.state"
run_plan replan
[ "$RC" -eq 2 ] || fail "replan without plan exits 2"
grep -q "missing key: plan" "$CDIR/stderr.txt" || fail "replan without plan names plan"
[ "$(bash "$TKT_STATE" "$S" get job.lane)" = "j-keep" ] || fail "replan without plan leaves lane untouched"

# --- drift exemption from the recorded verified_base ---
setup_case drift-a
rebase_plan
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "drift-a exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "1" ] || fail "drift-a counts round 1"
[ "$(bash "$TKT_STATE" "$S" get verified_base)" = "$(cat "$CDIR/base")" ] || fail "drift-a records verified_base"

setup_case drift-b
rebase_plan
A="$(cat "$CDIR/base")"
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed round"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "seed confirm"
bash "$TKT_STATE" "$S" set verified_base "$A" || fail "seed verified_base"
wcommit "$WT" f.txt v3
git -C "$WT" update-ref refs/remotes/origin/main HEAD
rebase_plan
B="$(cat "$CDIR/base")"
[ "$A" != "$B" ] || fail "drift-b needs a new base"
printf 'ok' >"$T/mode"
jobs_before="$(grep -c '^job|' "$T/stub.log" || true)"
run_plan verify
[ "$RC" -eq 0 ] || fail "drift-b exempt exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "drift-b"
grep -q "slot=verifier-r3-drift" "$T/stub.log" || fail "drift-b uses the drift slot"
grep -q "verifier-out-r3-drift.md" "$T/stub.log" || fail "drift-b writes the drift report"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "2" ] || fail "drift-b leaves verifier_round"
[ "$(bash "$TKT_STATE" "$S" get confirmed_for)" = "2" ] || fail "drift-b leaves confirmed_for"
[ "$(bash "$TKT_STATE" "$S" get verified_base)" = "$B" ] || fail "drift-b updates verified_base"
# Contract: skills/planning/SKILL.md step 3: an exempt verify dispatches one drift job.
[ "$(grep -c '^job|' "$T/stub.log")" = "$((jobs_before + 1))" ] || fail "drift-b starts one job"
jobs_drift="$(grep -c '^job|' "$T/stub.log")"
run_plan verify
[ "$RC" -eq 1 ] || fail "drift-d spent exemption exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "drift-d spent"
# Contract: skills/planning/SKILL.md step 3: a ROUND-LIMIT verify dispatches no job.
[ "$(grep -c '^job|' "$T/stub.log")" = "$jobs_drift" ] || fail "drift-d starts no job"

setup_case drift-c
rebase_plan
A="$(cat "$CDIR/base")"
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed round"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "seed confirm"
bash "$TKT_STATE" "$S" set verified_base "$A" || fail "seed verified_base"
printf 'ok' >"$T/mode"
jobs_before="$(grep -c '^job|' "$T/stub.log" || true)"
run_plan verify
[ "$RC" -eq 1 ] || fail "drift-c exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "drift-c no change"
# Contract: skills/planning/SKILL.md step 3: a ROUND-LIMIT verify dispatches no job.
[ "$(grep -c '^job|' "$T/stub.log")" = "$jobs_before" ] || fail "drift-c starts no job"

setup_case drift-c2
rebase_plan
A="$(cat "$CDIR/base")"
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed round"
bash "$TKT_STATE" "$S" set verified_base "$A" || fail "seed verified_base"
wcommit "$WT" g.txt other
git -C "$WT" update-ref refs/remotes/origin/main HEAD
rebase_plan
printf 'ok' >"$T/mode"
jobs_before="$(grep -c '^job|' "$T/stub.log" || true)"
run_plan verify
[ "$RC" -eq 1 ] || fail "drift-c2 exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 log=*" "drift-c2 same-Files edit"
# Contract: skills/planning/SKILL.md step 3: a ROUND-LIMIT verify dispatches no job.
[ "$(grep -c '^job|' "$T/stub.log")" = "$jobs_before" ] || fail "drift-c2 starts no job"

setup_case drift-e
rebase_plan
A="$(cat "$CDIR/base")"
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed round"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "seed confirm"
bash "$TKT_STATE" "$S" set verified_base "$A" || fail "seed verified_base"
wcommit "$WT" f.txt v3
git -C "$WT" update-ref refs/remotes/origin/main HEAD
rebase_plan
B="$(cat "$CDIR/base")"
printf 'ask' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "drift-e ask exits 1"
expect_verdict "TKT tkt-plan ASK id=j1 log=*" "drift-e ask"
[ "$(bash "$TKT_STATE" "$S" get verified_base)" = "$A" ] || fail "drift-e leaves verified_base"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "2" ] || fail "drift-e leaves verifier_round"
[ "$(bash "$TKT_STATE" "$S" get confirmed_for)" = "2" ] || fail "drift-e leaves confirmed_for"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "drift-e retry exits 0"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "drift-e retry exempt"
grep -q "slot=verifier-r3-drift" "$T/stub.log" || fail "drift-e retry uses the drift slot"

setup_case drift-f
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 1 || fail "seed round 1"
wcommit "$WT" f.txt v3
git -C "$WT" update-ref refs/remotes/origin/main HEAD
rebase_plan
B="$(cat "$CDIR/base")"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "drift-f exits 0"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "2" ] || fail "drift-f counts the round"
grep -q "slot=verifier-r2" "$T/stub.log" || fail "drift-f uses the counted slot"
grep -q "slot=verifier-r2-drift" "$T/stub.log" && fail "drift-f must not use the drift slot"
[ "$(bash "$TKT_STATE" "$S" get verified_base)" = "$B" ] || fail "drift-f records verified_base"

setup_case drift-err
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed round"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "seed confirm"
bash "$TKT_STATE" "$S" set verified_base deadbeefdeadbeefdeadbeefdeadbeefdeadbeef || fail "seed bogus base"
printf 'ok' >"$T/mode"
jobs_before="$(grep -c '^job|' "$T/stub.log" || true)"
run_plan verify
[ "$RC" -eq 1 ] || fail "drift-err exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "drift-err git error"
# Contract: skills/planning/SKILL.md step 3: a ROUND-LIMIT verify dispatches no job.
[ "$(grep -c '^job|' "$T/stub.log")" = "$jobs_before" ] || fail "drift-err starts no job"

setup_case drift-g
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed round"
VBASE="$(cat "$CDIR/base")"
bash "$TKT_STATE" "$S" set verified_base "$VBASE" || fail "seed verified_base"
run_plan set "$CDIR/plan.md"
[ "$RC" -eq 0 ] || fail "drift-g same-path set exits 0"
[ "$(bash "$TKT_STATE" "$S" get verified_base)" = "$VBASE" ] || fail "drift-g same-path keeps verified_base"
printf '# another plan\n' >"$CDIR/other2.md"
{
  printf 'Base: %s\n' "$VBASE"
  printf '\n## Files\n\n- `f.txt`\n'
} >"$CDIR/other2.md"
run_plan set "$CDIR/other2.md"
[ "$RC" -eq 0 ] || fail "drift-g new-path set exits 0"
[ -z "$(bash "$TKT_STATE" "$S" get verified_base 2>/dev/null || true)" ] || fail "drift-g new-path clears verified_base"

echo "tkt-plan: all cases passed"

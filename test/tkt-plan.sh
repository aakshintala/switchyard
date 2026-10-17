#!/usr/bin/env bash
# Tests for bin/tkt-plan: one Verifier round, post and plan-path set per call.
# Stub plan-check, post-plan and tkt-job on a temp TKT_BIN; a symlink there
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
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "PLAN-OK exits 0"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "PLAN-OK"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "2" ] || fail "PLAN-OK counts the round"
grep -q "verifier.md" "$T/stub.log" || fail "verify fills the verifier brief"
run_plan verify
[ "$RC" -eq 1 ] || fail "ROUND-LIMIT exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 log=*" "ROUND-LIMIT"
[ "$(grep -c '^job|' "$T/stub.log")" -eq 2 ] || fail "ROUND-LIMIT starts no third job"

# --- confirm records the edits, and the third round proceeds ---
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "confirm PLAN-OK exits 0"
expect_verdict "TKT tkt-plan PLAN-OK out=*confirm-out.md log=*" "confirm"
[ "$(bash "$TKT_STATE" "$S" get confirmed_for)" = "2" ] || fail "confirm records the round it covers"
grep -q "slot=confirm" "$T/stub.log" || fail "confirm runs the confirm slot"
grep -q "confirm.md" "$T/stub.log" || fail "confirm fills the confirm brief"
run_plan verify
[ "$RC" -eq 0 ] || fail "a confirmed third round exits 0"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "confirmed third round"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "3" ] || fail "the third round counts"
run_plan verify
[ "$RC" -eq 1 ] || fail "a fourth round exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=3 log=*" "fourth round"

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
printf '# another plan\n' >"$CDIR/other.md"
run_plan set "$CDIR/other.md"
[ "$RC" -eq 0 ] || fail "SET exits 0"
expect_verdict "TKT tkt-plan SET plan=$CDIR/other.md log=*" "SET"
[ "$(bash "$TKT_STATE" "$S" get plan)" = "$CDIR/other.md" ] || fail "SET stores the plan path"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "0" ] || fail "SET resets the round counter"

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

echo "tkt-plan: all cases passed"

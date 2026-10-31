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
# finding lines, exit 0), "ask" (no report, exit 1) or "ask-report" (with
# report=, exit 1). Writes --out-file.
printf 'ok' >"$T/mode"
cat >"$T/bin/tkt-job" <<EOF
#!/usr/bin/env bash
set -uo pipefail
state="\$1"
slot=""; out=""; rest=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --slot) slot="\$2"; shift 2 ;;
    --template) tmpl="\$2"; shift 2 ;;
    --out-file) out="\$2"; shift 2 ;;
    *) rest="\$rest \$1"; shift ;;
  esac
done
printf 'job|slot=%s|tmpl=%s|out=%s|rest=%s\n' "\$slot" "\$tmpl" "\$out" "\$rest" >>"$T/stub.log"
if [ "\$slot" = confirm ]; then
  confirm_job="\$(bash "$REAL_BIN/tkt-state" "\$state" get job.confirm 2>/dev/null || true)"
  printf 'confirm-job|%s\n' "\$confirm_job" >>"$T/stub.log"
fi
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
  ask-report)
    echo "TKT tkt-job ASK id=j1 report=which design rules the retry? log=x"
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

# Stub plan-sweep: prints one progress line on stderr, then the PACK line for
# --out; with sweepmode=fail it prints an unresolved line on stdout and exits 1.
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
printf 'plan-sweep: stub progress\n' >&2
if [ "\$(cat "$T/sweepmode" 2>/dev/null || printf 'ok')" = fail ]; then
  printf 'unresolved symbol: x (line 3)\n'
  exit 1
fi
printf 'PACK %s symbols=0 files=0 outside=0\n' "\$out"
EOF
chmod +x "$T/bin/plan-sweep"

# Stub gh on PATH (tkt-plan resolves gh from PATH, not TKT_BIN). Each call is
# logged as gh|<args>. The mode file holds: ok; nonl (body has no trailing
# newline); nocomments; empty (both calls print nothing); blank (body is only
# whitespace); fail (both calls exit 1); comments-fail (body ok, --comments exits 1).
mkdir -p "$T/ghbin"
printf 'ok' >"$T/ghmode"
: >"$T/gh.log"
cat >"$T/ghbin/gh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
printf 'gh|%s\n' "\$*" >>"$T/gh.log"
mode="\$(cat "$T/ghmode")"
comments=0
for a in "\$@"; do [ "\$a" = --comments ] && comments=1; done
case "\$mode:\$comments" in
  ok:0) printf 'BODY-TEXT-791\n' ;;
  ok:1) printf 'COMMENT-TEXT-791\n' ;;
  nonl:0) printf 'BODY-TEXT-791' ;;
  nonl:1) printf 'COMMENT-TEXT-791\n' ;;
  nocomments:0) printf 'BODY-TEXT-791\n' ;;
  nocomments:1|empty:*|blank:1) ;;
  blank:0) printf '   \n' ;;
  comments-fail:0) printf 'BODY-TEXT-791\n' ;;
  comments-fail:1) echo "gh: comments unavailable" >&2; exit 1 ;;
  fail:*) echo "gh: could not reach the API" >&2; exit 1 ;;
  *) echo "gh stub: unknown mode \$mode" >&2; exit 2 ;;
esac
EOF
chmod +x "$T/ghbin/gh"
export PATH="$T/ghbin:$PATH"

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
  printf 'ok' >"$T/ghmode"
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

# --- every ROUND-LIMIT prints open lines from the latest report ---
setup_case round-open-lines
rebase_plan
printf 'lines' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "round-open-lines first verify exits 1"
run_plan verify
[ "$RC" -eq 1 ] || fail "round-open-lines second verify exits 1"
jobs_before="$(grep -c '^job|' "$T/stub.log")"
run_plan verify
[ "$RC" -eq 1 ] || fail "round-open-lines limit exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 log=*" "round-open-lines"
grep -qx '1. Rulings miss a contradiction in bin/x' <<<"$OUT" || fail "ROUND-LIMIT keeps the first open line"
grep -qx '3. Gate skips package y' <<<"$OUT" || fail "ROUND-LIMIT keeps the final open line"
[ "$(grep -c '^job|' "$T/stub.log")" = "$jobs_before" ] || fail "round-open-lines limit starts no job"

setup_case round-no-report
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "round-no-report seed round"
run_plan verify
[ "$RC" -eq 1 ] || fail "round-no-report limit exits 1"
grep -qx 'none (no report: round 2 ended without one)' <<<"$OUT" || fail "missing report names the unfinished round"

setup_case round-empty-report
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "round-empty-report seed round"
: >"$CDIR/empty.md"
bash "$TKT_STATE" "$S" set last_report "$CDIR/empty.md" || fail "round-empty-report seed report"
run_plan verify
[ "$RC" -eq 1 ] || fail "round-empty-report limit exits 1"
grep -qx 'none' <<<"$OUT" || fail "an empty report prints none"

setup_case round-plan-ok-prefix
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "round-plan-ok-prefix seed round"
printf 'PLAN OK with trailing text\nopen finding\n' >"$CDIR/report.md"
bash "$TKT_STATE" "$S" set last_report "$CDIR/report.md" || fail "round-plan-ok-prefix seed report"
run_plan verify
[ "$RC" -eq 1 ] || fail "round-plan-ok-prefix limit exits 1"
grep -qx 'PLAN OK with trailing text' <<<"$OUT" || fail "PLAN OK with trailing text is not treated as success"
grep -qx 'open finding' <<<"$OUT" || fail "trailing-text report keeps its open lines"

setup_case round-stale-confirm-report
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "round-stale-confirm-report seed round"
printf '2. Current Verifier finding\n' >"$CDIR/verifier.md"
printf 'stale confirm finding\n' >"$CDIR/run/switchyard-518-confirm-out.md"
bash "$TKT_STATE" "$S" set last_report "$CDIR/verifier.md" || fail "round-stale-confirm-report seed latest report"
run_plan verify
[ "$RC" -eq 1 ] || fail "round-stale-confirm-report limit exits 1"
grep -qx '2. Current Verifier finding' <<<"$OUT" || fail "ROUND-LIMIT uses last_report"
grep -q 'stale confirm finding' <<<"$OUT" && fail "ROUND-LIMIT ignores a stale confirm report"

setup_case round-report-cap
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "round-report-cap seed round"
: >"$CDIR/report.md"
for n in $(seq 1 40); do printf 'line-%s\n' "$n" >>"$CDIR/report.md"; done
bash "$TKT_STATE" "$S" set last_report "$CDIR/report.md" || fail "round-report-cap seed report"
run_plan verify
[ "$RC" -eq 1 ] || fail "round-report-cap limit exits 1"
[ "$(grep -c '^line-' <<<"$OUT")" -eq 38 ] || fail "ROUND-LIMIT caps report lines at 38"
grep -qx 'line-38' <<<"$OUT" || fail "ROUND-LIMIT includes the 38th report line"
grep -qx 'line-39' <<<"$OUT" && fail "ROUND-LIMIT omits report lines after 38"

setup_case round-ok-reports
rebase_plan
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "round-ok-reports first verify exits 0"
run_plan verify
[ "$RC" -eq 0 ] || fail "round-ok-reports second verify exits 0"
run_plan verify
[ "$RC" -eq 1 ] || fail "round-ok-reports limit exits 1"
grep -qx 'none' <<<"$OUT" || fail "a PLAN OK report has no open lines"

setup_case round-confirm-report
rebase_plan
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "round-confirm-report verify 1 exits 0"
run_plan verify
[ "$RC" -eq 0 ] || fail "round-confirm-report verify 2 exits 0"
printf 'lines' >"$T/mode"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "round-confirm-report confirm exits 1"
run_plan verify
[ "$RC" -eq 1 ] || fail "round-confirm-report verify limit exits 1"
grep -qx '3. Gate skips package y' <<<"$OUT" || fail "verify ROUND-LIMIT uses the confirm report"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "round-confirm-report second confirm exits 1"
grep -qx '3. Gate skips package y' <<<"$OUT" || fail "confirm ROUND-LIMIT uses the confirm report"

setup_case round-confirm-ok
rebase_plan
printf 'lines' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "round-confirm-ok verify 1 exits 1"
run_plan verify
[ "$RC" -eq 1 ] || fail "round-confirm-ok verify 2 exits 1"
printf 'ok' >"$T/mode"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "round-confirm-ok confirm exits 0"
run_plan verify
[ "$RC" -eq 1 ] || fail "round-confirm-ok verify limit exits 1"
grep -qx 'none' <<<"$OUT" || fail "latest PLAN OK confirm report replaces prior lines"

# --- a grant records one extra confirm round and validates its inputs ---
setup_case grant-valid
rebase_plan
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "grant-valid seed confirm"
run_plan grant-round --by switchyard --comment 1234
[ "$RC" -eq 0 ] || fail "valid grant exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan SET grant=switchyard:1234 log=*" "valid grant"
[ "$(bash "$TKT_STATE" "$S" get granted_by)" = "switchyard" ] || fail "valid grant records the author"
[ "$(bash "$TKT_STATE" "$S" get granted_comment)" = "1234" ] || fail "valid grant records the comment"
[ -z "$(bash "$TKT_STATE" "$S" get granted_used 2>/dev/null || true)" ] || fail "valid grant starts unused"

setup_case grant-invalid
rebase_plan
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "grant-invalid seed confirm"
bash "$TKT_STATE" "$S" set granted_by "" || fail "grant-invalid seed empty grant"
grant_usage_case() {
  local label="$1"
  shift
  run_plan grant-round "$@"
  [ "$RC" -eq 2 ] || fail "$label exits 2 (rc=$RC)"
  grep -q '^usage: tkt-plan' "$CDIR/stderr.txt" || fail "$label prints usage"
  [ -z "$(bash "$TKT_STATE" "$S" get granted_by 2>/dev/null || true)" ] || fail "$label leaves granted_by unchanged"
}
grant_usage_case 'missing --by' --comment 1234
grant_usage_case 'missing --comment' --by switchyard
grant_usage_case 'empty --by' --by '' --comment 1234
grant_usage_case 'empty --comment' --by switchyard --comment ''
grant_usage_case 'space in --by' --by 'a b' --comment 1234
grant_usage_case 'space in --comment' --by switchyard --comment 'x y'
grant_usage_case 'tab in --comment' --by switchyard --comment $'x\ty'
grant_usage_case 'unknown flag' --by switchyard --comment 1234 --other
grant_usage_case 'stray argument' --by switchyard --comment 1234 extra

setup_case grant-pending
rebase_plan
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "grant-pending seed confirm"
bash "$TKT_STATE" "$S" set granted_by switchyard || fail "grant-pending seed grant author"
bash "$TKT_STATE" "$S" set granted_comment 1234 || fail "grant-pending seed grant comment"
run_plan grant-round --by switchyard --comment 5678
[ "$RC" -eq 2 ] || fail "second pending grant exits 2"
grep -q 'switchyard:1234' "$CDIR/stderr.txt" || fail "pending grant error names the existing grant"
[ "$(bash "$TKT_STATE" "$S" get granted_by)" = "switchyard" ] || fail "pending grant keeps the first author"
[ "$(bash "$TKT_STATE" "$S" get granted_comment)" = "1234" ] || fail "pending grant keeps the first comment"

setup_case grant-replace
rebase_plan
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "grant-replace seed confirm"
bash "$TKT_STATE" "$S" set granted_by old-grant || fail "grant-replace seed old grant author"
bash "$TKT_STATE" "$S" set granted_comment 99 || fail "grant-replace seed old grant comment"
bash "$TKT_STATE" "$S" set granted_used 1 || fail "grant-replace seed used"
run_plan grant-round --by 'switchyard:bot' --comment 'abc:def'
[ "$RC" -eq 0 ] || fail "used grant can be replaced (rc=$RC)"
[ "$(bash "$TKT_STATE" "$S" get granted_by)" = "switchyard:bot" ] || fail "replacement preserves colons in the author"
[ "$(bash "$TKT_STATE" "$S" get granted_comment)" = "abc:def" ] || fail "replacement preserves colons in the comment"
[ -z "$(bash "$TKT_STATE" "$S" get granted_used 2>/dev/null || true)" ] || fail "replacement clears used state"

setup_case grant-before-confirm
rebase_plan
bash "$TKT_STATE" "$S" set granted_by "" || fail "grant-before-confirm seed empty grant"
run_plan grant-round --by switchyard --comment 1234
[ "$RC" -eq 2 ] || fail "grant before confirm exits 2"
grep -q 'tkt-plan: no limit reached: the confirm round is still open' "$CDIR/stderr.txt" || fail "grant before confirm explains the open confirm round"
[ -z "$(bash "$TKT_STATE" "$S" get granted_by 2>/dev/null || true)" ] || fail "grant before confirm leaves grant state unchanged"

# --- a granted confirm bypasses only the confirm block, once ---
setup_case grant-extra
rebase_plan
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "grant-extra verify 1 exits 0"
run_plan verify
[ "$RC" -eq 0 ] || fail "grant-extra verify 2 exits 0"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "grant-extra initial confirm exits 0"
jobs_before="$(grep -c '^job|' "$T/stub.log")"
run_plan verify
[ "$RC" -eq 1 ] || fail "grant-extra verify before grant exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "verify before grant"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "grant-extra confirm before grant exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT confirm=done log=*" "confirm before grant"
[ "$(grep -c '^job|' "$T/stub.log")" = "$jobs_before" ] || fail "limits before grant start no job"
run_plan grant-round --by switchyard --comment 1234
[ "$RC" -eq 0 ] || fail "grant-extra grant exits 0"
run_plan verify
[ "$RC" -eq 1 ] || fail "pending grant does not unlock verify"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "verify with pending grant"
[ -z "$(bash "$TKT_STATE" "$S" get granted_used 2>/dev/null || true)" ] || fail "verify does not consume the pending grant"
[ "$(grep -c '^job|' "$T/stub.log")" = "$jobs_before" ] || fail "verify with pending grant starts no job"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "granted confirm exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
[ "$(bash "$TKT_STATE" "$S" get granted_used)" = "1" ] || fail "granted confirm consumes the grant"
[ "$(grep -c '^job|' "$T/stub.log")" = "$((jobs_before + 1))" ] || fail "granted confirm dispatches exactly one job"
grep -q '^job|slot=confirm|' "$T/stub.log" || fail "granted confirm uses the confirm slot"
run_plan verify
[ "$RC" -eq 1 ] || fail "verify after granted confirm exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "verify after granted confirm"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "confirm after granted confirm exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT confirm=done log=*" "confirm after granted confirm"
[ "$(grep -c '^job|' "$T/stub.log")" = "$((jobs_before + 1))" ] || fail "limits after granted confirm start no job"

setup_case grant-ask
rebase_plan
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "grant-ask seed confirm"
run_plan grant-round --by switchyard --comment ask
[ "$RC" -eq 0 ] || fail "grant-ask grant exits 0"
printf 'ask' >"$T/mode"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "granted ASK exits 1"
expect_verdict "TKT tkt-plan ASK id=j1 log=*" "granted ASK"
[ -z "$(bash "$TKT_STATE" "$S" get granted_used 2>/dev/null || true)" ] || fail "ASK does not consume the grant"
printf 'ok' >"$T/mode"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "granted confirm retry exits 0"
[ "$(bash "$TKT_STATE" "$S" get granted_used)" = "1" ] || fail "successful retry consumes the grant"

setup_case grant-lines
rebase_plan
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "grant-lines seed confirm"
run_plan grant-round --by switchyard --comment lines
[ "$RC" -eq 0 ] || fail "grant-lines grant exits 0"
printf 'lines' >"$T/mode"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "LINES granted confirm exits 1"
expect_verdict "TKT tkt-plan LINES n=3 out=*confirm-out.md log=*" "LINES granted confirm"
[ "$(bash "$TKT_STATE" "$S" get granted_used)" = "1" ] || fail "LINES granted confirm consumes the grant"

setup_case grant-reset-job
rebase_plan
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "grant-reset-job seed confirm"
bash "$TKT_STATE" "$S" set job.confirm j-old-confirm || fail "grant-reset-job seed old job"
run_plan grant-round --by switchyard --comment reset
[ "$RC" -eq 0 ] || fail "grant-reset-job grant exits 0"
printf 'ok' >"$T/mode"
jobs_before="$(grep -c '^job|' "$T/stub.log")"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "grant-reset-job confirm exits 0"
[ "$(grep -c '^job|' "$T/stub.log")" = "$((jobs_before + 1))" ] || fail "granted confirm starts a fresh job"
[ "$(grep '^confirm-job|' "$T/stub.log" | tail -n 1)" = 'confirm-job|' ] || fail "stored confirm job is cleared before dispatch"
[ "$(bash "$TKT_STATE" "$S" get job.confirm 2>/dev/null || true)" != "j-old-confirm" ] || fail "granted confirm retires the stored job id"

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

# --- two Verifier ASKs count the rounds, then the limit stops the third ---
setup_case ask
rebase_plan
jobs_before="$(grep -c '^job|' "$T/stub.log" || true)"
printf 'ask' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "ASK exits 1"
expect_verdict "TKT tkt-plan ASK id=j1 log=*" "ASK passthrough"
grep -q "which design rules the retry?" <<<"$OUT" || fail "ASK digest carries the question"
# Contract: docs/agents/workflow.md:5-6: each non-drift-exempt ASK consumes its round.
[ "$(bash "$TKT_STATE" "$S" get verifier_round 2>/dev/null || printf '0')" = "1" ] || fail "first ASK counts round 1"
grep -q "slot=verifier-r1" "$T/stub.log" || fail "first ASK uses slot verifier-r1"
printf 'ask-report' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "second ASK exits 1"
expect_verdict "TKT tkt-plan ASK id=j1 report=* log=*" "second ASK passthrough"
grep -q "which design rules the retry?" <<<"$OUT" || fail "second ASK digest carries the question"
# Contract: docs/agents/workflow.md:5-6: a second ASK is round 2.
[ "$(bash "$TKT_STATE" "$S" get verifier_round 2>/dev/null || printf '0')" = "2" ] || fail "second ASK counts round 2"
grep -q "slot=verifier-r2" "$T/stub.log" || fail "second ASK uses slot verifier-r2"
run_plan verify
[ "$RC" -eq 1 ] || fail "ROUND-LIMIT after two ASKs exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 log=*" "ROUND-LIMIT after two ASKs"
# Contract: docs/agents/workflow.md:7: ROUND-LIMIT dispatches no additional job.
[ "$(grep -c '^job|' "$T/stub.log")" = "$((jobs_before + 2))" ] || fail "ROUND-LIMIT after two ASKs starts no third job"
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
bash "$TKT_STATE" "$S" set granted_by switchyard || fail "seed grant author"
bash "$TKT_STATE" "$S" set granted_comment 5555 || fail "seed grant comment"
bash "$TKT_STATE" "$S" set granted_used 1 || fail "seed used grant"
bash "$TKT_STATE" "$S" set last_report "$CDIR/old-report.md" || fail "seed last report"
printf '# another plan\n' >"$CDIR/other.md"
{
  printf 'Base: %s\n' "$(cat "$CDIR/base")"
  printf '\n## Files\n\n- `f.txt`\n'
} >"$CDIR/other.md"
run_plan set "$CDIR/other.md"
[ "$RC" -eq 0 ] || fail "SET exits 0"
expect_verdict "TKT tkt-plan SET plan=$CDIR/other.md log=*" "SET"
grep -q '^plan-sweep: stub progress$' "$CDIR/stderr.txt" || fail "SET replays the sweep progress on stderr"
[ "$(bash "$TKT_STATE" "$S" get plan)" = "$CDIR/other.md" ] || fail "SET stores the plan path"
[ "$(bash "$TKT_STATE" "$S" get pack)" = "$CDIR/run/switchyard-518-pack.md" ] || fail "SET stores the pack path"
grep -q "sweep|.*--plan $CDIR/other.md" "$T/stub.log" || fail "SET refreshes the pack for the plan"
grep -q "sweep|.*--cwd $WT" "$T/stub.log" || fail "SET sweeps the worktree"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "0" ] || fail "SET resets the round counter"
[ -z "$(bash "$TKT_STATE" "$S" get confirmed_for)" ] || fail "SET clears the confirm record"
[ -z "$(bash "$TKT_STATE" "$S" get granted_by 2>/dev/null || true)" ] || fail "SET clears the grant author"
[ -z "$(bash "$TKT_STATE" "$S" get granted_comment 2>/dev/null || true)" ] || fail "SET clears the grant comment"
[ -z "$(bash "$TKT_STATE" "$S" get granted_used 2>/dev/null || true)" ] || fail "SET clears grant usage"
[ -z "$(bash "$TKT_STATE" "$S" get last_report 2>/dev/null || true)" ] || fail "SET clears the last report"
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
bash "$TKT_STATE" "$S" set granted_by switchyard || fail "seed same-path grant author"
bash "$TKT_STATE" "$S" set granted_comment keep || fail "seed same-path grant comment"
bash "$TKT_STATE" "$S" set granted_used 1 || fail "seed same-path grant usage"
bash "$TKT_STATE" "$S" set last_report "$CDIR/kept-report.md" || fail "seed same-path report"
run_plan set "$CDIR/plan.md"
[ "$RC" -eq 0 ] || fail "same-path SET exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan SET plan=$CDIR/plan.md log=*" "same-path SET"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "2" ] || fail "same-path SET keeps the round counter"
[ "$(bash "$TKT_STATE" "$S" get job.verifier-r1)" = "j-keep" ] || fail "same-path SET keeps the job slots"
[ "$(bash "$TKT_STATE" "$S" get granted_by)" = "switchyard" ] || fail "same-path SET keeps the grant author"
[ "$(bash "$TKT_STATE" "$S" get granted_comment)" = "keep" ] || fail "same-path SET keeps the grant comment"
[ "$(bash "$TKT_STATE" "$S" get granted_used)" = "1" ] || fail "same-path SET keeps grant usage"
[ "$(bash "$TKT_STATE" "$S" get last_report)" = "$CDIR/kept-report.md" ] || fail "same-path SET keeps the last report"
grep -q "sweep|.*--plan $CDIR/plan.md" "$T/stub.log" || fail "same-path SET still refreshes the pack"
# A verify after two counted rounds, with no confirm, stops before any job.
jobs_before="$(grep -c '^job|' "$T/stub.log")"
run_plan verify
[ "$RC" -eq 1 ] || fail "verify at round 2 exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 log=*" "verify at round 2"
[ "$(grep -c '^job|' "$T/stub.log")" = "$jobs_before" ] || fail "verify at round 2 starts no job"

# --- a failing sweep prints its stdout once and its progress once ---
setup_case set-fail
{
  printf 'Base: %s\n' "$(cat "$CDIR/base")"
  printf '\n## Files\n\n- `f.txt`\n'
} >"$CDIR/other.md"
printf 'fail' >"$T/sweepmode"
run_plan set "$CDIR/other.md"
[ "$RC" -eq 2 ] || fail "failing SET exits 2"
[ "$(grep -c '^unresolved symbol: x (line 3)$' "$CDIR/stderr.txt")" = 1 ] || fail "failing SET prints the unresolved line exactly once: $(cat "$CDIR/stderr.txt")"
[ "$(grep -c '^plan-sweep: stub progress$' "$CDIR/stderr.txt")" = 1 ] || fail "failing SET prints the progress line once: $(cat "$CDIR/stderr.txt")"
printf 'ok' >"$T/sweepmode"

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
grep -q 'tkt-plan <state> grant-round --by <who> --comment <id>' "$T/err-u.txt" || fail "usage names grant-round"

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
bash "$TKT_STATE" "$S" set granted_by switchyard || fail "seed replan grant author"
bash "$TKT_STATE" "$S" set granted_comment replan || fail "seed replan grant comment"
bash "$TKT_STATE" "$S" set granted_used 1 || fail "seed replan grant usage"
bash "$TKT_STATE" "$S" set last_report "$CDIR/replan-report.md" || fail "seed replan report"
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
[ "$(bash "$TKT_STATE" "$S" get granted_by)" = "switchyard" ] || fail "replan keeps grant author"
[ "$(bash "$TKT_STATE" "$S" get granted_comment)" = "replan" ] || fail "replan keeps grant comment"
[ "$(bash "$TKT_STATE" "$S" get granted_used)" = "1" ] || fail "replan keeps grant usage"
[ "$(bash "$TKT_STATE" "$S" get last_report)" = "$CDIR/replan-report.md" ] || fail "replan keeps last_report"
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
bash "$TKT_STATE" "$S" set granted_by switchyard || fail "seed drift grant author"
bash "$TKT_STATE" "$S" set granted_comment drift || fail "seed drift grant comment"
bash "$TKT_STATE" "$S" set granted_used "" || fail "seed unused drift grant"
bash "$TKT_STATE" "$S" set verified_base "$A" || fail "seed verified_base"
wcommit "$WT" f.txt v3
git -C "$WT" update-ref refs/remotes/origin/main HEAD
rebase_plan
B="$(cat "$CDIR/base")"
[ "$A" != "$B" ] || fail "drift-b needs a new base"
# Drift follows the task paths, so the drift fixture names its Files entry as a task.
{
  printf 'Base: %s\n' "$B"
  printf '\n## Files\n\n- `f.txt`\n\n## Tasks\n\n1. Check `f.txt`.\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
printf 'ok' >"$T/mode"
jobs_before="$(grep -c '^job|' "$T/stub.log" || true)"
run_plan verify
[ "$RC" -eq 0 ] || fail "drift-b exempt exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "drift-b"
[ "$(bash "$TKT_STATE" "$S" get last_report)" = "$CDIR/run/switchyard-518-verifier-out-r3-drift.md" ] || fail "drift-b records the exempt report as last_report"
grep -q "slot=verifier-r3-drift" "$T/stub.log" || fail "drift-b uses the drift slot"
grep -q "verifier-out-r3-drift.md" "$T/stub.log" || fail "drift-b writes the drift report"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "2" ] || fail "drift-b leaves verifier_round"
[ "$(bash "$TKT_STATE" "$S" get confirmed_for)" = "2" ] || fail "drift-b leaves confirmed_for"
[ "$(bash "$TKT_STATE" "$S" get granted_by)" = "switchyard" ] || fail "drift-b keeps the pending grant author"
[ "$(bash "$TKT_STATE" "$S" get granted_comment)" = "drift" ] || fail "drift-b keeps the pending grant comment"
[ -z "$(bash "$TKT_STATE" "$S" get granted_used 2>/dev/null || true)" ] || fail "drift-b leaves the grant unused"
[ "$(bash "$TKT_STATE" "$S" get verified_base)" = "$B" ] || fail "drift-b updates verified_base"
[ -r "$CDIR/run/switchyard-518-verifier-extra-r3-drift.md" ] || fail "drift-b writes the drift extra file"
# Contract: skills/planning/SKILL.md step 3: an exempt verify dispatches one drift job.
[ "$(grep -c '^job|' "$T/stub.log")" = "$((jobs_before + 1))" ] || fail "drift-b starts one job"
jobs_drift="$(grep -c '^job|' "$T/stub.log")"
run_plan verify
[ "$RC" -eq 1 ] || fail "drift-d spent exemption exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "drift-d spent"
# Contract: skills/planning/SKILL.md step 3: a ROUND-LIMIT verify dispatches no job.
[ "$(grep -c '^job|' "$T/stub.log")" = "$jobs_drift" ] || fail "drift-d starts no job"

# Expand task token forms before using them as Git pathspecs: brace alternatives
# and unique suffixes resolve to real paths; glob tokens pass through directly.
resolved_drift_case() {
  local name="$1" changed="$2" other="$3" token="$4" a b
  setup_case "$name"
  mkdir -p "$WT/$(dirname "$changed")"
  wcommit "$WT" "$changed" before
  if [ -n "$other" ]; then
    mkdir -p "$WT/$(dirname "$other")"
    wcommit "$WT" "$other" unchanged
  fi
  git -C "$WT" update-ref refs/remotes/origin/main HEAD
  git -C "$WT" rev-parse HEAD >"$CDIR/base"
  a="$(cat "$CDIR/base")"
  {
    printf 'Base: %s\n' "$a"
    printf '\n## Files\n\n- `%s`\n' "$changed"
    if [ -n "$other" ]; then printf -- '- `%s`\n' "$other"; fi
    printf '\n## Tasks\n\n1. Edit `%s`.\n\n## Gate\n\n`true`\n' "$token"
  } >"$CDIR/plan.md"
  bash "$TKT_STATE" "$S" set verifier_round 2 || fail "$name seed round"
  bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "$name seed confirm"
  bash "$TKT_STATE" "$S" set verified_base "$a" || fail "$name seed verified_base"
  wcommit "$WT" "$changed" after
  git -C "$WT" update-ref refs/remotes/origin/main HEAD
  git -C "$WT" rev-parse HEAD >"$CDIR/base"
  b="$(cat "$CDIR/base")"
  {
    printf 'Base: %s\n' "$b"
    printf '\n## Files\n\n- `%s`\n' "$changed"
    if [ -n "$other" ]; then printf -- '- `%s`\n' "$other"; fi
    printf '\n## Tasks\n\n1. Edit `%s`.\n\n## Gate\n\n`true`\n' "$token"
  } >"$CDIR/plan.md"
  [ "$a" != "$b" ] || fail "$name needs a new base"
  printf 'ok' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 0 ] || fail "$name exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
  expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "$name"
  grep -q "slot=verifier-r3-drift" <<<"$(tail -n 1 "$T/stub.log")" || fail "$name uses the drift slot"
  [ "$(bash "$TKT_STATE" "$S" get verifier_round)" = 2 ] || fail "$name leaves verifier_round"
}

resolved_drift_case drift-j src/later.rs src/lib.rs 'src/{lib,later}.rs'
resolved_drift_case drift-k src/a.rs '' a.rs
resolved_drift_case drift-l src/a.rs '' 'src/*.rs'

# --- drift follows the task paths: a task-path change is drift ---
setup_case drift-i
mkdir -p "$WT/src"
wcommit "$WT" src/a.rs "a1"
wcommit "$WT" src/b.rs "b1"
git -C "$WT" update-ref refs/remotes/origin/main HEAD
git -C "$WT" rev-parse HEAD >"$CDIR/base"
{
  printf 'Base: %s\n' "$(cat "$CDIR/base")"
  printf '\n## Files\n\n- `src/a.rs`\n- `src/b.rs`\n\n## Tasks\n\n1. Edit `src/a.rs`.\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
A="$(cat "$CDIR/base")"
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed round"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "seed confirm"
bash "$TKT_STATE" "$S" set verified_base "$A" || fail "seed verified_base"
wcommit "$WT" src/a.rs "a2"
git -C "$WT" update-ref refs/remotes/origin/main HEAD
git -C "$WT" rev-parse HEAD >"$CDIR/base"
{
  printf 'Base: %s\n' "$(cat "$CDIR/base")"
  printf '\n## Files\n\n- `src/a.rs`\n- `src/b.rs`\n\n## Tasks\n\n1. Edit `src/a.rs`.\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
B="$(cat "$CDIR/base")"
[ "$A" != "$B" ] || fail "drift-i needs a new base"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "drift-i exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "drift-i"
grep -q "slot=verifier-r3-drift" <<<"$(tail -n 1 "$T/stub.log")" || fail "drift-i uses the drift slot"
grep -q "verifier-out-r3-drift.md" <<<"$(tail -n 1 "$T/stub.log")" || fail "drift-i writes the drift report"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "2" ] || fail "drift-i leaves verifier_round"
[ "$(bash "$TKT_STATE" "$S" get confirmed_for)" = "2" ] || fail "drift-i leaves confirmed_for"
[ "$(bash "$TKT_STATE" "$S" get verified_base)" = "$B" ] || fail "drift-i updates verified_base"

# --- a Files change no task names is not drift: the round limit applies ---
setup_case drift-h
mkdir -p "$WT/src"
wcommit "$WT" src/a.rs "a1"
wcommit "$WT" src/b.rs "b1"
git -C "$WT" update-ref refs/remotes/origin/main HEAD
git -C "$WT" rev-parse HEAD >"$CDIR/base"
{
  printf 'Base: %s\n' "$(cat "$CDIR/base")"
  printf '\n## Files\n\n- `src/a.rs`\n- `src/b.rs`\n\n## Tasks\n\n1. Edit `src/a.rs`.\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
A="$(cat "$CDIR/base")"
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed round"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "seed confirm"
bash "$TKT_STATE" "$S" set verified_base "$A" || fail "seed verified_base"
wcommit "$WT" src/b.rs "b2"
git -C "$WT" update-ref refs/remotes/origin/main HEAD
git -C "$WT" rev-parse HEAD >"$CDIR/base"
{
  printf 'Base: %s\n' "$(cat "$CDIR/base")"
  printf '\n## Files\n\n- `src/a.rs`\n- `src/b.rs`\n\n## Tasks\n\n1. Edit `src/a.rs`.\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
B="$(cat "$CDIR/base")"
[ "$A" != "$B" ] || fail "drift-h needs a new base"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "drift-h exits 1 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "drift-h Files outside tasks"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "2" ] || fail "drift-h leaves verifier_round"
[ "$(bash "$TKT_STATE" "$S" get verified_base)" = "$A" ] || fail "drift-h leaves verified_base"

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
# Drift follows the task paths, so the drift fixture names its Files entry as a task.
{
  printf 'Base: %s\n' "$B"
  printf '\n## Files\n\n- `f.txt`\n\n## Tasks\n\n1. Check `f.txt`.\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
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

# --- verify passes the ticket text, body then comments, in its run file ---
setup_case ticket-ok
rebase_plan
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "ticket-ok exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
X="$CDIR/run/switchyard-518-verifier-extra-r1.md"
grep -qF "EXTRA=@$X" "$T/stub.log" || fail "ticket-ok passes the run file as EXTRA"
[ -r "$X" ] || fail "ticket-ok writes the run file"
grep -qx '## Ticket switchyard#518' "$X" || fail "ticket-ok heads the ticket text"
L_BODY="$(grep -n '^BODY-TEXT-791$' "$X" | cut -d: -f1)"
L_COMM="$(grep -n '^COMMENT-TEXT-791$' "$X" | cut -d: -f1)"
[ -n "$L_BODY" ] && [ -n "$L_COMM" ] && [ "$L_BODY" -lt "$L_COMM" ] || fail "ticket-ok puts the body before the comments"
grep -qx '## Ticket comments' "$X" || fail "ticket-ok heads the comments"

# --- a caller --extra file follows the ticket text; the job gets the run file ---
setup_case ticket-extra
rebase_plan
printf 'CALLER-LINE\n' >"$CDIR/caller.md"
run_plan verify --extra "$CDIR/caller.md"
[ "$RC" -eq 0 ] || fail "ticket-extra exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
X="$CDIR/run/switchyard-518-verifier-extra-r1.md"
grep -qF "EXTRA=@$X" "$T/stub.log" || fail "ticket-extra passes the run file as EXTRA"
grep -qF "EXTRA=@$CDIR/caller.md" "$T/stub.log" && fail "ticket-extra never passes the caller file as EXTRA"
L_COMM="$(grep -n '^COMMENT-TEXT-791$' "$X" | cut -d: -f1)"
L_CALL="$(grep -n '^CALLER-LINE$' "$X" | cut -d: -f1)"
[ -n "$L_COMM" ] && [ -n "$L_CALL" ] && [ "$L_COMM" -lt "$L_CALL" ] || fail "ticket-extra puts the caller extra after the ticket"
grep -qx '## Extra' "$X" || fail "ticket-extra heads the caller extra"

# --- --extra wins over state extra ---
setup_case ticket-precedence
rebase_plan
printf 'STATE-LINE\n' >"$CDIR/state-extra.md"
bash "$TKT_STATE" "$S" set extra "$CDIR/state-extra.md" || fail "seed state extra"
printf 'CALLER-LINE\n' >"$CDIR/caller.md"
run_plan verify --extra "$CDIR/caller.md"
[ "$RC" -eq 0 ] || fail "ticket-precedence exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
X="$CDIR/run/switchyard-518-verifier-extra-r1.md"
grep -q '^CALLER-LINE$' "$X" || fail "ticket-precedence uses the --extra file"
grep -q 'STATE-LINE' "$X" && fail "ticket-precedence ignores state extra when --extra is set"

# --- state extra, bare path and @-prefixed, follows the ticket text once ---
setup_case ticket-state-bare
rebase_plan
printf 'STATE-LINE\n' >"$CDIR/state-extra.md"
bash "$TKT_STATE" "$S" set extra "$CDIR/state-extra.md" || fail "seed bare state extra"
run_plan verify
[ "$RC" -eq 0 ] || fail "ticket-state-bare exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
X="$CDIR/run/switchyard-518-verifier-extra-r1.md"
L_COMM="$(grep -n '^COMMENT-TEXT-791$' "$X" | cut -d: -f1)"
L_STATE="$(grep -n '^STATE-LINE$' "$X" | cut -d: -f1)"
[ -n "$L_COMM" ] && [ -n "$L_STATE" ] && [ "$L_COMM" -lt "$L_STATE" ] || fail "ticket-state-bare puts state extra after the ticket"

setup_case ticket-state-at
rebase_plan
printf 'STATE-LINE\n' >"$CDIR/state-extra.md"
bash "$TKT_STATE" "$S" set extra "@$CDIR/state-extra.md" || fail "seed @ state extra"
run_plan verify
[ "$RC" -eq 0 ] || fail "ticket-state-at exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
X="$CDIR/run/switchyard-518-verifier-extra-r1.md"
grep -q '^STATE-LINE$' "$X" || fail "ticket-state-at reads the path after one @"
grep -qF "EXTRA=@@" "$T/stub.log" && fail "ticket-state-at never doubles the @"

# --- no comments: the body alone, and no comments heading ---
setup_case ticket-nocomments
rebase_plan
printf 'nocomments' >"$T/ghmode"
run_plan verify
printf 'ok' >"$T/ghmode"
[ "$RC" -eq 0 ] || fail "ticket-nocomments exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
X="$CDIR/run/switchyard-518-verifier-extra-r1.md"
grep -qx 'BODY-TEXT-791' "$X" || fail "ticket-nocomments keeps the body"
grep -q '## Ticket comments' "$X" && fail "ticket-nocomments omits the comments heading"

# --- a body with no trailing newline still ends its line before the caller extra ---
setup_case ticket-nonl
rebase_plan
printf 'CALLER-LINE' >"$CDIR/caller.md"
printf 'nonl' >"$T/ghmode"
run_plan verify --extra "$CDIR/caller.md"
printf 'ok' >"$T/ghmode"
[ "$RC" -eq 0 ] || fail "ticket-nonl exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
X="$CDIR/run/switchyard-518-verifier-extra-r1.md"
grep -qx '## Extra' "$X" || fail "ticket-nonl starts the extra heading on its own line"
grep -qx 'CALLER-LINE' "$X" || fail "ticket-nonl keeps the caller line whole"

# --- an unreadable caller extra exits 2 before any ticket read ---
setup_case ticket-bad-extra
rebase_plan
gh_before="$(grep -c '^gh|' "$T/gh.log" || true)"
run_plan verify --extra "$CDIR/nope.md"
[ "$RC" -eq 2 ] || fail "ticket-bad-extra exits 2 (rc=$RC)"
grep -q "cannot read extra file: $CDIR/nope.md" "$CDIR/stderr.txt" || fail "ticket-bad-extra names the file"
[ "$(grep -c '^gh|' "$T/gh.log" || true)" = "$gh_before" ] || fail "ticket-bad-extra reads no ticket"

# A ticket read that fails: exit 2 with the ticket message, no job, no state write.
# $1 is the case, $2 the gh mode, $3 (optional) the seeded verifier_round.
ticket_fail_case() {
  setup_case "$1"
  rebase_plan
  printf 'ok' >"$T/mode"
  [ -z "${3:-}" ] || bash "$TKT_STATE" "$S" set verifier_round "$3" || fail "$1 seed round"
  bash "$TKT_STATE" "$S" set job.verifier-r1 j-keep || fail "$1 seed job"
  cp "$S" "$CDIR/before.state"
  printf '%s' "$2" >"$T/ghmode"
  jobs_before="$(grep -c '^job|' "$T/stub.log" || true)"
  run_plan verify
  printf 'ok' >"$T/ghmode"
  [ "$RC" -eq 2 ] || fail "$1 exits 2 (rc=$RC)"
  grep -q "tkt-plan: cannot read ticket text for switchyard#518" "$CDIR/stderr.txt" || fail "$1 names the ticket"
  [ "$(grep -c '^job|' "$T/stub.log" || true)" = "$jobs_before" ] || fail "$1 starts no job"
  cmp -s "$S" "$CDIR/before.state" || fail "$1 writes no state"
  [ "$(bash "$TKT_STATE" "$S" get job.verifier-r1)" = "j-keep" ] || fail "$1 keeps the job slot"
}

ticket_fail_case ticket-empty empty
ticket_fail_case ticket-blank blank
ticket_fail_case ticket-fail fail
ticket_fail_case ticket-comments-fail comments-fail
ticket_fail_case ticket-fail-round fail 1

# --- the ticket is read only once a job is about to start ---
gh_count() { grep -c '^gh|' "$T/gh.log" || true; }

setup_case order-round-limit
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed round"
gh_before="$(gh_count)"
run_plan verify
[ "$RC" -eq 1 ] || fail "order round-limit exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 log=*" "order round-limit"
[ "$(gh_count)" = "$gh_before" ] || fail "ROUND-LIMIT reads no ticket"

setup_case order-confirmed
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed round"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "seed confirm"
gh_before="$(gh_count)"
run_plan verify
[ "$RC" -eq 1 ] || fail "order confirmed exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "order confirmed"
[ "$(gh_count)" = "$gh_before" ] || fail "confirm=done reads no ticket"

setup_case order-stale
gh_before="$(gh_count)"
run_plan verify
[ "$RC" -eq 1 ] || fail "order stale exits 1"
expect_verdict "TKT tkt-plan STALE n=1 base=* log=*" "order stale"
[ "$(gh_count)" = "$gh_before" ] || fail "STALE reads no ticket"

setup_case order-plan-check
rebase_plan
printf 'lines' >"$T/pcmode"
gh_before="$(gh_count)"
run_plan verify
printf 'ok' >"$T/pcmode"
[ "$RC" -eq 1 ] || fail "order plan-check exits 1"
expect_verdict "TKT tkt-plan PLAN-CHECK n=2 log=*" "order plan-check"
[ "$(gh_count)" = "$gh_before" ] || fail "PLAN-CHECK reads no ticket"

# --- confirm passes the ticket text, then the state extra, in its run file ---
setup_case confirm-ticket
rebase_plan
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
printf 'ok' >"$T/mode"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "confirm-ticket exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
X="$CDIR/run/switchyard-518-confirm-extra.md"
grep -qF "EXTRA=@$X" "$T/stub.log" || fail "confirm passes the confirm extra file as EXTRA"
L_BODY="$(grep -n '^BODY-TEXT-791$' "$X" | cut -d: -f1)"
L_COMM="$(grep -n '^COMMENT-TEXT-791$' "$X" | cut -d: -f1)"
[ -n "$L_BODY" ] && [ -n "$L_COMM" ] && [ "$L_BODY" -lt "$L_COMM" ] || fail "confirm extra holds the body then the comments"

setup_case confirm-state-extra
rebase_plan
printf 'STATE-LINE\n' >"$CDIR/state-extra.md"
bash "$TKT_STATE" "$S" set extra "$CDIR/state-extra.md" || fail "seed confirm state extra"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "confirm-state-extra exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
X="$CDIR/run/switchyard-518-confirm-extra.md"
L_COMM="$(grep -n '^COMMENT-TEXT-791$' "$X" | cut -d: -f1)"
L_STATE="$(grep -n '^STATE-LINE$' "$X" | cut -d: -f1)"
[ -n "$L_COMM" ] && [ -n "$L_STATE" ] && [ "$L_COMM" -lt "$L_STATE" ] || fail "confirm puts the state extra after the ticket"

setup_case confirm-bad-extra
rebase_plan
bash "$TKT_STATE" "$S" set extra "$CDIR/nope.md" || fail "seed missing state extra"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
gh_before="$(gh_count)"
jobs_before="$(grep -c '^job|' "$T/stub.log" || true)"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 2 ] || fail "confirm-bad-extra exits 2 (rc=$RC)"
grep -q "cannot read extra file: $CDIR/nope.md" "$CDIR/stderr.txt" || fail "confirm-bad-extra names the file"
[ "$(gh_count)" = "$gh_before" ] || fail "confirm-bad-extra reads no ticket"
[ "$(grep -c '^job|' "$T/stub.log" || true)" = "$jobs_before" ] || fail "confirm-bad-extra starts no job"

# A confirm whose ticket read fails: exit 2, no job, no state write.
# $1 is the case, $2 the gh mode.
confirm_fail_case() {
  setup_case "$1"
  rebase_plan
  printf 'ok' >"$T/mode"
  printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
  cp "$S" "$CDIR/before.state"
  printf '%s' "$2" >"$T/ghmode"
  jobs_before="$(grep -c '^job|' "$T/stub.log" || true)"
  run_plan confirm --edits "$CDIR/edits.md"
  printf 'ok' >"$T/ghmode"
  [ "$RC" -eq 2 ] || fail "$1 exits 2 (rc=$RC)"
  grep -q "tkt-plan: cannot read ticket text for switchyard#518" "$CDIR/stderr.txt" || fail "$1 names the ticket"
  [ "$(grep -c '^job|' "$T/stub.log" || true)" = "$jobs_before" ] || fail "$1 starts no job"
  cmp -s "$S" "$CDIR/before.state" || fail "$1 writes no state"
}

confirm_fail_case confirm-empty empty
confirm_fail_case confirm-blank blank
confirm_fail_case confirm-fail fail

setup_case confirm-order
rebase_plan
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "seed confirm"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
gh_before="$(gh_count)"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "confirm-order exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT confirm=done log=*" "confirm-order"
[ "$(gh_count)" = "$gh_before" ] || fail "a used confirm reads no ticket"

# --- real templates: the filled verify and confirm briefs carry the ticket text ---
cp "$SCRIPT_DIR/../skills/planning/briefs/verifier.md" "$T/home/.agents/skills/planning/briefs/verifier.md" || fail "copy the real verifier brief"
cp "$SCRIPT_DIR/../skills/planning/briefs/confirm.md" "$T/home/.agents/skills/planning/briefs/confirm.md" || fail "copy the real confirm brief"
setup_case real-brief
rebase_plan
printf 'pack\n' >"$CDIR/pack.md"
bash "$TKT_STATE" "$S" set pack "$CDIR/pack.md" || fail "seed pack"
printf 'ok' >"$T/mode"
TKT_BIN="$T/realbin" run_plan verify
VB="$CDIR/run/switchyard-518-verifier-r1-1.md"
[ -r "$VB" ] || fail "real verify fills the verifier brief"
grep -q 'BODY-TEXT-791' "$VB" && grep -q 'COMMENT-TEXT-791' "$VB" || fail "real verify brief carries the ticket text"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
TKT_BIN="$T/realbin" run_plan confirm --edits "$CDIR/edits.md"
CB="$CDIR/run/switchyard-518-confirm-1.md"
[ -r "$CB" ] || fail "real confirm fills the confirm brief"
grep -q 'BODY-TEXT-791' "$CB" && grep -q 'COMMENT-TEXT-791' "$CB" || fail "real confirm brief carries the ticket text"

echo "tkt-plan: all cases passed"

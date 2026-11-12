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
# shellcheck source=../bin/lib/plan-tokens.sh
. "$REAL_BIN/lib/plan-tokens.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-tkt-plan.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp" "$T/bin" "$T/cases"
export HOME="$T/home" TMPDIR="$T/tmp" TKT_BIN="$T/bin"
unset DELEGATE_JOBS_DIR

# Files entries expose their read/write mark as a second parser field. A
# missing marker is a write, and the default pathspec mode still includes all.
parser_plan="$T/files-parser.md"
printf '## Files\n- `read.txt` (read)\n| `table.txt` | (read) |\n- `write.txt`\n- `new.txt` (new)\n' >"$parser_plan"
parser_entries="$(awk -v mode=entries "$_plan_files_awk" "$parser_plan")"
[ "$parser_entries" = "$(printf 'read.txt\tread\ntable.txt\tread\nwrite.txt\twrite\nnew.txt\twrite')" ] || fail "Files parser fields: [$parser_entries]"
[ "$(plan_files_pathspecs "$parser_plan")" = "$(printf 'read.txt\ntable.txt\nwrite.txt\nnew.txt')" ] || fail "all Files paths include reads and writes"
[ "$(plan_files_pathspecs "$parser_plan" all)" = "$(printf 'read.txt\ntable.txt\nwrite.txt\nnew.txt')" ] || fail "explicit all Files paths include reads and writes"
[ "$(plan_files_pathspecs "$parser_plan" writes)" = "$(printf 'write.txt\nnew.txt')" ] || fail "writes include new entries and omit reads"
[ "$(plan_files_pathspecs "$parser_plan" new)" = "new.txt" ] || fail "new mode returns marked writes only"
[ "$(plan_files_pathspecs "$parser_plan" lines)" = "$(printf '2\tread.txt\n3\ttable.txt\n4\twrite.txt\n5\tnew.txt')" ] || fail "lines mode preserves new token and line number"

# A prose-suffixed (read) mark is a read in the shared reader.
prose_plan="$T/files-prose-read.md"
printf '## Files\n- `w2.txt`\n- `r9.rs` (read) -- reason\n' >"$prose_plan"
prose_entries="$(awk -v mode=entries "$_plan_files_awk" "$prose_plan")"
[ "$prose_entries" = "$(printf 'w2.txt\twrite\nr9.rs\tread')" ] || fail "prose-suffixed (read) is a read: [$prose_entries]"
[ "$(plan_files_pathspecs "$prose_plan" writes)" = "w2.txt" ] || fail "writes omit prose-suffixed reads"
[ "$(plan_records "$prose_plan" | awk -F '\t' '$5 == "r9.rs" { print $4 }')" = "1" ] || fail "plan_records marks the prose-suffixed form as a read"
[ "$(plan_records "$prose_plan" | awk -F '\t' '$5 == "w2.txt" { print $4 }')" = "0" ] || fail "plan_records leaves the plain write unread"

[ -x "$REAL_BIN/plan-gate" ] || fail "real plan-gate missing"
ln -s "$REAL_BIN/plan-gate" "$T/bin/plan-gate" || fail "symlink plan-gate"

# Stub plan-check: mode file holds "ok" (exit 0), "lines" (exit 1, two lines), or "real" (runs bin/plan-check).
printf 'ok' >"$T/pcmode"
cat >"$T/bin/plan-check" <<EOF
#!/usr/bin/env bash
set -uo pipefail
printf 'check|%s\n' "\$*" >>"$T/stub.log"
if [ "\$(cat "$T/pcmode")" = real ]; then
  "$REAL_BIN/plan-check" "\$@"
  exit \$?
fi
pcmode="\$(cat "$T/pcmode")"
if [ "\$pcmode" = lines ] || [ "\$pcmode" = retry-once ] || [ "\$pcmode" = retry-always ]; then
  pc_count="\$(cat "$T/pc-count" 2>/dev/null || printf '0')"
  pc_count=\$((pc_count + 1))
  printf '%s' "\$pc_count" >"$T/pc-count"
  if [ "\$pcmode" != retry-once ] || [ "\$pc_count" -eq 1 ]; then
  printf 'missing path: bin/ghost (line 9): correct it, or mark the line new or removed\noutside Files: test/ghost (line 12): add it to Files, or mark the line reads\n'
  exit 1
  fi
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
slot=""; out=""; rest=""; resume=""; prompt=""; tmpl=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --slot) slot="\$2"; shift 2 ;;
    --template) tmpl="\$2"; shift 2 ;;
    --out-file) out="\$2"; shift 2 ;;
    --resume) resume="\$2"; shift 2 ;;
    --prompt) prompt="\$2"; shift 2 ;;
    *) rest="\$rest \$1"; shift ;;
  esac
done
printf 'job|slot=%s|tmpl=%s|out=%s|rest=%s\n' "\$slot" "\$tmpl" "\$out" "\$rest" >>"$T/stub.log"
if [ -n "\$resume" ]; then
  printf 'resume|slot=%s|job=%s|prompt=%s\n' "\$slot" "\$resume" "\$prompt" >>"$T/stub.log"
  sed 's/^/resume-prompt|/' "\$prompt" >>"$T/stub.log"
  bash "$REAL_BIN/tkt-state" "\$state" set "job.\$slot" resumed-job-id || exit 2
  echo "TKT tkt-job DONE id=resumed-job-id head=h commits=0 gate=none report=resume log=x"
  exit 0
fi
if [ "\$slot" = confirm ]; then
  confirm_job="\$(bash "$REAL_BIN/tkt-state" "\$state" get job.confirm 2>/dev/null || true)"
  printf 'confirm-job|%s\n' "\$confirm_job" >>"$T/stub.log"
  if [ -n "\$confirm_job" ]; then
    printf 'confirm-watch|%s\n' "\$confirm_job" >>"$T/stub.log"
  else
    printf 'confirm-dispatch\n' >>"$T/stub.log"
    bash "$REAL_BIN/tkt-state" "\$state" set job.confirm j1 || exit 2
  fi
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
  last)
    for n in \$(seq 1 18); do printf 'finding %s\n' "\$n"; done >"\$out"
    printf 'PLAN OK\n' >>"\$out"
    echo "TKT tkt-job DONE id=j1 head=h commits=0 gate=none report=finding 1 log=x"
    ;;
  conflict)
    for n in \$(seq 1 18); do printf 'finding %s\n' "\$n"; done >"\$out"
    printf 'STATUS: PLAN OK\nPLAN OK\n' >>"\$out"
    echo "TKT tkt-job DONE id=j1 head=h commits=0 gate=none report=finding 1 log=x"
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
  silent)
    echo "TKT tkt-job DONE id=j1 head=h commits=0 gate=none report=x log=x"
    exit 0
    ;;
  nested)
    # Controlled interleave: a second verify on the same state runs while this
    # job holds its report path. It runs in ok mode, so it cannot nest again.
    printf 'ok' >"$T/mode"
    bash "$REAL_BIN/tkt-plan" "\$state" verify >"$T/nested.out" 2>&1
    printf 'PLAN OK\nouter\n' >"\$out"
    echo "TKT tkt-job DONE id=j1 head=h commits=0 gate=none report=PLAN OK log=x"
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
printf 'stub pack for %s\n' "\$out" >"\$out" || exit 1
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
if [ "\${1:-}" = api ]; then
  case "\${2:-}" in
    repos/*/issues/comments/*) [ -f "$T/comment.json" ] || exit 1; cat "$T/comment.json"; exit 0 ;;
    *) echo "gh stub: unexpected API endpoint \${2:-}" >&2; exit 2 ;;
  esac
fi
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
REAL_GIT="$(command -v git)"
cat >"$T/ghbin/git" <<EOF
#!/usr/bin/env bash
set -uo pipefail
for arg in "\$@"; do
  if [ "\$arg" = fetch ]; then
    printf 'fetch|%s\\n' "\$*" >>"$T/git-fetch.log"
    if [ -f "$T/fetch-fail" ]; then
      echo 'fatal: simulated fetch failure' >&2
      exit 1
    fi
    exit 0
  fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$T/ghbin/git"
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
  printf 'ok' >"$T/pcmode"
  printf '0' >"$T/pc-count"
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

set_plan_base() {
  local new_base="$1"
  { printf 'Base: %s\n' "$new_base"; tail -n +2 "$CDIR/plan.md"; } >"$CDIR/plan.tmp"
  mv "$CDIR/plan.tmp" "$CDIR/plan.md"
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

state_get() { bash "$TKT_STATE" "$S" get "$1" 2>/dev/null || true; }

set_ruling_comment() {
  local body="$1" created_at="${2:-2099-01-01T00:00:00Z}" comment_issue="${3:-518}"
  jq -n --arg body "$body" --arg url "https://api.github.com/repos/switchyard/issues/$comment_issue" --arg created_at "$created_at" '{body:$body,issue_url:$url,created_at:$created_at}' >"$T/comment.json"
}

seed_triaged_stop() {
  bash "$TKT_STATE" "$S" set plan_stop_verdict_at 2000-01-01T00:00:00Z || fail "seed prior triaged stop timestamp"
  set_ruling_comment 'Ruling for the open line.'
}

expect_plan_verdict() {
  [ "$(state_get plan_verdict)" = "$1" ] || fail "$3: plan_verdict is [$(state_get plan_verdict)], expected [$1]"
  [ "$(state_get plan_verdict_base)" = "$2" ] || fail "$3: plan_verdict_base is [$(state_get plan_verdict_base)], expected [$2]"
  if [ -z "$1" ]; then
    [ -z "$(state_get plan_verdict_hash)" ] || fail "$3: cleared verdict leaves plan_verdict_hash [$(state_get plan_verdict_hash)]"
  fi
}

expect_current_plan_verdict_hash() {
  expected_hash="$(git hash-object "$(state_get plan)")"
  [ "$(state_get plan_verdict_hash)" = "$expected_hash" ] || fail "$1: plan_verdict_hash is [$(state_get plan_verdict_hash)], expected [$expected_hash]"
}

: >"$T/stub.log"

if [ -z "${TKT_PLAN_TEST_ONLY:-}" ]; then
# --- open planner questions stop before a Verifier until one ruling is recorded ---
setup_case questions-stop
rebase_plan
cat >>"$CDIR/plan.md" <<'EOF'

## Open questions

1. Which fallback applies when the primary path is missing?
2. Should the planner resume automatically after a plan-check failure?
EOF
: >"$T/stub.log"
run_plan verify
[ "$RC" -eq 1 ] || fail "open questions stop verify (rc=$RC)"
expect_verdict "TKT tkt-plan QUESTIONS log=*" "open questions stop"
grep -Fq 'Which fallback applies when the primary path is missing?' <<<"$OUT" || fail "QUESTIONS prints the first question"
grep -Fq 'Should the planner resume automatically after a plan-check failure?' <<<"$OUT" || fail "QUESTIONS prints the second question"
expect_plan_verdict questions "$(cat "$CDIR/base")" "open questions stop"
[ -n "$(state_get plan_questions_verdict_at)" ] || fail "QUESTIONS records its verdict timestamp"
[ -z "$(state_get verifier_round)" ] || fail "QUESTIONS does not spend a Verifier round"
[ "$(grep -c '^job|slot=verifier-' "$T/stub.log" || true)" = 0 ] || fail "QUESTIONS starts no Verifier"
first_verdict_at="$(state_get plan_questions_verdict_at)"
sleep 1
run_plan verify
[ "$RC" -eq 1 ] || fail "rerun verify with open questions stops again (rc=$RC)"
[ "$(state_get plan_questions_verdict_at)" = "$first_verdict_at" ] || fail "rerun verify keeps the first QUESTIONS verdict time"

jq -n --arg body 'Use the documented fallback when the primary path is missing. Resume the planner once after a plan-check failure.' --arg url 'https://api.github.com/repos/switchyard/issues/518' --arg created_at '2000-01-01T00:00:00Z' '{body:$body,issue_url:$url,created_at:$created_at}' >"$T/comment.json"
run_plan rule-questions --comment 654321
[ "$RC" -eq 1 ] || fail "ruling comment before the QUESTIONS verdict is refused (rc=$RC)"
expect_verdict "TKT tkt-plan QUESTIONS-REFUSED reason=comment-time log=*" "reject pre-verdict ruling comment"
[ -z "$(state_get plan_questions_comment)" ] || fail "pre-verdict comment is not recorded as a ruling"
jq -n --arg body 'Use the documented fallback when the primary path is missing. Resume the planner once after a plan-check failure.' --arg url 'https://api.github.com/repos/switchyard/issues/518' --arg created_at '2099-01-01T00:00:00Z' '{body:$body,issue_url:$url,created_at:$created_at}' >"$T/comment.json"
run_plan rule-questions --comment 654321
[ "$RC" -eq 0 ] || fail "record ruling for all questions (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan QUESTIONS-RECORDED comment=654321 log=*" "record ruling for all questions"
[ "$(state_get plan_questions_comment)" = 654321 ] || fail "the ruling comment id is recorded"
run_plan verify
[ "$RC" -eq 0 ] || fail "verify continues after ruling (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "verify continues after ruling"
[ "$(state_get verifier_round)" = 1 ] || fail "verify after ruling runs the first Verifier round"
[ "$(grep -c '^job|slot=verifier-' "$T/stub.log" || true)" = 1 ] || fail "verify after ruling starts one Verifier"

# An empty questions section and a section containing only `none` both pass through.
setup_case questions-empty
rebase_plan
cat >>"$CDIR/plan.md" <<'EOF'

## Open questions

EOF
run_plan verify
[ "$RC" -eq 0 ] || fail "empty questions section continues verify (rc=$RC)"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "empty questions section"
[ "$(grep -c '^job|slot=verifier-' "$T/stub.log" || true)" = 2 ] || fail "empty questions section starts Verifier"

setup_case questions-none
rebase_plan
cat >>"$CDIR/plan.md" <<'EOF'

## Open questions

none
EOF
: >"$T/stub.log"
run_plan verify
[ "$RC" -eq 0 ] || fail "none questions section continues verify (rc=$RC)"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "none questions section"
# Empty markers match lanecheck's unanswered-question rules.
setup_case questions-empty-markers
rebase_plan
cat >>"$CDIR/plan.md" <<'EOF'

## Open questions

- nothing
- NONE.
- n/a
- no
- -
EOF
: >"$T/stub.log"
run_plan verify
[ "$RC" -eq 0 ] || fail "empty question markers continue verify (rc=$RC)"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "empty question markers"
[ "$(grep -c '^job|slot=verifier-' "$T/stub.log" || true)" = 1 ] || fail "empty question markers start Verifier"
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
expect_verdict "TKT tkt-plan PLAN-CHECK report_lines=2 log=*" "PLAN-CHECK"
grep -q "missing path: bin/ghost" <<<"$OUT" || fail "PLAN-CHECK lists the first line"
grep -q "outside Files: test/ghost" <<<"$OUT" || fail "PLAN-CHECK lists the second line"
grep -Fq 'planner job not recorded in job.planner; not resumed' <<<"$OUT" || fail "PLAN-CHECK reports that the planner job was not recorded"
grep -q "^job|" "$T/stub.log" && fail "PLAN-CHECK starts no job"
printf 'ok' >"$T/pcmode"

# --- a recorded planner job gets one plan-check retry before the Verifier ---
: >"$T/stub.log"
setup_case plan-check-resume-clean
rebase_plan
bash "$TKT_STATE" "$S" set job.planner planner-job-1471 || fail "seed planner job"
printf 'retry-once' >"$T/pcmode"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "clean plan-check retry continues (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "clean plan-check retry"
[ "$(cat "$T/pc-count")" = 2 ] || fail "clean plan-check retry checks twice"
grep -Fq 'resume|slot=planner|job=planner-job-1471|prompt=' "$T/stub.log" || fail "resume uses the planner slot, recorded job and prompt file"
grep -Fxq 'resume-prompt|missing path: bin/ghost (line 9): correct it, or mark the line new or removed' "$T/stub.log" || fail "resume prompt carries first plan-check line"
grep -Fxq 'resume-prompt|outside Files: test/ghost (line 12): add it to Files, or mark the line reads' "$T/stub.log" || fail "resume prompt carries second plan-check line"
first_check_line="$(grep -n '^check|' "$T/stub.log" | sed -n '1s/:.*//p')"
resume_line="$(grep -n '^resume|' "$T/stub.log" | sed -n '1s/:.*//p')"
second_check_line="$(grep -n '^check|' "$T/stub.log" | sed -n '2s/:.*//p')"
verifier_line="$(grep -n '^job|slot=verifier-r1' "$T/stub.log" | sed -n '1s/:.*//p')"
[ "$first_check_line" -lt "$resume_line" ] && [ "$resume_line" -lt "$second_check_line" ] && [ "$second_check_line" -lt "$verifier_line" ] || fail "resume and recheck precede the Verifier"
[ "$(state_get verifier_round)" = 1 ] || fail "planner resume does not count as a Verifier round"
[ "$(state_get job.planner)" = resumed-job-id ] || fail "resume keeps the planner slot on the resumed job"

# --- a second failing plan-check stops before any Verifier round ---
: >"$T/stub.log"
setup_case plan-check-resume-still-fails
rebase_plan
bash "$TKT_STATE" "$S" set job.planner planner-job-1471 || fail "seed failing planner job"
printf 'retry-always' >"$T/pcmode"
run_plan verify
[ "$RC" -eq 1 ] || fail "second plan-check failure exits 1"
expect_verdict "TKT tkt-plan PLAN-CHECK report_lines=2 log=*" "second plan-check failure"
grep -q 'missing path: bin/ghost' <<<"$OUT" || fail "second plan-check failure reports its lines"
[ "$(cat "$T/pc-count")" = 2 ] || fail "second plan-check failure checks exactly twice"
[ "$(grep -c '^resume|' "$T/stub.log")" -eq 1 ] || fail "second plan-check failure resumes exactly once"
[ "$(grep -c '^job|slot=verifier-' "$T/stub.log" || true)" -eq 0 ] || fail "second plan-check failure spends no Verifier round"
[ -z "$(state_get verifier_round)" ] || fail "second plan-check failure leaves Verifier round count unchanged"
printf 'ok' >"$T/pcmode"

# --- real plan-check line-number citation guidance reaches PLAN-CHECK output ---
setup_case citation-hint
mkdir -p "$WT/src"
wcommit "$WT" src/lib.rs $'pub fn existing() {}\n'
git -C "$WT" update-ref refs/remotes/origin/main HEAD
git -C "$WT" rev-parse HEAD >"$CDIR/base"
printf 'Base: %s\n\n## Files\n\n- `src/lib.rs`\n\n## Rulings\n\nSee `src/lib.rs:1`.\n\n## Gate\n\n`true`\n' "$(cat "$CDIR/base")" >"$CDIR/plan.md"
printf 'real' >"$T/pcmode"
run_plan verify
[ "$RC" -eq 1 ] || fail "citation-hint PLAN-CHECK exits 1 (rc=$RC)"
expect_verdict "TKT tkt-plan PLAN-CHECK report_lines=1 log=*" "citation-hint PLAN-CHECK"
grep -Fq "line-number citation:" <<<"$OUT" || fail "citation-hint output identifies the line-number citation"
grep -Fq 'cite `path::symbol` or a doc heading' <<<"$OUT" || fail "citation-hint output suggests a stable citation"
printf 'ok' >"$T/pcmode"

# --- resolving only an unresolved-symbol line does not consume a confirm round ---
setup_case confirm-unresolved-free
mkdir -p "$WT/src"
wcommit "$WT" src/cited.rs $'pub fn available() {}\n'
git -C "$WT" update-ref refs/remotes/origin/main HEAD
B="$(git -C "$WT" rev-parse HEAD)"
{
  printf 'Base: %s\n\n## Files\n\n- `src/cited.rs`\n\n## Rulings\n\nSee `src/cited.rs::absent`.\n\n## Gate\n\n`true`\n' "$B"
} >"$CDIR/plan.md"
printf 'round 2, line 1: cite the existing symbol\ndone: corrected the plan citation\n' >"$CDIR/edits.md"
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "confirm-unresolved-free seed verifier round"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "confirm-unresolved-free seed confirm round"
printf 'real' >"$T/pcmode"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "unresolved-symbol confirm check stops without spending a round"
expect_verdict "TKT tkt-plan PLAN-CHECK report_lines=2 log=*" "unresolved symbol is reported before confirm accounting"
grep -Fq 'Unresolved symbols:' <<<"$OUT" || fail "confirm PLAN-CHECK names the unresolved section"
grep -Fq 'src/cited.rs::absent' <<<"$OUT" || fail "confirm PLAN-CHECK names the unresolved citation"
[ "$(state_get confirmed_for)" = 2 ] || fail "unresolved PLAN-CHECK preserves the prior confirm counter"
sed 's/::absent/::available/' "$CDIR/plan.md" >"$CDIR/plan.fixed.md"
mv "$CDIR/plan.fixed.md" "$CDIR/plan.md"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "unresolved-only repair is free (rc=$RC): $(first_line)"
expect_verdict "TKT tkt-plan UNRESOLVED-FIX log=*" "unresolved-only plan repair"
[ "$(state_get confirmed_for)" = 2 ] || fail "unresolved-only confirm retry does not move confirmed_for"
run_plan verify
[ "$RC" -eq 0 ] || fail "unresolved-only repair verifies without a confirm round (rc=$RC): $(first_line)"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "unresolved-only repair verify"
grep -Fq 'slot=verifier-r3-unresolved' "$T/stub.log" || fail "unresolved-only repair uses its free verifier slot"
[ "$(state_get verifier_round)" = 2 ] || fail "unresolved-only repair does not increment verifier_round"
[ "$(state_get confirmed_for)" = 2 ] || fail "unresolved-only repair keeps the confirm counter unchanged"
: >"$T/stub.log"

# --- plan-check lines block confirm without consuming its round or grant ---
setup_case confirm-plan-check
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "confirm-plan-check seed round"
printf 'ok' >"$T/mode"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
printf 'lines' >"$T/pcmode"
jobs_before="$(grep -c '^job|' "$T/stub.log" || true)"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "confirm-plan-check exits 1"
expect_verdict "TKT tkt-plan PLAN-CHECK report_lines=2 log=*" "confirm PLAN-CHECK"
grep -q "missing path: bin/ghost" <<<"$OUT" || fail "confirm PLAN-CHECK lists the first line"
grep -q "outside Files: test/ghost" <<<"$OUT" || fail "confirm PLAN-CHECK lists the second line"
[ "$(grep -c '^job|' "$T/stub.log" || true)" = "$jobs_before" ] || fail "confirm PLAN-CHECK starts no job"
[ -z "$(bash "$TKT_STATE" "$S" get confirmed_for 2>/dev/null || true)" ] || fail "confirm PLAN-CHECK leaves the confirm round open"
printf 'ok' >"$T/pcmode"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "confirm after PLAN-CHECK exits 0 (rc=$RC)"
[ "$(grep -c '^job|' "$T/stub.log" || true)" -eq "$((jobs_before + 1))" ] || fail "confirm after PLAN-CHECK runs a job"
[ "$(bash "$TKT_STATE" "$S" get confirmed_for)" = "2" ] || fail "confirm after PLAN-CHECK records the round"

setup_case confirm-plan-check-grant
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "confirm-plan-check-grant seed round"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "confirm-plan-check-grant seed confirm"
bash "$TKT_STATE" "$S" set granted_by switchyard || fail "confirm-plan-check-grant seed author"
bash "$TKT_STATE" "$S" set granted_comment 1234 || fail "confirm-plan-check-grant seed comment"
printf 'ok' >"$T/mode"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
printf 'lines' >"$T/pcmode"
jobs_before="$(grep -c '^job|' "$T/stub.log" || true)"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "granted confirm PLAN-CHECK exits 1"
expect_verdict "TKT tkt-plan PLAN-CHECK report_lines=2 log=*" "granted confirm PLAN-CHECK"
[ "$(grep -c '^job|' "$T/stub.log" || true)" = "$jobs_before" ] || fail "granted confirm PLAN-CHECK starts no job"
[ "$(bash "$TKT_STATE" "$S" get confirmed_for)" = "2" ] || fail "granted confirm PLAN-CHECK preserves the prior confirm"
[ -z "$(bash "$TKT_STATE" "$S" get granted_used 2>/dev/null || true)" ] || fail "granted confirm PLAN-CHECK leaves the grant pending"
printf 'ok' >"$T/pcmode"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "granted confirm after PLAN-CHECK exits 0 (rc=$RC)"
[ "$(bash "$TKT_STATE" "$S" get granted_used)" = "1" ] || fail "granted confirm after PLAN-CHECK uses the grant"
: >"$T/stub.log"

# --- a refused verify keeps the verdict a granted confirm wrote (#1491) ---
# fiber #4234: ROUND-LIMIT, granted confirm PLAN-OK, a later grant, verify
# ROUND-LIMIT again, then post failed verdict=none: the refused verify had
# blanked the verdict on entry before it refused.
setup_case post-after-granted-confirm
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "post-after-granted-confirm seed round"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "post-after-granted-confirm seed confirm"
bash "$TKT_STATE" "$S" set granted_by flywheel || fail "post-after-granted-confirm seed author"
bash "$TKT_STATE" "$S" set granted_comment 111 || fail "post-after-granted-confirm seed comment"
printf 'ok' >"$T/mode"
run_plan verify
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "post-after-granted-confirm first verify"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
run_plan confirm --edits "$CDIR/edits.md"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "post-after-granted-confirm confirm"
expect_plan_verdict ok "$(cat "$CDIR/base")" "post-after-granted-confirm confirm verdict"
run_plan grant-round --by flywheel --comment 222 --ruling 222
expect_verdict "TKT tkt-plan SET grant=flywheel:222 log=*" "post-after-granted-confirm grant"
jobs_before="$(grep -c '^job|' "$T/stub.log" || true)"
run_plan verify
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "post-after-granted-confirm second verify"
[ "$(grep -c '^job|' "$T/stub.log" || true)" = "$jobs_before" ] || fail "post-after-granted-confirm ROUND-LIMIT starts no job"
expect_plan_verdict ok "$(cat "$CDIR/base")" "post-after-granted-confirm ROUND-LIMIT keeps the verdict"
expect_current_plan_verdict_hash "post-after-granted-confirm ROUND-LIMIT keeps the hash"
run_plan post
[ "$RC" -eq 0 ] || fail "post-after-granted-confirm post exits 0 (rc=$RC): $(first_line)"
expect_verdict "TKT tkt-plan POSTED urls=* log=*" "post-after-granted-confirm post"
: >"$T/stub.log"

# --- LINES, then PLAN-OK, then the round limit ---
setup_case rounds
rebase_plan
printf 'lines' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "LINES exits 1"
expect_verdict "TKT tkt-plan LINES report_lines=3 out=* log=*" "LINES"
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
grep -qx 'staleness-check: none (no confirm-edits file)' <<<"$OUT" || fail "confirm reports no edits file for the staleness check"
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

# --- confirm compares the plan with the verify snapshot, not edit mtimes ---
setup_case confirm-applied-plan-newer-edits
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 1 || fail "confirm-applied-plan-newer-edits seed round"
run_plan verify
[ "$RC" -eq 0 ] || fail "confirm-applied-plan-newer-edits verify exits 0 (rc=$RC)"
expected_verified_hash="$(git -C "$WT" hash-object "$CDIR/plan.md")"
edits="$CDIR/run/switchyard-518-confirm-edits-p2.md"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$edits"
cat "$edits" >>"$CDIR/plan.md"
touch -t 202001010001 "$CDIR/plan.md"
touch -t 202001010002 "$edits"
run_plan confirm --edits "$edits"
[ "$RC" -eq 0 ] || fail "confirm accepts applied edits even when the edits file is newer (rc=$RC)"
[ "$(state_get verified_plan_hash)" = "$expected_verified_hash" ] || fail "verify records the plan content hash"
expect_verdict "TKT tkt-plan PLAN-OK out=*confirm-out.md log=*" "confirm applied edits with newer mtime"
grep -qx 'staleness-check: hash' <<<"$OUT" || fail "confirm reports the hash staleness check"

setup_case confirm-unchanged-since-verify
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 1 || fail "confirm-unchanged-since-verify seed round"
run_plan verify
[ "$RC" -eq 0 ] || fail "confirm-unchanged-since-verify verify exits 0 (rc=$RC)"
edits="$CDIR/run/switchyard-518-confirm-edits-p2.md"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$edits"
touch -t 202001010001 "$CDIR/plan.md"
touch -t 202001010002 "$edits"
run_plan confirm --edits "$edits"
[ "$RC" -eq 1 ] || fail "confirm rejects unchanged plan since verify (rc=$RC)"
expect_verdict "TKT tkt-plan STALE-CONFIRM edits=* plan=* log=*" "confirm unchanged plan since verify"
grep -qx 'staleness-check: hash' <<<"$OUT" || fail "stale confirm reports the hash staleness check"

# --- confirm with no recorded plan hash skips the stale-confirm check ---
setup_case confirm-stale-edits
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "confirm-stale-edits seed round"
edits="$CDIR/run/switchyard-518-confirm-edits-p2.md"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$edits"
touch -t 202001010001 "$CDIR/plan.md"
touch -t 202001010002 "$edits"
[ -z "$(state_get verified_plan_hash)" ] || fail "confirm-stale-edits has no recorded plan hash"
# Another ticket's newer edits file in the shared run dir does not block this one.
other="$CDIR/run/switchyard-5180-confirm-edits-p2.md"
printf 'other ticket\n' >"$other"
touch -t 202001010003 "$other"
printf 'ok' >"$T/mode"
jobs_before="$(grep -c '^job|' "$T/stub.log" || true)"
run_plan confirm --edits "$edits"
[ "$RC" -eq 0 ] || fail "confirm with no recorded hash accepts newer edits (rc=$RC)"
expect_verdict "TKT tkt-plan PLAN-OK out=*confirm-out.md log=*" "confirm with no recorded plan hash"
grep -qx 'staleness-check: skipped (no verified_plan_hash)' <<<"$OUT" || fail "confirm reports the missing-hash staleness check was skipped"
[ "$(grep -c '^job|' "$T/stub.log" || true)" -eq "$((jobs_before + 1))" ] || fail "confirm with no recorded hash runs a job"
[ "$(state_get confirmed_for)" = "2" ] || fail "confirm with no recorded hash records the round"

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

# A verdict on the last line passes; line 1 stays the fast path.
setup_case verdict-last
rebase_plan
printf 'last' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "verdict-last verify exits 0 (rc=$RC)"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "verdict-last"
expect_plan_verdict ok "$(cat "$CDIR/base")" "verdict-last"
printf 'ok' >"$T/mode"

setup_case verdict-last-confirm
rebase_plan
printf 'last' >"$T/mode"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "verdict-last confirm exits 0 (rc=$RC)"
expect_verdict "TKT tkt-plan PLAN-OK out=*confirm-out.md log=*" "verdict-last confirm"
printf 'ok' >"$T/mode"

setup_case verdict-last-round-limit
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "verdict-last-round-limit seed round"
{ for n in $(seq 1 18); do printf 'finding %s\n' "$n"; done; printf 'PLAN OK\n'; } >"$CDIR/report.md"
bash "$TKT_STATE" "$S" set last_report "$CDIR/report.md" || fail "verdict-last-round-limit seed report"
run_plan verify
[ "$RC" -eq 1 ] || fail "verdict-last-round-limit exits 1"
grep -qx 'none' <<<"$OUT" || fail "ROUND-LIMIT shows no open lines for a verdict-last pass"

# Two verdict lines that disagree (one carries text beside PLAN OK) are not a pass.
setup_case verdict-conflict
rebase_plan
printf 'conflict' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "verdict-conflict verify exits 1 (rc=$RC)"
expect_verdict "TKT tkt-plan LINES report_lines=20 out=* log=*" "verdict-conflict"
expect_plan_verdict lines "$(cat "$CDIR/base")" "verdict-conflict"
printf 'ok' >"$T/mode"

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
[ -z "$(bash "$TKT_STATE" "$S" get granted_owner 2>/dev/null || true)" ] || fail "plain grant has no owner approval"

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
grant_usage_case 'empty --ruling' --by switchyard --comment 1234 --ruling ''
grant_usage_case 'missing --ruling value' --by switchyard --comment 1234 --ruling
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

setup_case grant-second-used
rebase_plan
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "grant-second-used seed confirm"
bash "$TKT_STATE" "$S" set granted_by old-grant || fail "grant-second-used seed old grant author"
bash "$TKT_STATE" "$S" set granted_comment 99 || fail "grant-second-used seed old grant comment"
bash "$TKT_STATE" "$S" set granted_used 1 || fail "grant-second-used seed used"
run_plan grant-round --by switchyard --comment 5678
[ "$RC" -eq 2 ] || fail "second used grant exits 2 (rc=$RC)"
grep -q 'old-grant:99' "$CDIR/stderr.txt" || fail "used grant refusal names the existing grant"
grep -q -- '--ruling' "$CDIR/stderr.txt" || fail "used grant refusal names --ruling"
grep -qi 'owner' "$CDIR/stderr.txt" && fail "used grant refusal has no owner wording: $(cat "$CDIR/stderr.txt")"
[ "$(bash "$TKT_STATE" "$S" get granted_by)" = "old-grant" ] || fail "used grant refusal keeps the first author"
[ "$(bash "$TKT_STATE" "$S" get granted_comment)" = "99" ] || fail "used grant refusal keeps the first comment"
[ "$(bash "$TKT_STATE" "$S" get granted_used)" = "1" ] || fail "used grant refusal keeps used state"
[ -z "$(bash "$TKT_STATE" "$S" get granted_owner 2>/dev/null || true)" ] || fail "used grant refusal leaves owner empty"

setup_case grant-ruling
rebase_plan
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "grant-ruling seed confirm"
bash "$TKT_STATE" "$S" set granted_by 'old:by' || fail "grant-ruling seed old grant author"
bash "$TKT_STATE" "$S" set granted_comment 'x:y' || fail "grant-ruling seed old grant comment"
bash "$TKT_STATE" "$S" set granted_used 1 || fail "grant-ruling seed used"
run_plan grant-round --by 'switchyard:bot' --comment 'abc:def' --ruling 'own:1'
[ "$RC" -eq 0 ] || fail "ruling grant exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan SET grant=switchyard:bot:abc:def log=*" "ruling grant"
[ "$(bash "$TKT_STATE" "$S" get granted_by)" = "switchyard:bot" ] || fail "ruling grant records the author"
[ "$(bash "$TKT_STATE" "$S" get granted_comment)" = "abc:def" ] || fail "ruling grant records the comment"
[ -z "$(bash "$TKT_STATE" "$S" get granted_owner 2>/dev/null || true)" ] || fail "ruling grant writes no granted_owner"
[ -z "$(bash "$TKT_STATE" "$S" get granted_used 2>/dev/null || true)" ] || fail "ruling grant starts unused"
bash "$TKT_STATE" "$S" list grant | grep -q 'round=3 by=switchyard:bot.*comment=abc:def.*ruling=own:1' || fail "ruling grant records round, grantor and comment"
bash "$TKT_STATE" "$S" list grant | grep -q 'via=ruling' || fail "ruling grant records the ruling flag"
bash "$TKT_STATE" "$S" set granted_used 1 || fail "ruling consume the grant"
run_plan grant-round --by later --comment later
[ "$RC" -eq 2 ] || fail "third grant without a ruling exits 2"
grep -q 'switchyard:bot' "$CDIR/stderr.txt" || fail "third grant refusal names the latest author"
grep -q 'abc:def' "$CDIR/stderr.txt" || fail "third grant refusal names the latest comment"
grep -q -- '--ruling' "$CDIR/stderr.txt" || fail "third grant refusal names --ruling"
grep -qi 'owner' "$CDIR/stderr.txt" && fail "third grant refusal has no owner wording: $(cat "$CDIR/stderr.txt")"
[ -z "$(bash "$TKT_STATE" "$S" get granted_owner 2>/dev/null || true)" ] || fail "third grant refusal writes no granted_owner"

setup_case grant-first-ruling
rebase_plan
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "grant-first-ruling seed confirm"
run_plan grant-round --by switchyard --comment first --ruling 'own:2'
[ "$RC" -eq 0 ] || fail "first ruling grant exits 0 (rc=$RC)"
[ -z "$(bash "$TKT_STATE" "$S" get granted_owner 2>/dev/null || true)" ] || fail "first grant writes no granted_owner"
bash "$TKT_STATE" "$S" list grant | grep -q 'via=ruling.*ruling=own:2' || fail "first grant records the ruling flag"

# --- a second and a third grant with --ruling each re-arm the pending grant ---
setup_case grant-ruling-repeat
rebase_plan
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "grant-ruling-repeat verify 1 exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
run_plan verify
[ "$RC" -eq 0 ] || fail "grant-ruling-repeat verify 2 exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "grant-ruling-repeat initial confirm exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
run_plan grant-round --by fly --comment c1
[ "$RC" -eq 0 ] || fail "grant-ruling-repeat first grant exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
[ "$(bash "$TKT_STATE" "$S" list grant 2>/dev/null | grep -c .)" = "1" ] || fail "grant-ruling-repeat first grant leaves one record"
bash "$TKT_STATE" "$S" list grant | grep -q 'round=3 by=fly.*comment=c1' || fail "grant-ruling-repeat first record carries round, grantor and comment"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "grant-ruling-repeat first granted confirm exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
run_plan grant-round --by fly --comment c2 --ruling r2
[ "$RC" -eq 0 ] || fail "grant-ruling-repeat second grant exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan SET grant=fly:c2 log=*" "grant-ruling-repeat second grant"
[ -z "$(bash "$TKT_STATE" "$S" get granted_used 2>/dev/null || true)" ] || fail "grant-ruling-repeat second grant re-arms the pending grant"
[ -z "$(bash "$TKT_STATE" "$S" get granted_owner 2>/dev/null || true)" ] || fail "grant-ruling-repeat second grant writes no granted_owner"
[ "$(bash "$TKT_STATE" "$S" list grant 2>/dev/null | grep -c .)" = "2" ] || fail "grant-ruling-repeat second grant leaves two records"
bash "$TKT_STATE" "$S" list grant | grep -q 'round=4 by=fly.*comment=c2.*ruling=r2' || fail "grant-ruling-repeat second record carries round, grantor and comment"
bash "$TKT_STATE" "$S" list grant | grep -q 'via=ruling' || fail "grant-ruling-repeat second record names the ruling flag"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "grant-ruling-repeat second granted confirm exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
run_plan grant-round --by fly --comment c3 --ruling r3
[ "$RC" -eq 0 ] || fail "grant-ruling-repeat third grant exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
[ -z "$(bash "$TKT_STATE" "$S" get granted_used 2>/dev/null || true)" ] || fail "grant-ruling-repeat third grant re-arms the pending grant"
[ "$(bash "$TKT_STATE" "$S" list grant 2>/dev/null | grep -c .)" = "3" ] || fail "grant-ruling-repeat three grants leave three records"
bash "$TKT_STATE" "$S" list grant | grep -q 'round=5 by=fly.*comment=c3.*ruling=r3' || fail "grant-ruling-repeat third record carries round, grantor and comment"
rounds="$(bash "$TKT_STATE" "$S" list grant 2>/dev/null | sed -n 's/^round=\([0-9]*\).*/\1/p')"
[ "$rounds" = "$(printf '3\n4\n5')" ] || fail "grant-ruling-repeat records three distinct, increasing round numbers: [$rounds]"

# --- --ruling on a second grant works and records the same way ---
setup_case grant-second-ruling
rebase_plan
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "grant-second-ruling seed confirm"
bash "$TKT_STATE" "$S" set granted_by fly || fail "grant-second-ruling seed grant author"
bash "$TKT_STATE" "$S" set granted_comment c1 || fail "grant-second-ruling seed grant comment"
bash "$TKT_STATE" "$S" set granted_used 1 || fail "grant-second-ruling seed used"
run_plan grant-round --by fly --comment c2 --ruling o2
[ "$RC" -eq 0 ] || fail "grant-second-ruling exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan SET grant=fly:c2 log=*" "grant-second-ruling"
[ -z "$(bash "$TKT_STATE" "$S" get granted_used 2>/dev/null || true)" ] || fail "grant-second-ruling re-arms the pending grant"
[ -z "$(bash "$TKT_STATE" "$S" get granted_owner 2>/dev/null || true)" ] || fail "grant-second-ruling writes no granted_owner"
bash "$TKT_STATE" "$S" list grant | grep -q 'round=3 by=fly.*comment=c2.*ruling=o2' || fail "grant-second-ruling record carries round, grantor and comment"
bash "$TKT_STATE" "$S" list grant | grep -q 'via=ruling' || fail "grant-second-ruling record names the ruling flag"

setup_case grant-before-confirm
rebase_plan
bash "$TKT_STATE" "$S" set granted_by "" || fail "grant-before-confirm seed empty grant"
run_plan grant-round --by switchyard --comment 1234
[ "$RC" -eq 2 ] || fail "grant before confirm exits 2"
grep -Fq "tkt-plan: no limit reached: the confirm round is still open; rerun: tkt-plan $S confirm --edits <file>" "$CDIR/stderr.txt" || fail "grant before confirm explains how to rerun confirm"
[ -z "$(bash "$TKT_STATE" "$S" get granted_by 2>/dev/null || true)" ] || fail "grant before confirm leaves grant state unchanged"

# --- a terminal BLOCKED confirm is dispatched again; a live one is watched ---
setup_case confirm-blocked-rerun
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "confirm-blocked-rerun seed round"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
printf 'blocked' >"$T/mode"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "confirm-blocked-rerun first confirm exits 1"
grep -Fxq 'staleness-check: none (no confirm-edits file)' <<<"$OUT" || fail "confirm-blocked-rerun prints the staleness check on a job exit"
[ "$(state_get job.confirm)" = "j1" ] || fail "confirm-blocked-rerun stores the blocked job"
[ -z "$(state_get confirmed_for)" ] || fail "confirm-blocked-rerun leaves the round open"
mkdir -p "$TMPDIR/delegate-jobs"
printf '{"status":"BLOCKED"}\n' >"$TMPDIR/delegate-jobs/j1.json"
printf 'ok' >"$T/mode"
dispatches_before="$(grep -c '^confirm-dispatch$' "$T/stub.log" || true)"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "confirm-blocked-rerun retry exits 0 (rc=$RC)"
[ "$(grep -c '^confirm-dispatch$' "$T/stub.log" || true)" -eq "$((dispatches_before + 1))" ] || fail "confirm-blocked-rerun dispatches a second job"
[ "$(grep -c '^confirm-watch|' "$T/stub.log" || true)" -eq 0 ] || fail "confirm-blocked-rerun does not replay the blocked job"
[ "$(state_get confirmed_for)" = "2" ] || fail "confirm-blocked-rerun records the round after its report"

setup_case confirm-running-job
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "confirm-running-job seed round"
bash "$TKT_STATE" "$S" set job.confirm j-running || fail "confirm-running-job seed job"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
printf '{"status":"RUNNING"}\n' >"$TMPDIR/delegate-jobs/j-running.json"
printf 'ok' >"$T/mode"
dispatches_before="$(grep -c '^confirm-dispatch$' "$T/stub.log" || true)"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "confirm-running-job exits 0 (rc=$RC)"
[ "$(grep -c '^confirm-dispatch$' "$T/stub.log" || true)" = "$dispatches_before" ] || fail "confirm-running-job does not dispatch again"
[ "$(grep -c '^confirm-watch|j-running$' "$T/stub.log" || true)" -eq 1 ] || fail "confirm-running-job watches the stored job"
[ "$(state_get job.confirm)" = "j-running" ] || fail "confirm-running-job retains the stored job"

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
grep -Fq "if another fully specified confirm is authorized, run tkt-plan $S grant-round --by <who> --comment <id>, then tkt-plan $S confirm --edits <file>; after a non-converging confirm, escalate to a flywheel or surveyor steward and, once its ruling comment is posted, run tkt-plan $S rule-ok --by <flywheel|surveyor> --ruling <RULING-id> --comment <id>; after triage answers every open line, run tkt-plan $S triaged --comment <id>" <<<"$OUT" || fail "verify ROUND-LIMIT names the grant, steward ruling and triaged paths"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "grant-extra confirm before grant exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT confirm=done log=*" "confirm before grant"
grep -Fq "if another fully specified confirm is authorized, run tkt-plan $S grant-round --by <who> --comment <id>, then tkt-plan $S confirm --edits <file>; after a non-converging confirm, escalate to a flywheel or surveyor steward and, once its ruling comment is posted, run tkt-plan $S rule-ok --by <flywheel|surveyor> --ruling <RULING-id> --comment <id>; after triage answers every open line, run tkt-plan $S triaged --comment <id>" <<<"$OUT" || fail "confirm ROUND-LIMIT names the grant, steward ruling and triaged paths"
[ "$(grep -c '^job|' "$T/stub.log")" = "$jobs_before" ] || fail "limits before grant start no job"
run_plan grant-round --by switchyard --comment 1234
[ "$RC" -eq 0 ] || fail "grant-extra grant exits 0"
grep -Fq "next: tkt-plan $S confirm --edits <file>" <<<"$OUT" || fail "grant success names confirm as the next command"
run_plan verify
[ "$RC" -eq 1 ] || fail "pending grant does not unlock verify"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "verify with pending grant"
grep -Fq "a grant is pending (switchyard:1234); verify does not consume it: run tkt-plan $S confirm --edits <file>" <<<"$OUT" || fail "verify with pending grant points at confirm without consuming the grant"
! grep -Fq "if no grant is recorded" <<<"$OUT" || fail "verify with pending grant does not suggest recording another grant"
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

# --- triaged records a plan verdict only after confirm or exhausted rounds ---
setup_case triaged-before-round-limit
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 1 || fail "triaged-before-round-limit seed round"
seed_triaged_stop
run_plan triaged --comment 123456
[ "$RC" -eq 1 ] || fail "triaged before the confirm round or round limit exits 1"
expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=rounds-open log=*" "triaged before round limit"
[ -z "$(state_get plan_triage_comment)" ] || fail "triaged refusal does not record a comment"

# A ruling may close the findings already judged on the unchanged plan text.
setup_case triaged-lines-before-round-limit
rebase_plan
base_now="$(cat "$CDIR/base")"
bash "$TKT_STATE" "$S" set verifier_round 1 || fail "triaged-lines-before-round-limit seed round"
bash "$TKT_STATE" "$S" set plan_verdict lines || fail "triaged-lines-before-round-limit seed LINES"
bash "$TKT_STATE" "$S" set plan_verdict_base "$base_now" || fail "triaged-lines-before-round-limit seed base"
bash "$TKT_STATE" "$S" set plan_verdict_hash "$(git hash-object "$CDIR/plan.md")" || fail "triaged-lines-before-round-limit seed hash"
seed_triaged_stop
run_plan triaged --comment 123457
[ "$RC" -eq 0 ] || fail "triaged current LINES verdict before round limit exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_plan_verdict triaged "$base_now" "triaged current LINES verdict before round limit"
[ "$(state_get plan_verdict_hash)" = "$(git hash-object "$CDIR/plan.md")" ] || fail "triaged stores current plan hash"
[ "$(state_get plan_triage_comment)" = 123457 ] || fail "triaged current LINES verdict records the comment id"

# --- a ruling-only plan edit closes LINES and permits posting without another round ---
setup_case ruling-only-post
rebase_plan
base_now="$(cat "$CDIR/base")"
printf 'Base: %s\n\n## Rulings\n\n- Open line: use the default behavior.\n\n## Files\n\n- `f.txt`\n\n## Gate\n\n`true`\n' "$base_now" >"$CDIR/plan.md"
printf 'lines' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "ruling-only-post records a LINES verdict (rc=$RC)"
expect_plan_verdict lines "$base_now" "ruling-only-post LINES verdict"
awk '{ if ($0 == "- Open line: use the default behavior.") print "- Ruling comment 654321 settles the open line."; else print }' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
set_ruling_comment 'Use the default behavior.'
run_plan triaged --comment 654321
[ "$RC" -eq 0 ] || fail "ruling-only-post accepts a Rulings-only edit (rc=$RC): $(first_line) $(cat "$CDIR/stderr.txt")"
expect_plan_verdict triaged "$base_now" "ruling-only-post settled verdict"
[ "$(state_get plan_triage_comment)" = 654321 ] || fail "ruling-only-post records the ruling comment id"
[ "$(state_get verifier_round)" = 1 ] || fail "ruling-only-post does not spend a Verifier round"
run_plan post
[ "$RC" -eq 0 ] || fail "ruling-only-post posts without another Verifier round (rc=$RC): $(first_line) $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan POSTED urls=* log=*" "ruling-only-post"

# --- non-Rulings plan edits refuse triage and expose a scoped Verifier EXTRA ---
setup_case ruling-files-change
rebase_plan
base_now="$(cat "$CDIR/base")"
printf 'Base: %s\n\n## Rulings\n\n- Open line: use the default behavior.\n\n## Files\n\n- `f.txt`\n\n## Gate\n\n`true`\n' "$base_now" >"$CDIR/plan.md"
printf 'lines' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "ruling-files-change records a LINES verdict"
original_verdict_hash="$(state_get plan_verdict_hash)"
awk '{ if ($0 == "- `f.txt`") print "- `g.txt`"; else print }' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
set_ruling_comment 'The Files path changed.'
run_plan triaged --comment 654322
[ "$RC" -eq 1 ] || fail "ruling-files-change refuses a Files edit (rc=$RC)"
expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=plan-changed log=*" "ruling-files-change"
diff_file="$(sed -n 's/^EXTRA diff: //p' <<<"$OUT")"
[ -n "$diff_file" ] && [ -r "$diff_file" ] || fail "ruling-files-change exposes its scoped diff file"
grep -Fq "verify --extra $diff_file" <<<"$OUT" || fail "ruling-files-change names one scoped Verifier pass with the diff in EXTRA"
grep -Fq -- '-- `f.txt`' "$diff_file" && grep -Fq -- '+- `g.txt`' "$diff_file" || fail "ruling-files-change diff names the changed Files entry"
[ "$(state_get plan_verdict)" = lines ] || fail "ruling-files-change does not record a passing verdict"
[ "$(state_get plan_verdict_hash)" = "$original_verdict_hash" ] || fail "ruling-files-change preserves the original verdict hash"
[ -z "$(state_get plan_triage_comment)" ] || fail "ruling-files-change does not record the ruling comment"

# A used confirm round is an alternate eligibility path, even before round 2.
setup_case triaged-after-confirm
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 1 || fail "triaged-after-confirm seed round"
bash "$TKT_STATE" "$S" set confirmed_for 1 || fail "triaged-after-confirm seed confirm"
seed_triaged_stop
run_plan triaged --comment 234567
[ "$RC" -eq 0 ] || fail "triaged after confirm exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_plan_verdict triaged "$(cat "$CDIR/base")" "triaged after confirm"
[ "$(state_get plan_triage_comment)" = 234567 ] || fail "triaged after confirm records the comment id"

# Exhausting both Verifier rounds lets triage answer open lines without another round.
setup_case triaged-post
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "triaged-post seed rounds"
seed_triaged_stop
run_plan triaged --comment 345678
[ "$RC" -eq 0 ] || fail "triaged after round limit exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_plan_verdict triaged "$(cat "$CDIR/base")" "triaged after round limit"
[ "$(state_get plan_triage_comment)" = 345678 ] || fail "triaged records the numeric comment id"
run_plan post
[ "$RC" -eq 0 ] || fail "triaged verdict permits post (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan POSTED urls=* log=*" "triaged verdict permits post"

setup_case triaged-invalid-comment
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "triaged-invalid-comment seed rounds"
run_plan triaged --comment 12x
[ "$RC" -eq 2 ] || fail "triaged rejects a non-numeric comment id"
grep -Fq 'tkt-plan: comment id must contain only digits' "$CDIR/stderr.txt" || fail "triaged invalid comment explains the numeric requirement"

# Editing the plan's Base invalidates the accepted triaged verdict.
setup_case triaged-stale
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "triaged-stale seed rounds"
seed_triaged_stop
run_plan triaged --comment 456789
[ "$RC" -eq 0 ] || fail "triaged-stale records its verdict"
set_plan_base 0000000000000000000000000000000000000000
run_plan post
[ "$RC" -eq 1 ] || fail "triaged verdict with changed Base is refused"
expect_verdict "TKT tkt-plan POST-FAIL reason=verdict verdict=none log=*" "edited triaged plan reads as absent"

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
expect_verdict "TKT tkt-plan LINES report_lines=3 out=*confirm-out.md log=*" "LINES granted confirm"
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
expect_verdict "TKT tkt-plan LINES report_lines=* out=*confirm-out.md log=*" "confirm LINES"
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
grep -Fq "run tkt-plan $S confirm --edits <file>, or after triage answers every open line run tkt-plan $S triaged --comment <id>" <<<"$OUT" || fail "round limit names confirm and triaged paths"
# Contract: docs/agents/workflow.md:7: ROUND-LIMIT dispatches no additional job.
[ "$(grep -c '^job|' "$T/stub.log")" = "$((jobs_before + 2))" ] || fail "ROUND-LIMIT after two ASKs starts no third job"
printf 'ok' >"$T/mode"

# --- post runs post-plan behind a real plan-gate check ---
setup_case post
bash "$TKT_STATE" "$S" set plan_verdict ok || fail "seed post verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base "$(cat "$CDIR/base")" || fail "seed post verdict base"
: >"$T/stub.log"
run_plan post
[ "$RC" -eq 0 ] || fail "POSTED exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan POSTED urls=*issuecomment-11* log=*" "POSTED"
grep -q "issuecomment-12" <<<"$OUT" || fail "POSTED lists every URL"
grep -q "post|518.*--repo switchyard" "$T/stub.log" || fail "post passes issue and repo to post-plan"
post_run="$(state_get post_run)"
[[ "$post_run" =~ ^[A-Za-z0-9._-]+$ ]] || fail "post stores a valid per-state run id"
grep -Fq -- "--run $post_run" "$T/stub.log" || fail "post passes the stored run id to post-plan"
run_plan post
[ "$RC" -eq 0 ] || fail "same-state post exits 0"
post_run_again="$(state_get post_run)"
[ "$post_run_again" = "$post_run" ] || fail "same-state post keeps its run id"
[ "$(grep -c '^post|' "$T/stub.log")" = "2" ] || fail "same-state post invokes post-plan again"
second_post="$(grep '^post|' "$T/stub.log" | sed -n '2p')"
case "$second_post" in *"--run $post_run"*) ;; *) fail "same-state post passes the same run id again";; esac
run_plan post --part P3
[ "$RC" -eq 0 ] || fail "--part post exits 0"
grep -q "post|.*--part P3" "$T/stub.log" || fail "--part reaches post-plan"

# --- post with no --part takes the label from the state's part ---
# An unlabelled post reuses post-plan's own unlabelled comments and deletes the
# leftovers, so on a part-2 state it overwrites part 1's posted plan. fiber
# #4078 hit that. The state knows the part, so post must use it.
setup_case post-part-from-state
bash "$TKT_STATE" "$S" set plan_verdict ok || fail "seed part-state verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base "$(cat "$CDIR/base")" || fail "seed part-state base"
bash "$TKT_STATE" "$S" set part 2 || fail "seed part"
: >"$T/stub.log"
run_plan post
[ "$RC" -eq 0 ] || fail "post on a part-2 state exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -q "post|.*--part P2" "$T/stub.log" || fail "state part=2 defaults the label to P2"
grep -q 'using P2 from the state' "$CDIR/stderr.txt" || fail "post says which label it chose"
# An explicit --part still wins over the state.
: >"$T/stub.log"
run_plan post --part P9
[ "$RC" -eq 0 ] || fail "explicit --part over a part-2 state exits 0"
grep -q "post|.*--part P9" "$T/stub.log" || fail "explicit --part wins over the state"
# part=1 stays unlabelled: part 1's comment was posted that way, and labelling
# it now would orphan that comment instead of editing it.
bash "$TKT_STATE" "$S" set part 1 || fail "seed part one"
: >"$T/stub.log"
run_plan post
[ "$RC" -eq 0 ] || fail "post on a part-1 state exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -q -- "--part" "$T/stub.log" && fail "part=1 posts unlabelled"

# --- set stores the plan path and invalidates plan-specific state, but keeps completed round counts ---
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
bash "$TKT_STATE" "$S" set granted_owner old-owner || fail "seed grant owner"
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
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "2" ] || fail "SET preserves the round counter"
[ "$(bash "$TKT_STATE" "$S" get confirmed_for)" = "2" ] || fail "SET preserves the confirm-round count"
[ "$(bash "$TKT_STATE" "$S" get granted_by)" = "switchyard" ] || fail "SET preserves the grant author"
[ "$(bash "$TKT_STATE" "$S" get granted_comment)" = "5555" ] || fail "SET preserves the grant comment"
[ "$(bash "$TKT_STATE" "$S" get granted_used)" = "1" ] || fail "SET preserves grant usage"
[ "$(bash "$TKT_STATE" "$S" get granted_owner)" = "old-owner" ] || fail "SET preserves grant owner"
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
bash "$TKT_STATE" "$S" set granted_owner owner-keep || fail "seed same-path grant owner"
bash "$TKT_STATE" "$S" set last_report "$CDIR/kept-report.md" || fail "seed same-path report"
run_plan set "$CDIR/plan.md"
[ "$RC" -eq 0 ] || fail "same-path SET exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan SET plan=$CDIR/plan.md log=*" "same-path SET"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "2" ] || fail "same-path SET keeps the round counter"
[ "$(bash "$TKT_STATE" "$S" get job.verifier-r1)" = "j-keep" ] || fail "same-path SET keeps the job slots"
[ "$(bash "$TKT_STATE" "$S" get granted_by)" = "switchyard" ] || fail "same-path SET keeps the grant author"
[ "$(bash "$TKT_STATE" "$S" get granted_comment)" = "keep" ] || fail "same-path SET keeps the grant comment"
[ "$(bash "$TKT_STATE" "$S" get granted_used)" = "1" ] || fail "same-path SET keeps grant usage"
[ "$(bash "$TKT_STATE" "$S" get granted_owner)" = "owner-keep" ] || fail "same-path SET keeps grant owner"
[ "$(bash "$TKT_STATE" "$S" get last_report)" = "$CDIR/kept-report.md" ] || fail "same-path SET keeps the last report"
grep -q "sweep|.*--plan $CDIR/plan.md" "$T/stub.log" || fail "same-path SET still refreshes the pack"
# An unchanged re-set reuses the successful sweep result.
: >"$T/stub.log"
run_plan set "$CDIR/plan.md"
[ "$RC" -eq 0 ] || fail "unchanged same-path SET exits 0"
[ "$(grep -c '^sweep|' "$T/stub.log" || true)" -eq 0 ] || fail "unchanged same-path SET skips plan-sweep"
# Editing a plan in place changes the content key and sweeps again.
printf '\nPlan note: changed.\n' >>"$CDIR/plan.md"
: >"$T/stub.log"
run_plan set "$CDIR/plan.md"
[ "$RC" -eq 0 ] || fail "edited same-path SET exits 0"
[ "$(grep -c '^sweep|' "$T/stub.log" || true)" -eq 1 ] || fail "edited same-path SET runs plan-sweep again"
# A missing pack artifact invalidates an otherwise matching cache entry.
rm -f "$(bash "$TKT_STATE" "$S" get pack)"
: >"$T/stub.log"
run_plan set "$CDIR/plan.md"
[ "$RC" -eq 0 ] || fail "SET after pack deletion exits 0"
[ "$(grep -c '^sweep|' "$T/stub.log" || true)" -eq 1 ] || fail "SET after pack deletion runs plan-sweep"
# A verify after two counted rounds, with no confirm, stops before any job.
jobs_before="$(grep -c '^job|' "$T/stub.log")"
run_plan verify
[ "$RC" -eq 1 ] || fail "verify at round 2 exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 log=*" "verify at round 2"
[ "$(grep -c '^job|' "$T/stub.log")" = "$jobs_before" ] || fail "verify at round 2 starts no job"

# --- a new plan path resets the pack cache, even with identical content ---
setup_case reset-new-path
run_plan set "$CDIR/plan.md"
[ "$RC" -eq 0 ] || fail "initial cache SET exits 0"
cp "$CDIR/plan.md" "$CDIR/plan-copy.md"
: >"$T/stub.log"
run_plan set "$CDIR/plan-copy.md"
[ "$RC" -eq 0 ] || fail "new-path cache SET exits 0"
[ "$(grep -c '^sweep|' "$T/stub.log" || true)" -eq 1 ] || fail "new plan path runs plan-sweep despite identical content"
[ "$(state_get pack_plan_hash)" = "$(git -C "$WT" hash-object "$CDIR/plan-copy.md")" ] || fail "new-path SET stores the swept plan hash"

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

# --- with gate.script set, set rejects a hand-expanded Gate line before any write ---
setup_case set-gate
bash "$TKT_STATE" "$S" set gate.script scripts/check || fail "gate seed script"
{
  printf 'Base: %s\n' "$(cat "$CDIR/base")"
  printf '\n## Files\n\n- `f.txt`\n\n## Gate\n\ncargo fmt --check && cargo nextest run\n'
} >"$CDIR/hand.md"
run_plan set "$CDIR/hand.md"
[ "$RC" -eq 1 ] || fail "hand-expanded Gate line: SET exits 1 (rc=$RC)"
expect_verdict "TKT tkt-plan SET-FAIL reason=gate log=*" "hand-expanded Gate line"
grep -q 'must run the gate script scripts/check' <<<"$OUT" || fail "SET-FAIL log names the gate script: $OUT"
[ "$(state_get plan)" = "$CDIR/plan.md" ] || fail "rejected SET leaves the plan path unchanged"
{
  printf 'Base: %s\n' "$(cat "$CDIR/base")"
  printf '\n## Files\n\n- `f.txt`\n\n## Gate\n\nscripts/check --base %s\n' "$(cat "$CDIR/base")"
} >"$CDIR/scripted.md"
run_plan set "$CDIR/scripted.md"
[ "$RC" -eq 0 ] || fail "scripts/check Gate line: SET exits 0 (rc=$RC: $(cat "$CDIR/stderr.txt"))"
expect_verdict "TKT tkt-plan SET plan=$CDIR/scripted.md log=*" "scripts/check Gate line"

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
grep -q 'tkt-plan <state> grant-round --by <who> --comment <id> \[--ruling <id>\]' "$T/err-u.txt" || fail "usage names grant-round and --ruling"

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
printf 'Verify the plan.\n\nPlan: __PLAN__\nBase: __BASE__\n__EXTRA__\n' >"$T/home/.agents/skills/planning/briefs/verifier.md"

setup_case realmodel
rebase_plan
TKT_BIN="$T/realbin" run_plan verify
[ "$RC" -eq 0 ] || fail "real tkt-job PLAN-OK exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "real tkt-job"
grep -Fxq 'When the plan passes, the report must start with this exact first line, with nothing before or after it on that line:' "$CDIR/run/switchyard-518-verifier-r1-1.md" || fail "Verifier brief contains verdict-line instruction"
grep -Fxq 'PLAN OK' "$CDIR/run/switchyard-518-verifier-r1-1.md" || fail "Verifier brief contains verbatim verdict line"

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
bash "$TKT_STATE" "$S" set plan_verdict ok || fail "seed replan verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base "$(cat "$CDIR/base")" || fail "seed replan verdict base"
replan_plan_hash="$(git -C "$WT" hash-object "$CDIR/plan.md")"
bash "$TKT_STATE" "$S" set plan_verdict_hash "$replan_plan_hash" || fail "seed replan verdict hash"
bash "$TKT_STATE" "$S" set verified_plan_hash "$replan_plan_hash" || fail "seed replan verified plan hash"
bash "$TKT_STATE" "$S" set pack_plan_hash old-plan-hash || fail "seed replan pack hash"
bash "$TKT_STATE" "$S" set plan_triage_comment 123456 || fail "seed replan triage comment"
bash "$TKT_STATE" "$S" set reviewed "$(cat "$CDIR/base")" || fail "seed replan reviewed head"
bash "$TKT_STATE" "$S" set review_status done || fail "seed replan review status"
bash "$TKT_STATE" "$S" set job.verifier-r1 j-v1 || fail "seed verifier job"
run_plan replan
[ "$RC" -eq 0 ] || fail "replan exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan REPLAN cleared=round,job.lane,job.fix1,job.fix2,job.fix3,job.preflight,findings,reviewed,review_status log=*" "replan"
[ -z "$(bash "$TKT_STATE" "$S" get round 2>/dev/null || true)" ] || fail "replan clears round"
[ -z "$(bash "$TKT_STATE" "$S" get job.lane 2>/dev/null || true)" ] || fail "replan clears job.lane"
[ -z "$(bash "$TKT_STATE" "$S" get job.fix1 2>/dev/null || true)" ] || fail "replan clears job.fix1"
[ -z "$(bash "$TKT_STATE" "$S" get job.fix2 2>/dev/null || true)" ] || fail "replan clears job.fix2"
[ -z "$(bash "$TKT_STATE" "$S" get job.fix3 2>/dev/null || true)" ] || fail "replan clears job.fix3"
[ -z "$(bash "$TKT_STATE" "$S" get job.preflight 2>/dev/null || true)" ] || fail "replan clears job.preflight"
[ -z "$(bash "$TKT_STATE" "$S" get findings 2>/dev/null || true)" ] || fail "replan clears findings"
[ "$(state_get plan_verdict)" = "ok" ] || fail "replan keeps matching plan verdict"
[ "$(state_get plan_verdict_base)" = "$(cat "$CDIR/base")" ] || fail "replan keeps matching plan verdict base"
[ "$(state_get plan_verdict_hash)" = "$replan_plan_hash" ] || fail "replan keeps matching plan verdict hash"
[ -z "$(bash "$TKT_STATE" "$S" get verified_plan_hash 2>/dev/null || true)" ] || fail "replan clears verified plan hash"
[ -z "$(bash "$TKT_STATE" "$S" get pack_plan_hash 2>/dev/null || true)" ] || fail "replan clears pack plan hash"
[ -z "$(bash "$TKT_STATE" "$S" get plan_triage_comment 2>/dev/null || true)" ] || fail "replan clears plan triage comment"
[ -z "$(bash "$TKT_STATE" "$S" get reviewed 2>/dev/null || true)" ] || fail "replan clears reviewed head"
[ -z "$(bash "$TKT_STATE" "$S" get review_status 2>/dev/null || true)" ] || fail "replan clears review status"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "2" ] || fail "replan keeps verifier_round"
[ "$(bash "$TKT_STATE" "$S" get confirmed_for)" = "2" ] || fail "replan keeps confirmed_for"
[ "$(bash "$TKT_STATE" "$S" get granted_by)" = "switchyard" ] || fail "replan keeps grant author"
[ "$(bash "$TKT_STATE" "$S" get granted_comment)" = "replan" ] || fail "replan keeps grant comment"
[ "$(bash "$TKT_STATE" "$S" get granted_used)" = "1" ] || fail "replan keeps grant usage"
[ "$(bash "$TKT_STATE" "$S" get last_report)" = "$CDIR/replan-report.md" ] || fail "replan keeps last_report"
[ "$(bash "$TKT_STATE" "$S" get job.verifier-r1)" = "j-v1" ] || fail "replan keeps verifier jobs"
setup_case replan-stale-verdict
bash "$TKT_STATE" "$S" set plan_verdict ok || fail "seed stale replan verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base "$(cat "$CDIR/base")" || fail "seed stale replan verdict base"
bash "$TKT_STATE" "$S" set plan_verdict_hash stale-plan-hash || fail "seed stale replan verdict hash"
run_plan replan
[ "$RC" -eq 0 ] || fail "replan with stale verdict exits 0"
expect_plan_verdict "" "" "replan clears a stale plan verdict"

setup_case replan-missing-verdict-hash
bash "$TKT_STATE" "$S" set plan_verdict ok || fail "seed replan verdict without hash"
bash "$TKT_STATE" "$S" set plan_verdict_base "$(cat "$CDIR/base")" || fail "seed replan verdict base without hash"
run_plan replan
[ "$RC" -eq 0 ] || fail "replan with unhashable verdict exits 0"
expect_plan_verdict "" "" "replan clears a verdict without a matching hash"

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

# Cited-symbol re-anchor: unrelated changes move the base without another
# Verifier round when every cited declaration and body is unchanged.
setup_case reanchor-untouched
mkdir -p "$WT/src"
wcommit "$WT" src/lib.rs $'pub fn cited_one() {\n    let value = 1;\n}\npub fn cited_two() {\n    let value = 2;\n}\npub fn unrelated() {\n    let value = 10;\n}\n'
A="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" update-ref refs/remotes/origin/main "$A"
{
  printf 'Base: %s\n\n## Files\n\n- `src/lib.rs`\n\n## Tasks\n\n1. Preserve `src/lib.rs::cited_one` and `src/lib.rs::cited_two`.\n\n## Gate\n\n`true`\n' "$A"
} >"$CDIR/plan.md"
printf 'real' >"$T/pcmode"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "reanchor-untouched initial verify exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
[ "$(state_get plan_verdict)" = ok ] || fail "reanchor-untouched initial verify records an OK verdict"
[ "$(state_get verified_base)" = "$A" ] || fail "reanchor-untouched initial verify records base A"
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "reanchor-untouched seed exhausted Verifier count"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "reanchor-untouched seed confirm count"
wcommit "$WT" src/lib.rs $'pub fn cited_one() {\n    let value = 1;\n}\npub fn cited_two() {\n    let value = 2;\n}\npub fn unrelated() {\n    let value = 11;\n}\n'
B="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" update-ref refs/remotes/origin/main "$B"
set_plan_base "$B"
: >"$T/stub.log"
run_plan verify
[ "$RC" -eq 0 ] || fail "reanchor-untouched is mechanical (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan REANCHORED base=$B log=*" "reanchor-untouched"
[ "$(state_get verified_base)" = "$B" ] || fail "reanchor-untouched advances verified_base"
[ "$(state_get verifier_round)" = 2 ] || fail "reanchor-untouched does not spend a Verifier round"
[ "$(state_get confirmed_for)" = 2 ] || fail "reanchor-untouched preserves the confirm count"
[ "$(grep -c '^job|' "$T/stub.log" || true)" = 0 ] || fail "reanchor-untouched starts no Verifier job"

# Braces inside strings are data, not the end of a cited symbol's body.
setup_case reanchor-brace-in-string
mkdir -p "$WT/src"
wcommit "$WT" src/lib.rs $'pub fn cited() {\n    let marker = "}";\n    let value = 1;\n}\npub fn unrelated() {\n    let value = 10;\n}\n'
A="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" update-ref refs/remotes/origin/main "$A"
{
  printf 'Base: %s\n\n## Files\n\n- `src/lib.rs`\n\n## Tasks\n\n1. Preserve `src/lib.rs::cited`.\n\n## Gate\n\n`true`\n' "$A"
} >"$CDIR/plan.md"
printf 'real' >"$T/pcmode"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "reanchor-brace-in-string initial verify exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "reanchor-brace-in-string seed exhausted Verifier count"
wcommit "$WT" src/lib.rs $'pub fn cited() {\n    let marker = "}";\n    let value = 2;\n}\npub fn unrelated() {\n    let value = 10;\n}\n'
B="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" update-ref refs/remotes/origin/main "$B"
set_plan_base "$B"
: >"$T/stub.log"
run_plan verify
[ "$RC" -eq 0 ] || fail "reanchor-brace-in-string dispatches a drift verify (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "reanchor-brace-in-string"
grep -q 'slot=verifier-r3-drift' "$T/stub.log" || fail "reanchor-brace-in-string checks the changed body"
grep -Fq 'Re-anchor review is limited to these cited symbols: src/lib.rs::cited.' <<<"$OUT" || fail "reanchor-brace-in-string names the changed citation"

# With only the Base line changed, a changed cited body reopens only that
# citation, even when both planning counters are exhausted.
setup_case reanchor-changed-symbol
mkdir -p "$WT/src"
wcommit "$WT" src/lib.rs $'pub fn cited_one() {\n    let value = 1;\n}\npub fn cited_two() {\n    let value = 2;\n}\npub fn unrelated() {\n    let value = 10;\n}\n'
A="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" update-ref refs/remotes/origin/main "$A"
{
  printf 'Base: %s\n\n## Files\n\n- `src/lib.rs`\n\n## Tasks\n\n1. Preserve `src/lib.rs::cited_one` and `src/lib.rs::cited_two`.\n\n## Gate\n\n`true`\n' "$A"
} >"$CDIR/plan.md"
printf 'real' >"$T/pcmode"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "reanchor-changed-symbol initial verify exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
[ "$(state_get plan_verdict)" = ok ] || fail "reanchor-changed-symbol initial verify records an OK verdict"
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "reanchor-changed-symbol seed exhausted Verifier count"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "reanchor-changed-symbol seed confirm count"
wcommit "$WT" src/lib.rs $'pub fn cited_one() {\n    let value = 1;\n}\npub fn cited_two() {\n    let value = 22;\n}\npub fn unrelated() {\n    let value = 10;\n}\n'
B="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" update-ref refs/remotes/origin/main "$B"
set_plan_base "$B"
: >"$T/stub.log"
run_plan verify
[ "$RC" -eq 0 ] || fail "reanchor-changed-symbol dispatches a drift verify (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "reanchor-changed-symbol"
[ "$(state_get verified_base)" = "$B" ] || fail "reanchor-changed-symbol advances verified_base after review"
[ "$(state_get verifier_round)" = 2 ] || fail "reanchor-changed-symbol leaves Verifier count unchanged"
[ "$(state_get confirmed_for)" = 2 ] || fail "reanchor-changed-symbol leaves confirm count unchanged"
grep -q 'slot=verifier-r3-drift' "$T/stub.log" || fail "reanchor-changed-symbol uses a drift Verifier slot"
[ "$(grep -c '^job|' "$T/stub.log" || true)" = 1 ] || fail "reanchor-changed-symbol starts exactly one Verifier job"
reanchor_extra="$CDIR/run/switchyard-518-verifier-extra-r3-drift.md"
grep -Fq 'Re-anchor review is limited to these cited symbols: src/lib.rs::cited_two.' "$reanchor_extra" || fail "reanchor-changed-symbol names the changed citation"
grep -Fq 'Re-anchor review is limited to these cited symbols: src/lib.rs::cited_two.' <<<"$OUT" || fail "reanchor-changed-symbol emits the changed citation"
if grep -Fq 'src/lib.rs::cited_one' "$reanchor_extra"; then fail "reanchor-changed-symbol does not name the untouched citation"; fi
if grep -Fq 'src/lib.rs::cited_one' <<<"$OUT"; then fail "reanchor-changed-symbol does not emit the untouched citation"; fi

# A cited symbol renamed in the new base follows the same focused review path,
# rather than stopping as an unresolved-symbol plan-check error.
wcommit "$WT" src/lib.rs $'pub fn cited_one() {\n    let value = 1;\n}\npub fn renamed_two() {\n    let value = 22;\n}\npub fn unrelated() {\n    let value = 10;\n}\n'
C="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" update-ref refs/remotes/origin/main "$C"
set_plan_base "$C"
: >"$T/stub.log"
run_plan verify
[ "$RC" -eq 0 ] || fail "reanchor-renamed-symbol dispatches a drift verify (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "reanchor-renamed-symbol"
[ "$(state_get verified_base)" = "$C" ] || fail "reanchor-renamed-symbol advances verified_base after review"
[ "$(state_get verifier_round)" = 2 ] || fail "reanchor-renamed-symbol leaves Verifier count unchanged"
[ "$(state_get confirmed_for)" = 2 ] || fail "reanchor-renamed-symbol leaves confirm count unchanged"
grep -q 'slot=verifier-r3-drift' "$T/stub.log" || fail "reanchor-renamed-symbol uses a drift Verifier slot"
grep -Fq 'Re-anchor review is limited to these cited symbols: src/lib.rs::cited_two.' "$reanchor_extra" || fail "reanchor-renamed-symbol names the missing citation"
grep -Fq 'Re-anchor review is limited to these cited symbols: src/lib.rs::cited_two.' <<<"$OUT" || fail "reanchor-renamed-symbol emits the missing citation"
if grep -Fq 'src/lib.rs::cited_one' "$reanchor_extra"; then fail "reanchor-renamed-symbol does not name the untouched citation"; fi
if grep -Fq 'src/lib.rs::cited_one' <<<"$OUT"; then fail "reanchor-renamed-symbol does not emit the untouched citation"; fi

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

# --- no resolvable task path: Files paths are the drift fallback ---
setup_case drift-no-task-path
mkdir -p "$WT/src"
wcommit "$WT" src/a.rs "a1"
git -C "$WT" update-ref refs/remotes/origin/main HEAD
git -C "$WT" rev-parse HEAD >"$CDIR/base"
A="$(cat "$CDIR/base")"
{
  printf 'Base: %s\n' "$A"
  printf '\n## Files\n\n- `src/a.rs`\n\n## Tasks\n\n1. Sweep with `perl -pi -e '\''s/old/new/'\'' src/a.rs`.\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "drift-no-task-path seed round"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "drift-no-task-path seed confirm"
bash "$TKT_STATE" "$S" set verified_base "$A" || fail "drift-no-task-path seed verified_base"
wcommit "$WT" src/a.rs "a2"
git -C "$WT" update-ref refs/remotes/origin/main HEAD
git -C "$WT" rev-parse HEAD >"$CDIR/base"
B="$(cat "$CDIR/base")"
{
  printf 'Base: %s\n' "$B"
  printf '\n## Files\n\n- `src/a.rs`\n\n## Tasks\n\n1. Sweep with `perl -pi -e '\''s/old/new/'\'' src/a.rs`.\n\n## Gate\n\n`true`\n'
} >"$CDIR/plan.md"
[ "$A" != "$B" ] || fail "drift-no-task-path needs a new base"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "drift-no-task-path exempt exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "drift-no-task-path"
grep -q "slot=verifier-r3-drift" <<<"$(tail -n 1 "$T/stub.log")" || fail "drift-no-task-path uses the drift slot"
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = 2 ] || fail "drift-no-task-path leaves verifier_round"
[ "$(bash "$TKT_STATE" "$S" get verified_base)" = "$B" ] || fail "drift-no-task-path updates verified_base"

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
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "seed confirm round"
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
[ "$(bash "$TKT_STATE" "$S" get verifier_round)" = "2" ] || fail "drift-g new-path preserves verifier_round"
[ "$(bash "$TKT_STATE" "$S" get confirmed_for)" = "2" ] || fail "drift-g new-path preserves the confirm-round count"

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

# A ticket read that fails: exit 2 with the ticket message, no job, and only
# the verifier verdict metadata cleared.
# $1 is the case, $2 the gh mode, $3 (optional) the seeded verifier_round.
ticket_fail_case() {
  setup_case "$1"
  rebase_plan
  printf 'ok' >"$T/mode"
  [ -z "${3:-}" ] || bash "$TKT_STATE" "$S" set verifier_round "$3" || fail "$1 seed round"
  bash "$TKT_STATE" "$S" set job.verifier-r1 j-keep || fail "$1 seed job"
  bash "$TKT_STATE" "$S" set plan_verdict ok || fail "$1 seed verdict"
  bash "$TKT_STATE" "$S" set plan_verdict_base "$(cat "$CDIR/base")" || fail "$1 seed verdict base"
  grep -v -e '^plan_verdict=' -e '^plan_verdict_base=' -e '^plan_verdict_hash=' -e '^plan_verdict_at=' -e '^plan_verdict_by=' -e '^plan_verdict_ruling=' -e '^plan_verdict_comment=' -e '^plan_triage_comment=' "$S" >"$CDIR/expected.state"
  printf '%s' "$2" >"$T/ghmode"
  jobs_before="$(grep -c '^job|' "$T/stub.log" || true)"
  run_plan verify
  printf 'ok' >"$T/ghmode"
  [ "$RC" -eq 2 ] || fail "$1 exits 2 (rc=$RC)"
  grep -q "tkt-plan: cannot read ticket text for switchyard#518" "$CDIR/stderr.txt" || fail "$1 names the ticket"
  [ "$(grep -c '^job|' "$T/stub.log" || true)" = "$jobs_before" ] || fail "$1 starts no job"
  grep -v -e '^plan_verdict=' -e '^plan_verdict_base=' -e '^plan_verdict_hash=' -e '^plan_verdict_at=' -e '^plan_verdict_by=' -e '^plan_verdict_ruling=' -e '^plan_verdict_comment=' -e '^plan_triage_comment=' "$S" >"$CDIR/actual.state"
  cmp -s "$CDIR/actual.state" "$CDIR/expected.state" || fail "$1 clears only the verdict metadata"
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
grep -q "tkt-plan .* confirm --edits <file>" <<<"$OUT" || fail "order round-limit names the confirm command"
grep -q "triaged --comment <id>" <<<"$OUT" || fail "order round-limit names the triage escape"
[ "$(gh_count)" = "$gh_before" ] || fail "ROUND-LIMIT reads no ticket"

setup_case order-confirmed
rebase_plan
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed round"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "seed confirm"
gh_before="$(gh_count)"
run_plan verify
[ "$RC" -eq 1 ] || fail "order confirmed exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "order confirmed"
grep -q "grant-round --by <who> --comment <id>" <<<"$OUT" || fail "confirm=done names the grant command"
grep -q "confirm --edits <file>" <<<"$OUT" || fail "confirm=done names the confirm command"
grep -q "rule-ok --by <flywheel|surveyor> --ruling <RULING-id> --comment <id>" <<<"$OUT" || fail "confirm=done names the steward ruling path"
grep -q "triaged --comment <id>" <<<"$OUT" || fail "confirm=done names the triage escape"
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
expect_verdict "TKT tkt-plan PLAN-CHECK report_lines=2 log=*" "order plan-check"
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
grep -q "grant-round --by <who> --comment <id>" <<<"$OUT" || fail "confirm-order names the grant command"
grep -q "confirm --edits <file>" <<<"$OUT" || fail "confirm-order names the confirm command"
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

# --- a LINES verify is recorded and blocks post before post-plan ---
setup_case verdict-lines-post
rebase_plan
base_now="$(cat "$CDIR/base")"
bash "$TKT_STATE" "$S" set plan_verdict ok || fail "seed prior verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base "$base_now" || fail "seed prior verdict base"
printf 'lines' >"$T/mode"
posts_before="$(grep -c '^post|' "$T/stub.log" || true)"
run_plan verify
[ "$RC" -eq 1 ] || fail "LINES verify exits 1"
expect_verdict "TKT tkt-plan LINES report_lines=3 out=* log=*" "LINES verify stores verdict"
expect_plan_verdict lines "$base_now" "LINES verify"
expect_current_plan_verdict_hash "LINES verify stores current plan hash"
run_plan post
[ "$RC" -eq 1 ] || fail "post after LINES exits 1"
expect_verdict "TKT tkt-plan POST-FAIL reason=verdict verdict=lines log=*" "post after LINES"
grep -q "plan_verdict=lines plan_verdict_base=$base_now plan_base=$base_now" <<<"$OUT" || fail "post refusal prints the verdict digest"
[ "$(grep -c '^post|' "$T/stub.log" || true)" = "$posts_before" ] || fail "post after LINES does not run post-plan"
expect_plan_verdict lines "$base_now" "post keeps LINES verdict"

# --- PLAN OK permits post, then a new plan path clears the recorded pair ---
setup_case verdict-ok-post-set
rebase_plan
base_now="$(cat "$CDIR/base")"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "PLAN OK verify exits 0"
expect_plan_verdict ok "$base_now" "PLAN OK verify"
run_plan post
[ "$RC" -eq 0 ] || fail "post after PLAN OK exits 0"
expect_verdict "TKT tkt-plan POSTED urls=* log=*" "post after PLAN OK"
printf 'Base: %s\n\n## Files\n\n- `f.txt`\n\n## Gate\n\n`true`\n' "$base_now" >"$CDIR/other.md"
run_plan set "$CDIR/other.md"
[ "$RC" -eq 0 ] || fail "set of a new plan path exits 0"
expect_plan_verdict "" "" "set of a new plan path"
run_plan post
[ "$RC" -eq 1 ] || fail "post after new-path set exits 1"
expect_verdict "TKT tkt-plan POST-FAIL reason=verdict verdict=none log=*" "post after new-path set"

# --- set --no-verifier records skipped; a same-path set without it clears skipped ---
setup_case verdict-set-skip
rebase_plan
base_now="$(cat "$CDIR/base")"
run_plan set "$CDIR/plan.md" --no-verifier
[ "$RC" -eq 0 ] || fail "set --no-verifier exits 0"
expect_plan_verdict skipped "$base_now" "set --no-verifier"
expect_current_plan_verdict_hash "set --no-verifier stores current plan hash"
run_plan post
[ "$RC" -eq 0 ] || fail "post after skipped set exits 0"
run_plan set "$CDIR/plan.md"
[ "$RC" -eq 0 ] || fail "same-path set without --no-verifier exits 0"
expect_plan_verdict "" "" "same-path set clears skipped"
run_plan post
[ "$RC" -eq 1 ] || fail "post after clearing skipped exits 1"
expect_verdict "TKT tkt-plan POST-FAIL reason=verdict verdict=none log=*" "post after clearing skipped"

# --- post --no-verifier records or refreshes skipped and preserves other verdicts ---
setup_case verdict-post-skip
rebase_plan
base_now="$(cat "$CDIR/base")"
run_plan post --no-verifier
[ "$RC" -eq 0 ] || fail "post --no-verifier with no verdict exits 0"
expect_plan_verdict skipped "$base_now" "post --no-verifier fills empty verdict"
expect_current_plan_verdict_hash "post --no-verifier stores current plan hash"
posts_before="$(grep -c '^post|' "$T/stub.log" || true)"
bash "$TKT_STATE" "$S" set plan_verdict lines || fail "seed stored LINES verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base "$base_now" || fail "seed stored LINES base"
run_plan post --no-verifier
[ "$RC" -eq 1 ] || fail "post --no-verifier cannot replace LINES"
expect_verdict "TKT tkt-plan POST-FAIL reason=verdict verdict=lines log=*" "post --no-verifier preserves LINES"
[ "$(grep -c '^post|' "$T/stub.log" || true)" = "$posts_before" ] || fail "post --no-verifier over LINES does not post"
expect_plan_verdict lines "$base_now" "post --no-verifier preserves stored verdict"

# --- editing the Base invalidates the accepted verdict text ---
setup_case verdict-stale-base
rebase_plan
base_now="$(cat "$CDIR/base")"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "stale-base setup verify exits 0"
expect_plan_verdict ok "$base_now" "stale-base setup"
{
  printf 'Base: %s\n' 0000000000000000000000000000000000000000
  tail -n +2 "$CDIR/plan.md"
} >"$CDIR/changed.md"
mv "$CDIR/changed.md" "$CDIR/plan.md"
run_plan post
[ "$RC" -eq 1 ] || fail "post after Base changes exits 1"
expect_verdict "TKT tkt-plan POST-FAIL reason=verdict verdict=none log=*" "edited plan reads as no verdict"

# --- verdict-ok-ancestor-unchanged: an unchanged Files path survives a descendant Base ---
setup_case verdict-ok-ancestor-unchanged
stored_base="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set plan_verdict ok || fail "ancestor-unchanged: seed ok verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base "$stored_base" || fail "ancestor-unchanged: seed verdict base"
printf 'unrelated\n' >"$WT/other.txt"
git -C "$WT" add other.txt
git -C "$WT" -c user.email=t@t -c user.name=t commit -qm unrelated
current_base="$(git -C "$WT" rev-parse HEAD)"
set_plan_base "$current_base"
run_plan post
[ "$RC" -eq 0 ] || fail "ancestor-unchanged: descendant base with unchanged Files exits 0"
expect_verdict "TKT tkt-plan POSTED urls=* log=*" "ancestor-unchanged"

# --- verdict-ok-ancestor-files-changed: changing a Files path on a descendant Base is stale ---
setup_case verdict-ok-ancestor-files-changed
stored_base="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set plan_verdict ok || fail "ancestor-files-changed: seed ok verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base "$stored_base" || fail "ancestor-files-changed: seed verdict base"
printf 'changed\n' >"$WT/f.txt"
git -C "$WT" add f.txt
git -C "$WT" -c user.email=t@t -c user.name=t commit -qm changed-file
current_base="$(git -C "$WT" rev-parse HEAD)"
set_plan_base "$current_base"
run_plan post
[ "$RC" -eq 1 ] || fail "ancestor-files-changed: changed Files path exits 1"
expect_verdict "TKT tkt-plan POST-FAIL reason=verdict verdict=stale log=*" "ancestor-files-changed"

# --- verdict-ok-sibling-base: a sibling current Base is stale ---
setup_case verdict-ok-sibling-base
stored_base="$(git -C "$WT" rev-parse HEAD)"
common_base="$(git -C "$WT" rev-list --max-parents=0 "$stored_base")"
bash "$TKT_STATE" "$S" set plan_verdict ok || fail "sibling-base: seed ok verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base "$stored_base" || fail "sibling-base: seed verdict base"
git -C "$WT" checkout -q --detach "$common_base"
printf 'sibling\n' >"$WT/sibling.txt"
git -C "$WT" add sibling.txt
git -C "$WT" -c user.email=t@t -c user.name=t commit -qm sibling
current_base="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" checkout -q "$stored_base"
set_plan_base "$current_base"
run_plan post
[ "$RC" -eq 1 ] || fail "sibling-base: non-descendant base exits 1"
expect_verdict "TKT tkt-plan POST-FAIL reason=verdict verdict=stale log=*" "sibling-base"

# --- every verify refusal after argument parsing, except ROUND-LIMIT, clears the previous verdict ---
seed_ok_verdict() {
  current_base="$(cat "$CDIR/base")"
  bash "$TKT_STATE" "$S" set plan_verdict ok || fail "seed verify verdict"
  bash "$TKT_STATE" "$S" set plan_verdict_base "$current_base" || fail "seed verify verdict base"
}
setup_case verdict-clear-check
rebase_plan
seed_ok_verdict
printf 'lines' >"$T/pcmode"
run_plan verify
[ "$RC" -eq 1 ] || fail "PLAN-CHECK verify exits 1"
expect_verdict "TKT tkt-plan PLAN-CHECK report_lines=2 log=*" "PLAN-CHECK clears verdict"
expect_plan_verdict "" "" "PLAN-CHECK clears pair"
printf 'ok' >"$T/pcmode"
setup_case verdict-clear-stale
seed_ok_verdict
run_plan verify
[ "$RC" -eq 1 ] || fail "STALE verify exits 1"
expect_verdict "TKT tkt-plan STALE n=1 base=* log=*" "STALE clears verdict"
expect_plan_verdict "" "" "STALE clears pair"
setup_case verdict-clear-ask
rebase_plan
seed_ok_verdict
printf 'ask' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "ASK verify exits 1"
expect_verdict "TKT tkt-plan ASK id=j1 log=*" "ASK clears verdict"
expect_plan_verdict "" "" "ASK clears pair"
printf 'ok' >"$T/mode"
setup_case verdict-clear-round
rebase_plan
seed_ok_verdict
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed round limit"
run_plan verify
[ "$RC" -eq 1 ] || fail "ROUND-LIMIT verify exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 log=*" "ROUND-LIMIT keeps verdict"
# ROUND-LIMIT is a budget refusal, not a judgment of the plan: it keeps the verdict (#1491).
expect_plan_verdict ok "$current_base" "ROUND-LIMIT keeps pair"
setup_case verdict-clear-model
rebase_plan
seed_ok_verdict
sed '/^model.verifier=/d' "$S" >"$CDIR/no-model.state"
S="$CDIR/no-model.state"
run_plan verify
[ "$RC" -eq 2 ] || fail "missing model verify exits 2"
expect_plan_verdict "" "" "missing model clears pair"
setup_case verdict-clear-ticket
rebase_plan
seed_ok_verdict
printf 'fail' >"$T/ghmode"
run_plan verify --model test-model
printf 'ok' >"$T/ghmode"
[ "$RC" -eq 2 ] || fail "ticket read failure verify exits 2"
expect_plan_verdict "" "" "ticket read failure clears pair"

# --- replan clears verdict state ---
setup_case verdict-replan
rebase_plan
seed_ok_verdict
run_plan replan
[ "$RC" -eq 0 ] || fail "replan with verdict exits 0"
expect_plan_verdict "" "" "replan clears verdict"

# --- an exempt drift verify still records the report verdict and current base ---
setup_case verdict-drift
rebase_plan
base_now="$(cat "$CDIR/base")"
old_base="$(git -C "$WT" rev-list --max-parents=0 HEAD)"
bash "$TKT_STATE" "$S" set verified_base "$old_base" || fail "seed older verified base"
printf 'Base: %s\n\n## Files\n\n- `f.txt`\n\n## Tasks\n\n- update `f.txt`\n\n## Gate\n\n`true`\n' "$base_now" >"$CDIR/plan.md"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "drift-exempt verify exits 0"
expect_plan_verdict ok "$base_now" "drift-exempt verify"

# --- confirm records the report verdict and keeps it on pre-report exits ---
setup_case verdict-confirm-lines
rebase_plan
base_now="$(cat "$CDIR/base")"
printf 'round 1, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
printf 'lines' >"$T/mode"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "confirm LINES exits 1"
expect_plan_verdict lines "$base_now" "confirm LINES"
expect_current_plan_verdict_hash "confirm LINES stores current plan hash"
setup_case verdict-confirm-ok
rebase_plan
base_now="$(cat "$CDIR/base")"
printf 'round 1, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
printf 'ok' >"$T/mode"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "confirm PLAN OK exits 0"
expect_plan_verdict ok "$base_now" "confirm PLAN OK"
expect_current_plan_verdict_hash "confirm PLAN OK stores current plan hash"
setup_case verdict-confirm-preserves
rebase_plan
base_now="$(cat "$CDIR/base")"
bash "$TKT_STATE" "$S" set plan_verdict lines || fail "seed confirm LINES verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base "$base_now" || fail "seed confirm LINES base"
bash "$TKT_STATE" "$S" set confirmed_for 1 || fail "seed confirm limit"
printf 'round 1, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "limited confirm exits 1"
expect_verdict "TKT tkt-plan ROUND-LIMIT confirm=done log=*" "limited confirm keeps previous verdict"
expect_plan_verdict lines "$base_now" "limited confirm keeps pair"

# --- same-path --no-verifier does not overwrite an existing word ---
setup_case verdict-set-preserves
rebase_plan
base_now="$(cat "$CDIR/base")"
bash "$TKT_STATE" "$S" set plan_verdict lines || fail "seed same-path LINES verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base "$base_now" || fail "seed same-path LINES base"
run_plan set "$CDIR/plan.md" --no-verifier
[ "$RC" -eq 0 ] || fail "same-path set --no-verifier exits 0"
expect_plan_verdict lines "$base_now" "same-path --no-verifier preserves LINES"
setup_case verdict-set-preserves-ok
rebase_plan
old_base="$(git -C "$WT" rev-parse HEAD^)"
bash "$TKT_STATE" "$S" set plan_verdict ok || fail "seed same-path OK verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base "$old_base" || fail "seed same-path OK base"
run_plan set "$CDIR/plan.md" --no-verifier
[ "$RC" -eq 0 ] || fail "same-path set --no-verifier preserves OK"
expect_plan_verdict ok "$old_base" "same-path --no-verifier preserves OK pair"

# --- an accepted word with a mismatched base is stale even with the fast-path flag ---
setup_case verdict-stale-flag
rebase_plan
base_now="$(cat "$CDIR/base")"
bash "$TKT_STATE" "$S" set plan_verdict ok || fail "seed stale flag verdict"
bash "$TKT_STATE" "$S" set plan_verdict_base 0000000000000000000000000000000000000000 || fail "seed stale flag base"
run_plan post --no-verifier
[ "$RC" -eq 1 ] || fail "post --no-verifier with stale pair exits 1"
expect_verdict "TKT tkt-plan POST-FAIL reason=verdict verdict=stale log=*" "post --no-verifier with stale pair"
expect_plan_verdict ok 0000000000000000000000000000000000000000 "post --no-verifier does not overwrite stale word"

# --- verify refuses a report without a fresh report verdict ---
setup_case verdict-clear-blocked
rebase_plan
seed_ok_verdict
printf 'blocked' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "BLOCKED verify exits 1"
expect_verdict "TKT tkt-plan BLOCKED id=j1 log=*" "BLOCKED clears verdict"
expect_plan_verdict "" "" "BLOCKED clears pair"
printf 'ok' >"$T/mode"

# --- set --no-verifier refreshes a stored skipped verdict at the current base ---
setup_case verdict-set-skipped-old-base
rebase_plan
base_now="$(cat "$CDIR/base")"
old_base="$(git -C "$WT" rev-parse HEAD^)"
bash "$TKT_STATE" "$S" set plan_verdict skipped || fail "seed old skipped verdict for set"
bash "$TKT_STATE" "$S" set plan_verdict_base "$old_base" || fail "seed old skipped base for set"
run_plan set "$CDIR/plan.md" --no-verifier
[ "$RC" -eq 0 ] || fail "set --no-verifier refreshes an old skipped verdict"
expect_plan_verdict skipped "$base_now" "set --no-verifier refreshes skipped"

# --- post --no-verifier refreshes skipped; post without it keeps stale refusal ---
setup_case verdict-post-skipped-old-base
rebase_plan
base_now="$(cat "$CDIR/base")"
old_base="$(git -C "$WT" rev-parse HEAD^)"
bash "$TKT_STATE" "$S" set plan_verdict skipped || fail "seed old skipped verdict for post"
bash "$TKT_STATE" "$S" set plan_verdict_base "$old_base" || fail "seed old skipped base for post"
run_plan post
[ "$RC" -eq 1 ] || fail "post without --no-verifier refuses old skipped verdict"
expect_verdict "TKT tkt-plan POST-FAIL reason=verdict verdict=stale log=*" "post without flag refuses stale skipped"
expect_plan_verdict skipped "$old_base" "post without flag preserves stale skipped pair"
run_plan post --no-verifier
[ "$RC" -eq 0 ] || fail "post --no-verifier refreshes an old skipped verdict"
expect_verdict "TKT tkt-plan POSTED urls=* log=*" "post --no-verifier refreshes skipped"
expect_plan_verdict skipped "$base_now" "post --no-verifier refreshes skipped"

# --- a verify never overwrites an earlier Verifier report ---
# A Verifier report already on disk still reserves its name; SET no longer resets the count to make it look like round 1.
setup_case verify-no-overwrite
rebase_plan
seeded="$CDIR/run/switchyard-518-verifier-out-r1.md"
printf 'known verifier finding\n' >"$seeded"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "verify-no-overwrite exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
[ "$(cat "$seeded")" = "known verifier finding" ] || fail "verify-no-overwrite leaves the seeded report unchanged"
grep -q "out=$CDIR/run/switchyard-518-verifier-out-r1-2.md|" "$T/stub.log" || fail "verify-no-overwrite writes verifier-out-r1-2.md"
[ "$(state_get last_report)" = "$CDIR/run/switchyard-518-verifier-out-r1-2.md" ] || fail "verify-no-overwrite records the new report as last_report"
expect_verdict "TKT tkt-plan PLAN-OK out=$CDIR/run/switchyard-518-verifier-out-r1-2.md log=*" "verify-no-overwrite"

# The next free suffix skips every report that exists.
setup_case verify-free-suffix
rebase_plan
printf 'first\n' >"$CDIR/run/switchyard-518-verifier-out-r1.md"
printf 'second\n' >"$CDIR/run/switchyard-518-verifier-out-r1-2.md"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "verify-free-suffix exits 0 (rc=$RC)"
[ "$(cat "$CDIR/run/switchyard-518-verifier-out-r1-2.md")" = "second" ] || fail "verify-free-suffix leaves the -2 report unchanged"
grep -q "out=$CDIR/run/switchyard-518-verifier-out-r1-3.md|" "$T/stub.log" || fail "verify-free-suffix writes verifier-out-r1-3.md"

# A confirm round never overwrites an earlier confirm report. Reach the confirm
# round as confirm-lines does: two LINES verifies, then confirm.
setup_case confirm-no-overwrite
rebase_plan
printf 'lines' >"$T/mode"
run_plan verify
run_plan verify
printf 'ok' >"$T/mode"
seeded="$CDIR/run/switchyard-518-confirm-out.md"
printf 'known confirm finding\n' >"$seeded"
printf 'round 2, line 1: add bin/x to Files\ndone: added\n' >"$CDIR/edits.md"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "confirm-no-overwrite exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
[ "$(cat "$seeded")" = "known confirm finding" ] || fail "confirm-no-overwrite leaves the seeded report unchanged"
grep -q "out=$CDIR/run/switchyard-518-confirm-out-2.md|" "$T/stub.log" || fail "confirm-no-overwrite writes confirm-out-2.md"
[ "$(state_get last_report)" = "$CDIR/run/switchyard-518-confirm-out-2.md" ] || fail "confirm-no-overwrite records the new report as last_report"
expect_verdict "TKT tkt-plan PLAN-OK out=$CDIR/run/switchyard-518-confirm-out-2.md log=*" "confirm-no-overwrite"

# --- a verify reserves its report path before the job runs ---
# An empty file is a reservation another round holds: the round takes the next
# suffix and leaves the reservation alone.
setup_case verify-empty-reservation
rebase_plan
: >"$CDIR/run/switchyard-518-verifier-out-r1.md"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "verify-empty-reservation exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
[ -e "$CDIR/run/switchyard-518-verifier-out-r1.md" ] && [ ! -s "$CDIR/run/switchyard-518-verifier-out-r1.md" ] || fail "verify-empty-reservation leaves the reservation empty"
grep -q "out=$CDIR/run/switchyard-518-verifier-out-r1-2.md|" "$T/stub.log" || fail "verify-empty-reservation writes r1-2"
[ "$(state_get last_report)" = "$CDIR/run/switchyard-518-verifier-out-r1-2.md" ] || fail "verify-empty-reservation records r1-2"

# Controlled interleave: the job for round 1 holds r1, and a second verify on
# the same state runs before that job writes. The second must take r1-2, and
# the first must still write its own report to r1.
setup_case verify-interleave
rebase_plan
printf 'nested' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "verify-interleave outer exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
r1="$CDIR/run/switchyard-518-verifier-out-r1.md"
r2="$CDIR/run/switchyard-518-verifier-out-r1-2.md"
grep -qx 'outer' "$r1" || fail "verify-interleave keeps the outer report in r1"
grep -qx 'outer' "$r2" && fail "verify-interleave keeps the nested verify out of r1-2's outer text"
grep -q 'PLAN OK' "$r2" || fail "verify-interleave writes the nested report to r1-2"
[ "$(state_get last_report)" = "$r1" ] || fail "verify-interleave records the outer report as last_report"
printf 'ok' >"$T/mode"

# A job that exits 0 without writing its report is "wrote no report", not
# LINES report_lines=0, and leaves its reservation empty.
setup_case job-silent-no-report
rebase_plan
printf 'silent' >"$T/mode"
run_plan verify
[ "$RC" -eq 3 ] || fail "job-silent-no-report exits 3 (rc=$RC)"
grep -q 'wrote no report' "$CDIR/stderr.txt" || fail "job-silent-no-report says it wrote no report"
grep -q '^LINES' <<<"$OUT" && fail "job-silent-no-report is not LINES report_lines=0"
r1="$CDIR/run/switchyard-518-verifier-out-r1.md"
[ -e "$r1" ] && [ ! -s "$r1" ] || fail "job-silent-no-report leaves the reservation empty"
printf 'ok' >"$T/mode"

# A blocked job leaves its empty reservation, and the next round does not reuse it.
setup_case job-blocked-reservation
rebase_plan
printf 'blocked' >"$T/mode"
run_plan verify
case "$(first_line)" in *BLOCKED*) ;; *) fail "job-blocked-reservation verdict is BLOCKED: [$(first_line)]" ;; esac
r1="$CDIR/run/switchyard-518-verifier-out-r1.md"
[ -e "$r1" ] && [ ! -s "$r1" ] || fail "job-blocked-reservation leaves the reservation empty"
printf 'ok' >"$T/mode"
run_plan verify
[ "$RC" -eq 0 ] || fail "job-blocked-reservation retry exits 0 (rc=$RC)"
grep -q "out=$CDIR/run/switchyard-518-verifier-out-r1-2.md|" "$T/stub.log" || fail "job-blocked-reservation retry writes r1-2"

# --- one edited-plan re-confirm is free, the next one is refused ---
setup_case confirm-free-reconfirm
rebase_plan
prior_confirm="$CDIR/run/switchyard-518-confirm-out.md"
printf 'prior confirmation\n' >"$prior_confirm"
printf 'line 1 was edited\n' >"$CDIR/run/switchyard-518-confirm-edits-1.md"
printf 'line 1 was edited\n' >"$CDIR/edits.md"
touch -t 202001010000 "$prior_confirm"
touch -t 202101010000 "$CDIR/run/switchyard-518-confirm-edits-1.md"
touch -t 204001010000 "$CDIR/plan.md"
bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "seed prior confirm"
bash "$TKT_STATE" "$S" set last_report "$prior_confirm" || fail "seed prior report"
bash "$TKT_STATE" "$S" set last_confirm_report "$prior_confirm" || fail "seed last confirm report"
bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed confirm verifier round"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 0 ] || fail "free re-confirm exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
[ "$(state_get confirm_reconfirm_used)" = "1" ] || fail "free re-confirm records that it was used"
printf 'line 2 was edited\n' >"$CDIR/run/switchyard-518-confirm-edits-2.md"
touch -t 203001010000 "$CDIR/run/switchyard-518-confirm-edits-2.md"
run_plan confirm --edits "$CDIR/edits.md"
[ "$RC" -eq 1 ] || fail "second re-confirm exits 1 (rc=$RC)"
expect_verdict "TKT tkt-plan ROUND-LIMIT confirm=done log=*" "second re-confirm"

# --- LINES and PLAN-CHECK name the line count, not a finding count (#1109) ---
# `n=` reads as a finding count; `report_lines=` says what the number is.
setup_case verdict-line-count
rebase_plan
printf 'lines' >"$T/mode"
run_plan verify
[ "$RC" -eq 1 ] || fail "verdict-line-count LINES exits 1"
expect_verdict "TKT tkt-plan LINES report_lines=3 out=* log=*" "verdict-line-count LINES names report_lines"
case "$(first_line)" in *" n="*) fail "verdict-line-count LINES carries no bare n=: [$(first_line)]";; esac
printf 'ok' >"$T/mode"

setup_case verdict-plan-check-line-count
rebase_plan
printf 'lines' >"$T/pcmode"
run_plan verify
printf 'ok' >"$T/pcmode"
[ "$RC" -eq 1 ] || fail "verdict-plan-check-line-count exits 1"
expect_verdict "TKT tkt-plan PLAN-CHECK report_lines=2 log=*" "verdict-plan-check-line-count names report_lines"
case "$(first_line)" in *" n="*) fail "verdict-plan-check-line-count carries no bare n=: [$(first_line)]";; esac
fi

if [ -z "${TKT_PLAN_TEST_ONLY:-}" ] || [ "$TKT_PLAN_TEST_ONLY" = unresolved-insertion ]; then
  # Inserting a task beside an unresolved-symbol fix is not an exempt repair.
  setup_case confirm-unresolved-insertion
  mkdir -p "$WT/src"
  wcommit "$WT" src/cited.rs $'pub fn available() {}\n'
  git -C "$WT" update-ref refs/remotes/origin/main HEAD
  B="$(git -C "$WT" rev-parse HEAD)"
  {
    printf 'Base: %s\n\n## Files\n\n- `src/cited.rs`\n\n## Tasks\n\n1. Preserve `src/cited.rs::absent`.\n\n## Gate\n\n`true`\n' "$B"
  } >"$CDIR/plan.md"
  bash "$TKT_STATE" "$S" set verifier_round 2 || fail "confirm-unresolved-insertion seed verifier round"
  bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "confirm-unresolved-insertion seed confirm round"
  printf 'real' >"$T/pcmode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "unresolved-symbol finding is recorded before the insertion test (rc=$RC)"
  expect_verdict "TKT tkt-plan PLAN-CHECK report_lines=* log=*" "confirm-unresolved-insertion unresolved baseline"
  awk '{ if ($0 == "1. Preserve `src/cited.rs::absent`.") { print "1. Preserve `src/cited.rs::available`."; print "2. Add an independent task."; } else print }' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
  : >"$T/stub.log"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "inserted task beside an unresolved fix reaches ROUND-LIMIT (rc=$RC): $(first_line)"
  expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 confirm=done log=*" "confirm-unresolved-insertion is not unresolved-only"
  [ "$(grep -c '^job|slot=verifier-' "$T/stub.log" || true)" = 0 ] || fail "confirm-unresolved-insertion starts no free Verifier job"
  [ "$(state_get verifier_round)" = 2 ] || fail "confirm-unresolved-insertion preserves the exhausted count"
  : >"$T/stub.log"
fi

# Verbatim ruling acceptance: selectors skip legacy cases for focused runs;
# the unfiltered invocation still covers all cases.
write_triaged_tasks_plan() {
  printf 'Base: %s\n\n## Rulings\n\n- Open line: clarify the task wording.\n\n## Tasks\n\n1. Keep the existing task wording.\n\n## Files\n\n- `f.txt`\n\n## Gate\n\n`true`\n' "$(cat "$CDIR/base")" >"$CDIR/plan.md"
}

write_triaged_interfaces_plan() {
  printf 'Base: %s\n\n## Rulings\n\n- Open line: clarify the interface wording.\n\n## Interfaces\n\n1. Preserve the existing interface.\n\n## Files\n\n- `f.txt`\n\n## Tasks\n\n1. Preserve the existing task.\n\n## Gate\n\n`true`\n' "$(cat "$CDIR/base")" >"$CDIR/plan.md"
}

replace_plan_line() {
  local old_line="$1" new_line="$2"
  printf '%s\n' "$new_line" >"$T/replacement-lines"
  awk -v old_line="$old_line" -v replacements_file="$T/replacement-lines" '
    BEGIN { while ((getline line < replacements_file) > 0) replacements[++count]=line }
    $0 == old_line { for (i=1; i<=count; i++) print replacements[i]; next }
    { print }
  ' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
}

if [ -z "${TKT_PLAN_TEST_ONLY:-}" ] || [ "$TKT_PLAN_TEST_ONLY" = verbatim ]; then
  setup_case triaged-lines-stop-time
  rebase_plan
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-lines-stop-time records a LINES verdict"
  lines_stop_at="$(state_get plan_stop_verdict_at)"
  [ -n "$lines_stop_at" ] || fail "triaged-lines-stop-time records its stop timestamp"
  lines_stop_at=2000-01-01T00:00:00Z
  bash "$TKT_STATE" "$S" set plan_stop_verdict_at "$lines_stop_at" || fail "triaged-lines-stop-time seeds a known stop time"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-lines-stop-time repeats the LINES verdict"
  [ "$(state_get plan_stop_verdict_at)" = "$lines_stop_at" ] || fail "triaged-lines-stop-time keeps the first time for the same stop"
  run_plan replan
  [ "$RC" -eq 0 ] || fail "triaged-lines-stop-time replans"
  [ -z "$(state_get plan_stop_verdict_at)" ] || fail "replan clears the plan stop timestamp"
  [ -z "$(state_get plan_stop_verdict_key)" ] || fail "replan clears the plan stop key"

  setup_case triaged-round-limit-stop-time
  rebase_plan
  bash "$TKT_STATE" "$S" set verifier_round 2 || fail "seed triaged round limit"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-round-limit-stop-time emits ROUND-LIMIT"
  expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 log=*" "triaged-round-limit-stop-time"
  round_limit_stop_at="$(state_get plan_stop_verdict_at)"
  [ -n "$round_limit_stop_at" ] || fail "triaged-round-limit-stop-time records its stop timestamp"
  round_limit_stop_at=2000-01-01T00:00:00Z
  bash "$TKT_STATE" "$S" set plan_stop_verdict_at "$round_limit_stop_at" || fail "triaged-round-limit-stop-time seeds a known stop time"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-round-limit-stop-time repeats ROUND-LIMIT"
  [ "$(state_get plan_stop_verdict_at)" = "$round_limit_stop_at" ] || fail "triaged-round-limit-stop-time keeps the first time for the same stop"

  # A ruling written into the plan changes its hash; the ROUND-LIMIT that
  # follows must keep the LINES stop time, or the ruling reads as stale.
  setup_case triaged-round-limit-after-edit
  rebase_plan
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-round-limit-after-edit records a LINES verdict"
  bash "$TKT_STATE" "$S" set plan_stop_verdict_at 2000-01-01T00:00:00Z || fail "triaged-round-limit-after-edit seeds a known stop time"
  printf '\n## Rulings\n\n- Ruling comment settles the open line.\n' >>"$CDIR/plan.md"
  bash "$TKT_STATE" "$S" set verifier_round 2 || fail "triaged-round-limit-after-edit seeds the round limit"
  run_plan verify
  expect_verdict "TKT tkt-plan ROUND-LIMIT round=2 log=*" "triaged-round-limit-after-edit"
  [ "$(state_get plan_stop_verdict_at)" = 2000-01-01T00:00:00Z ] || fail "triaged-round-limit-after-edit keeps the LINES stop time"

  # A ruling always comes from the current ticket and must postdate its stop.
  setup_case triaged-ruling-source
  rebase_plan
  write_triaged_tasks_plan
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-ruling-source records a LINES verdict"
  set_ruling_comment 'Use exact wording.' '2099-01-01T00:00:00Z' 519
  : >"$T/gh.log"
  run_plan triaged --comment 654320
  [ "$RC" -eq 1 ] || fail "triaged-ruling-source refuses a comment on another issue"
  expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=ruling-source issue=518 log=*" "triaged-ruling-source"
  grep -Fq 'gh|api repos/switchyard/issues/comments/654320' "$T/gh.log" || fail "triaged-ruling-source fetches the comment"

  setup_case triaged-ruling-stale
  rebase_plan
  write_triaged_tasks_plan
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-ruling-stale records a LINES verdict"
  awk '{ if ($0 == "- Open line: clarify the task wording.") print "- Comment 654321 settles the open line."; else print }' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
  set_ruling_comment 'Use exact wording.' '2000-01-01T00:00:00Z'
  run_plan triaged --comment 654321
  [ "$RC" -eq 1 ] || fail "triaged-ruling-stale refuses a comment before the stop verdict"
  expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=ruling-stale log=*" "triaged-ruling-stale"

  setup_case triaged-ruling-missing-stop-time
  rebase_plan
  write_triaged_tasks_plan
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-ruling-missing-stop-time records a LINES verdict"
  bash "$TKT_STATE" "$S" set plan_stop_verdict_at "" || fail "clear triaged stop timestamp"
  bash "$TKT_STATE" "$S" set plan_verdict_at "" || fail "clear triaged plan verdict timestamp"
  set_ruling_comment 'Use exact wording.'
  run_plan triaged --comment 654321
  [ "$RC" -eq 1 ] || fail "triaged-ruling-missing-stop-time refuses a missing stop timestamp"
  expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=ruling-stale log=*" "triaged-ruling-missing-stop-time"

  # Keep the pre-existing Rulings-only success and unrelated Files-diff
  # refusal on the focused path too.
  setup_case triaged-focused-ruling-only
  rebase_plan
  base_now="$(cat "$CDIR/base")"
  printf 'Base: %s\n\n## Rulings\n\n- Open line: use the default behavior.\n\n## Files\n\n- `f.txt`\n\n## Gate\n\n`true`\n' "$base_now" >"$CDIR/plan.md"
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-focused-ruling-only records a LINES verdict"
  awk '{ if ($0 == "- Open line: use the default behavior.") print "- Comment 654321 settles the open line."; else print }' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
  set_ruling_comment 'Use the default behavior.'
  run_plan triaged --comment 654321
  [ "$RC" -eq 0 ] || fail "triaged-focused-ruling-only preserves Rulings-only acceptance (rc=$RC): $(first_line)"
  expect_plan_verdict triaged "$base_now" "triaged-focused-ruling-only"
  [ "$(state_get plan_triage_comment)" = 654321 ] || fail "triaged-focused-ruling-only records the comment id"

  setup_case triaged-focused-other-diff
  rebase_plan
  base_now="$(cat "$CDIR/base")"
  printf 'Base: %s\n\n## Rulings\n\n- Open line: use the default behavior.\n\n## Files\n\n- `f.txt`\n\n## Gate\n\n`true`\n' "$base_now" >"$CDIR/plan.md"
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-focused-other-diff records a LINES verdict"
  awk '{ if ($0 == "- `f.txt`") print "- `g.txt`"; else print }' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
  set_ruling_comment 'The unrelated Files change is not ruled.'
  run_plan triaged --comment 654322
  [ "$RC" -eq 1 ] || fail "triaged-focused-other-diff refuses a nonverbatim Files change"
  expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=plan-changed log=*" "triaged-focused-other-diff"
  diff_file="$(sed -n 's/^EXTRA diff: //p' <<<"$OUT")"
  [ -n "$diff_file" ] && [ -r "$diff_file" ] || fail "triaged-focused-other-diff keeps the scoped diff"
  grep -Fq "verify --extra $diff_file" <<<"$OUT" || fail "triaged-focused-other-diff points at one scoped Verifier pass"

  # A quote permits a task line to be applied verbatim without spending another
  # Verifier round, and the accepted plan diff remains journaled in run/.
  setup_case triaged-verbatim
  rebase_plan
  write_triaged_interfaces_plan
  base_now="$(cat "$CDIR/base")"
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-verbatim records a LINES verdict"
  jobs_before="$(grep -c '^job|slot=verifier-' "$T/stub.log" || true)"
  awk '{ if ($0 == "- Open line: clarify the interface wording.") print "- Comment 654323 rules: apply the interface wording exactly."; else if ($0 == "1. Preserve the existing interface.") print "1. Use the revised interface."; else print }' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
  set_ruling_comment $'  - Preserve the existing interface.  \n  - Use the revised interface.  '
  : >"$T/gh.log"
  run_plan triaged --comment 654323
  [ "$RC" -eq 0 ] || fail "triaged-verbatim accepts the quoted Interfaces edit (rc=$RC): $(first_line)"
  expect_verdict "TKT tkt-plan SET triaged=654323 plan-diff=* log=*" "triaged-verbatim success names its diff"
  expect_plan_verdict triaged "$base_now" "triaged-verbatim records a passing verdict"
  expect_current_plan_verdict_hash "triaged-verbatim records the current plan hash"
  [ "$(state_get plan_triage_comment)" = 654323 ] || fail "triaged-verbatim records the ruling comment id"
  [ "$(state_get verifier_round)" = 1 ] || fail "triaged-verbatim does not spend a Verifier round"
  [ "$(grep -c '^job|slot=verifier-' "$T/stub.log" || true)" = "$jobs_before" ] || fail "triaged-verbatim starts no additional Verifier"
  diff_file="$(sed -n 's/.*plan-diff=\([^ ]*\).*/\1/p' <<<"$(first_line)")"
  [ -r "$diff_file" ] && [[ "$diff_file" == "$CDIR/run/"* ]] || fail "triaged-verbatim keeps the plan diff in run/: [$diff_file]"
  grep -Fq "gh|api repos/switchyard/issues/comments/654323" "$T/gh.log" || fail "triaged-verbatim reads the ruling comment through gh api"

  # One unquoted addition makes the whole outside-Rulings edit ineligible.
  setup_case triaged-verbatim-extra-line
  rebase_plan
  write_triaged_interfaces_plan
  base_now="$(cat "$CDIR/base")"
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-verbatim-extra-line records a LINES verdict"
  awk '{ if ($0 == "- Open line: clarify the interface wording.") print "- Comment 654324 rules: apply the interface wording exactly."; else if ($0 == "1. Preserve the existing interface.") { print "1. Use the revised interface."; print "2. Add this unquoted interface." } else print }' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
  set_ruling_comment $'  - Preserve the existing interface.  \n  - Use the revised interface.  '
  : >"$T/gh.log"
  run_plan triaged --comment 654324
  [ "$RC" -eq 1 ] || fail "triaged-verbatim-extra-line refuses an unquoted task"
  expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=plan-changed log=*" "triaged-verbatim-extra-line"
  grep -Fq 'first unmatched line: 2. Add this unquoted interface.' <<<"$OUT" || fail "triaged-verbatim-extra-line names its first unmatched line: $OUT"
  [ "$(state_get plan_verdict)" = lines ] || fail "triaged-verbatim-extra-line preserves the LINES verdict"
  [ -z "$(state_get plan_triage_comment)" ] || fail "triaged-verbatim-extra-line does not record triage"

  # A deleted Gate command is covered by the ruling check just like an addition.
  setup_case triaged-deleted-gate
  rebase_plan
  write_triaged_tasks_plan
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-deleted-gate records a LINES verdict"
  awk '{ if ($0 == "- Open line: clarify the task wording.") print "- Comment 654327 rules: use the exact task wording."; else if ($0 == "`true`") next; else print }' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
  set_ruling_comment 'Use the exact wording.'
  run_plan triaged --comment 654327
  [ "$RC" -eq 1 ] || fail "triaged-deleted-gate refuses an unquoted deleted Gate line"
  expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=plan-changed log=*" "triaged-deleted-gate"
  grep -Fq 'first unmatched line: `true`' <<<"$OUT" || fail "triaged-deleted-gate names the deleted Gate line: $OUT"

  # A quoted line cannot be accepted against a plan whose Base has moved.
  setup_case triaged-verbatim-base-moved
  rebase_plan
  write_triaged_tasks_plan
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-verbatim-base-moved records a LINES verdict"
  awk '{ if ($0 == "1. Keep the existing task wording.") print "1. Use the exact wording."; else print }' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
  set_plan_base "$(git -C "$WT" rev-parse HEAD^)"
  set_ruling_comment 'Use the exact wording.'
  : >"$T/gh.log"
  run_plan triaged --comment 654325
  [ "$RC" -eq 1 ] || fail "triaged-verbatim-base-moved refuses a moved Base"
  expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=plan-changed log=*" "triaged-verbatim-base-moved"
  [ "$(state_get plan_verdict)" = lines ] || fail "triaged-verbatim-base-moved preserves the LINES verdict"
  [ -n "$(grep -F 'gh|api repos/switchyard/issues/comments/654325' "$T/gh.log" || true)" ] || fail "triaged-verbatim-base-moved always reads the ruling comment"
fi

if [ -z "${TKT_PLAN_TEST_ONLY:-}" ] || [ "$TKT_PLAN_TEST_ONLY" = stale-recovery ]; then
  # A changed cited symbol with a plan-body edit gets a full drift review, not
  # the symbol-limited note reserved for an unchanged plan body.
  setup_case reanchor-body-edited
  mkdir -p "$WT/src"
  wcommit "$WT" src/lib.rs $'pub fn cited_one() {\n    let value = 1;\n}\npub fn cited_two() {\n    let value = 2;\n}\n'
  A="$(git -C "$WT" rev-parse HEAD)"
  git -C "$WT" update-ref refs/remotes/origin/main "$A"
  {
    printf 'Base: %s\n\n## Files\n\n- `src/lib.rs`\n\n## Tasks\n\n1. Preserve `src/lib.rs::cited_one` and `src/lib.rs::cited_two`.\n\n## Gate\n\n`true`\n' "$A"
  } >"$CDIR/plan.md"
  printf 'real' >"$T/pcmode"
  printf 'ok' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 0 ] || fail "reanchor-body-edited initial verify exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
  bash "$TKT_STATE" "$S" set verifier_round 2 || fail "reanchor-body-edited seed exhausted Verifier count"
  bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "reanchor-body-edited seed confirm count"
  wcommit "$WT" src/lib.rs $'pub fn cited_one() {\n    let value = 1;\n}\npub fn cited_two() {\n    let value = 22;\n}\n'
  B="$(git -C "$WT" rev-parse HEAD)"
  git -C "$WT" update-ref refs/remotes/origin/main "$B"
  awk '{ if ($0 == "1. Preserve `src/lib.rs::cited_one` and `src/lib.rs::cited_two`.") print "1. Carefully preserve `src/lib.rs::cited_one` and `src/lib.rs::cited_two`."; else print }' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
  set_plan_base "$B"
  : >"$T/stub.log"
  run_plan verify
  [ "$RC" -eq 0 ] || fail "reanchor-body-edited dispatches a drift verify (rc=$RC): $(cat "$CDIR/stderr.txt")"
  expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "reanchor-body-edited"
  grep -q 'slot=verifier-r3-drift' "$T/stub.log" || fail "reanchor-body-edited uses a drift Verifier slot"
  reanchor_edited_extra="$CDIR/run/switchyard-518-verifier-extra-r3-drift.md"
  if grep -Fq 'Re-anchor review is limited to these cited symbols:' "$reanchor_edited_extra"; then fail "reanchor-body-edited does not limit review of an edited plan body"; fi
  if grep -Fq 'Re-anchor review is limited to these cited symbols:' <<<"$OUT"; then fail "reanchor-body-edited output does not limit review of an edited plan body"; fi

  # Task-path drift remains exempt for a cited plan whose body changed, so
  # mechanical re-anchor does not apply.
  setup_case reanchor-task-path-drift
  mkdir -p "$WT/src"
  wcommit "$WT" src/lib.rs $'pub fn cited() {\n    let value = 1;\n}\n'
  wcommit "$WT" task.txt "task source v1"
  A="$(git -C "$WT" rev-parse HEAD)"
  git -C "$WT" update-ref refs/remotes/origin/main "$A"
  {
    printf 'Base: %s\n\n## Files\n\n- `src/lib.rs`\n- `task.txt`\n\n## Tasks\n\n1. Inspect `task.txt` and preserve `src/lib.rs::cited`.\n\n## Gate\n\n`true`\n' "$A"
  } >"$CDIR/plan.md"
  printf 'real' >"$T/pcmode"
  printf 'ok' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 0 ] || fail "reanchor-task-path-drift initial verify exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
  bash "$TKT_STATE" "$S" set verifier_round 2 || fail "reanchor-task-path-drift seed exhausted Verifier count"
  bash "$TKT_STATE" "$S" set confirmed_for 2 || fail "reanchor-task-path-drift seed confirm count"
  wcommit "$WT" task.txt "task source v2"
  B="$(git -C "$WT" rev-parse HEAD)"
  git -C "$WT" update-ref refs/remotes/origin/main "$B"
  awk '{ if ($0 == "1. Inspect `task.txt` and preserve `src/lib.rs::cited`.") print "1. Inspect `task.txt` carefully and preserve `src/lib.rs::cited`."; else print }' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
  set_plan_base "$B"
  : >"$T/stub.log"
  run_plan verify
  [ "$RC" -eq 0 ] || fail "reanchor-task-path-drift exempt verify runs at the round limit (rc=$RC): $(first_line)"
  expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "reanchor-task-path-drift"
  grep -q 'slot=verifier-r3-drift' "$T/stub.log" || fail "reanchor-task-path-drift uses the drift slot"
  [ "$(state_get verifier_round)" = 2 ] || fail "reanchor-task-path-drift leaves the round budget unchanged"
  [ "$(state_get confirmed_for)" = 2 ] || fail "reanchor-task-path-drift preserves the confirm count"

  # A build stale-recovery verify exempts changed plan Files even when the
  # plan's resolved Task paths do not include the changed file.
  setup_case build-stale-recovery-drift
  wcommit "$WT" task.txt "task source"
  git -C "$WT" update-ref refs/remotes/origin/main HEAD
  A="$(git -C "$WT" rev-parse HEAD)"
  bash "$TKT_STATE" "$S" set verifier_round 2 || fail "build-stale-recovery-drift seed round"
  bash "$TKT_STATE" "$S" set verified_base "$A" || fail "build-stale-recovery-drift seed verified base"
  wcommit "$WT" f.txt v3
  git -C "$WT" update-ref refs/remotes/origin/main HEAD
  B="$(git -C "$WT" rev-parse HEAD)"
  {
    printf 'Base: %s\n' "$B"
    printf '\n## Files\n\n- `f.txt`\n- `task.txt`\n\n## Tasks\n\n1. Inspect `task.txt`.\n\n## Gate\n\n`true`\n'
  } >"$CDIR/plan.md"
  bash "$TKT_STATE" "$S" set build_stale_recovery_base "$B" || fail "build-stale-recovery-drift seed recovery Base"
  bash "$TKT_STATE" "$S" set build_stale_recovery_plan_hash "$(git -C "$WT" hash-object "$CDIR/plan.md")" || fail "build-stale-recovery-drift seed recovery plan hash"
  printf 'ok' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 0 ] || fail "build-stale-recovery-drift exempt verify runs at the round limit (rc=$RC): $(first_line)"
  expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "build-stale-recovery-drift"
  grep -q 'slot=verifier-r3-drift' "$T/stub.log" || fail "build-stale-recovery-drift uses the drift slot"
  [ "$(state_get verifier_round)" = 2 ] || fail "build-stale-recovery-drift leaves the round budget unchanged"
  [ -z "$(state_get build_stale_recovery_base)" ] || fail "build-stale-recovery-drift clears the recovery Base"
  [ -z "$(state_get build_stale_recovery_plan_hash)" ] || fail "build-stale-recovery-drift clears the recovery plan hash"
  # Build stale recovery keeps the drift exemption for a plan with citations.
  setup_case build-stale-recovery-cited
  mkdir -p "$WT/src"
  wcommit "$WT" src/lib.rs $'pub fn cited() {\n    let value = 1;\n}\n'
  wcommit "$WT" task.txt "task source"
  git -C "$WT" update-ref refs/remotes/origin/main HEAD
  A="$(git -C "$WT" rev-parse HEAD)"
  bash "$TKT_STATE" "$S" set verifier_round 2 || fail "build-stale-recovery-cited seed round"
  bash "$TKT_STATE" "$S" set verified_base "$A" || fail "build-stale-recovery-cited seed verified base"
  wcommit "$WT" f.txt v3
  git -C "$WT" update-ref refs/remotes/origin/main HEAD
  B="$(git -C "$WT" rev-parse HEAD)"
  {
    printf 'Base: %s\n' "$B"
    printf '\n## Files\n\n- `f.txt`\n- `task.txt`\n- `src/lib.rs`\n\n## Tasks\n\n1. Inspect `task.txt`.\n\n## Rulings\nPreserve `src/lib.rs::cited`.\n\n## Gate\n\n`true`\n'
  } >"$CDIR/plan.md"
  bash "$TKT_STATE" "$S" set build_stale_recovery_base "$B" || fail "build-stale-recovery-cited seed recovery Base"
  bash "$TKT_STATE" "$S" set build_stale_recovery_plan_hash "$(git -C "$WT" hash-object "$CDIR/plan.md")" || fail "build-stale-recovery-cited seed recovery plan hash"
  printf 'ok' >"$T/mode"
  : >"$T/stub.log"
  run_plan verify
  [ "$RC" -eq 0 ] || fail "build-stale-recovery-cited exempt verify runs at the round limit (rc=$RC): $(first_line)"
  expect_verdict "TKT tkt-plan PLAN-OK out=* log=*" "build-stale-recovery-cited"
  grep -q 'slot=verifier-r3-drift' "$T/stub.log" || fail "build-stale-recovery-cited uses the drift slot"
  [ "$(state_get verifier_round)" = 2 ] || fail "build-stale-recovery-cited leaves the round budget unchanged"
  [ -z "$(state_get build_stale_recovery_base)" ] || fail "build-stale-recovery-cited clears the recovery Base"
  [ -z "$(state_get build_stale_recovery_plan_hash)" ] || fail "build-stale-recovery-cited clears the recovery plan hash"
fi

if [ -z "${TKT_PLAN_TEST_ONLY:-}" ] || [ "$TKT_PLAN_TEST_ONLY" = amendment ]; then
  # After the Verifier budget is spent, an unmatched triaged edit must point to
  # grant-round + confirm rather than a verify --extra that ROUND-LIMIT rejects.
  setup_case triaged-verbatim-spent-rounds
  rebase_plan
  write_triaged_interfaces_plan
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-verbatim-spent-rounds records a LINES verdict"
  bash "$TKT_STATE" "$S" set verifier_round 2 || fail "triaged-verbatim-spent-rounds seed spent rounds"
  awk '{ if ($0 == "1. Preserve the existing interface.") print "1. Add an unquoted interface."; else print }' "$CDIR/plan.md" >"$CDIR/plan.tmp" && mv "$CDIR/plan.tmp" "$CDIR/plan.md"
  set_ruling_comment 'No interface-line quote here.'
  : >"$T/gh.log"
  run_plan triaged --comment 654326
  [ "$RC" -eq 1 ] || fail "triaged-verbatim-spent-rounds refuses the unmatched interface edit"
  expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=plan-changed log=*" "triaged-verbatim-spent-rounds"
  diff_file="$(sed -n 's/^EXTRA diff: //p' <<<"$OUT")"
  [ -n "$diff_file" ] && [ -r "$diff_file" ] || fail "triaged-verbatim-spent-rounds exposes its diff"
  grep -Fq "run tkt-plan $S grant-round --by <who> --comment <id>, then tkt-plan $S confirm --edits $diff_file" <<<"$OUT" || fail "triaged-verbatim-spent-rounds names the grant-round + confirm repair: $OUT"
  ! grep -Fq 'verify --extra' <<<"$OUT" || fail "triaged-verbatim-spent-rounds does not suggest verify --extra: $OUT"

  # A pasted diff is a ruling when its added lines match, fenced or bare.
  setup_case triaged-pasted-diff-fenced
  rebase_plan
  write_triaged_interfaces_plan
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-pasted-diff-fenced records LINES"
  replace_plan_line '1. Preserve the existing interface.' '1. Use the revised interface.'
  set_ruling_comment $'Apply the quoted change:\n```diff\n-1. Preserve the existing interface.\n+1. Use the revised interface.\n```'
  run_plan triaged --comment 700001
  [ "$RC" -eq 0 ] || fail "triaged-pasted-diff-fenced accepts the fenced diff (rc=$RC): $OUT"
  expect_plan_verdict triaged "$(cat "$CDIR/base")" "triaged-pasted-diff-fenced"

  setup_case triaged-pasted-diff-bare
  rebase_plan
  write_triaged_interfaces_plan
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-pasted-diff-bare records LINES"
  replace_plan_line '1. Preserve the existing interface.' '1. Use the revised interface.'
  set_ruling_comment $'Apply the quoted change:\n-1. Preserve the existing interface.\n+1. Use the revised interface.'
  run_plan triaged --comment 700002
  [ "$RC" -eq 0 ] || fail "triaged-pasted-diff-bare accepts bare diff lines (rc=$RC): $OUT"

  # Every added line must be quoted, and the refusal names the missing one.
  setup_case triaged-pasted-diff-missing-line
  rebase_plan
  write_triaged_interfaces_plan
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-pasted-diff-missing-line records LINES"
  replace_plan_line '1. Preserve the existing interface.' $'1. Use the revised interface.\n2. Add the second interface.'
  set_ruling_comment $'```diff\n-1. Preserve the existing interface.\n+1. Use the revised interface.\n```'
  run_plan triaged --comment 700003
  [ "$RC" -eq 1 ] || fail "triaged-pasted-diff-missing-line refuses an unquoted addition"
  expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=plan-changed log=*" "triaged-pasted-diff-missing-line"
  grep -Fq 'first unmatched line: 2. Add the second interface.' <<<"$OUT" || fail "triaged-pasted-diff-missing-line names the missing line: $OUT"

  # A pasted deletion line is a ruling; omitting it names the deleted line.
  setup_case triaged-pasted-diff-deletion
  rebase_plan
  write_triaged_interfaces_plan
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-pasted-diff-deletion records LINES"
  replace_plan_line '1. Preserve the existing interface.' ''
  set_ruling_comment $'```diff\n-1. Preserve the existing interface.\n```'
  run_plan triaged --comment 700004
  [ "$RC" -eq 0 ] || fail "triaged-pasted-diff-deletion accepts its deleted line (rc=$RC): $OUT"

  setup_case triaged-pasted-diff-deletion-missing
  rebase_plan
  write_triaged_interfaces_plan
  printf 'lines' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 1 ] || fail "triaged-pasted-diff-deletion-missing records LINES"
  replace_plan_line '1. Preserve the existing interface.' ''
  set_ruling_comment 'This ruling does not quote the deleted line.'
  run_plan triaged --comment 700005
  [ "$RC" -eq 1 ] || fail "triaged-pasted-diff-deletion-missing refuses an unquoted deletion"
  expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=plan-changed log=*" "triaged-pasted-diff-deletion-missing"
  grep -Fq 'first unmatched line: 1. Preserve the existing interface.' <<<"$OUT" || fail "triaged-pasted-diff-deletion-missing names the deleted line: $OUT"

  # PLAN-OK has no stop time, so its verdict time governs ruling freshness.
  setup_case triaged-plan-ok-newer-ruling
  rebase_plan
  write_triaged_interfaces_plan
  printf 'ok' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 0 ] || fail "triaged-plan-ok-newer-ruling records PLAN-OK (rc=$RC): $(first_line) $(cat "$CDIR/stderr.txt")"
  [ -n "$(state_get plan_verdict_at)" ] || fail "PLAN-OK records its verdict time"
  replace_plan_line '1. Preserve the existing interface.' '1. Use the revised interface.'
  bash "$TKT_STATE" "$S" set plan_verdict_at 2000-01-01T00:00:00Z || fail "seed old PLAN-OK verdict time"
  # Dated after the seeded verdict but before the triaged verdict this run records.
  set_ruling_comment $'```diff\n-1. Preserve the existing interface.\n+1. Use the revised interface.\n```' 2001-01-01T00:00:00Z
  run_plan triaged --comment 700006
  [ "$RC" -eq 0 ] || fail "triaged-plan-ok-newer-ruling accepts a newer quoted ruling (rc=$RC): $OUT"
  expect_plan_verdict triaged "$(cat "$CDIR/base")" "triaged-plan-ok-newer-ruling"
  triaged_verdict_at="$(state_get plan_verdict_at)"
  [ -n "$triaged_verdict_at" ] && [ "$triaged_verdict_at" != 2000-01-01T00:00:00Z ] || fail "passing triaged refreshes the plan verdict time"
  # Replaying the same comment after it passed triaged is stale.
  run_plan triaged --comment 700006
  [ "$RC" -eq 1 ] || fail "triaged-plan-ok-newer-ruling refuses a replay of comment 700006 (rc=$RC): $OUT"
  expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=ruling-stale log=*" "triaged-plan-ok-newer-ruling-replay"

  setup_case triaged-plan-ok-old-ruling
  rebase_plan
  write_triaged_interfaces_plan
  printf 'ok' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 0 ] || fail "triaged-plan-ok-old-ruling records PLAN-OK"
  replace_plan_line '1. Preserve the existing interface.' '1. Use the revised interface.'
  set_ruling_comment 'The ruling is older than PLAN-OK.' 2000-01-01T00:00:00Z
  run_plan triaged --comment 700007
  [ "$RC" -eq 1 ] || fail "triaged-plan-ok-old-ruling refuses an older ruling"
  expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=ruling-stale log=*" "triaged-plan-ok-old-ruling"

  setup_case triaged-plan-ok-unquoted
  rebase_plan
  write_triaged_interfaces_plan
  printf 'ok' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 0 ] || fail "triaged-plan-ok-unquoted records PLAN-OK"
  replace_plan_line '1. Preserve the existing interface.' '1. Use the revised interface.'
  set_ruling_comment 'This newer ruling does not quote the edit.'
  run_plan triaged --comment 700008
  [ "$RC" -eq 1 ] || fail "triaged-plan-ok-unquoted refuses an unquoted edit"
  expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=plan-changed log=*" "triaged-plan-ok-unquoted"

  setup_case triaged-plan-ok-ruling-replay
  rebase_plan
  write_triaged_interfaces_plan
  printf 'ok' >"$T/mode"
  run_plan verify
  [ "$RC" -eq 0 ] || fail "triaged-plan-ok-ruling-replay records PLAN-OK"
  replace_plan_line '1. Preserve the existing interface.' '1. Use the revised interface.'
  set_ruling_comment $'```diff\n-1. Preserve the existing interface.\n+1. Use the revised interface.\n```'
  run_plan triaged --comment 700009
  [ "$RC" -eq 0 ] || fail "triaged-plan-ok-ruling-replay accepts the first ruling"
  set_ruling_comment 'Replay an older ruling.' 2000-01-01T00:00:00Z
  run_plan triaged --comment 700010
  [ "$RC" -eq 1 ] || fail "triaged-plan-ok-ruling-replay refuses an older ruling after triage"
  expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=ruling-stale log=*" "triaged-plan-ok-ruling-replay"

  # Quoting cannot bypass the Verifier requirement for structural sections.
  for section in Files Gate Tasks; do
    setup_case "triaged-protected-$section"
    rebase_plan
    write_triaged_interfaces_plan
    printf 'lines' >"$T/mode"
    run_plan verify
    [ "$RC" -eq 1 ] || fail "triaged-protected-$section records LINES"
    case "$section" in
      Files) old_line='- `f.txt`'; new_line='- `g.txt`' ;;
      Gate) old_line='`true`'; new_line='`false`' ;;
      Tasks) old_line='1. Preserve the existing task.'; new_line='1. Revise the existing task.' ;;
    esac
    replace_plan_line "$old_line" "$new_line"
    set_ruling_comment "$(printf '```diff\n-%s\n+%s\n```' "$old_line" "$new_line")"
    run_plan triaged --comment 700011
    [ "$RC" -eq 1 ] || fail "triaged-protected-$section refuses a quoted structural edit"
    expect_verdict "TKT tkt-plan TRIAGED-REFUSED reason=plan-changed log=*" "triaged-protected-$section"
  done
fi

# A steward ruling records PLAN-OK only for the current, fresh plan and a
# comment on this issue that follows the latest plan/stop verdict.
if [ -z "${TKT_PLAN_TEST_ONLY:-}" ] || [ "$TKT_PLAN_TEST_ONLY" = rule-ok ]; then
  setup_case rule-ok-invalid-steward
  rebase_plan
  run_plan rule-ok --by owner --ruling RULING-1604 --comment 654001
  [ "$RC" -eq 1 ] || fail "rule-ok-invalid-steward refuses an unapproved steward"
  expect_verdict "TKT tkt-plan RULE-OK-REFUSED reason=steward log=*" "rule-ok-invalid-steward"

  setup_case rule-ok-comment-fetch
  rebase_plan
  bash "$TKT_STATE" "$S" set plan_verdict_at 2000-01-01T00:00:00Z || fail "seed rule-ok comment-fetch verdict time"
  rm -f "$T/comment.json"
  run_plan rule-ok --by surveyor --ruling RULING-1604 --comment 654002
  [ "$RC" -eq 1 ] || fail "rule-ok-comment-fetch refuses an unreadable comment"
  expect_verdict "TKT tkt-plan RULE-OK-REFUSED reason=comment-fetch log=*" "rule-ok-comment-fetch"

  setup_case rule-ok-comment-issue
  rebase_plan
  bash "$TKT_STATE" "$S" set plan_verdict_at 2000-01-01T00:00:00Z || fail "seed rule-ok comment-issue verdict time"
  set_ruling_comment 'Steward ruling RULING-1604.' 2099-01-01T00:00:00Z 519
  run_plan rule-ok --by surveyor --ruling RULING-1604 --comment 654003
  [ "$RC" -eq 1 ] || fail "rule-ok-comment-issue refuses another issue's comment"
  expect_verdict "TKT tkt-plan RULE-OK-REFUSED reason=comment-issue log=*" "rule-ok-comment-issue"

  setup_case rule-ok-before-plan-verdict
  rebase_plan
  bash "$TKT_STATE" "$S" set plan_verdict_at 2010-01-01T00:00:00Z || fail "seed rule-ok latest plan verdict time"
  bash "$TKT_STATE" "$S" set plan_stop_verdict_at 2000-01-01T00:00:00Z || fail "seed rule-ok older stop time"
  set_ruling_comment 'Steward ruling RULING-1604.' 2005-01-01T00:00:00Z
  run_plan rule-ok --by surveyor --ruling RULING-1604 --comment 654004
  [ "$RC" -eq 1 ] || fail "rule-ok-before-plan-verdict refuses an old comment"
  expect_verdict "TKT tkt-plan RULE-OK-REFUSED reason=comment-time log=*" "rule-ok-before-plan-verdict"

  setup_case rule-ok-before-stop-verdict
  rebase_plan
  bash "$TKT_STATE" "$S" set plan_verdict_at 2000-01-01T00:00:00Z || fail "seed rule-ok older plan verdict time"
  bash "$TKT_STATE" "$S" set plan_stop_verdict_at 2010-01-01T00:00:00Z || fail "seed rule-ok latest stop time"
  set_ruling_comment 'Steward ruling RULING-1604.' 2005-01-01T00:00:00Z
  run_plan rule-ok --by surveyor --ruling RULING-1604 --comment 654005
  [ "$RC" -eq 1 ] || fail "rule-ok-before-stop-verdict refuses an old comment"
  expect_verdict "TKT tkt-plan RULE-OK-REFUSED reason=comment-time log=*" "rule-ok-before-stop-verdict"

  setup_case rule-ok-missing-ruling
  rebase_plan
  bash "$TKT_STATE" "$S" set plan_verdict_at 2000-01-01T00:00:00Z || fail "seed rule-ok missing-ruling verdict time"
  set_ruling_comment 'Steward ruling RULING-OTHER.'
  run_plan rule-ok --by surveyor --ruling RULING-1604 --comment 654006
  [ "$RC" -eq 1 ] || fail "rule-ok-missing-ruling refuses a body without the requested id"
  expect_verdict "TKT tkt-plan RULE-OK-REFUSED reason=ruling-missing log=*" "rule-ok-missing-ruling"

  setup_case rule-ok-no-plan
  rebase_plan
  bash "$TKT_STATE" "$S" set plan "" || fail "clear rule-ok plan"
  run_plan rule-ok --by surveyor --ruling RULING-1604 --comment 654007
  [ "$RC" -eq 1 ] || fail "rule-ok-no-plan refuses when no plan is recorded"
  expect_verdict "TKT tkt-plan RULE-OK-REFUSED reason=plan log=*" "rule-ok-no-plan"

  setup_case rule-ok-fetch-failure
  rebase_plan
  : >"$T/fetch-fail"
  run_plan rule-ok --by surveyor --ruling RULING-1604 --comment 654008
  rm -f "$T/fetch-fail"
  [ "$RC" -eq 1 ] || fail "rule-ok-fetch-failure refuses when origin fetch fails"
  expect_verdict "TKT tkt-plan RULE-OK-REFUSED reason=stale-check log=*" "rule-ok-fetch-failure"
  grep -Fq 'fatal: simulated fetch failure' <<<"$OUT" || fail "rule-ok-fetch-failure prints the first fetch error line"

  setup_case rule-ok-stale
  : >"$T/git-fetch.log"
  bash "$TKT_STATE" "$S" set plan_verdict_at 2000-01-01T00:00:00Z || fail "seed rule-ok stale verdict time"
  set_ruling_comment 'Steward ruling RULING-1604: dispatch this exact plan.'
  run_plan rule-ok --by surveyor --ruling RULING-1604 --comment 654008
  [ "$RC" -eq 1 ] || fail "rule-ok-stale refuses a plan behind origin/main"
  expect_verdict "TKT tkt-plan RULE-OK-REFUSED reason=stale log=*" "rule-ok-stale"
  grep -Fq "fetch|-C $WT fetch -q origin main" "$T/git-fetch.log" || fail "rule-ok-stale fetches origin before checking staleness"
  grep -Fq "run implement's stale-plan check, revise the plan, then tkt-plan $S set $CDIR/plan.md, then rerun: tkt-plan $S rule-ok --by surveyor --ruling RULING-1604 --comment 654008" <<<"$OUT" || fail "rule-ok-stale prints the stale recovery sequence with the same comment"
  stale_plan_verdict_at="$(state_get plan_verdict_at)"
  rebase_plan
  run_plan set "$CDIR/plan.md"
  [ "$RC" -eq 0 ] || fail "rule-ok-stale set after rebase succeeds (rc=$RC): $(cat "$CDIR/stderr.txt")"
  expect_verdict "TKT tkt-plan SET plan=$CDIR/plan.md log=*" "rule-ok-stale set after rebase"
  [ "$(state_get plan_verdict_at)" = "$stale_plan_verdict_at" ] || fail "set after rebase preserves plan_verdict_at"
  run_plan rule-ok --by surveyor --ruling RULING-1604 --comment 654008
  [ "$RC" -eq 0 ] || fail "rule-ok-stale accepts the same comment after rebase and set (rc=$RC): $(cat "$CDIR/stderr.txt")"
  expect_verdict "TKT tkt-plan RULE-OK by=surveyor ruling=RULING-1604 comment=654008 log=*" "rule-ok-stale same-comment retry"


  setup_case rule-ok-already-ok
  rebase_plan
  bash "$TKT_STATE" "$S" set plan_verdict ok || fail "seed rule-ok already-ok verdict"
  bash "$TKT_STATE" "$S" set plan_verdict_base "$(cat "$CDIR/base")" || fail "seed rule-ok already-ok base"
  bash "$TKT_STATE" "$S" set plan_verdict_hash "$(git -C "$WT" hash-object -w "$CDIR/plan.md")" || fail "seed rule-ok already-ok hash"
  run_plan rule-ok --by surveyor --ruling RULING-1604 --comment 654009
  [ "$RC" -eq 1 ] || fail "rule-ok-already-ok refuses an existing PLAN-OK"
  expect_verdict "TKT tkt-plan RULE-OK-REFUSED reason=already-ok log=*" "rule-ok-already-ok"

  setup_case rule-ok-success
  rebase_plan
  bash "$TKT_STATE" "$S" set plan_verdict_at 2000-01-01T00:00:00Z || fail "seed rule-ok success verdict time"
  bash "$TKT_STATE" "$S" set plan_stop_verdict_at 2001-01-01T00:00:00Z || fail "seed rule-ok success stop time"
  set_ruling_comment 'Steward ruling RULING-1604: dispatch this exact plan.'
  run_plan rule-ok --by surveyor --ruling RULING-1604 --comment 654010
  [ "$RC" -eq 0 ] || fail "rule-ok-success records PLAN-OK (rc=$RC): $(cat "$CDIR/stderr.txt")"
  expect_verdict "TKT tkt-plan RULE-OK by=surveyor ruling=RULING-1604 comment=654010 log=*" "rule-ok-success"
  expect_plan_verdict ok "$(cat "$CDIR/base")" "rule-ok-success"
  expect_current_plan_verdict_hash "rule-ok-success"
  [ "$(state_get plan_verdict_by)" = surveyor ] || fail "rule-ok-success records steward provenance"
  [ "$(state_get plan_verdict_ruling)" = RULING-1604 ] || fail "rule-ok-success records ruling provenance"
  [ "$(state_get plan_verdict_comment)" = 654010 ] || fail "rule-ok-success records comment provenance"
  grep -Fq "next: tkt-build $S" <<<"$OUT" || fail "rule-ok-success prints tkt-build as the next step"
  grep -Fq 'tkt-plan rule-ok by=surveyor ruling=RULING-1604 comment=654010' "$CDIR/tkt.journal" || fail "rule-ok-success journals its ruling provenance"
fi

echo "tkt-plan: all cases passed"

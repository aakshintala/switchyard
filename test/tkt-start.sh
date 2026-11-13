#!/usr/bin/env bash
# Tests for bin/tkt-start: state, worktree, current check and preflight.
# One fixture builder (setup) and one stub dir serve every case; families
# differing by one flag or stub output run as table loops. HOME and TMPDIR
# point inside a temp dir; nothing touches the network or $HOME/.agents.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TKT="$SCRIPT_DIR/../bin/tkt-start"
fail() { echo "FAIL: $1" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/test-tkt-start.XXXXXX")"
T="$(cd "$T" && pwd)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp" "$T/bin" "$T/tktbin" "$T/cases"
export HOME="$T/home" TMPDIR="$T/tmp" TKT_BIN="$T/tktbin" FW_RUN="$T/fw-run"
export PATH="$T/bin:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t
mkdir -p "$HOME/.agents/skills/planning/briefs"
printf '# fixture preflight template\n' >"$HOME/.agents/skills/planning/briefs/preflight.md"
TEMPLATE="$HOME/.agents/skills/planning/briefs/preflight.md"
cat >"$T/bin/gh" <<EOF
#!/usr/bin/env bash
printf 'gh|%s\n' "\$*" >>"$T/calls.log"
if [ -f "$T/gh-fail" ]; then exit 4; fi
case " \$* " in
  *" api --paginate "*)
    if [ -f "$T/api-fail" ]; then echo "gh: api files boom" >&2; exit 5; fi
    if [ -f "$T/api-files" ]; then cat "$T/api-files"; exit 0; fi
    url=""
    for arg in "\$@"; do case "\$arg" in repos/*/pulls/*/files\?*) url="\$arg";; esac; done
    pr="\${url#*/pulls/}"; pr="\${pr%%/*}"
    jq -r --arg n "\$pr" '.[] | select((.number|tostring) == \$n) | (.files // [])[] | .path' "$T/prlist"
    exit 0 ;;
  *" pr list "*)
    if [ -f "$T/prlist-fail" ]; then echo "gh: pr list boom" >&2; exit 5; fi
    cat "$T/prlist"; exit 0 ;;
  *" graphql "*) cat "$T/edited"; exit 0 ;;
  *" issue view "*" lastEditedAt "*)
    printf 'Unknown JSON field: "lastEditedAt"\n' >&2; exit 1 ;;
  *" pr view "*" --json state "*) cat "$T/prstate"; exit 0 ;;
  *" pr view "*) cat "$T/prhead"; exit 0 ;;
  *" issue view "*"state,comments"*)
    if [ -f "$T/issue-fail" ]; then echo "gh: issue view boom" >&2; exit 5; fi
    cat "$T/issue"; exit 0 ;;
  *)
    if [ -f "$T/body-fail" ]; then echo "gh: issue body boom" >&2; exit 4; fi
    cat "$T/body"; exit 0 ;;
esac
EOF
chmod +x "$T/bin/gh"
cat >"$T/bin/file-claim" <<EOF
#!/usr/bin/env bash
printf 'file-claim|%s\\n' "\$*" >>"$T/calls.log"
[ "\${1:-}" = claim ] || exit 2
printf 'GRANT takeover fence\\n'
EOF
chmod +x "$T/bin/file-claim"
export FW_FILE_CLAIM="$T/bin/file-claim"
cat >"$T/tktbin/plan-sweep" <<EOF
#!/usr/bin/env bash
printf 'plan-sweep|%s\n' "\$*" >>"$T/calls.log"
if [ -f "$T/sweep-fail" ]; then echo "plan-sweep: boom" >&2; exit 6; fi
if [ -f "$T/sweep-fail1" ]; then echo "plan-sweep: boom" >&2; exit 1; fi
if [ -f "$T/sweep-mixed" ]; then printf 'mkdir: cannot create directory: /x\nunresolved path: x\n'; exit 1; fi
if [ -f "$T/sweep-pure" ]; then printf 'unresolved path: x\nunresolved symbol: y\n'; exit 1; fi
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "--out" ] && out="\$a"; prev="\$a"; done
[ -n "\$out" ] && printf 'pack stub\n' >"\$out"
exit 0
EOF
chmod +x "$T/tktbin/plan-sweep"
cat >"$T/tktbin/tkt-job" <<EOF
#!/usr/bin/env bash
printf 'tkt-job|%s\n' "\$*" >>"$T/calls.log"
if [ -f "$T/job-fail" ]; then echo "tkt-job: boom" >&2; exit 3; fi
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "--out-file" ] && out="\$a"; prev="\$a"; done
[ -n "\$out" ] && cat "$T/jobout" >"\$out"
if [ -f "$T/job-blocked" ]; then echo "TKT tkt-job BLOCKED id=j1 log=x"; exit 1; fi
if [ -f "$T/job-concerns" ]; then [ -f "$T/job-noise" ] && { echo "watch noise" >&2; echo >&2; }; echo "TKT tkt-job CONCERNS id=j1 log=x"; echo "reviewer is uneasy"; exit 1; fi
exit 0
EOF
chmod +x "$T/tktbin/tkt-job"
cat >"$T/tktbin/plan-check" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$T/tktbin/plan-check"
ln -s "$SCRIPT_DIR/../bin/plan-gate" "$T/tktbin/plan-gate"
cat >"$T/tktbin/post-plan" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$T/post-plan.log"
printf 'https://example.invalid/comment/1\\n'
EOF
chmod +x "$T/tktbin/post-plan"
# reload [DROP]: rebuild ARGS from the shared flag set, minus DROP and its value.
reload() {
  ARGS=(); skip=0
  for a in --run "$RUN" --repo acme/widget --issue 42 --spec 42 --branch tkt-start \
    --worktree "$WT" --workflow-doc "$CDIR/wf.md" --closing "Resolves #42" --env "FOO=1" \
    --body-has "Resolves #42" --body-has "Co-authored with Claude Code." --extra "$CDIR/extra.md" \
    --merge-gate ci --merge-check 'cargo check --all-targets' --mutant-job Selection --model lane=sol --model preflight=luna --files f.txt; do
    if [ "$skip" -eq 1 ]; then skip=0; elif [ "$a" = "${1:-}" ]; then skip=1; else ARGS+=("$a"); fi
  done
}
build_case_template() {
  local dir="$1" add_change="$2" filing
  mkdir -p "$dir"
  git init -q --bare "$dir/origin.git"
  git --git-dir="$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q "$dir/seed"
  git -C "$dir/seed" symbolic-ref HEAD refs/heads/main
  git -C "$dir/seed" remote add origin "$dir/origin.git"
  git -C "$dir/seed" commit -q --allow-empty -m init
  printf '%s\n' one >"$dir/seed/f.txt"
  git -C "$dir/seed" add -A
  GIT_AUTHOR_DATE=2026-01-01T00:00:00+00:00 GIT_COMMITTER_DATE=2026-01-01T00:00:00+00:00 \
    git -C "$dir/seed" commit -q -m filing
  filing="$(git -C "$dir/seed" rev-parse HEAD)"
  printf '%s\n' "$filing" >"$dir/filing"
  if [ "$add_change" = yes ]; then
    printf '%s\n' two >"$dir/seed/f.txt"
    git -C "$dir/seed" add -A
    GIT_AUTHOR_DATE=2026-02-01T00:00:00+00:00 GIT_COMMITTER_DATE=2026-02-01T00:00:00+00:00 \
      git -C "$dir/seed" commit -q -m change
  fi
  git -C "$dir/seed" push -q origin HEAD:main
  git clone -q "$dir/origin.git" "$dir/clone" 2>/dev/null
}
TEMPLATES="$T/templates"
mkdir -p "$TEMPLATES"
build_case_template "$TEMPLATES/ONE" no
build_case_template "$TEMPLATES/TWO" yes

# setup NAME ONE|TWO AGAINST|FILING|SKIP: copy a private seed, origin and
# clone from the matching common fixture. Sets CDIR CLONE WT RUN FILING.
setup() {
  : >"$T/calls.log"; rm -f "$T/gh-fail" "$T/prlist-fail" "$T/api-fail" "$T/api-files" "$T/sweep-fail" "$T/sweep-fail1" "$T/sweep-mixed" "$T/sweep-pure" "$T/job-fail" "$T/job-concerns" "$T/job-noise" "$T/job-blocked" "$T/issue-fail"
  printf 'null\n' >"$T/edited"; : >"$T/prhead"; : >"$T/prstate"; printf '[]\n' >"$T/prlist"
  printf '%s\n' '{"state":"OPEN","comments":[]}' >"$T/issue"
  printf 'two core lines\n1. core -- first\n2. **core** -- second\n3. non-blocking -- other\nCore items: 2\nNon-blocking items: 1\nSTATUS: DONE\n' >"$T/jobout"
  CDIR="$T/cases/$1"; rm -rf "$CDIR"; mkdir -p "$CDIR"
  FW_RUN="$CDIR/fw-run"; export FW_RUN; mkdir -p "$FW_RUN"
  CASE_TEMPLATE="$TEMPLATES/$2"
  cp -R "$CASE_TEMPLATE/." "$CDIR/"
  ORIGIN="$CDIR/origin.git"; SEED="$CDIR/seed"; CLONE="$CDIR/clone"
  git -C "$SEED" remote set-url origin "$ORIGIN"
  git -C "$CLONE" remote set-url origin "$ORIGIN"
  FILING="$(cat "$CASE_TEMPLATE/filing")"
  WT="$CDIR/wt"; RUN="$CDIR/run"; mkdir -p "$RUN"
  printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
  [ "$3" = AGAINST ] && printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
  [ "$3" = FILING ] && printf 'Work for #42.\n\nfiling commit: %s\n' "$FILING" >"$T/body"
  reload
}
# run_start [EXTRA...]: run tkt-start in CLONE on ARGS; sets OUT and RC.
run_start() {
  RC=0; OUT="$(cd "$CLONE" && bash "$TKT" "${ARGS[@]}" "$@" 2>"$CDIR/stderr")" || RC=$?
  [ -n "$OUT" ] || OUT="$(cat "$CDIR/stderr")"
}
# want PREFIX RC NAME: RC matches, OUT line 1 carries PREFIX, its log= file exists.
want() {
  [ "$RC" -eq "$2" ] || fail "$3: exit $RC"
  first="$(printf '%s\n' "$OUT" | head -n 1)"
  case "$first" in "TKT tkt-start $1"*) ;; *) fail "$3: line 1 [$first] wants prefix [TKT tkt-start $1]" ;; esac
  log="${first##* log=}"; [ -n "$log" ] && [ -f "$log" ] || fail "$3: missing log file [$log]"
}
expect_state() {
  S="$RUN/widget-42.state"
  [ -f "$S" ] || fail "$1: no state file [$S]"
  for kv in "repo=acme/widget" "issue=42" "spec=42" "branch=tkt-start" "worktree=$WT" "run=$RUN" \
    "workflow_doc=$CDIR/wf.md" "closing=Resolves #42" "env=FOO=1" "extra=$CDIR/extra.md" \
    "merge_gate=ci" "merge_check=cargo check --all-targets" "mutant_job=Selection"; do
    grep -qF "$kv" "$S" || fail "$1: state misses [$kv]"
  done
  [ "$(grep -c '^body_has=' "$S")" -eq 2 ] || fail "$1: state wants 2 body_has lines"
  grep -qF "body_has=Resolves #42" "$S" || fail "$1: state misses body line 1"
  [ "$(grep -c '^model\.lane=' "$S")" -eq 1 ] || fail "$1: state wants 1 model.lane"
  [ "$(grep -c '^model\.preflight=' "$S")" -eq 1 ] || fail "$1: state wants 1 model.preflight"
  j="${S%.state}.journal"
  for step in "state " "worktree " "check "; do
    grep -q "tkt-start $step" "$j" || fail "$1: journal misses ${step}step"
  done
}
# A missing worktree needs a repository checkout as its starting point.
setup norepo ONE AGAINST
mkdir -p "$T/nonrepo"
[ ! -e "$WT" ] || fail "norepo: worktree unexpectedly exists"
RC=0; OUT="$(cd "$T/nonrepo" && bash "$TKT" "${ARGS[@]}" 2>"$CDIR/stderr")" || RC=$?
want "STEP-FAIL step=repo rc=128" 128 norepo
case "$OUT" in *"run from inside acme/widget's checkout"*) ;; *) fail "norepo: failure misses checkout guidance" ;; esac
[ ! -e "$RUN/widget-42.state" ] || fail "norepo: state was written"
# A worktree without the repo gate leaves gate.script unset; a worktree with
# an executable scripts/check seeds it automatically before planning starts.
setup gate-script-absent ONE AGAINST; run_start --no-preflight
want "SKIPPED filing=" 0 gate-script-absent
if grep -q '^gate\.script=' "$RUN/widget-42.state"; then fail "gate-script-absent: unexpected gate.script key"; fi

setup gate-script-present ONE AGAINST
git -C "$CLONE" worktree add --no-track -b tkt-start "$WT" origin/main >/dev/null
mkdir -p "$WT/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WT/scripts/check"
chmod +x "$WT/scripts/check"
run_start --no-preflight
want "SKIPPED filing=" 0 gate-script-present
grep -qxF 'gate.script=scripts/check' "$RUN/widget-42.state" \
  || fail "gate-script-present: state does not set gate.script to scripts/check"

setup takeover-no-files ONE AGAINST
reload --files
run_start --no-preflight --takeover '#123' --gate 'bash scripts/check'
[ "$RC" -eq 2 ] || fail "takeover-no-files: exit $RC, want 2"
grep -Fxq 'tkt-start: --takeover requires non-blank --files PATHS' "$CDIR/stderr" \
  || fail "takeover-no-files: refusal message missing: $(cat "$CDIR/stderr")"
[ ! -e "$RUN/widget-42.state" ] || fail "takeover-no-files: state was written before refusal"

setup takeover-blank-files ONE AGAINST
reload --files
run_start --no-preflight --takeover '#123' --gate 'bash scripts/check' --files '  '
[ "$RC" -eq 2 ] || fail "takeover-blank-files: exit $RC, want 2"
grep -Fxq 'tkt-start: --takeover requires non-blank --files PATHS' "$CDIR/stderr" \
  || fail "takeover-blank-files: refusal message missing: $(cat "$CDIR/stderr")"
[ ! -e "$RUN/widget-42.state" ] || fail "takeover-blank-files: state was written before refusal"

setup takeover ONE AGAINST
run_start --no-preflight --takeover '#123' --gate 'bash scripts/check'
want "SKIPPED filing=" 0 takeover
S="$RUN/widget-42.state"
grep -qxF 'plan=takeover #123' "$S" || fail "takeover: state does not record the source in plan"
grep -qxF 'gate=bash scripts/check' "$S" || fail "takeover: state does not record the gate"
grep -qxF 'fence=f.txt' "$S" || fail "takeover: --files did not seed the takeover fence"
claim_host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf unknown)"
grep -qxF "file-claim|claim --lane fiber-42 --paths --repo acme/widget --worktree $claim_host:$WT -- f.txt" "$T/calls.log" \
  || fail "takeover: --files did not claim/reuse its fence: $(grep '^file-claim|' "$T/calls.log" || true)"

after_takeover_calls="$(grep -c '^file-claim|' "$T/calls.log")"
[ "$after_takeover_calls" -eq 1 ] || fail "takeover did not make exactly one claim check"

# current, plus the resume path: a rerun reuses the worktree with no dup lines.
setup current ONE AGAINST; run_start
want "CURRENT " 0 current
expect_state current
[ -d "$WT" ] || fail "current: no worktree [$WT]"
[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "tkt-start" ] || fail "current: worktree not on tkt-start"
[ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$CLONE" rev-parse origin/main)" ] || fail "current: worktree not at origin/main"
git -C "$WT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 && fail "current: worktree tracks an upstream"
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "current: tkt-job must not run"
[ "$(grep -c '^plan-sweep|' "$T/calls.log")" -eq 0 ] || fail "current: plan-sweep must not run"
case "$OUT" in *"no edit info"*) ;; *) fail "current: digest misses edit evidence" ;; esac
run_start
want "CURRENT " 0 rerun
[ "$(grep -c '^body_has=' "$RUN/widget-42.state")" -eq 2 ] || fail "rerun: body_has duplicated"
[ "$(grep -c '^model\.lane=' "$RUN/widget-42.state")" -eq 1 ] || fail "rerun: model.lane duplicated"
# Resume the same physical run through a symlinked --run path. The duplicate
# scan must compare physical paths, not spellings of the same state file.
setup same-run-physical ONE AGAINST
run_start --no-preflight
want "SKIPPED filing=" 0 same-run-physical-first
ln -s "$RUN" "$CDIR/run-alias"
RUN="$CDIR/run-alias"; reload
run_start --no-preflight
want "SKIPPED filing=" 0 same-run-physical-resume

# A second run beside the existing one is refused before its state is written.
setup duplicate-sibling ONE AGAINST
run_start --no-preflight
want "SKIPPED filing=" 0 duplicate-sibling-first
existing_state="$(cd "$RUN" && pwd -P)/widget-42.state"; existing_run="$RUN"
RUN="$CDIR/sibling-run"; reload
run_start --no-preflight
want "DUPLICATE state=$existing_state run=$existing_run" 2 duplicate-sibling
case "$OUT" in *"resume with --run $existing_run"*) ;; *) fail "duplicate-sibling: output misses resume hint: $OUT" ;; esac
case "$OUT" in *"rename it to $existing_state.retired"*"pass --split <label>"*) ;; *) fail "duplicate-sibling: output misses retired/split exits: $OUT" ;; esac
[ ! -e "$RUN/widget-42.state" ] || fail "duplicate-sibling: second state was written"

# A run nested under FW_RUN cannot create a second state for a root-level run.
setup duplicate-child ONE AGAINST
RUN="$FW_RUN"; reload
run_start --no-preflight
want "SKIPPED filing=" 0 duplicate-child-first
existing_state="$(cd "$RUN" && pwd -P)/widget-42.state"; existing_run="$RUN"
RUN="$FW_RUN/child-run"; reload
run_start --no-preflight
want "DUPLICATE state=$existing_state run=$existing_run" 2 duplicate-child
case "$OUT" in *"resume with --run $existing_run"*) ;; *) fail "duplicate-child: output misses resume hint: $OUT" ;; esac
case "$OUT" in *"rename it to $existing_state.retired"*"pass --split <label>"*) ;; *) fail "duplicate-child: output misses retired/split exits: $OUT" ;; esac
[ ! -e "$RUN/widget-42.state" ] || fail "duplicate-child: second state was written"

# --split opts into a sibling run while preserving the label in its state.
setup split-sibling ONE AGAINST
run_start --no-preflight
want "SKIPPED filing=" 0 split-sibling-first
RUN="$CDIR/sibling-run"; reload
run_start --no-preflight --split a
want "SKIPPED filing=" 0 split-sibling
[ "$(sed -n 's/^split=//p' "$RUN/widget-42.state" | head -n 1)" = a ] \
  || fail "split-sibling: new state does not store split=a"

# A split label cannot change the identity of a state already in this run.
setup split-same-run ONE AGAINST
run_start --no-preflight
want "SKIPPED filing=" 0 split-same-run-first
existing_state="$(cd "$RUN" && pwd -P)/widget-42.state"
run_start --no-preflight --split b
want "DUPLICATE state=$existing_state split=none" 2 split-same-run
case "$OUT" in *"stored split=none"*"requested split=b"*) ;; *) fail "split-same-run: output misses both labels: $OUT" ;; esac
[ "$(grep -c '^split=' "$RUN/widget-42.state" || true)" -eq 0 ] \
  || fail "split-same-run: refused start modified state"

# Reusing the same split label follows the ordinary resume path.
setup split-same-label ONE AGAINST
run_start --no-preflight --split a
want "SKIPPED filing=" 0 split-same-label-first
run_start --no-preflight --split a
want "SKIPPED filing=" 0 split-same-label-resume
[ "$(grep -c '^split=a$' "$RUN/widget-42.state")" -eq 1 ] \
  || fail "split-same-label: state does not retain exactly one split=a"

# A plain start cannot resume a split part as if it were the whole ticket.
setup split-plain-resume ONE AGAINST
run_start --no-preflight --split a
want "SKIPPED filing=" 0 split-plain-resume-first
existing_state="$(cd "$RUN" && pwd -P)/widget-42.state"
run_start --no-preflight
want "DUPLICATE state=$existing_state split=a requested=none" 2 split-plain-resume
case "$OUT" in *"--split <label>"*) ;; *) fail "split-plain-resume: output misses --split <label> hint: $OUT" ;; esac
[ "$(grep -c '^split=a$' "$RUN/widget-42.state")" -eq 1 ] \
  || fail "split-plain-resume: refused start modified state"

# Labels are single non-blank words and reject whitespace or newlines.
for bad_split_case in blank whitespace newline; do
  setup "split-invalid-$bad_split_case" ONE AGAINST
  case "$bad_split_case" in
    blank) run_start --no-preflight --split '' ;;
    whitespace) run_start --no-preflight --split '  ' ;;
    newline) run_start --no-preflight --split $'a\nb' ;;
  esac
  [ "$RC" -eq 2 ] || fail "split-invalid-$bad_split_case: exit $RC, want 2"
  grep -qF -- '--split' "$CDIR/stderr" || fail "split-invalid-$bad_split_case: stderr does not name --split"
  [ ! -e "$RUN/widget-42.state" ] || fail "split-invalid-$bad_split_case: state was written"
done

# A sibling state with a terminal PR is no longer a live duplicate.
for terminal_pr_state in MERGED CLOSED; do
  setup "duplicate-terminal-$terminal_pr_state" ONE AGAINST
  run_start --no-preflight
  want "SKIPPED filing=" 0 "duplicate-terminal-$terminal_pr_state-first"
  "$SCRIPT_DIR/../bin/tkt-state" "$RUN/widget-42.state" set pr 123
  printf '%s\n' "$terminal_pr_state" >"$T/prstate"
  existing_state="$(cd "$RUN" && pwd -P)/widget-42.state"
  RUN="$CDIR/sibling-run"; reload
  run_start --no-preflight
  want "SKIPPED filing=" 0 "duplicate-terminal-$terminal_pr_state"
  grep -qF 'gh|pr view 123 --repo acme/widget --json state --jq .state' "$T/calls.log" \
    || fail "duplicate-terminal-$terminal_pr_state: candidate PR state was not checked"
done

# An unreadable PR state remains live and explains the failed lookup.
setup duplicate-pr-unreadable ONE AGAINST
run_start --no-preflight
want "SKIPPED filing=" 0 duplicate-pr-unreadable-first
"$SCRIPT_DIR/../bin/tkt-state" "$RUN/widget-42.state" set pr 124
: >"$T/prstate"
touch "$T/gh-fail"
existing_state="$(cd "$RUN" && pwd -P)/widget-42.state"; existing_run="$RUN"
RUN="$CDIR/sibling-run"; reload
run_start --no-preflight
want "DUPLICATE state=$existing_state run=$existing_run" 2 duplicate-pr-unreadable
case "$OUT" in *"PR state of 124 could not be read"*"counts as live"*) ;; *) fail "duplicate-pr-unreadable: output misses unreadable reason: $OUT" ;; esac
case "$OUT" in *"resume with --run $existing_run"*) ;; *) fail "duplicate-pr-unreadable: output misses resume hint: $OUT" ;; esac
[ ! -e "$RUN/widget-42.state" ] || fail "duplicate-pr-unreadable: second state was written"

# The exact-state scan ignores a retired archive file.
setup duplicate-retired ONE AGAINST
printf 'retired fixture\n' >"$RUN/widget-42.state.retired"
RUN="$CDIR/sibling-run"; reload
run_start --no-preflight
want "SKIPPED filing=" 0 duplicate-retired
[ -f "$RUN/widget-42.state" ] || fail "duplicate-retired: start did not write a fresh state"

# from any cwd: with the worktree in place, tkt-start resolves origin/main
# through --worktree, not the caller's directory.
setup elsewhere ONE AGAINST
git -C "$CLONE" worktree add --no-track -b keepbranch2 "$WT" origin/main >/dev/null
mkdir -p "$T/elsewhere"
RC=0; OUT="$(cd "$T/elsewhere" && bash "$TKT" "${ARGS[@]}" 2>"$CDIR/stderr")" || RC=$?
want "CURRENT " 0 elsewhere
[ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$CLONE" rev-parse origin/main)" ] || fail "elsewhere: worktree not at origin/main"
# an existing worktree is reused, not recreated.
setup reused ONE AGAINST
git -C "$CLONE" worktree add --no-track -b keepbranch "$WT" origin/main >/dev/null
printf 'marker\n' >"$WT/marker.txt"; run_start
want "CURRENT " 0 reused
[ -f "$WT/marker.txt" ] || fail "reused: marker gone, worktree was recreated"
[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "keepbranch" ] || fail "reused: worktree branch changed"
# stale by commit: a touching commit after filing runs the full preflight.
setup stale TWO FILING; run_start
want "PREFLIGHT core=2 out=" 1 stale
expect_state stale
grep -q '^plan-sweep|' "$T/calls.log" || fail "stale: plan-sweep not called"
sweep_args="$(grep '^plan-sweep|' "$T/calls.log" | head -n 1)"
for want_arg in "--cwd $WT" "--base origin/main" "--files f.txt" "--out $RUN/widget-42-sweep.md"; do
  case "$sweep_args" in *"$want_arg"*) ;; *) fail "stale: plan-sweep misses [$want_arg]" ;; esac
done
grep -q '^tkt-job|' "$T/calls.log" || fail "stale: tkt-job not called"
job_args="$(grep '^tkt-job|' "$T/calls.log" | head -n 1)"
BASE="$(git -C "$CLONE" rev-parse origin/main)"
for want_arg in "$RUN/widget-42.state --slot preflight" "--template $TEMPLATE" "--out-file $RUN/widget-42-preflight-out.md" \
  "ISSUE=42" "SPEC=42" "REPO=acme/widget" "WORKFLOW_DOC=$CDIR/wf.md" "BASE=$BASE" "PACK=$RUN/widget-42-sweep.md"; do
  case "$job_args" in *"$want_arg"*) ;; *) fail "stale: tkt-job misses [$want_arg]" ;; esac
done
[ -f "$RUN/widget-42-preflight-out.md" ] || fail "stale: no out file"
cmp -s "$T/jobout" "$RUN/widget-42-preflight-out.md" || fail "stale: out file differs"
j="$RUN/widget-42.state"; j="${j%.state}.journal"
grep -q "tkt-start preflight " "$j" || fail "stale: journal misses preflight step"
# edited after filing: the since form runs and shows in the digest.
setup edited TWO AGAINST
printf '2026-06-01T00:00:00Z\n' >"$T/edited"; run_start
want "PREFLIGHT core=2 out=" 1 edited
case "$OUT" in *"since=2026-06-01T00:00:00Z"*) ;; *) fail "edited: digest misses the since form" ;; esac
printf '2025-06-01T00:00:00Z\n' >"$T/edited"; run_start
want "PREFLIGHT core=2 out=" 1 oldedit
case "$OUT" in *"since="*) fail "oldedit: digest must not claim a since check" ;; esac
# missing named file: the real sweep tolerates unresolved tokens, still preflights.
setup missing ONE AGAINST
cp "$T/tktbin/plan-sweep" "$T/tktbin/plan-sweep.stub"
printf '#!/usr/bin/env bash\nexec "%s/../bin/plan-sweep" "$@"\n' "$SCRIPT_DIR" >"$T/tktbin/plan-sweep"
chmod +x "$T/tktbin/plan-sweep"; run_start --files "f.txt, missing.txt"
mv "$T/tktbin/plan-sweep.stub" "$T/tktbin/plan-sweep"
want "PREFLIGHT core=2 out=" 1 missing
[ ! -f "$RUN/widget-42-sweep.md" ] || fail "missing: the real sweep writes nothing on unresolved tokens"
# no pack was written, so the brief must not name it: tkt-job must get PACK=none.
grep -q '^tkt-job|.*PACK=none' "$T/calls.log" || fail "missing: tkt-job must run with PACK=none, not the absent pack"
case "$OUT" in *"missing-file:missing.txt"*) ;; *) fail "missing: digest misses the reason" ;; esac
# --files: spaces split paths as commas do, so "a b,c" is three paths, not two.
setup spaces ONE AGAINST
reload --files; run_start --files "a b,c"
case "$OUT" in *"files=a,b,c"*) ;; *) fail "spaces: digest misses files=a,b,c" ;; esac
# --files takes the words after it up to the next flag; a repeat appends.
setup words ONE AGAINST
reload --files; run_start --files a b c
[ "$RC" -ne 2 ] || fail "words: --files a b c gives usage"
case "$OUT" in *"files=a,b,c"*) ;; *) fail "words: digest misses files=a,b,c" ;; esac
setup wordsflag ONE AGAINST
reload --files; run_start --files a b --no-preflight
want "SKIPPED filing=" 0 wordsflag
printf '%s\n' "$OUT" | grep -qx -- 'files=a,b' || fail "wordsflag: digest misses the whole field files=a,b"
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "wordsflag: tkt-job must not run"
setup repeat ONE AGAINST
reload --files; run_start --files x --files y z
case "$OUT" in *"files=x,y,z"*) ;; *) fail "repeat: digest misses files=x,y,z" ;; esac
setup stray ONE AGAINST
reload --files; run_start stray
[ "$RC" -eq 2 ] || fail "stray: bare word with no --files exits $RC"
setup flagfirst ONE AGAINST
reload --files; run_start --files --no-preflight
[ "$RC" -eq 2 ] || fail "flagfirst: --files then a flag exits $RC"
grep -qF -- --files "$CDIR/stderr" || fail "flagfirst: stderr does not name --files"
# unreadable or unresolvable filing commit preflights with a reason.
setup badfiling ONE SKIP
printf 'Work for #42 with no filing line.\n' >"$T/body"; run_start
want "PREFLIGHT core=2 out=" 1 badfiling
grep -q '^tkt-job|' "$T/calls.log" || fail "badfiling: tkt-job must run"
case "$OUT" in *"reason=filing-commit:unreadable"*) ;; *) fail "badfiling: digest misses the reason" ;; esac
printf 'Work for #42.\n\nWritten against deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' >"$T/body"; run_start
want "PREFLIGHT core=2 out=" 1 badsha
case "$OUT" in *"reason=filing-commit:unreadable"*) ;; *) fail "badsha: digest misses the reason" ;; esac
# core-count table: only the job output, want rc and want line differ.
# Contract: the count rule in bin/tkt-start's header.
for spec in "zerocore|0|PREFLIGHT core=0 nonblocking=3 out=" "twocore|1|PREFLIGHT core=2 out=" "backtick|1|PREFLIGHT core=1 out=" "dashcore|1|PREFLIGHT core=2 out=" "dashnb|0|PREFLIGHT core=0 nonblocking=1 out=" "starbare|0|PREFLIGHT core=0 nonblocking=0 out=" "nonecolon|0|PREFLIGHT core=0 nonblocking=1 out=" "naw|0|PREFLIGHT core=0 nonblocking=0 out=" "nothing|0|PREFLIGHT core=0 nonblocking=1 out=" "barecore|0|PREFLIGHT core=0 nonblocking=1 out=" "boldnone|0|PREFLIGHT core=0 nonblocking=1 out=" "noneof|1|PREFLIGHT core=1 out=" "nbnone|0|PREFLIGHT core=0 nonblocking=1 out=" "midtick|1|PREFLIGHT core=1 out=" "midbold|1|PREFLIGHT core=1 out=" "twotags|1|PREFLIGHT core=1 out=" "trailtick|1|PREFLIGHT core=1 out=" "trailbold|1|PREFLIGHT core=1 out=" "coreoutcome|0|PREFLIGHT core=0 nonblocking=1 out=" "nilsentence|0|PREFLIGHT core=0 nonblocking=0 out=" "nbnilsentence|0|PREFLIGHT core=0 nonblocking=0 out=" "trailspace|0|PREFLIGHT core=0 nonblocking=2 out="; do
  IFS='|' read -r name rc want_line <<<"$spec"
  setup "$name" TWO FILING
  case "$name" in
    trailspace) printf '1. non-blocking -- one\n2. non-blocking -- two\nCore items: 0  \nNon-blocking items: 2  \n' >"$T/jobout" ;;
    zerocore) printf '1. non-blocking -- one\n2. non-blocking -- two\n3. non-blocking -- three\nCore items: 0\nNon-blocking items: 3\n' >"$T/jobout" ;;
    backtick) printf '1. `core` — first\n2. plain note\nCore items: 1\nNon-blocking items: 0\n' >"$T/jobout" ;;
    dashcore) printf -- '- core -- first\n- **core** -- second\nCore items: 2\nNon-blocking items: 0\n' >"$T/jobout" ;;
    dashnb) printf -- '- non-blocking -- a\nCore items: 0\nNon-blocking items: 1\n' >"$T/jobout" ;;
    starbare) printf '**core** -- x\nCore items: 0\nNon-blocking items: 0\n' >"$T/jobout" ;;
    nonecolon) printf '%s\n' '- core: none found.' '- non-blocking -- a' 'Core items: 0' 'Non-blocking items: 1' >"$T/jobout" ;;
    naw) printf '%s\n' '- core: N/A.' 'Core items: 0' 'Non-blocking items: 0' >"$T/jobout" ;;
    nothing) printf '%s\n' '- core: Nothing' '- non-blocking -- a' 'Core items: 0' 'Non-blocking items: 1' >"$T/jobout" ;;
    barecore) printf '%s\n' '- core:' '- non-blocking -- a' 'Core items: 0' 'Non-blocking items: 1' >"$T/jobout" ;;
    boldnone) printf '%s\n' '- **core:** `None`.' '- non-blocking -- a' 'Core items: 0' 'Non-blocking items: 1' >"$T/jobout" ;;
    noneof) printf '%s\n' '- core: none of the callers handle X' 'Core items: 1' 'Non-blocking items: 0' >"$T/jobout" ;;
    nbnone) printf '%s\n' '- non-blocking: none.' '- non-blocking -- a' 'Core items: 0' 'Non-blocking items: 1' >"$T/jobout" ;;
    midtick) printf '%s\n' '- hold.rs:15-20 says the handle must close before the guard kills, but `Drop` reaps (hold.rs:139) before the handle closes. `core`. The answer must say whether the early kill is intended.' 'Core items: 1' 'Non-blocking items: 0' >"$T/jobout" ;;
    midbold) printf '%s\n' '2. the guard reaps early (hold.rs:139). **core** -- the early kill.' 'Core items: 1' 'Non-blocking items: 0' >"$T/jobout" ;;
    twotags) printf '%s\n' '- `core` here, and `core` again.' 'Core items: 1' 'Non-blocking items: 0' >"$T/jobout" ;;
    trailtick) printf '%s\n' '- The answer must say whether the early kill is intended. `core`.' 'Core items: 1' 'Non-blocking items: 0' >"$T/jobout" ;;
    trailbold) printf '%s\n' '2. The guard reaps early (hold.rs:139). **core**' 'Core items: 1' 'Non-blocking items: 0' >"$T/jobout" ;;
    coreoutcome) printf '%s\n' '- non-blocking -- the core outcome is unchanged.' 'Core items: 0' 'Non-blocking items: 1' >"$T/jobout" ;;
    nilsentence) printf '%s\n' '- core: none. Each choice above is settled by a ruling, the goal, or code.' 'Core items: 0' 'Non-blocking items: 0' >"$T/jobout" ;;
    nbnilsentence) printf '%s\n' '- non-blocking: nothing. The sweep is clean.' 'Core items: 0' 'Non-blocking items: 0' >"$T/jobout" ;;
  esac
  run_start
  want "$want_line" "$rc" "$name"
  if [ "$name" = twocore ] || [ "$name" = dashcore ]; then case "$OUT" in *"nonblocking="*) fail "$name: nonzero core must not carry nonblocking" ;; esac; fi
done
# field-count cases: tkt-start reads the trailing Core/Non-blocking field
# lines, not the bullet shapes above them.
setup fieldunbulleted TWO FILING
printf 'The guard reaps early and the answer must say why.\nCore items: 1\nNon-blocking items: 0\n' >"$T/jobout"
run_start
want "PREFLIGHT core=1 out=" 1 fieldunbulleted
case "$OUT" in *"nonblocking="*) fail "fieldunbulleted: nonzero core must not carry nonblocking" ;; esac
setup fieldruled TWO FILING
printf '1. core -- first, settled by a ruling in the issue comments.\n1. non-blocking -- other\nCore items: 0\nNon-blocking items: 1\n' >"$T/jobout"
run_start
want "PREFLIGHT core=0 nonblocking=1 out=" 0 fieldruled
setup fieldmissing TWO FILING
printf '1. core -- first\n2. non-blocking -- other\nNon-blocking items: 1\n' >"$T/jobout"
run_start
want "PREFLIGHT core=unknown out=" 1 fieldmissing
case "$OUT" in *"no 'Core items:' line"*) ;; *) fail "fieldmissing: digest misses the missing-field message" ;; esac
# stale with no --files: the sweep is skipped, the preflight still runs.
setup nofiles TWO FILING
reload --files; run_start
want "PREFLIGHT core=2 out=" 1 nofiles
grep -q '^tkt-job|' "$T/calls.log" || fail "nofiles: tkt-job must run"
job_args="$(grep '^tkt-job|' "$T/calls.log" | head -n 1)"
case "$job_args" in *"PACK=none"*) ;; *) fail "nofiles: tkt-job misses [PACK=none]" ;; esac
[ "$(grep -c '^plan-sweep|' "$T/calls.log")" -eq 0 ] || fail "nofiles: plan-sweep must be skipped"
case "$OUT" in *"sweep=none"*) ;; *) fail "nofiles: digest must mark the sweep skipped" ;; esac
# stored head drift exits 3 naming state, worktree and pr heads.
setup drift ONE AGAINST; run_start
[ "$RC" -eq 0 ] || fail "driftsetup: exit $RC"
ACTUAL="$(git -C "$WT" rev-parse HEAD)"
S="$RUN/widget-42.state"
bash "$SCRIPT_DIR/../bin/tkt-state" "$S" set post_run old-run
bash "$SCRIPT_DIR/../bin/tkt-state" "$S" set head deadbeefdeadbeefdeadbeefdeadbeefdeadbeef; run_start
want "DRIFT state=deadbeef" 3 drift
[ "$(bash "$SCRIPT_DIR/../bin/tkt-state" "$S" get post_run)" = old-run ] || fail "drift: refused start preserves post_run"
case "$OUT" in *"worktree=$ACTUAL"*) ;; *) fail "drift: digest misses the worktree HEAD" ;; esac
case "$OUT" in *"pr=none"*) ;; *) fail "drift: digest misses the pr head" ;; esac
bash "$SCRIPT_DIR/../bin/tkt-state" "$RUN/widget-42.state" set head "$ACTUAL"; run_start
want "CURRENT " 0 driftmatch
bash "$SCRIPT_DIR/../bin/tkt-state" "$RUN/widget-42.state" set pr 7
printf 'baadf00dbaadf00dbaadf00dbaadf00dbaadf00d\n' >"$T/prhead"; run_start
want "DRIFT state=$ACTUAL" 3 prdrift
case "$OUT" in *"pr=baadf00d"*) ;; *) fail "prdrift: digest misses the pr head" ;; esac
case "$OUT" in *"reconcile the state, worktree, and PR heads before rerunning tkt-start"*) ;; *) fail "prdrift: refusal names the repair" ;; esac
case "$OUT" in *--part*) fail "prdrift: an unmerged or unreadable PR must not suggest a next part" ;; esac
setup driftmerged ONE AGAINST; run_start
[ "$RC" -eq 0 ] || fail "driftmerged setup: exit $RC"
ACTUAL="$(git -C "$WT" rev-parse HEAD)"
bash "$SCRIPT_DIR/../bin/tkt-state" "$RUN/widget-42.state" set head "$ACTUAL"
bash "$SCRIPT_DIR/../bin/tkt-state" "$RUN/widget-42.state" set pr 7
printf 'baadf00dbaadf00dbaadf00dbaadf00dbaadf00d\n' >"$T/prhead"
printf 'MERGED\n' >"$T/prstate"; run_start
want "DRIFT state=$ACTUAL" 3 driftmerged
case "$OUT" in *--part*) ;; *) fail "driftmerged: message must name --part" ;; esac
case "$OUT" in *"pr 7"*|*"pr=7"*) ;; *) fail "driftmerged: message must name PR 7" ;; esac
# An invalid part key cannot suggest a numeric --part, so it still names the
# general head-reconciliation remedy.
bash "$SCRIPT_DIR/../bin/tkt-state" "$RUN/widget-42.state" set part not-a-number
run_start
want "DRIFT state=$ACTUAL" 3 driftmerged-invalid-part
case "$OUT" in *"reconcile the state, worktree, and PR heads before rerunning tkt-start"*) ;; *) fail "driftmerged-invalid-part: refusal names the repair" ;; esac
setup prmatch ONE AGAINST; run_start
ACTUAL="$(git -C "$WT" rev-parse HEAD)"
bash "$SCRIPT_DIR/../bin/tkt-state" "$RUN/widget-42.state" set head "$ACTUAL"
bash "$SCRIPT_DIR/../bin/tkt-state" "$RUN/widget-42.state" set pr 7
printf '%s\n' "$ACTUAL" >"$T/prhead"; : >"$T/prstate"; run_start
want "CURRENT " 0 prmatch
[ "$(grep -cF -- '--json state' "$T/calls.log")" -eq 0 ] || fail "prmatch: merged-state lookup must not run without drift"
printf '1' >"$T/gh-fail"; run_start
want "PRECONDITION pr=unreadable" 2 prunreadable
# --no-preflight on a stale ticket: check only, SKIPPED with exit 0, no job.
setup noflightstale TWO FILING
run_start --no-preflight
want "SKIPPED filing=" 0 noflightstale
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "noflightstale: tkt-job must not run"
[ "$(grep -c '^plan-sweep|' "$T/calls.log")" -eq 0 ] || fail "noflightstale: plan-sweep must not run"
# a ticket STALE without the flag returns SKIPPED with it: the same missing-file
# reason is named, but no STALE or CURRENT token, no sweep and no job.
setup skipstale ONE AGAINST
reload --files; run_start --files missing.txt --no-preflight
want "SKIPPED filing=" 0 skipstale
case "$OUT" in *STALE*|*CURRENT*|*reason=*) fail "skipstale: SKIPPED must carry no STALE, CURRENT or reason" ;; esac
case "$OUT" in *"files=missing.txt"*) ;; *) fail "skipstale: digest misses files=missing.txt" ;; esac
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "skipstale: tkt-job must not run"
[ "$(grep -c '^plan-sweep|' "$T/calls.log")" -eq 0 ] || fail "skipstale: plan-sweep must not run"
: >"$T/calls.log"; run_start --files missing.txt
case "$OUT" in *"reason=missing-file:missing.txt"*) ;; *) fail "skipstale: without the flag the ticket must be stale" ;; esac
# --no-preflight never reads the issue body: a failing body read still ends SKIPPED.
setup skipbody ONE AGAINST
printf '1' >"$T/body-fail"; run_start --no-preflight
want "SKIPPED filing=none" 0 skipbody
run_start
want "STEP-FAIL step=github" 4 skipbody
rm -f "$T/body-fail"
# usage table: each missing flag, a --model without role=, a bad gate.
setup usage ONE AGAINST
for flag in --run --repo --issue --spec --branch --worktree --workflow-doc --closing; do
  reload "$flag"; run_start
  [ "$RC" -eq 2 ] || fail "usage $flag: exit $RC"
  grep -qF -- "$flag" "$CDIR/stderr" || fail "usage $flag: stderr does not name it"
done
for spec in "--model --model solorole" "--merge-gate --merge-gate someday" "--merge-check --merge-check"; do
  reload; run_start ${spec#* }
  [ "$RC" -eq 2 ] || fail "usage ${spec#* }: exit $RC"
  grep -qF -- "${spec%% *}" "$CDIR/stderr" || fail "usage ${spec#* }: stderr does not name ${spec%% *}"
done
reload; run_start --help
[ "$RC" -eq 2 ] || fail "usage help: exit $RC"
grep -qF -- 'ticket body' "$CDIR/stderr" || fail "usage help: stderr does not say --spec holds the ticket body"
# failure table: name, stub flag, want rc, want line. sweep-mixed pins the
# classifier: a mkdir-style diagnostic beside an unresolved line is still a
# failure. sweep-pure pins the other side: all-unresolved still preflights.
for spec in "ghfail|gh-fail|4|STEP-FAIL step=github" "jobfail|job-fail|3|STEP-FAIL step=tkt-job rc=3" \
  "sweepfail|sweep-fail|6|STEP-FAIL step=plan-sweep rc=6" "sweepop|sweep-fail1|1|STEP-FAIL step=plan-sweep rc=1" \
  "sweepmixed|sweep-mixed|1|STEP-FAIL step=plan-sweep rc=1" "sweeppure|sweep-pure|1|PREFLIGHT core=2 out="; do
  IFS='|' read -r name flag rc want_line <<<"$spec"
  n=TWO; b=FILING; [ "$name" = ghfail ] && { n=ONE; b=AGAINST; }
  setup "$name" "$n" "$b"
  printf '1' >"$T/$flag"; run_start
  want "$want_line" "$rc" "$name"
  case "$name" in
    sweeppure) grep -q '^tkt-job|' "$T/calls.log" || fail "sweeppure: tkt-job must run" ;;
    ghfail|jobfail|sweepop|sweepmixed) case "$OUT" in *CURRENT*) fail "$name: must never print CURRENT" ;; esac ;;
  esac
  case "$name" in
    sweepfail|sweepop|sweepmixed) [ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "$name: tkt-job must not run after sweep fails" ;;
    ghfail) case "$OUT" in *core=0*) fail "ghfail: must never print core=0" ;; esac ;;
  esac
done
# the real plan-sweep on an unwritable out path fails with no unresolved line.
setup sweepreal ONE AGAINST
printf 'blocker\n' >"$T/blocker"
sweep_real_out=""; sweep_real_rc=0
sweep_real_out="$(bash "$SCRIPT_DIR/../bin/plan-sweep" --cwd "$CLONE" --base origin/main --files f.txt --out "$T/blocker/out.md" 2>&1)" || sweep_real_rc=$?
[ "$sweep_real_rc" -eq 1 ] || fail "sweepreal: exit $sweep_real_rc"
case "$sweep_real_out" in *unresolved\ *) fail "sweepreal: operational failure must not list unresolved tokens" ;; esac
[ -e "$T/blocker/out.md" ] && fail "sweepreal: must write nothing on failure"
# DONE_WITH_CONCERNS: the preflight report is the product, so a clean
# preflight (core=0) still passes; BLOCKED still fails the step.
setup concerns TWO FILING
printf '1. non-blocking -- only a note\nCore items: 0\nNon-blocking items: 1\n' >"$T/jobout"; touch "$T/job-concerns"; run_start
want "PREFLIGHT core=0 nonblocking=1 out=" 0 concerns
[ -s "$RUN/widget-42-preflight-out.md" ] || fail "concerns: report file missing"
# Stray stderr lines before the verdict (watch output, a blank line) are not the verdict.
setup concerns-noise TWO FILING
printf '1. non-blocking -- only a note\nCore items: 0\nNon-blocking items: 1\n' >"$T/jobout"; touch "$T/job-concerns" "$T/job-noise"; run_start
want "PREFLIGHT core=0 nonblocking=1 out=" 0 concerns-noise
[ -s "$RUN/widget-42-preflight-out.md" ] || fail "concerns-noise: report file missing"
setup blocked TWO FILING
printf '1. non-blocking -- only a note\n' >"$T/jobout"; touch "$T/job-blocked"; run_start
want "STEP-FAIL step=tkt-job rc=1" 1 blocked
case "$OUT" in *PREFLIGHT*) fail "blocked: must never print PREFLIGHT" ;; esac
# worktree add failure exits with its code naming the step.
setup wtaddfail ONE AGAINST
git -C "$CLONE" branch tkt-start origin/main; run_start
want "STEP-FAIL step=worktree rc=255" 255 wtaddfail
case "$OUT" in *CURRENT*) fail "wtaddfail: must never print CURRENT" ;; esac
# fetch failure exits with its code naming the step, before any worktree.
setup fetchfail ONE AGAINST
git -C "$CLONE" remote set-url origin "$CDIR/definitely-missing.git"; run_start
want "STEP-FAIL step=fetch rc=128" 128 fetchfail
[ ! -e "$WT" ] || fail "fetchfail: worktree must not be created"
# a held state lock exits 2 naming the holder.
setup locked ONE AGAINST
mkdir "$RUN/widget-42.state.lock"
printf '12345\n' >"$RUN/widget-42.state.lock/pid"; run_start
want "BUSY holder=12345" 2 locked
grep -q '12345' "$CDIR/stderr" || fail "locked: stderr does not name pid"
# the lastEditedAt lookup passes owner, name and number as GraphQL variables.
setup gqlvars ONE AGAINST
run_start
grep -qF -- '-F owner=acme' "$T/calls.log" || fail "gqlvars: owner not passed with -F"
grep -qF -- '-F name=widget' "$T/calls.log" || fail "gqlvars: name not passed with -F"
grep -qF -- '-F number=42' "$T/calls.log" || fail "gqlvars: number not passed with -F"
grep -q 'owner: "acme"' "$T/calls.log" && fail "gqlvars: owner still interpolated into the query"
# --closing must agree with the spec on Part-of vs Resolves.
setup partclose ONE AGAINST
printf 'Batch part.\n\nPart of #9\n' >"$CDIR/spec.md"
run_start --spec "$CDIR/spec.md"
[ "$RC" -eq 2 ] || fail "partclose: exit $RC, want 2"
grep -qF -- '--closing' "$CDIR/stderr" || fail "partclose: stderr does not name --closing"
grep -qF -- "$CDIR/spec.md" "$CDIR/stderr" || fail "partclose: stderr does not name the spec it read"
run_start --spec "$CDIR/spec.md" --closing "Part of #9"
want "CURRENT " 0 partok
# a missing --spec file is named, instead of grep's redirect hiding it.
setup specmissing ONE AGAINST
run_start --spec "$CDIR/nope.md" --closing "Part of #9"
[ "$RC" -eq 2 ] || fail "specmissing: exit $RC, want 2"
grep -qF -- "$CDIR/nope.md" "$CDIR/stderr" || fail "specmissing: stderr does not name the path"
grep -qF -- 'does not exist' "$CDIR/stderr" || fail "specmissing: stderr does not say the file is missing"
[ ! -e "$RUN/widget-42.state" ] || fail "specmissing: state must not be written"
setup partrev ONE AGAINST
run_start --closing "Part of #9"
[ "$RC" -eq 2 ] || fail "partrev: exit $RC, want 2"
grep -qF -- '--closing' "$CDIR/stderr" || fail "partrev: stderr does not name --closing"
# a non-numeric --issue exits 2 naming it, before any state or worktree.
setup numissue ONE AGAINST
run_start --issue abc
[ "$RC" -eq 2 ] || fail "numissue: exit $RC, want 2"
grep -qF -- '--issue' "$CDIR/stderr" || fail "numissue: stderr does not name --issue"
[ ! -e "$RUN/widget-abc.state" ] || fail "numissue: state must not be written"
[ ! -e "$CDIR/wt" ] || fail "numissue: worktree must not be created"
# merged-PR search: `tkt-start` searches merged PRs for `#<issue> in:body`
# after the currency check. A `Resolves #<issue>` hit stops with MERGED-STOP,
# unless the issue is OPEN with a comment newer than the newest Resolves merge
# (a recurrence, noted and continued). A `Part of #<issue>` hit prints a NOTE
# with every touched path and the run continues. The boundary is a non-digit
# after the number, so `#42` never matches `#421`. The stub's default
# `pr list` is empty.
# a Resolves hit stops with MERGED-STOP before any preflight work.
setup mergedstop ONE AGAINST
printf '%s\n' '[{"number":7,"body":"Fixes it.\n\nResolves #42.\n","files":[{"path":"f.txt"}]}]' >"$T/prlist"
run_start
want "MERGED-STOP pr=7" 1 mergedstop
case "$OUT" in *CURRENT*) fail "mergedstop: must never print CURRENT" ;; esac
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "mergedstop: tkt-job must not run" # docs/agents/issue-tracker.md:31
[ "$(grep -c '^plan-sweep|' "$T/calls.log")" -eq 0 ] || fail "mergedstop: plan-sweep must not run" # docs/agents/issue-tracker.md:31
grep -qF -- '--state merged' "$T/calls.log" || fail "mergedstop: search misses --state merged"
# a MERGED-STOP rerun after a successful start leaves post_run alone (#1517).
setup mergedpostrun ONE AGAINST
run_start --no-preflight
want "SKIPPED filing=" 0 mergedpostrun-first-start
S="$RUN/widget-42.state"
bash "$SCRIPT_DIR/../bin/tkt-state" "$S" set post_run old-run
printf '%s\n' '[{"number":7,"body":"Fixes it.\n\nResolves #42.\n","files":[{"path":"f.txt"}]}]' >"$T/prlist"
run_start --no-preflight
want "MERGED-STOP pr=7" 1 mergedpostrun
[ "$(bash "$SCRIPT_DIR/../bin/tkt-state" "$S" get post_run)" = old-run ] || fail "mergedpostrun: MERGED-STOP preserves post_run"
grep -qF -- '--limit 100' "$T/calls.log" || fail "mergedstop: search misses --limit 100"
grep -qF -- '#42 in:body' "$T/calls.log" || fail "mergedstop: search misses [#42 in:body]"
# a Part-of hit notes every touched path, unfiltered by --files, and continues.
setup mergedpart ONE AGAINST
printf '%s\n' '[{"number":8,"body":"First half.\n\nPart of #42\n","files":[{"path":"f.txt"},{"path":"other/dir.txt"}]}]' >"$T/prlist"
run_start
want "CURRENT " 0 mergedpart
case "$OUT" in *"NOTE merged Part-of PR #8"*) ;; *) fail "mergedpart: digest misses the NOTE" ;; esac
for p in f.txt other/dir.txt; do case "$OUT" in *"$p"*) ;; *) fail "mergedpart: NOTE misses [$p]" ;; esac; done
[ "$(grep -c 'state,comments' "$T/calls.log")" -eq 0 ] || fail "mergedpart: no Resolves hit, so no issue lookup"
# A Part-of PR's paginated REST response includes paths past the first 100.
setup mergedpartpaged ONE AGAINST
pr_files='['
api_files=""
i=1
while [ "$i" -le 100 ]; do
  [ "$i" -eq 1 ] || pr_files+=','
  pr_files+="{\"path\":\"file-$i.txt\"}"
  api_files+="file-$i.txt\n"
  i=$((i + 1))
done
pr_files+=']'
printf '[{"number":18,"body":"Part of #42","files":%s}]\n' "$pr_files" >"$T/prlist"
printf '%b' "${api_files}collision.txt\n" >"$T/api-files"
run_start
want "CURRENT " 0 mergedpartpaged
case "$OUT" in *"NOTE merged Part-of PR #18"*"collision.txt"*) ;; *) fail "mergedpartpaged: NOTE misses path after 100" ;; esac
grep -qF 'gh|api --paginate repos/acme/widget/pulls/18/files?per_page=100 -q .[].filename' "$T/calls.log" || fail "mergedpartpaged: PR file read did not paginate"
# each Part-of hit prints its own NOTE.
setup mergedparts ONE AGAINST
printf '%s\n' '[{"number":8,"body":"Part of #42","files":[{"path":"f.txt"}]},{"number":9,"body":"Part of #42","files":[{"path":"g.txt"}]}]' >"$T/prlist"
run_start
want "CURRENT " 0 mergedparts
case "$OUT" in *"NOTE merged Part-of PR #8"*) ;; *) fail "mergedparts: digest misses the NOTE for PR #8" ;; esac
case "$OUT" in *"NOTE merged Part-of PR #9"*) ;; *) fail "mergedparts: digest misses the NOTE for PR #9" ;; esac
# Resolves wins when both kinds hit, even listed second.
setup mergedwins ONE AGAINST
printf '%s\n' '[{"number":8,"body":"Part of #42","files":[]},{"number":7,"body":"Done.\nResolves #42","files":[]}]' >"$T/prlist"
run_start
want "MERGED-STOP pr=7" 1 mergedwins
case "$OUT" in *"NOTE merged Part-of"*) fail "mergedwins: a Resolves hit must stop, not note" ;; esac
# the boundary: `#421` is no hit for issue 42, on either keyword.
setup mergededge ONE AGAINST
printf '%s\n' '[{"number":7,"body":"Unrelated.\n\nResolves #421\n","files":[]}]' >"$T/prlist"
run_start
want "CURRENT " 0 mergededge
case "$OUT" in *MERGED-STOP*) fail "mergededge: #421 must not stop #42" ;; esac
setup mergededgepart ONE AGAINST
printf '%s\n' '[{"number":8,"body":"Part of #421","files":[{"path":"f.txt"}]}]' >"$T/prlist"
run_start
want "CURRENT " 0 mergededgepart
case "$OUT" in *"NOTE merged Part-of"*) fail "mergededgepart: #421 must not note #42" ;; esac
# a failed search fails the github step and never reports CURRENT or PREFLIGHT.
setup mergedfail ONE AGAINST
printf '1' >"$T/prlist-fail"; run_start
want "STEP-FAIL step=github" 5 mergedfail
case "$OUT" in *CURRENT*) fail "mergedfail: must never print CURRENT" ;; esac
case "$OUT" in *PREFLIGHT*) fail "mergedfail: must never print PREFLIGHT" ;; esac
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "mergedfail: tkt-job must not run" # docs/agents/issue-tracker.md:31
[ "$(grep -c '^plan-sweep|' "$T/calls.log")" -eq 0 ] || fail "mergedfail: plan-sweep must not run" # docs/agents/issue-tracker.md:31
# the search runs on the --no-preflight path too: a Resolves hit stops
# instead of STALE, a Part-of hit notes and then STALE exits.
setup mergednoflight TWO FILING
printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[]}]' >"$T/prlist"
run_start --no-preflight
want "MERGED-STOP pr=7" 1 mergednoflight
case "$OUT" in *"SKIPPED"*|*"STALE reason="*) fail "mergednoflight: must stop, not print SKIPPED or STALE" ;; esac
setup mergednoflightpart TWO FILING
printf '%s\n' '[{"number":8,"body":"Part of #42","files":[{"path":"f.txt"}]}]' >"$T/prlist"
run_start --no-preflight
want "SKIPPED filing=" 0 mergednoflightpart
case "$OUT" in *"NOTE merged Part-of PR #8"*) ;; *) fail "mergednoflightpart: digest misses the NOTE" ;; esac
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "mergednoflightpart: tkt-job must not run" # docs/agents/issue-tracker.md:32
[ "$(grep -c '^plan-sweep|' "$T/calls.log")" -eq 0 ] || fail "mergednoflightpart: plan-sweep must not run" # docs/agents/issue-tracker.md:32
# many Part-of hits all print to stdout and the log, beyond the digest cap.
setup mergedmany ONE AGAINST
prlist='['
for n in {1..40}; do
  [ "$n" -eq 1 ] || prlist="${prlist},"
  prlist+="{\"number\":$((100+n)),\"body\":\"Part of #42\",\"files\":[{\"path\":\"file-$n.txt\"}]}"
done
printf '%s]\n' "$prlist" >"$T/prlist"
run_start
want "CURRENT " 0 mergedmany
mergedmany_log="$(printf '%s\n' "$OUT" | head -n 1)"; mergedmany_log="${mergedmany_log##* log=}"
for n in {1..40}; do
  note="NOTE merged Part-of PR #$((100+n)) files=file-$n.txt"
  case "$OUT" in *"$note"*) ;; *) fail "mergedmany: stdout misses [$note]" ;; esac
  grep -qF -- "$note" "$mergedmany_log" || fail "mergedmany: log misses [$note]"
done
# a Part-of hit on the stale path notes and still preflights.
setup mergedstalepart TWO FILING
printf '%s\n' '[{"number":8,"body":"Part of #42","files":[{"path":"f.txt"}]}]' >"$T/prlist"
run_start
want "PREFLIGHT core=" 1 mergedstalepart
case "$OUT" in *"NOTE merged Part-of PR #8"*) ;; *) fail "mergedstalepart: digest misses the NOTE" ;; esac
# a recurrence: the issue is OPEN with a comment newer than the Resolves merge,
# so the run notes it and continues instead of stopping.
setup recurred ONE AGAINST
printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T01:00:00Z"}]' >"$T/prlist"
printf '%s\n' '{"state":"OPEN","comments":[{"createdAt":"2026-10-28T01:00:01Z"}]}' >"$T/issue"
run_start
want "CURRENT " 0 recurred
case "$OUT" in *"NOTE recurred after merged PR #7"*) ;; *) fail "recurred: digest misses the NOTE" ;; esac
case "$OUT" in *MERGED-STOP*) fail "recurred: must not stop" ;; esac
grep -qF -- 'state,comments' "$T/calls.log" || fail "recurred: no issue state lookup"
grep -qF -- 'number,body,' "$T/calls.log" && grep -qF -- 'mergedAt' "$T/calls.log" || fail "recurred: pr list misses body or mergedAt"
# an older comment, a comment at exactly the merge time, and a closed issue
# all still stop with MERGED-STOP and print no recurrence NOTE.
setup recurredold ONE AGAINST
printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T01:00:00Z"}]' >"$T/prlist"
printf '%s\n' '{"state":"OPEN","comments":[{"createdAt":"2026-10-28T00:59:59Z"}]}' >"$T/issue"
run_start
want "MERGED-STOP pr=7" 1 recurredold
case "$OUT" in *"NOTE recurred"*) fail "recurredold: an older comment must not recur" ;; esac
setup recurredtie ONE AGAINST
printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T01:00:00Z"}]' >"$T/prlist"
printf '%s\n' '{"state":"OPEN","comments":[{"createdAt":"2026-10-28T01:00:00Z"}]}' >"$T/issue"
run_start
want "MERGED-STOP pr=7" 1 recurredtie
case "$OUT" in *"NOTE recurred"*) fail "recurredtie: an equal comment must not recur" ;; esac
setup recurredclosed ONE AGAINST
printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T01:00:00Z"}]' >"$T/prlist"
printf '%s\n' '{"state":"CLOSED","comments":[{"createdAt":"2026-10-28T01:00:01Z"}]}' >"$T/issue"
run_start
want "MERGED-STOP pr=7" 1 recurredclosed
case "$OUT" in *"NOTE recurred"*) fail "recurredclosed: a closed issue must not recur" ;; esac
# two Resolves hits: the NOTE names the newest merge, while MERGED-STOP keeps
# the first-listed PR and a comment between the merges still stops.
setup recurrednewest ONE AGAINST
printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T01:00:00Z"},{"number":9,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T03:00:00Z"}]' >"$T/prlist"
printf '%s\n' '{"state":"OPEN","comments":[{"createdAt":"2026-10-28T04:00:00Z"}]}' >"$T/issue"
run_start
want "CURRENT " 0 recurrednewest
case "$OUT" in *"NOTE recurred after merged PR #9"*) ;; *) fail "recurrednewest: NOTE must name the newest merge #9" ;; esac
printf '%s\n' '{"state":"OPEN","comments":[{"createdAt":"2026-10-28T02:00:00Z"}]}' >"$T/issue"
run_start
want "MERGED-STOP pr=7" 1 recurrednewestbetween
case "$OUT" in *"NOTE recurred"*) fail "recurrednewestbetween: a comment between the merges must not recur" ;; esac
setup recurrednewesttie ONE AGAINST
printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T01:00:00Z"},{"number":9,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T01:00:00Z"}]' >"$T/prlist"
printf '%s\n' '{"state":"OPEN","comments":[{"createdAt":"2026-10-28T02:00:00Z"}]}' >"$T/issue"
run_start
want "CURRENT " 0 recurrednewesttie
case "$OUT" in *"NOTE recurred after merged PR #7"*) ;; *) fail "recurrednewesttie: a tied merge must name the first-listed PR #7" ;; esac
# bad timestamps: an unreadable merge time anywhere stops, with no issue
# lookup; an unreadable comment time is ignored, not newer.
for spec in absent null badtext secondbad soon nullcomment; do
  setup "recurredbad-$spec" ONE AGAINST
  case "$spec" in
    absent) printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[]}]' >"$T/prlist"
      printf '%s\n' '{"state":"OPEN","comments":[{"createdAt":"2026-10-28T02:00:00Z"}]}' >"$T/issue" ;;
    null) printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":null}]' >"$T/prlist"
      printf '%s\n' '{"state":"OPEN","comments":[{"createdAt":"2026-10-28T02:00:00Z"}]}' >"$T/issue" ;;
    badtext) printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":"yesterday"}]' >"$T/prlist"
      printf '%s\n' '{"state":"OPEN","comments":[{"createdAt":"2026-10-28T02:00:00Z"}]}' >"$T/issue" ;;
    secondbad) printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T01:00:00Z"},{"number":9,"body":"Resolves #42","files":[],"mergedAt":"soon"}]' >"$T/prlist"
      printf '%s\n' '{"state":"OPEN","comments":[{"createdAt":"2026-10-28T02:00:00Z"}]}' >"$T/issue" ;;
    soon) printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T01:00:00Z"}]' >"$T/prlist"
      printf '%s\n' '{"state":"OPEN","comments":[{"createdAt":"soon"}]}' >"$T/issue" ;;
    nullcomment) printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T01:00:00Z"}]' >"$T/prlist"
      printf '%s\n' '{"state":"OPEN","comments":[{"createdAt":null}]}' >"$T/issue" ;;
  esac
  run_start
  want "MERGED-STOP pr=7" 1 "recurredbad-$spec"
  case "$OUT" in *"NOTE recurred"*) fail "recurredbad-$spec: must not recur" ;; esac
  case "$spec" in
    absent|null|badtext|secondbad)
      [ "$(grep -c 'state,comments' "$T/calls.log")" -eq 0 ] || fail "recurredbad-$spec: unreadable merge time must skip the issue lookup" ;;
  esac
done
# a recurrence beside a Part-of hit prints both NOTEs and continues.
setup recurredpart ONE AGAINST
printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T01:00:00Z"},{"number":8,"body":"Part of #42","files":[{"path":"f.txt"}]}]' >"$T/prlist"
printf '%s\n' '{"state":"OPEN","comments":[{"createdAt":"2026-10-28T02:00:00Z"}]}' >"$T/issue"
run_start
want "CURRENT " 0 recurredpart
case "$OUT" in *"NOTE recurred after merged PR #7"*) ;; *) fail "recurredpart: digest misses the recurrence NOTE" ;; esac
case "$OUT" in *"NOTE merged Part-of PR #8"*) ;; *) fail "recurredpart: digest misses the Part-of NOTE" ;; esac
# a recurrence on the stale path still preflights, with the NOTE in the
# digest and the log.
setup recurredstale TWO FILING
printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T01:00:00Z"}]' >"$T/prlist"
printf '%s\n' '{"state":"OPEN","comments":[{"createdAt":"2026-10-28T02:00:00Z"}]}' >"$T/issue"
run_start
want "PREFLIGHT core=" 1 recurredstale
case "$OUT" in *"NOTE recurred after merged PR #7"*) ;; *) fail "recurredstale: digest misses the NOTE" ;; esac
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 1 ] || fail "recurredstale: tkt-job must run once"
recurredstale_log="$(printf '%s\n' "$OUT" | head -n 1)"; recurredstale_log="${recurredstale_log##* log=}"
grep -qF -- "NOTE recurred after merged PR #7" "$recurredstale_log" || fail "recurredstale: log misses the NOTE"
# a recurrence under --no-preflight exits SKIPPED with the NOTE, calling neither job.
setup recurredstalenoflight TWO FILING
printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T01:00:00Z"}]' >"$T/prlist"
printf '%s\n' '{"state":"OPEN","comments":[{"createdAt":"2026-10-28T02:00:00Z"}]}' >"$T/issue"
run_start --no-preflight
want "SKIPPED filing=" 0 recurredstalenoflight
case "$OUT" in *"NOTE recurred after merged PR #7"*) ;; *) fail "recurredstalenoflight: digest misses the NOTE" ;; esac
case "$OUT" in *MERGED-STOP*) fail "recurredstalenoflight: must not stop, must print SKIPPED" ;; esac
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "recurredstalenoflight: tkt-job must not run" # docs/agents/issue-tracker.md:32
[ "$(grep -c '^plan-sweep|' "$T/calls.log")" -eq 0 ] || fail "recurredstalenoflight: plan-sweep must not run" # docs/agents/issue-tracker.md:32
# a failed issue lookup fails the github step and never reports CURRENT or PREFLIGHT.
setup recurredfail ONE AGAINST
printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T01:00:00Z"}]' >"$T/prlist"
printf '1' >"$T/issue-fail"; run_start
want "STEP-FAIL step=github" 5 recurredfail
case "$OUT" in *CURRENT*) fail "recurredfail: must never print CURRENT" ;; esac
case "$OUT" in *PREFLIGHT*) fail "recurredfail: must never print PREFLIGHT" ;; esac
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "recurredfail: tkt-job must not run" # docs/agents/issue-tracker.md:31
[ "$(grep -c '^plan-sweep|' "$T/calls.log")" -eq 0 ] || fail "recurredfail: plan-sweep must not run" # docs/agents/issue-tracker.md:31
setup recurredbadjson ONE AGAINST
printf '%s\n' '[{"number":7,"body":"Resolves #42","files":[],"mergedAt":"2026-10-28T01:00:00Z"}]' >"$T/prlist"
printf 'not json\n' >"$T/issue"; run_start
[ "$RC" -ne 0 ] || fail "recurredbadjson: exit $RC"
recurredbadjson_first="$(printf '%s\n' "$OUT" | head -n 1)"
case "$recurredbadjson_first" in "TKT tkt-start STEP-FAIL step=github"*) ;; *) fail "recurredbadjson: line 1 [$recurredbadjson_first] wants STEP-FAIL step=github" ;; esac
case "$OUT" in *CURRENT*) fail "recurredbadjson: must never print CURRENT" ;; esac
case "$OUT" in *PREFLIGHT*) fail "recurredbadjson: must never print PREFLIGHT" ;; esac
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "recurredbadjson: tkt-job must not run" # docs/agents/issue-tracker.md:31
[ "$(grep -c '^plan-sweep|' "$T/calls.log")" -eq 0 ] || fail "recurredbadjson: plan-sweep must not run" # docs/agents/issue-tracker.md:31
# Invalid --spec-issue values are rejected before writing state.
invalid_spec_issue_failures=()
invalid_spec_issue_n=0
for bad in abc 0 00 -3 4.5 '' ' '; do
  invalid_spec_issue_n=$((invalid_spec_issue_n + 1))
  setup "specissueinvalid$invalid_spec_issue_n" ONE AGAINST
  run_start --spec-issue "$bad"
  [ "$RC" -eq 2 ] || invalid_spec_issue_failures+=("[$bad] exit=$RC")
  grep -qF -- '--spec-issue' "$CDIR/stderr" || invalid_spec_issue_failures+=("[$bad] stderr misses --spec-issue")
  [ ! -e "$RUN/widget-42.state" ] || invalid_spec_issue_failures+=("[$bad] state was written")
done
setup specissue10digit ONE AGAINST
run_start --spec-issue 1000000000
want "CURRENT " 0 specissue10digit
[ "$(grep -c '^spec_issue=' "$RUN/widget-42.state")" -eq 1 ] || fail "specissue10digit: wants one spec_issue line"
grep -qFx 'spec_issue=1000000000' "$RUN/widget-42.state" || fail "specissue10digit: state misses [spec_issue=1000000000]"
setup specissuenovalue ONE AGAINST
run_start --spec-issue
[ "$RC" -eq 2 ] || invalid_spec_issue_failures+=("[missing] exit=$RC")
grep -qF -- 'usage: tkt-start' "$CDIR/stderr" || invalid_spec_issue_failures+=("[missing] stderr misses usage")
[ ! -e "$RUN/widget-42.state" ] || invalid_spec_issue_failures+=("[missing] state was written")
[ "${#invalid_spec_issue_failures[@]}" -eq 0 ] || fail "specissueinvalid: ${invalid_spec_issue_failures[*]}"

# --spec-issue stores a positive issue number as given, including leading zeros.
setup specissue ONE AGAINST
run_start --spec-issue 445
want "CURRENT " 0 specissue
[ "$(grep -c '^spec_issue=' "$RUN/widget-42.state")" -eq 1 ] || fail "specissue: wants one spec_issue line"
grep -qFx 'spec_issue=445' "$RUN/widget-42.state" || fail "specissue: state misses [spec_issue=445]"
run_start
want "CURRENT " 0 specissuererun
[ "$(grep -c '^spec_issue=' "$RUN/widget-42.state")" -eq 1 ] || fail "specissuererun: stored value was not preserved"
grep -qFx 'spec_issue=445' "$RUN/widget-42.state" || fail "specissuererun: state misses [spec_issue=445]"
setup specissueleadingzero ONE AGAINST
run_start --spec-issue 007
want "CURRENT " 0 specissueleadingzero
grep -qFx 'spec_issue=007' "$RUN/widget-42.state" || fail "specissueleadingzero: state misses [spec_issue=007]"
setup specissuenine ONE AGAINST
run_start --spec-issue 999999999
want "CURRENT " 0 specissuenine
grep -qFx 'spec_issue=999999999' "$RUN/widget-42.state" || fail "specissuenine: state misses [spec_issue=999999999]"
setup specissuerepeat ONE AGAINST
run_start --spec-issue 1 --spec-issue 2
want "CURRENT " 0 specissuerepeat
[ "$(grep -c '^spec_issue=' "$RUN/widget-42.state")" -eq 1 ] || fail "specissuerepeat: wants one spec_issue line"
grep -qFx 'spec_issue=2' "$RUN/widget-42.state" || fail "specissuerepeat: state misses [spec_issue=2]"
setup specissueabsent ONE AGAINST
run_start
want "CURRENT " 0 specissueabsent
[ "$(grep -c '^spec_issue=' "$RUN/widget-42.state")" -eq 0 ] || fail "specissueabsent: unexpected spec_issue line"

# --body-ends writes one body_ends line; a repeat keeps only the last value.
setup bodyends ONE AGAINST
run_start --body-ends 'X'
want "CURRENT " 0 bodyends
[ "$(grep -c '^body_ends=' "$RUN/widget-42.state")" -eq 1 ] || fail "bodyends: wants one body_ends line"
grep -qF 'body_ends=X' "$RUN/widget-42.state" || fail "bodyends: state misses [body_ends=X]"
setup bodyendsrepeat ONE AGAINST
run_start --body-ends 'A' --body-ends 'B'
want "CURRENT " 0 bodyendsrepeat
[ "$(grep -c '^body_ends=' "$RUN/widget-42.state")" -eq 1 ] || fail "bodyendsrepeat: wants one body_ends line"
grep -qF 'body_ends=B' "$RUN/widget-42.state" || fail "bodyendsrepeat: state misses [body_ends=B]"
grep -qF 'body_ends=A' "$RUN/widget-42.state" && fail "bodyendsrepeat: stale value [body_ends=A] remains"
# an empty or blank --body-ends exits 2 naming the rule, before any state write.
setup bodyendsempty ONE AGAINST
run_start --body-ends ''
[ "$RC" -eq 2 ] || fail "bodyendsempty: exit $RC"
grep -qF 'tkt-start: --body-ends needs a value that is not blank' "$CDIR/stderr" || fail "bodyendsempty: stderr misses the blank rule"
[ ! -e "$RUN/widget-42.state" ] || fail "bodyendsempty: state must not be written"
setup bodyendsblank ONE AGAINST
run_start --body-ends '  '
[ "$RC" -eq 2 ] || fail "bodyendsblank: exit $RC"
grep -qF 'tkt-start: --body-ends needs a value that is not blank' "$CDIR/stderr" || fail "bodyendsblank: stderr misses the blank rule"
[ ! -e "$RUN/widget-42.state" ] || fail "bodyendsblank: state must not be written"
# a value holding a newline exits 2 naming the rule, before any state write.
setup bodyendsnewline ONE AGAINST
run_start --body-ends "$(printf 'a\nb')"
[ "$RC" -eq 2 ] || fail "bodyendsnewline: exit $RC"
grep -qF 'tkt-start: --body-ends value holds a newline' "$CDIR/stderr" || fail "bodyendsnewline: stderr misses the newline rule"
[ ! -e "$RUN/widget-42.state" ] || fail "bodyendsnewline: state must not be written"
# --body-ends with no value exits 2 through usage.
setup bodyendsnovalue ONE AGAINST
run_start --body-ends
[ "$RC" -eq 2 ] || fail "bodyendsnovalue: exit $RC"
grep -qF 'usage: tkt-start' "$CDIR/stderr" || fail "bodyendsnovalue: stderr misses usage"
[ ! -e "$RUN/widget-42.state" ] || fail "bodyendsnovalue: state must not be written"
# a run without the flag writes no body_ends line.
setup bodyendsabsent ONE AGAINST
run_start
want "CURRENT " 0 bodyendsabsent
[ "$(grep -c '^body_ends=' "$RUN/widget-42.state")" -eq 0 ] || fail "bodyendsabsent: unexpected body_ends line"
# end to end: tkt-start stores --body-ends, tkt-ship passes it to ship-pr.
setup bodyendse2e ONE AGAINST
cat >"$T/tktbin/ship-pr" <<EOF
#!/usr/bin/env bash
printf 'ship-pr|%s\n' "\$*" >>"$T/shipcalls.log"
for a in "\$@"; do printf 'arg|%s\n' "\$a" >>"$T/shipcalls.log"; done
echo "merged deadbeef1234567890"
exit 0
EOF
chmod +x "$T/tktbin/ship-pr"
cat >"$T/tktbin/lanecheck" <<EOF
#!/usr/bin/env bash
printf 'called\\n' >"$T/lanecheck-called"
echo 'lanecheck must not be called by tkt-ship' >&2
exit 99
EOF
chmod +x "$T/tktbin/lanecheck"
: >"$T/shipcalls.log"
rm -f "$T/lanecheck-called"
run_start --body-ends 'X'
want "CURRENT " 0 bodyendse2e
grep -qF 'body_ends=X' "$RUN/widget-42.state" || fail "bodyendse2e: state misses [body_ends=X]"
S2E_STATE="$RUN/widget-42.state"
bash "$SCRIPT_DIR/../bin/tkt-state" "$S2E_STATE" set pr 7
bash "$SCRIPT_DIR/../bin/tkt-state" "$S2E_STATE" set reviewed "$(git -C "$WT" rev-parse HEAD)"
S2E_HEAD="$(git -C "$WT" rev-parse HEAD)"
bash "$SCRIPT_DIR/../bin/tkt-state" "$S2E_STATE" set head "$S2E_HEAD"
printf '%s' "$S2E_HEAD" >"$T/prhead"
S2E_OUT="$(bash "$SCRIPT_DIR/../bin/tkt-ship" "$S2E_STATE" 2>"$CDIR/ship-stderr")" || fail "bodyendse2e: tkt-ship exit $?"
case "$S2E_OUT" in "TKT tkt-ship MERGED"*) ;; *) fail "bodyendse2e: tkt-ship [$S2E_OUT] wants MERGED" ;; esac
grep -Fxq 'RETIRE issue=42' <<<"$S2E_OUT" || fail "bodyendse2e: missing RETIRE instruction"
[ ! -e "$T/lanecheck-called" ] || fail "bodyendse2e: tkt-ship called lanecheck"
[ "$(grep -c -x -F 'arg|--body-ends' "$T/shipcalls.log")" -eq 1 ] || fail "bodyendse2e: body-ends once: $(cat "$T/shipcalls.log")"
got="$(grep -A1 -x -F 'arg|--body-ends' "$T/shipcalls.log" | sed -n 2p)"
[ "$got" = 'arg|X' ] || fail "bodyendse2e: body-ends value, got [$got]"
part_seed_pr() {
  run_start
  [ "$RC" -eq 0 ] || fail "$1 setup: exit $RC"
  part_actual="$(git -C "$WT" rev-parse HEAD)"
  bash "$SCRIPT_DIR/../bin/tkt-state" "$RUN/widget-42.state" set head "$part_actual"
  bash "$SCRIPT_DIR/../bin/tkt-state" "$RUN/widget-42.state" set pr 7
}

# A merged part archives its state under the lock, then starts with the ticket
# identity and any model role not overridden by the new invocation.
setup partmerged ONE AGAINST; part_seed_pr partmerged
S="$RUN/widget-42.state"; ARCHIVE="$S.part1"
bash "$SCRIPT_DIR/../bin/tkt-state" "$S" set reviewed "$part_actual"
bash "$SCRIPT_DIR/../bin/tkt-state" "$S" set plan /x
journal_before="$(cat "$RUN/widget-42.journal")"
printf 'MERGED\n' >"$T/prstate"
reload --model; run_start --part 2
want "CURRENT " 0 partmerged
[ -f "$ARCHIVE" ] || fail "partmerged: archive missing [$ARCHIVE]"
grep -qF -- 'pr=7' "$ARCHIVE" || fail "partmerged: archive misses [pr=7]"
grep -qF -- 'part=2' "$S" || fail "partmerged: state misses [part=2]"
grep -qF -- 'repo=acme/widget' "$S" || fail "partmerged: state misses [repo=acme/widget]"
grep -qF -- 'issue=42' "$S" || fail "partmerged: state misses [issue=42]"
grep -qF -- "worktree=$WT" "$S" || fail "partmerged: state misses worktree"
grep -qF -- "run=$RUN" "$S" || fail "partmerged: state misses run"
grep -qF -- 'model.lane=sol' "$S" || fail "partmerged: state misses [model.lane=sol]"
grep -qF -- 'model.preflight=luna' "$S" || fail "partmerged: state misses [model.preflight=luna]"
[ "$(grep -c '^model\.lane=' "$S")" -eq 1 ] || fail "partmerged: state wants 1 model.lane"
[ "$(grep -c '^model\.preflight=' "$S")" -eq 1 ] || fail "partmerged: state wants 1 model.preflight"
grep -qE '^(pr|head|reviewed|plan)=' "$S" && fail "partmerged: archived values remain in new state"
journal_after="$(cat "$RUN/widget-42.journal")"
case "$journal_after" in "$journal_before"*) ;; *) fail "partmerged: journal was not preserved" ;; esac
case "$journal_after" in *"archived state part1 pr=7 -> $ARCHIVE"*) ;; *) fail "partmerged: journal misses archive record" ;; esac
cp "$ARCHIVE" "$CDIR/archive.before"
: >"$T/calls.log"; run_start --part 2
want "CURRENT " 0 partrerun
[ "$(grep -c '^part=' "$S")" -eq 1 ] || fail "partrerun: state wants 1 part"
grep -qF -- 'part=2' "$S" || fail "partrerun: state misses [part=2]"
cmp -s "$ARCHIVE" "$CDIR/archive.before" || fail "partrerun: archive changed"
[ "$(grep -c 'pr view .*--json state' "$T/calls.log")" -eq 0 ] || fail "partrerun: merged-state lookup must not run"

# An open PR refuses without moving or changing the state.
setup partopen ONE AGAINST; part_seed_pr partopen
S="$RUN/widget-42.state"; cp "$S" "$CDIR/state.before"
printf 'OPEN\n' >"$T/prstate"; run_start --part 2
want "PRECONDITION part=2 pr=7" 2 partopen
case "$OUT" in *'needs part 1'*) ;; *) fail "partopen: message misses [needs part 1]" ;; esac
grep -qF -- 'pr=7' "$CDIR/state.before" || fail "partopen: saved state misses [pr=7]"
cmp -s "$S" "$CDIR/state.before" || fail "partopen: state changed"
[ ! -e "$S.part1" ] || fail "partopen: archive must not exist"
[ ! -e "$S.lock" ] || fail "partopen: lock was not released"

# A missing PR cannot be treated as a merged part.
setup partnopr ONE AGAINST; run_start
S="$RUN/widget-42.state"; cp "$S" "$CDIR/state.before"
run_start --part 2
want "PRECONDITION part=2 pr=none" 2 partnopr
case "$OUT" in *'pr=none'*) ;; *) fail "partnopr: message misses [pr=none]" ;; esac
cmp -s "$S" "$CDIR/state.before" || fail "partnopr: state changed"
[ ! -e "$S.part1" ] || fail "partnopr: archive must not exist"

# Never replace a previous archive.
setup partexists ONE AGAINST; part_seed_pr partexists
S="$RUN/widget-42.state"; cp "$S" "$CDIR/state.before"
printf 'old archive\n' >"$S.part1"; printf 'MERGED\n' >"$T/prstate"
run_start --part 2
want "PRECONDITION part=2" 2 partexists
case "$OUT" in *"$S.part1"*) ;; *) fail "partexists: message misses [$S.part1]" ;; esac
cmp -s "$S" "$CDIR/state.before" || fail "partexists: state changed"
grep -qF -- 'old archive' "$S.part1" || fail "partexists: previous archive changed"
[ ! -e "$S.lock" ] || fail "partexists: lock was not released"

# --env rejects empty assignment values before writing state, while non-empty
# values remain accepted.
setup envempty ONE AGAINST
run_start --env 'CARGO_BUILD_JOBS=3 NEXTEST_TEST_THREADS= CARGO_INCREMENTAL=0'
[ "$RC" -eq 2 ] || fail "envempty: exit $RC, want 2"
grep -qF -- 'tkt-start: --env sets NEXTEST_TEST_THREADS to an empty value; drop it or give it a value' "$CDIR/stderr" || fail "envempty: stderr misses the variable-specific error"
[ ! -e "$RUN/widget-42.state" ] || fail "envempty: state was written"

setup envset ONE AGAINST
run_start --env 'CARGO_BUILD_JOBS=3 NEXTEST_TEST_THREADS=2 CARGO_INCREMENTAL=0'
want "CURRENT " 0 envset
grep -qF -- 'env=CARGO_BUILD_JOBS=3 NEXTEST_TEST_THREADS=2 CARGO_INCREMENTAL=0' "$RUN/widget-42.state" || fail "envset: state misses the non-empty env prefix"

# Invalid values fail before the first state write.
setup partbad ONE AGAINST
for bad in one x missing; do
  case "$bad" in one) run_start --part 1 ;; x) run_start --part x ;; missing) run_start --part ;; esac
  [ "$RC" -eq 2 ] || fail "partbad $bad: exit $RC, want 2"
  grep -qF -- '--part' "$CDIR/stderr" || fail "partbad $bad: stderr does not name --part"
  [ ! -e "$RUN/widget-42.state" ] || fail "partbad $bad: state was written"
done

setup modelrole ONE AGAINST; run_start --model bogus=x
[ "$RC" -eq 2 ] || fail "modelrole: unknown --model role exits $RC, want 2"
grep -qF 'known roles: lane, fix, map, verifier, verify, review, overbuild, preflight' "$CDIR/stderr" \
  || fail "modelrole: stderr does not print the known roles"
model_roles="$(sed -n 's/^model_roles=(\(.*\))$/\1/p' "$TKT")"
[ -n "$model_roles" ] || fail "modelrole: tkt-start has no known model roles"
for role in $model_roles; do
  grep -qF -- "\`$role\`" "$SCRIPT_DIR/../skills/implement/SKILL.md" \
    || fail "modelrole: skills/implement/SKILL.md does not name role [$role]"
done

# Posting before and after a successful tkt-start restart uses different run
# IDs. post-plan is stubbed here; test/post-plan.sh covers comment creation.
setup post-run-reset ONE AGAINST
run_start --no-preflight
want "SKIPPED filing=" 0 post-run-reset-first-start
S="$RUN/widget-42.state"
base="$(git -C "$WT" rev-parse HEAD)"
plan="$CDIR/plan.md"
printf 'Base: %s\n\n## Files\n\n- `f.txt`\n\n## Gate\n\n`true`\n' "$base" >"$plan"
bash "$SCRIPT_DIR/../bin/tkt-state" "$S" set plan "$plan" || fail "post-run-reset: set plan"
bash "$SCRIPT_DIR/../bin/tkt-state" "$S" set plan_verdict ok || fail "post-run-reset: set plan verdict"
bash "$SCRIPT_DIR/../bin/tkt-state" "$S" set plan_verdict_base "$base" || fail "post-run-reset: set verdict base"
: >"$T/post-plan.log"
post_out="$(bash "$SCRIPT_DIR/../bin/tkt-plan" "$S" post 2>"$CDIR/post-first.stderr")" || fail "post-run-reset: first post failed: $(cat "$CDIR/post-first.stderr")"
post_run_first="$(bash "$SCRIPT_DIR/../bin/tkt-state" "$S" get post_run)"
[ -n "$post_run_first" ] || fail "post-run-reset: first post stores its run ID"
run_start --no-preflight
want "SKIPPED filing=" 0 post-run-reset-restart
[ -z "$(bash "$SCRIPT_DIR/../bin/tkt-state" "$S" get post_run)" ] || fail "post-run-reset: successful restart clears post_run"
post_out="$(bash "$SCRIPT_DIR/../bin/tkt-plan" "$S" post 2>"$CDIR/post-second.stderr")" || fail "post-run-reset: second post failed: $(cat "$CDIR/post-second.stderr")"
post_run_second="$(bash "$SCRIPT_DIR/../bin/tkt-state" "$S" get post_run)"
[ -n "$post_run_second" ] || fail "post-run-reset: second post stores its run ID"
[ "$post_run_second" != "$post_run_first" ] || fail "post-run-reset: second post gets a fresh run ID"
[ "$(wc -l <"$T/post-plan.log" | tr -d ' ')" = 2 ] || fail "post-run-reset: post-plan is called twice"
for post_run in "$post_run_first" "$post_run_second"; do
  grep -Fq -- "--run $post_run" "$T/post-plan.log" || fail "post-run-reset: post-plan receives run ID $post_run"
done

# A new ticket can start at any part without an older state to archive.
setup partnostate ONE AGAINST
run_start --part 2
want "CURRENT " 0 partnostate
grep -qF -- 'part=2' "$RUN/widget-42.state" || fail "partnostate: state misses [part=2]"
[ ! -e "$RUN/widget-42.state.part1" ] || fail "partnostate: unexpected archive"

# The requested model wins over the archived value for the same role.
setup partmodel ONE AGAINST; part_seed_pr partmodel
S="$RUN/widget-42.state"
bash "$SCRIPT_DIR/../bin/tkt-state" "$S" set model.lane old
printf 'MERGED\n' >"$T/prstate"
reload --model; run_start --part 2 --model lane=new
want "CURRENT " 0 partmodel
grep -qF -- 'model.lane=new' "$S" || fail "partmodel: state misses [model.lane=new]"
grep -qE '^model\.lane=old$' "$S" && fail "partmodel: stale model.lane value remains"
[ "$(grep -c '^model\.lane=' "$S")" -eq 1 ] || fail "partmodel: state wants 1 model.lane"

# Each carried model.* line is named in the TKT output, with its real value;
# a role the new run passes with --model is not carried and gets no note.
setup partcarry ONE AGAINST; part_seed_pr partcarry
case "$OUT" in *carried*) fail "partcarry: a run without --part must print no carried note" ;; esac
S="$RUN/widget-42.state"
bash "$SCRIPT_DIR/../bin/tkt-state" "$S" set model.fix fixm
printf 'MERGED\n' >"$T/prstate"
reload --model; run_start --part 2
want "CURRENT " 0 partcarry
for line in model.lane=sol model.fix=fixm model.preflight=luna; do
  note="carried $line from part 1; pass --model ${line#model.} to change it"
  [ "$(printf '%s\n' "$OUT" | grep -cxF -- "$note")" -eq 1 ] || fail "partcarry: output wants one [$note]"
done
setup partcarrymodel ONE AGAINST; part_seed_pr partcarrymodel
S="$RUN/widget-42.state"
bash "$SCRIPT_DIR/../bin/tkt-state" "$S" set model.fix fixm
printf 'MERGED\n' >"$T/prstate"
reload --model; run_start --part 2 --model lane=X
want "CURRENT " 0 partcarrymodel
case "$OUT" in *'carried model.lane'*) fail "partcarrymodel: a --model role must get no carried note" ;; esac
printf '%s\n' "$OUT" | grep -qxF -- 'carried model.fix=fixm from part 1; pass --model fix=fixm to change it' \
  || fail "partcarrymodel: output misses the model.fix note"
grep -qxF -- 'model.lane=X' "$S" || fail "partcarrymodel: state misses [model.lane=X]"

# A part split carries the plan verdict: the plan is shared across parts, so
# the new part keeps plan_verdict and plan_verdict_base and the build does
# not refuse with verdict=none.
setup partverdict ONE AGAINST; part_seed_pr partverdict
S="$RUN/widget-42.state"
bash "$SCRIPT_DIR/../bin/tkt-state" "$S" set plan_verdict ok
bash "$SCRIPT_DIR/../bin/tkt-state" "$S" set plan_verdict_base "$FILING"
VERDICT_HASH="$(printf 'shared plan text\n' | git hash-object --stdin)"
bash "$SCRIPT_DIR/../bin/tkt-state" "$S" set plan_verdict_hash "$VERDICT_HASH"
printf 'MERGED\n' >"$T/prstate"
reload --model; run_start --part 2
want "CURRENT " 0 partverdict
grep -qF -- 'plan_verdict=ok' "$S" || fail "partverdict: state misses [plan_verdict=ok]"
grep -qF -- "plan_verdict_base=$FILING" "$S" || fail "partverdict: state misses [plan_verdict_base=$FILING]"
grep -qF -- "plan_verdict_hash=$VERDICT_HASH" "$S" || fail "partverdict: state misses [plan_verdict_hash=$VERDICT_HASH]"
grep -qF -- 'plan_verdict=ok' "$S.part1" || fail "partverdict: archive misses [plan_verdict=ok]"

# An invalid stored part is reported, and a missing part above part 1 is not inferred.
setup partnonnumeric ONE AGAINST; part_seed_pr partnonnumeric
S="$RUN/widget-42.state"
bash "$SCRIPT_DIR/../bin/tkt-state" "$S" set part x
printf 'MERGED\n' >"$T/prstate"; run_start --part 2
want "PRECONDITION part=2" 2 partnonnumeric
case "$OUT" in *x*) ;; *) fail "partnonnumeric: message misses [x]" ;; esac
[ ! -e "$S.lock" ] || fail "partnonnumeric: lock was not released"
setup partmissingn ONE AGAINST; part_seed_pr partmissingn
S="$RUN/widget-42.state"; cp "$S" "$CDIR/state.before"
printf 'MERGED\n' >"$T/prstate"; run_start --part 3
want "PRECONDITION part=3" 2 partmissingn
case "$OUT" in *'part is missing'*) ;; *) fail "partmissingn: message misses [part is missing]" ;; esac
cmp -s "$S" "$CDIR/state.before" || fail "partmissingn: state changed"
[ ! -e "$S.lock" ] || fail "partmissingn: lock was not released"

# --mutant-job adds the mutants label to the branch PR when the repo defines
# the label; otherwise, or when the PR already carries it, nothing is edited.
setup mutantlabel ONE AGAINST
cp "$T/bin/gh" "$T/bin/gh.shared"
cat >"$T/bin/gh" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" pr list --head "*)
    printf 'gh|%s\\n' "\$*" >>"$T/calls.log"
    printf '7\\n'; exit 0 ;;
  *"labels?per_page=100"*)
    printf 'gh|%s\\n' "\$*" >>"$T/calls.log"
    if [ -f "$T/labels-fail" ]; then echo "gh: labels boom" >&2; exit 5; fi
    if [ -f "$T/labels-nomutants" ]; then printf 'bug\\n'; else printf 'bug\\nmutants\\n'; fi
    exit 0 ;;
  *" --json labels "*)
    printf 'gh|%s\\n' "\$*" >>"$T/calls.log"
    if [ -f "$T/pr-labeled" ]; then printf 'mutants\\n'; else printf 'bug\\n'; fi
    exit 0 ;;
  *" pr edit "*" --add-label mutants "*)
    printf 'gh|%s\\n' "\$*" >>"$T/calls.log"
    if [ -f "$T/edit-fail" ]; then echo "gh: edit boom" >&2; exit 5; fi
    exit 0 ;;
  *) exec "$T/bin/gh.shared" "\$@" ;;
esac
EOF
chmod +x "$T/bin/gh"
run_start
want "CURRENT " 0 mutantlabel
grep -qF -- 'gh|pr edit 7 --repo acme/widget --add-label mutants' "$T/calls.log" || fail "mutantlabel: no mutants label edit"
: >"$T/calls.log"; printf '1' >"$T/labels-nomutants"; run_start
want "CURRENT " 0 mutantlabelnolabel
grep -qF -- 'pr edit' "$T/calls.log" && fail "mutantlabelnolabel: no edit without a repo mutants label"
: >"$T/calls.log"; rm -f "$T/labels-nomutants"; printf '1' >"$T/pr-labeled"; run_start
want "CURRENT " 0 mutantlabellabeled
grep -qF -- 'pr edit' "$T/calls.log" && fail "mutantlabellabeled: no edit when the PR already carries mutants"
: >"$T/calls.log"; rm -f "$T/pr-labeled"; printf '1' >"$T/edit-fail"; run_start
want "STEP-FAIL step=github rc=5" 5 mutantlabeleditfail
rm -f "$T/edit-fail"
: >"$T/calls.log"; printf '1' >"$T/labels-fail"; run_start
want "STEP-FAIL step=github rc=5" 5 mutantlabellistfail
rm -f "$T/labels-fail"
mv "$T/bin/gh.shared" "$T/bin/gh"

echo "tkt-start: all cases passed"

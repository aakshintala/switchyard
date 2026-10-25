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
export HOME="$T/home" TMPDIR="$T/tmp" TKT_BIN="$T/tktbin"
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
  *" graphql "*) cat "$T/edited"; exit 0 ;;
  *" issue view "*" lastEditedAt "*)
    printf 'Unknown JSON field: "lastEditedAt"\n' >&2; exit 1 ;;
  *" pr view "*) cat "$T/prhead"; exit 0 ;;
  *) cat "$T/body"; exit 0 ;;
esac
EOF
chmod +x "$T/bin/gh"
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
# reload [DROP]: rebuild ARGS from the shared flag set, minus DROP and its value.
reload() {
  ARGS=(); skip=0
  for a in --run "$RUN" --repo acme/widget --issue 42 --spec 42 --branch tkt-start \
    --worktree "$WT" --workflow-doc "$CDIR/wf.md" --closing "Resolves #42" --env "FOO=1" \
    --body-has "Resolves #42" --body-has "Co-authored with Claude Code." --extra "$CDIR/extra.md" \
    --merge-gate ci --mutant-job Selection --model lane=sol --model preflight=luna --files f.txt; do
    if [ "$skip" -eq 1 ]; then skip=0; elif [ "$a" = "${1:-}" ]; then skip=1; else ARGS+=("$a"); fi
  done
}
# setup NAME ONE|TWO AGAINST|FILING|SKIP: fresh stubs, a seed repo (a filing
# commit, plus a touching commit for TWO) pushed to origin/main, a clone, the
# issue body and docs, ARGS loaded. Sets CDIR CLONE WT RUN FILING.
setup() {
  : >"$T/calls.log"; rm -f "$T/gh-fail" "$T/sweep-fail" "$T/sweep-fail1" "$T/sweep-mixed" "$T/sweep-pure" "$T/job-fail" "$T/job-concerns" "$T/job-noise" "$T/job-blocked"
  printf 'null\n' >"$T/edited"; : >"$T/prhead"
  printf 'two core lines\n1. core -- first\n2. **core** -- second\n3. non-blocking -- other\n' >"$T/jobout"
  CDIR="$T/cases/$1"; rm -rf "$CDIR"; mkdir -p "$CDIR"
  ORIGIN="$CDIR/origin.git"; SEED="$CDIR/seed"
  git init -q --bare "$ORIGIN"; git init -q "$SEED"; git -C "$SEED" remote add origin "$ORIGIN"
  git -C "$SEED" commit -q --allow-empty -m init
  printf '%s\n' one >"$SEED/f.txt"; git -C "$SEED" add -A
  GIT_AUTHOR_DATE=2026-01-01T00:00:00+00:00 GIT_COMMITTER_DATE=2026-01-01T00:00:00+00:00 git -C "$SEED" commit -q -m filing
  FILING="$(git -C "$SEED" rev-parse HEAD)"
  if [ "$2" = TWO ]; then printf '%s\n' two >"$SEED/f.txt"; git -C "$SEED" add -A
    GIT_AUTHOR_DATE=2026-02-01T00:00:00+00:00 GIT_COMMITTER_DATE=2026-02-01T00:00:00+00:00 git -C "$SEED" commit -q -m change; fi
  git -C "$SEED" push -q origin HEAD:main
  CLONE="$CDIR/clone"; git clone -q "$ORIGIN" "$CLONE" 2>/dev/null
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
    "merge_gate=ci" "mutant_job=Selection"; do
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
# Contract: bin/tkt-start header: a core/non-blocking line counts with '<n>.' or '-' then spaces and optional backtick/bold marks; a bare '*' never counts.
for spec in "zerocore|0|PREFLIGHT core=0 nonblocking=3 out=" "twocore|1|PREFLIGHT core=2 out=" "backtick|1|PREFLIGHT core=1 out=" "dashcore|1|PREFLIGHT core=2 out=" "dashnb|0|PREFLIGHT core=0 nonblocking=1 out=" "starbare|0|PREFLIGHT core=0 nonblocking=0 out="; do
  IFS='|' read -r name rc want_line <<<"$spec"
  setup "$name" TWO FILING
  case "$name" in
    zerocore) printf '1. non-blocking -- one\n2. non-blocking -- two\n3. non-blocking -- three\n' >"$T/jobout" ;;
    backtick) printf '1. `core` — first\n2. plain note\n' >"$T/jobout" ;;
    dashcore) printf -- '- core -- first\n- **core** -- second\n' >"$T/jobout" ;;
    dashnb) printf -- '- non-blocking -- a\n' >"$T/jobout" ;;
    starbare) printf '**core** -- x\n' >"$T/jobout" ;;
  esac
  run_start
  want "$want_line" "$rc" "$name"
  if [ "$name" = twocore ] || [ "$name" = dashcore ]; then case "$OUT" in *"nonblocking="*) fail "$name: nonzero core must not carry nonblocking" ;; esac; fi
done
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
bash "$SCRIPT_DIR/../bin/tkt-state" "$RUN/widget-42.state" set head deadbeefdeadbeefdeadbeefdeadbeefdeadbeef; run_start
want "DRIFT state=deadbeef" 3 drift
case "$OUT" in *"worktree=$ACTUAL"*) ;; *) fail "drift: digest misses the worktree HEAD" ;; esac
case "$OUT" in *"pr=none"*) ;; *) fail "drift: digest misses the pr head" ;; esac
bash "$SCRIPT_DIR/../bin/tkt-state" "$RUN/widget-42.state" set head "$ACTUAL"; run_start
want "CURRENT " 0 driftmatch
bash "$SCRIPT_DIR/../bin/tkt-state" "$RUN/widget-42.state" set pr 7
printf 'baadf00dbaadf00dbaadf00dbaadf00dbaadf00d\n' >"$T/prhead"; run_start
want "DRIFT state=$ACTUAL" 3 prdrift
case "$OUT" in *"pr=baadf00d"*) ;; *) fail "prdrift: digest misses the pr head" ;; esac
printf '%s\n' "$ACTUAL" >"$T/prhead"; run_start
want "CURRENT " 0 prmatch
printf '1' >"$T/gh-fail"; run_start
want "PRECONDITION pr=unreadable" 2 prunreadable
# --no-preflight on a stale ticket: check only, no job, exit 1.
setup noflightstale TWO FILING
run_start --no-preflight
want "STALE reason=" 1 noflightstale
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "noflightstale: tkt-job must not run"
[ "$(grep -c '^plan-sweep|' "$T/calls.log")" -eq 0 ] || fail "noflightstale: plan-sweep must not run"
# usage table: each missing flag, a --model without role=, a bad gate.
setup usage ONE AGAINST
for flag in --run --repo --issue --spec --branch --worktree --workflow-doc --closing; do
  reload "$flag"; run_start
  [ "$RC" -eq 2 ] || fail "usage $flag: exit $RC"
  grep -qF -- "$flag" "$CDIR/stderr" || fail "usage $flag: stderr does not name it"
done
for spec in "--model --model solorole" "--merge-gate --merge-gate someday"; do
  reload; run_start ${spec#* }
  [ "$RC" -eq 2 ] || fail "usage ${spec#* }: exit $RC"
  grep -qF -- "${spec%% *}" "$CDIR/stderr" || fail "usage ${spec#* }: stderr does not name ${spec%% *}"
done
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
printf '1. non-blocking -- only a note\n' >"$T/jobout"; touch "$T/job-concerns"; run_start
want "PREFLIGHT core=0 nonblocking=1 out=" 0 concerns
[ -s "$RUN/widget-42-preflight-out.md" ] || fail "concerns: report file missing"
# Stray stderr lines before the verdict (watch output, a blank line) are not the verdict.
setup concerns-noise TWO FILING
printf '1. non-blocking -- only a note\n' >"$T/jobout"; touch "$T/job-concerns" "$T/job-noise"; run_start
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
run_start --spec "$CDIR/spec.md" --closing "Part of #9"
want "CURRENT " 0 partok
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
echo "tkt-start: all cases passed"

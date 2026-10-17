#!/usr/bin/env bash
# Tests for bin/tkt-start: state, worktree, current check and preflight.
# Real git on throwaway repos: a temp dir with HOME and TMPDIR set inside it,
# a bare origin, a clone. A stub gh script on PATH answers gh issue view
# --json body and the lastEditedAt query from fixture files. Stub plan-sweep
# and tkt-job in the TKT_BIN dir record their argv. HOME points at a temp
# dir holding a fixture preflight template; nothing touches the network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TKT="$SCRIPT_DIR/../bin/tkt-start"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-tkt-start.XXXXXX")"
T="$(cd "$T" && pwd)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp" "$T/bin" "$T/tktbin" "$T/cases"
export HOME="$T/home" TMPDIR="$T/tmp" TKT_BIN="$T/tktbin"
export PATH="$T/bin:$PATH"

mkdir -p "$HOME/.agents/skills/planning/briefs"
printf '# fixture preflight template\n' >"$HOME/.agents/skills/planning/briefs/preflight.md"
TEMPLATE="$HOME/.agents/skills/planning/briefs/preflight.md"

cat >"$T/bin/gh" <<EOF
#!/usr/bin/env bash
printf 'gh|%s\n' "\$*" >>"$T/calls.log"
if [ -f "$T/gh-fail" ]; then exit 4; fi
case " \$* " in
  *" lastEditedAt "*) cat "$T/edited"; exit 0 ;;
esac
cat "$T/body"
exit 0
EOF
chmod +x "$T/bin/gh"

cat >"$T/tktbin/plan-sweep" <<EOF
#!/usr/bin/env bash
printf 'plan-sweep|%s\n' "\$*" >>"$T/calls.log"
if [ -f "$T/sweep-fail" ]; then echo "plan-sweep: boom" >&2; exit 6; fi
out=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "--out" ]; then out="\$a"; fi
  prev="\$a"
done
[ -n "\$out" ] && printf 'pack stub\n' >"\$out"
exit 0
EOF
chmod +x "$T/tktbin/plan-sweep"

cat >"$T/tktbin/tkt-job" <<EOF
#!/usr/bin/env bash
printf 'tkt-job|%s\n' "\$*" >>"$T/calls.log"
if [ -f "$T/job-fail" ]; then echo "tkt-job: boom" >&2; exit 3; fi
out=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "--out-file" ]; then out="\$a"; fi
  prev="\$a"
done
[ -n "\$out" ] && cat "$T/jobout" >"\$out"
exit 0
EOF
chmod +x "$T/tktbin/tkt-job"

# Fresh per-case controls and fixtures.
reset_stub() {
  : >"$T/calls.log"
  rm -f "$T/gh-fail" "$T/sweep-fail" "$T/job-fail"
  printf 'null\n' >"$T/edited"
  printf 'two core lines\n1. core -- first\n2. **core** -- second\n3. non-blocking -- other\n' >"$T/jobout"
}

# New case dir with a bare origin and a seed repo pushed to origin/main.
# Sets CDIR, ORIGIN, SEED.
new_origin() {
  CDIR="$T/cases/$1"
  rm -rf "$CDIR"
  mkdir -p "$CDIR"
  ORIGIN="$CDIR/origin.git"
  SEED="$CDIR/seed"
  git init -q --bare "$ORIGIN"
  git init -q "$SEED"
  git -C "$SEED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$SEED" remote add origin "$ORIGIN"
}

# cmt <file> <content> <message> [date]: commit a file in SEED, prints the SHA.
cmt() {
  printf '%s\n' "$2" >"$SEED/$1"
  git -C "$SEED" -c user.email=t@t -c user.name=t add -A
  if [ -n "${4:-}" ]; then
    GIT_AUTHOR_DATE="$4" GIT_COMMITTER_DATE="$4" \
      git -C "$SEED" -c user.email=t@t -c user.name=t commit -q -m "$3"
  else
    git -C "$SEED" -c user.email=t@t -c user.name=t commit -q -m "$3"
  fi
  git -C "$SEED" rev-parse HEAD
}

# Clone ORIGIN into $CDIR/clone; sets CLONE, WT, RUN.
fresh_clone() {
  CLONE="$CDIR/clone"
  git clone -q "$ORIGIN" "$CLONE" 2>/dev/null
  WT="$CDIR/wt"
  RUN="$CDIR/run"
  mkdir -p "$RUN"
}

# common_args prints one arg per line; load_args reads them into ARGS so
# values holding spaces and # survive intact.
load_args() {
  ARGS=()
  while IFS= read -r line; do
    ARGS+=("$line")
  done < <(common_args)
}

# Run tkt-start in CLONE on ARGS plus any extra args; sets OUT and RC.
run_start() {
  OUT=""
  RC=0
  OUT="$(cd "$CLONE" && bash "$TKT" "${ARGS[@]}" "$@" 2>"$CDIR/stderr")" || RC=$?
  [ -n "$OUT" ] || OUT="$(cat "$CDIR/stderr")"
}

expect_line1() {
  first="$(printf '%s\n' "$OUT" | head -n 1)"
  case "$first" in
    "TKT tkt-start $1"*) ;;
    *) fail "$2: line 1 [$first] wants prefix [TKT tkt-start $1]" ;;
  esac
}

expect_logfile() {
  log="$(printf '%s\n' "$OUT" | head -n 1 | sed -n 's/.* log=//p')"
  [ -n "$log" ] || fail "$1: no log= in line 1"
  [ -f "$log" ] || fail "$1: missing log file [$log]"
  lines="$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
  [ "$lines" -le 41 ] || fail "$1: over 40 digest lines ($lines total)"
}

state_path() {
  printf '%s\n' "$RUN/widget-42.state"
}

common_args() {
  printf '%s\n' --run "$RUN" --repo acme/widget --issue 42 --spec 42 \
    --branch tkt-start --worktree "$WT" --workflow-doc "$CDIR/wf.md" \
    --closing "Resolves #42" --env "FOO=1" --body-has "Resolves #42" \
    --body-has "Co-authored with Claude Code." --extra "$CDIR/extra.md" \
    --merge-gate ci --mutant-job Selection --model lane=sol --model preflight=luna \
    --files f.txt
}

expect_state() {
  S="$(state_path)"
  [ -f "$S" ] || fail "$1: no state file [$S]"
  for kv in "repo=acme/widget" "issue=42" "spec=42" "branch=tkt-start" \
    "worktree=$WT" "run=$RUN" "workflow_doc=$CDIR/wf.md" "closing=Resolves #42" \
    "env=FOO=1" "extra=$CDIR/extra.md" "merge_gate=ci" "mutant_job=Selection"; do
    grep -qF "$kv" "$S" || fail "$1: state misses [$kv]"
  done
  [ "$(grep -c '^body_has=' "$S")" -eq 2 ] || fail "$1: state wants 2 body_has lines"
  grep -qF "body_has=Resolves #42" "$S" || fail "$1: state misses body line 1"
  [ "$(grep -c '^model\.lane=' "$S")" -eq 1 ] || fail "$1: state wants 1 model.lane"
  [ "$(grep -c '^model\.preflight=' "$S")" -eq 1 ] || fail "$1: state wants 1 model.preflight"
  j="${S%.state}.journal"
  [ -f "$j" ] || fail "$1: no journal"
  grep -q "tkt-start state " "$j" || fail "$1: journal misses state step"
  grep -q "tkt-start worktree " "$j" || fail "$1: journal misses worktree step"
  grep -q "tkt-start check " "$j" || fail "$1: journal misses check step"
}

# --- new worktree on a current ticket ---
reset_stub; new_origin current
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
OTHER="$(cmt other.txt two other 2026-02-01T00:00:00+00:00)"
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
load_args
run_start
[ "$RC" -eq 0 ] || fail "current: exit $RC"
expect_line1 "CURRENT " current
expect_state current
expect_logfile current
[ -d "$WT" ] || fail "current: no worktree [$WT]"
[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "tkt-start" ] || fail "current: worktree not on tkt-start"
[ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$CLONE" rev-parse origin/main)" ] || fail "current: worktree not at origin/main"
git -C "$WT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 && fail "current: worktree tracks an upstream"
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "current: tkt-job must not run"
[ "$(grep -c '^plan-sweep|' "$T/calls.log")" -eq 0 ] || fail "current: plan-sweep must not run"
case "$OUT" in *"no edit info"*) ;; *) fail "current: digest misses edit evidence" ;; esac
# A rerun reuses the worktree and adds no duplicate list lines.
load_args
run_start
[ "$RC" -eq 0 ] || fail "rerun: exit $RC"
expect_line1 "CURRENT " rerun
[ "$(grep -c '^body_has=' "$(state_path)")" -eq 2 ] || fail "rerun: body_has duplicated"
[ "$(grep -c '^model\.lane=' "$(state_path)")" -eq 1 ] || fail "rerun: model.lane duplicated"

# --- existing worktree is reused, not recreated ---
reset_stub; new_origin reused
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
git -C "$CLONE" worktree add --no-track -b keepbranch "$WT" origin/main >/dev/null
printf 'marker\n' >"$WT/marker.txt"
load_args
run_start
[ "$RC" -eq 0 ] || fail "reused: exit $RC"
expect_line1 "CURRENT " reused
[ -f "$WT/marker.txt" ] || fail "reused: marker gone, worktree was recreated"
[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "keepbranch" ] || fail "reused: worktree branch changed"

# --- stale by commit: touching commit after filing runs preflight ---
reset_stub; new_origin stale
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
cmt f.txt two change 2026-02-01T00:00:00+00:00
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nfiling commit: %s\n' "$FILING" >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
load_args
run_start
[ "$RC" -eq 1 ] || fail "stale: exit $RC"
expect_line1 "PREFLIGHT core=2 out=" stale
expect_logfile stale
expect_state stale
grep -q '^plan-sweep|' "$T/calls.log" || fail "stale: plan-sweep not called"
sweep_args="$(grep '^plan-sweep|' "$T/calls.log" | head -n 1)"
case "$sweep_args" in *"--cwd $WT"*) ;; *) fail "stale: plan-sweep misses --cwd [$sweep_args]" ;; esac
case "$sweep_args" in *"--base origin/main"*) ;; *) fail "stale: plan-sweep misses --base [$sweep_args]" ;; esac
case "$sweep_args" in *"--files f.txt"*) ;; *) fail "stale: plan-sweep misses --files [$sweep_args]" ;; esac
case "$sweep_args" in *"--out $RUN/widget-42-sweep.md"*) ;; *) fail "stale: plan-sweep misses --out [$sweep_args]" ;; esac
grep -q '^tkt-job|' "$T/calls.log" || fail "stale: tkt-job not called"
job_args="$(grep '^tkt-job|' "$T/calls.log" | head -n 1)"
case "$job_args" in *"$(state_path) --slot preflight"*) ;; *) fail "stale: tkt-job misses state/slot [$job_args]" ;; esac
case "$job_args" in *"--template $TEMPLATE"*) ;; *) fail "stale: tkt-job misses template [$job_args]" ;; esac
case "$job_args" in *"--out-file $RUN/widget-42-preflight-out.md"*) ;; *) fail "stale: tkt-job misses --out-file [$job_args]" ;; esac
for kv in ISSUE=42 SPEC=42 REPO=acme/widget "WORKFLOW_DOC=$CDIR/wf.md"; do
  case "$job_args" in *"$kv"*) ;; *) fail "stale: tkt-job misses [$kv]" ;; esac
done
BASE="$(git -C "$CLONE" rev-parse origin/main)"
case "$job_args" in *"BASE=$BASE"*) ;; *) fail "stale: tkt-job misses BASE [$job_args]" ;; esac
[ -f "$RUN/widget-42-preflight-out.md" ] || fail "stale: no out file"
cmp -s "$T/jobout" "$RUN/widget-42-preflight-out.md" || fail "stale: out file differs"
j="$(state_path)"; j="${j%.state}.journal"
grep -q "tkt-start preflight " "$j" || fail "stale: journal misses preflight step"

# --- edited after filing: since form runs and shows in the digest ---
reset_stub; new_origin edited
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
cmt f.txt two change 2026-02-01T00:00:00+00:00
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
printf '2026-06-01T00:00:00Z\n' >"$T/edited"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
load_args
run_start
[ "$RC" -eq 1 ] || fail "edited: exit $RC"
expect_line1 "PREFLIGHT core=2 out=" edited
case "$OUT" in *"since=2026-06-01T00:00:00Z"*) ;; *) fail "edited: digest misses the since form" ;; esac
# An edit before the filing commit date runs no since check.
printf '2025-06-01T00:00:00Z\n' >"$T/edited"
: >"$T/calls.log"
load_args
run_start
[ "$RC" -eq 1 ] || fail "oldedit: exit $RC"
expect_line1 "PREFLIGHT core=2 out=" oldedit
case "$OUT" in *"since="*) fail "oldedit: digest must not claim a since check" ;; esac

# --- named file missing at origin/main: preflight ---
reset_stub; new_origin missing
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
load_args
run_start --files "f.txt, missing.txt"
[ "$RC" -eq 1 ] || fail "missing: exit $RC"
expect_line1 "PREFLIGHT core=2 out=" missing
grep -q '^tkt-job|' "$T/calls.log" || fail "missing: tkt-job must run"
case "$OUT" in *"missing-file:missing.txt"*) ;; *) fail "missing: digest misses the reason" ;; esac

# --- unreadable or unresolvable filing commit: preflight ---
reset_stub; new_origin badfiling
cmt f.txt one filing 2026-01-01T00:00:00+00:00 >/dev/null
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42 with no filing line.\n' >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
load_args
run_start
[ "$RC" -eq 1 ] || fail "badfiling: exit $RC"
expect_line1 "PREFLIGHT core=2 out=" badfiling
grep -q '^tkt-job|' "$T/calls.log" || fail "badfiling: tkt-job must run"
case "$OUT" in *"reason=filing-commit:unreadable"*) ;; *) fail "badfiling: digest misses the reason" ;; esac
printf 'Work for #42.\n\nWritten against deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' >"$T/body"
: >"$T/calls.log"
load_args
run_start
[ "$RC" -eq 1 ] || fail "badsha: exit $RC"
expect_line1 "PREFLIGHT core=2 out=" badsha
case "$OUT" in *"reason=filing-commit:unreadable"*) ;; *) fail "badsha: digest misses the reason" ;; esac

# --- preflight with 0 core lines exits 0 with the nonblocking count ---
reset_stub; new_origin zerocore
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
cmt f.txt two change 2026-02-01T00:00:00+00:00
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
printf '1. non-blocking -- one\n2. non-blocking -- two\n3. non-blocking -- three\n' >"$T/jobout"
load_args
run_start
[ "$RC" -eq 0 ] || fail "zerocore: exit $RC"
expect_line1 "PREFLIGHT core=0 nonblocking=3 out=" zerocore
expect_logfile zerocore

# --- preflight with 2 core lines exits 1 with no nonblocking key ---
reset_stub; new_origin twocore
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
cmt f.txt two change 2026-02-01T00:00:00+00:00
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
printf '1. core -- first\n2. **core** -- second\n3. non-blocking -- other\n' >"$T/jobout"
load_args
run_start
[ "$RC" -eq 1 ] || fail "twocore: exit $RC"
expect_line1 "PREFLIGHT core=2 out=" twocore
case "$OUT" in *"nonblocking="*) fail "twocore: nonzero core must not carry nonblocking" ;; esac

# --- --no-preflight on a stale ticket: check only, no job, exit 1 ---
reset_stub; new_origin noflightstale
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
cmt f.txt two change 2026-02-01T00:00:00+00:00
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
load_args
run_start --no-preflight
[ "$RC" -eq 1 ] || fail "noflightstale: exit $RC"
expect_line1 "STALE reason=" noflightstale
expect_logfile noflightstale
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "noflightstale: tkt-job must not run"
[ "$(grep -c '^plan-sweep|' "$T/calls.log")" -eq 0 ] || fail "noflightstale: plan-sweep must not run"

# --- --no-preflight on a current ticket: CURRENT, exit 0 ---
reset_stub; new_origin noflightcurrent
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
load_args
run_start --no-preflight
[ "$RC" -eq 0 ] || fail "noflightcurrent: exit $RC"
expect_line1 "CURRENT " noflightcurrent
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "noflightcurrent: tkt-job must not run"

# --- missing required flag exits 2 naming it ---
reset_stub; new_origin usage
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
for flag in --run --repo --issue --spec --branch --worktree --workflow-doc --closing; do
  load_args
  args=(); skip=0
  for a in ${ARGS[@]+"${ARGS[@]}"}; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$a" in
      "$flag") skip=1; continue ;;
    esac
    args+=("$a")
  done
  ARGS=(${args[@]+"${args[@]}"})
  run_start
  [ "$RC" -eq 2 ] || fail "usage $flag: exit $RC"
  grep -qF -- "$flag" "$CDIR/stderr" || fail "usage $flag: stderr does not name it"
done
# A --model without role= exits 2; a bad --merge-gate exits 2.
load_args
run_start --model solorole
[ "$RC" -eq 2 ] || fail "usage model: exit $RC"
grep -qF -- "--model" "$CDIR/stderr" || fail "usage model: stderr does not name --model"
load_args
run_start --merge-gate someday
[ "$RC" -eq 2 ] || fail "usage gate: exit $RC"
grep -qF -- "--merge-gate" "$CDIR/stderr" || fail "usage gate: stderr does not name --merge-gate"

# --- a failed GitHub read exits with its code naming the step, never CURRENT ---
reset_stub; new_origin ghfail
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
printf '1' >"$T/gh-fail"
load_args
run_start
[ "$RC" -eq 4 ] || fail "ghfail: exit $RC"
expect_line1 "STEP-FAIL step=github" ghfail
case "$OUT" in *CURRENT*) fail "ghfail: must never print CURRENT" ;; esac
case "$OUT" in *core=0*) fail "ghfail: must never print core=0" ;; esac

# --- a failed tkt-job passes through with its code naming the step ---
reset_stub; new_origin jobfail
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
cmt f.txt two change 2026-02-01T00:00:00+00:00
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
printf '1' >"$T/job-fail"
load_args
run_start
[ "$RC" -eq 3 ] || fail "jobfail: exit $RC"
expect_line1 "STEP-FAIL step=tkt-job rc=3" jobfail
case "$OUT" in *CURRENT*) fail "jobfail: must never print CURRENT" ;; esac

# --- a failed plan-sweep exits with its code naming the step ---
reset_stub; new_origin sweepfail
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
cmt f.txt two change 2026-02-01T00:00:00+00:00
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
printf '1' >"$T/sweep-fail"
load_args
run_start
[ "$RC" -eq 6 ] || fail "sweepfail: exit $RC"
expect_line1 "STEP-FAIL step=plan-sweep rc=6" sweepfail
[ "$(grep -c '^tkt-job|' "$T/calls.log")" -eq 0 ] || fail "sweepfail: tkt-job must not run after sweep fails"

# --- worktree add failure exits with its code naming the step ---
reset_stub; new_origin wtaddfail
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
git -C "$CLONE" branch tkt-start origin/main
load_args
run_start
[ "$RC" -eq 255 ] || fail "wtaddfail: exit $RC"
expect_line1 "STEP-FAIL step=worktree rc=255" wtaddfail
case "$OUT" in *CURRENT*) fail "wtaddfail: must never print CURRENT" ;; esac

# --- fetch failure exits with its code naming the step ---
reset_stub; new_origin fetchfail
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
git -C "$CLONE" remote set-url origin "$CDIR/definitely-missing.git"
load_args
run_start
[ "$RC" -eq 128 ] || fail "fetchfail: exit $RC"
expect_line1 "STEP-FAIL step=fetch rc=128" fetchfail
[ ! -e "$WT" ] || fail "fetchfail: worktree must not be created"

# --- a held state lock exits 2 naming the holder ---
reset_stub; new_origin locked
FILING="$(cmt f.txt one filing 2026-01-01T00:00:00+00:00)"
git -C "$SEED" push -q origin HEAD:main
fresh_clone
printf 'Work for #42.\n\nWritten against %s\n' "$FILING" >"$T/body"
printf 'touch\n' >"$CDIR/wf.md"; printf 'extra\n' >"$CDIR/extra.md"
mkdir -p "$RUN"
mkdir "$RUN/widget-42.state.lock"
printf '12345\n' >"$RUN/widget-42.state.lock/pid"
load_args
run_start
[ "$RC" -eq 2 ] || fail "locked: exit $RC"
expect_line1 "BUSY holder=12345" locked
grep -q '12345' "$CDIR/stderr" || fail "locked: stderr does not name pid"
rm -rf "$RUN/widget-42.state.lock"

echo "tkt-start: all cases passed"

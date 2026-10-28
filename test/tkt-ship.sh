#!/usr/bin/env bash
# Tests for bin/tkt-ship: run ship-pr from state, rerun on 124, digest red CI.
# Stubs for ship-pr, gh-ci, gh and plan-gate live on a temp TKT_BIN; the stub
# ship-pr exits per $T/exitcodes (one code per call, last repeats) and prints
# $T/shiplog to stderr. The gh stub serves $T/prhead for headRefOid queries
# and $T/ghstate otherwise. Real git on throwaway repos for drift and diff
# flags. HOME and TMPDIR point at temp dirs; nothing touches the network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TKT="$SCRIPT_DIR/../bin/tkt-ship"
REAL_BIN="$SCRIPT_DIR/../bin"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-tkt-ship.XXXXXX")"
T="$(cd "$T" && pwd)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp" "$T/bin" "$T/cases"
export HOME="$T/home" TMPDIR="$T/tmp" TKT_BIN="$T/bin"
export PATH="$T/bin:$PATH"

[ -x "$REAL_BIN/plan-gate" ] || fail "real plan-gate missing"
ln -s "$REAL_BIN/plan-gate" "$T/bin/plan-gate" || fail "symlink plan-gate"

cat >"$T/bin/ship-pr" <<EOF
#!/usr/bin/env bash
printf 'ship-pr|cwd=%s|%s\n' "\$(pwd)" "\$*" >>"$T/calls.log"
for a in "\$@"; do printf 'arg|%s\n' "\$a" >>"$T/calls.log"; done
n="\$(cat "$T/count")"; printf '%s' "\$((n+1))" >"$T/count"
codes="\$(cat "$T/exitcodes")"
code="\$(printf '%s' "\$codes" | awk -v i="\$((n+1))" '{print (i<=NF ? \$i : \$NF)}')"
[ -f "$T/shiplog" ] && cat "$T/shiplog" >&2
if [ "\$code" = "0" ]; then echo "merged \$(cat "$T/sha" 2>/dev/null || printf deadbeef1234567890)"; fi
exit "\$code"
EOF
chmod +x "$T/bin/ship-pr"

cat >"$T/bin/gh-ci" <<EOF
#!/usr/bin/env bash
printf 'gh-ci|LINES=%s|cwd=%s|%s\n' "\${GH_CI_LOG_LINES:-}" "\$(pwd)" "\$*" >>"$T/calls.log"
if [ "\${1:-}" = "failures" ]; then
  [ -f "$T/failures-log" ] && cat "$T/failures-log"
  [ ! -f "$T/ghci-fail" ] || exit 1
fi
exit 0
EOF
chmod +x "$T/bin/gh-ci"

cat >"$T/bin/gh" <<EOF
#!/usr/bin/env bash
printf 'gh|%s\n' "\$*" >>"$T/calls.log"
case " \$* " in
  *" headRefOid "*) cat "$T/prhead"; exit 0 ;;
esac
if [ "\${1:-}" = "pr" ]; then cat "$T/ghstate"; fi
exit 0
EOF
chmod +x "$T/bin/gh"

# Reset per-case stub controls.
reset_stub() {
  printf '0' >"$T/count"
  : >"$T/calls.log"
  rm -f "$T/shiplog" "$T/failures-log" "$T/ghci-fail" "$T/sha" "$T/ghstate" "$T/exitcodes"
  printf '7' >"$T/exitcodes"
  printf 'OPEN' >"$T/ghstate"
  : >"$T/prhead"
}

# New case dir with run dir, git worktree and base state (head set, PR head
# matches: no drift). Sets CDIR, WT, S and H.
setup_case() {
  CDIR="$T/cases/$1"
  mkdir -p "$CDIR/run" "$CDIR/wt"
  WT="$CDIR/wt"
  S="$CDIR/tkt.state"
  H="$(fresh_repo "$WT")"
  printf '%s' "$H" >"$T/prhead"
  {
    printf 'repo=%s\n' acme/repo
    printf 'issue=%s\n' 515
    printf 'pr=%s\n' 7
    printf 'reviewed=%s\n' rev123
    printf 'worktree=%s\n' "$WT"
    printf 'run=%s\n' "$CDIR/run"
    printf 'head=%s\n' "$H"
  } >"$S"
}

# Throwaway git repo: one commit on origin/main, then a commit touching
# src/a.go. Prints HEAD; sets nothing.
fresh_repo() {
  git init -q "$1"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$1" update-ref refs/remotes/origin/main HEAD
  mkdir -p "$1/src"
  printf 'x\n' >"$1/src/a.go"
  git -C "$1" -c user.email=t@t -c user.name=t add -A
  git -C "$1" -c user.email=t@t -c user.name=t commit -q -m change
  git -C "$1" rev-parse HEAD
}

# Run tkt-ship on $S; sets OUT (stdout) and RC. Never fails the suite itself.
# With a directory argument, run from there instead of this shell's cwd.
run_ship() {
  OUT=""
  RC=0
  if [ $# -gt 0 ]; then
    OUT="$( (cd "$1" && bash "$TKT" "$S" 2>"$CDIR/stderr") )" || RC=$?
  else
    OUT="$(bash "$TKT" "$S" 2>"$CDIR/stderr")" || RC=$?
  fi
  [ -n "$OUT" ] || OUT="$(cat "$CDIR/stderr")"
}

expect_line1() {
  first="$(printf '%s\n' "$OUT" | head -n 1)"
  case "$first" in
    "TKT tkt-ship $1"*) ;;
    *) fail "$2: line 1 [$first] wants prefix [TKT tkt-ship $1]" ;;
  esac
}

expect_journal() {
  j="${S%.state}.journal"
  [ -f "$j" ] || fail "$1: no journal"
  grep -q "tkt-ship $2" "$j" || fail "$1: journal misses [$2]"
}

expect_logfile() {
  log="$(printf '%s\n' "$OUT" | head -n 1 | sed -n 's/.* log=//p')"
  [ -n "$log" ] || fail "$1: no log= in line 1"
  [ -f "$log" ] || fail "$1: missing log file [$log]"
}

# --- merged ---
reset_stub; setup_case merged
printf '0' >"$T/exitcodes"; printf 'cafef00d1234' >"$T/sha"
run_ship
[ "$RC" -eq 0 ] || fail "merged: exit $RC"
expect_line1 "MERGED sha=cafef00d1234 " merged
expect_journal merged MERGED
expect_logfile merged
[ ! -e "$S.lock" ] || fail "merged: lock not released"
[ "$(printf '%s\n' "$OUT" | wc -l)" -le 41 ] || fail "merged: over 40 digest lines"

# --- flake note on stderr text ---
reset_stub; setup_case flake
printf '0' >"$T/exitcodes"
printf 'CI failure outside the diff (x); rerunning failed jobs once -- file the flake\n' >"$T/shiplog"
run_ship
[ "$RC" -eq 0 ] || fail "flake: exit $RC"
expect_line1 "MERGED sha=" flake
case "$OUT" in *FLAKE-NOTE*) ;; *) fail "flake: no FLAKE-NOTE" ;; esac

# --- 124 rerun loop ends PENDING after three reruns ---
reset_stub; setup_case pending
printf '124' >"$T/exitcodes"
run_ship
[ "$RC" -eq 1 ] || fail "pending: exit $RC"
expect_line1 "PENDING attempts=4" pending
[ "$(grep -c '^ship-pr|' "$T/calls.log")" -eq 4 ] || fail "pending: wants 4 ship-pr calls"

# --- 124 then success merges ---
reset_stub; setup_case retry
printf '124 0' >"$T/exitcodes"
run_ship
[ "$RC" -eq 0 ] || fail "retry: exit $RC"
expect_line1 "MERGED sha=" retry
[ "$(grep -c '^ship-pr|' "$T/calls.log")" -eq 2 ] || fail "retry: wants 2 ship-pr calls"

# --- CI-FAIL with panics, diff flags and mutant lines ---
reset_stub; setup_case cifail
printf '1' >"$T/exitcodes"
printf 'ship-pr: CI failed\n' >"$T/shiplog"
cat >"$T/failures-log" <<'LOGEOF'
=== CI / unit (11): failure
##[error] failing step: run unit tests
thread 'x' panicked at src/a.go:10:5
--- FAIL: TestFoo
=== CI / mutants-shard-2 (12): failure
MISSED mutant src/a.go:12
TIMEOUT mutant src/b.go:3
thread 'y' panicked at vendor/other.go:1:2
LOGEOF
run_ship
[ "$RC" -eq 1 ] || fail "cifail: exit $RC"
expect_line1 "CI-FAIL jobs=2 inside-diff=1 mutants=2" cifail
grep -F -q "gh-ci|LINES=300|cwd=$WT|failures --pr 7 --repo acme/repo" "$T/calls.log" || fail "cifail: gh-ci not called with LINES=300, --repo and worktree cwd"
case "$OUT" in *"job: CI / unit (11)"*) ;; *) fail "cifail: no job name" ;; esac
case "$OUT" in *"panic [in-diff]: thread 'x' panicked at src/a.go"*) ;; *) fail "cifail: no in-diff panic" ;; esac
case "$OUT" in *"panic [outside]: thread 'y' panicked at vendor/other.go"*) ;; *) fail "cifail: no outside panic" ;; esac
case "$OUT" in *"mutant: MISSED mutant src/a.go:12"*) ;; *) fail "cifail: no MISSED line" ;; esac
case "$OUT" in *"mutant: TIMEOUT mutant src/b.go:3"*) ;; *) fail "cifail: no TIMEOUT line" ;; esac
expect_journal cifail CI-FAIL

# --- CI-FAIL on a multi-file diff: the list must reach awk whole (#787) ---
reset_stub; setup_case cifail-multi
printf 'x\n' >"$WT/src/b.go"
git -C "$WT" -c user.email=t@t -c user.name=t add -A
git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m two
NH="$(git -C "$WT" rev-parse HEAD)"
grep -v '^head=' "$S" >"$S.n"
printf 'head=%s\n' "$NH" >>"$S.n"
mv "$S.n" "$S"
printf '%s' "$NH" >"$T/prhead"
printf '1' >"$T/exitcodes"
printf 'ship-pr: CI failed\n' >"$T/shiplog"
cat >"$T/failures-log" <<'LOGEOF'
=== CI / unit (11): failure
##[error] failing step: run unit tests
thread 'x' panicked at src/b.go:10:5
LOGEOF
run_ship
[ "$RC" -eq 1 ] || fail "cifail-multi: exit $RC"
expect_line1 "CI-FAIL jobs=1 inside-diff=1 mutants=0" cifail-multi
case "$OUT" in *"panic [in-diff]: thread 'x' panicked at src/b.go"*) ;; *) fail "cifail-multi: no in-diff panic in second file" ;; esac
expect_journal cifail-multi CI-FAIL

# --- gate failure skips gh-ci ---
reset_stub; setup_case gatefail
printf '1' >"$T/exitcodes"
printf 'ship-pr: gate failed\n' >"$T/shiplog"
run_ship
[ "$RC" -eq 1 ] || fail "gatefail: exit $RC"
expect_line1 "GATE-FAIL" gatefail
grep -q '^gh-ci|' "$T/calls.log" && fail "gatefail: gh-ci must not run"

# --- merge error but GitHub says MERGED ---
reset_stub; setup_case remerged
printf '1' >"$T/exitcodes"
printf 'ship-pr: gh pr merge failed\n' >"$T/shiplog"
printf 'MERGED' >"$T/ghstate"
run_ship
[ "$RC" -eq 0 ] || fail "remerged: exit $RC"
expect_line1 "MERGED" remerged
grep -q '^gh|' "$T/calls.log" || fail "remerged: gh pr view not called"

# --- merge error, still open ---
reset_stub; setup_case mergefail
printf '1' >"$T/exitcodes"
printf 'ship-pr: merge status could not be confirmed after 12 polls\n' >"$T/shiplog"
printf 'OPEN' >"$T/ghstate"
run_ship
[ "$RC" -eq 1 ] || fail "mergefail: exit $RC"
expect_line1 "MERGE-FAIL" mergefail

# --- conflict ---
reset_stub; setup_case conflict
printf '3' >"$T/exitcodes"
printf 'ship-pr: rebase onto origin/main conflicts\n' >"$T/shiplog"
run_ship
[ "$RC" -eq 1 ] || fail "conflict: exit $RC"
expect_line1 "CONFLICT" conflict

# --- patch changed ---
reset_stub; setup_case patch
printf '4' >"$T/exitcodes"
run_ship
[ "$RC" -eq 1 ] || fail "patch: exit $RC"
expect_line1 "PATCH-CHANGED head=$H" patch

# --- body lines missing ---
reset_stub; setup_case body
printf '5' >"$T/exitcodes"
printf 'missing body line: Resolves #515\n' >"$T/shiplog"
run_ship
[ "$RC" -eq 1 ] || fail "body: exit $RC"
expect_line1 "BODY" body
case "$OUT" in *"missing body line: Resolves #515"*) ;; *) fail "body: digest misses the line" ;; esac

# --- precondition ---
reset_stub; setup_case precond
printf '2' >"$T/exitcodes"
printf 'ship-pr: no such worktree\n' >"$T/shiplog"
run_ship
[ "$RC" -eq 2 ] || fail "precond: exit $RC"
expect_line1 "PRECONDITION" precond

# --- unknown exit ---
reset_stub; setup_case unknown
printf '7' >"$T/exitcodes"
run_ship
[ "$RC" -eq 3 ] || fail "unknown: exit $RC"
expect_line1 "UNKNOWN rc=7" unknown

# --- missing state key exits 2 naming it on stdout and stderr ---
reset_stub; setup_case missingkey
grep -v '^pr=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
run_ship
[ "$RC" -eq 2 ] || fail "missingkey: exit $RC"
expect_line1 "PRECONDITION missing=pr" missingkey
grep -q 'missing key: pr' "$CDIR/stderr" || fail "missingkey: stderr does not name pr"
case "$OUT" in *pr*) ;; *) fail "missingkey: output does not name pr" ;; esac

# --- missing head key exits 2 naming it on stdout and stderr ---
reset_stub; setup_case nohead
grep -v '^head=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
run_ship
[ "$RC" -eq 2 ] || fail "nohead: exit $RC"
expect_line1 "PRECONDITION missing=head" nohead
grep -q 'missing key: head' "$CDIR/stderr" || fail "nohead: stderr does not name head"

# --- head drift exits 3 naming all three SHAs on stdout and stderr ---
reset_stub; setup_case drift
grep -v '^head=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
printf 'head=%s\n' dead00000000000000000000000000000000000000 >>"$S"
run_ship
[ "$RC" -eq 3 ] || fail "drift: exit $RC"
expect_line1 "DRIFT state=dead00000000000000000000000000000000000000" drift
case "$OUT" in *"$H"*) ;; *) fail "drift: worktree/PR HEAD not named" ;; esac
grep -q 'dead00000000000000000000000000000000000000' "$CDIR/stderr" || fail "drift: stderr misses state head"
grep -q "$H" "$CDIR/stderr" || fail "drift: stderr misses worktree HEAD"
[ "$(grep -c '^ship-pr|' "$T/calls.log")" -eq 0 ] || fail "drift: ship-pr must not run"

# --- PR head drift exits 3 naming all three SHAs ---
reset_stub; setup_case prdrift
printf '%s' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' >"$T/prhead"
run_ship
[ "$RC" -eq 3 ] || fail "prdrift: exit $RC"
expect_line1 "DRIFT state=$H worktree=$H pr=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" prdrift
[ "$(grep -c '^ship-pr|' "$T/calls.log")" -eq 0 ] || fail "prdrift: ship-pr must not run"

# --- held ship lock exits 2 naming the holder's pid ---
reset_stub; setup_case locked
mkdir "$S.lock"
printf '12345\n' >"$S.lock/pid"
run_ship
[ "$RC" -eq 2 ] || fail "locked: exit $RC"
expect_line1 "BUSY holder=12345" locked
grep -q '12345' "$CDIR/stderr" || fail "locked: stderr does not name pid"
[ "$(grep -c '^ship-pr|' "$T/calls.log")" -eq 0 ] || fail "locked: ship-pr must not run"
rm -rf "$S.lock"

# --- live holder pid on <state>.lock exits 2 naming the pid, ship-pr not invoked ---
reset_stub; setup_case livelock
mkdir "$S.lock"
printf '%s\n' "$$" >"$S.lock/pid"
run_ship
[ "$RC" -eq 2 ] || fail "livelock: exit $RC"
expect_line1 "BUSY holder=$$" livelock
grep -q "$$" "$CDIR/stderr" || fail "livelock: stderr does not name pid"
[ "$(grep -c '^ship-pr|' "$T/calls.log")" -eq 0 ] || fail "livelock: ship-pr must not run"
rm -rf "$S.lock"

# --- flags from state reach ship-pr ---
reset_stub; setup_case flags
printf '0' >"$T/exitcodes"
printf 'body_has=%s\n' 'Resolves #515' 'Co-authored-by: T' >>"$S"
printf 'unverified text\n' >"$CDIR/unverified.md"
printf 'unverified=%s\n' "$CDIR/unverified.md" >>"$S"
printf 'merge_gate=%s\n' gate >>"$S"
printf 'env=%s\n' 'FOO=1 BAR=2' >>"$S"
printf '# Plan\n\n## Gate\n\n`bash test/gate.sh`\n' >"$CDIR/plan.md"
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
run_ship
[ "$RC" -eq 0 ] || fail "flags: exit $RC"
grep -F -q -- '--body-has Resolves #515' "$T/calls.log" || fail "flags: body-has 1 missing"
grep -F -q -- '--body-has Co-authored-by: T' "$T/calls.log" || fail "flags: body-has 2 missing"
[ "$(grep -c -x -F 'arg|--body-ends' "$T/calls.log")" -eq 1 ] || fail "flags: body-ends once: $(cat "$T/calls.log")"
got="$(grep -A1 -x -F 'arg|--body-ends' "$T/calls.log" | sed -n 2p)"
[ "$got" = 'arg|Co-authored with Claude Code.' ] || fail "flags: body-ends value, got [$got]"
grep -F -q -- "--unverified-fixes $CDIR/unverified.md" "$T/calls.log" || fail "flags: unverified missing"
grep -F -q -- '--gate FOO=1 BAR=2 bash test/gate.sh' "$T/calls.log" || fail "flags: gate missing"

# --- no_mutants_label set: reason reaches ship-pr as one argument ---
reset_stub; setup_case nomutants
printf '0' >"$T/exitcodes"
printf 'no_mutants_label=%s\n' 'test-only PR, nothing to mutate' >>"$S"
run_ship
[ "$RC" -eq 0 ] || fail "nomutants: exit $RC"
[ "$(grep -c -x -F 'arg|--no-mutants-label' "$T/calls.log")" -eq 1 ] || fail "nomutants: flag missing: $(cat "$T/calls.log")"
got="$(grep -A1 -x -F 'arg|--no-mutants-label' "$T/calls.log" | sed -n 2p)"
[ "$got" = 'arg|test-only PR, nothing to mutate' ] || fail "nomutants: reason not one argument, got [$got]"

# --- no_mutants_label unset: ship-pr gets no such flag ---
reset_stub; setup_case nomutantsunset
printf '0' >"$T/exitcodes"
run_ship
[ "$RC" -eq 0 ] || fail "nomutantsunset: exit $RC"
[ "$(grep -c -F 'no-mutants-label' "$T/calls.log")" -eq 0 ] || fail "nomutantsunset: flag present: $(cat "$T/calls.log")"
[ "$(grep -c -x -F 'arg|--body-ends' "$T/calls.log")" -eq 1 ] || fail "nomutantsunset: body-ends once without body_has: $(cat "$T/calls.log")"
got="$(grep -A1 -x -F 'arg|--body-ends' "$T/calls.log" | sed -n 2p)"
[ "$got" = 'arg|Co-authored with Claude Code.' ] || fail "nomutantsunset: body-ends value, got [$got]"

# --- ship-pr runs from the run dir even when the caller is in the worktree ---
reset_stub; setup_case shipcwd
printf '0' >"$T/exitcodes"
run_ship "$WT"
[ "$RC" -eq 0 ] || fail "shipcwd: exit $RC"
want="$(cd "$CDIR/run" && pwd -P)"
got="$(sed -n 's/^ship-pr|cwd=\([^|]*\)|.*/\1/p' "$T/calls.log" | head -n 1)"
[ -n "$got" ] || fail "shipcwd: no ship-pr call recorded"
got_p="$(cd "$got" && pwd -P)"
[ "$got_p" = "$want" ] || fail "shipcwd: ship-pr cwd [$got_p] wants [$want]"

# --- a relative worktree in state reaches ship-pr absolute ---
reset_stub; setup_case relwork
printf '0' >"$T/exitcodes"
grep -v '^worktree=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
printf 'worktree=%s\n' "relwork/wt" >>"$S"
run_ship "$T/cases"
[ "$RC" -eq 0 ] || fail "relwork: exit $RC"
wtabs="$(cd "$WT" && pwd)"
grep -F -q -- "--worktree $wtabs" "$T/calls.log" || fail "relwork: ship-pr misses the absolute worktree: $(cat "$T/calls.log")"

# --- a relative worktree that exists nowhere is rejected ---
reset_stub; setup_case relmissing
grep -v '^worktree=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
printf 'worktree=%s\n' "relwork/nope" >>"$S"
run_ship "$T/cases"
[ "$RC" -eq 2 ] || fail "relmissing: exit $RC, want 2"
expect_line1 "PRECONDITION relative=" relmissing
[ "$(grep -c '^ship-pr|' "$T/calls.log")" -eq 0 ] || fail "relmissing: ship-pr must not run"

echo "tkt-ship: all cases passed"

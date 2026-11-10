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
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "edit" ]; then
  [ ! -f "$T/body-write-fail" ] || exit 1
  previous=""
  for arg in "\$@"; do
    if [ "\$previous" = "--body-file" ]; then cat "\$arg" >"$T/prbody"; fi
    previous="\$arg"
  done
  exit 0
fi
case " \$* " in
  *" headRefOid "*) cat "$T/prhead"; exit 0 ;;
  *"--json body"*) [ ! -f "$T/body-read-fail" ] || exit 1; { cat "$T/prbody" 2>/dev/null || printf ''; }; exit 0 ;;
esac
if [ "\${1:-}" = "pr" ]; then cat "$T/ghstate"; fi
exit 0
EOF
chmod +x "$T/bin/gh"

# Reset per-case stub controls.
reset_stub() {
  printf '0' >"$T/count"
  : >"$T/calls.log"
  rm -f "$T/shiplog" "$T/failures-log" "$T/ghci-fail" "$T/sha" "$T/ghstate" "$T/exitcodes" "$T/body-read-fail" "$T/body-write-fail"
  printf '7' >"$T/exitcodes"
  printf 'OPEN' >"$T/ghstate"
  : >"$T/prhead"
  : >"$T/prbody"
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

# --- a current LINES plan verdict refuses ship with both sanctioned exits ---
reset_stub; setup_case verdict-lines
printf '0' >"$T/exitcodes"
printf 'Base: %s\n\n## Files\n\n- `src/a.go`\n\n## Gate\n\n`true`\n' "$H" >"$CDIR/plan.md"
printf 'plan=%s\nplan_verdict=lines\nplan_verdict_base=%s\nplan_verdict_hash=%s\n' \
  "$CDIR/plan.md" "$H" "$(git hash-object "$CDIR/plan.md")" >>"$S"
run_ship
[ "$RC" -eq 1 ] || fail "LINES verdict refuses ship (rc=$RC)"
expect_line1 "VERDICT-REFUSED verdict=lines" "LINES verdict refusal"
case "$OUT" in *"plan_verdict=lines plan_verdict_base=$H plan_base=$H"*) ;; *) fail "LINES refusal has the build verdict digest: [$OUT]" ;; esac
case "$OUT" in *"tkt-plan $S triaged --comment <id>"*) ;; *) fail "LINES refusal names triaged exit: [$OUT]" ;; esac
case "$OUT" in *"edit the plan and use --no-verifier"*) ;; *) fail "LINES refusal names edit and --no-verifier exit: [$OUT]" ;; esac
[ "$(grep -c '^ship-pr|' "$T/calls.log")" -eq 0 ] || fail "LINES verdict does not invoke ship-pr"

# --- accepted plan verdicts and a missing verdict key preserve ship behavior ---
for accepted in ok triaged; do
  reset_stub; setup_case "verdict-$accepted"
  printf '0' >"$T/exitcodes"
  printf 'Base: %s\n\n## Files\n\n- `src/a.go`\n\n## Gate\n\n`true`\n' "$H" >"$CDIR/plan.md"
  printf 'plan=%s\nplan_verdict=%s\nplan_verdict_hash=%s\n' \
    "$CDIR/plan.md" "$accepted" "$(git hash-object "$CDIR/plan.md")" >>"$S"
  run_ship
  [ "$RC" -eq 0 ] || fail "$accepted verdict permits ship (rc=$RC)"
  expect_line1 "MERGED sha=" "$accepted verdict permits ship"
done

reset_stub; setup_case verdict-absent
printf '0' >"$T/exitcodes"
printf 'Base: %s\n\n## Files\n\n- `src/a.go`\n\n## Gate\n\n`true`\n' "$H" >"$CDIR/plan.md"
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
run_ship
[ "$RC" -eq 0 ] || fail "missing plan verdict key permits ship (rc=$RC)"
expect_line1 "MERGED sha=" "missing plan verdict key permits ship"

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

# --- lost-race merge error, still open ---
reset_stub; setup_case lostrace
printf '1' >"$T/exitcodes"
printf 'ship-pr: gh pr merge failed: lost the race to origin/main (the rebased head lost the race again); rerun: bash /x/ship-pr 7\n' >"$T/shiplog"
printf 'OPEN' >"$T/ghstate"
run_ship
[ "$RC" -eq 1 ] || fail "lostrace: exit $RC"
expect_line1 "MERGE-FAIL" lostrace

# --- lost-race merge error but GitHub says MERGED ---
reset_stub; setup_case lostremerged
printf '1' >"$T/exitcodes"
printf 'ship-pr: gh pr merge failed: lost the race to origin/main (the rebased head lost the race again); rerun: bash /x/ship-pr 7\n' >"$T/shiplog"
printf 'MERGED' >"$T/ghstate"
run_ship
[ "$RC" -eq 0 ] || fail "lostremerged: exit $RC"
expect_line1 "MERGED" lostremerged

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
printf 'missing body line: Resolves #515\nship-pr: BODY text needs a required line\nship-pr: refused BODY\n' >"$T/shiplog"
run_ship
[ "$RC" -eq 1 ] || fail "body: exit $RC"
expect_line1 "BODY" body
case "$OUT" in *"missing body line: Resolves #515"*) ;; *) fail "body: digest misses the line" ;; esac

# --- a mutants refusal reports the family named by ship-pr ---
reset_stub; setup_case mutants-refusal
printf '5' >"$T/exitcodes"
printf 'ship-pr: refused MUTANTS\nmutants gate needs zero-proof evidence\n' >"$T/shiplog"
run_ship
[ "$RC" -eq 1 ] || fail "mutants-refusal: exit $RC"
expect_line1 "MUTANTS" mutants-refusal
case "$OUT" in *"mutants gate needs zero-proof evidence"*) ;; *) fail "mutants-refusal: digest misses ship-pr log tail" ;; esac

# --- a review refusal reports the family named by ship-pr ---
reset_stub; setup_case review-refusal
printf '5' >"$T/exitcodes"
printf 'ship-pr: refused REVIEW\nreview state needs a scoped verify\n' >"$T/shiplog"
run_ship
[ "$RC" -eq 1 ] || fail "review-refusal: exit $RC"
expect_line1 "REVIEW" review-refusal
case "$OUT" in *"review state needs a scoped verify"*) ;; *) fail "review-refusal: digest misses ship-pr log tail" ;; esac

# --- an unclassified exit 5 is an honest SHIP outcome, not a guessed family ---
reset_stub; setup_case unclassified
printf '5' >"$T/exitcodes"
printf 'ship-pr: refusal wording changed\ninspect this ship-pr failure\n' >"$T/shiplog"
run_ship
[ "$RC" -eq 1 ] || fail "unclassified: exit $RC"
expect_line1 "SHIP" unclassified
case "$OUT" in *"inspect this ship-pr failure"*) ;; *) fail "unclassified: digest misses ship-pr log tail" ;; esac

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

# --- missing reviewed distinguishes a gate-blocked review and names its repair ---
reset_stub; setup_case missingreviewed-gatefailed
grep -v '^reviewed=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
printf 'review_status=gate-failed\n' >>"$S"
run_ship
[ "$RC" -eq 2 ] || fail "missingreviewed-gatefailed: exit $RC"
expect_line1 "PRECONDITION missing=reviewed" missingreviewed-gatefailed
case "$OUT" in *"tkt-build $S --from gate"*) ;; *) fail "missingreviewed-gatefailed: refusal names the gate repair command: [$OUT]" ;; esac

# A deliberately skipped review is distinct from work blocked by the gate.
reset_stub; setup_case missingreviewed-skipped
grep -v '^reviewed=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
printf 'review_status=skipped\n' >>"$S"
run_ship
[ "$RC" -eq 2 ] || fail "missingreviewed-skipped: exit $RC"
expect_line1 "PRECONDITION missing=reviewed" missingreviewed-skipped
case "$OUT" in *"review_status=skipped"*"tkt-build $S --from review"*) ;; *) fail "missingreviewed-skipped: refusal distinguishes deliberate skip and names review repair: [$OUT]" ;; esac

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
printf 'body_ends=%s\n' 'Co-authored with Claude Code.' >>"$S"
printf 'unverified text\n' >"$CDIR/unverified.md"
printf 'unverified=%s\n' "$CDIR/unverified.md" >>"$S"
printf 'merge_gate=%s\n' gate >>"$S"
printf 'merge_check=%s\n' 'cargo check --all-targets' >>"$S"
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
[ "$(grep -c -x -F 'arg|--merge-check' "$T/calls.log")" -eq 0 ] || fail "flags: merge-check omitted when merge_gate=gate"

# --- merge_check reaches ship-pr for a CI merge gate ---
reset_stub; setup_case mergecheck-ci
printf '0' >"$T/exitcodes"
printf 'merge_gate=%s\n' ci >>"$S"
printf 'merge_check=%s\n' 'cargo check --all-targets' >>"$S"
run_ship
[ "$RC" -eq 0 ] || fail "mergecheck-ci: exit $RC"
[ "$(grep -c -x -F 'arg|--merge-check' "$T/calls.log")" -eq 1 ] || fail "mergecheck-ci: merge-check flag missing: $(cat "$T/calls.log")"
got="$(grep -A1 -x -F 'arg|--merge-check' "$T/calls.log" | sed -n 2p)"
[ "$got" = 'arg|cargo check --all-targets' ] || fail "mergecheck-ci: value not one argument, got [$got]"
[ "$(grep -c -x -F 'arg|--gate' "$T/calls.log")" -eq 0 ] || fail "mergecheck-ci: no local gate"

# --- merge_check applies the env prefix for a CI merge gate ---
reset_stub; setup_case mergecheck-env
printf '0' >"$T/exitcodes"
printf 'merge_gate=%s\n' ci >>"$S"
printf 'merge_check=%s\n' 'cargo check --all-targets' >>"$S"
printf 'env=%s\n' 'FOO=1 BAR=2' >>"$S"
run_ship
[ "$RC" -eq 0 ] || fail "mergecheck-env: exit $RC"
[ "$(grep -c -x -F 'arg|--merge-check' "$T/calls.log")" -eq 1 ] || fail "mergecheck-env: merge-check flag missing: $(cat "$T/calls.log")"
got="$(grep -A1 -x -F 'arg|--merge-check' "$T/calls.log" | sed -n 2p)"
[ "$got" = 'arg|FOO=1 BAR=2 cargo check --all-targets' ] || fail "mergecheck-env: value misses env prefix, got [$got]"

# --- mutant_job opts the ticket into the mutants gate
reset_stub; setup_case mutantjob
printf '0' >"$T/exitcodes"
printf 'mutant_job=%s\n' Selection >>"$S"
run_ship
[ "$RC" -eq 0 ] || fail "mutantjob: exit $RC"
[ "$(grep -c -x -F 'arg|--mutants-gate' "$T/calls.log")" -eq 1 ] || fail "mutantjob: mutants gate flag missing: $(cat "$T/calls.log")"

# --- gate.script set: a Gate line that hand-expands it stops ship before ship-pr ---
reset_stub; setup_case gate-script-hand
printf '0' >"$T/exitcodes"
printf 'merge_gate=%s\n' gate >>"$S"
printf 'gate.script=%s\n' test/gate.sh >>"$S"
printf '# Plan\n\n## Gate\n\n`cargo test`\n' >"$CDIR/plan.md"
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
run_ship
[ "$RC" -eq 2 ] || fail "gate-script-hand: exit $RC"
expect_line1 "PRECONDITION gate=failed" gate-script-hand
[ "$(grep -c '^ship-pr|' "$T/calls.log")" -eq 0 ] || fail "gate-script-hand: ship-pr must not run"

# --- the same Gate line stops a CI-gated ship too (no merge_gate key) ---
reset_stub; setup_case gate-script-ci
printf '0' >"$T/exitcodes"
printf 'gate.script=%s\n' test/gate.sh >>"$S"
printf '# Plan\n\n## Gate\n\n`cargo test`\n' >"$CDIR/plan.md"
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
run_ship
[ "$RC" -eq 2 ] || fail "gate-script-ci: exit $RC"
expect_line1 "PRECONDITION gate=failed" gate-script-ci
[ "$(grep -c '^ship-pr|' "$T/calls.log")" -eq 0 ] || fail "gate-script-ci: ship-pr must not run"

# --- no_mutants_label set: reason reaches ship-pr as one argument ---
reset_stub; setup_case nomutants
printf '0' >"$T/exitcodes"
printf 'no_mutants_label=%s\n' 'test-only PR, nothing to mutate' >>"$S"
run_ship
[ "$RC" -eq 0 ] || fail "nomutants: exit $RC"
[ "$(grep -c -x -F 'arg|--no-mutants-label' "$T/calls.log")" -eq 1 ] || fail "nomutants: flag missing: $(cat "$T/calls.log")"
got="$(grep -A1 -x -F 'arg|--no-mutants-label' "$T/calls.log" | sed -n 2p)"
[ "$got" = 'arg|test-only PR, nothing to mutate' ] || fail "nomutants: reason not one argument, got [$got]"

# --- no_mutants_label unset: ship-pr gets no such flag, and no body_ends
# line means no --body-ends check ---
reset_stub; setup_case nomutantsunset
printf '0' >"$T/exitcodes"
run_ship
[ "$RC" -eq 0 ] || fail "nomutantsunset: exit $RC"
[ "$(grep -c -F 'no-mutants-label' "$T/calls.log")" -eq 0 ] || fail "nomutantsunset: flag present: $(cat "$T/calls.log")"
[ "$(grep -c -F 'mutants-gate' "$T/calls.log")" -eq 0 ] || fail "nomutantsunset: mutants gate without mutant_job: $(cat "$T/calls.log")"
[ "$(grep -c -x -F 'arg|--body-ends' "$T/calls.log")" -eq 0 ] || fail "nomutantsunset: body-ends without a body_ends line: $(cat "$T/calls.log")"

# --- body_ends from state reaches ship-pr as one argument ---
reset_stub; setup_case bodyends
printf '0' >"$T/exitcodes"
printf 'body_ends=%s\n' 'X' >>"$S"
run_ship
[ "$RC" -eq 0 ] || fail "bodyends: exit $RC"
[ "$(grep -c -x -F 'arg|--body-ends' "$T/calls.log")" -eq 1 ] || fail "bodyends: body-ends once: $(cat "$T/calls.log")"
got="$(grep -A1 -x -F 'arg|--body-ends' "$T/calls.log" | sed -n 2p)"
[ "$got" = 'arg|X' ] || fail "bodyends: body-ends value, got [$got]"
grep -v '^body_ends=' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
printf 'body_ends=%s\n' 'X y' >>"$S"
: >"$T/calls.log"
run_ship
[ "$RC" -eq 0 ] || fail "bodyends-space: exit $RC"
[ "$(grep -c -x -F 'arg|--body-ends' "$T/calls.log")" -eq 1 ] || fail "bodyends-space: body-ends once: $(cat "$T/calls.log")"
got="$(grep -A1 -x -F 'arg|--body-ends' "$T/calls.log" | sed -n 2p)"
[ "$got" = 'arg|X y' ] || fail "bodyends-space: body-ends value, got [$got]"

# --- an empty body_ends line means no check, so no flag ---
reset_stub; setup_case bodyendsempty
printf '0' >"$T/exitcodes"
printf 'body_ends=\n' >>"$S"
run_ship
[ "$RC" -eq 0 ] || fail "bodyendsempty: exit $RC"
[ "$(grep -c -x -F 'arg|--body-ends' "$T/calls.log")" -eq 0 ] || fail "bodyendsempty: body-ends with an empty line: $(cat "$T/calls.log")"

# --- a blank body_ends line means no check, so no flag ---
reset_stub; setup_case bodyendsblank
printf '0' >"$T/exitcodes"
printf 'body_ends=   \n' >>"$S"
run_ship
[ "$RC" -eq 0 ] || fail "bodyendsblank: exit $RC"
[ "$(grep -c -x -F 'arg|--body-ends' "$T/calls.log")" -eq 0 ] || fail "bodyendsblank: body-ends with a blank line: $(cat "$T/calls.log")"

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

# The ship notice is first on stderr; the verdict remains stdout line 1.
reset_stub; setup_case notice
printf '0' >"$T/exitcodes"
run_ship
[ "$RC" -eq 0 ] || fail "notice: exit $RC"
expect_line1 "MERGED sha=" notice
[ "$(head -n 1 "$CDIR/stderr")" = "tkt-ship: no shell timeout: waits are bounded at 144000 s (40 h), worst case; a clean run takes minutes" ] \
  || fail "notice is stderr line 1: [$(cat "$CDIR/stderr")]"

# Usage errors print guidance but no wait notice.
usage_rc=0
bash "$TKT" >"$T/usage-out" 2>"$T/usage-err" || usage_rc=$?
[ "$usage_rc" -eq 2 ] || fail "usage: exit $usage_rc"
! grep -q '^tkt-ship: no shell timeout' "$T/usage-err" || fail "usage error has no longest-wait notice: [$(cat "$T/usage-err")]"
grep -q 'background' "$T/usage-err" && grep -q 'no shell timeout' "$T/usage-err" \
  || fail "usage mentions background and no shell timeout: [$(cat "$T/usage-err")]"
grep -q 'unverified' "$T/usage-err" \
  || fail "usage names the unverified state key: [$(cat "$T/usage-err")]"
grep -q -F -- '--unverified-fixes' "$T/usage-err" \
  || fail "usage names --unverified-fixes: [$(cat "$T/usage-err")]"
grep -q -F -- 'merge_check' "$T/usage-err" && grep -q -F -- '--merge-check' "$T/usage-err" \
  || fail "usage names the merge_check state key and --merge-check: [$(cat "$T/usage-err")]"

# CI-FAIL carries never-started lines and omits the empty failed-jobs summary.
reset_stub; setup_case neverstarted
printf '1' >"$T/exitcodes"
printf 'gh-ci: check ci has no check run after 10 min; it never started\n' >"$T/shiplog"
run_ship
[ "$RC" -eq 1 ] || fail "neverstarted: exit $RC"
expect_line1 "CI-FAIL jobs=0 inside-diff=0 mutants=0" neverstarted
case "$OUT" in *"gh-ci: check ci has no check run after 10 min; it never started"*) ;; *) fail "digest carries never-started line: [$OUT]" ;; esac
case "$OUT" in *"gh-ci reported no failed jobs"*) fail "digest drops empty failed-jobs line: [$OUT]" ;; esac

# --- a stale Local gate sha refuses ship ---
reset_stub; setup_case gateship-stale
printf '0' >"$T/exitcodes"
stale="0000000000000000000000000000000000000000"
printf 'Title\n\nLocal gate: pass at %s (bash test/gate.sh)\nImplemented by: m/a\n' "$stale" >"$T/prbody"
cp "$T/prbody" "$CDIR/body-before"
run_ship
[ "$RC" -eq 1 ] || fail "gateship-stale: exit $RC"
expect_line1 "GATE-STALE gate=$stale head=$H" gateship-stale
grep -Fq "tkt-ship: Local gate sha $stale is not PR head $H (gate: bash test/gate.sh); the gate did not run on the head" "$CDIR/stderr" \
  || fail "gateship-stale: stderr misses the refusal reason: [$(cat "$CDIR/stderr")]"
cmp -s "$CDIR/body-before" "$T/prbody" || fail "gateship-stale: stale body remains unchanged without a journal PASS"
! grep -q '^gh|pr edit ' "$T/calls.log" || fail "gateship-stale: no body edit without a journal PASS"
[ "$(grep -c '^ship-pr|' "$T/calls.log")" -eq 0 ] || fail "gateship-stale: did not invoke ship-pr after refusing"

# --- a fresh Local gate sha says nothing ---
reset_stub; setup_case gateship-fresh
printf '0' >"$T/exitcodes"
printf 'Title\n\nLocal gate: pass at %s (bash test/gate.sh)\nImplemented by: m/a\n' "$H" >"$T/prbody"
run_ship
[ "$RC" -eq 0 ] || fail "gateship-fresh: exit $RC"
expect_line1 "MERGED sha=" gateship-fresh
grep -q "Local gate" "$CDIR/stderr" && fail "gateship-fresh: unexpected Local gate warning: [$(cat "$CDIR/stderr")]"

# --- no journal PASS and no Local gate body line says nothing and leaves the body alone ---
reset_stub; setup_case gateship-noline
printf '0' >"$T/exitcodes"
printf 'Title\n\nImplemented by: m/a\n' >"$T/prbody"
cp "$T/prbody" "$CDIR/body-before"
run_ship
[ "$RC" -eq 0 ] || fail "gateship-noline: exit $RC"
expect_line1 "MERGED sha=" gateship-noline
grep -q "Local gate" "$CDIR/stderr" && fail "gateship-noline: unexpected Local gate warning: [$(cat "$CDIR/stderr")]"
grep -q "Local gate" <<<"$OUT" && fail "gateship-noline: unexpected Local gate line in output"
cmp -s "$CDIR/body-before" "$T/prbody" || fail "gateship-noline: body changed without a journal PASS"
! grep -q '^gh|pr edit ' "$T/calls.log" || fail "gateship-noline: no body edit without a journal PASS"

# --- a PASS at the PR head restores the missing line in gate placement, silently ---
reset_stub; setup_case gateship-fill
printf '0' >"$T/exitcodes"
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `src/a.go`

## Gate

`bash test/gate.sh`
EOF
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
bash "$REAL_BIN/tkt-state" "$S" journal "tkt-gate PASS head=1111111111111111111111111111111111111111" || fail "gateship-fill: journal an earlier gate PASS"
bash "$REAL_BIN/tkt-state" "$S" journal "tkt-gate PASS head=$H" || fail "gateship-fill: journal the latest gate PASS"
printf 'Title\n\nSome text.\nImplemented by: m/a\n' >"$T/prbody"
run_ship
[ "$RC" -eq 0 ] || fail "gateship-fill: exit $RC"
expect_line1 "MERGED sha=" gateship-fill
grep -q "Local gate" "$CDIR/stderr" && fail "gateship-fill: unexpected Local gate output: [$(cat "$CDIR/stderr")]"
cat >"$CDIR/body-expected" <<EOF
Title

Some text.
Local gate: pass at $H (bash test/gate.sh)
Implemented by: m/a
EOF
cmp -s "$CDIR/body-expected" "$T/prbody" || fail "gateship-fill: body line is not in gate placement: [$(cat "$T/prbody")]"
grep -q '^gh|pr edit ' "$T/calls.log" || fail "gateship-fill: edited body after a current PASS"

# --- a PASS at an older head refuses with both shas and the gate command ---
reset_stub; setup_case gateship-earlier
printf '0' >"$T/exitcodes"
OLD=1111111111111111111111111111111111111111
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `src/a.go`

## Gate

`bash test/gate.sh`
EOF
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
bash "$REAL_BIN/tkt-state" "$S" journal "tkt-gate PASS head=$OLD" || fail "gateship-earlier: journal the gate PASS"
printf 'Title\n' >"$T/prbody"
cp "$T/prbody" "$CDIR/body-before"
run_ship
[ "$RC" -eq 1 ] || fail "gateship-earlier: exit $RC"
expect_line1 "GATE-STALE gate=$OLD head=$H" gateship-earlier
grep -Fq "tkt-ship: tkt-gate last passed at $OLD but PR head is $H; the gate did not run on the head (gate: bash test/gate.sh)" "$CDIR/stderr" \
  || fail "gateship-earlier: stderr misses the stale-gate refusal: [$(cat "$CDIR/stderr")]"
[ "$(grep -c 'tkt-gate last passed at' "$CDIR/stderr")" = "1" ] || fail "gateship-earlier: head-drift refusal is not printed exactly once"
cmp -s "$CDIR/body-before" "$T/prbody" || fail "gateship-earlier: body changed after an older PASS"
! grep -q '^gh|pr edit ' "$T/calls.log" || fail "gateship-earlier: no body edit after an older PASS"
[ "$(grep -c '^ship-pr|' "$T/calls.log")" -eq 0 ] || fail "gateship-earlier: did not invoke ship-pr after refusing"

# A full PASS at B overrides an older Local gate body line without warning.
reset_stub; setup_case gateship-pass-current-stale-body
printf '0' >"$T/exitcodes"
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `src/a.go`

## Gate

`bash test/gate.sh`
EOF
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
printf 'Title\n\nLocal gate: pass at %s (bash test/gate.sh)\nImplemented by: m/a\n' "$OLD" >"$T/prbody"
bash "$REAL_BIN/tkt-state" "$S" journal "tkt-gate PASS head=$H" || fail "gateship-pass-current-stale-body: journal the current gate PASS"
run_ship
[ "$RC" -eq 0 ] || fail "gateship-pass-current-stale-body: exit $RC"
expect_line1 "MERGED sha=" gateship-pass-current-stale-body
grep -q 'Local gate' "$CDIR/stderr" && fail "gateship-pass-current-stale-body: unexpected Local gate warning: [$(cat "$CDIR/stderr")]"
cat >"$CDIR/body-expected" <<EOF
Title

Local gate: pass at $H (bash test/gate.sh)
Implemented by: m/a
EOF
cmp -s "$CDIR/body-expected" "$T/prbody" || fail "gateship-pass-current-stale-body: stale body line was not rewritten: [$(cat "$T/prbody")]"
grep -q '^gh|pr edit ' "$T/calls.log" || fail "gateship-pass-current-stale-body: edited body after a current PASS"

# A checks-only PASS at B cannot replace a full PASS at A for ship coverage.
reset_stub; setup_case gateship-checks-only-at-new-head
printf '0' >"$T/exitcodes"
A="$H"
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `src/a.go`

## Gate

`bash test/gate.sh`
EOF
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
bash "$REAL_BIN/tkt-state" "$S" journal "tkt-gate PASS head=$A" || fail "gateship-checks-only-at-new-head: journal the earlier full PASS"
printf 'new commit\n' >"$WT/src/b.go"
git -C "$WT" -c user.email=t@t -c user.name=t add src/b.go
git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m second
B="$(git -C "$WT" rev-parse HEAD)"
bash "$REAL_BIN/tkt-state" "$S" set head "$B" || fail "gateship-checks-only-at-new-head: update state head"
printf '%s' "$B" >"$T/prhead"
H="$B"
bash "$REAL_BIN/tkt-state" "$S" journal "tkt-gate PASS head=$B checks-only" || fail "gateship-checks-only-at-new-head: journal the checks-only PASS"
printf 'Title\n\nImplemented by: m/a\n' >"$T/prbody"
cp "$T/prbody" "$CDIR/body-before"
run_ship
[ "$RC" -eq 1 ] || fail "gateship-checks-only-at-new-head: exit $RC"
expect_line1 "GATE-STALE gate=$A head=$B" gateship-checks-only-at-new-head
grep -Fq "tkt-ship: tkt-gate last passed at $A but PR head is $B; the gate did not run on the head" "$CDIR/stderr" \
  || fail "gateship-checks-only-at-new-head: stderr misses the full-PASS refusal: [$(cat "$CDIR/stderr")]"
! grep -q 'Local gate: pass at' "$T/prbody" || fail "gateship-checks-only-at-new-head: checks-only PASS inserted a body line"
cmp -s "$CDIR/body-before" "$T/prbody" || fail "gateship-checks-only-at-new-head: body changed after an older full PASS"
[ "$(grep -c '^ship-pr|' "$T/calls.log")" -eq 0 ] || fail "gateship-checks-only-at-new-head: did not invoke ship-pr after refusing"

# A body line cannot hide a stale journal PASS.
reset_stub; setup_case gateship-pass-with-body
printf '0' >"$T/exitcodes"
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `src/a.go`

## Gate

`bash test/gate.sh`
EOF
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
bash "$REAL_BIN/tkt-state" "$S" journal "tkt-gate PASS head=$OLD" || fail "gateship-pass-with-body: journal the old gate PASS"
printf 'Title\n\nLocal gate: pass at %s (bash test/gate.sh)\nImplemented by: m/a\n' "$H" >"$T/prbody"
run_ship
[ "$RC" -eq 1 ] || fail "gateship-pass-with-body: exit $RC"
expect_line1 "GATE-STALE gate=$OLD head=$H" gateship-pass-with-body
grep -Fq "tkt-ship: tkt-gate last passed at $OLD but PR head is $H; the gate did not run on the head (gate: bash test/gate.sh)" "$CDIR/stderr" \
  || fail "gateship-pass-with-body: body line hid the stale-gate refusal: [$(cat "$CDIR/stderr")]"
[ "$(grep -c 'tkt-gate last passed at' "$CDIR/stderr")" = "1" ] || fail "gateship-pass-with-body: stale-gate refusal is not printed exactly once"
! grep -q '^gh|pr edit ' "$T/calls.log" || fail "gateship-pass-with-body: no body edit after an older PASS"
[ "$(grep -c '^ship-pr|' "$T/calls.log")" -eq 0 ] || fail "gateship-pass-with-body: did not invoke ship-pr after refusing"

# --- body read failure only warns, and body write failure only warns ---
reset_stub; setup_case gateship-readfail
printf '0' >"$T/exitcodes"
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `src/a.go`

## Gate

`bash test/gate.sh`
EOF
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
bash "$REAL_BIN/tkt-state" "$S" journal "tkt-gate PASS head=$H" || fail "gateship-readfail: journal the current gate PASS"
: >"$T/body-read-fail"
run_ship
[ "$RC" -eq 0 ] || fail "gateship-readfail: exit $RC"
expect_line1 "MERGED sha=" gateship-readfail
grep -q 'cannot read PR 7 body; skipping the Local gate check' "$CDIR/stderr" || fail "gateship-readfail: missing read warning: [$(cat "$CDIR/stderr")]"
! grep -q 'tkt-gate last passed at' "$CDIR/stderr" || fail "gateship-readfail: unexpected stale-gate refusal: [$(cat "$CDIR/stderr")]"
! grep -q '^gh|pr edit ' "$T/calls.log" || fail "gateship-readfail: no edit after a failed body read"

reset_stub; setup_case gateship-writefail
printf '0' >"$T/exitcodes"
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `src/a.go`

## Gate

`bash test/gate.sh`
EOF
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
bash "$REAL_BIN/tkt-state" "$S" journal "tkt-gate PASS head=$H" || fail "gateship-writefail: journal the gate PASS"
printf 'Title\n' >"$T/prbody"
cp "$T/prbody" "$CDIR/body-before"
: >"$T/body-write-fail"
run_ship
[ "$RC" -eq 0 ] || fail "gateship-writefail: exit $RC"
grep -q 'cannot update PR 7 body; leaving it unchanged' "$CDIR/stderr" || fail "gateship-writefail: missing write warning: [$(cat "$CDIR/stderr")]"
cmp -s "$CDIR/body-before" "$T/prbody" || fail "gateship-writefail: body changed despite edit failure"

echo "tkt-ship: all cases passed"

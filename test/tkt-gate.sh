#!/usr/bin/env bash
# Tests for bin/tkt-gate: pre-push checks and the gate on the remote tip.
# A stub plan-gate on a temp TKT_BIN prints the canned gate command; stub gate
# commands live there too. Real git on throwaway repos with a bare origin.
# Tests set HOME and TMPDIR to a temp dir and never read $HOME/.agents.
# No test touches the network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../bin/tkt-gate"
TKT_STATE="$SCRIPT_DIR/../bin/tkt-state"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-tkt-gate.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp" "$T/bin" "$T/cases"
export HOME="$T/home" TMPDIR="$T/tmp" TKT_BIN="$T/bin"
export PATH="$T/bin:$PATH"

# Stub plan-gate: print the canned gate command for the case.
cat >"$T/bin/plan-gate" <<EOF
#!/usr/bin/env bash
cat "$T/gate-cmd"
EOF
chmod +x "$T/bin/plan-gate"
printf 'gate-ok\n' >"$T/gate-cmd"

# Stub gates. gate-ok passes and marks its run; gate-bad echoes, then fails,
# so a writer judged by its trailing echo would report success.
cat >"$T/bin/gate-ok" <<EOF
#!/usr/bin/env bash
touch "$T/gate-ran"
echo "gate ok"
EOF
cat >"$T/bin/gate-bad" <<EOF
#!/usr/bin/env bash
touch "$T/gate-ran"
echo "gate log line 1"
echo "thread 'x' panicked at src/main.rs:9"
i=3
while [ "\$i" -le 30 ]; do
  echo "gate log line \$i"
  i=\$((i + 1))
done
echo "error: boom"
exit 3
EOF
cat >"$T/bin/gate-quiet" <<EOF
#!/usr/bin/env bash
touch "$T/gate-ran"
exit 4
EOF
chmod +x "$T/bin/gate-ok" "$T/bin/gate-bad" "$T/bin/gate-quiet"

# New case: a bare origin, a seed main pushed to it, and a clone worktree on
# branch tkt-517 with a base state file. Sets CDIR, WT, S.
setup_case() {
  CDIR="$T/cases/$1"
  mkdir -p "$CDIR/run"
  git init -q --bare "$CDIR/origin.git"
  git init -q "$CDIR/seed"
  git -C "$CDIR/seed" symbolic-ref HEAD refs/heads/main
  git -C "$CDIR/seed" config user.email t@t
  git -C "$CDIR/seed" config user.name t
  printf 'base\n' >"$CDIR/seed/base.txt"
  git -C "$CDIR/seed" add base.txt
  git -C "$CDIR/seed" commit -qm init
  git -C "$CDIR/seed" remote add origin "$CDIR/origin.git"
  git -C "$CDIR/seed" push -q origin main
  WT="$CDIR/wt"
  git clone -q "$CDIR/origin.git" "$WT"
  git -C "$WT" config user.email t@t
  git -C "$WT" config user.name t
  git -C "$WT" checkout -qb tkt-517
  S="$CDIR/tkt.state"
  {
    printf 'repo=%s\n' switchyard
    printf 'issue=%s\n' 517
    printf 'run=%s\n' "$CDIR/run"
    printf 'worktree=%s\n' "$WT"
    printf 'branch=%s\n' tkt-517
  } >"$S"
  printf 'gate-ok\n' >"$T/gate-cmd"
  rm -f "$T/gate-ran"
}

# Default plan: Files covers base.txt. The Gate section is never read here
# because plan-gate is stubbed.
write_plan() {
  cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `base.txt`

## Gate

`gate-ok`
EOF
  printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
}

commit_file() {
  printf '%s\n' "$2" >"$WT/$1"
  git -C "$WT" add "$1"
  git -C "$WT" commit -qm "$1"
}

push_branch() {
  git -C "$WT" push -q origin tkt-517
}

# Run tkt-gate on the current case state; sets OUT and RC, keeps stderr in file.
run_gate() {
  OUT="$(bash "$GATE" "$S" "$@" 2>"$CDIR/stderr.txt")"; RC=$?
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

# --- PASS: tip matches, the fence covers the change, the gate passes ---
setup_case pass
write_plan
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set env "FOO=bar" || fail "set env"
run_gate --expect-head "$H"
[ "$RC" -eq 0 ] || fail "PASS exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=$H log=*" "PASS"
grep -qx "commits=1 merges=0" <<<"$OUT" || fail "PASS digest counts the history"
grep -qx "gate=PASS" <<<"$OUT" || fail "PASS digest names the gate result"
[ -f "$T/gate-ran" ] || fail "PASS runs the gate"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$H" ] || fail "PASS sets state head"
grep -q "tkt-gate PASS" "$CDIR/tkt.journal" || fail "PASS journals the verdict"
logpath="${OUT%%$'\n'*}"; logpath="${logpath##*log=}"
[ -f "$logpath" ] || fail "PASS writes its log file"
grep -q "PASS head=$H" "$logpath" || fail "PASS log holds the verdict"

# --- PASS with no new commits: an empty diff and an empty history ---
setup_case pass-empty
write_plan
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$H" || fail "set head"
run_gate
[ "$RC" -eq 0 ] || fail "empty PASS exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=$H log=*" "empty PASS"
grep -qx "commits=0 merges=0" <<<"$OUT" || fail "empty PASS counts zero commits"

# --- TIP: a local commit the origin never saw runs no gate ---
setup_case tip-unpushed
write_plan
commit_file base.txt "base changed"
run_gate
[ "$RC" -eq 1 ] || fail "TIP exits 1"
expect_verdict "TKT tkt-gate TIP * log=*" "TIP"
grep -q "missing" <<<"$OUT" || fail "TIP names the missing ref"
[ ! -f "$T/gate-ran" ] || fail "TIP runs no gate"

# --- TIP: the origin is behind the local HEAD, even with --expect-head=HEAD ---
setup_case tip-behind
write_plan
commit_file base.txt "base changed"
push_branch
commit_file base.txt "one more"
H="$(git -C "$WT" rev-parse HEAD)"
run_gate --expect-head "$H"
[ "$RC" -eq 1 ] || fail "behind TIP exits 1"
expect_verdict "TKT tkt-gate TIP * log=*" "behind TIP"
grep -q "origin/tkt-517" <<<"$OUT" || fail "behind TIP names the remote ref"
[ ! -f "$T/gate-ran" ] || fail "behind TIP runs no gate"

# --- TIP: origin matches --expect-head but not the local HEAD ---
setup_case tip-expect-stale
write_plan
commit_file base.txt "base changed"
push_branch
PUSHED="$(git -C "$WT" rev-parse HEAD)"
commit_file base.txt "one more"
run_gate --expect-head "$PUSHED"
[ "$RC" -eq 1 ] || fail "stale expect TIP exits 1"
expect_verdict "TKT tkt-gate TIP * log=*" "stale expect TIP"
[ ! -f "$T/gate-ran" ] || fail "stale expect TIP runs no gate"

# --- TIP: --expect-head names another sha ---
setup_case tip-expect
write_plan
commit_file base.txt "base changed"
push_branch
run_gate --expect-head 0000000000000000000000000000000000000000
[ "$RC" -eq 1 ] || fail "expect TIP exits 1"
expect_verdict "TKT tkt-gate TIP * log=*" "expect TIP"
grep -q "0000000000000000000000000000000000000000" <<<"$OUT" || fail "expect TIP names the expected sha"

# --- FENCE: an uncovered file runs no gate ---
setup_case fence
write_plan
commit_file evil.txt "evil"
push_branch
run_gate
[ "$RC" -eq 1 ] || fail "FENCE exits 1"
expect_verdict "TKT tkt-gate FENCE n=1 log=*" "FENCE"
grep -qx "evil.txt" <<<"$OUT" || fail "FENCE digest lists the path"
[ ! -f "$T/gate-ran" ] || fail "FENCE runs no gate"

# --- FENCE lists 30 paths fully, then counts the rest ---
setup_case fence-many
write_plan
i=1
while [ "$i" -le 32 ]; do
  printf 'x\n' >"$WT/f$i.txt"
  i=$((i + 1))
done
git -C "$WT" add -A
git -C "$WT" commit -qm many
push_branch
run_gate
[ "$RC" -eq 1 ] || fail "many FENCE exits 1"
expect_verdict "TKT tkt-gate FENCE n=32 log=*" "many FENCE"
[ "$(grep -c "^f[0-9]*\.txt$" <<<"$OUT")" -eq 30 ] || fail "many FENCE lists 30 paths"
grep -qx "... and 2 more" <<<"$OUT" || fail "many FENCE counts the rest"

# --- FENCE at the edge: 30 uncovered files list fully with no rest line ---
setup_case fence-thirty
write_plan
i=1
while [ "$i" -le 30 ]; do
  printf 'x\n' >"$WT/g$i.txt"
  i=$((i + 1))
done
git -C "$WT" add -A
git -C "$WT" commit -qm thirty
push_branch
run_gate
[ "$RC" -eq 1 ] || fail "thirty FENCE exits 1"
expect_verdict "TKT tkt-gate FENCE n=30 log=*" "thirty FENCE"
[ "$(grep -c "^g[0-9]*\.txt$" <<<"$OUT")" -eq 30 ] || fail "thirty FENCE lists every path"
grep -q "more" <<<"$OUT" && fail "thirty FENCE has no rest line"

# --- a renamed file is listed under its old path: Files covers only the new
# --- name, so the fence fires on the old one. Without --no-renames the diff
# --- would list moved.txt alone and pass.
setup_case rename
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `moved.txt`

## Gate

`gate-ok`
EOF
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
git -C "$WT" mv base.txt moved.txt
git -C "$WT" commit -qm rename
push_branch
run_gate
[ "$RC" -eq 1 ] || fail "rename exits 1"
expect_verdict "TKT tkt-gate FENCE n=1 log=*" "rename"
grep -qx "base.txt" <<<"$OUT" || fail "rename fence lists the old path"
[ ! -f "$T/gate-ran" ] || fail "rename runs no gate"

# --- a `*` cover in Files ---
setup_case glob
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `bin/*`

## Gate

`gate-ok`
EOF
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
mkdir -p "$WT/bin"
commit_file bin/new.sh "#!/bin/sh"
push_branch
run_gate
[ "$RC" -eq 0 ] || fail "glob exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "glob"

# --- a `/` cover in Files ---
setup_case dir
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `test/`

## Gate

`gate-ok`
EOF
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
mkdir -p "$WT/test"
commit_file test/new.sh "# test"
push_branch
run_gate
[ "$RC" -eq 0 ] || fail "dir exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "dir"

# --- FAIL: the gate echoes, then fails; the exit code survives ---
setup_case fail
write_plan
commit_file base.txt "base changed"
push_branch
printf 'gate-bad\n' >"$T/gate-cmd"
run_gate
[ "$RC" -eq 1 ] || fail "FAIL exits 1"
expect_verdict "TKT tkt-gate FAIL rc=3 log=*" "FAIL"
grep -qx "error: boom" <<<"$OUT" || fail "FAIL digest holds the error line"
grep -q "panicked" <<<"$OUT" || fail "FAIL digest holds the panicked line"
grep -qx "gate log line 12" <<<"$OUT" || fail "FAIL digest holds the last 20 lines"
grep -qx "gate log line 11" <<<"$OUT" && fail "FAIL digest drops older lines"
gatelog="$(grep '^gatelog=' <<<"$OUT" | head -n 1)"; gatelog="${gatelog#gatelog=}"
[ -f "$gatelog" ] || fail "FAIL digest names the gate log"
if bash "$TKT_STATE" "$S" get head >/dev/null 2>&1; then
  fail "FAIL sets no state head"
fi

# --- FAIL with no error lines: the digest is just the tail ---
setup_case fail-quiet
write_plan
commit_file base.txt "base changed"
push_branch
printf 'gate-quiet\n' >"$T/gate-cmd"
run_gate
[ "$RC" -eq 1 ] || fail "quiet FAIL exits 1"
expect_verdict "TKT tkt-gate FAIL rc=4 log=*" "quiet FAIL"
grep -qx "commits=1 merges=0" <<<"$OUT" || fail "quiet FAIL digest counts the history"
grep -q "^gatelog=" <<<"$OUT" || fail "quiet FAIL digest names the gate log"

# --- --checks-only runs no gate, even a failing one ---
setup_case checks-only
write_plan
commit_file base.txt "base changed"
push_branch
printf 'gate-bad\n' >"$T/gate-cmd"
H="$(git -C "$WT" rev-parse HEAD)"
run_gate --checks-only
[ "$RC" -eq 0 ] || fail "--checks-only exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=$H log=*" "--checks-only"
grep -qx "gate=skipped" <<<"$OUT" || fail "--checks-only digest marks the gate skipped"
[ ! -f "$T/gate-ran" ] || fail "--checks-only runs no gate"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$H" ] || fail "--checks-only sets state head"

# --- the state fence list covers the change with no plan key ---
setup_case fence-list
printf 'fence=%s\n' 'base.txt' >>"$S"
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
run_gate --checks-only
[ "$RC" -eq 0 ] || fail "fence list exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=$H log=*" "fence list"

# --- a gate with no plan key exits 2 naming plan ---
setup_case gate-no-plan
printf 'fence=%s\n' 'base.txt' >>"$S"
commit_file base.txt "base changed"
push_branch
run_gate
[ "$RC" -eq 2 ] || fail "gate without plan exits 2"
grep -q "plan" "$CDIR/stderr.txt" || fail "gate without plan names plan"
[ ! -f "$T/gate-ran" ] || fail "gate without plan runs no gate"

# --- history: the digest counts commits and merges ---
setup_case merges
write_plan
commit_file base.txt "one"
git -C "$WT" checkout -qb side
commit_file base.txt "two"
git -C "$WT" checkout -q tkt-517
git -C "$WT" merge -q --no-ff side -m merge-side
push_branch
run_gate
[ "$RC" -eq 0 ] || fail "merges exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "merges"
grep -qx "commits=3 merges=1" <<<"$OUT" || fail "merges digest counts commits and merges"

# --- a missing state key exits 2 naming it ---
setup_case missing-key
write_plan
grep -v '^branch=' "$S" >"$CDIR/nobranch.state"
S="$CDIR/nobranch.state"
run_gate
[ "$RC" -eq 2 ] || fail "missing key exits 2"
grep -q "branch" "$CDIR/stderr.txt" || fail "missing key names branch"
[ ! -f "$T/gate-ran" ] || fail "missing key runs no gate"

# --- neither plan nor fence exits 2 naming plan ---
setup_case no-fence-source
run_gate
[ "$RC" -eq 2 ] || fail "no fence source exits 2"
grep -q "plan" "$CDIR/stderr.txt" || fail "no fence source names plan"

# --- head drift exits 3 naming the stored head and the worktree HEAD ---
setup_case drift
write_plan
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head 0000000000000000000000000000000000000000 || fail "set fake head"
run_gate
[ "$RC" -eq 3 ] || fail "drift exits 3"
grep -q "0000000000000000000000000000000000000000" "$CDIR/stderr.txt" || fail "drift names the stored head"
grep -q "$H" "$CDIR/stderr.txt" || fail "drift names the worktree HEAD"
[ ! -f "$T/gate-ran" ] || fail "drift runs no gate"

# --- a held lock exits 2 naming the pid, and runs no gate ---
setup_case locked
write_plan
mkdir "$S.lock"
printf '424242\n' >"$S.lock/pid"
run_gate
[ "$RC" -eq 2 ] || fail "a held lock exits 2"
grep -q "424242" "$CDIR/stderr.txt" || fail "a held lock names the pid"
[ ! -f "$T/gate-ran" ] || fail "a held lock runs no gate"
rm -rf "$S.lock"

echo "tkt-gate: all cases passed"

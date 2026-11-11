#!/usr/bin/env bash
# Tests for bin/tkt-gate: pre-push checks and the gate on the remote tip.
# A stub plan-gate on a temp TKT_BIN prints the canned gate command; stub gate
# commands live there too. Real git on throwaway repos with a bare origin.
# Tests set HOME and TMPDIR to a temp dir and never read $HOME/.agents.
# GIT_CONFIG_NOSYSTEM keeps the cases off the host git config, and each case
# pins its own branch refs, so init.defaultBranch cannot break the clone.
# No test touches the network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../bin/tkt-gate"
SHIP="$SCRIPT_DIR/../bin/tkt-ship"
TKT_STATE="$SCRIPT_DIR/../bin/tkt-state"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-tkt-gate.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp" "$T/bin" "$T/cases"
export HOME="$T/home" TMPDIR="$T/tmp" TKT_BIN="$T/bin"
export PATH="$T/bin:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null T
unset CARGO_SLOT_REAL

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
cat >"$T/bin/gate-empty" <<EOF
#!/usr/bin/env bash
touch "$T/gate-ran"
echo "error: no tests to run"
EOF
chmod +x "$T/bin/gate-ok" "$T/bin/gate-bad" "$T/bin/gate-quiet" "$T/bin/gate-empty"

cat >"$T/bin/cargo" <<EOF
#!/usr/bin/env bash
printf 'held=%s\n' "\${CARGO_SLOT_HELD-unset}" >"$T/cargo-held"
printf 'threads=%s\n' "\${NEXTEST_TEST_THREADS-unset}" >"$T/cargo-threads"
printf 'args=%s\n' "\$*" >"$T/cargo-args"
EOF
chmod +x "$T/bin/cargo"

cat >"$T/bin/gh" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" --json headRefOid "*) cat "$T/pr-head" 2>/dev/null; exit 0 ;;
  *" --json body "*) cat "$T/pr-body" 2>/dev/null; exit 0 ;;
  *" pr edit "*)
    previous=""
    for arg in "\$@"; do
      if [ "\$previous" = "--body-file" ]; then cat "\$arg" >"$T/pr-body"; fi
      previous="\$arg"
    done
    exit 0 ;;
esac
exit 0
EOF
cat >"$T/bin/ship-pr" <<'EOF'
#!/usr/bin/env bash
echo 'merged test-sha'
EOF
chmod +x "$T/bin/gh" "$T/bin/ship-pr"

# New case: a bare origin, a seed main pushed to it, and a clone worktree on
# branch tkt-517 with a base state file. Sets CDIR, WT, S.
setup_case() {
  CDIR="$T/cases/$1"
  mkdir -p "$CDIR/run"
  FW_RUN="$CDIR/run"
  export FW_RUN
  git init -q --bare "$CDIR/origin.git"
  git --git-dir="$CDIR/origin.git" symbolic-ref HEAD refs/heads/main
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
  DELEGATE_JOBS_DIR="$CDIR/jobs"
  export DELEGATE_JOBS_DIR
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

setup_from_job_case() {
  setup_case "$1"
  write_plan
  commit_file base.txt "base changed"
  push_branch
  H="$(git -C "$WT" rev-parse HEAD)"
  printf '%s\n' "$H" >"$T/pr-head"
  : >"$T/pr-body"
  bash "$TKT_STATE" "$S" set pr 7 || fail "from-job set PR"
  mkdir -p "$DELEGATE_JOBS_DIR"
}

plant_job_record() {
  local id="$1" gate="$2" exit_code="$3" head="$4" dirty_after="$5"
  case "$gate" in
    none)
      jq -n --arg head "$head" --argjson dirty "$dirty_after" \
        '{result:{changeSet:{headAfter:$head,dirtyAfter:$dirty}}}' \
        >"$DELEGATE_JOBS_DIR/$id.json" || fail "plant model-reported record $id" ;;
    *)
      jq -n --arg head "$head" --argjson exit_code "$exit_code" --argjson dirty "$dirty_after" \
        '{result:{gateResult:{command:"bash gate-wrapper.sh",exitCode:$exit_code},
                  changeSet:{headAfter:$head,dirtyAfter:$dirty}}}' \
        >"$DELEGATE_JOBS_DIR/$id.json" || fail "plant delegate record $id" ;;
  esac
}

journal_env64() {
  printf '%s' "$(bash "$TKT_STATE" "$S" get env 2>/dev/null || true)" | jq -Rrs '@base64'
}

journal_job_gate() {
  bash "$TKT_STATE" "$S" journal "tkt-job gate slot=fix1 job=$1 cmd64=$(printf '%s' "$2" | jq -Rrs '@base64') env64=$(journal_env64)" || fail "journal delegate gate command"
  cp "$CDIR/tkt.journal" "$CDIR/journal-before"
}

expect_from_job_refusal() {
  local id="$1" check="$2"
  run_gate --from-job "$id"
  [ "$RC" -ne 0 ] || fail "--from-job $check refusal exits nonzero"
  grep -Fq -- "--from-job check failed: $check" "$CDIR/stderr.txt" || fail "--from-job refusal names $check: $(cat "$CDIR/stderr.txt")"
  cmp -s "$CDIR/journal-before" "$CDIR/tkt.journal" || fail "--from-job $check refusal writes no journal lines"
  ! grep -q 'tkt-gate PASS head=' "$CDIR/tkt.journal" || fail "--from-job $check refusal journals no PASS"
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

expect_stop_list_path() {
  local path="$1"
  grep -Fqx "$path — contract change: ask first" <<<"$OUT" \
    || fail "stop-list names $path with contract-change instruction: [$OUT]"
  [ "$(bash "$TKT_STATE" "$S" list outside_plan)" = "" ] \
    || fail "stop-list does not record refused paths in outside_plan"
  [ ! -f "$T/gate-ran" ] || fail "stop-list refusal runs no gate"
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
grep -Eq "tkt-gate PASS head=$H$" "$CDIR/tkt.journal" || fail "PASS journals a plain full-gate verdict"
! grep -q "tkt-gate PASS head=$H checks-only" "$CDIR/tkt.journal" || fail "PASS is not marked checks-only"
logpath="${OUT%%$'\n'*}"; logpath="${logpath##*log=}"
[ -f "$logpath" ] || fail "PASS writes its log file"
grep -q "PASS head=$H" "$logpath" || fail "PASS log holds the verdict"

# A tkt-gate command resolves cargo through cargo-slot and holds one slot.
setup_case cargo-slot
write_plan
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
printf 'cargo nextest run\n' >"$T/gate-cmd"
export CARGO_SLOTS=1 CARGO_SLOT_DIR="$T/cargo-slots" CARGO_SLOT_TEST_CORES=12
run_gate --expect-head "$H"
unset CARGO_SLOTS CARGO_SLOT_DIR CARGO_SLOT_TEST_CORES
[ "$RC" -eq 0 ] || fail "cargo-slot PASS exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
[ "$(cat "$T/cargo-held")" = "held=1" ] || fail "tkt-gate cargo did not hold a slot"
[ "$(cat "$T/cargo-threads")" = "threads=12" ] || fail "tkt-gate nextest did not get the per-slot thread cap"

# The gate exports the cargo found before installing its shim. A gate command
# that adds a markerless cargo wrapper later on PATH still reaches that cargo.
cat >"$T/cargo-slot-gate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${CARGO_SLOT_REAL-unset}" >"$T/cargo-slot-real"
shim="$(command -v cargo)"
mkdir -p "$T/markerless"
cat >"$T/markerless/cargo" <<'STUB'
#!/usr/bin/env bash
: >"$T/markerless-ran"
exit 88
STUB
chmod +x "$T/markerless/cargo"
PATH="$T/markerless:$PATH" "$shim" build
EOF
chmod +x "$T/cargo-slot-gate.sh"
setup_case cargo-slot-real
write_plan
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
printf 'bash %s\n' "$T/cargo-slot-gate.sh" >"$T/gate-cmd"
export CARGO_SLOTS=1 CARGO_SLOT_DIR="$T/cargo-slots"
run_gate --expect-head "$H"
unset CARGO_SLOTS CARGO_SLOT_DIR
[ "$RC" -eq 0 ] || fail "CARGO_SLOT_REAL integration exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
[ "$(cat "$T/cargo-slot-real")" = "$T/bin/cargo" ] ||
  fail "tkt-gate exported [$(cat "$T/cargo-slot-real")], want pre-shim cargo $T/bin/cargo"
[ "$(cat "$T/cargo-args")" = "args=build" ] || fail "configured real cargo did not receive the build"
[ ! -e "$T/markerless-ran" ] || fail "markerless cargo wrapper ran before CARGO_SLOT_REAL"

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

# --- rerun logs: two runs on the same head keep two logs ---
setup_case rerun-logs
write_plan
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
run_gate
[ "$RC" -eq 0 ] || fail "first rerun exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
log1="$(first_line)"; log1="${log1##*log=}"
run_gate
[ "$RC" -eq 0 ] || fail "second rerun exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
log2="$(first_line)"; log2="${log2##*log=}"
[ "$log1" != "$log2" ] || fail "reruns keep two logs"
[ -f "$log1" ] && [ -f "$log2" ] || fail "both rerun logs exist"

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

# --- PASS: a matching fence-grant Paths entry covers a changed file ---
setup_case fence-grant-pass
write_plan
cat >"$FW_RUN/fiber-517-fence-grant-1.md" <<'EOF'
Ticket: 517
Paths:
- evil.txt

Reads:
- read-only.txt
EOF
commit_file evil.txt "granted change"
push_branch
run_gate
[ "$RC" -eq 0 ] || fail "matching fence-grant Paths passes (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "matching fence-grant Paths"
[ -f "$T/gate-ran" ] || fail "matching fence-grant Paths runs the gate"

# --- PASS: an extensionless granted file (bin/<script>) is covered ---
setup_case fence-grant-extensionless
write_plan
cat >"$FW_RUN/fiber-517-fence-grant-1.md" <<'EOF'
Ticket: 517
Paths:
- Makefile
EOF
commit_file Makefile "granted extensionless change"
push_branch
run_gate
[ "$RC" -eq 0 ] || fail "extensionless fence-grant path passes (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "extensionless fence-grant path"

# --- OUTSIDE-PLAN: a grant file for another ticket does not cover this change ---
setup_case fence-grant-other-ticket
write_plan
cat >"$FW_RUN/fiber-518-fence-grant-1.md" <<'EOF'
Ticket: 518
Paths:
- evil.txt
EOF
commit_file evil.txt "other ticket grant"
push_branch
run_gate
[ "$RC" -eq 0 ] || fail "other-ticket fence-grant exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "other-ticket fence-grant"
grep -qx "OUTSIDE-PLAN n=1" <<<"$OUT" || fail "other-ticket grant reports outside-plan path"
grep -qx "evil.txt" <<<"$OUT" || fail "other-ticket fence-grant reports evil.txt"
[ "$(bash "$TKT_STATE" "$S" list outside_plan)" = evil.txt ] || fail "other-ticket path is recorded in state"
[ -f "$T/gate-ran" ] || fail "other-ticket fence-grant runs the gate"

# --- OUTSIDE-PLAN: a path listed only under a grant's Reads is not covered ---
setup_case fence-grant-reads
write_plan
cat >"$FW_RUN/fiber-517-fence-grant-1.md" <<'EOF'
Ticket: 517
Paths:
- another.txt

Reads:
- evil.txt
EOF
commit_file evil.txt "read-only change"
push_branch
run_gate
[ "$RC" -eq 0 ] || fail "Reads-only fence-grant exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "Reads-only fence-grant"
grep -qx "OUTSIDE-PLAN n=1" <<<"$OUT" || fail "Reads-only grant reports outside-plan path"
grep -qx "evil.txt" <<<"$OUT" || fail "Reads-only fence-grant reports evil.txt"
[ "$(bash "$TKT_STATE" "$S" list outside_plan)" = evil.txt ] || fail "Reads-only path is recorded in state"
[ -f "$T/gate-ran" ] || fail "Reads-only fence-grant runs the gate"

# --- OUTSIDE-PLAN: an uncovered file is reported and the gate runs ---
setup_case fence
write_plan
commit_file evil.txt "evil"
push_branch
run_gate
[ "$RC" -eq 0 ] || fail "OUTSIDE-PLAN exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "OUTSIDE-PLAN"
grep -qx "OUTSIDE-PLAN n=1" <<<"$OUT" || fail "outside-plan report counts the path"
grep -qx "evil.txt" <<<"$OUT" || fail "outside-plan report lists the path"
[ "$(bash "$TKT_STATE" "$S" list outside_plan)" = evil.txt ] || fail "outside-plan path is recorded in state"
[ -f "$T/gate-ran" ] || fail "OUTSIDE-PLAN runs the gate"

# --- OUTSIDE-PLAN lists every changed path without truncation ---
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
[ "$RC" -eq 0 ] || fail "many OUTSIDE-PLAN exits 0"
expect_verdict "TKT tkt-gate PASS head=* log=*" "many OUTSIDE-PLAN"
grep -qx "OUTSIDE-PLAN n=32" <<<"$OUT" || fail "many outside-plan report counts 32 paths"
[ "$(grep -c '^f[0-9]*\.txt$' <<<"$OUT")" -eq 32 ] || fail "many outside-plan report lists all 32 paths"
[ -f "$T/gate-ran" ] || fail "many outside-plan report runs the gate"

# --- OUTSIDE-PLAN lists all 30 paths without an extra count line ---
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
[ "$RC" -eq 0 ] || fail "thirty OUTSIDE-PLAN exits 0"
expect_verdict "TKT tkt-gate PASS head=* log=*" "thirty OUTSIDE-PLAN"
grep -qx "OUTSIDE-PLAN n=30" <<<"$OUT" || fail "thirty outside-plan report counts 30 paths"
[ "$(grep -c '^g[0-9]*\.txt$' <<<"$OUT")" -eq 30 ] || fail "thirty outside-plan report lists every path"
grep -q "more" <<<"$OUT" && fail "thirty outside-plan report has no rest line"
[ -f "$T/gate-ran" ] || fail "thirty outside-plan report runs the gate"

# --- OUTSIDE-PLAN: an unplanned rename is reported under its old path ---
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
[ "$RC" -eq 0 ] || fail "rename exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "rename"
grep -qx "OUTSIDE-PLAN n=1" <<<"$OUT" || fail "rename reports one outside-plan path"
grep -qx "base.txt" <<<"$OUT" || fail "rename report lists the old path"
[ "$(bash "$TKT_STATE" "$S" list outside_plan)" = base.txt ] || fail "rename records the old path"
[ -f "$T/gate-ran" ] || fail "rename runs the gate"

# --- stop-list: unplanned documentation, including root and nested paths ---
setup_case stop-docs
write_plan
mkdir -p "$WT/docs/guide/nested" "$WT/docs/adr" "$WT/docs/testing"
commit_file GLOSSARY.md "unplanned glossary"
commit_file docs/guide/nested/guide.md "unplanned nested docs"
commit_file docs/adr/decision.md "unplanned ADR"
commit_file docs/testing/x.md "nested testing guide"
push_branch
run_gate
[ "$RC" -eq 1 ] || fail "docs stop-list exits 1"
expect_verdict "TKT tkt-gate STOP-LIST n=4 log=*" "docs stop-list"
expect_stop_list_path GLOSSARY.md
expect_stop_list_path docs/guide/nested/guide.md
expect_stop_list_path docs/adr/decision.md
expect_stop_list_path docs/testing/x.md

# --- stop-list beats additive-only for an existing unplanned docs file ---
setup_case stop-additive-doc
mkdir -p "$CDIR/seed/docs"
printf '# Guide\n\nExisting guide.\n' >"$CDIR/seed/docs/guide.md"
git -C "$CDIR/seed" add docs/guide.md
git -C "$CDIR/seed" commit -qm "add guide on main"
git -C "$CDIR/seed" push -q origin main
git -C "$WT" fetch -q origin
git -C "$WT" reset -q --hard origin/main
write_plan
printf '\n## New section\n\nAdded guidance.\n' >>"$WT/docs/guide.md"
git -C "$WT" add docs/guide.md
git -C "$WT" commit -qm "append to unplanned guide"
push_branch
run_gate
[ "$RC" -eq 1 ] || fail "additive docs stop-list exits 1"
expect_verdict "TKT tkt-gate STOP-LIST n=1 log=*" "additive docs stop-list"
expect_stop_list_path docs/guide.md

# --- stop-list: unplanned GitHub workflows ---
setup_case stop-workflows
write_plan
mkdir -p "$WT/.github/workflows"
commit_file .github/workflows/ci.yml "unplanned workflow"
push_branch
run_gate
[ "$RC" -eq 1 ] || fail "workflow stop-list exits 1"
expect_verdict "TKT tkt-gate STOP-LIST n=1 log=*" "workflow stop-list"
expect_stop_list_path .github/workflows/ci.yml

# --- stop-list: scripts/check ---
setup_case stop-check-script
write_plan
mkdir -p "$WT/scripts"
commit_file scripts/check "unplanned check script"
push_branch
run_gate
[ "$RC" -eq 1 ] || fail "scripts/check stop-list exits 1"
expect_verdict "TKT tkt-gate STOP-LIST n=1 log=*" "scripts/check stop-list"
expect_stop_list_path scripts/check

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

# --- FAIL with a nextest block: the digest carries the failing test's block ---
setup_case fail-nextest
write_plan
commit_file base.txt "base changed"
push_branch
{
  for i in $(seq 1 30); do echo "        PASS [   0.010s] x::t$i"; done
  echo "        FAIL [   0.120s] x y::tests::broken"
  echo "stderr ─── y::tests::broken"
  echo "thread 'y::tests::broken' panicked at crates/x/tests/y.rs:335:9:"
  echo "expected 3 got 4"
  for i in $(seq 1 25); do echo "        PASS [   0.010s] x::u$i"; done
  echo "────────────"
  echo "     Summary [   0.200s] 56 tests run: 55 passed, 1 failed"
  echo "        FAIL [   0.120s] x y::tests::broken"
} >"$T/nextest.log"
printf "cat '%s'; exit 100\n" "$T/nextest.log" >"$T/gate-cmd"
run_gate
[ "$RC" -eq 1 ] || fail "nextest FAIL exits 1"
expect_verdict "TKT tkt-gate FAIL rc=100 log=*" "nextest FAIL"
grep -qx "stderr ─── y::tests::broken" <<<"$OUT" || fail "nextest FAIL digest holds the block's stderr line"
grep -qx "expected 3 got 4" <<<"$OUT" || fail "nextest FAIL digest holds the panic message line"

# --- a gate that runs zero tests fails even at exit 0 ---
setup_case zero-tests
write_plan
commit_file base.txt "base changed"
push_branch
printf 'gate-empty\n' >"$T/gate-cmd"
run_gate
[ "$RC" -eq 1 ] || fail "zero tests exits 1"
expect_verdict "TKT tkt-gate FAIL rc=4 log=*" "zero tests"
grep -q "no tests to run" <<<"$OUT" || fail "zero tests digest holds the marker"

# --- FAIL then echo: a gate that fails before its trailing echo still fails ---
setup_case fail-echo
write_plan
commit_file base.txt "base changed"
push_branch
printf 'false; echo gate-ended\n' >"$T/gate-cmd"
run_gate
[ "$RC" -eq 1 ] || fail "fail-echo exits 1"
expect_verdict "TKT tkt-gate FAIL rc=1 log=*" "fail-echo"
grep -q "gate-ended" <<<"$OUT" && fail "fail-echo never runs the trailing echo"

# --- an && chain that passes still passes ---
setup_case chain
write_plan
commit_file base.txt "base changed"
push_branch
printf 'true && echo chain-ok\n' >"$T/gate-cmd"
run_gate
[ "$RC" -eq 0 ] || fail "chain exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "chain"

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
grep -Eq "tkt-gate PASS head=$H checks-only$" "$CDIR/tkt.journal" || fail "--checks-only journals its distinct verdict"
! grep -Eq "tkt-gate PASS head=$H$" "$CDIR/tkt.journal" || fail "--checks-only does not journal a full-gate verdict"
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

# --- bare takeover plans and takeovers without a state gate are refused ---
setup_case takeover-bare
printf 'plan=takeover\ngate=gate-ok\n' >>"$S"
run_gate
[ "$RC" -eq 2 ] || fail "bare takeover exits 2 (rc=$RC)"
[ -z "$OUT" ] || fail "bare takeover writes no verdict: [$OUT]"
grep -Fxq "tkt-gate: invalid takeover plan value: expected 'takeover <pr-or-branch>'" "$CDIR/stderr.txt" \
  || fail "bare takeover refusal message changed: $(cat "$CDIR/stderr.txt")"

setup_case takeover-no-gate
printf 'plan=takeover #123\n' >>"$S"
run_gate
[ "$RC" -eq 2 ] || fail "takeover without gate exits 2 (rc=$RC)"
[ -z "$OUT" ] || fail "takeover without gate writes no verdict: [$OUT]"
grep -Fxq 'tkt-gate: takeover #123 has no gate command in state (key: gate)' "$CDIR/stderr.txt" \
  || fail "takeover without gate refusal message changed: $(cat "$CDIR/stderr.txt")"

# --- takeover state uses its stored fence and gate without a plan file ---
setup_case takeover
printf 'plan=takeover #123\ngate=gate-ok\nfence=base.txt\n' >>"$S"
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
run_gate --checks-only
[ "$RC" -eq 0 ] || fail "takeover checks-only exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=$H log=*" "takeover checks-only"
[ ! -f "$T/gate-ran" ] || fail "takeover checks-only runs no gate"

setup_case takeover-full
printf 'plan=takeover branch-123\ngate=gate-ok\nfence=base.txt\n' >>"$S"
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
run_gate
[ "$RC" -eq 0 ] || fail "takeover full gate exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=$H log=*" "takeover full gate"
[ -f "$T/gate-ran" ] || fail "takeover full gate did not run the state gate"

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

# Stub gh: answers `pr view <n> --json headRefOid` from the canned head file,
# as test/ship-pr.sh does.
gh() {
  echo "gh $*" >>"$T/gh.log"
  if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    case "$*" in
      *"--json body"*) cat "$T/pr-body" 2>/dev/null || printf ''; return 0 ;;
    esac
    h="$(cat "$T/pr-head")"
    case "$*" in
      *--jq*) printf '%s\n' "$h" ;;
      *) printf '{"headRefOid":"%s"}\n' "$h" ;;
    esac
    return 0
  fi
  if [ "$1" = "pr" ] && [ "$2" = "edit" ]; then
    if [ -f "$T/gh-edit-fail" ]; then
      echo "fake gh: edit failed" >&2
      return 1
    fi
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--body-file" ]; then cat "$a" >"$T/pr-body"; fi
      prev="$a"
    done
    return 0
  fi
  echo "fake gh: unsupported: gh $*" >&2
  return 2
}
export -f gh

# --- PR drift: state head, the worktree HEAD and the PR head agree ---
setup_case pr-ok
write_plan
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$H" || fail "set head"
bash "$TKT_STATE" "$S" set pr 518 || fail "set pr"
printf '%s\n' "$H" >"$T/pr-head"
run_gate
[ "$RC" -eq 0 ] || fail "pr match exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=$H log=*" "pr match"

# --- PR drift: a PR head the state never saw exits 3 naming every head ---
setup_case pr-drift
write_plan
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$H" || fail "set head"
bash "$TKT_STATE" "$S" set pr 518 || fail "set pr"
printf '0000000000000000000000000000000000000000\n' >"$T/pr-head"
run_gate
[ "$RC" -eq 3 ] || fail "pr drift exits 3"
grep -q "$H" "$CDIR/stderr.txt" || fail "pr drift names the worktree HEAD"
grep -q "0000000000000000000000000000000000000000" "$CDIR/stderr.txt" || fail "pr drift names the PR head"
[ ! -f "$T/gate-ran" ] || fail "pr drift runs no gate"

# --- a pushed worktree head descended from state and matching the PR is accepted ---
setup_case pr-pushed-head
write_plan
commit_file base.txt "state head"
push_branch
OLD_HEAD="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$OLD_HEAD" || fail "set old head"
bash "$TKT_STATE" "$S" set pr 518 || fail "set pr"
printf 'stray\n' >"$WT/stray.txt"
git -C "$WT" add stray.txt
git -C "$WT" commit -qm "pushed head"
push_branch
NEW_HEAD="$(git -C "$WT" rev-parse HEAD)"
printf '%s\n' "$NEW_HEAD" >"$T/pr-head"
run_gate
[ "$RC" -eq 0 ] || fail "pushed head drift reports outside-plan path (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "pushed head drift"
grep -qx "OUTSIDE-PLAN n=1" <<<"$OUT" || fail "pushed head drift reports one outside-plan path"
grep -qx "stray.txt" <<<"$OUT" || fail "pushed head drift reports stray.txt"
[ "$(bash "$TKT_STATE" "$S" list outside_plan)" = stray.txt ] || fail "pushed head drift records stray.txt"
[ -f "$T/gate-ran" ] || fail "pushed head drift runs the gate"
drift_line="$(grep 'accepted pushed head drift' "$CDIR/stderr.txt")"
case "$drift_line" in
  *"$OLD_HEAD"*"$NEW_HEAD"*) ;;
  *) fail "pushed head acceptance names the old and new heads: [$drift_line]" ;;
esac
[ "$(grep -c 'accepted pushed head drift' "$CDIR/stderr.txt")" -eq 1 ] || fail "pushed head acceptance prints one line"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$NEW_HEAD" ] || fail "pushed head acceptance updates state head before later checks"

# --- a non-ancestor state head remains drift ---
setup_case pr-non-ancestor
write_plan
BASE_HEAD="$(git -C "$WT" rev-parse HEAD)"
commit_file base.txt "state sibling"
OLD_HEAD="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" reset -q --hard "$BASE_HEAD"
commit_file base.txt "PR sibling"
push_branch
NEW_HEAD="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$OLD_HEAD" || fail "set sibling state head"
bash "$TKT_STATE" "$S" set pr 518 || fail "set pr"
printf '%s\n' "$NEW_HEAD" >"$T/pr-head"
run_gate
[ "$RC" -eq 3 ] || fail "non-ancestor head drift exits 3"
grep -q "$OLD_HEAD" "$CDIR/stderr.txt" || fail "non-ancestor drift names the stored head"
grep -q "$NEW_HEAD" "$CDIR/stderr.txt" || fail "non-ancestor drift names the PR/worktree head"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD_HEAD" ] || fail "non-ancestor drift leaves state head unchanged"
[ ! -f "$T/gate-ran" ] || fail "non-ancestor drift runs no gate"

# --- a worktree ahead of the PR head remains drift ---
setup_case pr-worktree-ahead
write_plan
commit_file base.txt "PR head"
push_branch
OLD_HEAD="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$OLD_HEAD" || fail "set PR head"
bash "$TKT_STATE" "$S" set pr 518 || fail "set pr"
printf '%s\n' "$OLD_HEAD" >"$T/pr-head"
commit_file base.txt "worktree ahead"
run_gate
[ "$RC" -eq 3 ] || fail "worktree ahead of PR drift exits 3"
grep -q "$OLD_HEAD" "$CDIR/stderr.txt" || fail "worktree-ahead drift names the stored/PR head"
grep -q "$(git -C "$WT" rev-parse HEAD)" "$CDIR/stderr.txt" || fail "worktree-ahead drift names the worktree HEAD"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$OLD_HEAD" ] || fail "worktree-ahead drift leaves state head unchanged"
[ ! -f "$T/gate-ran" ] || fail "worktree-ahead drift runs no gate"

# --- the PR lookup names the worktree's repo even from another directory ---
setup_case pr-repo
write_plan
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$H" || fail "set head"
bash "$TKT_STATE" "$S" set pr 518 || fail "set pr"
printf '%s\n' "$H" >"$T/pr-head"
: >"$T/gh.log"
mkdir -p "$T/elsewhere"
OUT="$(cd "$T/elsewhere" && bash "$GATE" "$S" 2>"$CDIR/stderr.txt")"; RC=$?
[ "$RC" -eq 0 ] || fail "pr repo exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=$H log=*" "pr repo"
origin_url="$(git -C "$WT" config --get remote.origin.url)"
grep -q -- "$origin_url" "$T/gh.log" || fail "pr lookup names the worktree's repo"

# --- a held lock exits 2 naming the pid, and runs no gate ---
setup_case locked
write_plan
mkdir "$S.phase"
printf '424242\n' >"$S.phase/pid"
run_gate
[ "$RC" -eq 2 ] || fail "a held lock exits 2"
grep -q "424242" "$CDIR/stderr.txt" || fail "a held lock names the pid"
[ ! -f "$T/gate-ran" ] || fail "a held lock runs no gate"
rm -rf "$S.phase"

# --- repo as owner/name still lands logs and scripts directly in run ---
setup_case repo-slash
write_plan
bash "$TKT_STATE" "$S" set repo owner/name || fail "set repo owner/name"
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
run_gate
[ "$RC" -eq 0 ] || fail "owner/name repo exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=$H log=*" "owner/name repo"
ls "$CDIR"/run/name-517-tkt-gate-*.log >/dev/null 2>&1 || fail "owner/name repo writes log directly in run"
set -- "$CDIR"/run/name-517-tkt-gate-*.sh
[ "$#" -eq 1 ] && [ -f "$1" ] || fail "owner/name repo writes gate script directly in run"
[ -z "$(find "$CDIR/run" -mindepth 1 -type d)" ] || fail "owner/name repo creates no subdirectory"

# --- two gate runs for one ticket write two gate scripts, each its own gate ---
setup_case two-gate-scripts
write_plan
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
run_gate --expect-head "$H"
[ "$RC" -eq 0 ] || fail "first gate run exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
printf 'gate-bad\n' >"$T/gate-cmd"
run_gate --expect-head "$H"
set -- "$CDIR"/run/switchyard-517-tkt-gate-*.sh
[ "$#" -eq 2 ] || fail "two gate runs write two gate scripts (found $#)"
passes=0
fails=0
for f in "$@"; do
  if (cd "$WT" && bash "$f") >/dev/null 2>&1; then passes=$((passes + 1)); else fails=$((fails + 1)); fi
done
[ "$passes" -eq 1 ] && [ "$fails" -eq 1 ] || fail "each gate script runs its own gate command (pass=$passes fail=$fails)"

# Add reg.txt (two lines) to main, then move the branch onto origin/main so the
# branch's own commits are the only change. Sets up the additive-fence cases.
add_main_file() {
  printf 'one\ntwo\n' >"$CDIR/seed/reg.txt"
  git -C "$CDIR/seed" add reg.txt
  git -C "$CDIR/seed" commit -qm reg
  git -C "$CDIR/seed" push -q origin main
  git -C "$WT" fetch -q origin && git -C "$WT" reset -q --hard origin/main
}

# --- additive: an appended line to a file on origin/main passes the fence ---
setup_case additive-append
write_plan
add_main_file
printf 'three\n' >>"$WT/reg.txt"
git -C "$WT" commit -qam "append reg"
push_branch
run_gate
[ "$RC" -eq 0 ] || fail "additive append exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "additive append"

# --- OUTSIDE-PLAN: a rewrite of an origin/main file is reported ---
setup_case additive-rewrite
write_plan
add_main_file
printf 'ONE\ntwo\n' >"$WT/reg.txt"
git -C "$WT" commit -qam "rewrite reg"
push_branch
run_gate
[ "$RC" -eq 0 ] || fail "outside-plan rewrite exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "outside-plan rewrite"
grep -qx "OUTSIDE-PLAN n=1" <<<"$OUT" || fail "outside-plan rewrite reports one path"
grep -qx "reg.txt" <<<"$OUT" || fail "outside-plan rewrite reports reg.txt"
[ -f "$T/gate-ran" ] || fail "outside-plan rewrite runs the gate"

# --- OUTSIDE-PLAN: a new file is reported ---
setup_case additive-new
write_plan
commit_file new.txt "new"
push_branch
run_gate
[ "$RC" -eq 0 ] || fail "outside-plan new file exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "outside-plan new file"
grep -qx "OUTSIDE-PLAN n=1" <<<"$OUT" || fail "outside-plan new file reports one path"
grep -qx "new.txt" <<<"$OUT" || fail "outside-plan new file reports new.txt"
[ -f "$T/gate-ran" ] || fail "outside-plan new file runs the gate"

# --- OUTSIDE-PLAN: a binary rewrite is reported ---
setup_case additive-binary
write_plan
printf '\0\1\2' >"$CDIR/seed/bin.dat"
git -C "$CDIR/seed" add bin.dat
git -C "$CDIR/seed" commit -qm bin
git -C "$CDIR/seed" push -q origin main
git -C "$WT" fetch -q origin && git -C "$WT" reset -q --hard origin/main
printf '\0\1\2\3' >"$WT/bin.dat"
git -C "$WT" commit -qam "change binary"
push_branch
run_gate
[ "$RC" -eq 0 ] || fail "outside-plan binary exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "outside-plan binary"
grep -qx "OUTSIDE-PLAN n=1" <<<"$OUT" || fail "outside-plan binary reports one path"
grep -qx "bin.dat" <<<"$OUT" || fail "outside-plan binary reports bin.dat"
[ -f "$T/gate-ran" ] || fail "outside-plan binary runs the gate"

# --- OUTSIDE-PLAN: the additive exception and covered files stay covered ---
setup_case additive-mix
write_plan
add_main_file
printf 'base changed\n' >"$WT/base.txt"
printf 'three\n' >>"$WT/reg.txt"
git -C "$WT" commit -qam "covered and additive"
commit_file new.txt "new"
push_branch
run_gate
[ "$RC" -eq 0 ] || fail "outside-plan mix exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "outside-plan mix"
grep -qx "OUTSIDE-PLAN n=1" <<<"$OUT" || fail "outside-plan mix reports only the uncovered path"
grep -qx "new.txt" <<<"$OUT" || fail "outside-plan mix reports new.txt"
grep -qx "reg.txt" <<<"$OUT" && fail "outside-plan mix omits additive reg.txt"
grep -qx "base.txt" <<<"$OUT" && fail "outside-plan mix omits covered base.txt"
[ "$(bash "$TKT_STATE" "$S" list outside_plan)" = new.txt ] || fail "outside-plan mix records only new.txt"
[ -f "$T/gate-ran" ] || fail "outside-plan mix runs the gate"

# --- a new file the plan marks new in Tasks is covered; an unmarked one is reported ---
setup_case new-marked
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `base.txt`

## Tasks

1. Add `made.txt` (new) with the table.
2. Touch `stray.txt` for the helper.

## Gate

`gate-ok`
EOF
printf 'plan=%s\n' "$CDIR/plan.md" >>"$S"
commit_file made.txt "made"
commit_file stray.txt "stray"
push_branch
run_gate
[ "$RC" -eq 0 ] || fail "new-marked exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "new-marked"
grep -qx "OUTSIDE-PLAN n=1" <<<"$OUT" || fail "new-marked reports one outside-plan path"
grep -qx "stray.txt" <<<"$OUT" || fail "new-marked reports stray.txt"
grep -qx "made.txt" <<<"$OUT" && fail "new-marked report drops made.txt"
[ "$(bash "$TKT_STATE" "$S" list outside_plan)" = stray.txt ] || fail "new-marked records only stray.txt"
[ -f "$T/gate-ran" ] || fail "new-marked runs the gate"

prepare_cargo_case() {
  setup_case "$1"
  cat >"$CDIR/seed/Cargo.toml" <<'EOF'
[package]
name = "fixture"
version = "0.1.0"
edition = "2021"

[workspace]
members = []

[dependencies]
alpha = "1"

[dev-dependencies]
fixture-test = "1"

[workspace.dependencies]
shared-fixture = "1"
EOF
  git -C "$CDIR/seed" add -- Cargo.toml
  git -C "$CDIR/seed" commit -qm "add Cargo manifest"
  git -C "$CDIR/seed" push -q origin main
  git -C "$WT" fetch -q origin && git -C "$WT" reset -q --hard origin/main
  write_plan
}

# --- stop-list: new dependencies in [dependencies] refuse ---
prepare_cargo_case new-dependency
cat >"$WT/Cargo.toml" <<'EOF'
[package]
name = "fixture"
version = "0.1.0"
edition = "2021"

[workspace]
members = []

[dependencies]
alpha = "1"
beta = "2"

[dev-dependencies]
fixture-test = "1"

[workspace.dependencies]
shared-fixture = "1"
EOF
git -C "$WT" add -- Cargo.toml
git -C "$WT" commit -qm "add runtime dependency"
push_branch
run_gate
[ "$RC" -eq 1 ] || fail "new [dependencies] entry exits 1"
expect_verdict "TKT tkt-gate STOP-LIST n=1 log=*" "new [dependencies] entry"
expect_stop_list_path Cargo.toml

# --- stop-list: new dependencies in [dev-dependencies] refuse ---
prepare_cargo_case new-dev-dependency
cat >"$WT/Cargo.toml" <<'EOF'
[package]
name = "fixture"
version = "0.1.0"
edition = "2021"

[workspace]
members = []

[dependencies]
alpha = "1"

[dev-dependencies]
fixture-test = "1"
new-test = "2"

[workspace.dependencies]
shared-fixture = "1"
EOF
git -C "$WT" add -- Cargo.toml
git -C "$WT" commit -qm "add dev dependency"
push_branch
run_gate
[ "$RC" -eq 1 ] || fail "new [dev-dependencies] entry exits 1"
expect_verdict "TKT tkt-gate STOP-LIST n=1 log=*" "new [dev-dependencies] entry"
expect_stop_list_path Cargo.toml

# --- stop-list: new dependencies in [workspace.dependencies] refuse ---
prepare_cargo_case new-workspace-dependency
cat >"$WT/Cargo.toml" <<'EOF'
[package]
name = "fixture"
version = "0.1.0"
edition = "2021"

[workspace]
members = []

[dependencies]
alpha = "1"

[dev-dependencies]
fixture-test = "1"

[workspace.dependencies]
shared-fixture = "1"
new-shared = "2"
EOF
git -C "$WT" add -- Cargo.toml
git -C "$WT" commit -qm "add workspace dependency"
push_branch
run_gate
[ "$RC" -eq 1 ] || fail "new [workspace.dependencies] entry exits 1"
expect_verdict "TKT tkt-gate STOP-LIST n=1 log=*" "new [workspace.dependencies] entry"
expect_stop_list_path Cargo.toml

expect_new_cargo_table() {
  local name="$1" table="$2" form="$3" dependency="$4"
  prepare_cargo_case "$name"
  cat >"$WT/Cargo.toml" <<'EOF'
[package]
name = "fixture"
version = "0.1.0"
edition = "2021"

[workspace]
members = []
EOF
  printf '[%s]\n' "$table" >>"$WT/Cargo.toml"
  if [ "$form" = entry ]; then
    printf '%s = "1"\n' "$dependency" >>"$WT/Cargo.toml"
  else
    printf 'version = "1"\n' >>"$WT/Cargo.toml"
  fi
  git -C "$WT" add -- Cargo.toml
  git -C "$WT" commit -qm "add $dependency dependency"
  push_branch
  run_gate
  [ "$RC" -eq 1 ] || fail "new dependency in [$table] exits 1"
  expect_verdict "TKT tkt-gate STOP-LIST n=1 log=*" "new dependency in [$table]"
  expect_stop_list_path Cargo.toml
}

# --- stop-list: each Cargo dependency table form detects a new crate ---
expect_new_cargo_table new-build-table build-dependencies entry build-tool
expect_new_cargo_table new-target-dependencies "target.'cfg(unix)'.dependencies" entry target-runtime
expect_new_cargo_table new-target-dev-dependencies "target.'cfg(unix)'.dev-dependencies" entry target-test
expect_new_cargo_table new-target-build-dependencies "target.'cfg(unix)'.build-dependencies" entry target-build-tool
expect_new_cargo_table new-dependency-header dependencies.direct-header header direct-header
expect_new_cargo_table new-dev-dependency-header dev-dependencies.direct-dev-header header direct-dev-header
expect_new_cargo_table new-build-dependency-header build-dependencies.direct-build-header header direct-build-header
expect_new_cargo_table new-workspace-dependency-header workspace.dependencies.direct-workspace-header header direct-workspace-header
expect_new_cargo_table new-target-dependency-header "target.'cfg(unix)'.dependencies.target-header" header target-header
expect_new_cargo_table new-target-dev-dependency-header "target.'cfg(unix)'.dev-dependencies.target-dev-header" header target-dev-header
expect_new_cargo_table new-target-build-dependency-header "target.'cfg(unix)'.build-dependencies.target-build-header" header target-build-header

# --- a covered Cargo.toml still cannot add a dependency ---
prepare_cargo_case covered-new-dependency
cat >"$CDIR/plan.md" <<'EOF'
# Plan

## Files

- `base.txt`
- `Cargo.toml`

## Gate

`gate-ok`
EOF
cat >"$WT/Cargo.toml" <<'EOF'
[package]
name = "fixture"
version = "0.1.0"
edition = "2021"

[dependencies]
covered-new = "1"
EOF
git -C "$WT" add -- Cargo.toml
git -C "$WT" commit -qm "add dependency to covered manifest"
push_branch
run_gate
[ "$RC" -eq 1 ] || fail "covered Cargo.toml new dependency exits 1"
expect_verdict "TKT tkt-gate STOP-LIST n=1 log=*" "covered Cargo.toml new dependency"
expect_stop_list_path Cargo.toml

# --- a version bump of an existing dependency is not a stop-list change ---
prepare_cargo_case dependency-version-bump
cat >"$WT/Cargo.toml" <<'EOF'
[package]
name = "fixture"
version = "0.1.0"
edition = "2021"

[workspace]
members = []

[dependencies]
alpha = "2"

[dev-dependencies]
fixture-test = "1"

[workspace.dependencies]
shared-fixture = "1"
EOF
git -C "$WT" add -- Cargo.toml
git -C "$WT" commit -qm "bump dependency version"
push_branch
run_gate
[ "$RC" -eq 0 ] || fail "dependency version bump exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "dependency version bump"
grep -qx "OUTSIDE-PLAN n=1" <<<"$OUT" || fail "dependency version bump is reported as ordinary outside-plan work"
grep -qx "Cargo.toml" <<<"$OUT" || fail "dependency version bump lists Cargo.toml"
[ "$(bash "$TKT_STATE" "$S" list outside_plan)" = Cargo.toml ] || fail "version bump is recorded outside-plan"
[ -f "$T/gate-ran" ] || fail "dependency version bump runs the gate"

# --- PASS writes a Local gate line directly above Implemented by: ---
setup_case gate-body
write_plan
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$H" || fail "set head"
bash "$TKT_STATE" "$S" set pr 518 || fail "set pr"
printf '%s\n' "$H" >"$T/pr-head"
printf 'Title\n\nSome text.\nImplemented by: m/a\nCo-authored with Claude Code.\n' >"$T/pr-body"
: >"$T/gh.log"
run_gate
[ "$RC" -eq 0 ] || fail "gate body exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=$H log=*" "gate body"
grep -qx "Local gate: pass at $H (gate-ok)" "$T/pr-body" || fail "gate body writes the Local gate line: [$(cat "$T/pr-body")]"
[ "$(grep -c '^Local gate:' "$T/pr-body")" -eq 1 ] || fail "gate body writes one Local gate line"
impl_line="$(grep -n '^Implemented by:' "$T/pr-body" | head -n 1 | cut -d: -f1)"
gate_line="$(grep -n '^Local gate:' "$T/pr-body" | head -n 1 | cut -d: -f1)"
[ "$gate_line" -eq "$((impl_line - 1))" ] || fail "gate body puts the line above Implemented by (gate=$gate_line impl=$impl_line)"

# --- a second PASS replaces the earlier Local gate line ---
{ printf 'Local gate: pass at 0000000000000000000000000000000000000000 (old-cmd)\n'; cat "$T/pr-body"; } >"$T/pr-body.tmp" && mv "$T/pr-body.tmp" "$T/pr-body"
run_gate
[ "$RC" -eq 0 ] || fail "gate body replace exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
[ "$(grep -c '^Local gate:' "$T/pr-body")" -eq 1 ] || fail "second PASS keeps one Local gate line: [$(cat "$T/pr-body")]"
grep -qx "Local gate: pass at $H (gate-ok)" "$T/pr-body" || fail "second PASS replaces the sha"
grep -q "0000000000000000000000000000000000000000" "$T/pr-body" && fail "second PASS drops the old sha"

# --- --from-job journals a delegate's full-gate PASS for tkt-ship ---
setup_from_job_case from-job-pass
bash "$TKT_STATE" "$S" set reviewed 1111111111111111111111111111111111111111 || fail "from-job set reviewed"
plant_job_record job-from-job present 0 "$H" false
journal_job_gate job-from-job gate-ok
run_gate --from-job job-from-job
[ "$RC" -eq 0 ] || fail "--from-job PASS exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=$H log=*" "--from-job PASS"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$H" ] || fail "--from-job PASS sets state head"
grep -q " tkt-gate from-job id=job-from-job head=$H$" "$CDIR/tkt.journal" || fail "--from-job records its source"
[ "$(tail -n 2 "$CDIR/tkt.journal" | head -n 1 | cut -d' ' -f2-)" = "tkt-gate from-job id=job-from-job head=$H" ] || fail "source line immediately precedes PASS"
[ "$(tail -n 1 "$CDIR/tkt.journal" | cut -d' ' -f2-)" = "tkt-gate PASS head=$H" ] || fail "--from-job keeps the plain PASS journal line"
OUT="$(bash "$SHIP" "$S" 2>"$CDIR/ship-stderr.txt")"; RC=$?
[ "$RC" -eq 0 ] || fail "tkt-ship accepts --from-job PASS (rc=$RC): $(cat "$CDIR/ship-stderr.txt")"
case "$(head -n 1 <<<"$OUT")" in "TKT tkt-ship MERGED "*) ;; *) fail "tkt-ship passes GATE-STALE check: $(head -n 1 <<<"$OUT")" ;; esac
! grep -q 'GATE-STALE' <<<"$OUT" || fail "tkt-ship does not report GATE-STALE after --from-job PASS"

# --- --from-job refuses a model-reported gate result without journaling ---
setup_from_job_case from-job-model-reported
plant_job_record job-model none none "$H" false
journal_job_gate job-model gate-ok
expect_from_job_refusal job-model 'delegate gateResult'

# --- --from-job rejects a string-valued exit code ---
setup_from_job_case from-job-noninteger
plant_job_record job-noninteger present 0 "$H" false
jq '.result.gateResult.exitCode = "0"' "$DELEGATE_JOBS_DIR/job-noninteger.json" >"$CDIR/record.tmp" \
  && mv "$CDIR/record.tmp" "$DELEGATE_JOBS_DIR/job-noninteger.json" || fail "make exitCode non-integer"
journal_job_gate job-noninteger gate-ok
expect_from_job_refusal job-noninteger 'delegate gateResult'

# --- --from-job requires the gate command to match the current plan exactly ---
setup_from_job_case from-job-command
plant_job_record job-command present 0 "$H" false
journal_job_gate job-command 'gate-wrong'
expect_from_job_refusal job-command 'gate command'

# --- --from-job refuses when the current ticket environment differs ---
setup_from_job_case from-job-env
bash "$TKT_STATE" "$S" set env 'FOO=dispatch' || fail "set original from-job env"
plant_job_record job-env-old present 0 "$H" false
jq '.supersededBy = "job-env"' "$DELEGATE_JOBS_DIR/job-env-old.json" >"$CDIR/record.tmp" \
  && mv "$CDIR/record.tmp" "$DELEGATE_JOBS_DIR/job-env-old.json" || fail "link resumed job"
plant_job_record job-env present 0 "$H" false
journal_job_gate job-env-old gate-ok
journal_job_gate job-env gate-ok
bash "$TKT_STATE" "$S" set env 'FOO=changed' || fail "change from-job env"
expect_from_job_refusal job-env-old 'gate command/environment'

# --- --from-job passes with a long ticket environment encoded on one line ---
setup_from_job_case from-job-long-env
long_ticket_env='FOO=LZSQks5W03TsZ2IkZYmBQaX5sL4gmbQpD61j3JP6ZsYvVv1VVwhwX8qgF6LkcNbnEbDQzAyrfRnbJRjC'
bash "$TKT_STATE" "$S" set env "$long_ticket_env" || fail "set long from-job env"
plant_job_record job-long-env present 0 "$H" false
journal_job_gate job-long-env gate-ok
encoded_env="$(printf '%s' "$long_ticket_env" | jq -Rrs '@base64')"
case "$encoded_env" in *n*) ;; *) fail "long env fixture encoding contains n" ;; esac
[ "${#encoded_env}" -gt 76 ] || fail "long env fixture encoding exceeds base64 wrap width"
run_gate --from-job job-long-env
[ "$RC" -eq 0 ] || fail "--from-job passes long env (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=$H log=*" "--from-job long env"

# --- --from-job refuses a nonzero delegate gate exit ---
setup_from_job_case from-job-nonzero
plant_job_record job-nonzero present 3 "$H" false
journal_job_gate job-nonzero gate-ok
expect_from_job_refusal job-nonzero 'gate exit code'

# --- --from-job refuses when the record's head differs from the worktree ---
setup_from_job_case from-job-head
plant_job_record job-head present 0 0000000000000000000000000000000000000000 false
journal_job_gate job-head gate-ok
expect_from_job_refusal job-head 'head check'

# --- --from-job also requires the PR head to match the delegate head ---
setup_from_job_case from-job-pr-head
plant_job_record job-pr-head present 0 "$H" false
journal_job_gate job-pr-head gate-ok
printf '%040d\n' 1 >"$T/pr-head"
expect_from_job_refusal job-pr-head 'head check'

# --- --from-job requires changeSet.dirtyAfter=false ---
setup_from_job_case from-job-dirty-after
plant_job_record job-dirty-after present 0 "$H" true
journal_job_gate job-dirty-after gate-ok
expect_from_job_refusal job-dirty-after 'dirty tree'

# --- --from-job refuses when dirtyAfter is missing ---
setup_from_job_case from-job-missing-dirty-after
plant_job_record job-missing-dirty-after present 0 "$H" false
jq 'del(.result.changeSet.dirtyAfter)' "$DELEGATE_JOBS_DIR/job-missing-dirty-after.json" >"$CDIR/record.tmp" \
  && mv "$CDIR/record.tmp" "$DELEGATE_JOBS_DIR/job-missing-dirty-after.json" || fail "remove dirtyAfter"
journal_job_gate job-missing-dirty-after gate-ok
expect_from_job_refusal job-missing-dirty-after 'dirty tree'

# --- --from-job requires the worktree to be clean now ---
setup_from_job_case from-job-dirty-now
plant_job_record job-dirty-now present 0 "$H" false
journal_job_gate job-dirty-now gate-ok
printf 'uncommitted\n' >"$WT/untracked.txt"
expect_from_job_refusal job-dirty-now 'dirty tree'

# --- --from-job requires the record to capture headAfter ---
setup_from_job_case from-job-missing-head
plant_job_record job-missing-head present 0 "$H" false
jq 'del(.result.changeSet.headAfter)' "$DELEGATE_JOBS_DIR/job-missing-head.json" >"$CDIR/record.tmp" \
  && mv "$CDIR/record.tmp" "$DELEGATE_JOBS_DIR/job-missing-head.json" || fail "remove headAfter"
journal_job_gate job-missing-head gate-ok
expect_from_job_refusal job-missing-head 'head check'

# --- --from-job refuses a matching job when the plan Files fence is exceeded ---
setup_from_job_case from-job-fence
commit_file outside.txt "outside"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
printf '%s\n' "$H" >"$T/pr-head"
plant_job_record job-fence present 0 "$H" false
journal_job_gate job-fence gate-ok
run_gate --from-job job-fence
[ "$RC" -eq 0 ] || fail "--from-job outside-plan report exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=* log=*" "--from-job outside-plan report"
grep -qx "OUTSIDE-PLAN n=1" <<<"$OUT" || fail "--from-job reports one outside-plan path"
grep -qx "outside.txt" <<<"$OUT" || fail "--from-job reports outside.txt"
[ "$(bash "$TKT_STATE" "$S" list outside_plan)" = outside.txt ] || fail "--from-job records outside.txt"
grep -q 'tkt-gate PASS head=' "$CDIR/tkt.journal" || fail "--from-job outside-plan report journals PASS"
! [ -f "$T/gate-ran" ] || fail "--from-job validates stored gate evidence without rerunning the gate"

# --- --from-job refuses an unpushed tip even when the delegate head matches ---
setup_from_job_case from-job-unpushed
commit_file base.txt "unpushed change"
H="$(git -C "$WT" rev-parse HEAD)"
printf '%s\n' "$H" >"$T/pr-head"
plant_job_record job-unpushed present 0 "$H" false
journal_job_gate job-unpushed gate-ok
run_gate --from-job job-unpushed
[ "$RC" -eq 1 ] || fail "--from-job unpushed tip refusal exits 1"
expect_verdict "TKT tkt-gate TIP * log=*" "--from-job unpushed tip"
! grep -q 'tkt-gate PASS head=' "$CDIR/tkt.journal" || fail "--from-job unpushed tip refusal journals no PASS"

# --- newest resumed job's own explicit gate line overrides the dispatch line ---
setup_from_job_case from-job-resumed-explicit-gate
plant_job_record old-9 present 0 "$H" false
jq '.supersededBy = "stub-1"' "$DELEGATE_JOBS_DIR/old-9.json" >"$CDIR/record.tmp" \
  && mv "$CDIR/record.tmp" "$DELEGATE_JOBS_DIR/old-9.json" || fail "link resumed explicit-gate job"
plant_job_record stub-1 present 0 "$H" false
journal_job_gate old-9 gate-ok
journal_job_gate stub-1 gate-x
expect_from_job_refusal old-9 'gate command/environment'

# --- a newest old-format journal line cannot fall back to an older valid line ---
setup_from_job_case from-job-old-format-newest
plant_job_record old-9 present 0 "$H" false
jq '.supersededBy = "stub-1"' "$DELEGATE_JOBS_DIR/old-9.json" >"$CDIR/record.tmp" \
  && mv "$CDIR/record.tmp" "$DELEGATE_JOBS_DIR/old-9.json" || fail "link old-format resumed job"
plant_job_record stub-1 present 0 "$H" false
journal_job_gate old-9 gate-ok
bash "$TKT_STATE" "$S" journal 'tkt-job gate slot=fix1 job=stub-1 cmd=gate-ok env64=' || fail "journal old-format newest line"
cp "$CDIR/tkt.journal" "$CDIR/journal-before"
expect_from_job_refusal old-9 'gate command/environment'

# --- --from-job journals the newest job in a superseded chain ---
setup_from_job_case from-job-superseded
plant_job_record job-old present 0 "$H" false
jq '.supersededBy = "job-new"' "$DELEGATE_JOBS_DIR/job-old.json" >"$CDIR/record.tmp" \
  && mv "$CDIR/record.tmp" "$DELEGATE_JOBS_DIR/job-old.json" || fail "link superseded job"
plant_job_record job-new present 0 "$H" false
journal_job_gate job-new gate-ok
run_gate --from-job job-old
[ "$RC" -eq 0 ] || fail "--from-job follows supersededBy (rc=$RC): $(cat "$CDIR/stderr.txt")"
grep -q " tkt-gate from-job id=job-new head=$H$" "$CDIR/tkt.journal" || fail "--from-job marks the newest job id"
[ "$(tail -n 1 "$CDIR/tkt.journal" | cut -d' ' -f2-)" = "tkt-gate PASS head=$H" ] || fail "superseded job retains the plain PASS line"

# --- PASS with only body_has set lands above the attribution, which stays last ---
setup_case gate-body-has
write_plan
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set head "$H" || fail "set head"
bash "$TKT_STATE" "$S" set pr 518 || fail "set pr"
bash "$TKT_STATE" "$S" add body_has "Co-authored-by: Claude" || fail "add body_has"
printf '%s\n' "$H" >"$T/pr-head"
printf 'Title\n\nSome text.\nCo-authored-by: Claude <noreply@example.com>\n' >"$T/pr-body"
run_gate
[ "$RC" -eq 0 ] || fail "gate body-has exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=$H log=*" "gate body-has"
grep -qx "Local gate: pass at $H (gate-ok)" "$T/pr-body" || fail "gate body-has writes the Local gate line: [$(cat "$T/pr-body")]"
[ "$(grep -c '^Local gate:' "$T/pr-body")" -eq 1 ] || fail "gate body-has writes one Local gate line"
[ "$(tail -n 1 "$T/pr-body")" = "Co-authored-by: Claude <noreply@example.com>" ] || fail "gate body-has keeps the attribution last: [$(cat "$T/pr-body")]"
gate_line="$(grep -n '^Local gate:' "$T/pr-body" | head -n 1 | cut -d: -f1)"
attr_line="$(grep -n '^Co-authored' "$T/pr-body" | head -n 1 | cut -d: -f1)"
[ "$gate_line" -eq "$((attr_line - 1))" ] || fail "gate body-has puts the line above the attribution (gate=$gate_line attr=$attr_line)"

# --- FAIL leaves the PR body alone ---
setup_case gate-body-fail
write_plan
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set pr 518 || fail "set pr"
printf '%s\n' "$H" >"$T/pr-head"
printf 'Title\n\nImplemented by: m/a\n' >"$T/pr-body"
cp "$T/pr-body" "$T/pr-body.before"
printf 'gate-bad\n' >"$T/gate-cmd"
run_gate
[ "$RC" -eq 1 ] || fail "gate body FAIL exits 1"
expect_verdict "TKT tkt-gate FAIL rc=3 log=*" "gate body FAIL"
cmp "$T/pr-body.before" "$T/pr-body" || fail "FAIL leaves the body alone"

# --- a body-write failure only warns: PASS still exits 0 ---
setup_case gate-body-writefail
write_plan
commit_file base.txt "base changed"
push_branch
H="$(git -C "$WT" rev-parse HEAD)"
bash "$TKT_STATE" "$S" set pr 518 || fail "set pr"
printf '%s\n' "$H" >"$T/pr-head"
printf 'Title\n' >"$T/pr-body"
: >"$T/gh-edit-fail"
run_gate
[ "$RC" -eq 0 ] || fail "write-fail exits 0 (rc=$RC): $(cat "$CDIR/stderr.txt")"
expect_verdict "TKT tkt-gate PASS head=$H log=*" "write-fail"
grep -qi "warning" "$CDIR/stderr.txt" || fail "write-fail warns: [$(cat "$CDIR/stderr.txt")]"
[ "$(bash "$TKT_STATE" "$S" get head)" = "$H" ] || fail "write-fail still sets state head"
rm -f "$T/gh-edit-fail"

echo "tkt-gate: all cases passed"

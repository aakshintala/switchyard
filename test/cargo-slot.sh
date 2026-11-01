#!/usr/bin/env bash
# Tests for bin/cargo-slot, against a fake real cargo in a mktemp -d fixture
# (never ~/.cache/agents). Handshakes use FIFOs: a blocking open or read
# waits for the event it needs, and the watchdog bounds the whole file. A
# waiter's stderr goes straight to the R/err FIFO, with no pipe and no process
# substitution: a regular file cannot block a reader, so the FIFO is what makes
# the readiness read wait for the line with no deadline. A waiter that exits
# first gives that read EOF. Absence checks drain a reaped waiter's FIFO to EOF
# and compare every line read. No test sleeps or polls: each wait is a blocking
# read or a wait on a pid, and the watchdog bounds a hang. The dead-holder
# tests pause the shim between its two dead-pid reads through the test-only
# CARGO_SLOT_RECHECK_FIFO hook in bin/cargo-slot.
# Not shown: that the waiting line prints once across several rescans. A shim
# that printed on every rescan passes, because the suite releases a holder
# right after the first line. Showing it would need a timed wait across rescans,
# which this suite does not have.
# The suite proves only that a waiter takes a slot after a release, which needs
# at least one rescan after the waiting line.
set -uo pipefail

# The suite re-execs itself into its own process group, so the watchdog can
# send TERM to every fake and shim at once. test/run uses no job control.
if [ "${1:-}" != "--inner" ]; then
  ( set -m; bash "$0" --inner & wait $! )
  exit $?
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIM="$SCRIPT_DIR/../bin/cargo-slot"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-cargo-slot.XXXXXX")"
PIDS=()
WD_PID=""

# Watchdog: after 90 s it TERMs the whole group. A passing run never gets
# there, because cleanup kills the watcher and its sleep first.
( sleep 90 & echo $! >"$T/wd.pid"; wait $!; kill -TERM 0 ) &
WD_PID=$!

# Cleanup order: the watcher, then its sleep, then the group TERM for the
# fakes and shims. The test shell ignores that TERM, so it survives to assert
# that every recorded pid is gone. The status is kept, so a pass exits 0.
cleanup() {
  local st=$? p
  trap - EXIT
  kill "$WD_PID" 2>/dev/null
  [ -f "$T/wd.pid" ] && kill "$(cat "$T/wd.pid")" 2>/dev/null
  trap '' TERM
  kill -TERM 0 2>/dev/null
  for p in ${PIDS[@]+"${PIDS[@]}"}; do
    wait "$p" 2>/dev/null
    if kill -0 "$p" 2>/dev/null; then
      echo "FAIL: pid $p alive after cleanup" >&2
      st=1
    fi
  done
  chmod -R u+rwx "$T" 2>/dev/null
  rm -rf "$T"
  exit "$st"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

mkdir -p "$T/home" "$T/shims" "$T/real" "$T/py" "$T/runs"
PY="$(command -v python3)" || fail "python3 not on PATH"
ln -s "$PY" "$T/py/python3"
ln -s "$SHIM" "$T/shims/cargo"

# Fake real cargo. It logs its start, argc, argv and CARGO_SLOT_HELD into
# $FAKE_DIR. FAKE_READ_STDIN=1 reads one stdin line. FAKE_HOLD=1 writes its
# pid to $FAKE_DIR/up and blocks until $FAKE_DIR/go is written. FAKE_DAEMON=1
# starts a background child blocked on daemon.go; FAKE_SIGNAL sends the named
# signal to the stub itself.
cat >"$T/real/cargo" <<'FAKE'
#!/usr/bin/env bash
printf 'started\n' >"$FAKE_DIR/started"
{
  printf 'argc=%s\n' "$#"
  for a in "$@"; do printf '<%s>\n' "$a"; done
} >"$FAKE_DIR/args"
printf 'held=%s\n' "${CARGO_SLOT_HELD-unset}" >"$FAKE_DIR/held"
if [ "${FAKE_READ_STDIN:-0}" = 1 ]; then
  IFS= read -r line || true
  printf 'stdin=%s\n' "${line-}" >"$FAKE_DIR/stdin"
fi
if [ "${FAKE_DAEMON:-0}" = 1 ]; then
  ( IFS= read -r _ <"$FAKE_DIR/daemon.go" ) &
  printf '%s\n' "$!" >"$FAKE_DIR/daemon.pid"
fi
if [ "${FAKE_HOLD:-0}" = 1 ]; then
  printf '%s\n' "$$" >"$FAKE_DIR/up"
  IFS= read -r _ <"$FAKE_DIR/go"
fi
if [ -n "${FAKE_SIGNAL:-}" ]; then
  kill -s "$FAKE_SIGNAL" "$$"
fi
exit "${FAKE_EXIT:-0}"
FAKE
chmod 755 "$T/real/cargo"

# Fake real cargo that reports SIGPIPE and SIGXFSZ dispositions on entry.
# undef is the default; a python3 fake would always see IGNORE.
mkdir -p "$T/perlreal"
cat >"$T/perlreal/cargo" <<'PERL'
#!/usr/bin/env perl
open(my $fh, '>', "$ENV{FAKE_DIR}/sig") or die "sig: $!";
print $fh "PIPE=", (defined $SIG{PIPE} ? $SIG{PIPE} : 'undef'),
  " XFSZ=", (defined $SIG{XFSZ} ? $SIG{XFSZ} : 'undef'), "\n";
close $fh;
exit 0;
PERL
chmod 755 "$T/perlreal/cargo"

BASEPATH="$T/shims:$T/real:$T/py:/usr/bin:/bin"

# stage DIR: a run directory with the fake's up and go FIFOs and a stderr FIFO.
stage() {
  mkdir -p "$1" && mkfifo "$1/up" "$1/go" "$1/err" || fail "cannot stage $1"
}

# new_run NAME: a fresh run directory; sets R.
new_run() {
  R="$T/runs/$1"
  stage "$R"
}

# shim_cmd R [VAR=VAL ...] -- ARGS: sets CMD to the installed shim run as
# `cargo` in a clean environment. Later VAR=VAL words override the defaults
# (PATH too).
shim_cmd() {
  local r="$1" envs=()
  shift
  while [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  CMD=(env -i PATH="$BASEPATH" HOME="$T/home" FAKE_DIR="$r"
    ${envs[@]+"${envs[@]}"} "$T/shims/cargo" "$@")
}

# cargo_as: the same arguments as shim_cmd, run in the foreground.
cargo_as() {
  shim_cmd "$@"
  "${CMD[@]}"
}

# spawn R [VAR=VAL ...] -- ARGS: the shim in the background, stderr straight to
# the FIFO R/err (stage made it). The background open of the write end and the
# open of fd 9 for reading unblock each other. Fd 9 holds no write end, so its
# reads reach EOF once the child has exited. Sets SPAWNED to its pid; after exec
# that is the fake's pid. The pid is recorded for cleanup. ERR_SEEN collects the
# stderr lines fd 9 yields.
spawn() {
  local r="$1"
  shift
  shim_cmd "$r" "$@"
  "${CMD[@]}" 2>"$r/err" &
  SPAWNED=$!
  PIDS+=("$SPAWNED")
  exec 9<"$r/err"
  ERR_SEEN=""
}

# spawn_quiet R [VAR=VAL ...] -- ARGS: the shim in the background with stderr
# in R/hold.err, for a holder that never waits. Sets SPAWNED.
spawn_quiet() {
  local r="$1"
  shift
  shim_cmd "$r" "$@"
  "${CMD[@]}" 2>"$r/hold.err" &
  SPAWNED=$!
  PIDS+=("$SPAWNED")
}

expect_build_args() {
  [ "$(cat "$1/args")" = "$(printf 'argc=3\n<build>\n<a b>\n<>')" ] ||
    fail "args reached the fake as: $(cat "$1/args")"
}

expect_no_slot_dir() {
  [ ! -e "${1:-$T/slots}" ] || fail "pass-through created the slot directory"
}

# expect_err_line TEXT: the waiter's next stderr line (fd 9) is TEXT. No
# deadline: the watchdog bounds a hang, and a waiter that exits first gives EOF.
expect_err_line() {
  local line
  IFS= read -r -u 9 line || fail "no stderr line, want [$1]"
  ERR_SEEN+="$line"$'\n'
  [ "$line" = "$1" ] || fail "stderr line [$line], want [$1]"
}

# expect_waiter_log R: the waiter in R has been reaped. Draining fd 9 to EOF
# collects any line not yet read; the collected lines must be exactly one
# waiting line. R is named for the callers' readability; the lines come from fd 9.
expect_waiter_log() {
  local rest
  rest="$(cat <&9)"
  [ -z "$rest" ] || ERR_SEEN+="$rest"$'\n'
  [ "$ERR_SEEN" = $'cargo-slot: waiting\n' ] ||
    fail "waiter stderr is [$ERR_SEEN], want one waiting line"
}

# hold_slot R SLOTS N: a holder that takes one of the N slots in SLOTS. It
# writes its pid to R/up and blocks until R/go is written. Sets HOLD_PID.
hold_slot() {
  spawn_quiet "$1" CARGO_SLOTS="$3" CARGO_SLOT_DIR="$2" FAKE_HOLD=1 -- build
  HOLD_PID=$SPAWNED
  IFS= read -r _ <"$1/up"
}

# release R: the holder in R reads its go line and exits 0.
release() {
  printf 'go\n' >"$1/go"
}

# Task 1: skeleton, real-cargo lookup, pass-through.

new_run passthrough-unset
cargo_as "$R" FAKE_EXIT=7 CARGO_SLOT_DIR="$T/slots" -- build "a b" ""
rc=$?
[ "$rc" = 7 ] || fail "unset CARGO_SLOTS: exit $rc, want 7 from the fake"
expect_build_args "$R"
expect_no_slot_dir

for v in "CARGO_SLOTS=" "CARGO_SLOTS=0"; do
  new_run "passthrough-$v"
  cargo_as "$R" "$v" FAKE_EXIT=7 CARGO_SLOT_DIR="$T/slots" -- build "a b" ""
  rc=$?
  [ "$rc" = 7 ] || fail "$v: exit $rc, want 7 from the fake"
  expect_build_args "$R"
  expect_no_slot_dir
done

# Planted cargo files in the working directory and in tools/. Each one records
# its own name in FAKE_DIR and exits 0, so a test shows which one ran.
mkdir -p "$T/cwd/tools"
printf '#!/bin/sh\n: >"$FAKE_DIR/cwd-ran"\n' >"$T/cwd/cargo"
printf '#!/bin/sh\n: >"$FAKE_DIR/tools-ran"\n' >"$T/cwd/tools/cargo"
chmod 755 "$T/cwd/cargo" "$T/cwd/tools/cargo"

new_run nocargo
env -i PATH="$T/shims:$T/py" HOME="$T/home" FAKE_DIR="$R" \
  "$T/shims/cargo" build >"$R/out" 2>"$R/shim.err"
rc=$?
[ "$rc" = 127 ] || fail "no real cargo on PATH: exit $rc, want 127"
grep -q 'cargo-slot:' "$R/shim.err" || fail "no real cargo: no cargo-slot: line on stderr"

# An unset PATH searches nothing, not even the working directory.
new_run pathunset
( cd "$T/cwd" && env -u PATH FAKE_DIR="$R" "$T/py/python3" "$SHIM" build ) \
  >"$R/out" 2>"$R/shim.err"
rc=$?
[ "$rc" = 127 ] || fail "PATH unset: exit $rc, want 127"
grep -q 'cargo-slot:' "$R/shim.err" || fail "PATH unset: no cargo-slot: line on stderr"
[ ! -e "$R/cwd-ran" ] || fail "PATH unset searched the working directory"

# A symlink to the shim in a second PATH directory, and a byte copy of it,
# are both skipped by the marker; the real fake runs.
mkdir -p "$T/shims2" "$T/copies"
ln -s "$SHIM" "$T/shims2/cargo"
cp "$SHIM" "$T/copies/cargo" && chmod 755 "$T/copies/cargo" || fail "cannot stage copy"
new_run shim-links
cargo_as "$R" PATH="$T/shims:$T/shims2:$T/copies:$T/real:$T/py:/usr/bin:/bin" \
  FAKE_EXIT=0 -- build "a b" ""
rc=$?
[ "$rc" = 0 ] || fail "symlink and copy of the shim: exit $rc, want 0"
expect_build_args "$R"

# Two byte-identical copies of the shim ahead of the real cargo: each skips
# the other by the marker, so no exec loop. A loop hangs, which the watchdog
# turns into a failure.
mkdir -p "$T/c1" "$T/c2"
cp "$SHIM" "$T/c1/cargo" && cp "$SHIM" "$T/c2/cargo" || fail "cannot stage copies"
chmod 755 "$T/c1/cargo" "$T/c2/cargo"
new_run two-copies
cargo_as "$R" PATH="$T/c1:$T/c2:$T/real:$T/py:/usr/bin:/bin" -- build "a b" ""
rc=$?
[ "$rc" = 0 ] || fail "two copies of the shim: exit $rc, want 0"
expect_build_args "$R"

# A directory named cargo and a non-executable file named cargo, both ahead
# of the real cargo, are skipped.
mkdir -p "$T/dircargo/cargo" "$T/nonexec"
: >"$T/nonexec/cargo"
chmod 644 "$T/nonexec/cargo"
new_run dir-and-nonexec
cargo_as "$R" PATH="$T/shims:$T/dircargo:$T/nonexec:$T/real:$T/py:/usr/bin:/bin" \
  -- build "a b" ""
rc=$?
[ "$rc" = 0 ] || fail "directory and non-executable cargo: exit $rc, want 0"
expect_build_args "$R"

# A relative entry resolves against the working directory, so tools/cargo runs
# ahead of the real cargo.
new_run relative-entry
( cd "$T/cwd" &&
  cargo_as "$R" PATH="$T/shims:tools:$T/real:$T/py:/usr/bin:/bin" -- build "a b" "" )
rc=$?
[ "$rc" = 0 ] || fail "relative PATH entry: exit $rc, want 0 from tools/cargo"
[ -e "$R/tools-ran" ] || fail "tools/cargo behind a relative PATH entry did not run"
[ ! -e "$R/started" ] || fail "the real cargo ran ahead of tools/cargo"

# An empty entry and a "." entry both name the working directory, so cwd/cargo
# runs ahead of the real cargo.
for entry in "" "."; do
  new_run "cwd-entry-${entry:-empty}"
  ( cd "$T/cwd" &&
    cargo_as "$R" PATH="$T/shims:$entry:$T/real:$T/py:/usr/bin:/bin" -- build "a b" "" )
  rc=$?
  [ "$rc" = 0 ] || fail "PATH entry [$entry]: exit $rc, want 0 from cwd/cargo"
  [ -e "$R/cwd-ran" ] || fail "PATH entry [$entry] did not name the working directory"
  [ ! -e "$R/started" ] || fail "the real cargo ran ahead of cwd/cargo for PATH entry [$entry]"
done

# A regular file named like a PATH directory is skipped.
: >"$T/notdir"
new_run file-entry
cargo_as "$R" PATH="$T/notdir:$T/shims:$T/real:$T/py:/usr/bin:/bin" -- build "a b" ""
rc=$?
[ "$rc" = 0 ] || fail "file PATH entry: exit $rc, want 0"
expect_build_args "$R"

# The shim's own directory is skipped even for a cargo with no marker: the
# shim here runs by path, and the cargo beside it is a plain planted file.
mkdir -p "$T/own"
cp "$SHIM" "$T/own/shim-by-path" && chmod 755 "$T/own/shim-by-path" || fail "cannot stage own-dir shim"
printf '#!/bin/sh\n: >"$FAKE_DIR/own-planted"\n' >"$T/own/cargo"
chmod 755 "$T/own/cargo"
new_run own-dir
env -i PATH="$T/own:$T/real:$T/py:/usr/bin:/bin" HOME="$T/home" FAKE_DIR="$R" \
  "$T/own/shim-by-path" build "a b" ""
rc=$?
[ "$rc" = 0 ] || fail "own directory: exit $rc, want 0 from the real fake"
[ ! -e "$R/own-planted" ] || fail "a cargo in the shim's own directory ran"
expect_build_args "$R"

# The same directory named by a relative entry, with the shim run by a relative
# path from it, is still the shim's own directory and is skipped.
new_run own-dir-relative
( cd "$T/own" && env -i PATH=".:$T/real:$T/py:/usr/bin:/bin" HOME="$T/home" \
  FAKE_DIR="$R" ./shim-by-path build "a b" "" )
rc=$?
[ "$rc" = 0 ] || fail "relative own directory: exit $rc, want 0 from the real fake"
[ ! -e "$R/own-planted" ] || fail "a relative entry for the shim's own directory ran a cargo"
expect_build_args "$R"

# SIGPIPE and SIGXFSZ are ignored on entry (the parent ignores them, Python
# ignores them too); the shim restores both to default before exec.
new_run signals
( trap '' PIPE XFSZ
  cargo_as "$R" PATH="$T/shims:$T/perlreal:/usr/bin:/bin" -- build )
rc=$?
[ "$rc" = 0 ] || fail "signal case: exit $rc, want 0"
[ "$(cat "$R/sig")" = "PIPE=undef XFSZ=undef" ] ||
  fail "signals not default in the exec'd fake: $(cat "$R/sig")"

# CARGO_SLOT_HELD=1 runs the child at once with no slot dir. A held nested
# call reaches the fake with CARGO_SLOT_HELD still set.
new_run held
cargo_as "$R" CARGO_SLOTS=1 CARGO_SLOT_HELD=1 CARGO_SLOT_DIR="$T/slots" -- build "a b" ""
rc=$?
[ "$rc" = 0 ] || fail "held nested call: exit $rc, want 0"
[ "$(cat "$R/held")" = "held=1" ] || fail "held nested call: fake saw $(cat "$R/held")"
expect_no_slot_dir

# stdin passes through to the real cargo.
new_run stdin
printf 'x\n' | cargo_as "$R" FAKE_READ_STDIN=1 -- build
[ "$(cat "$R/stdin")" = "stdin=x" ] || fail "stdin: fake read $(cat "$R/stdin")"

# Task 2: subcommand classification. A slot-taking subcommand waits behind a
# held slot, and its fake never starts. Every other subcommand passes at once.

# waits_behind_holder NAME [VAR=VAL ...] -- ARGS: with the slot held, the
# waiter prints one waiting line and its fake never starts.
waits_behind_holder() {
  local name="$1" envs=() h w hold wpid
  shift
  while [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  h="$T/runs/$name-hold"
  w="$T/runs/$name-wait"
  stage "$h"
  stage "$w"
  hold_slot "$h" "$h/slots" 1
  hold=$HOLD_PID
  spawn "$w" CARGO_SLOTS=1 CARGO_SLOT_DIR="$h/slots" ${envs[@]+"${envs[@]}"} -- "$@"
  wpid=$SPAWNED
  expect_err_line "cargo-slot: waiting"
  [ ! -e "$w/started" ] || fail "$name: fake started while the slot was held"
  kill -TERM "$wpid"
  wait "$wpid" 2>/dev/null
  [ ! -e "$w/started" ] || fail "$name: fake started after the waiter was killed"
  expect_waiter_log "$w"
  release "$h"
  wait "$hold" 2>/dev/null
}

# passes_while_held NAME ARGS...: with the slot held, the fake runs at once
# and the shim exits with the fake's status.
passes_while_held() {
  local name="$1" h w hold wpid rc
  shift
  h="$T/runs/$name-hold"
  w="$T/runs/$name-pass"
  stage "$h"
  stage "$w"
  hold_slot "$h" "$h/slots" 1
  hold=$HOLD_PID
  spawn "$w" CARGO_SLOTS=1 CARGO_SLOT_DIR="$h/slots" FAKE_HOLD=1 -- "$@"
  wpid=$SPAWNED
  IFS= read -r _ <"$w/up"
  release "$w"
  wait "$wpid"
  rc=$?
  [ "$rc" = 0 ] || fail "$name: exit $rc, want 0 from the fake"
  release "$h"
  wait "$hold" 2>/dev/null
}

for sub in build check clippy test nextest bench run doc; do
  waits_behind_holder "sub-$sub" -- "$sub"
done

# `cargo mutants` never takes a slot: the shim refuses it with exit 1 before
# any lookup or validation, so lanes cannot run mutants locally. Mutants run
# in CI; read verdicts from there.
refuses_mutants() {
  local name="$1" rc want
  shift
  new_run "refuse-$name"
  cargo_as "$R" CARGO_SLOT_DIR="$T/slots-$name" "$@" 2>"$R/shim.err"
  rc=$?
  [ "$rc" = 1 ] || fail "$name: exit $rc, want 1 refusal"
  want='cargo-slot: cargo mutants is banned for lanes; mutants run in CI, read verdicts with ~/.agents/bin/mutant-verdicts <run> --repo <owner/name>'
  printf '%s\n' "$want" >"$R/want.err"
  cmp -s "$R/shim.err" "$R/want.err" ||
    fail "$name: stderr was [$(cat "$R/shim.err")], want [$want]"
  [ ! -e "$R/started" ] || fail "$name: fake cargo started"
  expect_no_slot_dir "$T/slots-$name"
}

refuses_mutants plain -- mutants
refuses_mutants list -- mutants --list
refuses_mutants plus -- +nightly mutants
refuses_mutants dash-c -- -C dir mutants
refuses_mutants config -- --config k=v mutants
refuses_mutants bad-slots CARGO_SLOTS=abc -- mutants
refuses_mutants held CARGO_SLOTS=1 CARGO_SLOT_HELD=1 -- mutants
refuses_mutants nocargo PATH="$T/shims:$T/py" -- mutants
waits_behind_holder "global-options" -- \
  +nightly -Z unstable-options --config k=v -C dir --color always -q -v \
  --locked --offline --frozen test
waits_behind_holder "config-equals" -- --config=k=v build

for sub in metadata fmt --version help t; do
  passes_while_held "pass-$sub" "$sub"
done
passes_while_held "pass-no-args"
passes_while_held "value-option-eats-test" -Z test fmt
passes_while_held "plus-only-first" -q +nightly build

# CARGO_SLOTS is read only for a slot-taking subcommand: a bad value on any
# other subcommand passes straight through with exit 0 and no shim stderr.
for pair in "abc:fmt" "abc:--version" "-1:metadata"; do
  v="${pair%%:*}"
  sub="${pair#*:}"
  new_run "junk-$v-$sub"
  cargo_as "$R" CARGO_SLOTS="$v" CARGO_SLOT_DIR="$T/slots" -- "$sub" 2>"$R/shim.err"
  rc=$?
  [ "$rc" = 0 ] || fail "CARGO_SLOTS=$v $sub: exit $rc, want 0 from the fake"
  [ ! -s "$R/shim.err" ] || fail "CARGO_SLOTS=$v $sub: shim wrote [$(cat "$R/shim.err")]"
  expect_no_slot_dir
done

# Task 3: slots, waiting, reentrancy, validation, environment, interrupt and
# lock failure.

# Two slots, three builds. The first two take slots; the third waits, starts
# once a holder releases, and prints its waiting line once.
S="$T/two"
stage "$S/a"
stage "$S/b"
stage "$S/c"
hold_slot "$S/a" "$S/slots" 2
A=$HOLD_PID
hold_slot "$S/b" "$S/slots" 2
B=$HOLD_PID
spawn "$S/c" CARGO_SLOTS=2 CARGO_SLOT_DIR="$S/slots" FAKE_HOLD=1 -- build "a b" ""
C=$SPAWNED
expect_err_line "cargo-slot: waiting"
[ ! -e "$S/c/started" ] || fail "third build started with both slots held"
release "$S/a"
wait "$A" 2>/dev/null
IFS= read -r _ <"$S/c/up"
release "$S/c"
wait "$C"
rc=$?
[ "$rc" = 0 ] || fail "third build: exit $rc, want 0 once a slot freed"
expect_build_args "$S/c"
expect_waiter_log "$S/c"
[ -e "$S/slots/slot-1.lock" ] && [ -e "$S/slots/slot-2.lock" ] ||
  fail "slot files are missing after the runs"
[ ! -e "$S/slots/slot-3.lock" ] || fail "a slot-3.lock was created for N=2"
release "$S/b"
wait "$B" 2>/dev/null

# A killed holder frees its slot: kill -9 the fake, and the next build takes
# the one slot.
K="$T/killed"
stage "$K/h"
stage "$K/w"
hold_slot "$K/h" "$K/slots" 1
kill -9 "$HOLD_PID"
wait "$HOLD_PID" 2>/dev/null
spawn "$K/w" CARGO_SLOTS=1 CARGO_SLOT_DIR="$K/slots" FAKE_HOLD=1 -- build "a b" ""
KW=$SPAWNED
IFS= read -r _ <"$K/w/up"
release "$K/w"
wait "$KW"
rc=$?
[ "$rc" = 0 ] || fail "build after a killed holder: exit $rc, want 0"
[ -e "$K/slots/slot-1.lock" ] || fail "slot-1.lock missing after a killed holder"

# A live lock on an inode with a dead recorded pid is reclaimed to a new file.
# The hook pauses the waiter after its first dead-pid read. Releasing it without
# a rewrite leaves the second read the same dead pid, so the lock is reclaimed.
Q="$T/reclaim-dead"
stage "$Q/h"
stage "$Q/w"
hold_slot "$Q/h" "$Q/slots" 1
QH=$HOLD_PID
# An out-of-range pid returns ESRCH without relying on process reaping or pid reuse.
DEAD_PID=5000000
printf '%s cargo build\n' "$DEAD_PID" >"$Q/slots/slot-1.lock"
# Keep both peers open without blocking: notifications on 8, acknowledgements on 5.
mkfifo "$Q/recheck" "$Q/recheck.ack" || fail "cannot stage recheck FIFOs"
exec 8<>"$Q/recheck"
exec 5<>"$Q/recheck.ack"
spawn "$Q/w" CARGO_SLOTS=1 CARGO_SLOT_DIR="$Q/slots" CARGO_SLOT_RECHECK_FIFO="$Q/recheck" FAKE_HOLD=1 -- build
QW=$SPAWNED
IFS= read -r -u 8 line
[ "$line" = "stale $DEAD_PID" ] || fail "waiter reported [$line], want stale $DEAD_PID"
printf 'go\n' >&5
IFS= read -r _ <"$Q/w/up"
[ -e "$Q/slots/slot-1.lock.stale-$DEAD_PID" ] ||
  fail "dead holder's lock was not moved aside"
release "$Q/w"
wait "$QW"
rc=$?
[ "$rc" = 0 ] || fail "build after reclaiming a dead recorded holder: exit $rc, want 0"
release "$Q/h"
wait "$QH" 2>/dev/null

# A live holder replaces a stale pid before the waiter's second dead-pid read.
# The helper holds the slot flock throughout. The hook pauses the waiter after
# its first dead-pid read; the helper rewrites its live pid; the test releases
# the waiter, which must not reclaim.
Q="$T/reclaim-race"
stage "$Q/w"
mkdir -p "$Q/slots"
RACE_DEAD_PID=5000000
printf '%s cargo build\n' "$RACE_DEAD_PID" >"$Q/slots/slot-1.lock"
mkfifo "$Q/helper.out" "$Q/helper.in" "$Q/recheck" "$Q/recheck.ack" || fail "cannot stage reclaim-race FIFOs"
exec 7<>"$Q/helper.out"
exec 6<>"$Q/helper.in"
# Open both hook peers before spawning; never read acknowledgements as notifications.
exec 8<>"$Q/recheck"
exec 5<>"$Q/recheck.ack"
"$PY" -c '
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
out = open(sys.argv[2], "w")
cmd = open(sys.argv[3])
out.write("locked\n")
out.flush()
cmd.readline()
os.ftruncate(fd, 0)
os.lseek(fd, 0, os.SEEK_SET)
os.write(fd, ("%d cargo build\n" % os.getpid()).encode())
out.write("rewritten\n")
out.flush()
cmd.readline()
' "$Q/slots/slot-1.lock" "$Q/helper.out" "$Q/helper.in" &
QH=$!
PIDS+=("$QH")
IFS= read -r -u 7 line
[ "$line" = locked ] || fail "reclaim-race helper reported [$line], want locked"
spawn "$Q/w" CARGO_SLOTS=1 CARGO_SLOT_DIR="$Q/slots" CARGO_SLOT_RECHECK_FIFO="$Q/recheck" -- build
QW=$SPAWNED
IFS= read -r -u 8 line
[ "$line" = "stale $RACE_DEAD_PID" ] || fail "waiter reported [$line], want stale $RACE_DEAD_PID"
printf 'rewrite\n' >&6
IFS= read -r -u 7 line
[ "$line" = rewritten ] || fail "reclaim-race helper reported [$line], want rewritten"
printf 'go\n' >&5
expect_err_line "cargo-slot: waiting"
[ "$(cat "$Q/slots/slot-1.lock")" = "$QH cargo build" ] ||
  fail "live holder did not replace the stale pid in the lock file"
[ ! -e "$Q/slots/slot-1.lock.stale-$RACE_DEAD_PID" ] ||
  fail "live holder's lock was moved aside after its pid rewrite"
[ ! -e "$Q/w/started" ] || fail "build started while the live holder held the slot"
kill -TERM "$QW"
wait "$QW" 2>/dev/null
expect_waiter_log "$Q/w"
printf 'exit\n' >&6
wait "$QH" || fail "reclaim-race helper did not exit cleanly"

# A live recorded pid remains in place and the waiter continues to wait.
Q="$T/reclaim-live"
stage "$Q/h"
stage "$Q/w"
hold_slot "$Q/h" "$Q/slots" 1
QH=$HOLD_PID
spawn "$Q/w" CARGO_SLOTS=1 CARGO_SLOT_DIR="$Q/slots" -- build
QW=$SPAWNED
expect_err_line "cargo-slot: waiting"
[ ! -e "$Q/slots/slot-1.lock.stale-$QH" ] ||
  fail "live recorded holder's lock was moved aside"
[ ! -e "$Q/w/started" ] || fail "build started while the recorded holder was alive"
kill -TERM "$QW"
wait "$QW" 2>/dev/null
expect_waiter_log "$Q/w"
release "$Q/h"
wait "$QH" 2>/dev/null

# Nested calls. A slot-taking run records CARGO_SLOT_HELD=1 in the fake; a
# pass-through run records it absent; a nested run under a held slot runs at
# once even while the slot is held.
N="$T/nested"
stage "$N/h"
new_run nest-free
cargo_as "$R" CARGO_SLOTS=1 CARGO_SLOT_DIR="$N/free" -- build "a b" ""
[ "$(cat "$R/held")" = "held=1" ] || fail "slot-taking run: fake saw $(cat "$R/held")"
new_run nest-pass
cargo_as "$R" CARGO_SLOTS=1 CARGO_SLOT_DIR="$N/free" -- fmt
[ "$(cat "$R/held")" = "held=unset" ] || fail "pass-through run: fake saw $(cat "$R/held")"
hold_slot "$N/h" "$N/slots" 1
NH=$HOLD_PID
new_run nest-held
cargo_as "$R" CARGO_SLOTS=1 CARGO_SLOT_HELD=1 CARGO_SLOT_DIR="$N/slots" -- build "a b" ""
[ "$(cat "$R/held")" = "held=1" ] || fail "nested run under a held slot: fake saw $(cat "$R/held")"
release "$N/h"
wait "$NH" 2>/dev/null

# CARGO_SLOT_HELD of 0 or empty is unset: the run takes a slot like unset.
waits_behind_holder "held-zero" CARGO_SLOT_HELD=0 -- build
waits_behind_holder "held-empty" CARGO_SLOT_HELD= -- build

# Value validation: anything but digits exits 2 before the fake runs.
V="$T/validate"
i=0
for v in abc -1 +2 1.5 " 2" "2 " 2_0; do
  i=$((i + 1))
  new_run "bad-$i"
  cargo_as "$R" "CARGO_SLOTS=$v" CARGO_SLOT_DIR="$V/slots" -- build 2>"$R/shim.err"
  rc=$?
  [ "$rc" = 2 ] || fail "CARGO_SLOTS=[$v]: exit $rc, want 2"
  [ "$(cat "$R/shim.err")" = "cargo-slot: CARGO_SLOTS must be a positive integer, got '$v'" ] ||
    fail "CARGO_SLOTS=[$v]: stderr [$(cat "$R/shim.err")]"
  [ ! -e "$R/started" ] || fail "CARGO_SLOTS=[$v]: the fake ran"
  expect_no_slot_dir "$V/slots"
done

# All-zero digits pass straight through, like 0.
new_run zeros
cargo_as "$R" CARGO_SLOTS=00 CARGO_SLOT_DIR="$V/zeros" -- build "a b" ""
rc=$?
[ "$rc" = 0 ] || fail "CARGO_SLOTS=00: exit $rc, want 0 from the fake"
expect_build_args "$R"
expect_no_slot_dir "$V/zeros"

# No upper bound on N: one build takes slot-1.lock only, and the others are
# never created.
new_run big
cargo_as "$R" CARGO_SLOTS=100 CARGO_SLOT_DIR="$V/big" -- build "a b" ""
rc=$?
[ "$rc" = 0 ] || fail "CARGO_SLOTS=100: exit $rc, want 0 from the fake"
[ -e "$V/big/slot-1.lock" ] || fail "CARGO_SLOTS=100: slot-1.lock missing"
[ ! -e "$V/big/slot-2.lock" ] || fail "CARGO_SLOTS=100: slot-2.lock created with one build"

# HOME unset and CARGO_SLOT_DIR unset: no slot directory, exit 1.
new_run no-home
env -i PATH="$BASEPATH" FAKE_DIR="$R" CARGO_SLOTS=1 "$T/shims/cargo" build \
  2>"$R/shim.err"
rc=$?
[ "$rc" = 1 ] || fail "HOME unset: exit $rc, want 1"
grep -q '^cargo-slot:' "$R/shim.err" || fail "HOME unset: no cargo-slot: line"
[ ! -e "$R/started" ] || fail "HOME unset: the fake ran"

# CARGO_SLOT_DIR empty means the default under HOME.
new_run empty-dir
cargo_as "$R" CARGO_SLOTS=1 CARGO_SLOT_DIR= HOME="$T/home-empty" -- build "a b" ""
rc=$?
[ "$rc" = 0 ] || fail "empty CARGO_SLOT_DIR: exit $rc, want 0"
[ -e "$T/home-empty/.cache/agents/cargo-slots/slot-1.lock" ] ||
  fail "empty CARGO_SLOT_DIR: default slot file missing"

# Interrupt while waiting: SIGINT exits 130 with no traceback. The launcher
# sets SIGINT to default before exec, because a non-interactive bash starts
# a background child with SIGINT ignored.
I="$T/intr"
stage "$I/h"
stage "$I/w"
hold_slot "$I/h" "$I/slots" 1
IH=$HOLD_PID
env -i PATH="$BASEPATH" HOME="$T/home" FAKE_DIR="$I/w" CARGO_SLOTS=1 \
  CARGO_SLOT_DIR="$I/slots" "$PY" -c \
  'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' \
  "$T/shims/cargo" build 2>"$I/w/err" &
IP=$!
PIDS+=("$IP")
exec 9<"$I/w/err"
ERR_SEEN=""
expect_err_line "cargo-slot: waiting"
kill -INT "$IP"
wait "$IP"
rc=$?
[ "$rc" = 130 ] || fail "SIGINT while waiting: exit $rc, want 130"
expect_waiter_log "$I/w"
release "$I/h"
wait "$IH" 2>/dev/null

# Lock failures fail closed: a slot directory under a regular file, and a
# read-only slot directory with no slot file yet. Neither retries.
new_run file-parent
: >"$R/afile"
cargo_as "$R" CARGO_SLOTS=1 CARGO_SLOT_DIR="$R/afile/slots" -- build 2>"$R/shim.err"
rc=$?
[ "$rc" = 1 ] || fail "slot dir under a regular file: exit $rc, want 1"
grep -q '^cargo-slot:' "$R/shim.err" || fail "slot dir under a file: no cargo-slot: line"
[ ! -e "$R/started" ] || fail "slot dir under a file: the fake ran"

if [ "$(id -u)" = 0 ]; then
  echo "cargo-slot: read-only slot directory skipped (root ignores the mode)"
else
  new_run read-only
  mkdir -p "$R/ro"
  chmod 500 "$R/ro"
  cargo_as "$R" CARGO_SLOTS=1 CARGO_SLOT_DIR="$R/ro" -- build 2>"$R/shim.err"
  rc=$?
  chmod 755 "$R/ro"
  [ "$rc" = 1 ] || fail "read-only slot directory: exit $rc, want 1"
  grep -q '^cargo-slot:' "$R/shim.err" || fail "read-only slot directory: no cargo-slot: line"
  [ ! -e "$R/started" ] || fail "read-only slot directory: the fake ran"
fi

# Shared-checkout guard. CARGO_SLOT_SHARED_CHECKOUT names the shared checkout;
# a slot subcommand run from it is refused before any slot is taken. The
# fixture is a real repo with a worktree, a subdirectory, a symlink to the repo
# and a directory outside any repo. Its git commands ignore the global config.
guard_git() {
  GIT_CONFIG_GLOBAL=/dev/null git "$@"
}
mkdir -p "$T/shared" "$T/plain"
guard_git -C "$T/shared" init -q || fail "guard fixture: git init"
guard_git -C "$T/shared" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
  commit -q --allow-empty -m init || fail "guard fixture: commit"
guard_git -C "$T/shared" worktree add -q --detach "$T/ticket" ||
  fail "guard fixture: worktree"
mkdir "$T/shared/sub"
ln -s "$T/shared" "$T/shared-link"

# e. From a worktree, the var naming the shared checkout does not refuse.
new_run guard-e
( cd "$T/ticket" && cargo_as "$R" CARGO_SLOT_SHARED_CHECKOUT="$T/shared" \
  CARGO_SLOTS=1 CARGO_SLOT_DIR="$T/guard-e" -- build "a b" "" )
rc=$?
[ "$rc" = 0 ] || fail "guard e (worktree): exit $rc, want 0"
expect_build_args "$R"
[ -e "$T/guard-e/slot-1.lock" ] || fail "guard e (worktree): no slot taken"

# f. Unset var from the shared checkout: the guard is off, the slot is taken.
new_run guard-f
( cd "$T/shared" && cargo_as "$R" CARGO_SLOTS=1 CARGO_SLOT_DIR="$T/guard-f" -- build "a b" "" )
rc=$?
[ "$rc" = 0 ] || fail "guard f (unset var): exit $rc, want 0"
expect_build_args "$R"
[ -e "$T/guard-f/slot-1.lock" ] || fail "guard f (unset var): no slot taken"

# g. Empty var from the shared checkout: the guard is off, the slot is taken.
new_run guard-g
( cd "$T/shared" && cargo_as "$R" CARGO_SLOT_SHARED_CHECKOUT= CARGO_SLOTS=1 \
  CARGO_SLOT_DIR="$T/guard-g" -- build "a b" "" )
rc=$?
[ "$rc" = 0 ] || fail "guard g (empty var): exit $rc, want 0"
expect_build_args "$R"
[ -e "$T/guard-g/slot-1.lock" ] || fail "guard g (empty var): no slot taken"

# h. From a directory outside any repo, the var does not refuse.
new_run guard-h
( cd "$T/plain" && cargo_as "$R" CARGO_SLOT_SHARED_CHECKOUT="$T/shared" CARGO_SLOTS=1 \
  CARGO_SLOT_DIR="$T/guard-h" -- build "a b" "" )
rc=$?
[ "$rc" = 0 ] || fail "guard h (outside a repo): exit $rc, want 0"
expect_build_args "$R"

# i. A non-slot subcommand from the shared checkout passes with no slot taken.
new_run guard-i
( cd "$T/shared" && cargo_as "$R" CARGO_SLOT_SHARED_CHECKOUT="$T/shared" CARGO_SLOTS=1 \
  CARGO_SLOT_DIR="$T/guard-i" -- fmt )
rc=$?
[ "$rc" = 0 ] || fail "guard i (fmt): exit $rc, want 0"
[ -e "$R/started" ] || fail "guard i (fmt): the fake did not run"
expect_no_slot_dir "$T/guard-i"

# guard_refused NAME CWD [VAR=VAL ...]: check run from CWD is refused. Exit 1,
# the guard message alone on stderr, the fake never starts, no slot directory.
# The extra words come after the defaults, so they override them.
guard_refused() {
  local name="$1" dir="$2" slots="$T/guard-$1"
  shift 2
  local shared="" worktree_root="" w
  for w in "$@"; do
    case "$w" in
      CARGO_SLOT_SHARED_CHECKOUT=*) shared="${w#CARGO_SLOT_SHARED_CHECKOUT=}" ;;
      CARGO_SLOT_WORKTREE_ROOT=*) worktree_root="${w#CARGO_SLOT_WORKTREE_ROOT=}" ;;
    esac
  done
  local cwd
  cwd="$(cd "$dir" && pwd -P)" || fail "guard $name: cannot resolve $dir"
  local hint=""
  if [ -n "$worktree_root" ]; then
    while [[ "$worktree_root" == */ ]]; do worktree_root="${worktree_root%/}"; done
    local quoted_shared quoted_root
    quoted_shared="$(python3 -c 'import shlex, sys; print(shlex.quote(sys.argv[1]))' "$shared")"
    quoted_root="$(python3 -c 'import shlex, sys; print(shlex.quote(sys.argv[1]))' "$worktree_root")"
    hint="; for a scratch worktree run \`git -C $quoted_shared worktree add --detach $quoted_root/<name>\`, where <name> describes the job (e.g. audit, bench), never a lane number"
  fi
  local want="cargo-slot: cwd $cwd is inside the shared checkout $shared; cd into your ticket worktree and rerun$hint. This is a cwd check, not a permission denial."
  new_run "guard-$name"
  ( cd "$dir" && cargo_as "$R" CARGO_SLOTS=1 CARGO_SLOT_DIR="$slots" "$@" \
    -- check 2>"$R/shim.err" )
  local rc=$?
  [ "$rc" = 1 ] || fail "guard $name: exit $rc, want 1"
  [ "$(cat "$R/shim.err")" = "$want" ] ||
    fail "guard $name: stderr [$(cat "$R/shim.err")]"
  [ ! -e "$R/started" ] || fail "guard $name: the fake ran"
  [ ! -e "$slots" ] || fail "guard $name: slot directory created"
}

# a. Refused from the shared checkout itself.
guard_refused a "$T/shared" CARGO_SLOT_SHARED_CHECKOUT="$T/shared"
# b. Refused from a subdirectory of the shared checkout.
guard_refused b "$T/shared/sub" CARGO_SLOT_SHARED_CHECKOUT="$T/shared"
# c. Refused when the var is a symlink to the shared checkout.
guard_refused c "$T/shared" CARGO_SLOT_SHARED_CHECKOUT="$T/shared-link"
# d. Refused while a slot is already held: the guard runs before the held check.
guard_refused d "$T/shared" CARGO_SLOT_SHARED_CHECKOUT="$T/shared" CARGO_SLOT_HELD=1
# j. Refused before CARGO_SLOTS is validated: a bad value is not exit 2 here.
guard_refused j "$T/shared" CARGO_SLOT_SHARED_CHECKOUT="$T/shared" CARGO_SLOTS=abc
# k. GIT_* variables do not change the answer: GIT_DIR points nowhere.
guard_refused k "$T/shared" CARGO_SLOT_SHARED_CHECKOUT="$T/shared" GIT_DIR="$T/nogit"
# l. A configured root adds the quoted scratch-worktree command.
guard_refused l "$T/shared" CARGO_SLOT_SHARED_CHECKOUT="$T/shared" CARGO_SLOT_WORKTREE_ROOT="$T/fiber-worktrees"
# m. Trailing slashes on the configured root do not appear in the command.
guard_refused m "$T/shared" CARGO_SLOT_SHARED_CHECKOUT="$T/shared" CARGO_SLOT_WORKTREE_ROOT="$T/fiber-worktrees/"
# n. An empty root keeps the old refusal text.
guard_refused n "$T/shared" CARGO_SLOT_SHARED_CHECKOUT="$T/shared" CARGO_SLOT_WORKTREE_ROOT=

# Acceptance: a daemon child must not keep the slot after the cargo stub exits.
D="$T/daemon"
stage "$D/cargo"
stage "$D/reacquire"
mkfifo "$D/cargo/daemon.go" || fail "cannot stage daemon FIFO"
spawn_quiet "$D/cargo" CARGO_SLOTS=1 CARGO_SLOT_DIR="$D/slots" \
  FAKE_DAEMON=1 -- build
DAEMON_CARGO=$SPAWNED
wait "$DAEMON_CARGO"
rc=$?
[ "$rc" = 0 ] || fail "daemon stub: exit $rc, want 0"
DAEMON_PID="$(cat "$D/cargo/daemon.pid")"
kill -0 "$DAEMON_PID" 2>/dev/null || fail "daemon child did not outlive the cargo stub"
exec 8<>"$D/reacquire/up"
spawn "$D/reacquire" CARGO_SLOTS=1 CARGO_SLOT_DIR="$D/slots" FAKE_HOLD=1 -- build
REACQUIRE=$SPAWNED
# Blocks until the reacquiring build takes the slot; the watchdog bounds a hang.
IFS= read -r -u 8 _
release "$D/reacquire"
wait "$REACQUIRE"
rc=$?
[ "$rc" = 0 ] || fail "build after daemon stub: exit $rc, want 0"
kill -TERM "$DAEMON_PID" 2>/dev/null || true

# Acceptance: the shim propagates an ordinary exit status and re-raises a
# signal death with the conventional 128+N status.
new_run slot-exit-status
cargo_as "$R" CARGO_SLOTS=1 CARGO_SLOT_DIR="$T/status-slots" FAKE_EXIT=7 -- build
rc=$?
[ "$rc" = 7 ] || fail "slot child status: exit $rc, want 7"
new_run slot-signal-status
cargo_as "$R" CARGO_SLOTS=1 CARGO_SLOT_DIR="$T/signal-slots" FAKE_SIGNAL=TERM \
  -- build 2>"$R/shim.err"
rc=$?
[ "$rc" = 143 ] || fail "slot child signal: exit $rc, want 143"

# Acceptance: the lock file identifies the shim process and cargo argv while
# the stub is still running.
L="$T/holder-info"
stage "$L"
hold_slot "$L" "$L/slots" 1
LOCK_HOLDER=$HOLD_PID
[ "$(cat "$L/slots/slot-1.lock")" = "$LOCK_HOLDER cargo build" ] ||
  fail "lock file does not name holder $LOCK_HOLDER and argv: $(cat "$L/slots/slot-1.lock")"
release "$L"
wait "$LOCK_HOLDER"

echo "cargo-slot: all cases passed"
cleanup

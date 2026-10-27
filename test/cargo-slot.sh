#!/usr/bin/env bash
# Tests for bin/cargo-slot, against a fake real cargo in a mktemp -d fixture
# (never ~/.cache/agents). Every blocking wait is a FIFO open or read with a
# deadline, so a bug fails the case instead of hanging it.
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
# $FAKE_DIR. FAKE_READ_STDIN=1 reads one stdin line. FAKE_HOLD=1 reports its
# pid on $FAKE_DIR/up and blocks on $FAKE_DIR/go. Bash builtins only, so no
# child inherits the lock fd.
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
if [ "${FAKE_HOLD:-0}" = 1 ]; then
  printf '%s\n' "$$" >"$FAKE_DIR/up"
  IFS= read -r _ <"$FAKE_DIR/go"
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

# new_run NAME: a fresh directory for one run's fake logs and FIFOs; sets R.
new_run() {
  R="$T/runs/$1"
  mkdir -p "$R" && mkfifo "$R/up" "$R/go" || fail "cannot stage run $1"
}

# cargo_as R [VAR=VAL ...] -- ARGS: the installed shim, run as `cargo` in a
# clean environment. Later VAR=VAL words override the defaults (PATH too).
cargo_as() {
  local r="$1" envs=()
  shift
  while [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  env -i PATH="$BASEPATH" HOME="$T/home" FAKE_DIR="$r" \
    ${envs[@]+"${envs[@]}"} "$T/shims/cargo" "$@"
}

expect_build_args() {
  [ "$(cat "$1/args")" = "$(printf 'argc=3\n<build>\n<a b>\n<>')" ] ||
    fail "args reached the fake as: $(cat "$1/args")"
}

expect_no_slot_dir() {
  [ ! -e "$T/slots" ] || fail "pass-through created the slot directory"
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

new_run nocargo
env -i PATH="$T/shims:$T/py" HOME="$T/home" FAKE_DIR="$R" \
  "$T/shims/cargo" build >"$R/out" 2>"$R/err"
rc=$?
[ "$rc" = 127 ] || fail "no real cargo on PATH: exit $rc, want 127"
grep -q 'cargo-slot:' "$R/err" || fail "no real cargo: no cargo-slot: line on stderr"

new_run pathunset
env -u PATH FAKE_DIR="$R" "$T/py/python3" "$SHIM" build >"$R/out" 2>"$R/err"
rc=$?
[ "$rc" = 127 ] || fail "PATH unset: exit $rc, want 127"
grep -q 'cargo-slot:' "$R/err" || fail "PATH unset: no cargo-slot: line on stderr"

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

# An empty PATH element and relative elements come before the real cargo.
# Planted cargo files in the working directory and in rel/ never run.
mkdir -p "$T/cwd/rel"
for f in "$T/cwd/cargo" "$T/cwd/rel/cargo"; do
  printf '#!/bin/sh\n: >"$FAKE_DIR/planted"\n' >"$f"
  chmod 755 "$f"
done
new_run relative-and-empty
( cd "$T/cwd" &&
  cargo_as "$R" PATH="::.:rel:$T/real:$T/py:/usr/bin:/bin" -- build "a b" "" )
rc=$?
[ "$rc" = 0 ] || fail "relative and empty PATH entries: exit $rc, want 0"
[ ! -e "$R/planted" ] || fail "a planted cargo ran from an empty or relative PATH entry"
expect_build_args "$R"

# A regular file named like a PATH directory is skipped.
: >"$T/notdir"
new_run file-entry
cargo_as "$R" PATH="$T/notdir:$T/shims:$T/real:$T/py:/usr/bin:/bin" -- build "a b" ""
rc=$?
[ "$rc" = 0 ] || fail "file PATH entry: exit $rc, want 0"
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

echo "cargo-slot: all cases passed"
cleanup

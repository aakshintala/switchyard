#!/usr/bin/env bash
# box-setup.sh -- provision the box user's TMPDIR defaults in both Bash and systemd.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
BIN="$here/../bin/box-setup"
T="$(mktemp -d "${TMPDIR:-/tmp}/box-setup-XXXXXX")"
trap 'rm -rf "$T"' EXIT
LANES_TMP="$T/lanes-tmp"
rc=0
n=0

ok() {
  name="$1"
  shift
  n=$((n + 1))
  if "$@"; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    rc=1
  fi
}

has() { printf '%s\n' "$1" | grep -Fq -- "$2"; }
has_both() { has "$1" "$2" && has "$1" "$3"; }
output_is_lanes() { [ "$1" -eq 0 ] && [ "$2" = "$LANES_TMP" ]; }
stale_block_is_replaced() {
  ! grep -Fq '/old/tmp' "$1" && [ "$(grep -Fc 'switchyard box-setup: TMPDIR' "$1")" = 2 ]
}

# A systemctl stub records its args, so the test never reloads a real user manager.
# It lists the units in $UNITS_FILE and answers MainPID from $PIDS_DIR/<unit>.
SYSTEMCTL_LOG="$T/systemctl.log"
UNITS_FILE="$T/units"
PIDS_DIR="$T/pids"
mkdir -p "$PIDS_DIR"
: >"$UNITS_FILE"
cat >"$T/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$SYSTEMCTL_LOG"
case "\$*" in
  *list-units*) cat "$UNITS_FILE" ;;
  *'show -p MainPID --value '*) cat "$PIDS_DIR/\${*: -1}" 2>/dev/null || echo 0 ;;
esac
EOF
chmod +x "$T/systemctl"

# A synthetic /proc root; the test never reads the real /proc.
PROC_ROOT="$T/proc"
mkdir -p "$PROC_ROOT"

run_setup() {
  out="$(BOX_SETUP_PROC_ROOT="$PROC_ROOT" BOX_SYSTEMCTL="$T/systemctl" BOX_LANES_TMP="$LANES_TMP" HOME="$home" bash "$BIN" 2>&1)"
  code=$?
}

# fake_service <unit> <pid> <environ lines...>: a running unit whose process has that environment.
fake_service() {
  unit="$1" pid="$2"
  shift 2
  printf '%s loaded active running Fiber hub\n' "$unit" >>"$UNITS_FILE"
  printf '%s\n' "$pid" >"$PIDS_DIR/$unit"
  mkdir -p "$PROC_ROOT/$pid"
  printf '%s\0' "$@" >"$PROC_ROOT/$pid/environ"
}
no_warning() { ! has "$1" 'warning'; }
no_restart() { ! grep -q 'restart' "$SYSTEMCTL_LOG"; }

write_expected_block() {
  cat >"$1" <<EOF
# >>> switchyard box-setup: TMPDIR >>>
export TMPDIR=$LANES_TMP
# <<< switchyard box-setup: TMPDIR <<<
EOF
}

# A fresh home gets the export at the start of .bashrc and a systemd user env.
home="$T/fresh"
mkdir -p "$home"
run_setup
write_expected_block "$T/expected-bashrc"
printf 'TMPDIR=%s\n' "$LANES_TMP" >"$T/expected-lanes.conf"
ok "fresh setup exits successfully (exit $code)" test "$code" -eq 0
ok 'fresh setup creates the tmp directory' test -d "$LANES_TMP"
ok 'fresh setup creates the bashrc block first' cmp -s "$T/expected-bashrc" "$home/.bashrc"
ok 'fresh setup creates the systemd environment file' cmp -s "$T/expected-lanes.conf" "$home/.config/environment.d/lanes.conf"
ok 'fresh setup reports both files changed' has_both "$out" '.bashrc changed' 'lanes.conf changed'
ok 'fresh setup reloads the systemd user manager' grep -qx -- '--user daemon-reload' "$SYSTEMCTL_LOG"

# A second run must be byte-identical and report no file changes.
cp "$home/.bashrc" "$T/second-bashrc"
cp "$home/.config/environment.d/lanes.conf" "$T/second-lanes.conf"
run_setup
ok 'second setup exits successfully' test "$code" -eq 0
ok 'second setup leaves bashrc byte-identical' cmp -s "$T/second-bashrc" "$home/.bashrc"
ok 'second setup leaves lanes.conf byte-identical' cmp -s "$T/second-lanes.conf" "$home/.config/environment.d/lanes.conf"
ok 'second setup reports both files unchanged' has_both "$out" '.bashrc unchanged' 'lanes.conf unchanged'

# Debian-style interactive guard remains untouched and follows the export.
home="$T/debian"
mkdir -p "$home"
cat >"$T/debian-original" <<'EOF'
# ~/.bashrc: executed by bash(1) for non-login shells.
case $- in
  *i*) ;;
    *) return;;
esac

# User additions stay exactly where they were.
export DEBIAN_STYLE=1
EOF
cp "$T/debian-original" "$home/.bashrc"
chmod 640 "$home/.bashrc"
run_setup
write_expected_block "$T/debian-expected"
cat "$T/debian-original" >>"$T/debian-expected"
ok 'existing guarded bashrc is provisioned successfully' test "$code" -eq 0
ok 'the TMPDIR block precedes the interactive guard and preserves the rest byte for byte' cmp -s "$T/debian-expected" "$home/.bashrc"
if [ "$(uname -s)" = Darwin ]; then
  mode="$(stat -f '%Lp' "$home/.bashrc")"
else
  mode="$(stat -c '%a' "$home/.bashrc")"
fi
ok 'existing bashrc mode is preserved' test "$mode" = 640

# Sourcing in a non-interactive shell exports before Debian's guard returns;
# an unconfigured child command (a delegate-job stand-in) inherits the value.
out="$(env -i HOME="$home" PATH="$PATH" bash -c '. "$HOME/.bashrc"; bash -c "echo \\$TMPDIR"' 2>&1)"
code=$?
ok "non-interactive sourced bashrc lets a child inherit TMPDIR (got [$out], exit $code)" output_is_lanes "$code" "$out"
out="$(env -i HOME="$home" PATH="$PATH" bash -c '. "$HOME/.bashrc"; printf "%s\\n" "$TMPDIR"' 2>&1)"
code=$?
ok "sourcing bashrc with an interactive guard exports before its return (got [$out], exit $code)" output_is_lanes "$code" "$out"

# An old marked block is replaced, not left alongside the new value.
home="$T/stale"
mkdir -p "$home"
cat >"$home/.bashrc" <<'EOF'
# >>> switchyard box-setup: TMPDIR >>>
export TMPDIR=/old/tmp
# <<< switchyard box-setup: TMPDIR <<<
# Preserve this old tail.
case $- in *i*) ;; *) return;; esac
EOF
cp "$home/.bashrc" "$T/stale-original"
run_setup
write_expected_block "$T/stale-expected"
tail -n +4 "$T/stale-original" >>"$T/stale-expected"
ok 'stale setup exits successfully' test "$code" -eq 0
ok 'stale block is replaced while its tail is preserved' cmp -s "$T/stale-expected" "$home/.bashrc"
ok 'stale value is absent and exactly one block remains' stale_block_is_replaced "$home/.bashrc"

# A running Fiber hub (#1970): no hub is quiet, a hub with the lanes TMPDIR is
# quiet, and a hub started before lanes.conf existed gets one restart warning.
home="$T/services"
mkdir -p "$home"
run_setup
ok 'no hub service: setup exits successfully' test "$code" -eq 0
ok 'no hub service: no warning' no_warning "$out"

fake_service fiber-hub-good.service 101 LANG=C "TMPDIR=$LANES_TMP"
run_setup
ok 'hub with lanes TMPDIR: setup exits successfully' test "$code" -eq 0
ok 'hub with lanes TMPDIR: no warning' no_warning "$out"

fake_service fiber-hub-stale.service 202 LANG=C TMPDIR=/tmp
run_setup
ok 'hub without lanes TMPDIR: setup exits successfully' test "$code" -eq 0
ok 'hub without lanes TMPDIR: warns once, naming the unit' test "$(printf '%s\n' "$out" | grep -c 'warning')" = 1
ok 'hub without lanes TMPDIR: names the stale unit and its pid' has "$out" 'fiber-hub-stale.service (pid 202)'
ok 'hub without lanes TMPDIR: gives the restart and when to run it' \
  has_both "$out" "systemctl --user restart fiber-hub-stale.service" 'when no Fiber jobs are running'
ok 'hub without lanes TMPDIR: never restarts anything itself' no_restart

# A hub whose environ can't be read (#1977): the pid exited after `systemctl
# show`, so its /proc entry is gone. Say so, and give no restart advice.
fake_service fiber-hub-gone.service 303 LANG=C
rm -rf "${PROC_ROOT:?}/303"
run_setup
ok 'hub with unreadable environ: setup exits successfully' test "$code" -eq 0
ok 'hub with unreadable environ: says it could not read it' \
  has "$out" 'could not read the environment of fiber-hub-gone.service (pid 303)'
ok 'hub with unreadable environ: no restart advice for it' \
  test "$(printf '%s\n' "$out" | grep -c 'restart fiber-hub-gone.service')" = 0
ok 'hub with unreadable environ: only the stale hub warns' test "$(printf '%s\n' "$out" | grep -c 'warning')" = 1

if [ "$rc" = 0 ]; then
  echo "box-setup: $n ok"
else
  echo "box-setup: failures above ($n checks)"
fi
exit "$rc"

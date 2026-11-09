#!/usr/bin/env bash
# test-agents-ff.sh -- bin/agents-ff.sh over a real throwaway git repo.
#
# Same split as test-boxstale.sh, for the same reason: the Mac side is a real
# repo because the ahead/diverged cases turn on ancestry, and the box side is
# stubbed through BOX_SSH because it is one pull and one rev-parse.
#
# The two properties switchyard #1319 names are the first two cases: the pull
# never blocks a launch, and the WARN names both shas. They are tested as exit
# code and output, not as prose in the script.
set -u

here="$(cd "$(dirname "$0")/../bin" && pwd)"
rc=0
n=0

T="$(mktemp -d "${TMPDIR:-/tmp}/fw-agentsff-XXXXXX")"
trap 'rm -rf "$T"' EXIT

# A stub for $ssh. agents-ff calls it as: $ssh -o .. -o .. HOST '<pull; echo
# RC=$?; rev-parse>'. The stub ignores its arguments and replays what the case
# exported: BOXRC as the pull's exit code, BOXSHA as the resulting HEAD, and
# BOXDEAD=1 as an unreachable host (no output at all).
cat > "$T/fakessh" <<'STUB'
#!/usr/bin/env bash
[ -n "${BOXDEAD:-}" ] && exit 255
printf 'RC=%s\n' "${BOXRC:-0}"
[ -n "${BOXSHA:-}" ] && printf '%s\n' "$BOXSHA"
exit 0
STUB
chmod +x "$T/fakessh"

A="$T/agents"
mkdir -p "$A"
git -C "$A" init -q
git -C "$A" config user.email t@t
git -C "$A" config user.name t
mk() {
  echo "$1" >> "$A/f"
  git -C "$A" add f
  git -C "$A" commit -qm "$1"
  git -C "$A" rev-parse HEAD
}
c1="$(mk 'first: the oldest tool')"
c2="$(mk 'second: shipped from the mac')"
# A commit the Mac does not have, for the "box is ahead" case: make it on a
# branch, record it, then move main back so main is its ancestor.
git -C "$A" checkout -q -b ahead
c3="$(mk 'third: committed on the box by hand')"
git -C "$A" checkout -q main 2>/dev/null || git -C "$A" checkout -q master
git -C "$A" rev-parse HEAD > /dev/null
mac="$(git -C "$A" rev-parse HEAD)"

run() { # run [--strict]
  out="$(BOX_SSH="$T/fakessh" FW_AGENTS_DIR="$A" bash "$here/agents-ff.sh" "$@" 2>&1)"
  code=$?
}

ok() { # ok <name> <desc> <0|1>
  n=$((n + 1))
  if [ "$3" = 0 ]; then
    printf 'FAIL %s -- %s\n' "$1" "$2"
    printf '%s\n' "$out" | sed 's/^/     | /'
    printf '     exit %s\n' "$code"
    rc=1
  else
    # One `ok` line per passing case: bin/selftest counts them and calls a
    # silent suite red, because a suite that asserts nothing passes everything.
    printf 'ok %s\n' "$1"
  fi
}

has() { case "$out" in *"$1"*) echo 1;; *) echo 0;; esac; }

# 1. In step: exit 0, and the match line names the sha.
BOXRC=0 BOXSHA="$mac"; export BOXRC BOXSHA; unset BOXDEAD
run
ok instep-exit0 "a matching box exits 0" "$([ "$code" = 0 ] && echo 1 || echo 0)"
ok instep-says-match "names the match and the sha" "$(has "matches this Mac at ${mac:0:8}")"

# 2. A failed pull does not block the launch, and names both shas.
BOXRC=1 BOXSHA="$c1"; export BOXRC BOXSHA
run
ok failed-pull-exit0 "a failed pull still exits 0" "$([ "$code" = 0 ] && echo 1 || echo 0)"
ok failed-pull-mac-sha "the WARN names the mac sha" "$(has "mac=$mac")"
ok failed-pull-box-sha "the WARN names the box sha" "$(has "box=$c1")"
ok failed-pull-warns "the line is a WARN" "$(has 'WARN agents-ff')"
ok failed-pull-fix "it prints the fix command" "$(has "pull --ff-only")"

# 3. --strict is the only nonzero exit, for a caller that wants to gate.
run --strict
ok strict-exit3 "--strict exits 3 on a mismatch" "$([ "$code" = 3 ] && echo 1 || echo 0)"

# 4. Unreachable box: no sha to report, and still exit 0.
BOXDEAD=1; export BOXDEAD
run
ok dead-exit0 "an unreachable box exits 0" "$([ "$code" = 0 ] && echo 1 || echo 0)"
ok dead-says-unknown "says the box HEAD is unknown" "$(has 'box=unknown')"
unset BOXDEAD

# 5. Box ahead: the pull succeeded and the shas still differ, so say which way.
BOXRC=0 BOXSHA="$c3"; export BOXRC BOXSHA
run
ok ahead-named "names the box as ahead" "$(has 'box is AHEAD')"
ok ahead-exit0 "an ahead box still exits 0" "$([ "$code" = 0 ] && echo 1 || echo 0)"

# 6. The skip switch.
out="$(FW_NO_AGENTS_FF=1 BOX_SSH="$T/fakessh" FW_AGENTS_DIR="$A" bash "$here/agents-ff.sh" 2>&1)"
code=$?
ok skip-exit0 "FW_NO_AGENTS_FF exits 0" "$([ "$code" = 0 ] && echo 1 || echo 0)"
ok skip-says-so "FW_NO_AGENTS_FF says it skipped" "$(has 'skipped')"

# 7. A missing Mac dir pulls nothing and says so, rather than pulling blind.
out="$(BOX_SSH="$T/fakessh" FW_AGENTS_DIR="$T/nope" bash "$here/agents-ff.sh" 2>&1)"
code=$?
ok nomac-exit0 "a missing mac dir exits 0" "$([ "$code" = 0 ] && echo 1 || echo 0)"
ok nomac-says-why "says there is no target to compare against" "$(has 'no target to compare')"

printf '%s cases, %s\n' "$n" "$([ "$rc" = 0 ] && echo PASS || echo FAIL)"
exit "$rc"

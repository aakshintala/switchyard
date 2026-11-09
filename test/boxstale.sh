#!/usr/bin/env bash
# test-boxstale.sh -- bin/boxstale.sh over a real throwaway git repo.
#
# Why a real repo rather than a stubbed `git`: every case here turns on
# ancestry, and ancestry is the thing a stub would have to fake. The bug this
# suite exists for was a hardcoded consequence list standing in for a varying
# gap; a fake `git log` would be the same mistake one layer down.
#
# The box side IS stubbed, through BOX_SSH, because it is one `rev-parse` read
# and there is nothing to get wrong about it.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
BIN=${FW_TEST_BIN:-$here/../bin}
rc=0
n=0

T="$(mktemp -d "${TMPDIR:-/tmp}/fw-boxstale-XXXXXX")"
trap 'rm -rf "$T"' EXIT

# A stub for $ssh. boxstale calls it as: $ssh -o .. -o .. HOST 'git -C ...'.
# The stub ignores every argument and prints whatever $BOXSHA holds, so a case
# sets the box's HEAD by exporting one variable.
cat > "$T/fakessh" <<'STUB'
#!/usr/bin/env bash
[ -n "${BOXSHA:-}" ] || exit 7
printf '%s\n' "$BOXSHA"
STUB
chmod +x "$T/fakessh"

# A linear repo: c1 -> c2 -> c3, with subjects we can assert on.
A="$T/agents"
mkdir -p "$A"
git -C "$A" init -q
git -C "$A" config user.email t@t
git -C "$A" config user.name t
mk() { # mk <subject>
  echo "$1" >> "$A/f"
  git -C "$A" add f
  git -C "$A" commit -qm "$1"
  git -C "$A" rev-parse HEAD
}
c1="$(mk 'first: the oldest tool')"
c2="$(mk 'fence-grant: a failed lookup holds the claim (#1320)')"
c3="$(mk 'tkt-job: widen the idle window (#1292)')"

# A commit on a side branch, unreachable from main, for the diverged case.
git -C "$A" checkout -q -b side "$c1"
side="$(mk 'side: committed on the box by hand')"
git -C "$A" checkout -q -

run() { # run <boxsha> -> sets out, code
  out="$(BOXSHA="$1" BOX_SSH="$T/fakessh" FW_AGENTS_DIR="$A" bash "$BIN/boxstale.sh" 2>&1)"
  code=$?
}

ok() { # ok <name> <cond-desc> <0|1>
  n=$((n + 1))
  if [ "$3" = 0 ]; then
    printf 'FAIL %s -- %s\n' "$1" "$2"
    printf '%s\n' "$out" | sed 's/^/     | /'
    rc=1
  else
    # One `ok` line per passing case, not just a summary. bin/selftest counts
    # a suite's passes with `grep -c '^ok'`, so a suite that prints only a
    # tally reports "0 passed" and still shows green -- which is exactly what
    # this suite did on its first selftest run, and is indistinguishable from
    # a suite that stopped running cases.
    printf 'ok   %s\n' "$1"
  fi
}

has() { printf '%s\n' "$out" | grep -q -- "$1"; }
lacks() { ! printf '%s\n' "$out" | grep -q -- "$1"; }

# --- matching -----------------------------------------------------------
run "$c3"
ok matching-says-so 'expected "matches this Mac"' "$(has 'matches this Mac' && echo 1 || echo 0)"
ok matching-exits-0 "expected exit 0, got $code" "$([ "$code" = 0 ] && echo 1 || echo 0)"

# --- box one behind: the case the old constant got wrong -----------------
run "$c2"
ok behind-1-counts 'expected "BOX IS BEHIND by 1"' "$(has 'BOX IS BEHIND by 1' && echo 1 || echo 0)"
ok behind-1-names-the-commit 'expected the c3 subject in the gap' \
  "$(has 'widen the idle window' && echo 1 || echo 0)"
# The bug: consequences the box already has must not be claimed. c2 is IN the
# box, so #1320's subject must not appear as something it is missing.
ok behind-1-omits-what-box-has 'expected the c2 subject absent from the gap' \
  "$(lacks 'failed lookup holds the claim' && echo 1 || echo 0)"
ok behind-1-exits-1 "expected exit 1, got $code" "$([ "$code" = 1 ] && echo 1 || echo 0)"

# --- box two behind ------------------------------------------------------
run "$c1"
ok behind-2-counts 'expected "BOX IS BEHIND by 2"' "$(has 'BOX IS BEHIND by 2' && echo 1 || echo 0)"
ok behind-2-names-both 'expected both newer subjects' \
  "$(has 'widen the idle window' && has 'failed lookup holds the claim' && echo 1 || echo 0)"

# --- the box is AHEAD: the old wording called this "BOX IS BEHIND" -------
# Point the Mac at c2 by checking it out, and hand the stub c3.
git -C "$A" checkout -q "$c2"
run "$c3"
ok ahead-says-mac-behind 'expected "THIS MAC IS BEHIND"' "$(has 'THIS MAC IS BEHIND' && echo 1 || echo 0)"
ok ahead-does-not-say-box-behind 'expected no "BOX IS BEHIND"' \
  "$(lacks 'BOX IS BEHIND' && echo 1 || echo 0)"
# And it must not send the owner to pull a box that is ahead.
ok ahead-omits-the-owner-pull 'expected no box pull command' \
  "$(lacks "git -C ~/.agents pull" && echo 1 || echo 0)"
git -C "$A" checkout -q main 2>/dev/null || git -C "$A" checkout -q master

# --- diverged ------------------------------------------------------------
run "$side"
ok diverged-says-so 'expected "DIVERGED"' "$(has 'DIVERGED' && echo 1 || echo 0)"
ok diverged-not-a-missed-pull 'expected the "not a missed pull" line' \
  "$(has 'not a missed pull' && echo 1 || echo 0)"
ok diverged-exits-1 "expected exit 1, got $code" "$([ "$code" = 1 ] && echo 1 || echo 0)"

# --- a box sha this Mac has never seen -----------------------------------
run 0123456789012345678901234567890123456789
ok unknown-says-so 'expected "UNKNOWN COMMIT"' "$(has 'UNKNOWN COMMIT' && echo 1 || echo 0)"
ok unknown-says-fetch 'expected a fetch instruction' "$(has 'fetch --all' && echo 1 || echo 0)"
ok unknown-exits-2 "expected exit 2, got $code" "$([ "$code" = 2 ] && echo 1 || echo 0)"

# --- the box read failing is exit 2, not a false "behind" ----------------
run ''
ok ssh-fail-exits-2 "expected exit 2, got $code" "$([ "$code" = 2 ] && echo 1 || echo 0)"
ok ssh-fail-says-cannot-read 'expected "cannot read the box"' \
  "$(has "cannot read the box" && echo 1 || echo 0)"

# --- no stale constant left ---------------------------------------------
# The whole point of the change. If any of these strings is printed again from
# a literal, it is a claim about the gap that the gap did not make.
run "$c2"
for s in 'STALE-CONFIRM' 'switchyard#1275' 'switchyard#1287' 'Known consequences'; do
  ok "no-constant-$s" "expected $s to be gone" "$(lacks "$s" && echo 1 || echo 0)"
done

if [ "$rc" = 0 ]; then
  echo "boxstale: $n ok"
else
  echo "boxstale: FAILURES above ($n checks)"
fi
exit "$rc"

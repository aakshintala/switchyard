#!/usr/bin/env bash
# Tests for bin/mutant-verdicts, with a stub gh on PATH.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../bin/mutant-verdicts"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-mutant-verdicts.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

export STUB_ROOT="$T"
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "gh $*" >>"$STUB_ROOT/calls.log"
if [ "${1:-} ${2:-}" = "run view" ]; then
  cat "$STUB_ROOT/status"
  exit 0
fi
if [ "${1:-} ${2:-}" = "run download" ]; then
  if [ -e "$STUB_ROOT/dlfail" ]; then
    echo "stub: download failed" >&2
    exit 1
  fi
  dir=""
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--dir" ]; then
      dir="$a"
    fi
    prev="$a"
  done
  [ -n "$dir" ] || { echo "stub: no --dir" >&2; exit 1; }
  cp -r "$STUB_ROOT/fixtures/." "$dir"/
  exit 0
fi
echo "stub gh: unexpected call: $*" >&2
exit 1
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

reset() {
  rm -rf "$T/fixtures" "$T/dlfail"
  mkdir -p "$T/fixtures"
  : >"$T/calls.log"
  printf 'completed' >"$T/status"
}

empty_shard() {
  mkdir -p "$T/fixtures/$1"
  : >"$T/fixtures/$1/caught.txt"
  : >"$T/fixtures/$1/missed.txt"
  : >"$T/fixtures/$1/timeout.txt"
  : >"$T/fixtures/$1/unviable.txt"
}

shard_file() {
  local shard="$1" file="$2"
  shift 2
  mkdir -p "$T/fixtures/$shard"
  touch "$T/fixtures/$shard/$file"
  for line in "$@"; do
    printf '%s\n' "$line" >>"$T/fixtures/$shard/$file"
  done
}

run_script() {
  out="$(bash "$SCRIPT" "$@" 2>"$T/err.txt")"
  rc=$?
}

# --- case a: two shards spanning all four files give the exact sorted list
reset
M_CAUGHT='src/lib.rs:9:1: replace + with - in zeta'
M_MISSED='src/lib.rs:1:24: replace > with >= in f'
M_TIMEOUT='src/a.rs:3:5: replace == with != in mid'
M_UNVIABLE='src/lib.rs:2:1: replace * with / in g'
shard_file mutants-a caught.txt "$M_CAUGHT" ""
shard_file mutants-a missed.txt "$M_MISSED"
: >"$T/fixtures/mutants-a/timeout.txt"
: >"$T/fixtures/mutants-a/unviable.txt"
shard_file mutants-b timeout.txt "$M_TIMEOUT"
printf '%s' "$M_UNVIABLE" >"$T/fixtures/mutants-b/unviable.txt"
: >"$T/fixtures/mutants-b/caught.txt"
: >"$T/fixtures/mutants-b/missed.txt"
printf 'stray\n' >"$T/fixtures/notes.txt"
run_script 123
[ "$rc" = "0" ] || fail "two shards exits 0 (rc=$rc, stderr: $(cat "$T/err.txt"))"
expected="$(printf '%s\t%s\n%s\t%s\n%s\t%s\n%s\t%s' \
  "$M_TIMEOUT" "timeout" \
  "$M_MISSED" "missed" \
  "$M_UNVIABLE" "unviable" \
  "$M_CAUGHT" "caught")"
[ "$out" = "$expected" ] || fail "two shards print the exact sorted list (got: [$out])"
grep -qF "$(printf '%s\tcaught' "$M_CAUGHT")" <<<"$out" || fail "caught word is named"
grep -qF "$(printf '%s\tmissed' "$M_MISSED")" <<<"$out" || fail "missed word is named"
grep -qF "$(printf '%s\ttimeout' "$M_TIMEOUT")" <<<"$out" || fail "timeout word is named"
grep -qF "$(printf '%s\tunviable' "$M_UNVIABLE")" <<<"$out" || fail "unviable word is named"

# --- case b: an identical row in both shards prints once
reset
DUP='src/lib.rs:4:2: replace && with || in both'
empty_shard mutants-a
empty_shard mutants-b
shard_file mutants-a caught.txt "$DUP"
shard_file mutants-b caught.txt "$DUP"
run_script 123
[ "$rc" = "0" ] || fail "duplicate row exits 0 (rc=$rc)"
[ "$out" = "$(printf '%s\tcaught' "$DUP")" ] || fail "duplicate row prints once (got: [$out])"

# --- case c: the same mutant with two verdicts fails and names the mutant
reset
CLASH='src/lib.rs:7:3: replace < with <= in clash'
empty_shard mutants-a
empty_shard mutants-b
shard_file mutants-a caught.txt "$CLASH"
shard_file mutants-b missed.txt "$CLASH"
run_script 123
[ "$rc" = "1" ] || fail "conflicting verdicts exit 1 (rc=$rc)"
[ -z "$out" ] || fail "conflicting verdicts print nothing on stdout"
grep -q 'mutant-verdicts:' "$T/err.txt" || fail "conflicting verdicts explain on stderr"
grep -qF "$CLASH" "$T/err.txt" || fail "conflicting verdicts name the mutant"

# --- case d: an unfinished run fails before any download
reset
empty_shard mutants-a
shard_file mutants-a missed.txt "$M_MISSED"
printf 'in_progress' >"$T/status"
run_script 123
[ "$rc" = "1" ] || fail "in-progress run exits 1 (rc=$rc)"
[ -z "$out" ] || fail "in-progress run prints nothing on stdout"
grep -q 'run download' "$T/calls.log" && fail "in-progress run downloads nothing"

# --- case e: a failed download, and a download with no mutants-* dir, fail
reset
empty_shard mutants-a
shard_file mutants-a caught.txt "$M_CAUGHT"
touch "$T/dlfail"
run_script 123
[ "$rc" = "1" ] || fail "failed download exits 1 (rc=$rc)"
[ -z "$out" ] || fail "failed download prints nothing on stdout"
grep -q 'mutant-verdicts:' "$T/err.txt" || fail "failed download explains on stderr"
reset
printf 'stray\n' >"$T/fixtures/notes.txt"
run_script 123
[ "$rc" = "1" ] || fail "missing mutants-* dir exits 1 (rc=$rc)"
[ -z "$out" ] || fail "missing mutants-* dir prints nothing on stdout"

# --- case f: a shard missing timeout.txt fails with no partial list
reset
empty_shard mutants-a
shard_file mutants-a missed.txt "$M_MISSED"
mkdir -p "$T/fixtures/mutants-b"
: >"$T/fixtures/mutants-b/caught.txt"
: >"$T/fixtures/mutants-b/missed.txt"
: >"$T/fixtures/mutants-b/unviable.txt"
run_script 123
[ "$rc" = "1" ] || fail "missing timeout.txt exits 1 (rc=$rc)"
[ -z "$out" ] || fail "missing timeout.txt prints nothing on stdout"
grep -q 'mutant-verdicts:' "$T/err.txt" || fail "missing timeout.txt explains on stderr"

# --- case g: empty files everywhere give exit 0 with empty stdout
reset
empty_shard mutants-a
empty_shard mutants-b
run_script 123
[ "$rc" = "0" ] || fail "empty shards exit 0 (rc=$rc)"
[ -z "$out" ] || fail "empty shards print nothing (got: [$out])"

# --- case h: --repo reaches both gh calls; the download carries run and pattern
reset
empty_shard mutants-a
shard_file mutants-a caught.txt "$M_CAUGHT"
run_script 123 --repo o/n
[ "$rc" = "0" ] || fail "--repo run exits 0 (rc=$rc)"
grep -qF 'run view 123 --repo o/n' "$T/calls.log" || fail "--repo reaches run view"
grep -qF 'run download 123 --repo o/n --pattern mutants-*' "$T/calls.log" || fail "--repo, run and pattern reach run download"
: >"$T/calls.log"
run_script 123
[ "$rc" = "0" ] || fail "bare run exits 0 (rc=$rc)"
grep -qF -- '--repo' "$T/calls.log" && fail "bare run passes no --repo"

# --- case i: bad usage exits 2 with usage on stderr
run_script
[ "$rc" = "2" ] || fail "no run id exits 2 (rc=$rc)"
grep -qF 'usage: mutant-verdicts <run> [--repo OWNER/NAME]' "$T/err.txt" || fail "no run id prints usage"
run_script abc
[ "$rc" = "2" ] || fail "non-numeric id exits 2 (rc=$rc)"
grep -qF 'usage: mutant-verdicts <run> [--repo OWNER/NAME]' "$T/err.txt" || fail "non-numeric id prints usage"
run_script 123 --bogus
[ "$rc" = "2" ] || fail "unknown flag exits 2 (rc=$rc)"
grep -qF 'usage: mutant-verdicts <run> [--repo OWNER/NAME]' "$T/err.txt" || fail "unknown flag prints usage"
run_script 123 456
[ "$rc" = "2" ] || fail "two ids exit 2 (rc=$rc)"
grep -qF 'usage: mutant-verdicts <run> [--repo OWNER/NAME]' "$T/err.txt" || fail "two ids print usage"

# --- case j: the download dir is gone after success and after failure
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"
reset
empty_shard mutants-a
shard_file mutants-a caught.txt "$M_CAUGHT"
run_script 123
[ "$rc" = "0" ] || fail "cleanup success run exits 0 (rc=$rc)"
ls "$T/tmp" | grep -q 'mutant-verdicts' && fail "cleanup removes the download dir after success"
reset
touch "$T/dlfail"
run_script 123
[ "$rc" = "1" ] || fail "cleanup failure run exits 1 (rc=$rc)"
ls "$T/tmp" | grep -q 'mutant-verdicts' && fail "cleanup removes the download dir after failure"

# --- case k: a mutant line with spaces, arrows and a colon survives verbatim
reset
TRICKY='src/main.rs:10:5: replace -> with => in foo: bar baz > qux'
empty_shard mutants-a
shard_file mutants-a missed.txt "$TRICKY"
run_script 123
[ "$rc" = "0" ] || fail "tricky line exits 0 (rc=$rc)"
[ "$out" = "$(printf '%s\tmissed' "$TRICKY")" ] || fail "tricky line survives verbatim (got: [$out])"

echo "mutant-verdicts: all cases passed"

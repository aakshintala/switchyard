#!/usr/bin/env bash
# Tests for bin/plan-check. Exits non-zero on the first failed case.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/../bin/plan-check"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-plan-check.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# Fixture repo: two commits. BASE1 has no src/later.rs; BASE2 (HEAD) has it.
R="$T/repo"
mkdir -p "$R/src" "$R/docs" "$R/crates/a" "$R/crates/b" "$R/cfg" "$T/empty"
printf 'pub fn make_widget() {}\npub struct WidgetThing;\n' >"$R/src/lib.rs"
printf '# guide\n' >"$R/docs/guide.md"
printf 'a\n' >"$R/crates/a/x.rs"
printf 'b\n' >"$R/crates/b/x.rs"
printf 'x = 1\n' >"$R/cfg/unique.toml"
git -C "$R" init -q
git -C "$R" add -A
git -C "$R" -c user.name=test -c user.email=test@example.com commit -q -m one
BASE1="$(git -C "$R" rev-parse HEAD)"
printf 'later\n' >"$R/src/later.rs"
git -C "$R" add -A
git -C "$R" -c user.name=test -c user.email=test@example.com commit -q -m two
BASE2="$(git -C "$R" rev-parse HEAD)"

# mkplan NAME BODY: writes a plan whose Base is BASE2. The body starts on line 4.
mkplan() {
  printf '# Plan: #1 test\nBase: %s\n\n%b' "$BASE2" "$2" >"$T/$1.md"
  printf '%s' "$T/$1.md"
}

# run ARGS...: sets out (stdout) and code (exit status)
run() {
  out="$(bash "$CHECK" "$@" 2>"$T/err.txt")"
  code=$?
}

# expect_clean NAME PLAN: exit 0, nothing on stdout or stderr
expect_clean() {
  run "$2" --cwd "$R"
  [ "$code" = 0 ] || fail "$1: exits 0, got $code [$out]"
  [ -z "$out" ] || fail "$1: nothing on stdout, got [$out]"
  [ ! -s "$T/err.txt" ] || fail "$1: nothing on stderr"
}

# expect_problems NAME PLAN WANT: exit 1, stdout is WANT (printf %b)
expect_problems() {
  run "$2" --cwd "$R"
  [ "$code" = 1 ] || fail "$1: exits 1, got $code"
  want="$(printf '%b' "$3")"
  [ "$out" = "$want" ] || fail "$1: got [$out], want [$want]"
}

# expect_code NAME CODE ARGS...: exit status only
expect_code() {
  name="$1"; want="$2"; shift 2
  run "$@"
  [ "$code" = "$want" ] || fail "$name: exits $want, got $code"
  [ -z "$out" ] || fail "$name: nothing on stdout"
}

# 1. a clean plan: resolved paths, a line range, a basename, symbols, a path in Rulings
clean="$(mkplan clean '## Files\n- `src/lib.rs`\n- `cfg/unique.toml`\n\n## Rulings\nKeep `docs/guide.md` and call `make_widget()` on `WidgetThing`.\n\n## Tasks\n1. Edit `src/lib.rs:1-2` and `unique.toml`.\n')"
expect_clean "clean plan" "$clean"

# 2. a missing path outside Files
expect_problems "missing path" "$(mkplan missing '## Rulings\nSee `src/nope.rs`.\n')" \
  'missing path: src/nope.rs (line 5)'

# 3. a path on a line with the word new is exempt; a task line needs new too
expect_clean "new exempts a Files path and its task line" "$(mkplan newok '## Files\n- `src/brand.rs` (New file)\n\n## Tasks\n1. Write new `src/brand.rs` with `WidgetThing`.\n')"

# 3a. a new task path that is not in Files is still checked by check 2
expect_problems "new task path outside Files" "$(mkplan newout '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Create new `bin/brand-new-check`.\n')" \
  'outside Files: bin/brand-new-check (line 8)'

# 4. new as part of a longer word does not exempt
expect_problems "newer is not new" "$(mkplan newer '## Files\n- `src/nope.rs` (newer)\n')" \
  'missing path: src/nope.rs (line 5)'

# 5. an ambiguous suffix (two files end in /x.rs) resolves but stays out of the Files check
expect_clean "ambiguous suffix is not outside Files" "$(mkplan ambig '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Edit `x.rs`.\n')"

# 6. a task path outside Files
expect_problems "task path outside Files" "$(mkplan outside '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Edit `docs/guide.md` and `src/lib.rs`.\n')" \
  'outside Files: docs/guide.md (line 8)'

# 7. the Red commit section is checked the same way
expect_problems "red commit outside Files" "$(mkplan red '## Files\n- `src/lib.rs`\n\n## Red commit\n`docs/guide.md`\n')" \
  'outside Files: docs/guide.md (line 8)'

# 8. the same token printed once, on its first line
expect_problems "problem printed once per token" "$(mkplan once '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Edit `docs/guide.md:3`.\n2. Edit `docs/guide.md`.\n')" \
  'outside Files: docs/guide.md (line 8)'

# 9. fenced blocks and the Gate section are skipped
expect_clean "fence and Gate skipped" "$(mkplan skip '## Files\n- `src/lib.rs`\n\n## Rulings\n```\nsee `src/gone.rs` and `src/gone2.rs`\n```\n\n## Gate\n`src/gone.rs`\n')"

# 10. symbols: unknown ones are reported, new ones and existing ones pass
expect_problems "symbols" "$(mkplan syms '## Rulings\nCall `NoSuchThing()` and `Frob_Thing`.\nAdd `Brand_New` (new).\nUse `make_widget()` and `make_widget()` again.\n')" \
  'unknown symbol: NoSuchThing() (line 5)\nunknown symbol: Frob_Thing (line 5)'

# 11. a plain lowercase word or a prose token is not a symbol or a path
expect_clean "plain words are not checked" "$(mkplan words '## Rulings\nUse `cargo`, `run` and `bash test/run` as written.\n')"

# 11a. skip rule: placeholders, globs, spaces, bare extensions and `/`, `.`, `..` are not checked
expect_clean "skipped tokens" "$(mkplan skiptok '## Rulings\n`providers/<name>.lua` `tests/*.json` `a b/x.rs` `.lua` `/` `.` `..` `../x`\n')"

# 11b. suffix rule: a path matching nothing is reported only under a top-level entry
expect_problems "suffix: top-level zero match is missing" "$(mkplan topzero '## Rulings\nSee `docs/nope.md` and `providers/acme.json`.\n')" \
  'missing path: docs/nope.md (line 5)'
expect_clean "suffix: non-top-level zero match is skipped" "$(mkplan fixture '## Rulings\nSee `providers/acme.json`.\n')"
expect_clean "suffix: a Files suffix resolves for a task" "$(mkplan suffixok '## Files\n- `unique.toml`\n\n## Tasks\n1. Edit `cfg/unique.toml`.\n')"

# 11c. brace rule: one group expands per alternative; two groups are skipped
expect_problems "braces: each alternative checked" "$(mkplan braces '## Files\n- `src/{lib,later}.rs`\n\n## Rulings\nSee `src/{nope,lib}.rs` and `{a,b}/{c,d}.rs`.\n')" \
  'missing path: src/nope.rs (line 8)'
expect_problems "braces: an alternative outside Files" "$(mkplan bouts '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Edit `src/{lib,later}.rs`.\n')" \
  'outside Files: src/later.rs (line 8)'

# 11d. path::symbol rule: the path and the symbol are checked separately
expect_problems "path::symbol: unknown symbol" "$(mkplan split1 '## Rulings\n`src/lib.rs::make_widget` and `src/lib.rs::NoSuch`.\n')" \
  'unknown symbol: NoSuch (line 5)'
expect_problems "path::symbol: missing path" "$(mkplan split2 '## Rulings\n`src/nope.rs::make_widget`.\n')" \
  'missing path: src/nope.rs (line 5)'

# 11e. directory rule: a directory resolves by its trailing slash; Files covers it by prefix
expect_clean "directory covered by a Files path" "$(mkplan dirok '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Edit `src/`.\n')"
expect_problems "directory not covered by Files" "$(mkplan dirout '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Edit `src/` and `docs/`.\n')" \
  'outside Files: docs/ (line 8)'

# 11f. symbol rule: Tasks is not checked; Red commit is; a backticked token on a new line exempts
expect_clean "symbols in Tasks are not checked" "$(mkplan tasksym '## Tasks\n1. Add `NoSuchThing()`.\n')"
expect_problems "symbols in Red commit are checked" "$(mkplan redsym '## Red commit\n`Frob_Thing`\n')" \
  'unknown symbol: Frob_Thing (line 5)'
expect_clean "new line exempts a symbol in a backticked token" "$(mkplan newsym '## Rulings\nAdd new `src/x.rs::Brand_New`.\nCall `Brand_New`.\n')"

# 12. --base overrides the Base line: src/later.rs is absent at BASE1
later="$(mkplan later '## Files\n- `src/later.rs`\n')"
expect_clean "Base line resolves src/later.rs" "$later"
run "$later" --base "$BASE1" --cwd "$R"
[ "$code" = 1 ] || fail "--base BASE1 exits 1, got $code"
[ "$out" = 'missing path: src/later.rs (line 5)' ] || fail "--base BASE1: got [$out]"

# 13. --cwd defaults to the current directory
out="$(cd "$R" && bash "$CHECK" "$clean")" || fail "default cwd exits 0"
[ -z "$out" ] || fail "default cwd prints nothing"

# 14. exit 2: bad usage, unreadable plan, no Base line, bad REV, not a repo
expect_code "no args" 2
expect_code "-h" 2 -h
expect_code "--help" 2 --help
expect_code "two plan files" 2 "$clean" "$clean"
expect_code "--base without a value" 2 "$clean" --base
expect_code "unknown option" 2 "$clean" --bogus
expect_code "missing plan file" 2 "$T/does-not-exist.md" --cwd "$R"
noline="$T/noline.md"
printf '# Plan\n\n## Files\n- `src/lib.rs`\n' >"$noline"
expect_code "no Base line and no --base" 2 "$noline" --cwd "$R"
expect_code "--base is not a commit" 2 "$clean" --base nosuchrev --cwd "$R"
expect_code "--cwd is not a repo" 2 "$clean" --cwd "$T/empty"

echo "plan-check: all cases passed"

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
mkdir -p "$R/src" "$R/docs" "$R/crates/a" "$R/crates/b" "$R/cfg" "$R/xtask/tests/class_data" "$T/empty"
printf 'pub fn make_widget() {}\npub struct WidgetThing;\n' >"$R/src/lib.rs"
printf '# guide\n' >"$R/docs/guide.md"
printf 'a\n' >"$R/crates/a/x.rs"
printf 'b\n' >"$R/crates/b/x.rs"
printf 'x = 1\n' >"$R/cfg/unique.toml"
printf '{}\n' >"$R/xtask/tests/class_data/9v45-session-list.json"
git -C "$R" init -q
git -C "$R" add -A
git -C "$R" -c user.name=test -c user.email=test@example.com commit -q -m one
BASE1="$(git -C "$R" rev-parse HEAD)"
printf 'later\n' >"$R/src/later.rs"
printf 'make_widget();\nWidgetThing;\n' >"$R/src/caller.rs"
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

# Citations check the symbol at the base, including a single line and a range.
expect_clean "symbol at cited line" "$(mkplan citeok '## Files\n- `src/lib.rs`\n\n## Rulings\n`make_widget()` at `src/lib.rs:1`.\n`src/lib.rs:1-2` holds `WidgetThing`.\n')"
expect_problems "symbol absent from cited line" "$(mkplan citebad '## Rulings\n`make_widget()` at `src/lib.rs:2`.\n')" \
  'missing symbol: src/lib.rs:2 does not contain make_widget(): correct the citation'
expect_problems "symbol absent from cited range" "$(mkplan rangebad '## Rulings\n`src/lib.rs:1-2` holds `MissingThing`.\n')" \
  'missing symbol: src/lib.rs:1-2 does not contain MissingThing: correct the citation'

expect_clean "two adjacent citation pairs" "$(mkplan citepairs '## Rulings\n`make_widget()` at `src/lib.rs:1` and `WidgetThing` at `src/lib.rs:2`.\n')"
printf 'changed working tree\n' >"$R/src/lib.rs"
expect_clean "citations read the base" "$(mkplan citebase '## Rulings\n`make_widget()` at `src/lib.rs:1`.\n')"
git -C "$R" checkout -q -- src/lib.rs

# Quoted doc sections must be actual headings, not just text in the file.
expect_clean "doc heading exists" "$(mkplan headingok '## Rulings\nSee `docs/guide.md`, "guide".\n')"
expect_problems "doc heading missing" "$(mkplan headingbad '## Rulings\nSee `docs/guide.md`, "Order".\n')" \
  'missing heading: docs/guide.md, "Order": correct the citation'

# Changed symbols expose sites outside Files as warnings, never errors.
run "$(mkplan sweep '## Files\n- `src/lib.rs::make_widget`\n\n## Tasks\nChange `WidgetThing` in `src/lib.rs`.\n')" --cwd "$R"
[ "$code" = 0 ] || fail "completeness warning exits 0, got $code"
[ -z "$out" ] || fail "completeness warning is not an error"
grep -Fq 'warning: make_widget occurs outside Files: src/caller.rs' "$T/err.txt" || fail "warning names call site"
grep -Fq 'warning: WidgetThing occurs outside Files: src/caller.rs' "$T/err.txt" || fail "warning names construction site"
expect_clean "Files cover suppresses warning" "$(mkplan sweeppass '## Files\n- `src/`\n\n## Tasks\nChange `WidgetThing` in `src/lib.rs`.\n')"
run "$(mkplan sweepfail '## Files\n- `src/lib.rs::make_widget`\n\n## Rulings\nSee `src/nope.rs`.\n')" --cwd "$R"
[ "$code" = 1 ] || fail "completeness warning preserves error exit"
grep -Fq 'warning: make_widget occurs outside Files: src/caller.rs' "$T/err.txt" || fail "warning accompanies error"

# 2. a missing path outside Files
expect_problems "missing path" "$(mkplan missing '## Rulings\nSee `src/nope.rs`.\n')" \
  'missing path: src/nope.rs (line 5): does not exist on the base; correct the path, or mark the line (new) if the plan creates it, or (removed) if it deletes it'

# 3. a path on a line with the word new is exempt; a task line needs new too
expect_clean "new exempts a Files path and its task line" "$(mkplan newok '## Files\n- `src/brand.rs` (New file)\n\n## Tasks\n1. Write new `src/brand.rs` with `WidgetThing`.\n')"

# 3b. new paths close to a base filename need confirmation; new-confirmed bypasses it
expect_problems "new path close to a base filename" "$(mkplan nearnew '## Files\n- `xtask/tests/class_data/9v45-sessions-list.json` (new)\n')" \
  'new path xtask/tests/class_data/9v45-sessions-list.json is close to existing xtask/tests/class_data/9v45-session-list.json: confirm new, or correct it'
expect_clean "new-confirmed path close to a base filename" "$(mkplan nearconfirmed '## Files\n- `xtask/tests/class_data/9v45-sessions-list.json` (new-confirmed)\n')"
expect_clean "new path without a close base filename" "$(mkplan farnew '## Files\n- `src/brand.rs` (new)\n')"
expect_problems "new path already exists at base" "$(mkplan existingnew '## Files\n- `src/lib.rs` (new)\n')" \
  'new path src/lib.rs already exists at base: drop the new mark'

# 3a. a new task path that is not in Files is still checked by check 2
expect_problems "new task path outside Files" "$(mkplan newout '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Create new `bin/brand-new-check`.\n')" \
  'outside Files: bin/brand-new-check (line 8): add it to Files, or mark the line (reads) if the task only reads it'

# 4. new as part of a longer word does not exempt
expect_problems "newer is not new" "$(mkplan newer '## Files\n- `src/nope.rs` (newer)\n')" \
  'missing path: src/nope.rs (line 5): does not exist on the base; correct the path, or mark the line (new) if the plan creates it, or (removed) if it deletes it'

# 5. an ambiguous suffix (two files end in /x.rs) resolves but stays out of the Files check
expect_clean "ambiguous suffix is not outside Files" "$(mkplan ambig '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Edit `x.rs`.\n')"

# 6. a task path outside Files
expect_problems "task path outside Files" "$(mkplan outside '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Edit `docs/guide.md` and `src/lib.rs`.\n')" \
  'outside Files: docs/guide.md (line 8): add it to Files, or mark the line (reads) if the task only reads it'

# 7. the Red commit section is checked the same way
expect_problems "red commit outside Files" "$(mkplan red '## Files\n- `src/lib.rs`\n\n## Red commit\n`docs/guide.md`\n')" \
  'outside Files: docs/guide.md (line 8): add it to Files, or mark the line (reads) if the task only reads it'

# 8. the same token printed once, on its first line
expect_problems "problem printed once per token" "$(mkplan once '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Edit `docs/guide.md:3`.\n2. Edit `docs/guide.md`.\n')" \
  'outside Files: docs/guide.md (line 8): add it to Files, or mark the line (reads) if the task only reads it'

# 9. fenced blocks and the Gate section are skipped
expect_clean "fence and Gate skipped" "$(mkplan skip '## Files\n- `src/lib.rs`\n\n## Rulings\n```\nsee `src/gone.rs` and `src/gone2.rs`\n```\n\n## Gate\n`src/gone.rs`\n')"

# 10. prose symbols are never checked: backticked tokens outside Files pass
expect_clean "symbols in prose pass" "$(mkplan syms '## Rulings\nCall `NoSuchThing()` and `Frob_Thing`.\nAdd `Brand_New` (new).\nUse `make_widget()` and `make_widget()` again.\n')"

# 10a. the `example` word means nothing to the tools (see #443): prose lines
# are clean either way, and an example line with a missing path still reports it
expect_clean "example prose lines pass" "$(mkplan exampleok '## Rulings\nAn example `c_history` value.\n')"
expect_clean "unmarked symbol passes" "$(mkplan exampleno '## Rulings\nThe `c_history` value.\n')"
expect_problems "example does not exempt a missing path" "$(mkplan examplepath '## Rulings\nAn example `src/nope.rs`.\n')" \
  'missing path: src/nope.rs (line 5): does not exist on the base; correct the path, or mark the line (new) if the plan creates it, or (removed) if it deletes it'

# 11. a plain lowercase word or a prose token is not a symbol or a path
expect_clean "plain words are not checked" "$(mkplan words '## Rulings\nUse `cargo`, `run` and `bash test/run` as written.\n')"

# 11a. skip rule: placeholders, globs, spaces, bare extensions and `/`, `.`, `..` are not checked
expect_clean "skipped tokens" "$(mkplan skiptok '## Rulings\n`providers/<name>.lua` `tests/*.json` `a b/x.rs` `.lua` `/` `.` `..` `../x`\n')"

# 11b. suffix rule: a path matching nothing is reported only under a top-level entry
expect_problems "suffix: top-level zero match is missing" "$(mkplan topzero '## Rulings\nSee `docs/nope.md` and `providers/acme.json`.\n')" \
  'missing path: docs/nope.md (line 5): does not exist on the base; correct the path, or mark the line (new) if the plan creates it, or (removed) if it deletes it'
expect_clean "suffix: non-top-level zero match is skipped" "$(mkplan fixture '## Rulings\nSee `providers/acme.json`.\n')"
expect_clean "suffix: a Files suffix resolves for a task" "$(mkplan suffixok '## Files\n- `unique.toml`\n\n## Tasks\n1. Edit `cfg/unique.toml`.\n')"

# 11c. brace rule: one group expands per alternative; two groups are skipped
expect_problems "braces: each alternative checked" "$(mkplan braces '## Files\n- `src/{lib,later}.rs`\n\n## Rulings\nSee `src/{nope,lib}.rs` and `{a,b}/{c,d}.rs`.\n')" \
  'missing path: src/nope.rs (line 8): does not exist on the base; correct the path, or mark the line (new) if the plan creates it, or (removed) if it deletes it'
expect_problems "braces: an alternative outside Files" "$(mkplan bouts '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Edit `src/{lib,later}.rs`.\n')" \
  'outside Files: src/later.rs (line 8): add it to Files, or mark the line (reads) if the task only reads it'

# 11d. path::symbol checks both halves.
expect_clean "path::symbol exists" "$(mkplan splitok '## Rulings\n`src/lib.rs::make_widget`.\n')"
expect_problems "path::symbol missing" "$(mkplan split1 '## Rulings\n`src/lib.rs::NoSuch`.\n')" \
  'missing symbol: src/lib.rs::NoSuch does not contain NoSuch: correct the citation'
expect_problems "path::symbol: missing path" "$(mkplan split2 '## Rulings\n`src/nope.rs::make_widget`.\n')" \
  'missing path: src/nope.rs (line 5): does not exist on the base; correct the path, or mark the line (new) if the plan creates it, or (removed) if it deletes it'

# 11e. directory rule: a directory resolves by its trailing slash; Files covers it by prefix
expect_clean "directory covered by a Files path" "$(mkplan dirok '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Edit `src/`.\n')"
expect_problems "directory not covered by Files" "$(mkplan dirout '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Edit `src/` and `docs/`.\n')" \
  'outside Files: docs/ (line 8): add it to Files, or mark the line (reads) if the task only reads it'

# 11f. symbol rule: prose symbols are never checked, in any section
expect_clean "symbols in Tasks are not checked" "$(mkplan tasksym '## Tasks\n1. Add `NoSuchThing()`.\n')"
expect_clean "symbols in Red commit are not checked" "$(mkplan redsym '## Red commit\n`Frob_Thing`\n')"
expect_clean "new line exempts a symbol in a backticked token" "$(mkplan newsym '## Rulings\nAdd new `src/x.rs::Brand_New`.\nCall `Brand_New`.\n')"

# 11g. read mark: a task path on a line with reads/read-only/fixture stays out of check 2, but must still resolve
expect_clean "reads mark exempts task paths from Files" "$(mkplan readsok '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Reads `docs/guide.md` for context.\n2. Uses `cfg/unique.toml` (READ-ONLY).\n3. Loads `src/lib.rs` as fixture.\n')"
expect_problems "read mark does not exempt a missing path" "$(mkplan readmissing '## Tasks\n1. Reads `src/nope.rs` for context.\n')" \
  'missing path: src/nope.rs (line 5): does not exist on the base; correct the path, or mark the line (new) if the plan creates it, or (removed) if it deletes it'

# 11h. removed mark: like new, exempts missing paths; check 2 still applies
expect_clean "removed words exempt missing paths" "$(mkplan removedpaths '## Rulings\nRemoved `src/a.rs`.\nRemove `src/b.rs`.\nDeleted `src/c.rs`.\nDelete `src/d.rs`.\n')"
expect_problems "removed task path outside Files" "$(mkplan removedout '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Removed `src/brand.rs`.\n')" \
  'outside Files: src/brand.rs (line 8): add it to Files, or mark the line (reads) if the task only reads it'

# 11i. problem lines name the fix they accept
expect_problems "problem lines name the fix" "$(mkplan fixes '## Files\n- `src/lib.rs`\n\n## Rulings\nSee `src/nope.rs`.\nCall `Frob_Thing`.\n\n## Tasks\n1. Edit `docs/guide.md`.\n')" \
  'missing path: src/nope.rs (line 8): does not exist on the base; correct the path, or mark the line (new) if the plan creates it, or (removed) if it deletes it\noutside Files: docs/guide.md (line 12): add it to Files, or mark the line (reads) if the task only reads it'

# 10b. prose holds a camelCase token and a test name; a Files path still fails
expect_clean "camelCase and test names in prose pass" "$(mkplan prose101 '## Files\n- `src/lib.rs`\n\n## Rulings\nCall `parseHeader` with `test_handles_empty_files` on `Shape::Round`.\n')"
expect_problems "a bad path in Files still fails" "$(mkplan prose10b '## Files\n- `src/lib.rs`\n- `src/nope.rs`\n\n## Rulings\nCall `parseHeader` with `test_handles_empty_files` on `Shape::Round`.\n')" \
  'missing path: src/nope.rs (line 6): does not exist on the base; correct the path, or mark the line (new) if the plan creates it, or (removed) if it deletes it'

# 11j. line lists: a comma list of numbers and ranges is lines of the file (see #462)
expect_clean "comma list on a Files path" "$(mkplan linelist '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Edit `src/lib.rs:1,2`.\n')"
expect_clean "mixed range and number list on a Files path" "$(mkplan linemix '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Edit `src/lib.rs:1-2,5`.\n')"
expect_problems "comma list on a missing path names the path" "$(mkplan linemissing '## Rulings\nSee `src/nope.rs:1,2`.\n')" \
  'missing path: src/nope.rs (line 5): does not exist on the base; correct the path, or mark the line (new) if the plan creates it, or (removed) if it deletes it'

# 11k. Files directory and glob entries cover task paths (see #462)
expect_clean "Files directory covers a task path under it" "$(mkplan dircover '## Files\n- `src/`\n\n## Tasks\n1. Edit `src/lib.rs`.\n')"
expect_problems "Files directory does not cover a path outside it" "$(mkplan diroutside '## Files\n- `src/`\n\n## Tasks\n1. Edit `docs/guide.md`.\n')" \
  'outside Files: docs/guide.md (line 8): add it to Files, or mark the line (reads) if the task only reads it'
expect_clean "Files glob covers a matching task path" "$(mkplan globcover '## Files\n- `src/*.rs`\n\n## Tasks\n1. Edit `src/lib.rs`.\n')"
expect_problems "Files glob does not cover a non-matching path" "$(mkplan globoutside '## Files\n- `src/*.rs`\n\n## Tasks\n1. Edit `docs/guide.md`.\n')" \
  'outside Files: docs/guide.md (line 8): add it to Files, or mark the line (reads) if the task only reads it'

# 12. --base overrides the Base line: src/later.rs is absent at BASE1
later="$(mkplan later '## Files\n- `src/later.rs`\n')"
expect_clean "Base line resolves src/later.rs" "$later"
run "$later" --base "$BASE1" --cwd "$R"
[ "$code" = 1 ] || fail "--base BASE1 exits 1, got $code"
[ "$out" = 'missing path: src/later.rs (line 5): does not exist on the base; correct the path, or mark the line (new) if the plan creates it, or (removed) if it deletes it' ] || fail "--base BASE1: got [$out]"

# 12a. each problem names the mark it needs: (new) for a missing path, (reads) for an outside Files task path
run "$(mkplan marknew_ '## Rulings\nSee `src/nope.rs`.\n')" --cwd "$R"
case "$out" in *"missing path: src/nope.rs"*"(new)"*) ;; *) fail "missing path names (new): got [$out]" ;; esac
run "$(mkplan markreads_ '## Files\n- `src/lib.rs`\n\n## Tasks\n1. Edit `docs/guide.md`.\n')" --cwd "$R"
case "$out" in *"(reads)"*) ;; *) fail "outside Files names (reads): got [$out]" ;; esac

# 13. --cwd defaults to the current directory
out="$(cd "$R" && bash "$CHECK" "$clean")" || fail "default cwd exits 0"
[ -z "$out" ] || fail "default cwd prints nothing"

# 13b. without --cwd, a plan file inside a checkout uses that checkout,
# even when run from a directory that is not a git checkout (issue #1083)
cp "$clean" "$R/plan-in-repo.md"
out="$(cd "$T/empty" && bash "$CHECK" "$R/plan-in-repo.md" 2>"$T/err-13b.txt")"; code=$?
[ "$code" = 0 ] || fail "plan in a checkout without --cwd exits 0, got $code [$out]"
[ -z "$out" ] || fail "plan in a checkout without --cwd prints nothing"
[ ! -s "$T/err-13b.txt" ] || fail "plan in a checkout without --cwd: nothing on stderr"
# a plan file outside any checkout still fails naming --cwd
printf '# Plan: #1 test\nBase: %s\n\n## Files\n- `src/lib.rs`\n' "$BASE2" >"$T/empty-plan.md"
out="$(cd "$T/empty" && bash "$CHECK" "$T/empty-plan.md" 2>"$T/err-13c.txt")"; code=$?
[ "$code" = 2 ] || fail "plan outside a checkout exits 2, got $code"
grep -q -- "--cwd" "$T/err-13c.txt" || fail "plan outside a checkout names --cwd"
grep -Fq 'is not a git repository; pass --cwd <worktree>' "$T/err-13c.txt" || fail "plan outside a checkout identifies the missing --cwd"

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
backtick="$T/backtick.md"
printf '# Plan: #1 test\nBase: `%s`\n\n## Files\n- `src/later.rs`\n' "$BASE2" >"$backtick"
expect_clean "backticked Base line resolves src/later.rs" "$backtick"
expect_code "--base is not a commit" 2 "$clean" --base nosuchrev --cwd "$R"
grep -q -- "--cwd DIR" "$T/err.txt" || fail "--base is not a commit: stderr names --cwd DIR"
expect_code "--cwd is not a repo" 2 "$clean" --cwd "$T/empty"

# 15. the shared lib is sourced from beside the script: a relative-path run
# from the repo root exits 0, and a copy with no lib/ beside it exits 2.
out="$(cd "$SCRIPT_DIR/.." && bash bin/plan-check "$clean" --cwd "$R" 2>"$T/err.txt")"; code=$?
[ "$code" = 0 ] || fail "relative path exits 0, got $code [$out]"
[ -z "$out" ] || fail "relative path prints nothing"
[ ! -s "$T/err.txt" ] || fail "relative path: nothing on stderr"
mkdir -p "$T/nolib"
cp "$SCRIPT_DIR/../bin/plan-check" "$T/nolib/plan-check"
out="$(bash "$T/nolib/plan-check" "$clean" --cwd "$R" 2>"$T/err.txt")"; code=$?
[ "$code" = 2 ] || fail "missing lib exits 2, got $code"
[ -z "$out" ] || fail "missing lib: nothing on stdout"
grep -q "lib/plan-tokens.sh" "$T/err.txt" || fail "missing lib: stderr names lib/plan-tokens.sh"

# 16. Outcome: measurement and Outcome: pr pass; any other value fails
printf '# Plan: #1 test\nBase: %s\nOutcome: measurement\n\n## Files\n- `src/lib.rs`\n' "$BASE2" >"$T/outcome-measure.md"
expect_clean "Outcome measurement passes" "$T/outcome-measure.md"
printf '# Plan: #1 test\nBase: %s\nOutcome: pr\n\n## Files\n- `src/lib.rs`\n' "$BASE2" >"$T/outcome-pr.md"
expect_clean "Outcome pr passes" "$T/outcome-pr.md"
printf '# Plan: #1 test\nBase: %s\nOutcome: other\n\n## Files\n- `src/lib.rs`\n' "$BASE2" >"$T/outcome-other.md"
expect_problems "Outcome other fails" "$T/outcome-other.md" \
  'bad Outcome: other (line 3): write Outcome: pr or Outcome: measurement'
printf '# Plan: #1 test\nBase: %s\nOutcome: \n\n## Files\n- `src/lib.rs`\n' "$BASE2" >"$T/outcome-blank.md"
expect_problems "blank Outcome fails" "$T/outcome-blank.md" \
  'bad Outcome:  (line 3): write Outcome: pr or Outcome: measurement'
printf '# Plan: #1 test\nBase: %s\nOutcome:\n\n## Files\n- `src/lib.rs`\n' "$BASE2" >"$T/outcome-bare.md"
expect_problems "bare Outcome fails" "$T/outcome-bare.md" \
  'bad Outcome:  (line 3): write Outcome: pr or Outcome: measurement'

echo "plan-check: all cases passed"

#!/usr/bin/env bash
# Tests for bin/plan-sweep. Exits non-zero on the first failed case.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$SCRIPT_DIR/../bin/plan-sweep"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-plan-sweep.XXXXXX")"
mkdir -p "$T/home" "$T/tmp"
export HOME="$T/home" TMPDIR="$T/tmp"
trap 'rm -rf "$T"' EXIT

# The script runs under /bin/bash when it is executable, else bash.
sweep() {
  if [ -x "$SWEEP" ]; then
    /bin/bash "$SWEEP" "$@"
  else
    bash "$SWEEP" "$@"
  fi
}

# Fixture repo: a small Rust tree.
R="$T/repo"
mkdir -p "$R/src" "$R/tests/snapshots" "$R/docs" "$T/empty"
cat >"$R/src/lib.rs" <<'EOF'
pub mod shapes;
pub use shapes::Shape;
pub fn make_widget() -> u32 {
    1
}
EOF
cat >"$R/src/shapes.rs" <<'EOF'
pub enum Shape {
    Round,
    Square,
}
/// Makes a Shape.
impl Shape {
    pub fn area(&self) -> u32 {
        1
    }
}
EOF
cat >"$R/src/a.rs" <<'EOF'
pub fn a() {
    crate::make_widget();
}
EOF
cat >"$R/src/b.rs" <<'EOF'
pub fn b() {
    crate::make_widget();
}
EOF
cat >"$R/src/render.rs" <<'EOF'
use crate::shapes::Shape;
pub fn name(s: Shape) -> u32 {
    match s {
        Shape::Round => 1,
        Shape::Square => 2,
    }
}
EOF
cat >"$R/src/label.rs" <<'EOF'
pub const LABEL: &str = "WidgetThing";
EOF
printf 'label WidgetThing Shape v1\n' >"$R/tests/snapshots/label.snap"
{
  printf 'pub fn capped_fn() {\n}\npub fn exact_fn() {\n}\n'
  i=0; while [ "$i" -lt 41 ]; do printf '    capped_fn();\n'; i=$((i + 1)); done
  i=0; while [ "$i" -lt 40 ]; do printf '    exact_fn();\n'; i=$((i + 1)); done
} >"$R/src/many.rs"
cat >"$R/docs/guide.md" <<'EOF'
# Guide
Intro.
## Rules
Rule text.
### Detail
Detail text.
```
## Next
```
## Next
After text.
EOF
git -C "$R" init -q
git -C "$R" add -A
git -C "$R" -c user.name=test -c user.email=test@example.com commit -q -m one
BASE="$(git -C "$R" rev-parse HEAD)"

# run ARGS...: sets out (stdout) and code (exit status)
run() {
  out="$(sweep "$@" 2>"$T/err.txt")"
  code=$?
}

# outside_of PACK: prints the ## Outside Files section body
outside_of() {
  awk '/^## Outside Files/{f=1;next} /^## /{f=0} f' "$1"
}

# a. callers in two files
run --cwd "$R" --base "$BASE" --symbols make_widget --files src/lib.rs --out "$T/pack-a.md"
[ "$code" = 0 ] || fail "a: exits 0, got $code [$out]"
[ "$out" = "PACK $T/pack-a.md symbols=1 files=1 outside=2" ] || fail "a: PACK line, got [$out]"
grep -q '^## Symbol make_widget$' "$T/pack-a.md" || fail "a: Symbol head"
grep -q '^definitions: 1$' "$T/pack-a.md" || fail "a: one definition"
grep -q '^src/lib.rs:3: pub fn make_widget() -> u32 {$' "$T/pack-a.md" || fail "a: definition line"
grep -q '^callers: 2 lines in 2 files (shown 2)$' "$T/pack-a.md" || fail "a: caller counts"
grep -q '^src/a.rs:2:     crate::make_widget();$' "$T/pack-a.md" || fail "a: caller a"
grep -q '^src/b.rs:2:     crate::make_widget();$' "$T/pack-a.md" || fail "a: caller b"
want="$(printf 'src/a.rs caller\nsrc/b.rs caller')"
[ "$(outside_of "$T/pack-a.md")" = "$want" ] || fail "a: Outside Files exactly two caller lines"
[ "$(grep -c '^## Symbol make_widget$' "$T/pack-a.md")" = 1 ] || fail "a: one Symbol heading in the full pack"

# b. re-export, and no matches: line without --lang rust
run --cwd "$R" --base "$BASE" --symbols Shape --files src/shapes.rs --out "$T/pack-b.md"
[ "$code" = 0 ] || fail "b: exits 0, got $code [$out]"
[ "$out" = "PACK $T/pack-b.md symbols=1 files=1 outside=3" ] || fail "b: PACK line, got [$out]"
grep -q '^re-exports: 1$' "$T/pack-b.md" || fail "b: one re-export"
grep -q '^definitions: 1$' "$T/pack-b.md" || fail "b: enum is the only definition"
grep -q '^src/lib.rs:2: pub use shapes::Shape;$' "$T/pack-b.md" || fail "b: re-export line"
grep -q '^src/lib.rs re-export$' "$T/pack-b.md" || fail "b: Outside holds the re-export"
grep -q '^tests/snapshots/label.snap pin$' "$T/pack-b.md" || fail "b: Outside holds the uncovered pin"
[ "$(grep -c '^matches:' "$T/pack-b.md")" = 0 ] || fail "b: no matches line without --lang rust"

# c. enum match outside Files, through --plan and the shared cover rules
cat >"$T/plan-c.md" <<EOF
# Plan
Base: $BASE

## Files
- \`src/{shapes,lib}.rs\`
- \`tests/*.snap\`

## Interfaces
Uses \`Shape\`.
EOF
run --cwd "$R" --base "$BASE" --plan "$T/plan-c.md" --lang rust --out "$T/pack-c.md"
[ "$code" = 0 ] || fail "c: exits 0, got $code [$out]"
[ "$out" = "PACK $T/pack-c.md symbols=1 files=2 outside=1" ] || fail "c: PACK line, got [$out]"
grep -q '^Mode: plan '"$T"'/plan-c.md$' "$T/pack-c.md" || fail "c: Mode plan line"
grep -q '^matches: 2 lines in 1 files$' "$T/pack-c.md" || fail "c: match counts"
grep -q '^pins: 1 files$' "$T/pack-c.md" || fail "c: the snap pins Shape"
grep -q '^tests/snapshots/label.snap snap$' "$T/pack-c.md" || fail "c: pin line"
grep -q '^src/render.rs:4:         Shape::Round => 1,$' "$T/pack-c.md" || fail "c: match line"
[ "$(outside_of "$T/pack-c.md")" = "src/render.rs caller,match" ] || fail "c: Outside holds the match file only"
[ "$(grep -c '^src/lib.rs ' "$T/pack-c.md")" = 0 ] || fail "c: no Outside line for a Files path"
[ "$(grep -c '^src/shapes.rs ' "$T/pack-c.md")" = 0 ] || fail "c: no Outside line for an outlined path"
[ "$(outside_of "$T/pack-c.md" | grep -c '^tests/')" = 0 ] || fail "c: no Outside line for a covered snap"

# d. snapshot pin
run --cwd "$R" --base "$BASE" --symbols WidgetThing --files src/label.rs --out "$T/pack-d.md"
[ "$code" = 0 ] || fail "d: exits 0, got $code [$out]"
grep -q '^pins: 1 files$' "$T/pack-d.md" || fail "d: one pin file"
grep -q '^tests/snapshots/label.snap snap$' "$T/pack-d.md" || fail "d: pin line"
grep -q '^tests/snapshots/label.snap pin$' "$T/pack-d.md" || fail "d: Outside holds the pin"
[ "$(grep -c '^tests/snapshots/label.snap:[0-9]*: ' "$T/pack-d.md")" = 0 ] || fail "d: the snap line is not a caller line"

# e. caller limit: 41 calls show 40, exactly 40 show 40
run --cwd "$R" --base "$BASE" --symbols capped_fn,exact_fn --files src/many.rs --out "$T/pack-e.md"
[ "$code" = 0 ] || fail "e: exits 0, got $code [$out]"
grep -q '^callers: 41 lines in 1 files (shown 40)$' "$T/pack-e.md" || fail "e: capped counts"
[ "$(grep -c '^src/many.rs:[0-9]*:     capped_fn();$' "$T/pack-e.md")" = 40 ] || fail "e: exactly 40 capped lines shown"
grep -q '^callers: 40 lines in 1 files (shown 40)$' "$T/pack-e.md" || fail "e: exact counts"

# e2. many callers do not trip pipefail: 3000 short lines still exit 0 and show 40
{
  printf 'pub fn big_fn() {\n}\n'
  i=0; while [ "$i" -lt 3000 ]; do printf '    big_fn();\n'; i=$((i + 1)); done
} >"$R/src/big.rs"
git -C "$R" add src/big.rs
git -C "$R" -c user.name=test -c user.email=test@example.com commit -q -m big
BIGBASE="$(git -C "$R" rev-parse HEAD)"
run --cwd "$R" --base "$BIGBASE" --symbols big_fn --files src/big.rs --out "$T/pack-e2.md"
[ "$code" = 0 ] || fail "e2: exits 0, got $code [$out]"
grep -q '^callers: 3000 lines in 1 files (shown 40)$' "$T/pack-e2.md" || fail "e2: caller counts"
[ "$(grep -c '^src/big.rs:[0-9]*:     big_fn();$' "$T/pack-e2.md")" = 40 ] || fail "e2: exactly 40 caller lines shown"

# f. outline lists items with line numbers, never a body
run --cwd "$R" --base "$BASE" --files src/shapes.rs --out "$T/pack-f.md"
[ "$code" = 0 ] || fail "f: exits 0, got $code [$out]"
[ "$out" = "PACK $T/pack-f.md symbols=0 files=1 outside=0" ] || fail "f: PACK line, got [$out]"
grep -q '^## Outline src/shapes.rs$' "$T/pack-f.md" || fail "f: outline head"
grep -q '^1: pub enum Shape {$' "$T/pack-f.md" || fail "f: enum line"
grep -q '^6: impl Shape {$' "$T/pack-f.md" || fail "f: impl line"
grep -q '^7:     pub fn area(&self) -> u32 {$' "$T/pack-f.md" || fail "f: fn line"
[ "$(grep -c '^8: ' "$T/pack-f.md")" = 0 ] || fail "f: no body line"

# g. docs print the section verbatim and stop before the next heading
run --cwd "$R" --base "$BASE" --symbols make_widget --files src/lib.rs --docs docs/guide.md#Rules --out "$T/pack-g.md"
[ "$code" = 0 ] || fail "g: exits 0, got $code [$out]"
grep -q '^## Doc docs/guide.md#Rules$' "$T/pack-g.md" || fail "g: doc head"
grep -q '^Rule text\.$' "$T/pack-g.md" || fail "g: rule text"
grep -q '^### Detail$' "$T/pack-g.md" || fail "g: subsection kept"
grep -q '^## Next$' "$T/pack-g.md" || fail "g: fenced heading-like line kept"
[ "$(grep -c '^After text\.$' "$T/pack-g.md")" = 0 ] || fail "g: stops before the next heading"
run --cwd "$R" --base "$BASE" --symbols make_widget --files src/lib.rs --docs docs/guide.md#Nope --out "$T/pack-g2.md"
[ "$code" = 1 ] || fail "g: missing heading exits 1, got $code"
[ "$out" = "unresolved doc: docs/guide.md#Nope" ] || fail "g: unresolved doc line, got [$out]"

# h. cap: compact form keeps heads, counts and Outside Files, and says what was cut
run --cwd "$R" --base "$BASE" --symbols make_widget --files src/lib.rs --max-bytes 300 --out "$T/pack-h.md"
[ "$code" = 0 ] || fail "h: exits 0, got $code [$out]"
grep -q '^## Symbol make_widget$' "$T/pack-h.md" || fail "h: symbol head kept"
grep -q '^callers: 2 lines in 2 files (shown 2)$' "$T/pack-h.md" || fail "h: caller counts kept"
grep -q '^src/a.rs caller$' "$T/pack-h.md" || fail "h: Outside kept"
grep -q '^src/b.rs caller$' "$T/pack-h.md" || fail "h: Outside kept"
[ "$(grep -c '^src/a.rs:2:' "$T/pack-h.md")" = 0 ] || fail "h: no caller line"
grep -q '^## Cut$' "$T/pack-h.md" || fail "h: Cut section"
[ "$(grep -c '^## Symbol make_widget$' "$T/pack-h.md")" = 1 ] || fail "h: one Symbol heading in the compact pack"

# i. unknown token exits 1, writes nothing, leaves an existing file alone
run --cwd "$R" --base "$BASE" --symbols NoSuchThing --files src/lib.rs --out "$T/pack-i.md"
[ "$code" = 1 ] || fail "i: unknown symbol exits 1, got $code"
[ "$out" = "unresolved symbol: NoSuchThing" ] || fail "i: unresolved line, got [$out]"
[ ! -e "$T/pack-i.md" ] || fail "i: no pack file written"
printf 'keep me\n' >"$T/pack-i2.md"
run --cwd "$R" --base "$BASE" --symbols NoSuchThing --files src/lib.rs --out "$T/pack-i2.md"
[ "$code" = 1 ] || fail "i: existing file exits 1, got $code"
[ "$(cat "$T/pack-i2.md")" = "keep me" ] || fail "i: existing file untouched"
run --cwd "$R" --base "$BASE" --symbols make_widget --files src/nope.rs --out "$T/pack-i3.md"
[ "$code" = 1 ] || fail "i: unknown path exits 1, got $code"
[ "$out" = "unresolved path: src/nope.rs" ] || fail "i: unresolved path line, got [$out]"

# j. --plan reuses the new exemption; --symbols/--files get none
cat >"$T/plan-j.md" <<EOF
# Plan
Base: $BASE

## Files
- \`src/lib.rs\`

## Interfaces
New \`Brand_New\` helper.
EOF
run --cwd "$R" --base "$BASE" --plan "$T/plan-j.md" --out "$T/pack-j.md"
[ "$code" = 0 ] || fail "j: new symbol in plan exits 0, got $code [$out]"
[ "$(grep -c 'Brand_New' "$T/pack-j.md")" = 0 ] || fail "j: exempt token left out of the pack"
run --cwd "$R" --base "$BASE" --symbols Brand_New --files src/lib.rs --out "$T/pack-j2.md"
[ "$code" = 1 ] || fail "j: --symbols gets no exemption, got $code"
[ "$out" = "unresolved symbol: Brand_New" ] || fail "j: unresolved line, got [$out]"

# m. --plan Tasks new-marking exits 0; unmarked Interfaces symbol exits 1
cat >"$T/plan-m-a.md" <<EOF
# Plan
Base: $BASE

## Files
- \`src/lib.rs\`

## Tasks
1. Add \`Task_Only\` helper (new).
EOF
run --cwd "$R" --base "$BASE" --plan "$T/plan-m-a.md" --out "$T/pack-m-a.md"
[ "$code" = 0 ] || fail "m: marked Tasks symbol exits 0, got $code [$out]"
# Contract: skills/planning/SKILL.md:70 says unresolved new-marked symbols are omitted from the pack.
[ "$(grep -c 'Task_Only' "$T/pack-m-a.md")" = 0 ] || fail "m: marked token left out of the pack"
cat >"$T/plan-m-b.md" <<EOF
# Plan
Base: $BASE

## Files
- \`src/lib.rs\`

## Interfaces
Calls \`Unmarked_Name\` from the shim.
EOF
run --cwd "$R" --base "$BASE" --plan "$T/plan-m-b.md" --out "$T/pack-m-b.md"
[ "$code" = 1 ] || fail "m: unmarked Interfaces symbol exits 1, got $code [$out]"
printf '%s\n' "$out" | grep -q '^unresolved symbol: Unmarked_Name' || fail "m: unresolved line, got [$out]"

# k. usage: exit 2 with nothing on stdout
usage_cases=0
expect_usage() {
  usage_cases=$((usage_cases + 1))
  out="$(sweep "$@" 2>"$T/err.txt")"; code=$?
  [ "$code" = 2 ] || fail "k$usage_cases: exits 2, got $code [$*]"
  [ -z "$out" ] || fail "k$usage_cases: nothing on stdout [$*]"
}
expect_usage
expect_usage --help
expect_usage --cwd "$R" --base "$BASE" --symbols make_widget --files src/lib.rs --out rel/path.md
expect_usage --cwd "$R" --base "$BASE" --plan "$T/plan-j.md" --symbols make_widget --out "$T/pack-k.md"
expect_usage --cwd "$R" --base nosuchrev --symbols make_widget --files src/lib.rs --out "$T/pack-k.md"
expect_usage --cwd "$R" --base "$BASE" --symbols make_widget --files src/lib.rs --lang go --out "$T/pack-k.md"
expect_usage --cwd "$R" --base "$BASE" --symbols make_widget --files src/lib.rs --max-bytes 0 --out "$T/pack-k.md"
expect_usage --cwd "$T/empty" --base "$BASE" --symbols make_widget --files src/lib.rs --out "$T/pack-k.md"

# the shared lib is sourced from beside the script: a copy with no lib/ beside it exits 2
mkdir -p "$T/nolib"
cp "$SCRIPT_DIR/../bin/plan-sweep" "$T/nolib/plan-sweep"
out="$(bash "$T/nolib/plan-sweep" --cwd "$R" --base "$BASE" --symbols make_widget --files src/lib.rs --out "$T/pack-k2.md" 2>"$T/err.txt")"; code=$?
[ "$code" = 2 ] || fail "missing lib exits 2, got $code"
[ -z "$out" ] || fail "missing lib: nothing on stdout"
grep -q "lib/plan-tokens.sh" "$T/err.txt" || fail "missing lib: stderr names lib/plan-tokens.sh"

# l. definition outside Files
run --cwd "$R" --base "$BASE" --symbols Shape --files src/lib.rs --out "$T/pack-l.md"
[ "$code" = 0 ] || fail "l: exits 0, got $code [$out]"
[ "$out" = "PACK $T/pack-l.md symbols=1 files=1 outside=3" ] || fail "l: PACK line, got [$out]"
want="$(printf 'src/render.rs caller\nsrc/shapes.rs definition,caller\ntests/snapshots/label.snap pin')"
[ "$(outside_of "$T/pack-l.md")" = "$want" ] || fail "l: Outside holds definition and caller reasons"

echo "plan-sweep: all cases passed"

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
{
  i=1; while [ "$i" -le 10 ]; do printf 'pub fn count_fn%02d() {\n}\n' "$i"; i=$((i + 1)); done
} >"$R/src/count.rs"
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
! grep -q 'Task_Only' "$T/pack-m-a.md" || fail "m: marked token left out of the pack"
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

# n. full-tree git grep passes do not grow with the symbol count
REAL_GIT="$(command -v git)"
mkdir -p "$T/wrap"
cat >"$T/wrap/git" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$T/grep.log"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$T/wrap/git"
full_greps() {
  awk -v rev="$1" 'index($0, " grep ") && substr($0, length($0) - length(rev) + 1) == rev { n++ } END { printf "%d\n", n + 0 }' "$T/grep.log"
}
OLD_PATH="$PATH"
PATH="$T/wrap:$PATH"
NAMES12="Shape,make_widget,count_fn01,count_fn02,count_fn03,count_fn04,count_fn05,count_fn06,count_fn07,count_fn08,count_fn09,count_fn10"
: >"$T/grep.log"
run --cwd "$R" --base "$BASE" --symbols make_widget,count_fn01 --files src/lib.rs --out "$T/pack-n1.md"
[ "$code" = 0 ] || fail "n: 2 symbols exits 0, got $code [$out]"
# #735 Done when: a counting git wrapper shows the full-tree git grep count does not grow with the symbol count.
[ "$(full_greps "$BASE")" = 1 ] || fail "n: 2 symbols make 1 full-tree pass, got $(full_greps "$BASE")"
: >"$T/grep.log"
run --cwd "$R" --base "$BASE" --symbols "$NAMES12" --files src/lib.rs --out "$T/pack-n2.md"
[ "$code" = 0 ] || fail "n: 12 symbols exits 0, got $code [$out]"
# #735 Done when: a counting git wrapper shows the full-tree git grep count does not grow with the symbol count.
[ "$(full_greps "$BASE")" = 1 ] || fail "n: 12 symbols make 1 full-tree pass, got $(full_greps "$BASE")"
cat >"$T/plan-n2.md" <<EOF
# Plan
Base: $BASE

## Files
- \`src/lib.rs\`

## Interfaces
Uses \`Shape\` and \`make_widget\`.
EOF
: >"$T/grep.log"
run --cwd "$R" --base "$BASE" --plan "$T/plan-n2.md" --lang rust --out "$T/pack-n3.md"
[ "$code" = 0 ] || fail "n: plan 2 symbols exits 0, got $code [$out]"
# #735 Done when: a counting git wrapper shows the full-tree git grep count does not grow with the symbol count.
[ "$(full_greps "$BASE")" = 2 ] || fail "n: plan 2 symbols make 2 full-tree passes, got $(full_greps "$BASE")"
cat >"$T/plan-n12.md" <<EOF
# Plan
Base: $BASE

## Files
- \`src/lib.rs\`

## Interfaces
Uses \`Shape\`, \`make_widget\`, \`count_fn01\`, \`count_fn02\`, \`count_fn03\`, \`count_fn04\`, \`count_fn05\`, \`count_fn06\`, \`count_fn07\`, \`count_fn08\`, \`count_fn09\` and \`count_fn10\`.
EOF
: >"$T/grep.log"
run --cwd "$R" --base "$BASE" --plan "$T/plan-n12.md" --lang rust --out "$T/pack-n4.md"
[ "$code" = 0 ] || fail "n: plan 12 symbols exits 0, got $code [$out]"
# #735 Done when: a counting git wrapper shows the full-tree git grep count does not grow with the symbol count.
[ "$(full_greps "$BASE")" = 2 ] || fail "n: plan 12 symbols make 2 full-tree passes, got $(full_greps "$BASE")"
PATH="$OLD_PATH"

# p. progress lines go to stderr only, in section order
run --cwd "$R" --base "$BASE" --symbols make_widget,Shape --files src/lib.rs --out "$T/pack-p.md"
[ "$code" = 0 ] || fail "p: exits 0, got $code [$out]"
case "$out" in "PACK $T/pack-p.md symbols=2 files=1 outside="*) ;; *) fail "p: stdout is only the PACK line, got [$out]" ;; esac
# #735 Fix direction 1 and plan Ruling 6 (stderr start line, one line per symbol).
want="$(printf 'plan-sweep: resolving 2 symbols\nplan-sweep: symbol 1/2 make_widget\nplan-sweep: symbol 2/2 Shape')"
[ "$(cat "$T/err.txt")" = "$want" ] || fail "p: stderr progress lines, got [$(cat "$T/err.txt")]"
run --cwd "$R" --base "$BASE" --files src/lib.rs --out "$T/pack-p0.md"
[ "$code" = 0 ] || fail "p: files-only exits 0, got $code [$out]"
[ -z "$(cat "$T/err.txt")" ] || fail "p: files-only prints nothing on stderr, got [$(cat "$T/err.txt")]"
run --cwd "$R" --base "$BASE" --symbols nosuch --files src/lib.rs --out "$T/pack-p1.md"
[ "$code" = 1 ] || fail "p: unknown symbol exits 1, got $code"
[ "$out" = "unresolved symbol: nosuch" ] || fail "p: unresolved line on stdout, got [$out]"
[ "$(cat "$T/err.txt")" = "plan-sweep: resolving 1 symbols" ] || fail "p: start line only on stderr, got [$(cat "$T/err.txt")]"
case "$(cat "$T/err.txt")" in *"plan-sweep: symbol "*) fail "p: no per-symbol line without a section" ;; esac

# q. overlap fixtures: committed after BASE, so cases b, c and l keep their counts
cat >"$R/src/overlap.rs" <<'EOF'
pub enum ShapeKind {
    Tall,
    Wide,
}
pub fn shape_pair(first: ShapeKind, second: Shape) -> u32 {
    1
}
pub fn my_Shape() -> u32 {
    2
}
EOF
cat >"$R/src/qual.rs" <<'EOF'
use crate::shapes::Shape;
pub fn qual() -> u32 {
    let a = (Shape::Round);
    let b = ShapeKind::Tall;
    let c = XShape::Round;
    let d = 0;
    let e = XShape::Round Shape::A;
    1
}
Shape::Round
EOF
printf 'pub fn tabbed() {\n    let _ = Shape;\t// tabbed\n}\n' >"$R/src/tabbed.rs"
git -C "$R" add src/overlap.rs src/qual.rs src/tabbed.rs
git -C "$R" -c user.name=test -c user.email=test@example.com commit -q -m overlap
EDGEBASE="$(git -C "$R" rev-parse HEAD)"

# q1. overlapping names: the ShapeKind-only line is not Shape's
run --cwd "$R" --base "$EDGEBASE" --symbols Shape,ShapeKind --files src/lib.rs --out "$T/pack-q1.md"
[ "$code" = 0 ] || fail "q1: exits 0, got $code [$out]"
[ "$out" = "PACK $T/pack-q1.md symbols=2 files=1 outside=6" ] || fail "q1: PACK line, got [$out]"
grep -q '^callers: 12 lines in 5 files (shown 12)$' "$T/pack-q1.md" || fail "q1: Shape caller count"
grep -q '^src/overlap.rs:5: pub fn shape_pair(first: ShapeKind, second: Shape) -> u32 {$' "$T/pack-q1.md" || fail "q1: both-name line counted"
[ "$(grep -c '^src/overlap.rs:1:' "$T/pack-q1.md")" = 1 ] || fail "q1: ShapeKind-only line held by ShapeKind alone"
[ "$(grep -c 'my_Shape' "$T/pack-q1.md")" = 0 ] || fail "q1: _-preceded Shape not attributed"

# q2. the :: pass: first occurrence only, each name on its own
run --cwd "$R" --base "$EDGEBASE" --symbols Shape,ShapeKind --files src/lib.rs --lang rust --out "$T/pack-q2.md"
[ "$code" = 0 ] || fail "q2: exits 0, got $code [$out]"
grep -q '^matches: 4 lines in 2 files$' "$T/pack-q2.md" || fail "q2: Shape match counts"
grep -q '^src/qual.rs:3:     let a = (Shape::Round);$' "$T/pack-q2.md" || fail "q2: match after ( counts"
grep -q '^src/qual.rs:10: Shape::Round$' "$T/pack-q2.md" || fail "q2: match at line start counts"
[ "$(grep -c '^src/qual.rs:5:' "$T/pack-q2.md")" = 0 ] || fail "q2: XShape::Round alone is no match"
[ "$(grep -c 'XShape::Round Shape::A' "$T/pack-q2.md")" = 1 ] || fail "q2: first-occurrence-only line never matches"
grep -q '^matches: 1 lines in 1 files$' "$T/pack-q2.md" || fail "q2: ShapeKind match counts"
grep -q '^src/qual.rs:4:     let b = ShapeKind::Tall;$' "$T/pack-q2.md" || fail "q2: ShapeKind match line"

# q3. mixed unresolved plan tokens keep plan-line order
cat >"$T/plan-q3.md" <<EOF
# Plan
Base: $EDGEBASE

## Files
- \`src/lib.rs\`

## Interfaces
Uses \`NoSuchSym1\`.

## Tasks
1. Fix \`src/nosuch.rs\`.
EOF
run --cwd "$R" --base "$EDGEBASE" --plan "$T/plan-q3.md" --out "$T/pack-q3.md"
[ "$code" = 1 ] || fail "q3: exits 1, got $code"
# plan Ruling 4: unresolved lines keep plan-line order, as the base prints them.
want="$(printf 'unresolved symbol: NoSuchSym1 (line 8)\nunresolved path: src/nosuch.rs (line 11)')"
[ "$out" = "$want" ] || fail "q3: plan-line order, got [$out]"

# q4. a plan with no symbol tokens starts no batch and prints nothing
cat >"$T/plan-q4.md" <<EOF
# Plan
Base: $EDGEBASE

## Files
- \`src/lib.rs\`

## Tasks
1. Tidy \`src/lib.rs\`.
EOF
REAL_GIT2="$(command -v git)"
mkdir -p "$T/wrap2"
cat >"$T/wrap2/git" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$T/grep2.log"
exec "$REAL_GIT2" "\$@"
EOF
chmod +x "$T/wrap2/git"
OLD_PATH2="$PATH"
PATH="$T/wrap2:$PATH"
: >"$T/grep2.log"
run --cwd "$R" --base "$EDGEBASE" --plan "$T/plan-q4.md" --out "$T/pack-q4.md"
[ "$code" = 0 ] || fail "q4: exits 0, got $code [$out]"
[ -z "$(cat "$T/err.txt")" ] || fail "q4: no start line on stderr, got [$(cat "$T/err.txt")]"
[ "$(awk -v rev="$EDGEBASE" 'index($0, " grep ") && substr($0, length($0) - length(rev) + 1) == rev { n++ } END { printf "%d\n", n + 0 }' "$T/grep2.log")" = 0 ] || fail "q4: no full-tree grep runs"
PATH="$OLD_PATH2"

# q5. a bare backslash-n token resolves as on the base, tabs survive intact
run --cwd "$R" --base "$EDGEBASE" --symbols '\n' --files src/lib.rs --out "$T/pack-q5.md"
[ "$code" = 1 ] || fail "q5: exits 1, got $code"
[ "$out" = 'unresolved symbol: \n' ] || fail "q5: unresolved line, got [$out]"
run --cwd "$R" --base "$EDGEBASE" --symbols Shape --files src/lib.rs --out "$T/pack-q6.md"
[ "$code" = 0 ] || fail "q5: Shape exits 0, got $code [$out]"
tabwant="$(printf 'src/tabbed.rs:2:     let _ = Shape;\t// tabbed')"
grep -qF -- "$tabwant" "$T/pack-q6.md" || fail "q5: tab-bearing line keeps every byte"

# q6. adjacent overlap: `xx` is never an `x` caller (the retry keeps its left edge)
cat >"$R/src/adjacent.rs" <<'EOF'
pub fn x() {}
pub fn xx() {}
EOF
git -C "$R" add src/adjacent.rs
git -C "$R" -c user.name=test -c user.email=test@example.com commit -q -m adjacent
ADJBASE="$(git -C "$R" rev-parse HEAD)"
run --cwd "$R" --base "$ADJBASE" --symbols x,xx --files src/adjacent.rs --out "$T/pack-q7.md"
[ "$code" = 0 ] || fail "q6: exits 0, got $code [$out]"
[ "$out" = "PACK $T/pack-q7.md symbols=2 files=1 outside=0" ] || fail "q6: PACK line, got [$out]"
[ "$(grep -c '^callers: 0 lines in 0 files (shown 0)$' "$T/pack-q7.md")" = 2 ] || fail "q6: x keeps zero callers when xx exists"
[ "$(grep -c '^src/adjacent.rs:2:' "$T/pack-q7.md")" = 1 ] || fail "q6: xx line held by xx alone"

echo "plan-sweep: all cases passed"

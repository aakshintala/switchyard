#!/usr/bin/env bash
# Tests for bin/fill-brief. Exits non-zero on the first failed case.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILL="$SCRIPT_DIR/../bin/fill-brief"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-fill-brief.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# basic fill of two placeholders
printf 'a __A__ b __B__ c\n' >"$T/t.md"
out="$(bash "$FILL" "$T/t.md" 'A=1' 'B=2')" || fail "basic fill exits 0"
[ "$out" = "a 1 b 2 c" ] || fail "basic fill content: got [$out]"

# unfilled placeholder: exit 1, nothing on stdout, named on stderr
printf 'hello __NAME__, __NAME__ again, __OTHER__\n' >"$T/u.md"
stdout="$(bash "$FILL" "$T/u.md" 2>"$T/err.txt")" && fail "unfilled exits 1"
[ -z "$stdout" ] || fail "unfilled prints nothing on stdout"
grep -q '^unfilled: __NAME__$' "$T/err.txt" || fail "unfilled names __NAME__"
grep -q '^unfilled: __OTHER__$' "$T/err.txt" || fail "unfilled names __OTHER__"
[ "$(wc -l <"$T/err.txt" | tr -d ' ')" = "2" ] || fail "unfilled names each placeholder once"

# unknown key: exit 1, nothing on stdout, named on stderr
printf 'hi\n' >"$T/k.md"
stdout="$(bash "$FILL" "$T/k.md" 'ZZZ=1' 2>"$T/err2.txt")" && fail "unknown key exits 1"
[ -z "$stdout" ] || fail "unknown key prints nothing on stdout"
grep -q '^unknown key: ZZZ$' "$T/err2.txt" || fail "unknown key names ZZZ"

# unknown key alongside an otherwise clean fill still fails
printf 'hi __WHO__\n' >"$T/k2.md"
bash "$FILL" "$T/k2.md" 'WHO=you' 'EXTRA=1' >/dev/null 2>"$T/err3.txt" && fail "unknown key with valid fill exits 1"
grep -q '^unknown key: EXTRA$' "$T/err3.txt" || fail "unknown key with valid fill names EXTRA"

# __EXTRA__ defaults to empty when no EXTRA argument is given
printf 'before\n__EXTRA__\nafter\n' >"$T/ex.md"
out="$(bash "$FILL" "$T/ex.md" 2>"$T/err-ex.txt")" || fail "__EXTRA__ with no EXTRA argument exits 0"
[ "$out" = "$(printf 'before\n\nafter')" ] || fail "__EXTRA__ with no EXTRA argument fills to an empty line: got [$out]"
out="$(bash "$FILL" "$T/ex.md" 'EXTRA=line')" || fail "EXTRA=line exits 0"
[ "$out" = "$(printf 'before\nline\nafter')" ] || fail "EXTRA=line fills __EXTRA__: got [$out]"
# EXTRA given for a template without __EXTRA__ is an unknown key
bash "$FILL" "$T/t.md" 'A=1' 'B=2' 'EXTRA=x' >/dev/null 2>"$T/err-ex2.txt" && fail "EXTRA without __EXTRA__ exits 1"
grep -q '^unknown key: EXTRA$' "$T/err-ex2.txt" || fail "EXTRA without __EXTRA__ names EXTRA"

# key early in a long template must not trip pipefail + grep -q EPIPE (issue #55)
{ echo '__A__'; seq 1 5000 | sed 's/^/filler line /'; } >"$T/big.md"
bash "$FILL" "$T/big.md" 'A=x' >"$T/big-out.txt" 2>"$T/big-err.txt" || fail "a key early in a long template is known"
[ "$(head -1 "$T/big-out.txt")" = "x" ] || fail "a key early in a long template fills first line"

# a value that quotes a placeholder is data, not an unfilled placeholder (issue #70)
printf 'Plan:\n__PLAN__\n' >"$T/q.md"
printf 'quote: `diff __SINCE__..HEAD`\n' >"$T/qp.md"
out="$(bash "$FILL" "$T/q.md" "PLAN=@$T/qp.md" 2>"$T/err-q.txt")" || fail "quoted placeholder in value exits 0"
case "$out" in *'diff __SINCE__..HEAD'*) ;; *) fail "quoted placeholder printed literally: got [$out]" ;; esac
# a template placeholder with no key still fails as unfilled
printf 'Plan:\n__PLAN__ __SINCE__\n' >"$T/q2.md"
bash "$FILL" "$T/q2.md" "PLAN=@$T/qp.md" >/dev/null 2>"$T/err-q2.txt" && fail "template placeholder with no key exits 1"
grep -q '^unfilled: __SINCE__$' "$T/err-q2.txt" || fail "template placeholder with no key names __SINCE__"

# substitution is one pass: a value naming a later key's placeholder stays literal (issue #108)
printf '__A__ __B__\n' >"$T/op.md"
out="$(bash "$FILL" "$T/op.md" 'A=__B__' 'B=x')" || fail "one-pass fill exits 0"
[ "$out" = "__B__ x" ] || fail "one-pass fill keeps a later key's placeholder in a value: got [$out]"
out="$(bash "$FILL" "$T/op.md" 'B=__A__' 'A=y')" || fail "one-pass fill, reversed keys, exits 0"
[ "$out" = "y __A__" ] || fail "one-pass fill keeps an earlier key's placeholder in a value: got [$out]"

# adjacent placeholders are filled separately
printf '__A____B__\n' >"$T/adj.md"
out="$(bash "$FILL" "$T/adj.md" 'A=1' 'B=2')" || fail "adjacent placeholders exit 0"
[ "$out" = "12" ] || fail "adjacent placeholders content: got [$out]"

# multi-line @file value containing & \ $ / passes through unchanged
printf 'first __V__ last\n' >"$T/m.md"
printf 'a&b\\c$d/e\nsecond & \\ line\n' >"$T/val.txt"
bash "$FILL" "$T/m.md" "V=@$T/val.txt" >"$T/got.txt" || fail "atfile fill exits 0"
printf 'first a&b\\c$d/e\nsecond & \\ line\n last\n' >"$T/want.txt"
cmp -s "$T/got.txt" "$T/want.txt" || fail "atfile value is literal"

# a repeated placeholder is filled everywhere
printf 'x __A__ y __A__\n' >"$T/r.md"
out="$(bash "$FILL" "$T/r.md" 'A=Z')" || fail "repeat fill exits 0"
[ "$out" = "x Z y Z" ] || fail "repeat fill content: got [$out]"

# bad usage exits 2
bash "$FILL" >/dev/null 2>&1; [ "$?" = "2" ] || fail "no args exits 2"
usage_out="$(bash "$FILL" 2>&1 >/dev/null)" || true
case "$usage_out" in *"must come first"*) fail "usage no longer says --out must come first" ;; esac
case "$usage_out" in *"--out may come anywhere"*) ;; *) fail "usage says --out may come anywhere" ;; esac
for h in --help -h; do
  help_out="$(bash "$FILL" "$h" 2>&1 >/dev/null)" && fail "$h exits non-zero"
  case "$help_out" in "usage: fill-brief"*) ;; *) fail "$h prints usage, got [$help_out]" ;; esac
done
bash "$FILL" "$T/t.md" 'NOEQUALS'>/dev/null 2>&1; [ "$?" = "2" ] || fail "key without = exits 2"
bash "$FILL" "$T/does-not-exist.md" 'A=1' >/dev/null 2>&1; [ "$?" = "2" ] || fail "missing template exits 2"

# --out creates a missing directory
printf 'n __A__\n' >"$T/n.md"
bash "$FILL" --out "$T/new/dir/b.md" "$T/n.md" 'A=1' >/dev/null || fail "--out into a new directory exits 0"
[ -f "$T/new/dir/b.md" ] || fail "--out into a new directory writes the file"

# --out writes the file and prints exactly the launch line
printf 'a __A__ b\n' >"$T/o.md"
bash "$FILL" --out "$T/brief.md" "$T/o.md" 'A=1' >"$T/line.txt" || fail "--out exits 0"
[ "$(wc -l <"$T/line.txt" | tr -d ' ')" = "1" ] || fail "--out prints exactly one line"
[ "$(cat "$T/line.txt")" = "Read $T/brief.md and follow it." ] || fail "--out prints launch line"
bash "$FILL" "$T/o.md" 'A=1' >"$T/std.txt" || fail "stdout mode exits 0"
cmp -s "$T/brief.md" "$T/std.txt" || fail "--out file matches stdout mode"

# --out at any position: after the template, between assignments, last
printf 'a __A__ b __B__\n' >"$T/p.md"
bash "$FILL" "$T/p.md" 'A=1' 'B=2' >"$T/p-std.txt" || fail "position baseline exits 0"
for pos in after-template between last; do
  rm -f "$T/pos.md"
  case "$pos" in
    after-template) set -- "$T/p.md" --out "$T/pos.md" 'A=1' 'B=2' ;;
    between) set -- "$T/p.md" 'A=1' --out "$T/pos.md" 'B=2' ;;
    last) set -- "$T/p.md" 'A=1' 'B=2' --out "$T/pos.md" ;;
  esac
  bash "$FILL" "$@" >"$T/pos-line.txt" || fail "--out $pos exits 0"
  [ "$(cat "$T/pos-line.txt")" = "Read $T/pos.md and follow it." ] || fail "--out $pos prints launch line"
  cmp -s "$T/pos.md" "$T/p-std.txt" || fail "--out $pos file matches stdout mode"
done

# placeholder-free template, --out, no assignments (bash 3.2 empty-array hazard)
printf 'plain\n' >"$T/plain.md"
for pos in first last; do
  rm -f "$T/plain-out.md"
  if [ "$pos" = first ]; then set -- --out "$T/plain-out.md" "$T/plain.md"; else set -- "$T/plain.md" --out "$T/plain-out.md"; fi
  bash "$FILL" "$@" >/dev/null 2>"$T/err-plain.txt" || fail "--out $pos without assignments exits 0"
  [ "$(cat "$T/plain-out.md")" = "plain" ] || fail "--out $pos without assignments content"
done

# --out twice, or with no path, exits 2 with nothing on stdout
stdout="$(bash "$FILL" --out "$T/a.md" "$T/p.md" --out "$T/b.md" 'A=1' 'B=2' 2>/dev/null)"; [ "$?" = "2" ] || fail "--out twice exits 2"
[ -z "$stdout" ] || fail "--out twice prints nothing on stdout"
stdout="$(bash "$FILL" "$T/p.md" 'A=1' 'B=2' --out 2>/dev/null)"; [ "$?" = "2" ] || fail "trailing --out exits 2"
[ -z "$stdout" ] || fail "trailing --out prints nothing on stdout"
bash "$FILL" --out >/dev/null 2>&1; [ "$?" = "2" ] || fail "lone --out exits 2"
bash "$FILL" "$T/p.md" --out >/dev/null 2>&1; [ "$?" = "2" ] || fail "template then --out exits 2"

# the path checks apply wherever --out appears
stdout="$(bash "$FILL" "$T/p.md" --out rel/brief.md 'A=1' 'B=2' 2>/dev/null)"; [ "$?" = "2" ] || fail "relative --out after template exits 2"
[ -z "$stdout" ] || fail "relative --out after template prints nothing on stdout"

# --out is an option only as a whole argument: X=--out is a KEY=VALUE
printf '__X__\n' >"$T/x.md"
[ "$(bash "$FILL" "$T/x.md" 'X=--out')" = "--out" ] || fail "X=--out is a KEY=VALUE"

# __PARENT__: needs a non-empty PARENT value, no fallback
printf 'parent __PARENT__ and __A__\n' >"$T/par.md"
[ "$(bash "$FILL" "$T/par.md" 'PARENT=orch-1' 'A=x')" = "parent orch-1 and x" ] || fail "PARENT=orch-1 fills"
stdout="$(bash "$FILL" "$T/par.md" 'A=x' 2>"$T/err-par.txt")"; [ "$?" = "1" ] || fail "no PARENT exits 1"
[ -z "$stdout" ] || fail "no PARENT prints nothing on stdout"
grep -q '^unfilled: __PARENT__$' "$T/err-par.txt" || fail "no PARENT names __PARENT__"
stdout="$(bash "$FILL" "$T/par.md" 'PARENT=' 'A=x' 2>"$T/err-par.txt")"; [ "$?" = "1" ] || fail "empty PARENT exits 1"
[ -z "$stdout" ] || fail "empty PARENT prints nothing on stdout"
grep -q '^empty value: PARENT$' "$T/err-par.txt" || fail "empty PARENT names PARENT"
: >"$T/empty-val.txt"
stdout="$(bash "$FILL" "$T/par.md" "PARENT=@$T/empty-val.txt" 'A=x' 2>"$T/err-par.txt")"; [ "$?" = "1" ] || fail "empty @file PARENT exits 1"
[ -z "$stdout" ] || fail "empty @file PARENT prints nothing on stdout"
grep -q '^empty value: PARENT$' "$T/err-par.txt" || fail "empty @file PARENT names PARENT"
rm -f "$T/par-out.md"
stdout="$(bash "$FILL" --out "$T/par-out.md" "$T/par.md" 'PARENT=' 'A=x' 2>/dev/null)"; [ "$?" = "1" ] || fail "empty PARENT with --out exits 1"
[ -z "$stdout" ] || fail "empty PARENT with --out prints nothing on stdout"
[ ! -e "$T/par-out.md" ] || fail "empty PARENT with --out writes nothing"
# other keys may be empty
[ "$(bash "$FILL" "$T/par.md" 'PARENT=p' 'A=')" = "parent p and " ] || fail "empty A still fills"

# __GATE__: needs a non-blank GATE value, the same rule as PARENT
printf 'gate: __GATE__\n' >"$T/gate.md"
[ "$(bash "$FILL" "$T/gate.md" 'GATE=bash test/run')" = "gate: bash test/run" ] || fail "real GATE fills"
stdout="$(bash "$FILL" "$T/gate.md" 'GATE=' 2>"$T/err-gate.txt")"; [ "$?" = "1" ] || fail "empty GATE exits 1"
[ -z "$stdout" ] || fail "empty GATE prints nothing on stdout"
[ "$(cat "$T/err-gate.txt")" = "empty value: GATE" ] || fail "empty GATE names GATE"
stdout="$(bash "$FILL" "$T/gate.md" 'GATE=   ' 2>"$T/err-gate.txt")"; [ "$?" = "1" ] || fail "whitespace-only GATE exits 1"
[ -z "$stdout" ] || fail "whitespace-only GATE prints nothing on stdout"
[ "$(cat "$T/err-gate.txt")" = "empty value: GATE" ] || fail "whitespace-only GATE names GATE"
rm -f "$T/gate-out.md"
stdout="$(bash "$FILL" --out "$T/gate-out.md" "$T/gate.md" 'GATE=' 2>/dev/null)"; [ "$?" = "1" ] || fail "empty GATE with --out exits 1"
[ -z "$stdout" ] || fail "empty GATE with --out prints nothing on stdout"
[ ! -e "$T/gate-out.md" ] || fail "empty GATE with --out writes nothing"
stdout="$(bash "$FILL" "$T/gate.md" "GATE=@$T/empty-val.txt" 2>/dev/null)"; [ "$?" = "1" ] || fail "empty @file GATE exits 1"
[ -z "$stdout" ] || fail "empty @file GATE prints nothing on stdout"

# --out with a relative path exits 2, nothing on stdout
stdout="$(bash "$FILL" --out rel/brief.md "$T/o.md" 'A=1' 2>"$T/err-rel.txt")"; [ "$?" = "2" ] || fail "relative --out exits 2"
[ -z "$stdout" ] || fail "relative --out prints nothing on stdout"

# --out to an unwritable path exits 1, nothing on stdout
: >"$T/blocker"; stdout="$(bash "$FILL" --out "$T/blocker/brief.md" "$T/o.md" 'A=1' 2>/dev/null)"; [ "$?" = "1" ] || fail "unwritable --out exits 1"
[ -z "$stdout" ] || fail "unwritable --out prints nothing on stdout"
[ ! -e "$T/no-such-dir/brief.md" ] || fail "unwritable --out writes nothing"

# a failing placeholder check with --out exits 1 and writes nothing
printf 'hello __NAME__\n' >"$T/ou.md"
rm -f "$T/should-not-exist.md"
stdout="$(bash "$FILL" --out "$T/should-not-exist.md" "$T/ou.md" 2>"$T/err-ou.txt")"; [ "$?" = "1" ] || fail "unfilled --out exits 1"
[ -z "$stdout" ] || fail "unfilled --out prints nothing on stdout"
grep -q '^unfilled: __NAME__$' "$T/err-ou.txt" || fail "unfilled --out names __NAME__"
[ ! -e "$T/should-not-exist.md" ] || fail "unfilled --out writes nothing"

# --out with a newline in the path exits 2, nothing on stdout, writes nothing
nl_path="$T/bad
name.md"
stdout="$(bash "$FILL" --out "$nl_path" "$T/o.md" 'A=1' 2>"$T/err-nl.txt")"; [ "$?" = "2" ] || fail "newline --out exits 2"
[ -z "$stdout" ] || fail "newline --out prints nothing on stdout"
[ ! -e "$nl_path" ] || fail "newline --out writes nothing"

# --out to a write-only file exits 1: the read-back cannot be verified
printf '' >"$T/empty.md"
: >"$T/wo.md"
chmod 200 "$T/wo.md"
stdout="$(bash "$FILL" --out "$T/wo.md" "$T/empty.md" 2>"$T/err-wo.txt")"; [ "$?" = "1" ] || fail "unreadable --out exits 1"
[ -z "$stdout" ] || fail "unreadable --out prints nothing on stdout"
grep -q 'cannot read output file' "$T/err-wo.txt" || fail "unreadable --out names read error"
chmod 600 "$T/wo.md"

echo "fill-brief: all cases passed"

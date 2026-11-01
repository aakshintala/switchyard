#!/usr/bin/env bash
# Tests for bin/fence-grant. Exits non-zero on the first failed case.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FG="${FG:-$SCRIPT_DIR/../bin/fence-grant}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-fence-grant.XXXXXX")"
export T
PI_PID=""
cleanup() {
  if [ -n "$PI_PID" ]; then kill "$PI_PID" 2>/dev/null || true; fi
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/tmp" "$T/run" "$T/stubs" "$T/blobs" "$T/pr"
export TMPDIR="$T/tmp" FW_RUN="$T/run" FW_GH="$T/stubs/gh" FW_CLAUDE="$T/stubs/claude" FW_SSH="$T/stubs/ssh" FW_BOX_HOST=stub-box
export GH_TREE="$T/tree.json" GH_PRLIST='[]' CLAUDE_JSON='[]' SSH_OUT

cat >"$FW_GH" <<'GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T/gh.log"
case "$1" in
  api)
    case "$2" in
      repos/*/git/trees/main\?recursive=1)
        [ "${GH_TREE_FAIL:-0}" = 1 ] && { echo 'tree stub failure' >&2; exit 1; }
        [ -n "${GH_TREE_JSON:-}" ] && { printf '%s' "$GH_TREE_JSON"; exit 0; }
        cat "$GH_TREE"
        ;;
      repos/*/contents/*\?ref=main)
        [ "${GH_BLOB_FAIL:-0}" = 1 ] && { echo 'blob stub failure' >&2; exit 1; }
        path="${2#*/contents/}"
        path="${path%\?ref=main}"
        [ -f "$T/blobs/$path" ] || { echo "missing blob: $path" >&2; exit 1; }
        cat "$T/blobs/$path"
        ;;
      *) echo "stub gh: unexpected: $*" >&2; exit 99;;
    esac
    ;;
  pr)
    case "$2" in
      list)
        [ "${GH_PRLIST_FAIL:-0}" = 1 ] && { echo 'pr list stub failure' >&2; exit 1; }
        [ -n "${GH_PRLIST_JSON:-}" ] && { printf '%s' "$GH_PRLIST_JSON"; exit 0; }
        printf '%s' "$GH_PRLIST"
        ;;
      diff)
        pr="$3"
        case " $* " in
          *' --name-only '*)
            [ "${GH_DIFFN_FAIL:-}" != "$pr" ] || { echo 'pr names stub failure' >&2; exit 1; }
            [ -f "$T/pr/$pr.names" ] && cat "$T/pr/$pr.names"
            ;;
          *' --allow-escape-sequences '*)
            [ "${GH_DIFF_FAIL:-}" != "$pr" ] || { echo 'pr diff stub failure' >&2; exit 1; }
            [ -f "$T/pr/$pr.diff" ] && cat "$T/pr/$pr.diff"
            ;;
          *) echo "stub gh: unexpected: $*" >&2; exit 99;;
        esac
        ;;
      *) echo "stub gh: unexpected: $*" >&2; exit 99;;
    esac
    ;;
  *) echo "stub gh: unexpected: $*" >&2; exit 99;;
esac
GH_STUB

cat >"$FW_CLAUDE" <<'CLAUDE_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T/claude.log"
[ "${CLAUDE_FAIL:-0}" != 1 ] || { echo 'claude stub failure' >&2; exit 1; }
printf '%s' "${CLAUDE_JSON:-[]}"
CLAUDE_STUB

cat >"$FW_SSH" <<'SSH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T/ssh.log"
[ "${SSH_FAIL:-0}" != 1 ] || { echo 'ssh stub failure' >&2; exit 1; }
if [ -n "${SSH_OUT:-}" ]; then printf '%s\n' "$SSH_OUT"; else
  printf '%s\n' 'FWSEC=UPTIME' 'FWSEC=AGENTS' '[]' 'FWSEC=PILANES' PILANESOK 'FWSEC=END'
fi
SSH_STUB
chmod +x "$FW_GH" "$FW_CLAUDE" "$FW_SSH"

reset_case() {
  rm -rf "$FW_RUN" "$T/blobs" "$T/pr"
  mkdir -p "$FW_RUN" "$T/blobs" "$T/pr"
  : >"$T/gh.log"
  : >"$T/claude.log"
  : >"$T/ssh.log"
  cat >"$GH_TREE" <<'TREE'
{"truncated":false,"tree":[
{"type":"blob","path":"docs/tui.md"},
{"type":"blob","path":"docs/events.md"},
{"type":"blob","path":"crates/tui/src/turn/group.rs"},
{"type":"blob","path":"crates/tui/src/turn/group_tests.rs"},
{"type":"blob","path":"crates/extensions/src/process/tests.rs"},
{"type":"blob","path":"crates/extensions/src/process_tests.rs"},
{"type":"blob","path":"crates/a/tests.rs"},
{"type":"blob","path":"crates/b/tests.rs"},
{"type":"blob","path":"crates/c/tests.rs"},
{"type":"blob","path":"crates/d/tests.rs"},
{"type":"blob","path":"crates/e/tests.rs"},
{"type":"blob","path":"crates/f/tests.rs"},
{"type":"blob","path":"src/new_dir/keep.rs"}
]}
TREE
  GH_TREE_FAIL=0 GH_BLOB_FAIL=0 GH_PRLIST_FAIL=0 GH_DIFFN_FAIL= GH_DIFF_FAIL=
  GH_TREE_JSON= GH_PRLIST_JSON= GH_PRLIST='[]' CLAUDE_FAIL=0 CLAUDE_JSON='[]' SSH_FAIL=0 SSH_OUT=
  export GH_TREE_FAIL GH_BLOB_FAIL GH_PRLIST_FAIL GH_DIFFN_FAIL GH_DIFF_FAIL GH_TREE_JSON GH_PRLIST_JSON GH_PRLIST CLAUDE_FAIL CLAUDE_JSON SSH_FAIL SSH_OUT
}

run_fg() {
  bash "$FG" "$@" >"$T/out" 2>"$T/err"
  RC=$?
}

assert_rc() {
  [ "$RC" = "$1" ] || fail "$2: exit $RC, want $1; stdout=$(cat "$T/out"); stderr=$(cat "$T/err")"
}

assert_out() {
  [ "$(cat "$T/out")" = "$1" ] || fail "$2: stdout=$(cat "$T/out")"
}

assert_stderr() {
  [ "$(cat "$T/err")" = "$1" ] || fail "$2: stderr=$(cat "$T/err")"
}

assert_line() {
  grep -qxF "$1" "$T/out" || fail "$2: missing exact line [$1] in $(cat "$T/out")"
}

assert_contains() {
  grep -qF "$1" "$T/out" || fail "$2: missing [$1] in $(cat "$T/out")"
}

assert_not_contains() {
  ! grep -qF "$1" "$T/out" || fail "$2: unexpected [$1] in $(cat "$T/out")"
}

assert_no_grant() {
  [ ! -d "$FW_RUN" ] || [ -z "$(find "$FW_RUN" -name 'fiber-*-fence-grant*.md' -print)" ] || fail "$1: wrote grant file"
}

assert_no_probes() {
  [ ! -s "$T/gh.log" ] || fail "$1: called gh: $(cat "$T/gh.log")"
}

assert_usage() {
  assert_rc 2 "$1"
  assert_out '' "$1 stdout"
  assert_stderr 'usage: fence-grant <ticket> --paths <comma list> [--ranges <file:start-end,...>] [--reads <comma list>] [--new <comma list>] [--expect <file:line:symbol,...>] [--repo <owner/name>] [--ignore-pr <n>] [--ignore-ticket <n>] [--dry]' "$1 usage"
  assert_no_probes "$1"
  assert_no_grant "$1"
}

assert_error() {
  assert_rc 3 "$1"
  assert_out "$2" "$1 output"
  assert_no_grant "$1"
}

write_blob() {
  mkdir -p "$T/blobs/${1%/*}"
  printf '%s' "$2" >"$T/blobs/$1"
}

set_pr() {
  number="$1"; branch="$2"; path="$3"
  GH_PRLIST="[{\"number\":$number,\"headRefName\":\"$branch\"}]"
  export GH_PRLIST
  printf '%s\n' "$path" >"$T/pr/$number.names"
  printf 'diff --git a/%s b/%s\nindex 1111111..2222222 100644\n' "$path" "$path" >"$T/pr/$number.diff"
}

# --- Exit 0: free paths and grant-file writing --------------------------------
reset_case
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'free dry run'
assert_out "$(printf 'GRANT docs/tui.md\nGRANT')" 'free dry output'
assert_no_grant 'free dry run'

reset_case
run_fg 77 --paths docs/tui.md
assert_rc 0 'free grant file'
assert_out "$(printf 'GRANT docs/tui.md\nGRANT')" 'free grant output'
[ -f "$FW_RUN/fiber-77-fence-grant-1.md" ] || fail 'first grant file exists'
grep -qxF 'Paths:' "$FW_RUN/fiber-77-fence-grant-1.md" || fail 'grant file has Paths section'
grep -qxF -- '- docs/tui.md' "$FW_RUN/fiber-77-fence-grant-1.md" || fail 'grant file records the path'
grep -qxF 'Ranges: none' "$FW_RUN/fiber-77-fence-grant-1.md" || fail 'grant file records no ranges'
[ ! -d "$FW_RUN/.fence-grant.lock" ] || fail 'grant lock removed'
run_fg 77 --paths docs/tui.md
assert_rc 0 'second grant file'
[ -f "$FW_RUN/fiber-77-fence-grant-2.md" ] || fail 'grant numbering increments'

reset_case
run_fg 77 --paths=docs/tui.md --dry
assert_rc 0 'paths equals form'
assert_out "$(printf 'GRANT docs/tui.md\nGRANT')" 'paths equals output'

reset_case
run_fg 77 --paths='docs/{tui,tui}.md' --dry
assert_rc 0 'duplicate brace expansion'
assert_out "$(printf 'GRANT docs/tui.md\nGRANT docs/tui.md\nGRANT')" 'duplicate brace output'

reset_case
run_fg 77 --paths='crates/tui/src/turn/{group,group_tests}.rs' --dry
assert_rc 0 'multiple brace expansion'
assert_out "$(printf 'GRANT crates/tui/src/turn/group.rs\nGRANT crates/tui/src/turn/group_tests.rs\nGRANT')" 'multiple brace output'

reset_case
run_fg 77 --paths docs/tui.md --ranges 'docs/{tui,tui}.md:1-2' --dry
assert_rc 0 'ranges brace expansion'

reset_case
run_fg 77 --paths='crates/new/{one,two}.rs' '--new=crates/new/{one,two}.rs' --dry
assert_rc 0 'new paths brace expansion'
assert_out "$(printf 'GRANT crates/new/one.rs\nGRANT crates/new/two.rs\nGRANT')" 'new path output'

reset_case
write_blob docs/tui.md 'needle\n'
set_pr 11 fix/other docs/tui.md
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/tui.md --ranges=docs/tui.md:1-5 --expect=docs/tui.md:1:needle --ignore-pr=11 --ignore-ticket=77
assert_rc 0 'combined equals forms'
assert_out "$(printf 'GRANT docs/tui.md\nGRANT')" 'combined equals forms output'
grep -qxF 'Ranges: docs/tui.md:1-5' "$FW_RUN/fiber-88-fence-grant-1.md" || fail 'equals ranges recorded'

reset_case
run_fg 77 --paths docs/tui.md --reads='docs/{x}.md' --dry
assert_rc 0 'reads equals form and literal braces'
assert_out "$(printf 'GRANT docs/tui.md\nREAD docs/{x}.md\nGRANT')" 'reads brace stays literal'

reset_case
run_fg 77 --paths docs/tui.md --reads=docs/x.md
assert_rc 0 'reads writes grant file'
assert_out "$(printf 'GRANT docs/tui.md\nREAD docs/x.md\nGRANT')" 'reads output order'
tail -n 2 "$FW_RUN/fiber-77-fence-grant-1.md" >"$T/reads-tail"
[ "$(cat "$T/reads-tail")" = "$(printf 'Reads:\n- docs/x.md')" ] || fail 'Reads is the final grant-file section'

# A read in a live lane grant stops the hold probe at the exact Reads: line.
reset_case
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/other.md\n\nReads:\n- docs/events.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/events.md --dry
assert_rc 0 'read path does not hold'
assert_out "$(printf 'GRANT docs/events.md\nGRANT')" 'read path output'

reset_case
run_fg 77 --paths crates/tui/ --dry
assert_rc 0 'existing directory path'
assert_out "$(printf 'GRANT crates/tui/\nGRANT')" 'directory path output'

# --- Exit 1: held paths --------------------------------------------------------
reset_case
set_pr 11 fix/other docs/tui.md
run_fg 77 --paths docs/tui.md --dry
assert_rc 1 'open PR hold'
assert_line 'HELD docs/tui.md by PR #11' 'open PR output'
assert_no_grant 'open PR hold'

reset_case
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\nRanges: none\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/tui.md --dry
assert_rc 1 'live lane hold'
assert_out 'HELD docs/tui.md by lane #77' 'live lane output'

reset_case
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
run_fg 88 --paths docs/tui.md --dry
assert_rc 1 'fresh orphan grant hold'
assert_contains 'HELD docs/tui.md by lane #77 NO LIVE LANE:' 'fresh orphan label'

reset_case
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
touch -t 202001010000 "$FW_RUN/fiber-77-fence-grant-1.md"
run_fg 88 --paths docs/tui.md --dry
assert_rc 0 'old orphan grant expires'
assert_out "$(printf 'GRANT docs/tui.md\nGRANT')" 'old orphan output'

reset_case
sleep 300 &
PI_PID=$!
printf '%s\n' "$PI_PID" >"$FW_RUN/fiber-77-pi.pid"
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
run_fg 88 --paths docs/tui.md --dry
assert_rc 1 'live Mac pi lane hold'
assert_out 'HELD docs/tui.md by lane #77' 'Mac pi lane output'
kill "$PI_PID" 2>/dev/null || true
PI_PID=""

reset_case
printf 'Grant 1\n\nTicket: 88\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-88-fence-grant-1.md"
SSH_OUT=$'FWSEC=UPTIME\nFWSEC=AGENTS\n[]\nFWSEC=PILANES\nfiber-88\nPILANESOK\nFWSEC=END'
export SSH_OUT
run_fg 77 --paths docs/tui.md --dry
assert_rc 1 'live box pi lane hold'
assert_out 'HELD docs/tui.md by lane #88' 'box pi lane output'

reset_case
write_blob docs/tui.md $'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n'
set_pr 11 fix/other docs/tui.md
cat >"$T/pr/11.diff" <<'DIFF'
diff --git a/docs/tui.md b/docs/tui.md
index 1111111..2222222 100644
--- a/docs/tui.md
+++ b/docs/tui.md
@@ -3,2 +3,2 @@
-three
+THREE
@@ -8 +8 @@
-eight
+EIGHT
DIFF
run_fg 77 --paths docs/tui.md --dry
assert_rc 1 'whole-file PR hold with hunk windows'
assert_line 'HELD docs/tui.md by PR #11' 'whole-file hold line'
assert_line '  held window 3-4' 'first held window'
assert_line '  held window 8-8' 'second held window'
assert_line '  --ranges docs/tui.md:1-2,docs/tui.md:5-7,docs/tui.md:9-10' 'range complement'

reset_case
set_pr 11 fix/other docs/tui.md
cat >"$T/pr/11.diff" <<'DIFF'
diff --git a/docs/tui.md b/docs/tui.md
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/docs/tui.md
@@ -0,0 +1,1 @@
+new
DIFF
run_fg 77 --paths docs/tui.md --dry
assert_rc 1 'PR adds file whole'
assert_line '  the pull request adds this file whole, so there is no complement' 'new file whole message'

reset_case
set_pr 11 fix/other docs/tui.md
cat >"$T/pr/11.diff" <<'DIFF'
diff --git a/docs/tui.md b/docs/tui.md
index 1111111..2222222 100644
--- a/docs/tui.md
+++ b/docs/tui.md
@@ -3,2 +3,2 @@
-three
+THREE
DIFF
run_fg 77 --paths docs/tui.md --ranges docs/tui.md:1-2 --dry
assert_rc 0 'requested range outside PR hunk'
assert_out "$(printf 'GRANT docs/tui.md\nGRANT')" 'non-overlap range output'
reset_case
set_pr 11 fix/other docs/tui.md
cat >"$T/pr/11.diff" <<'DIFF'
diff --git a/docs/tui.md b/docs/tui.md
index 1111111..2222222 100644
--- a/docs/tui.md
+++ b/docs/tui.md
@@ -3,2 +3,2 @@
-three
+THREE
DIFF
run_fg 77 --paths docs/tui.md --ranges docs/tui.md:3-4 --dry
assert_rc 1 'requested range overlaps PR hunk'
assert_line 'HELD docs/tui.md by PR #11' 'overlapping range hold'

reset_case
set_pr 11 fix/other docs/tui.md
run_fg 77 --paths docs/tui.md --ignore-pr 11 --dry
assert_rc 0 'ignore PR holder'
assert_out "$(printf 'GRANT docs/tui.md\nGRANT')" 'ignore PR output'
reset_case
printf 'Grant 1\n\nTicket: 77\nPaths:\n- docs/tui.md\n' >"$FW_RUN/fiber-77-fence-grant-1.md"
CLAUDE_JSON='[{"name":"fiber-77","status":"busy"}]'
export CLAUDE_JSON
run_fg 88 --paths docs/tui.md --ignore-ticket 77 --dry
assert_rc 0 'ignore ticket holder'
assert_out "$(printf 'GRANT docs/tui.md\nGRANT')" 'ignore ticket output'
reset_case
set_pr 11 x/77-slug docs/tui.md
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'own ticket PR skipped'
assert_out "$(printf 'OWN skipping PR #11: its branch names ticket 77\nGRANT docs/tui.md\nGRANT')" 'own PR output'
run_fg 88 --paths docs/tui.md --dry
assert_rc 1 'same PR holds for another ticket'
assert_line 'HELD docs/tui.md by PR #11' 'other ticket sees PR hold'

reset_case
GH_PRLIST='[{"number":11}]'
export GH_PRLIST
printf '%s\n' docs/tui.md >"$T/pr/11.names"
printf 'diff --git a/docs/tui.md b/docs/tui.md\n' >"$T/pr/11.diff"
run_fg 77 --paths docs/tui.md --dry
assert_rc 1 'PR without branch name is not own'
assert_line 'HELD docs/tui.md by PR #11' 'missing branch name hold'

# A correct existing path and symbol still goes through the holder sweep.
reset_case
write_blob docs/tui.md 'needle\n'
set_pr 11 fix/other docs/tui.md
run_fg 77 --paths docs/tui.md --expect docs/tui.md:1:needle --dry
assert_rc 1 'valid expect still checks holds'
assert_not_contains 'NOSYMBOL' 'valid expect accepted'
assert_line 'HELD docs/tui.md by PR #11' 'valid expect holder'

# --- Exit 2: bad arguments -----------------------------------------------------
USAGE='usage: fence-grant <ticket> --paths <comma list> [--ranges <file:start-end,...>] [--reads <comma list>] [--new <comma list>] [--expect <file:line:symbol,...>] [--repo <owner/name>] [--ignore-pr <n>] [--ignore-ticket <n>] [--dry]'
reset_case
run_fg
assert_usage 'missing ticket'
reset_case
run_fg 12a --paths docs/tui.md
assert_usage 'non-digit ticket'
reset_case
run_fg 77 --dry
assert_usage 'missing paths'
reset_case
run_fg 77 --paths
assert_usage 'missing paths value'
reset_case
run_fg 77 --paths docs/tui.md --unknown
assert_usage 'unknown flag'

reset_case
run_fg 77 --paths docs/tui.md --ranges docs/events.md:1-3
assert_rc 2 'range outside paths'
assert_out 'ERROR --ranges names docs/events.md which is not under --paths' 'range outside paths output'
assert_stderr '' 'range outside paths stderr'
assert_no_grant 'range outside paths'

reset_case
run_fg 77 --paths docs/tui.md --ranges docs/tui.md:one-3
assert_usage 'non-numeric range'
reset_case
run_fg 77 --paths docs/tui.md --ranges docs/tui.md:4-3
assert_usage 'reversed range'
reset_case
run_fg 77 --paths docs/tui.md --expect docs/tui.md:needle
assert_rc 2 'expect without line'
assert_out '' 'expect without line stdout'
assert_stderr "$USAGE" 'expect without line usage'
assert_no_grant 'expect without line'

for bad_repo in '' noslash a/b/c /x x/; do
  reset_case
  run_fg 77 --paths docs/tui.md --repo "$bad_repo"
  assert_usage "invalid repo $bad_repo"
done
reset_case
run_fg 77 --paths docs/tui.md --repo
assert_usage 'missing repo value'

# --- Exit 3: each failed or unparseable probe fails closed --------------------
reset_case
GH_TREE_FAIL=1
export GH_TREE_FAIL
run_fg 77 --paths docs/tui.md
assert_error 'tree fetch failure' 'ERROR gh trees main tree stub failure '

reset_case
GH_TREE_JSON='not-json'
export GH_TREE_JSON
run_fg 77 --paths docs/tui.md
assert_error 'unparseable tree' 'ERROR tree of main unreadable or truncated'

reset_case
GH_TREE_JSON='{"truncated":true,"tree":[{"type":"blob","path":"docs/tui.md"}]}'
export GH_TREE_JSON
run_fg 77 --paths docs/tui.md
assert_error 'truncated tree' 'ERROR tree of main unreadable or truncated'

reset_case
GH_TREE_JSON='{"truncated":false,"tree":[]}'
export GH_TREE_JSON
run_fg 77 --paths docs/tui.md
assert_error 'empty tree' 'ERROR tree of main is empty'

reset_case
write_blob docs/tui.md 'needle\n'
GH_BLOB_FAIL=1
export GH_BLOB_FAIL
run_fg 77 --paths docs/tui.md --expect docs/tui.md:1:needle
assert_error 'contents fetch failure' 'ERROR gh contents docs/tui.md blob stub failure '

reset_case
GH_PRLIST_FAIL=1
export GH_PRLIST_FAIL
run_fg 77 --paths docs/tui.md
assert_error 'PR list failure' 'ERROR gh pr list pr list stub failure '

reset_case
GH_PRLIST='not-json'
export GH_PRLIST
run_fg 77 --paths docs/tui.md
assert_error 'unparseable PR list' 'ERROR gh pr list '

reset_case
{
  printf '['
  i=1
  while [ "$i" -le 200 ]; do
    [ "$i" -eq 1 ] || printf ','
    printf '{"number":%s,"headRefName":"other"}' "$i"
    i=$((i + 1))
  done
  printf ']'
} >"$T/prlist-200.json"
GH_PRLIST_JSON="$(cat "$T/prlist-200.json")"
export GH_PRLIST_JSON
run_fg 77 --paths docs/tui.md
assert_error 'PR list reaches 200-entry limit' 'ERROR gh pr list truncated at 200'

reset_case
set_pr 11 fix/other docs/tui.md
GH_DIFFN_FAIL=11
export GH_DIFFN_FAIL
run_fg 77 --paths docs/tui.md
assert_error 'PR names fetch failure' 'ERROR gh pr diff 11 pr names stub failure '

reset_case
set_pr 11 fix/other docs/tui.md
GH_DIFF_FAIL=11
export GH_DIFF_FAIL
run_fg 77 --paths docs/tui.md
assert_error 'full PR diff fetch failure' 'ERROR gh pr diff 11 pr diff stub failure '

reset_case
printf '[{"number":11,"headRefName":"fix/other"}]' >"$T/prlist"
GH_PRLIST="$(cat "$T/prlist")"
export GH_PRLIST
printf '%s\n' docs/tui.md >"$T/pr/11.names"
run_fg 77 --paths docs/tui.md
assert_error 'empty full PR diff' 'ERROR gh pr diff 11 '

reset_case
CLAUDE_FAIL=1
export CLAUDE_FAIL
run_fg 77 --paths docs/tui.md
assert_error 'Claude command failure' 'ERROR claude agents claude stub failure '

reset_case
CLAUDE_JSON='not-json'
export CLAUDE_JSON
run_fg 77 --paths docs/tui.md
assert_error 'unparseable Claude output' 'ERROR claude agents '

reset_case
SSH_FAIL=1
export SSH_FAIL
run_fg 77 --paths docs/tui.md
assert_error 'ssh command failure' 'ERROR ssh box ssh stub failure '

reset_case
SSH_OUT='broken markers'
export SSH_OUT
run_fg 77 --paths docs/tui.md
assert_error 'ssh output missing markers' 'ERROR ssh box '

reset_case
SSH_OUT=$'FWSEC=UPTIME\nFWSEC=AGENTS\n[]\nFWSEC=PILANES\nfiber-88\nFWSEC=END'
export SSH_OUT
run_fg 77 --paths docs/tui.md
assert_error 'box pi section missing marker' 'ERROR box pi lanes: no PILANESOK marker'

reset_case
rm -rf "$FW_RUN"
run_fg 77 --paths docs/tui.md
assert_error 'Mac pi probe missing run directory' 'ERROR mac pi lanes: run directory missing'

reset_case
mkdir "$FW_RUN/.fence-grant.lock"
FW_LOCK_TRIES=1 FW_LOCK_POLL=0 run_fg 77 --paths docs/tui.md
assert_error 'grant lock timeout' "ERROR cannot lock $FW_RUN/.fence-grant.lock"
reset_case
mkdir "$FW_RUN/.fence-grant.lock"
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'dry run ignores held lock'
assert_out "$(printf 'GRANT docs/tui.md\nGRANT')" 'dry run with held lock output'
assert_no_grant 'dry run with held lock'

reset_case
mkdir -p "$T/missing-parent"
ln -s "$T/missing-parent/no-such-dir/grant.md" "$FW_RUN/fiber-77-fence-grant-1.md"
run_fg 77 --paths docs/tui.md
assert_rc 3 'grant write failure'
assert_out "ERROR cannot write $FW_RUN/fiber-77-fence-grant-1.md" 'grant write failure output'
[ -z "$(find "$FW_RUN" -type f -name 'fiber-*-fence-grant*.md' -print)" ] || fail 'grant write failure: wrote regular grant file'
[ -L "$FW_RUN/fiber-77-fence-grant-1.md" ] || fail 'write failure symlink fixture remains'

# --- Exit 4: invalid grant meaning and suggestions ---------------------------
reset_case
run_fg 77 --paths crates/turn/src/group.rs,crates/turn/src/group_tests.rs --dry
assert_rc 4 'missing paths suggestions'
assert_out "$(printf 'MISSING crates/turn/src/group.rs\n  did you mean: crates/tui/src/turn/group.rs\nMISSING crates/turn/src/group_tests.rs\n  did you mean: crates/tui/src/turn/group_tests.rs')" 'missing path suggestion output'
assert_no_grant 'missing paths suggestions'

reset_case
set_pr 11 fix/other docs/tui.md
run_fg 77 --paths crates/turn/src/new.rs,docs/tui.md --new crates/turn/src/new.rs --dry
assert_rc 1 'new path accepted before hold probe'
assert_not_contains 'MISSING' 'new path is not missing'
assert_line 'HELD docs/tui.md by PR #11' 'other path still held'

reset_case
GH_TREE_JSON='{"truncated":false,"tree":[{"type":"blob","path":"crates/extensions/src/process/tests.rs"},{"type":"blob","path":"crates/extensions/src/process_tests.rs"}]}'
export GH_TREE_JSON
write_blob crates/extensions/src/process/tests.rs "$(python3 -c 'print("quiet\n" * 3153 + "other\n", end="")')"
write_blob crates/extensions/src/process_tests.rs "$(python3 -c 'print("quiet\n" * 3153 + "envelope_line\n", end="")')"
run_fg 77 --paths crates/extensions/src/process/tests.rs --expect crates/extensions/src/process/tests.rs:3154:envelope_line --dry
assert_rc 4 'expected symbol absent'
assert_out "$(printf 'NOSYMBOL crates/extensions/src/process/tests.rs:3154 does not hold envelope_line\n  did you mean: crates/extensions/src/process_tests.rs:3154')" 'NOSYMBOL suggestion output'
grep -qF 'contents/crates/extensions/src/process/tests.rs?ref=main' "$T/gh.log" || fail 'original blob fetched'
grep -qF 'contents/crates/extensions/src/process_tests.rs?ref=main' "$T/gh.log" || fail 'alternate blob fetched'
! cmp -s "$T/blobs/crates/extensions/src/process/tests.rs" "$T/blobs/crates/extensions/src/process_tests.rs" || fail 'same-basename fixture contents differ'
assert_no_grant 'expected symbol absent'

reset_case
write_blob crates/extensions/src/process/tests.rs "$(python3 -c 'print("quiet\n" * 3153 + "other\n", end="")')"
write_blob crates/extensions/src/process_tests.rs "$(python3 -c 'print("quiet\n" * 3153 + "envelope_line\n", end="")')"
for f in a b c d e; do write_blob "crates/$f/tests.rs" "$(python3 -c 'print("quiet\n" * 3153 + "envelope_line\n", end="")')"; done
run_fg 77 --paths crates/extensions/src/process/tests.rs --expect crates/extensions/src/process/tests.rs:3154:envelope_line --dry
assert_rc 4 'alternate suggestion sorts first'
[ "$(grep '^  did you mean:' "$T/out" | head -n 1)" = '  did you mean: crates/extensions/src/process_tests.rs:3154' ] || fail "spelling alternate did not sort first: $(cat "$T/out")"

reset_case
run_fg 77 --paths docs/tui.md --expect docs/missing.md:1:needle --dry
assert_rc 4 'expect file absent from tree'
assert_out 'MISSING docs/missing.md' 'missing expect file output'

reset_case
write_blob docs/tui.md 'needle\n'
run_fg 77 --paths docs/tui.md --expect docs/tui.md:1:needle --dry
assert_rc 0 'expected symbol present'
assert_out "$(printf 'GRANT docs/tui.md\nGRANT')" 'expected symbol present output'

# --repo routes every gh call, including the suggestion content read.
reset_case
write_blob docs/tui.md 'needle\n'
set_pr 11 fix/other docs/tui.md
cat >"$T/pr/11.diff" <<'DIFF'
diff --git a/docs/tui.md b/docs/tui.md
index 1111111..2222222 100644
--- a/docs/tui.md
+++ b/docs/tui.md
@@ -1,1 +1,1 @@
-needle
+changed
DIFF
run_fg 77 --paths docs/tui.md --expect docs/tui.md:1:needle --repo other/x --dry
assert_rc 1 'repo routing'
grep -qF 'api repos/other/x/git/trees/main?recursive=1' "$T/gh.log" || fail 'tree query uses --repo'
grep -qF 'api repos/other/x/contents/docs/tui.md?ref=main' "$T/gh.log" || fail 'blob fetch uses --repo'
[ "$(grep -cF 'api repos/other/x/contents/docs/tui.md?ref=main' "$T/gh.log")" = 2 ] || fail 'suggestion content fetch uses --repo'
grep -qF 'pr list -R other/x ' "$T/gh.log" || fail 'PR list uses --repo'
grep -qF 'pr diff 11 -R other/x --name-only' "$T/gh.log" || fail 'PR names use --repo'
grep -qF 'pr diff 11 -R other/x --allow-escape-sequences' "$T/gh.log" || fail 'PR diff uses --repo'

reset_case
run_fg 77 --paths=docs/tui.md --repo=other/x --dry
assert_rc 0 '--repo equals form'
grep -qF 'api repos/other/x/git/trees/main?recursive=1' "$T/gh.log" || fail 'repo equals form uses requested repo'

echo 'fence-grant tests passed'

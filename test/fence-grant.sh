#!/usr/bin/env bash
# Tests for bin/fence-grant. Exits non-zero on the first failed case.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FG="$SCRIPT_DIR/../bin/fence-grant"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-fence-grant.XXXXXX")"
export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tmp" "$T/run" "$T/stubs" "$T/blobs" "$T/pr"
export TMPDIR="$T/tmp" FW_RUN="$T/run" FW_GH="$T/stubs/gh" FW_CLAUDE="$T/stubs/claude" FW_SSH="$T/stubs/ssh" FW_BOX_HOST=stub-box
export GH_TREE="$T/tree.json" GH_PRLIST='[]' CLAUDE_JSON='[]' SSH_OUT

cat >"$FW_GH" <<'GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T/gh.log"
case "$1 $2" in
  'api '*)
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
  'pr list')
    [ "${GH_PRLIST_FAIL:-0}" = 1 ] && { echo 'pr list stub failure' >&2; exit 1; }
    [ -n "${GH_PRLIST_JSON:-}" ] && { printf '%s' "$GH_PRLIST_JSON"; exit 0; }
    printf '%s' "$GH_PRLIST"
    ;;
  'pr diff')
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
  : >"$T/gh.log"
  : >"$T/claude.log"
  : >"$T/ssh.log"
  rm -f "$FW_RUN"/fiber-*-fence-grant*.md "$FW_RUN"/.fence-grant.lock
  printf '%s\n' '{"truncated":false,"tree":[{"type":"blob","path":"docs/tui.md"}]}' >"$GH_TREE"
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

assert_no_grant() {
  [ -z "$(find "$FW_RUN" -name 'fiber-*-fence-grant*.md' -print)" ] || fail "$1: wrote grant file"
}

# Exit 0: a free path in dry mode prints the grant and writes nothing.
reset_case
run_fg 77 --paths docs/tui.md --dry
assert_rc 0 'free dry run'
assert_out "$(printf 'GRANT docs/tui.md\nGRANT')" 'free dry output'
assert_no_grant 'free dry run'

# Exit 3: a failed Claude lane probe fails closed and writes nothing.
reset_case
CLAUDE_FAIL=1
export CLAUDE_FAIL
run_fg 77 --paths docs/tui.md --dry
assert_rc 3 'claude failure'
[ "$(head -n 1 "$T/out")" = 'ERROR claude agents claude stub failure ' ] || fail "claude failure output: $(cat "$T/out")"
assert_no_grant 'claude failure'

# Exit 3: a failed box probe fails closed and writes nothing.
reset_case
SSH_FAIL=1
export SSH_FAIL
run_fg 77 --paths docs/tui.md --dry
assert_rc 3 'ssh failure'
[ "$(head -n 1 "$T/out")" = 'ERROR ssh box ssh stub failure ' ] || fail "ssh failure output: $(cat "$T/out")"
assert_no_grant 'ssh failure'

echo 'fence-grant tests passed'

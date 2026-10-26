#!/usr/bin/env bash
# Every tracked top-level bin/ script is mode 100755; bin/lib/ is sourced, not run, and is exempt.
# Usage: test/bin-modes.sh [ROOT]   (default: this repo). Fixture cases run first, in temp repos.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

check() {
  local root="$1" meta path mode bad=0
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $root" >&2; return 2; }
  while IFS=$'\t' read -r meta path; do
    [ -n "$path" ] || continue
    case "$path" in bin/*/*) continue;; bin/*) ;; *) continue;; esac
    mode="${meta%% *}"
    if [ "$mode" != 100755 ]; then
      echo "$path: mode $mode, want 100755 (git update-index --chmod=+x $path)"
      bad=1
    fi
  done < <(git -C "$root" ls-files -s -- bin)
  return "$bad"
}

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-bin-modes.XXXXXX")"
trap 'rm -rf "$T"' EXIT

MODE="$T/mode"
mkdir -p "$MODE/bin/lib"
printf 'x\n' >"$MODE/bin/tool"
printf 'x\n' >"$MODE/bin/lib/helper.sh"
git -C "$MODE" init -q
git -C "$MODE" add bin

out="$(check "$MODE")" && fail "644 top-level bin script exits 1"
grep -q '^bin/tool: mode 100644' <<<"$out" || fail "644 top-level bin script is named"
grep -q 'helper' <<<"$out" && fail "bin/lib/ at 644 is exempt"
git -C "$MODE" update-index --chmod=+x bin/tool
out="$(check "$MODE")" || fail "755 top-level bin script with 644 lib passes"
[ -z "$out" ] || fail "755 top-level bin script prints nothing: [$out]"

ROOT="${1:-$SCRIPT_DIR/..}"
out="$(check "$ROOT")" || { echo "$out" >&2; fail "tracked bin/ scripts are not all 100755"; }

echo "bin-modes: all cases passed"

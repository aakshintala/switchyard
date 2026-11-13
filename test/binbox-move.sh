#!/usr/bin/env bash
# Hermetic path and report-name checks for the moved flywheel tools.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
bin=$here/../bin
T=$(mktemp -d "${TMPDIR:-/tmp}/binbox-move.XXXXXX")
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/home" "$T/run" "$T/repo"
git -C "$T/repo" init -q
git -C "$T/repo" config user.name test
git -C "$T/repo" config user.email test@example.invalid
printf 'fixture\n' > "$T/repo/README.md"
git -C "$T/repo" add README.md
git -C "$T/repo" commit -qm fixture
git -C "$T/repo" branch -M main
git -C "$T/repo" update-ref refs/remotes/origin/main HEAD
printf 'A hermetic moved-slice brief test.\n' > "$T/notes.md"

(
  cd "$T"
  HOME="$T/home" FW_RUN="$T/run" RUN_DIR="$T/run" FW_REPO="$T/repo" \
    FW_WORKTREE_ROOT="$T/home/work/fiber-worktrees" SKIP_PATHS=1 TKT=1 \
    CLOSING='Part of #1448' bash "$bin/mkbrief.sh" 1448 feat/1448-binbox-test "$T/notes.md"
)
brief="$T/run/fiber-1448-orchestrator-brief.md"
test -s "$brief"
grep -F -- "$T/home/.agents/skills/implement/SKILL.md" "$brief" >/dev/null
grep -F -- "$T/home/work/fiber-worktrees/feat/1448-binbox-test" "$brief" >/dev/null
# Any absolute home path outside the hermetic $T tree is host-specific,
# whatever the caller's $HOME is.
if sed "s|$T|T|g" "$brief" | grep -E '(^|[^[:alnum:]_/])/(Users|home)/' >/dev/null; then
  echo 'FAIL mkbrief emits a host-specific home path' >&2
  exit 1
fi
grep -F -- 'Part of #1448' "$brief" >/dev/null
printf 'ok mkbrief-resolves-sibling-template-and-home-paths\n'

# The pi lane builds its fence grant itself after settling the plan; the
# rendered brief must not ask it to wait for flywheel admission.
(
  cd "$T"
  HOME="$T/home" FW_RUN="$T/run" RUN_DIR="$T/run" FW_REPO="$T/repo" \
    FW_WORKTREE_ROOT="$T/home/work/fiber-worktrees" SKIP_PATHS=1 TKT=1 PI=1 \
    bash "$bin/mkbrief.sh" 1476 feat/1476-pi-selfgrant "$T/notes.md"
)
pi_brief="$T/run/fiber-1476-orchestrator-brief.md"
test -s "$pi_brief"
if grep -Fq 'ADMITTED' "$pi_brief"; then
  echo 'FAIL pi brief still mentions ADMITTED' >&2
  exit 1
fi
if grep -Fq 'report PLANNED' "$pi_brief"; then
  echo 'FAIL pi brief still asks for a PLANNED report' >&2
  exit 1
fi
grep -F -- '~/.agents/bin/fence-grant 1476 --paths' "$pi_brief" >/dev/null || {
  echo 'FAIL pi brief omits the self-grant command' >&2
  exit 1
}
printf 'ok mkbrief-pi-self-grants-plan-files-without-admission-wait\n'

mkdir -p "$T/run/inbox/read" "$T/run/rulings"
printf 'STATUS: BLOCKED on fixture\n' > "$T/run/inbox/read/box-2465-20261109T120000Z-1-1.md"
out=$(FW_RUN="$T/run" bash "$bin/pending.sh")
printf '%s\n' "$out" | grep -E '^!2465 ' >/dev/null
printf 'ok pending-reads-box-report-name\n'

# Launch through a symlink from outside bin/: the script must still find its
# sibling helpers, and a Box-local relaunch must replace its old Box LANE block.
mkdir -p "$T/stubs" "$T/home/work/fiber" "$T/home/flywheel-inbox"
cat > "$T/stubs/uname" <<'EOF'
#!/bin/sh
echo Linux
EOF
cat > "$T/stubs/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GIT_LOG"
exit 0
EOF
cat > "$T/stubs/mkdir" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$T/stubs/claude" <<'EOF'
#!/bin/sh
case "${1:-}" in
  agents) [ "${2:-}" = --json ] && echo '[]' ;;
  stop) echo "stopped ${2:-}" ;;
  --bg)
n=0
[ ! -f "$CLAUDE_COUNT" ] || n=$(cat "$CLAUDE_COUNT")
n=$((n + 1))
printf '%s\n' "$n" > "$CLAUDE_COUNT"
printf '%s\n' "$*" >> "$CLAUDE_LOG"
printf 'backgrounded session %s\n' "fixture-$n"
  ;;
  *) exit 2 ;;
esac
EOF
cat > "$T/stubs/ssh" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in -o|-p|-i|-l|-F|-J|-L|-R) shift 2;; -*) shift;; *) break;; esac
done
[ $# -gt 0 ] || exit 0
shift
[ $# -gt 0 ] || exit 0
cd "$HOME" || exit 1
export PATH="$STUB_PATH:$PATH"
exec bash -c "$*"
EOF
cat > "$T/stubs/lanecheck" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$T/stubs/noop" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/stubs/"*
ln -s "$bin/boxlaunch.sh" "$T/boxlaunch-via-link"
touch "$T/run/fiber-1448-fence-grant-20261109T120000Z.md"
export STUB_PATH="$T/stubs" GIT_LOG="$T/git.log" CLAUDE_LOG="$T/claude.log" CLAUDE_COUNT="$T/claude.count"
for _ in 1 2; do
  HOME="$T/home" USER=fixture PATH="$T/stubs:$PATH" \
    FW_RUN="$T/run" RUN_DIR="$T/run" FW_BOX_RUN="$T/run" \
    FW_BOX_HOME="$T/home" FW_MAC_HOME="$T/home" FW_BOX_HOST=fixture \
    BOX_SSH="$T/stubs/ssh" FW_AGENTS_FF="$T/stubs/noop" \
    FW_BOXSTALE="$T/stubs/noop" FW_BOX_LANECHECK="$T/stubs/lanecheck" \
    bash "$T/boxlaunch-via-link" 1448 sonnet >/dev/null
done
[ "$(cat "$CLAUDE_COUNT")" = 2 ]
[ "$(grep -c '^BOX LANE:' "$T/run/fiber-1448-orchestrator-brief.md")" = 1 ]
[ "$(grep -c '^--bg ' "$CLAUDE_LOG")" = 2 ]
[ "$(grep -c 'fetch -q origin' "$GIT_LOG")" -eq 2 ]
printf 'ok boxlaunch-resolves-symlinked-siblings-and-replaces-box-lane-block\n'

#!/usr/bin/env bash
# Real fixture worktrees; gh and lsof stand in for host/network boundaries.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
REAP="$D/../bin/target-reap"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-target-reap.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export CARGO_SLOT_DIR="$T/slots"
mkdir -p "$T/bin" "$T/trees" "$CARGO_SLOT_DIR"
cat >"$T/bin/lsof" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = +D ]; then
  [ "$2" != "${BUSY_TREE:-}" ] || { echo 'p123'; exit 0; }
  [ "$2" != "${LSOF_ERROR_TREE:-}" ] || { echo 'lsof: permission denied' >&2; exit 1; }
fi
if [ "$1" = -a ]; then
  [ "${LOCK_CWD:-}" = '' ] || { printf 'p123\nn%s\n' "$LOCK_CWD"; exit 0; }
fi
exit 1
STUB
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = 'pr list' ] || exit 2
case "$PWD" in
  */closed) printf '[{"state":"CLOSED","headRefOid":"%s"}]\n' "$(git rev-parse HEAD)";;
  */old-pr) echo '[{"state":"CLOSED","headRefOid":"0000000000000000000000000000000000000000"}]';;
  */open-pr) printf '[{"state":"OPEN","headRefOid":"%s"}]\n' "$(git rev-parse HEAD)";;
  *) exit 1;;
esac
STUB
chmod +x "$T/bin/lsof" "$T/bin/gh"
export PATH="$T/bin:$PATH"
fail() { echo "FAIL: $*" >&2; exit 1; }
git init -q -b trunk "$T/repo"
git -C "$T/repo" config user.name Test
git -C "$T/repo" config user.email test@example.com
git -C "$T/repo" config commit.gpgsign false
printf 'target/\n' >"$T/repo/.gitignore"
git -C "$T/repo" add .gitignore
git -C "$T/repo" commit -qm init
git -C "$T/repo" update-ref refs/remotes/origin/trunk HEAD
git -C "$T/repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
new_tree() {
  git -C "$T/repo" worktree add -qb "${1// /-}" "$T/trees/$1"
  mkdir "$T/trees/$1/target"
  printf 'artifact\n' >"$T/trees/$1/target/build"
}
new_tree 'merged ticket'
out="$(python3 "$REAP" "$T/trees")" || fail 'dry run failed'
[[ "$out" == *"$T/trees/merged ticket"* && "$out" == *'bytes'* ]] || fail 'dry run did not report bytes and worktree'
[ -f "$T/trees/merged ticket/target/build" ] || fail 'dry run removed target'
out="$(python3 "$REAP" --apply "$T/trees")" || fail 'apply failed'
[ ! -e "$T/trees/merged ticket/target" ] || fail 'apply kept reclaimable target'
[ -f "$T/trees/merged ticket/.gitignore" ] || fail 'apply removed worktree content'
git -C "$T/repo" show-ref --verify --quiet refs/heads/merged-ticket || fail 'apply removed branch'
# Each safety guard keeps the exact target, while adjacent content survives.
for name in dirty busy lsof-error unmerged locked symlink; do new_tree "$name"; done
printf 'dirty\n' >"$T/trees/dirty/untracked"
export BUSY_TREE="$T/trees/busy" LSOF_ERROR_TREE="$T/trees/lsof-error"
printf 'new\n' >"$T/trees/unmerged/new"
git -C "$T/trees/unmerged" add new
git -C "$T/trees/unmerged" commit -qm unmerged
mv "$T/trees/symlink/target" "$T/outside-target"
ln -s "$T/outside-target" "$T/trees/symlink/target"
# A label naming the worktree blocks reaping even if its PID is stale.
printf '999999 cargo build --manifest-path %s/Cargo.toml\n' "$T/trees/locked" >"$CARGO_SLOT_DIR/slot-1.lock"
out="$(python3 "$REAP" --apply "$T/trees")" || fail 'guard run failed'
for name in dirty busy lsof-error unmerged locked symlink; do
  [ -f "$T/trees/$name/target/build" ] || fail "removed protected $name target"
  [[ "$out" != *"$T/trees/$name:"* ]] || fail "reported protected $name target"
done
[ -f "$T/outside-target/build" ] || fail 'followed target symlink'
# A PID-only cargo-slot label is resolved through the holder's cwd.
new_tree pid-locked
printf '%s cargo build\n' "$$" >"$CARGO_SLOT_DIR/slot-1.lock"
export LOCK_CWD="$T/trees/pid-locked"
out="$(python3 "$REAP" --apply "$T/trees/pid-locked")" || fail 'PID lock run failed'
[ -f "$T/trees/pid-locked/target/build" ] || fail 'ignored holder cwd'
rm "$CARGO_SLOT_DIR/slot-1.lock"
unset LOCK_CWD

# Closed PRs allow unmerged heads; open PRs and closed PRs for old heads do not.
for name in closed old-pr open-pr; do
  new_tree "$name"
  printf 'new\n' >"$T/trees/$name/new"
  git -C "$T/trees/$name" add new
  git -C "$T/trees/$name" commit -qm "$name"
done
out="$(python3 "$REAP" --apply "$T/trees/closed" "$T/trees/old-pr" "$T/trees/open-pr")" || fail 'PR run failed'
[ ! -e "$T/trees/closed/target" ] || fail 'closed PR kept target'
[ -f "$T/trees/old-pr/target/build" ] || fail 'old PR allowed new head'
[ -f "$T/trees/open-pr/target/build" ] || fail 'open PR allowed unmerged head'
# Inherited Git context must not substitute a different checkout's clean status.
out="$(GIT_DIR="$T/repo/.git" GIT_WORK_TREE="$T/repo" python3 "$REAP" --apply "$T/trees/dirty")" || fail 'inherited Git context run failed'
[ -f "$T/trees/dirty/target/build" ] || fail 'inherited Git context bypassed dirty guard'
# Registered nested worktrees are included, but registered siblings outside
# the supplied root are never touched. Overlapping roots count each tree once.
mkdir -p "$T/repo/tickets"
printf 'tickets/\n' >>"$T/repo/.git/info/exclude"
git -C "$T/repo" worktree add -qb nested "$T/repo/tickets/nested"
mkdir "$T/repo/tickets/nested/target"
printf 'nested artifact\n' >"$T/repo/tickets/nested/target/build"
new_tree outside
out="$(python3 "$REAP" --apply "$T/repo" "$T/repo/tickets")" || fail 'nested run failed'
[ ! -e "$T/repo/tickets/nested/target" ] || fail 'missed nested worktree'
[ -f "$T/trees/outside/target/build" ] || fail 'removed worktree outside roots'
[ "$(grep -c "$T/repo/tickets/nested:" <<<"$out")" = 1 ] || fail 'counted overlapping roots twice'
python3 - "$out" <<'CHECK'
import re
import sys
lines = sys.argv[1].splitlines()
amounts = [int(re.search(r': (\d+) bytes freed$', line)[1]) for line in lines]
assert len(amounts) == 2 and amounts[0] > 0 and amounts[0] == amounts[1], lines
CHECK
echo 'target-reap: all cases passed'

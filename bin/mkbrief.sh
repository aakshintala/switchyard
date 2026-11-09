#!/usr/bin/env bash
# mkbrief <issue> <branch> <notes-file>  -> $HOME/work/fiber-worktrees/flywheel/run/fiber-<issue>-orchestrator-brief.md
# PI=1 (with TKT=1): the pi/muse RPC lane template, template-pi.md in lib/.
# TKT=1: state-mode brief from template-tkt.md in lib/ plus run/fiber-<issue>-extra.md; CLOSING fills __CLOSING__ (default "Resolves #<n>").
# RUN_DIR and TPL_DIR override the run and template directories (tests).
set -euo pipefail
script_path=$0
while [ -L "$script_path" ]; do
  script_dir=$(cd "$(dirname "$script_path")" && pwd)
  link=$(readlink "$script_path")
  case "$link" in /*) script_path=$link;; *) script_path=$script_dir/$link;; esac
done
script_dir=$(cd "$(dirname "$script_path")" && pwd)
T=${TPL_DIR:-$script_dir}; n=$1; br=$2
R=${FW_RUN:-${RUN_DIR:-$HOME/work/fiber-worktrees/flywheel/run}}
out=$R/fiber-${TAG:-$n}-orchestrator-brief.md
REPO=${FW_REPO:-$HOME/work/fiber}
WORKTREES=${FW_WORKTREE_ROOT:-$HOME/work/fiber-worktrees}
L=${FW_LIB:-$script_dir/lib/fw-lib.sh}
. "$L"
# The model pool, from bin/lib/pool.md and nowhere else (switchyard #1065). Every
# template carries `__POOL__` instead of its own wording, so a pool swap is one
# edit. Refusing on a missing or empty file rather than falling back to a baked
# default: a default here would be a fourth place the pool can be set, which is
# the defect.
pool_f=${POOL_FILE:-$T/lib/pool.md}
pool=$(grep -v '^#' "$pool_f" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)
[ -n "$pool" ] || { echo "no model pool: $pool_f is missing or has no non-comment line" >&2; exit 2; }
pool_esc=$(printf '%s' "$pool" | sed 's/[\\&|]/\\&/g')
# The parent session a Mac --bg lane SendMessages its report to. bglaunch.sh
# refuses to launch without a real one; the bare name here keeps a box or pi
# brief (which reports by inbox, not SendMessage) buildable.
parent=$(FW_RUN=$R fw_parent || printf 'flywheel')
case $br in main/*|main) echo "branch $br: main/ cannot exist beside the main branch; use the crate name (bin/, provider/...)" >&2; exit 2;; esac
# A path is not a branch. #4111's plan-phase brief was built with
# `mkbrief.sh 4111 crates/main/tests/panel_look.rs <notes>`, which this script
# accepted: the brief then said `branch crates/main/tests/panel_look.rs` and
# every `cd` line in it pointed at a worktree that cannot exist. The arg order
# is <issue> <branch> <notes-file>, and a branch that names a tracked file is
# always the second argument landing in the first branch slot.
if git -C "$REPO" cat-file -e "origin/main:$br" 2>/dev/null; then
  echo "branch $br names a path tracked on origin/main; the args are <issue> <branch> <notes-file>" >&2
  exit 2
fi
other=$(git -C "$REPO" worktree list --porcelain | awk '/^worktree /{print $2}' | grep -E "/$n-[^/]*$" | grep -vx "$WORKTREES/$br" || true)
[ -z "${TAG:-}" ] && [ -n "$other" ] && { echo "#$n already has a worktree at $other; pass its branch, or remove it first" >&2; exit 2; }
# Every path the notes name must exist on origin/main unless its line says it is new (SKIP_PATHS=1 skips; tests).
# Two greps, not one: the first takes a path with its WHOLE extension, the
# second keeps the extensions we check, anchored at the end. One grep with the
# extension list inline matched a prefix of an extension -- `seeded.jsonl` hit
# the `json` branch and was reported as a missing `seeded.json`, which blocked
# #4234's brief on a file that is on origin/main. Anchoring closes the class,
# not just that one extension.
if [ -z "${SKIP_PATHS:-}" ]; then
  bad=$(grep -vi 'new' "$3" | grep -oE '(crates|docs|scripts|research|xtask|\.github)/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' | grep -E '\.(rs|md|toml|yml|yaml|sh|lua|jsonl|json)$' | sort -u | while read -r p; do
    git -C "$REPO" cat-file -e "origin/main:$p" 2>/dev/null || echo "$p"; done) || true
  [ -n "$bad" ] && { printf 'notes name paths missing on origin/main (git fetch first, or mark the line "new"):\n%s\n' "$bad" >&2; exit 2; }
fi
if [ "${TKT:-}" = 1 ]; then
  tpl=$T/lib/template-tkt.md; [ "${PI:-}" = 1 ] && tpl=$T/lib/template-pi.md
  closing=${CLOSING:-Resolves #$n}; closing_esc=$(printf '%s' "$closing" | sed 's/[\\&|]/\\&/g')
  # The extra file is an input, not an output: it holds the one project rule
  # this ticket turns on, written by whoever briefs the lane. Writing it with
  # `>` destroyed that (2026-11-04, #4152: a floors-are-measured rule was
  # replaced by the clock default, silently, between writing the notes and
  # launching). Seed it only when it is absent, so a hand-written rule stands
  # and a lane briefed without one still gets a real rule rather than a blank.
  [ -s "$R/fiber-$n-extra.md" ] || printf '%s\n' 'Time-dependent behaviour is tested under an injected clock; no test reads or sleeps on the real clock, and a test advances a fake clock only after a signal that the code under test is waiting on it (docs/testing.md "Waits and timeouts").' > "$R/fiber-$n-extra.md"
  printf '%s\n' "Ticket #$n. Read it with gh issue view $n. Closing line: $closing." > "$R/fiber-$n-spec.md"
  fill="s|__RUN__|$R|g; s|__CLOSING__|$closing_esc|g; s|__N__|$n|g; s|__BR__|$br|g; s|__PARENT__|$parent|g; s|__POOL__|$pool_esc|g"
else
  # A forgotten TKT=1 is invisible after the fact. The Claude template writes
  # to the same path as the state-mode one, so the brief looks built and a muse
  # lane dispatched with it is reading instructions for a harness it is not.
  # Every lane has run on muse since the no-Claude ruling (2026-11-04), which
  # makes template.md dead by default rather than a choice, so it now has to be
  # asked for by name. Refusing, not warning: the two outputs are
  # indistinguishable once written, which is the whole defect.
  [ "${CLAUDE_TPL:-}" = 1 ] || { echo "no TKT=1: that builds the Claude template (template.md) to the same path as the lane brief. Pass TKT=1 (with PI=1 for a muse lane), or CLAUDE_TPL=1 if you really mean the Claude template." >&2; exit 2; }
  tpl=$T/lib/template.md; fill="s|__N__|$n|g; s|__BR__|$br|g; s|__PARENT__|$parent|g; s|__POOL__|$pool_esc|g"
fi
filled=$(sed -e "s|/Users/aakshintala|$HOME|g" -e "s|/home/aakshintala|$HOME|g" -e "$fill" "$tpl")
# No placeholder reaches a launched brief. #4111 shipped a brief naming a
# worktree that could not exist, and switchyard #1065's pool swap shipped two
# briefs on the old pool; both were visible in the built file and nothing
# looked. This looks, for every placeholder at once, rather than one guard per
# placeholder added after each incident -- and it refuses before writing, so
# there is no half-built brief for a launcher to pick up.
#
# Only the filled template is checked, never the ticket notes: the notes are
# prose I write, and a ticket about a macro or an env var can name one of these
# legitimately.
left=$(printf '%s\n' "$filled" | grep -o '__[A-Z_]\{2,\}__' | sort -u | tr '\n' ' ') || true
[ -z "$left" ] || { echo "template $tpl still holds unfilled placeholders: $left" >&2; exit 2; }
{ printf '%s\n' "$filled"; echo "Ticket notes (#$n; the notes say whether the PR resolves #$n or is Part of it):"; cat "$3"; } > "$out"
st="If it exists (a stopped lane cut it), work in it; otherwise cut it first (see the worktree add line below)."
python3 - "$out" "$WORKTREES/$br" "$br" "$st" <<'PY'
import pathlib, sys
path, worktrees, branch, extra = sys.argv[1:]
text = pathlib.Path(path).read_text()
needle = f"- Worktree `{worktrees}` on branch `{branch}`, cut from origin/main."
text = text.replace(needle, needle + " " + extra)
pathlib.Path(path).write_text(text)
PY
echo "Read $out and follow it."

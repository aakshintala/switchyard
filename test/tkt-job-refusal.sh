#!/usr/bin/env bash
# Every orchestrator tkt-* entry point refuses delegate context before reading
# or changing ticket state. tkt-state remains an allowed worker tool.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-tkt-job-refusal.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/tmp"
export HOME="$T/tmp/home" TMPDIR="$T/tmp"
mkdir -p "$HOME"

STATE="$T/ticket.state"
JOURNAL="${STATE%.state}.journal"
printf 'sentinel=unchanged\n' >"$STATE"
printf 'journal sentinel\n' >"$JOURNAL"
printf 'brief\n' >"$T/brief.md"
printf 'spec\n' >"$T/spec.md"
printf 'workflow\n' >"$T/workflow.md"
cp "$STATE" "$T/state.before"
cp "$JOURNAL" "$T/journal.before"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# One row per entry point: the tool, then its arguments, all split on "|".
# Each row runs the same way, so a new tkt-* tool needs only a row here.
CASES=(
  "tkt-drive|$STATE"
  "tkt-fix|$STATE|--no-verify"
  "tkt-job|$STATE|--slot|lane|--brief|$T/brief.md"
  "tkt-build|$STATE"
  "tkt-plan|$STATE|verify"
  "tkt-verify|$STATE|--findings|$T/brief.md"
  "tkt-gate|$STATE"
  "tkt-ship|$STATE"
  "tkt-start|--run|$T/run|--repo|acme/switchyard|--issue|123|--spec|$T/spec.md|--branch|refusal-test|--worktree|$T/worktree|--workflow-doc|$T/workflow.md|--closing|Resolves #123|--no-preflight"
)

# Pinned copy of bin/lib/job-refusal.sh's wording, so a change to it fails here.
REFUSAL=": refusing to run inside delegate job refusal-fixture: a delegate job never runs the orchestrator's tkt-* tools; report to your orchestrator instead; if this is a top-level session, DELEGATE_JOB_ID leaked from its launcher (#1748): report that to switchyard"

for row in "${CASES[@]}"; do
  IFS='|' read -r -a args <<<"$row"
  tool="${args[0]}"
  stdout="$T/$tool.stdout"
  stderr="$T/$tool.stderr"
  rc=0
  DELEGATE_JOB_ID=refusal-fixture bash "$ROOT/bin/$tool" "${args[@]:1}" >"$stdout" 2>"$stderr" || rc=$?
  [ "$rc" -eq 2 ] || fail "$tool exited $rc instead of 2 (stdout: $(cat "$stdout"); stderr: $(cat "$stderr"))"
  [ ! -s "$stdout" ] || fail "$tool wrote stdout: $(cat "$stdout")"
  printf '%s%s\n' "$tool" "$REFUSAL" >"$T/expected.err"
  cmp -s "$T/expected.err" "$stderr" || fail "$tool refusal wording differs: $(cat "$stderr")"
  cmp -s "$T/state.before" "$STATE" || fail "$tool changed the state file"
  cmp -s "$T/journal.before" "$JOURNAL" || fail "$tool changed the journal"
done

echo 'tkt-job-refusal: all cases passed'

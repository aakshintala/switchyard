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

for tool in tkt-drive tkt-fix tkt-job tkt-build tkt-plan tkt-verify tkt-gate tkt-ship tkt-start; do
  stdout="$T/$tool.stdout"
  stderr="$T/$tool.stderr"
  rc=0
  case "$tool" in
    tkt-drive) DELEGATE_JOB_ID=refusal-fixture bash "$ROOT/bin/$tool" "$STATE" >"$stdout" 2>"$stderr" || rc=$? ;;
    tkt-fix) DELEGATE_JOB_ID=refusal-fixture bash "$ROOT/bin/$tool" "$STATE" --no-verify >"$stdout" 2>"$stderr" || rc=$? ;;
    tkt-job) DELEGATE_JOB_ID=refusal-fixture bash "$ROOT/bin/$tool" "$STATE" --slot lane --brief "$T/brief.md" >"$stdout" 2>"$stderr" || rc=$? ;;
    tkt-build) DELEGATE_JOB_ID=refusal-fixture bash "$ROOT/bin/$tool" "$STATE" >"$stdout" 2>"$stderr" || rc=$? ;;
    tkt-plan) DELEGATE_JOB_ID=refusal-fixture bash "$ROOT/bin/$tool" "$STATE" verify >"$stdout" 2>"$stderr" || rc=$? ;;
    tkt-verify) DELEGATE_JOB_ID=refusal-fixture bash "$ROOT/bin/$tool" "$STATE" --findings "$T/brief.md" >"$stdout" 2>"$stderr" || rc=$? ;;
    tkt-gate) DELEGATE_JOB_ID=refusal-fixture bash "$ROOT/bin/$tool" "$STATE" >"$stdout" 2>"$stderr" || rc=$? ;;
    tkt-ship) DELEGATE_JOB_ID=refusal-fixture bash "$ROOT/bin/$tool" "$STATE" >"$stdout" 2>"$stderr" || rc=$? ;;
    tkt-start)
      DELEGATE_JOB_ID=refusal-fixture bash "$ROOT/bin/$tool" \
        --run "$T/run" --repo acme/switchyard --issue 123 --spec "$T/spec.md" \
        --branch refusal-test --worktree "$T/worktree" --workflow-doc "$T/workflow.md" \
        --closing 'Resolves #123' --no-preflight >"$stdout" 2>"$stderr" || rc=$?
      ;;
  esac
  [ "$rc" -eq 2 ] || fail "$tool exited $rc instead of 2 (stdout: $(cat "$stdout"); stderr: $(cat "$stderr"))"
  [ ! -s "$stdout" ] || fail "$tool wrote stdout: $(cat "$stdout")"
  printf '%s\n' "$tool: refusing to run inside delegate job refusal-fixture: a lane never runs the orchestrator's tkt-* tools; report to your orchestrator instead; if this is a top-level session, DELEGATE_JOB_ID leaked from its launcher (#1748): report that to switchyard" >"$T/expected.err"
  cmp -s "$T/expected.err" "$stderr" || fail "$tool refusal wording differs: $(cat "$stderr")"
  cmp -s "$T/state.before" "$STATE" || fail "$tool changed the state file"
  cmp -s "$T/journal.before" "$JOURNAL" || fail "$tool changed the journal"
done

echo 'tkt-job-refusal: all cases passed'

#!/usr/bin/env bash
# Tests for bin/model-deprecations using a stub delegate and temporary inboxes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$ROOT/bin/model-deprecations"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-model-deprecations.XXXXXX")"
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"
trap 'rm -rf "$T"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

STUBS="$T/stubs"
mkdir -p "$STUBS"
cat >"$STUBS/delegate" <<'DELEGATE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  run)
    shift
    model=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --model) model="$2"; shift 2 ;;
        --cwd) shift 2 ;;
        *) echo "unexpected delegate run argument" >&2; exit 2 ;;
      esac
    done
    prompt="$(cat)"
    printf 'run model=%s\n' "$model" >>"$DELEGATE_CALLS"
    printf '%s\n' "$prompt" >"$DELEGATE_PROMPT"
    if [ "${DEPRECATIONS_STUB_MODE:-report}" = report ] || [ "${DEPRECATIONS_STUB_MODE:-report}" = invalid ]; then
      report_path="$(sed -n 's/^Scratch report path (write only the report here): //p' <<<"$prompt")"
      report_date="$(sed -n 's/^Report date: //p' <<<"$prompt")"
      source_line="$(sed -n 's/^Source line: //p' <<<"$prompt")"
      if [ "${DEPRECATIONS_STUB_MODE:-report}" = invalid ]; then
        printf '# Wrong heading\n' >"$report_path"
      else
        cat >"$report_path" <<REPORT
# Model deprecations $report_date
$source_line

## anthropic

| model | kind | field | vendor | models.dev |
|---|---|---|---|---|
| claude-old | deprecated | retirement date | 2026-10-01 (source: https://platform.claude.com/docs/en/about-claude/model-deprecations) | - |
| claude-retired | retired | source | https://platform.claude.com/docs/en/about-claude/model-deprecations | - |
| claude-new | new | source | https://platform.claude.com/docs/en/about-claude/model-deprecations | - |

## skipped
- muse: page unavailable (fixture)
REPORT
      fi
    fi
    echo "12345678-1234-1234-1234-123456789abc"
    ;;
  watch)
    shift
    [ "$#" -eq 1 ] || { echo "unexpected delegate watch arguments" >&2; exit 2; }
    printf 'watch %s\n' "$1" >>"$DELEGATE_CALLS"
    ;;
  *) echo "unexpected delegate command" >&2; exit 2 ;;
esac
DELEGATE
chmod +x "$STUBS/delegate"

export PATH="$STUBS:$PATH"
export DELEGATE_CALLS="$T/delegate-calls"
export DELEGATE_PROMPT="$T/delegate-prompt"
export MODEL_DEPRECATIONS_TODAY=2026-05-04
: >"$DELEGATE_CALLS"

# The checked-in brief names every vendor page and the required report layout.
BRIEF="$ROOT/bin/lib/model-deprecations-brief.md"
for vendor in Anthropic OpenAI Gemini OpenRouter Databricks Muse; do
  grep -q "^- $vendor:" "$BRIEF" || fail "brief page list missing $vendor"
done
for value in 'model | kind | field | vendor | models.dev' '## skipped' 'tool allowlist' 'prompt-only restriction'; do
  grep -qi "$value" "$BRIEF" || fail "brief missing $value"
done

# Default run asks for exactly one delegate job and atomically publishes its validated report.
INBOX="$T/inbox"
MODEL_CATALOG_INBOX="$INBOX" bash "$BIN" run >"$T/run.out" 2>"$T/run.err" || fail "run failed: $(cat "$T/run.err")"
[ ! -s "$T/run.err" ] || fail "successful run wrote stderr: $(cat "$T/run.err")"
REPORT="$INBOX/model-deprecations-2026-05-04.md"
[ -f "$REPORT" ] || fail "report was not moved into the inbox"
grep -q '^# Model deprecations 2026-05-04$' "$REPORT" || fail "report heading missing"
grep -q '^source: model-deprecations [0-9a-f]\{4,40\}$' "$REPORT" || fail "source line missing"
grep -q '^| model | kind | field | vendor | models.dev |$' "$REPORT" || fail "shared table header missing"
grep -q '^| claude-old | deprecated | retirement date | 2026-10-01 (source: https://platform.claude.com/' "$REPORT" || fail "deprecated row or source missing"
grep -q '^| claude-retired | retired | source | https://platform.claude.com/' "$REPORT" || fail "retired row or source missing"
grep -q '^| claude-new | new | source | https://platform.claude.com/' "$REPORT" || fail "new row or source missing"
grep -q '^## skipped$' "$REPORT" || fail "skipped section missing"
grep -q '^- muse: page unavailable (fixture)$' "$REPORT" || fail "failed page entry missing"
[ -z "$(find "$INBOX" -maxdepth 1 -name '.model-deprecations-*.tmp' -print -quit)" ] || fail "atomic inbox temporary file was left behind"
[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ] || fail "delegate scratch directory was left behind"
[ "$(grep -c '^run ' "$DELEGATE_CALLS")" -eq 1 ] || fail "run did not make exactly one delegate run"
[ "$(grep -c '^watch ' "$DELEGATE_CALLS")" -eq 1 ] || fail "delegate job was not waited on"
grep -q '^run model=muse/muse-spark-1.3-contributor$' "$DELEGATE_CALLS" || fail "default standard-rung Muse model was not selected"
grep -q '^Report date: 2026-05-04$' "$DELEGATE_PROMPT" || fail "date was not passed to the model"

# An empty job writes nothing and can use a configured model.
: >"$DELEGATE_CALLS"
EMPTY_INBOX="$T/empty-inbox"
DEPRECATIONS_STUB_MODE=empty MODEL_DEPRECATIONS_MODEL=custom/test-model MODEL_CATALOG_INBOX="$EMPTY_INBOX" \
  bash "$BIN" run >"$T/empty.out" 2>"$T/empty.err" || fail "empty run failed: $(cat "$T/empty.err")"
[ ! -s "$T/empty.out" ] && [ ! -s "$T/empty.err" ] || fail "empty result was not quiet"
[ ! -e "$EMPTY_INBOX" ] || fail "empty result wrote a report"
[ "$(grep -c '^run ' "$DELEGATE_CALLS")" -eq 1 ] || fail "empty result made more than one delegate run"
grep -q '^run model=custom/test-model$' "$DELEGATE_CALLS" || fail "MODEL_DEPRECATIONS_MODEL override was ignored"
[ "$(grep -c '^watch ' "$DELEGATE_CALLS")" -eq 1 ] || fail "empty delegate job was not waited on"

# Invalid model output is rejected before it can enter the inbox.
INVALID_INBOX="$T/invalid-inbox"
if DEPRECATIONS_STUB_MODE=invalid MODEL_CATALOG_INBOX="$INVALID_INBOX" bash "$BIN" run >"$T/invalid.out" 2>"$T/invalid.err"; then
  fail "invalid report was accepted"
fi
[ ! -e "$INVALID_INBOX" ] || fail "invalid report reached the inbox"
grep -q 'invalid report heading' "$T/invalid.err" || fail "invalid report rejection was not clear"

# Invalid commands and timer settings stop before starting a delegate.
: >"$DELEGATE_CALLS"
if bash "$BIN" run unexpected >"$T/args.out" 2>"$T/args.err"; then fail "run accepted extra arguments"; else [ "$?" -eq 2 ] || fail "run argument error was not usage"; fi
if bash "$BIN" install --print --at monday 08:45 >"$T/day.out" 2>"$T/day.err"; then fail "install accepted invalid day"; else [ "$?" -eq 2 ] || fail "invalid day error was not usage"; fi
if bash "$BIN" install --print --at Mon 24:00 >"$T/time.out" 2>"$T/time.err"; then fail "install accepted invalid time"; else [ "$?" -eq 2 ] || fail "invalid time error was not usage"; fi
[ ! -s "$DELEGATE_CALLS" ] || fail "argument error started a delegate job"

# Print mode shows the weekly schedule without writing units; default is Monday 08:45.
PRINT_HOME="$T/print-home"
XDG_CONFIG_HOME="$PRINT_HOME" HOME="$PRINT_HOME" bash "$BIN" install --print --at Thu 09:15 >"$T/print.txt" \
  || fail "install --print failed"
grep -q 'model-deprecations.service' "$T/print.txt" || fail "service missing from --print"
grep -q 'model-deprecations.timer' "$T/print.txt" || fail "timer missing from --print"
grep -q 'OnCalendar=Thu \*-\*-\* 09:15:00 UTC' "$T/print.txt" || fail "custom weekly schedule missing"
grep -q 'systemctl --user enable --now model-deprecations.timer' "$T/print.txt" || fail "enable command missing"
[ ! -e "$PRINT_HOME" ] || fail "--print wrote files"
XDG_CONFIG_HOME="$PRINT_HOME" HOME="$PRINT_HOME" bash "$BIN" install --print >"$T/default-print.txt" \
  || fail "default install --print failed"
grep -q 'OnCalendar=Mon \*-\*-\* 08:45:00 UTC' "$T/default-print.txt" || fail "default weekly schedule is not Monday 08:45"

# Real install mechanics are exercised with harmless systemd command stubs.
mkdir -p "$STUBS/install"
cat >"$STUBS/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_CALLS"
SYSTEMCTL
cat >"$STUBS/loginctl" <<'LOGINCTL'
#!/usr/bin/env bash
echo 'Linger=yes'
LOGINCTL
chmod +x "$STUBS/systemctl" "$STUBS/loginctl"
export SYSTEMCTL_CALLS="$T/systemctl-calls"
INSTALL_CONFIG="$T/actual-config"
PATH="$STUBS/install:$STUBS:$PATH" XDG_CONFIG_HOME="$INSTALL_CONFIG" HOME="$T/install-home" \
  bash "$BIN" install --at Sun 06:10 >"$T/install.out" 2>"$T/install.err" || fail "install failed: $(cat "$T/install.err")"
[ -f "$INSTALL_CONFIG/systemd/user/model-deprecations.service" ] || fail "service unit was not installed"
[ -f "$INSTALL_CONFIG/systemd/user/model-deprecations.timer" ] || fail "timer unit was not installed"
grep -q 'ExecStart=.*model-deprecations.* run' "$INSTALL_CONFIG/systemd/user/model-deprecations.service" || fail "service command missing"
grep -q 'OnCalendar=Sun \*-\*-\* 06:10:00 UTC' "$INSTALL_CONFIG/systemd/user/model-deprecations.timer" || fail "installed weekly schedule missing"
grep -q '^--user daemon-reload$' "$SYSTEMCTL_CALLS" || fail "daemon-reload was not called"
grep -q '^--user enable --now model-deprecations.timer$' "$SYSTEMCTL_CALLS" || fail "timer was not enabled"

printf 'model-deprecations: all cases passed\n'

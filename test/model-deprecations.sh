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
    cwd=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --model) model="$2"; shift 2 ;;
        --cwd) cwd="$2"; shift 2 ;;
        *) echo "unexpected delegate run argument" >&2; exit 2 ;;
      esac
    done
    prompt="$(cat)"
    report_path="$(sed -n 's/^Scratch report path (write only the report here): //p' <<<"$prompt")"
    empty=yes
    [ -z "$(find "$cwd" -mindepth 1 -print -quit)" ] || empty=no
    printf 'run model=%s cwd=%s scratch=%s empty=%s\n' "$model" "$cwd" "$report_path" "$empty" >>"$DELEGATE_CALLS"
    printf '%s\n' "$prompt" >"$DELEGATE_PROMPT"
    mkdir -p "$DELEGATE_JOBS_DIR"
    printf '{"status":"%s","result":{"status":"%s","text":"%s"}}\n' \
      "${DEPRECATIONS_STATUS:-DONE}" "${DEPRECATIONS_STATUS:-DONE}" "${DEPRECATIONS_RESULT_TEXT:-}" \
      >"$DELEGATE_JOBS_DIR/12345678-1234-1234-1234-123456789abc.json"
    if [ "${DEPRECATIONS_STUB_MODE:-report}" = report ] || [ "${DEPRECATIONS_STUB_MODE:-report}" = unknown ] || [ "${DEPRECATIONS_STUB_MODE:-report}" = duplicate ] || [ "${DEPRECATIONS_STUB_MODE:-report}" = capital ] || [ "${DEPRECATIONS_STUB_MODE:-report}" = empty ] || [ "${DEPRECATIONS_STUB_MODE:-report}" = blank ]; then
      report_date="$(sed -n 's/^Report date: //p' <<<"$prompt")"
      source_line="$(sed -n 's/^Source line: //p' <<<"$prompt")"
      if [ "${DEPRECATIONS_STUB_MODE:-report}" = empty ]; then
        printf '# Model deprecations %s\n%s\n\n## skipped\n' "$report_date" "$source_line" >"$report_path"
      elif [ "${DEPRECATIONS_STUB_MODE:-report}" = blank ]; then
        : >"$report_path"
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
- gemini: page unavailable (fixture)
REPORT
        case "${DEPRECATIONS_STUB_MODE:-report}" in
          capital) sed -i.bak -e 's/^## anthropic$/## Anthropic/' -e 's/^- gemini: /- Gemini: /' "$report_path"; rm -f "$report_path.bak" ;;
          unknown) sed -i.bak 's/^## anthropic$/## acme/' "$report_path"; rm -f "$report_path.bak" ;;
          duplicate) python3 - "$report_path" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text().replace("## anthropic", "## openai", 1)
s = s.replace("## skipped", "## OpenAI\n\n| model | kind | field | vendor | models.dev |\n|---|---|---|---|---|\n\n## skipped", 1)
p.write_text(s)
PY
          ;;
        esac
      fi
    fi
    echo "12345678-1234-1234-1234-123456789abc"
    if [ "${DEPRECATIONS_STUB_MODE:-report}" = run-fail ]; then exit 1; fi
    ;;
  watch)
    shift
    [ "$#" -eq 1 ] || { echo "unexpected delegate watch arguments" >&2; exit 2; }
    printf 'watch %s\n' "$1" >>"$DELEGATE_CALLS"
    if [ "${DEPRECATIONS_WATCH_RC:-0}" -ne 0 ]; then exit "$DEPRECATIONS_WATCH_RC"; fi
    ;;
  status)
    shift
    [ "$#" -eq 1 ] || { echo "unexpected delegate status arguments" >&2; exit 2; }
    printf 'status %s\n' "$1" >>"$DELEGATE_CALLS"
    printf '%s: %s (caller=fixture)\n' "$1" "${DEPRECATIONS_STATUS:-DONE}"
    ;;
  *) echo "unexpected delegate command" >&2; exit 2 ;;
esac
DELEGATE
chmod +x "$STUBS/delegate"

export PATH="$STUBS:$PATH"
export DELEGATE_CALLS="$T/delegate-calls"
export DELEGATE_PROMPT="$T/delegate-prompt"
export DELEGATE_JOBS_DIR="$T/delegate-jobs"
export MODEL_DEPRECATIONS_TODAY=2026-05-04
: >"$DELEGATE_CALLS"

# The checked-in brief names every vendor page and the required report layout.
BRIEF="$ROOT/bin/lib/model-deprecations-brief.md"
for vendor in Anthropic OpenAI Gemini OpenRouter Databricks; do
  grep -q "^- $vendor:" "$BRIEF" || fail "brief page list missing $vendor"
done
if grep -q '^- Muse:' "$BRIEF"; then fail "Muse API endpoint was left in the weekly page list"; fi
for value in 'model | kind | field | vendor | models.dev' '## skipped' 'Tools are not allowlisted' 'empty temporary working directory' 'caller script, not the model' 'Always write a complete report' 'caller script will publish nothing' 'https://ai.google.dev/gemini-api/docs/deprecations' 'OpenRouter is a catalog' 'There is no public Meta model lifecycle page' 'daily `model-catalog-diff` job covers Muse'; do
  grep -qi "$value" "$BRIEF" || fail "brief missing $value"
done

# Default run asks for exactly one delegate job and atomically publishes its validated report.
INBOX="$T/inbox"
MODEL_CATALOG_INBOX="$INBOX" DEPRECATIONS_STUB_MODE=capital bash "$BIN" run >"$T/run.out" 2>"$T/run.err" || fail "run failed: $(cat "$T/run.err")"
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
grep -q '^- Gemini: page unavailable (fixture)$' "$REPORT" || fail "failed page entry missing"
[ -z "$(find "$INBOX" -maxdepth 1 -name '.model-deprecations-*.tmp' -print -quit)" ] || fail "atomic inbox temporary file was left behind"
[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ] || fail "delegate scratch directory was left behind"
[ "$(grep -c '^run ' "$DELEGATE_CALLS")" -eq 1 ] || fail "run did not make exactly one delegate run"
[ "$(grep -c '^watch ' "$DELEGATE_CALLS")" -eq 1 ] || fail "delegate job was not waited on"
grep -q '^run model=fiber/codex/gpt-6-luna:medium cwd=' "$DELEGATE_CALLS" || fail "default allowed model fiber/codex/gpt-6-luna:medium was not selected"
RUN_LINE="$(grep '^run ' "$DELEGATE_CALLS")"
RUN_CWD="$(sed -E 's/.* cwd=([^ ]+) scratch=.*/\1/' <<<"$RUN_LINE")"
RUN_SCRATCH="$(sed -E 's/.* scratch=([^ ]+) empty=.*/\1/' <<<"$RUN_LINE")"
case "$RUN_CWD" in "$TMPDIR"/model-deprecations.*) ;; *) fail "delegate cwd was not a fresh temporary directory: $RUN_CWD" ;; esac
[ "$RUN_CWD" != "$ROOT" ] || fail "delegate cwd was the repository root"
[ "$RUN_SCRATCH" = "$RUN_CWD/report.md" ] || fail "scratch report was outside delegate cwd"
grep -q '^run .* empty=yes$' "$DELEGATE_CALLS" || fail "delegate cwd was not empty at job start"
grep -q '^Report date: 2026-05-04$' "$DELEGATE_PROMPT" || fail "date was not passed to the model"

# A DONE_WITH_CONCERNS job with a report publishes it with the delegate result text.
CONCERNS_INBOX="$T/concerns-inbox"
DEPRECATIONS_STATUS=DONE_WITH_CONCERNS DEPRECATIONS_RESULT_TEXT='Synthetic concern: one source needs follow-up.' \
  MODEL_CATALOG_INBOX="$CONCERNS_INBOX" bash "$BIN" run >"$T/concerns.out" 2>"$T/concerns.err" \
  || fail "DONE_WITH_CONCERNS report failed: $(cat "$T/concerns.err")"
CONCERNS_REPORT="$CONCERNS_INBOX/model-deprecations-2026-05-04.md"
[ -f "$CONCERNS_REPORT" ] || fail "DONE_WITH_CONCERNS report was not published"
grep -q '^# Model deprecations 2026-05-04$' "$CONCERNS_REPORT" || fail "DONE_WITH_CONCERNS report heading missing"
grep -q '^## concerns$' "$CONCERNS_REPORT" || fail "DONE_WITH_CONCERNS report has no concerns section"
grep -Fq 'Synthetic concern: one source needs follow-up.' "$CONCERNS_REPORT" || fail "delegate result text was not appended"

# A DONE_WITH_CONCERNS job with empty result text publishes the report without a concerns heading.
EMPTY_CONCERNS_INBOX="$T/empty-concerns-inbox"
DEPRECATIONS_STATUS=DONE_WITH_CONCERNS DEPRECATIONS_RESULT_TEXT='' \
  MODEL_CATALOG_INBOX="$EMPTY_CONCERNS_INBOX" bash "$BIN" run >"$T/empty-concerns.out" 2>"$T/empty-concerns.err" \
  || fail "DONE_WITH_CONCERNS empty-text report failed: $(cat "$T/empty-concerns.err")"
EMPTY_CONCERNS_REPORT="$EMPTY_CONCERNS_INBOX/model-deprecations-2026-05-04.md"
[ -f "$EMPTY_CONCERNS_REPORT" ] || fail "DONE_WITH_CONCERNS empty-text report was not published"
! grep -q '^## concerns$' "$EMPTY_CONCERNS_REPORT" || fail "empty result text left an empty concerns heading"

# A non-empty no-change report is still published for DONE_WITH_CONCERNS.
NO_CHANGE_CONCERNS_INBOX="$T/no-change-concerns-inbox"
DEPRECATIONS_STUB_MODE=empty DEPRECATIONS_STATUS=DONE_WITH_CONCERNS DEPRECATIONS_RESULT_TEXT='Synthetic concern for no-change report.' \
  MODEL_CATALOG_INBOX="$NO_CHANGE_CONCERNS_INBOX" bash "$BIN" run >"$T/no-change-concerns.out" 2>"$T/no-change-concerns.err" \
  || fail "DONE_WITH_CONCERNS no-change report failed: $(cat "$T/no-change-concerns.err")"
NO_CHANGE_CONCERNS_REPORT="$NO_CHANGE_CONCERNS_INBOX/model-deprecations-2026-05-04.md"
[ -f "$NO_CHANGE_CONCERNS_REPORT" ] || fail "DONE_WITH_CONCERNS no-change report was not published"
grep -Fq 'Synthetic concern for no-change report.' "$NO_CHANGE_CONCERNS_REPORT" || fail "no-change concern text was not appended"

# An empty job writes nothing and can use a configured model.
: >"$DELEGATE_CALLS"
EMPTY_INBOX="$T/empty-inbox"
DEPRECATIONS_STUB_MODE=empty MODEL_DEPRECATIONS_MODEL=custom/test-model MODEL_CATALOG_INBOX="$EMPTY_INBOX" \
  bash "$BIN" run >"$T/empty.out" 2>"$T/empty.err" || fail "empty run failed: $(cat "$T/empty.err")"
[ ! -s "$T/empty.out" ] && [ ! -s "$T/empty.err" ] || fail "empty result was not quiet"
[ ! -e "$EMPTY_INBOX" ] || fail "empty result wrote a report"
[ "$(grep -c '^run ' "$DELEGATE_CALLS")" -eq 1 ] || fail "empty result made more than one delegate run"
grep -q '^run model=custom/test-model cwd=' "$DELEGATE_CALLS" || fail "MODEL_DEPRECATIONS_MODEL override was ignored"
[ "$(grep -c '^watch ' "$DELEGATE_CALLS")" -eq 1 ] || fail "empty delegate job was not waited on"

# A missing scratch report is different from a valid no-change report.
MISSING_INBOX="$T/missing-inbox"
if DEPRECATIONS_STUB_MODE=missing MODEL_CATALOG_INBOX="$MISSING_INBOX" bash "$BIN" run >"$T/missing.out" 2>"$T/missing.err"; then
  fail "missing scratch report was accepted as no changes"
fi
MISSING_REPORT="$MISSING_INBOX/model-deprecations-2026-05-04.md"
[ -f "$MISSING_REPORT" ] || fail "missing scratch report did not publish a failure report"
grep -q '^- all: model produced no report (delegate status: DONE)$' "$MISSING_REPORT" || fail "missing report status was not recorded"
grep -q '^## skipped$' "$MISSING_REPORT" || fail "missing report failure has no skipped section"

# DONE_WITH_CONCERNS without a scratch report still publishes a failure report and fails.
CONCERNS_MISSING_INBOX="$T/concerns-missing-inbox"
if DEPRECATIONS_STUB_MODE=missing DEPRECATIONS_STATUS=DONE_WITH_CONCERNS MODEL_CATALOG_INBOX="$CONCERNS_MISSING_INBOX" \
  bash "$BIN" run >"$T/concerns-missing.out" 2>"$T/concerns-missing.err"; then
  fail "DONE_WITH_CONCERNS with a missing scratch report was accepted"
fi
CONCERNS_MISSING_REPORT="$CONCERNS_MISSING_INBOX/model-deprecations-2026-05-04.md"
[ -f "$CONCERNS_MISSING_REPORT" ] || fail "missing DONE_WITH_CONCERNS report did not publish failure report"
grep -q '^- all: model produced no report (delegate status: DONE_WITH_CONCERNS)$' "$CONCERNS_MISSING_REPORT" \
  || fail "missing DONE_WITH_CONCERNS report status was not recorded"

# An empty scratch report under DONE_WITH_CONCERNS is also a failure.
CONCERNS_EMPTY_INBOX="$T/concerns-empty-inbox"
if DEPRECATIONS_STUB_MODE=blank DEPRECATIONS_STATUS=DONE_WITH_CONCERNS MODEL_CATALOG_INBOX="$CONCERNS_EMPTY_INBOX" \
  bash "$BIN" run >"$T/concerns-empty.out" 2>"$T/concerns-empty.err"; then
  fail "DONE_WITH_CONCERNS with an empty scratch report was accepted"
fi
CONCERNS_EMPTY_REPORT="$CONCERNS_EMPTY_INBOX/model-deprecations-2026-05-04.md"
[ -f "$CONCERNS_EMPTY_REPORT" ] || fail "empty DONE_WITH_CONCERNS report did not publish failure report"
grep -q '^- all: model produced no report (delegate status: DONE_WITH_CONCERNS)$' "$CONCERNS_EMPTY_REPORT" \
  || fail "empty DONE_WITH_CONCERNS report status was not recorded"

# A job that did not finish with DONE publishes a failure report with its known status.
FAILED_INBOX="$T/failed-inbox"
if DEPRECATIONS_STATUS=ERROR MODEL_CATALOG_INBOX="$FAILED_INBOX" bash "$BIN" run >"$T/failed.out" 2>"$T/failed.err"; then
  fail "non-DONE delegate status was accepted"
fi
FAILED_REPORT="$FAILED_INBOX/model-deprecations-2026-05-04.md"
[ -f "$FAILED_REPORT" ] || fail "non-DONE job did not publish a failure report"
grep -q '^- all: model produced no report (delegate status: ERROR)$' "$FAILED_REPORT" || fail "non-DONE status was not recorded"

# A failed delegate run also publishes a failure report when its job status is known.
RUN_FAIL_INBOX="$T/run-fail-inbox"
if DEPRECATIONS_STUB_MODE=run-fail DEPRECATIONS_STATUS=FAILED MODEL_CATALOG_INBOX="$RUN_FAIL_INBOX" bash "$BIN" run >"$T/run-fail.out" 2>"$T/run-fail.err"; then
  fail "failed delegate run was accepted"
fi
RUN_FAIL_REPORT="$RUN_FAIL_INBOX/model-deprecations-2026-05-04.md"
[ -f "$RUN_FAIL_REPORT" ] || fail "failed delegate run did not publish a failure report"
grep -q '^- all: model produced no report (delegate status: FAILED)$' "$RUN_FAIL_REPORT" || fail "failed run status was not recorded"

# Invalid model output publishes a failure report and preserves the rejected report.
INVALID_INBOX="$T/invalid-inbox"
if DEPRECATIONS_STUB_MODE=unknown MODEL_CATALOG_INBOX="$INVALID_INBOX" bash "$BIN" run >"$T/invalid.out" 2>"$T/invalid.err"; then
  fail "unknown vendor report was accepted"
fi
INVALID_REPORT="$INVALID_INBOX/model-deprecations-2026-05-04.md"
REJECTED_REPORT="$INVALID_INBOX/model-deprecations-2026-05-04.rejected.md"
[ -f "$INVALID_REPORT" ] || fail "invalid report did not publish a failure report"
[ -f "$REJECTED_REPORT" ] || fail "invalid report was not preserved"
grep -q 'invalid vendor section' "$INVALID_REPORT" || fail "failure report did not name invalid vendor section"
grep -q '^## acme$' "$REJECTED_REPORT" || fail "rejected report copy missing unknown vendor"
if DEPRECATIONS_STUB_MODE=duplicate MODEL_CATALOG_INBOX="$T/duplicate-inbox" bash "$BIN" run >"$T/duplicate.out" 2>"$T/duplicate.err"; then
  fail "duplicate vendor report was accepted"
fi
grep -q 'invalid vendor section' "$T/duplicate.err" || fail "duplicate vendor rejection was not clear"

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
grep -q '^Environment=PATH=%h/.local/bin:' "$INSTALL_CONFIG/systemd/user/model-deprecations.service" || fail "service PATH does not reach delegate"
grep -q 'OnCalendar=Sun \*-\*-\* 06:10:00 UTC' "$INSTALL_CONFIG/systemd/user/model-deprecations.timer" || fail "installed weekly schedule missing"
grep -q '^--user daemon-reload$' "$SYSTEMCTL_CALLS" || fail "daemon-reload was not called"
grep -q '^--user enable --now model-deprecations.timer$' "$SYSTEMCTL_CALLS" || fail "timer was not enabled"

printf 'model-deprecations: all cases passed\n'

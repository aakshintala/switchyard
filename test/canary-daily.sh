#!/usr/bin/env bash
# Tests for bin/canary-daily using only temporary canary fixtures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/../bin/canary-daily"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-canary-daily.XXXXXX")"
trap 'rm -rf "$T"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

CANARY="$T/canary"
STUB_ROOT="$T/stubs"
mkdir -p "$CANARY" "$STUB_ROOT/bin"
cat >"$CANARY/canary-run.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
harness="$1"
task="$2"
cap="$3"
stub_root="${CANARY_STUB_ROOT:?}"
timeout="${CANARY_TIMEOUT:-/usr/bin/gnutimeout}"
if ! "$timeout" --version 2>/dev/null | head -1 | grep -q 'GNU coreutils'; then
  echo "$timeout is not GNU timeout; refusing to run" >&2
  exit 2
fi
if [ "${STUB_FAIL_HARNESS:-}" = "$harness" ]; then
  echo "stub failure before run directory" >&2
  exit 1
fi
count=0
if [ -f "$CANARY_DIR/stub-count" ]; then read -r count <"$CANARY_DIR/stub-count"; fi
count=$((count + 1))
printf '%s\n' "$count" >"$CANARY_DIR/stub-count"
run_dir="$CANARY_DIR/runs/20261108T000000Z-$harness-$task-$count"
mkdir -p "$run_dir/tasks/$task"
score=+0.1250
[ "$harness" != fiber ] || score=fail
printf '{"harness":"%s","version":"test-version","task":"%s","bench":"2a169abadf188b95f263cb28eae3937da3e576b2","cap_min":%s,"rc":0,"wall_s":12,"wrapup_rc":"0","restored":"none","final_score":"%s","run":"%s"}\n' \
  "$harness" "$task" "$cap" "$score" "$run_dir" >"$run_dir/meta.json"
printf '{"output_tail":"MISMATCH on 5 units\\ngrade: FAIL (verification)\\n"}\n{"text":"grade: FAIL (build)"}\n{"source":"print(\\"grade: FAIL (verification)\\")"}\n' >"$run_dir/agent.jsonl"
printf '{"output_tail":"grade: FAIL (verification)\\n"}\n' >"$run_dir/wrapup.jsonl"
printf '{"seed":0}\n{"seed":1}\n{"seed":2}\n' >"$run_dir/tasks/$task/scores.jsonl"
printf '== baseline grade\n'
printf '== %s: test-version (%s), cap %sm, deadline 00:00:00 UTC\n' "$harness" "$stub_root/bin/$harness" "$cap"
printf '== %s rc=0 wall=12s\n' "$harness"
printf '== final grade\n'
if [ "${STUB_OMIT_GRADES:-0}" != 1 ]; then echo '== grades during run: 2'; fi
printf 'run dir: %s\n' "$run_dir"
RUNNER
cat >"$CANARY/canary-sum.py" <<'SUM'
#!/usr/bin/env python3
import sys
print("== fixture {'harness': 'pi'}")
print("main {'inp': 10, 'cache': 20, 'out': 30} total 60 | wrapup {'inp': 1, 'cache': 2, 'out': 3} total 6")
print("-- friction:")
print("fixture friction detail")
SUM
cat >"$STUB_ROOT/bin/gnu-timeout" <<'TIMEOUT'
#!/usr/bin/env bash
printf 'timeout (GNU coreutils) test\n'
TIMEOUT
cat >"$STUB_ROOT/bin/bad-timeout" <<'TIMEOUT'
#!/usr/bin/env bash
printf 'timeout (uutils) test\n'
TIMEOUT
for h in codex fiber pi; do printf 'binary fixture: %s\n' "$h" >"$STUB_ROOT/bin/$h"; done
chmod +x "$CANARY/canary-run.sh" "$CANARY/canary-sum.py" "$STUB_ROOT/bin/gnu-timeout" "$STUB_ROOT/bin/bad-timeout"

prepare_canary() {
  local root="$1"
  mkdir -p "$root"
  cp "$CANARY/canary-run.sh" "$root/canary-run.sh"
  cp "$CANARY/canary-sum.py" "$root/canary-sum.py"
  chmod +x "$root/canary-run.sh" "$root/canary-sum.py"
}

run() {
  CANARY_DIR="$CANARY" CANARY_TIMEOUT="$STUB_ROOT/bin/gnu-timeout" CANARY_TODAY="$1" \
    CANARY_STUB_ROOT="$STUB_ROOT" bash "$BIN" "${@:2}"
}

# A default rotation run emits one complete row per default harness.
run 2026-01-01 run >"$T/first.out" 2>"$T/first.err" || fail "default run failed: $(cat "$T/first.err")"
[ ! -s "$T/first.err" ] || fail "successful run wrote stderr: $(cat "$T/first.err")"
[ "$(wc -l <"$CANARY/series.jsonl" | tr -d ' ')" = 3 ] || fail "default run did not append three rows"
python3 -I - "$CANARY/series.jsonl" "$STUB_ROOT/bin" "$(hostname -s)" <<'PY' || fail "first series rows failed validation"
import hashlib, json, sys
path, bin_dir, host = sys.argv[1:]
rows = [json.loads(line) for line in open(path, encoding="utf-8")]
required = {
    "date", "host", "harness", "harness_version", "harness_sha", "model", "thinking",
    "task", "bench", "cap_min", "score", "rc", "wrapup_rc", "restored", "main_tokens",
    "wrapup_tokens", "reviewer_tokens", "cost", "wall_s", "grades", "failed_attempts", "run_dir",
}
assert [row["harness"] for row in rows] == ["codex", "fiber", "pi"]
for row in rows:
    assert set(row) == required
    assert row["date"] == "2026-01-01" and row["host"] == host
    assert all(isinstance(row[key], str) for key in ("date", "host", "harness", "harness_version", "model", "thinking", "task", "bench", "run_dir"))
    assert isinstance(row["harness_sha"], str)
    assert row["harness_version"] == "test-version"
    assert row["harness_sha"] == hashlib.sha256(open(f"{bin_dir}/{row['harness']}", "rb").read()).hexdigest()
    assert row["model"] == "gpt-6-luna" and row["thinking"] == "xhigh"
    assert row["task"] in {"json-unescape", "float-print", "utf16-transcode"}
    assert row["bench"] == "2a169abadf188b95f263cb28eae3937da3e576b2"
    assert row["cap_min"] == 10 and row["rc"] == 0 and row["wall_s"] == 12
    assert all(type(row[key]) is int for key in ("cap_min", "rc", "wall_s", "grades", "failed_attempts"))
    assert row["wrapup_rc"] == "0" and row["restored"] == "none"
    assert isinstance(row["wrapup_rc"], str) and isinstance(row["restored"], str)
    assert row["main_tokens"] == {"inp": 10, "cache": 20, "out": 30, "total": 60}
    assert row["wrapup_tokens"] == {"inp": 1, "cache": 2, "out": 3, "total": 6}
    assert all(type(value) is int for tokens in (row["main_tokens"], row["wrapup_tokens"]) for value in tokens.values())
    assert row["reviewer_tokens"] is None and row["cost"] is None
    assert row["grades"] == 2 and row["failed_attempts"] == 3
    assert isinstance(row["run_dir"], str)
    assert (row["score"] is None) if row["harness"] == "fiber" else type(row["score"]) is float
PY
first_task="$(python3 -I - "$CANARY/series.jsonl" <<'PY'
import json, sys
print(json.loads(open(sys.argv[1], encoding="utf-8").readline())["task"])
PY
)"
[ -s "$CANARY/daily/2026-01-01.log" ] || fail "daily stdout log was not written"

# Consecutive injected dates rotate to another task; host-only fake prices are applied.
printf '{"gpt-6-luna":{"input":1.0,"cache":1.0,"output":1.0}}\n' >"$CANARY/prices.json"
run 2026-01-02 run >"$T/second.out" 2>"$T/second.err" || fail "second run failed: $(cat "$T/second.err")"
python3 -I - "$CANARY/series.jsonl" "$first_task" <<'PY' || fail "rotation or fake price calculation was wrong"
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
previous = sys.argv[2]
second = rows[3:]
assert len(second) == 3 and {row["date"] for row in second} == {"2026-01-02"}
assert len({row["task"] for row in second}) == 1 and second[0]["task"] != previous
for row in second:
    assert isinstance(row["cost"], float)
    all_tokens = sum(row[key][name] for key in ("main_tokens", "wrapup_tokens") for name in ("inp", "cache", "out"))
    assert row["cost"] == all_tokens / 1_000_000
PY

# --full covers all tasks and the grade-count fallback subtracts the baseline line.
STUB_OMIT_GRADES=1 run 2026-01-03 run --full --harness pi >"$T/full.out" 2>"$T/full.err" \
  || fail "full run failed: $(cat "$T/full.err")"
python3 -I - "$CANARY/series.jsonl" <<'PY' || fail "full run task set or fallback grade count was wrong"
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
full = rows[6:]
assert len(full) == 3 and {row["date"] for row in full} == {"2026-01-03"}
assert {row["task"] for row in full} == {"json-unescape", "float-print", "utf16-transcode"}
assert all(row["harness"] == "pi" and row["grades"] == 2 for row in full)
PY

# Exit-2 timeout refusal leaves the existing series byte-for-byte unchanged and creates no run dir.
REFUSAL="$T/refusal"
prepare_canary "$REFUSAL"
printf '{"keep":"unchanged"}\n' >"$REFUSAL/series.jsonl"
cp "$REFUSAL/series.jsonl" "$T/series.before"
if CANARY_DIR="$REFUSAL" CANARY_TIMEOUT="$STUB_ROOT/bin/bad-timeout" CANARY_TODAY=2026-01-01 CANARY_STUB_ROOT="$STUB_ROOT" \
  bash "$BIN" run --harness codex --task json-unescape >"$T/refusal.out" 2>"$T/refusal.err"; then
  fail "non-GNU timeout refusal unexpectedly succeeded"
else
  rc=$?
fi
[ "$rc" -eq 2 ] || fail "non-GNU timeout exited $rc, expected 2; stdout: $(cat "$T/refusal.out"); stderr: $(cat "$T/refusal.err")"
grep -q 'is not GNU timeout' "$T/refusal.err" || fail "timeout refusal message missing"
cmp -s "$T/series.before" "$REFUSAL/series.jsonl" || fail "timeout refusal changed series.jsonl"
[ ! -e "$REFUSAL/runs" ] || fail "timeout refusal created a run dir"

# A non-2 failure without a run directory skips only that pair and exits 1.
FAILURE="$T/failure"
prepare_canary "$FAILURE"
if CANARY_DIR="$FAILURE" CANARY_TIMEOUT="$STUB_ROOT/bin/gnu-timeout" CANARY_TODAY=2026-01-04 \
  CANARY_STUB_ROOT="$STUB_ROOT" STUB_FAIL_HARNESS=codex bash "$BIN" run --harness codex --harness pi --task json-unescape \
  >"$T/failure.out" 2>"$T/failure.err"; then
  fail "non-2 failure unexpectedly succeeded"
else
  rc=$?
fi
[ "$rc" -eq 1 ] || fail "non-2 failure exited $rc, expected 1"
grep -q 'codex/json-unescape exited 1 without a run dir' "$T/failure.err" || fail "failed pair was not reported"
python3 -I - "$FAILURE/series.jsonl" <<'PY' || fail "failed no-run-dir pair was recorded or successful pair was skipped"
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert len(rows) == 1 and rows[0]["harness"] == "pi"
PY

# A hand-made series proves latest-versus-trend deltas and latest-date token ratio.
REPORT="$T/report"
mkdir -p "$REPORT"
python3 -I - "$REPORT/series.jsonl" <<'PY'
import json, sys
path = sys.argv[1]
records = [
    ("2026-01-08", "codex", 0.2, 1000),
    ("2026-01-09", "codex", 0.4, 3000),
    ("2026-01-10", "codex", 0.3, 2000),
    ("2026-01-08", "pi", 0.3, 1500),
    ("2026-01-09", "pi", 0.5, 2500),
    ("2026-01-10", "pi", 0.5, 4000),
]
with open(path, "w", encoding="utf-8") as output:
    for day, harness, score, tokens in records:
        row = {"date": day, "task": "json-unescape", "harness": harness, "score": score,
               "main_tokens": {"inp": tokens // 2, "cache": tokens // 4, "out": tokens - tokens // 2 - tokens // 4, "total": tokens}}
        output.write(json.dumps(row) + "\n")
PY
report="$(CANARY_DIR="$REPORT" bash "$BIN" report --days 14)" || fail "report command failed"
grep -q 'json-unescape.*pi.*+0.5000.*+0.4000.*+0.1000.*4,000.*2,000.*+2,000.*2.00x' <<<"$report" \
  || fail "report did not show expected latest-vs-trend values:\n$report"
grep -q 'trend only: single-day spread is large' <<<"$report" || fail "report note missing"

# --print displays service, timer and commands without creating files.
HOME="$T/print-home" XDG_CONFIG_HOME="$T/xdg-config" bash "$BIN" install --print --at 07:30 >"$T/install.txt" \
  || fail "install --print failed"
grep -q 'canary-daily.service' "$T/install.txt" || fail "install service missing from --print"
grep -q 'canary-daily.timer' "$T/install.txt" || fail "install timer missing from --print"
grep -q 'Type=oneshot' "$T/install.txt" || fail "oneshot service missing from --print"
grep -q 'TimeoutStartSec=4h' "$T/install.txt" || fail "service timeout missing from --print"
grep -q 'OnCalendar=\*-\*-\* 07:30:00 UTC' "$T/install.txt" || fail "timer schedule missing from --print"
grep -q 'systemctl --user enable --now canary-daily.timer' "$T/install.txt" || fail "systemctl command missing from --print"
[ ! -e "$T/xdg-config" ] || fail "install --print wrote files"

printf 'canary-daily: all cases passed\n'

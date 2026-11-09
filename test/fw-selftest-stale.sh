#!/usr/bin/env bash
# fw_selftest_stale reports bin files newer than the last selftest log.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/fw-selftest-stale.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run"
. "$here/../bin/lib/fw-lib.sh"
FW_RUN="$T/run"
export FW_RUN

file="$T/bin/launcher.sh"
log="$T/run/custom-selftest-log.tsv"
: > "$file"
: > "$log"
python3 - "$file" "$log" <<'PY'
import os, sys, time
now = time.time()
os.utime(sys.argv[1], (now, now))
os.utime(sys.argv[2], (now - 60, now - 60))
PY
set +e
out=$(fw_selftest_stale "$T/bin" "$log")
rc=$?
set -e
if [ "$rc" -ne 0 ] || [ "$out" != "$file" ]; then
  printf 'FAIL stale file: expected rc=0 and %s, got rc=%s output=%s\n' "$file" "$rc" "$out" >&2
  exit 1
fi
printf 'ok stale-bin-file-is-listed\n'

python3 - "$file" "$log" <<'PY'
import os, sys, time
now = time.time()
os.utime(sys.argv[1], (now - 60, now - 60))
os.utime(sys.argv[2], (now, now))
PY
set +e
out=$(fw_selftest_stale "$T/bin" "$log")
rc=$?
set -e
if [ "$rc" -ne 1 ] || [ -n "$out" ]; then
  printf 'FAIL fresh files: expected rc=1 and no output, got rc=%s output=%s\n' "$rc" "$out" >&2
  exit 1
fi
printf 'ok fresh-bin-has-no-output\n'

set +e
out=$(fw_selftest_stale "$T/bin")
rc=$?
set -e
expected="$T/run/selftest-log.tsv is missing: no selftest has ever run"
if [ "$rc" -ne 0 ] || [ "$out" != "$expected" ]; then
  printf 'FAIL missing default log: expected rc=0 and %s, got rc=%s output=%s\n' "$expected" "$rc" "$out" >&2
  exit 1
fi
printf 'ok missing-default-log-is-reported\n'

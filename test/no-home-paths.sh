#!/usr/bin/env bash
# Reject tracked home paths except explicit markers and redacted fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
import re
import subprocess
import sys

allowed_markers = {
    "delegate/scripts/leak-scan.sh",
    "delegate/src/session/pi.rs",
    "test/no-home-paths.sh",
}
redacted_name = re.compile(
    rb"(?:user|dev|u|us|use)(?=$|/|[\s\\\"'`,;:!?)}\]]|\|)"
    rb"|user\.(?=$|/|[\s\\\"'`,;:!?)}\]]|\|)"
)


def is_recorded_regex(content, marker):
    prefix = content[max(0, marker.start() - 120):marker.start()]
    suffix = content[marker.end():]
    return (
        (suffix.startswith(b"[a-z]+") and b"grep -rlE" in prefix)
        or (suffix.startswith(b"[A-Za-z0-9_-]+") and b"grep -rhoE" in prefix)
        or (suffix.startswith(b"user[") and b"grep -o " in prefix)
    )

result = subprocess.run(
    ["git", "grep", "-n", "-a", "-F", "/Users/", "--"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
if result.returncode not in (0, 1):
    sys.stderr.buffer.write(result.stderr)
    sys.exit(result.returncode)

failures = []
for record in result.stdout.splitlines():
    path_bytes, line_bytes, content = record.split(b":", 2)
    path = path_bytes.decode("utf-8", "replace")
    line = line_bytes.decode("ascii", "replace")
    if path in allowed_markers:
        continue
    if path.startswith("delegate/tests/fixtures/"):
        invalid = False
        for marker in re.finditer(rb"/Users/", content):
            if is_recorded_regex(content, marker):
                continue
            if redacted_name.match(content, marker.end()) is None:
                invalid = True
                break
        if invalid:
            failures.append(f"{path}:{line}: fixture home path is not redacted")
        continue
    failures.append(f"{path}:{line}: forbidden home path")

if failures:
    for failure in failures:
        print(failure, file=sys.stderr)
    print("FAIL: no-home-paths found forbidden tracked paths", file=sys.stderr)
    sys.exit(1)

print("PASS: no-home-paths tracked-file scan")
PY

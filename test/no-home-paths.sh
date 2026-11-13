#!/usr/bin/env bash
# Reject tracked home paths except explicit markers and redacted fixtures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${NO_HOME_PATHS_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
cd "$ROOT"

if [ "${NO_HOME_PATHS_SKIP_CASES:-0}" != 1 ]; then
  T="$(mktemp -d "${TMPDIR:-/tmp}/no-home-paths.XXXXXX")"
  trap 'rm -rf "$T"' EXIT

  run_case() {
    local name=$1 expected=$2 path=$3 content=$4 repo="$T/$1" actual
    mkdir -p "$(dirname "$repo/$path")"
    git -C "$repo" init -q
    printf '%s\n' "$content" >"$repo/$path"
    git -C "$repo" add "$path"
    if NO_HOME_PATHS_ROOT="$repo" NO_HOME_PATHS_SKIP_CASES=1 \
      bash "$SCRIPT_DIR/no-home-paths.sh" >"$T/output" 2>&1; then
      actual=pass
    else
      actual=fail
    fi
    if [ "$actual" != "$expected" ]; then
      printf 'FAIL: no-home-paths case %s expected %s, got %s\n' \
        "$name" "$expected" "$actual" >&2
      cat "$T/output" >&2
      return 1
    fi
    printf 'ok no-home-paths case: %s (%s)\n' "$name" "$expected"
  }

  run_case literal-users fail script.sh 'echo /Users/somebody/x'
  run_case placeholder-users fail script.sh 'echo /Users/user/x'
  run_case substring-users fail script.sh 'echo $T/Users/x'
  run_case literal-home fail script.sh 'echo /home/somebody/x'
  run_case temp-home pass script.sh 'echo $T/home/work'
  run_case placeholder-home pass script.sh 'echo /home/test/.cache'
  run_case variable-home pass script.sh 'echo /home/${USER:?}'
  run_case redacted-users-fixture pass delegate/tests/fixtures/case.txt 'echo /Users/user/x'
  run_case unredacted-users-fixture fail delegate/tests/fixtures/case.txt 'echo /Users/somebody/x'
  run_case unredacted-home-fixture fail delegate/tests/fixtures/case.txt 'echo /home/somebody/x'
  run_case fixture-regex pass delegate/tests/fixtures/case.txt "grep -rlE '/Users/[a-z]+'"
  run_case file-url-users-fixture fail delegate/tests/fixtures/case.txt 'file:///Users/somebody/x'
  run_case file-url-home fail script.sh 'file:///home/somebody/x'
  run_case allowlisted-marker pass delegate/scripts/leak-scan.sh 'echo /Users/somebody/x'
fi

python3 - <<'PY'
import re
import subprocess
import sys

allowed_markers = {
    "delegate/scripts/leak-scan.sh",
    "delegate/src/session/pi.rs",
    "test/no-home-paths.sh",
}
# These are test placeholders, not owners: user/dev/test/a/operator are common
# fixture names, and u/us/use are truncations of user in redaction examples.
placeholder_names = {b"user", b"dev", b"test", b"a", b"operator", b"u", b"us", b"use"}
# A slash before the marker is a longer path, except after a URL's `//`
# (file:///Users/<name>, file:///home/<name>).
home_marker = re.compile(rb"(?:(?<![\w/])|(?<=//))/(?:Users|home)/")
literal_name = re.compile(rb"[A-Za-z0-9._-]+")

result = subprocess.run(
    ["git", "grep", "-n", "-a", "-F", "-e", "/Users/", "-e", "/home/", "--"],
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

    is_fixture = path.startswith("delegate/tests/fixtures/")
    # Outside fixtures any /Users/ fails, placeholder or not (#1694 Done-when 3).
    invalid = not is_fixture and b"/Users/" in content
    for marker in home_marker.finditer(content):
        # Fixture grep patterns may contain a character class after /Users/.
        if is_fixture and content[marker.start():].startswith(b"/Users/["):
            continue
        match = literal_name.match(content, marker.end())
        if match is None:
            continue
        name = match.group(0)
        # Recorded transcripts sometimes put sentence punctuation after the
        # redacted placeholder.
        if name in placeholder_names or (is_fixture and name == b"user."):
            continue
        invalid = True
        break
    if invalid:
        message = "fixture home path is not redacted" if is_fixture else "forbidden home path"
        failures.append(f"{path}:{line}: {message}")

if failures:
    for failure in failures:
        print(failure, file=sys.stderr)
    print("FAIL: no-home-paths found forbidden tracked paths", file=sys.stderr)
    sys.exit(1)

print("PASS: no-home-paths tracked-file scan")
PY

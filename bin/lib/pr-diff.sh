#!/usr/bin/env bash
# Fetch a PR diff, falling back to the paginated files API only for HTTP 406.
# Usage: pr_diff_fetch GH REPO PR EXPECTED_FILES [--name-only] [--allow-escape-sequences]
# Emits either changed filenames or a unified-diff-shaped stream on stdout.
pr_diff_fetch() {
  local gh="$1" repo="$2" pr="$3" expected="$4" mode="diff" allow_escapes=0 work
  shift 4
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name-only) mode="names" ;;
      --allow-escape-sequences) allow_escapes=1 ;;
      *) echo "pr-diff: unknown option $1" >&2; return 1 ;;
    esac
    shift
  done
  work="$(mktemp -d "${TMPDIR:-/tmp}/pr-diff.XXXXXX")" || {
    echo "pr-diff: cannot make temp directory for PR #$pr" >&2
    return 1
  }
  if [ "$mode" = "names" ]; then
    if "$gh" pr diff "$pr" -R "$repo" --name-only >"$work/diff" 2>"$work/diff.err"; then
      cat "$work/diff"
      rm -rf "$work"
      return 0
    fi
  elif [ "$allow_escapes" = "1" ]; then
    if "$gh" pr diff "$pr" -R "$repo" --allow-escape-sequences >"$work/diff" 2>"$work/diff.err"; then
      cat "$work/diff"
      rm -rf "$work"
      return 0
    fi
  else
    if "$gh" pr diff "$pr" -R "$repo" >"$work/diff" 2>"$work/diff.err"; then
      cat "$work/diff"
      rm -rf "$work"
      return 0
    fi
  fi
  if ! grep -qi 'HTTP 406' "$work/diff.err"; then
    cat "$work/diff.err" >&2
    rm -rf "$work"
    return 1
  fi
  if ! "$gh" api --paginate "repos/$repo/pulls/$pr/files?per_page=100" >"$work/files.json" 2>"$work/api.err"; then
    printf 'pr-diff: PR #%s files API failed after HTTP 406: ' "$pr" >&2
    cat "$work/api.err" >&2
    rm -rf "$work"
    return 1
  fi
  if python3 -I -c 'import json,sys
source, mode, expected, pr = sys.argv[1:]
def fail(message):
  print("pr-diff: " + message, file=sys.stderr)
  sys.exit(1)
try:
  text = open(source, encoding="utf-8").read()
  decoder = json.JSONDecoder()
  pages = []
  pos = 0
  while pos < len(text):
    while pos < len(text) and text[pos].isspace():
      pos += 1
    if pos == len(text):
      break
    page, pos = decoder.raw_decode(text, pos)
    if isinstance(page, list):
      pages.extend(page)
    elif isinstance(page, dict) and isinstance(page.get("filename"), str):
      pages.append(page)
    else:
      fail("PR #%s files API returned an unexpected JSON shape" % pr)
except Exception as exc:
  if isinstance(exc, SystemExit):
    raise
  fail("PR #%s files API returned invalid JSON: %s" % (pr, exc))
if expected:
  if not expected.isdigit():
    fail("PR #%s has an invalid changedFiles count: %s" % (pr, expected))
  if int(expected) > 3000:
    fail("PR #%s has more than 3000 changed files; the files API limit is 3000" % pr)
if len(pages) > 3000:
  fail("PR #%s returned more than 3000 files; the files API limit is 3000" % pr)
if expected and len(pages) != int(expected):
  fail("PR #%s files API returned %s files; changedFiles is %s" % (pr, len(pages), expected))
files = []
for row in pages:
  if not isinstance(row, dict):
    fail("PR #%s files API contains an invalid file entry" % pr)
  name = row.get("filename")
  status = row.get("status")
  if not isinstance(name, str) or not name or "\n" in name or "\r" in name:
    fail("PR #%s files API contains an invalid filename" % pr)
  old = row.get("previous_filename", name) if status == "renamed" else name
  if not isinstance(old, str) or not old or "\n" in old or "\r" in old:
    fail("PR #%s files API contains an invalid previous_filename" % pr)
  files.append((name, old, status, row.get("patch")))
if mode == "names":
  for name, old, status, patch in files:
    print(name)
  sys.exit(0)
for name, old, status, patch in files:
  print("diff --git a/%s b/%s" % (old, name))
  if status == "renamed":
    print("rename from %s" % old)
    print("rename to %s" % name)
    print("index 0000000..1111111 100644")
  elif status == "added":
    print("new file mode 100644")
    print("index 0000000..1111111 100644")
  elif status == "removed":
    print("deleted file mode 100644")
    print("index 1111111..0000000 100644")
  else:
    print("index 1111111..2222222 100644")
  if not isinstance(patch, str) or not patch:
    continue
  if status == "added":
    print("--- /dev/null")
    print("+++ b/%s" % name)
  elif status == "removed":
    print("--- a/%s" % old)
    print("+++ /dev/null")
  else:
    print("--- a/%s" % old)
    print("+++ b/%s" % name)
  sys.stdout.write(patch)
  if not patch.endswith("\n"):
    sys.stdout.write("\n")
' "$work/files.json" "$mode" "$expected" "$pr"; then
    rm -rf "$work"
    return 0
  fi
  rm -rf "$work"
  return 1
}

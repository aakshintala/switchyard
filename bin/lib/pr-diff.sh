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

# fence-grant caches PR diffs by repository, number and immutable head SHA.
# A relative XDG_CACHE_HOME is ignored: Git's convention only gives an absolute
# cache root, and falling back to HOME keeps the location deterministic.
_pr_diff_cache_root() {
  if [ -n "${FENCE_GRANT_CACHE_DIR:-}" ]; then
    printf '%s\n' "$FENCE_GRANT_CACHE_DIR"
  else
    case "${XDG_CACHE_HOME:-}" in
      /*) printf '%s/switchyard/fence-grant/pr-diffs\n' "$XDG_CACHE_HOME";;
      *) printf '%s/.cache/switchyard/fence-grant/pr-diffs\n' "$HOME";;
    esac
  fi
}

# Emit changed paths from a unified diff. Quoted paths use Git's C-style
# byte escapes; unresolved headers fail so callers can use the API names route.
pr_diff_names_from_diff() {
  python3 -I - "$1" <<'PY'
import re
import sys

def fail():
    raise ValueError("unresolved diff path")

def unquote(value):
    if not value.startswith('"'):
        return value
    if len(value) < 2 or not value.endswith('"'):
        fail()
    body = value[1:-1]
    out = bytearray()
    i = 0
    escapes = {'"': 34, '\\': 92, 't': 9, 'n': 10, 'r': 13, 'b': 8, 'f': 12, 'v': 11}
    while i < len(body):
        ch = body[i]
        if ch != '\\':
            out.extend(ch.encode('utf-8'))
            i += 1
            continue
        i += 1
        if i >= len(body):
            fail()
        ch = body[i]
        if ch in '01234567':
            end = i
            while end < len(body) and end < i + 3 and body[end] in '01234567':
                end += 1
            out.append(int(body[i:end], 8))
            i = end
        elif ch in escapes:
            out.append(escapes[ch])
            i += 1
        else:
            fail()
    try:
        value = out.decode('utf-8')
    except UnicodeDecodeError:
        fail()
    if chr(10) in value or chr(13) in value:
        fail()
    return value

def header_pair(header):
    if header.startswith('"'):
        values = []
        i = 0
        while i < len(header):
            while i < len(header) and header[i] == ' ':
                i += 1
            if i == len(header):
                break
            start = i
            if header[i] == '"':
                i += 1
                escaped = False
                while i < len(header):
                    if not escaped and header[i] == '"':
                        i += 1
                        break
                    if not escaped and header[i] == '\\':
                        escaped = True
                    else:
                        escaped = False
                    i += 1
                else:
                    fail()
                values.append(unquote(header[start:i]))
            else:
                while i < len(header) and header[i] != ' ':
                    i += 1
                values.append(header[start:i])
        if len(values) == 2:
            return values
        return []
    matches = []
    for match in re.finditer(r' b/', header):
        left, right = header[:match.start()], header[match.start() + 1:]
        if left.startswith('a/') and right.startswith('b/'):
            matches.append((left, right))
    return matches[0] if len(matches) == 1 else []

def marker(raw, side):
    value = unquote(raw)
    if value == '/dev/null':
        return None
    prefix = side + '/'
    if not value.startswith(prefix):
        fail()
    value = value[2:]
    if not value or chr(10) in value or chr(13) in value:
        fail()
    return value

def section_paths(section):
    old = marker(section['old'], 'a') if 'old' in section else None
    new = marker(section['new'], 'b') if 'new' in section else None
    if old is not None or new is not None:
        return [new or old]
    if section['renames']:
        if len(section['renames']) != 2:
            fail()
        return section['renames']
    pair = header_pair(section['header'])
    if len(pair) != 2 or not pair[0].startswith('a/') or not pair[1].startswith('b/') or pair[0][2:] != pair[1][2:]:
        fail()
    return [pair[0][2:]]

try:
    with open(sys.argv[1], encoding='utf-8') as source:
        lines = source.read().splitlines()
    sections = []
    current = None
    for line in lines:
        if line.startswith('diff --git '):
            if current is not None:
                sections.append(current)
            current = {'header': line[len('diff --git '):], 'renames': [], 'in_hunk': False}
        elif current is not None and line.startswith('@@ '):
            current['in_hunk'] = True
        elif current is not None and not current['in_hunk'] and line.startswith('--- '):
            current['old'] = line[4:]
        elif current is not None and not current['in_hunk'] and line.startswith('+++ '):
            current['new'] = line[4:]
        elif current is not None and not current['in_hunk'] and line.startswith('rename from '):
            current['renames'].append(unquote(line[len('rename from '):]))
        elif current is not None and not current['in_hunk'] and line.startswith('rename to '):
            current['renames'].append(unquote(line[len('rename to '):]))
    if current is not None:
        sections.append(current)
    if not sections:
        fail()
    seen = set()
    ordered = []
    for section in sections:
        for path in section_paths(section):
            if chr(10) in path or chr(13) in path:
                fail()
            if path not in seen:
                seen.add(path)
                ordered.append(path)
    for path in ordered:
        print(path)
except Exception:
    sys.exit(1)
PY
}

# Cache compare-endpoint diffs by repository, PR, base and immutable head SHA.
# Fallback results remain uncached because they are not pinned by compare.
pr_diff_fetch_cached() {
  local gh="$1" repo="$2" pr="$3" expected="$4" head_sha="$5" base="$6" mode="diff"
  local cache_root cache_dir cache_file work tmp_file sections last_byte cache_base cache_hit=0
  shift 6
  while [ "$#" -gt 0 ]; do
    case "$1" in --name-only) mode="names";; --allow-escape-sequences) :;; *) echo "pr-diff: unknown option $1" >&2; return 1;; esac
    shift
  done
  if [ -z "$head_sha" ] || [ -z "$base" ]; then
    if [ "$mode" = names ]; then pr_diff_fetch "$gh" "$repo" "$pr" "$expected" --name-only; else pr_diff_fetch "$gh" "$repo" "$pr" "$expected" --allow-escape-sequences; fi
    return $?
  fi
  cache_root=$(_pr_diff_cache_root)
  cache_dir="$cache_root/$repo/$pr"
  cache_base=${base//\//%2F}
  cache_file="$cache_dir/$head_sha-$cache_base.diff"
  work="$(mktemp -d "${TMPDIR:-/tmp}/pr-diff-cache.XXXXXX")" || { echo "pr-diff: cannot make temporary directory for PR #$pr" >&2; return 1; }
  if [ -f "$cache_file" ]; then
    cp "$cache_file" "$work/fetch" || { rm -rf "$work"; return 1; }
    cache_hit=1
  else
    if ! "$gh" api "repos/$repo/compare/$base...$head_sha" -H 'Accept: application/vnd.github.diff' >"$work/fetch" 2>"$work/compare.err"; then
      if pr_diff_fetch "$gh" "$repo" "$pr" "$expected" --allow-escape-sequences >"$work/fallback"; then
        if [ "$mode" = names ]; then
          if ! pr_diff_names_from_diff "$work/fallback" >"$work/names"; then
            pr_diff_fetch "$gh" "$repo" "$pr" "$expected" --name-only >"$work/names" || { rm -rf "$work"; return 1; }
          fi
          cat "$work/names"
        else
          cat "$work/fallback"
        fi
        local rc=$?; rm -rf "$work"; return "$rc"
      fi
      cat "$work/compare.err" >&2; rm -rf "$work"; return 1
    fi
    if [ -s "$work/fetch" ]; then
      last_byte=$(tail -c 1 "$work/fetch" | od -An -t x1 | tr -d '[:space:]')
      if [ "$last_byte" != 0a ]; then echo "pr-diff: PR #$pr returned a truncated diff" >&2; rm -rf "$work"; return 1; fi
    fi
    sections=$(grep -c '^diff --git ' "$work/fetch" 2>/dev/null || true)
    if [ -n "$expected" ] && [ "$expected" != "$sections" ]; then echo "pr-diff: PR #$pr returned $sections diff sections; changedFiles is $expected" >&2; rm -rf "$work"; return 1; fi
    if ! pr_diff_names_from_diff "$work/fetch" >"$work/names"; then
      # An ambiguous mode-only header is never guessed or cached.
      if ! pr_diff_fetch "$gh" "$repo" "$pr" "$expected" --name-only >"$work/names"; then rm -rf "$work"; return 1; fi
      if [ "$mode" = names ]; then cat "$work/names"; else cat "$work/fetch"; fi
      local rc=$?; rm -rf "$work"; return "$rc"
    fi
    mkdir -p "$cache_dir" || { rm -rf "$work"; return 1; }
    tmp_file=$(mktemp "$cache_dir/.pr-diff.XXXXXX") || { rm -rf "$work"; return 1; }
    if ! cp "$work/fetch" "$tmp_file" || ! mv -f "$tmp_file" "$cache_file"; then rm -f "$tmp_file"; rm -rf "$work"; return 1; fi
    # A newly published head supersedes all cached heads for this PR.
    find "$cache_dir" -type f ! -name "$head_sha-$cache_base.diff" -delete
  fi
  if [ "$mode" = names ]; then
    if ! pr_diff_names_from_diff "$work/fetch" >"$work/names"; then
      [ "$cache_hit" -eq 0 ] || rm -f "$cache_file"
      pr_diff_fetch "$gh" "$repo" "$pr" "$expected" --name-only >"$work/names" || { rm -rf "$work"; return 1; }
    fi
    cat "$work/names"
  else
    cat "$work/fetch"
  fi
  local rc=$?; rm -rf "$work"; return "$rc"
}

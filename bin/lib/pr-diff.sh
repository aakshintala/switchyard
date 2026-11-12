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

# Cache compare-endpoint diffs by repository, PR, base and immutable head SHA.
# Fallback results remain uncached because they are not pinned by compare.
pr_diff_fetch_cached() {
  local gh="$1" repo="$2" pr="$3" expected="$4" head_sha="$5" base="$6" mode="diff"
  local cache_root cache_dir cache_file work tmp_file actual sections last_byte
  shift 6
  while [ "$#" -gt 0 ]; do
    case "$1" in --name-only) mode="names";; --allow-escape-sequences) :;; *) echo "pr-diff: unknown option $1" >&2; return 1;; esac
    shift
  done
  if ! [[ "$head_sha" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] || [ -z "$base" ]; then
    if [ "$mode" = names ]; then pr_diff_fetch "$gh" "$repo" "$pr" "$expected" --name-only; else pr_diff_fetch "$gh" "$repo" "$pr" "$expected" --allow-escape-sequences; fi
    return $?
  fi
  cache_root=$(_pr_diff_cache_root)
  cache_dir="$cache_root/$repo/$pr"
  cache_file="$cache_dir/$head_sha-$base.diff"
  work="$(mktemp -d "${TMPDIR:-/tmp}/pr-diff-cache.XXXXXX")" || { echo "pr-diff: cannot make temporary directory for PR #$pr" >&2; return 1; }
  if [ -f "$cache_file" ]; then cp "$cache_file" "$work/fetch"; else
    if ! "$gh" api "repos/$repo/compare/$base...$head_sha" -H 'Accept: application/vnd.github.diff' >"$work/fetch" 2>"$work/compare.err"; then
      # Compare may reject oversized diffs; use the established path, uncached.
      if pr_diff_fetch "$gh" "$repo" "$pr" "$expected" --allow-escape-sequences >"$work/fallback"; then
        if [ "$mode" = names ]; then sed -n 's/^diff --git a\/[^ ]* b\/\(.*\)$/\1/p' "$work/fallback"; else cat "$work/fallback"; fi
        rm -rf "$work"; return 0
      fi
      cat "$work/compare.err" >&2; rm -rf "$work"; return 1
    fi
    if [ -s "$work/fetch" ]; then
      last_byte=$(tail -c 1 "$work/fetch" | od -An -t x1 | tr -d '[:space:]')
      if [ "$last_byte" != 0a ]; then echo "pr-diff: PR #$pr returned a truncated diff" >&2; rm -rf "$work"; return 1; fi
    fi
    sections=$(grep -c '^diff --git ' "$work/fetch" 2>/dev/null || true)
    if [ -n "$expected" ] && [ "$expected" != "$sections" ]; then echo "pr-diff: PR #$pr returned $sections diff sections; changedFiles is $expected" >&2; rm -rf "$work"; return 1; fi
    mkdir -p "$cache_dir" || { rm -rf "$work"; return 1; }
    tmp_file=$(mktemp "$cache_dir/.pr-diff.XXXXXX") || { rm -rf "$work"; return 1; }
    if ! cp "$work/fetch" "$tmp_file" || ! mv -f "$tmp_file" "$cache_file"; then rm -f "$tmp_file"; rm -rf "$work"; return 1; fi
    # A newly published head supersedes all cached heads for this PR.
    find "$cache_dir" -type f ! -name "$head_sha-$base.diff" -delete
  fi
  if [ "$mode" = names ]; then sed -n 's/^diff --git a\/[^ ]* b\/\(.*\)$/\1/p' "$work/fetch"; else cat "$work/fetch"; fi
  local rc=$?; rm -rf "$work"; return "$rc"
}

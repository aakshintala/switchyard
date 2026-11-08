#!/usr/bin/env bash
# Verify test/run switches suites to Bash 5 when an older Bash starts it.
set -uo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

is_bash5() {
  # shellcheck disable=SC2016
  [ -x "$1" ] && "$1" -c 'test "${BASH_VERSINFO[0]}" -ge 5' >/dev/null 2>&1
}

find_bash5() {
  local candidate path dir
  if is_bash5 /opt/homebrew/bin/bash; then
    printf '%s\n' /opt/homebrew/bin/bash
    return 0
  fi
  if [ -n "${BASH:-}" ] && is_bash5 "$BASH"; then
    printf '%s\n' "$BASH"
    return 0
  fi
  path="${PATH:-}"
  while :; do
    case "$path" in
      *:*) dir="${path%%:*}"; path="${path#*:}" ;;
      *) dir="$path"; path="" ;;
    esac
    [ -n "$dir" ] || dir=.
    candidate="$dir/bash"
    if is_bash5 "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    [ -n "$path" ] || break
  done
  return 1
}

old_bash=/bin/bash
# shellcheck disable=SC2016
if [ ! -x "$old_bash" ] || ! "$old_bash" -c 'test "${BASH_VERSINFO[0]}" -lt 5' >/dev/null 2>&1; then
  echo 'SKIP: no Bash older than 5 at /bin/bash to compare'
  exit 0
fi

bash5="$(find_bash5 || true)"
if [ -z "$bash5" ]; then
  echo 'SKIP: no Bash 5 available to compare'
  exit 0
fi
case "$bash5" in /*) ;; *) bash5="$PWD/$bash5" ;; esac

script_dir="$(cd "$(dirname "$0")" && pwd)"
runner="$script_dir/run"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-bash5-runner.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/old-bin" "$tmp/new-bin"

cat >"$tmp/bare-local-start.sh" <<'STUB'
#!/usr/bin/env bash
set -u
read_start() {
  local start
  printf '%s\n' "$start"
}
read_start
STUB
chmod +x "$tmp/bare-local-start.sh"

# Put an old Bash first and Bash 5 later on PATH. The explicit override also
# exercises the preferred Homebrew-candidate path without relying on this
# machine's fixed /opt/homebrew location.
ln -s "$old_bash" "$tmp/old-bin/bash"
ln -s "$bash5" "$tmp/new-bin/bash"
system_path=/usr/bin:/bin:/usr/sbin:/sbin

expect_bash5_unbound_error() {
  local label="$1" homebrew_bash="$2" controlled_path="$3" output="$tmp/$1.out" rc
  if TEST_RUN_HOMEBREW_BASH="$homebrew_bash" PATH="$controlled_path" \
      "$old_bash" "$runner" --run-parallel "$tmp/bare-local-start.sh" >"$output" 2>&1; then
    echo "FAIL: $label: test/run let bare local start pass under Bash 3.2" >&2
    cat "$output" >&2
    return 1
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ] || {
    echo "FAIL: $label: test/run exited $rc, expected 1" >&2
    cat "$output" >&2
    return 1
  }
  grep -q 'unbound variable' "$output" || {
    echo "FAIL: $label: Bash 5 unbound-variable diagnostic missing" >&2
    cat "$output" >&2
    return 1
  }
  grep -q 'FAIL: bare-local-start.sh (exit 1' "$output" || {
    echo "FAIL: $label: suite failure was not reported" >&2
    cat "$output" >&2
    return 1
  }
  echo "PASS: $label selected Bash 5 and reported bare local start as unbound"
}

# The current runner must fail this proof: it runs `bash` from controlled PATH,
# which is Bash 3.2, even though a Bash 5 candidate is available explicitly.
expect_bash5_unbound_error homebrew-candidate "$bash5" "$tmp/old-bin:$system_path" || exit 1
# Also discover a later Bash 5 on PATH when the first `bash` is still Bash 3.2.
expect_bash5_unbound_error path-candidate '' "$tmp/old-bin:$system_path:$tmp/new-bin" || exit 1

# With Bash 5 unavailable, the runner must say so once and still run the suite.
output="$tmp/no-bash5.out"
if TEST_RUN_HOMEBREW_BASH='' PATH="$system_path" "$old_bash" "$runner" \
    --run-parallel "$tmp/bare-local-start.sh" >"$output" 2>&1; then
  :
else
  rc=$?
  echo "FAIL: fallback with no Bash 5 exited $rc" >&2
  cat "$output" >&2
  exit 1
fi
notices="$(grep -c '^test/run: Bash 5 unavailable;' "$output" || true)"
[ "$notices" -eq 1 ] || {
  echo "FAIL: expected one no-Bash-5 notice, found $notices" >&2
  cat "$output" >&2
  exit 1
}
grep -q 'PASS: bare-local-start.sh' "$output" || {
  echo 'FAIL: fallback did not run the suite' >&2
  cat "$output" >&2
  exit 1
}
echo 'PASS: no-Bash-5 fallback printed one notice and ran the suite'

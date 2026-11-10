#!/usr/bin/env bash
# Hermetic tests for bin/box-tmp-reap.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
BIN=$here/../bin
T=$(mktemp -d "${TMPDIR:-/tmp}/box-tmp-reap.XXXXXX")
trap 'rm -rf "$T"' EXIT

ok() { printf 'ok %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

old_stamp=202001010000
first=$T/first
two=$T/two
mkdir -p "$first/open" "$first/fresh-inside/nested" "$two"
printf old >"$first/old"
printf fresh >"$first/fresh"
printf open >"$first/open/file"
printf fresh >"$first/fresh-inside/nested/file"
printf old >"$two/old"
touch -t "$old_stamp" "$first/old" "$first/open/file" "$first/open" \
  "$first/fresh-inside" "$first/fresh-inside/nested" "$two/old"

cat >"$T/lsof" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -Fn ] && [ "${2:-}" = +D ] || exit 2
if [ "$3" = "$BOX_TMP_REAP_OPEN_DIR" ]; then
  printf 'p123\nf3\nn%s/open/file\n' "$3"
fi
# lsof returns 1 when the scan found no open files.
exit 1
EOF
chmod +x "$T/lsof"
export BOX_TMP_REAP_OPEN_DIR="$(cd -P "$first" && pwd -P)"
missing=$T/missing

out=$(BOX_TMP_REAP_LSOF="$T/lsof" bash "$BIN/box-tmp-reap" \
  "$first" "$missing" "$two" 2>&1) || fail "reaper-exits-zero-for-missing-directory ($out)"
[ ! -e "$first/old" ] || fail old-entry-deleted
ok old-entry-deleted
[ -e "$first/fresh" ] || fail fresh-entry-kept
ok fresh-entry-kept
[ -e "$first/open/file" ] || fail open-entry-kept
ok open-entry-kept
[ -e "$first/fresh-inside/nested/file" ] || fail fresh-child-keeps-old-directory
ok fresh-child-keeps-old-directory
[ ! -e "$two/old" ] || fail second-directory-processed
ok second-directory-processed
printf '%s\n' "$out" | grep -F "box-tmp-reap: $missing is missing or unreadable; skipping" >/dev/null \
  || fail missing-directory-reported
ok missing-directory-reported
printf '%s\n' "$out" | grep -F "box-tmp-reap: $first deleted=1 kept=2" >/dev/null \
  || fail "first-directory-summary ($out)"
printf '%s\n' "$out" | grep -F "box-tmp-reap: $two deleted=1 kept=0" >/dev/null \
  || fail "second-directory-summary ($out)"
ok per-directory-summaries

# An unavailable lsof means the open-file set is unknown, so nothing is deleted.
no_lsof=$T/no-lsof
mkdir -p "$no_lsof"
printf old >"$no_lsof/old"
touch -t "$old_stamp" "$no_lsof/old"
out=$(BOX_TMP_REAP_LSOF="$T/not-installed" bash "$BIN/box-tmp-reap" "$no_lsof" 2>&1) \
  || fail "reaper-exits-zero-without-lsof ($out)"
[ -e "$no_lsof/old" ] || fail missing-lsof-fails-closed
ok missing-lsof-fails-closed
printf '%s\n' "$out" | grep -F 'lsof not found; skipping deletion for this run' >/dev/null \
  || fail missing-lsof-reported
ok missing-lsof-reported

exit 0

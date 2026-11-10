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

# lsof stderr decides whether the open set is known (#1554). Each case gets a
# dir with an old owned entry, an old owned entry lsof reports open, and a
# directory standing in for a root-owned /tmp/systemd-private-* dir.
# fake_lsof <name> <exit> <stderr line>: a fake that reports <dir>/open/f open.
fake_lsof() {
  printf '#!/usr/bin/env bash\nprintf "n%%s/open/f\\n" "$3"\nprintf "%%s\\n" %q >&2\nexit %s\n' \
    "$3" "$2" >"$T/$1"
  chmod +x "$T/$1"
}
lsof_case() { # <name> <exit> <stderr line, with @ for the dir> <expect: reap|keep>
  local d=$T/case-$1 rd out line
  mkdir -p "$d/open"
  rd=$(cd -P "$d" && pwd -P)
  printf old >"$d/old"; printf x >"$d/open/f"
  touch -t "$old_stamp" "$d/old" "$d/open/f" "$d/open"
  line=${3//@/$rd}
  fake_lsof "lsof-$1" "$2" "$line"
  out=$(BOX_TMP_REAP_LSOF="$T/lsof-$1" bash "$BIN/box-tmp-reap" "$d" 2>&1) || fail "lsof-$1-exits-zero ($out)"
  [ -e "$d/open/f" ] || fail "lsof-$1-keeps-open-entry"
  if [ "$4" = reap ]; then
    [ ! -e "$d/old" ] || fail "lsof-$1-reaps-old-entry ($out)"
    printf '%s\n' "$out" | grep -E "box-tmp-reap: $d deleted=1 kept=1 secs=[0-9]+$" >/dev/null \
      || fail "lsof-$1-summary ($out)"
  else
    [ -e "$d/old" ] || fail "lsof-$1-deletes-nothing ($out)"
    printf '%s\n' "$out" | grep -F "box-tmp-reap: lsof failed for $d; skipping deletion" >/dev/null \
      || fail "lsof-$1-reported ($out)"
  fi
  ok "lsof-$1"
}
# A warning for a dir under an entry owned by someone else is harmless. The
# fixture cannot chown to another user, so it names a path that does not exist:
# `find -user` finds no owned entry there, the same answer as a root-owned dir.
lsof_case unowned-opendir-warning 1 "lsof: WARNING: can't opendir(@/systemd-private-x/tmp): Permission denied" reap
# The same warning under an entry this user owns: its contents are unknown.
lsof_case owned-opendir-warning 1 "lsof: WARNING: can't opendir(@/open/sub): Permission denied" keep
# Any other stderr line, or an exit above 1, fails closed.
lsof_case other-stderr 1 "lsof: status error on /proc/1/fd: Permission denied" keep
lsof_case exit-2 2 "" keep

exit 0

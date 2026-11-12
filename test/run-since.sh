#!/usr/bin/env bash
# Verify test/run --since selects the changed suites in a throwaway Git repo.
set -uo pipefail

D="$(cd "$(dirname "$0")" && pwd)"
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-run-since.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp/tmp"
mkdir -p "$TMPDIR"
repo="$tmp/repo"
out="$tmp/output.log"
log="$tmp/suite.log"
expected="$tmp/expected.log"
actual="$tmp/actual.log"

# The fixture has stubs for every suite referenced by the full runner lists.
expected_suite_names() {
  # shellcheck disable=SC2016
  grep -Eo '"\$D"/[^" ]+\.sh' "$D/run" | sed 's|.*/||' | grep -v '^\*\.sh$' | sort -u
}

ensure_suite() {
  local name="$1"
  mkdir -p "$repo/test"
  cat >"$repo/test/$name" <<EOF
#!/usr/bin/env bash
printf 'suite:%s\\n' '$name' >> "\$FIXTURE_LOG"
if [ "\${FIXTURE_FAIL:-}" = '$name' ]; then
  exit 7
fi
EOF
  chmod +x "$repo/test/$name"
}

new_fixture() {
  local name
  rm -rf "$repo"
  mkdir -p "$repo/test" "$repo/bin/lib" "$repo/skills" "$repo/docs"
  cp "$D/run" "$repo/test/run"
  while IFS= read -r name; do
    [ -n "$name" ] && ensure_suite "$name"
  done <<EOF
$(expected_suite_names)
EOF
  cat >"$repo/bin/check-pack" <<'EOF'
#!/usr/bin/env bash
printf 'check-pack\n' >> "$FIXTURE_LOG"
echo 'stub check-pack ran'
[ "${CHECK_PACK_FAIL:-0}" != 1 ] || exit 5
EOF
  chmod +x "$repo/bin/check-pack"
  : >"$log"
  git -C "$repo" init -q || fail 'could not initialize fixture repo'
  git -C "$repo" config user.name 'Switchyard Test'
  git -C "$repo" config user.email 'switchyard-test@example.invalid'
}

commit_base() {
  git -C "$repo" add . || fail 'could not add fixture baseline'
  git -C "$repo" commit -qm 'fixture baseline' || fail 'could not commit fixture baseline'
  BASE="$(git -C "$repo" rev-parse HEAD)"
}

commit_delta() {
  git -C "$repo" add . || fail 'could not add fixture change'
  git -C "$repo" commit -qm 'fixture change' || fail 'could not commit fixture change'
}

run_since() {
  local arg="${1:-$BASE}"
  if (cd "$repo" && FIXTURE_LOG="$log" bash test/run --since "$arg") >"$out" 2>&1; then
    run_rc=0
  else
    run_rc=$?
  fi
}

assert_selected() {
  grep -F "test/run --since $BASE: selected $1" "$out" >/dev/null || {
    cat "$out" >&2
    fail "selection did not include $1"
  }
}

assert_not_selected() {
  if grep -F "test/run --since $BASE: selected $1" "$out" >/dev/null; then
    cat "$out" >&2
    fail "selection unexpectedly included $1"
  fi
}

assert_only_suite() {
  local expected_line="suite:$1"
  printf '%s\n' "$expected_line" >"$expected"
  grep '^suite:' "$log" >"$actual" || :
  diff -u "$expected" "$actual" >/dev/null || {
    cat "$out" >&2
    cat "$actual" >&2
    fail "expected only $1 to run"
  }
}

assert_full_suite_ran() {
  expected_suite_names | sed 's/^/suite:/' >"$expected"
  sort "$expected" -o "$expected"
  grep '^suite:' "$log" | sort >"$actual" || :
  diff -u "$expected" "$actual" >/dev/null || {
    cat "$out" >&2
    diff -u "$expected" "$actual" >&2 || :
    fail 'full-suite fallback did not run the complete registered list'
  }
  grep -F 'PASS: deterministic-parallel-failure (' "$out" >/dev/null || fail 'full-suite fallback skipped the parallel self-test'
  grep -F 'PASS: deterministic-serial-failure (' "$out" >/dev/null || fail 'full-suite fallback skipped the serial self-test'
}

# A changed top-level suite selects itself and nothing else.
new_fixture
commit_base
printf '\n# changed suite\n' >>"$repo/test/agents-ff.sh"
commit_delta
run_since
[ "$run_rc" -eq 0 ] || fail 'changed suite run failed'
assert_selected test/agents-ff.sh
assert_only_suite agents-ff.sh

# A changed bin command selects its same-named suite when that suite exists.
new_fixture
ensure_suite own-command.sh
mkdir -p "$repo/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/bin/own-command"
chmod +x "$repo/bin/own-command"
commit_base
printf '\n# changed command\n' >>"$repo/bin/own-command"
commit_delta
run_since
[ "$run_rc" -eq 0 ] || fail 'bin command with its own suite failed'
assert_selected test/own-command.sh
assert_only_suite own-command.sh

# Command references match both bin/X and bare X, but not a longer hyphenated name.
new_fixture
ensure_suite path-command.sh
ensure_suite bare-command.sh
ensure_suite longer-command.sh
ensure_suite tkt-fix.sh
cat >>"$repo/test/path-command.sh" <<'EOF'
if false; then
  bin/tkt-fix --help
fi
EOF
cat >>"$repo/test/bare-command.sh" <<'EOF'
if false; then
  tkt-fix --help
fi
EOF
cat >>"$repo/test/longer-command.sh" <<'EOF'
tkt-fix-foo --help
EOF
mkdir -p "$repo/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/bin/tkt-fix"
chmod +x "$repo/bin/tkt-fix"
commit_base
printf '\n# changed command\n' >>"$repo/bin/tkt-fix"
commit_delta
run_since
[ "$run_rc" -eq 0 ] || {
  cat "$out" >&2
  fail 'bin command reference selection failed'
}
assert_selected test/tkt-fix.sh
assert_selected test/path-command.sh
assert_selected test/bare-command.sh
assert_not_selected test/longer-command.sh
printf '%s\n' suite:tkt-fix.sh suite:path-command.sh suite:bare-command.sh | sort >"$expected"
grep '^suite:' "$log" | sort >"$actual" || :
diff -u "$expected" "$actual" >/dev/null || fail 'command-reference run selected the wrong suites'

# Changes under bin/lib, test/run, and a shared test helper run the full list.
for fallback in bin-lib test-run test-helper; do
  new_fixture
  case "$fallback" in
    bin-lib) mkdir -p "$repo/bin/lib"; target="$repo/bin/lib/helper.sh" ;;
    test-run) target="$repo/test/run" ;;
    test-helper) mkdir -p "$repo/test/lib"; target="$repo/test/lib/helper.sh" ;;
  esac
  [ -e "$target" ] || printf '# fixture helper\n' >"$target"
  commit_base
  printf '\n# trigger %s fallback\n' "$fallback" >>"$target"
  commit_delta
  run_since
  [ "$run_rc" -eq 0 ] || fail "$fallback full-suite fallback failed"
  grep -F "test/run --since $BASE: selected full suite (${target#"$repo"/})" "$out" >/dev/null || {
    cat "$out" >&2
    fail "$fallback fallback selection line missing"
  }
  assert_full_suite_ran
  echo "PASS: $fallback change ran the complete full-suite list"
done

# Documentation-only changes select nothing and return success.
new_fixture
printf 'fixture docs\n' >"$repo/docs/notes.md"
commit_base
printf '\nchanged\n' >>"$repo/docs/notes.md"
commit_delta
run_since
[ "$run_rc" -eq 0 ] || fail 'docs-only selection did not exit 0'
grep -F "test/run --since $BASE: no suites selected" "$out" >/dev/null || {
  cat "$out" >&2
  fail 'docs-only selection did not print no suites selected'
}
[ ! -s "$log" ] || fail 'docs-only change unexpectedly ran a suite'
echo 'PASS: docs-only change selected no suites'

# Skills changes select and run check-pack.
new_fixture
printf 'fixture skill\n' >"$repo/skills/example.md"
commit_base
printf '\nchanged\n' >>"$repo/skills/example.md"
commit_delta
run_since
[ "$run_rc" -eq 0 ] || fail 'skills selection failed'
assert_selected bin/check-pack
grep -F 'check-pack' "$log" >/dev/null || fail 'skills change did not run check-pack'
echo 'PASS: skills change selected check-pack'
: >"$log"
CHECK_PACK_FAIL=1 run_since
[ "$run_rc" -ne 0 ] || fail 'check-pack failure returned success'
grep -F "test/run --since $BASE: selected bin/check-pack" "$out" >/dev/null || fail 'failing check-pack was not selected'
grep -F 'FAIL: check-pack (exit 5)' "$out" >/dev/null || {
  cat "$out" >&2
  fail 'check-pack failure was not reported'
}
echo 'PASS: check-pack failure returned non-zero'

# A selected suite failure propagates a non-zero status.
new_fixture
ensure_suite failing.sh
commit_base
cat >"$repo/test/failing.sh" <<'EOF'
#!/usr/bin/env bash
echo 'fixture selected suite failure'
exit 7
EOF
chmod +x "$repo/test/failing.sh"
commit_delta
run_since
[ "$run_rc" -ne 0 ] || fail 'selected suite failure returned success'
assert_selected test/failing.sh
grep -F 'FAIL: failing.sh (exit 7,' "$out" >/dev/null || {
  cat "$out" >&2
  fail 'selected suite failure was not reported'
}
echo 'PASS: selected suite failure returned non-zero'

# A bad Git revision fails loudly rather than looking like an empty diff.
new_fixture
commit_base
if (cd "$repo" && FIXTURE_LOG="$log" bash test/run --since missing-not-a-revision) >"$out" 2>&1; then
  run_rc=0
else
  run_rc=$?
fi
[ "$run_rc" -ne 0 ] || fail 'bad sha returned success'
grep -F 'test/run: cannot diff' "$out" >/dev/null || {
  cat "$out" >&2
  fail 'bad sha did not print a diff error'
}
echo 'PASS: bad sha failed loudly'

echo 'PASS: test/run --since mapping fixture'

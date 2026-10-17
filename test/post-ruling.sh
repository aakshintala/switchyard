#!/usr/bin/env bash
# Tests for bin/post-ruling: gh is a stub function (no network), HOME and
# TMPDIR point at a temp dir. Each case stages the script into a fixture
# bin/ beside a stub inbox-send, so the script's call through its own
# directory hits the stub and never the real inbox-send.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POST="$SCRIPT_DIR/../bin/post-ruling"
URL="https://github.com/aakshintala/switchyard/issues/504#issuecomment-999"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-post-ruling.XXXXXX")"
mkdir -p "$T/tmp" "$T/home"
export HOME="$T/home" TMPDIR="$T/tmp"
trap 'rm -rf "$T"' EXIT
export T URL

# --- fake gh: logs argv, prints a fixed comment URL for issue comment.
# Touch $T/comment-fail ($T/edit-fail) to fail that call. The posted body
# lands in $T/posted.md for the identical-bytes check.
gh() (
  set -euo pipefail
  {
    printf 'gh'
    printf ' %s' "$@"
    printf '\n'
  } >>"$T/gh.log"
  if [ "${1:-}" = "issue" ] && [ "${2:-}" = "comment" ]; then
    [ ! -e "$T/comment-fail" ] || { echo "fake gh: comment failed" >&2; exit 1; }
    body=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--body-file" ]; then body="$a"; fi
      prev="$a"
    done
    [ -n "$body" ] || { echo "fake gh: no --body-file" >&2; exit 2; }
    cp "$body" "$T/posted.md"
    printf '%s\n' "$URL"
    exit 0
  fi
  if [ "${1:-}" = "issue" ] && [ "${2:-}" = "edit" ]; then
    [ ! -e "$T/edit-fail" ] || { echo "fake gh: edit failed" >&2; exit 1; }
    exit 0
  fi
  echo "fake gh: unexpected call: $*" >&2
  exit 2
)
export -f gh

# stage: reset logs and flags, copy the script into a fixture bin/ beside
# a stub inbox-send that records its call and stdin.
stage() {
  rm -rf "$T/fbin" "$T/gh.log" "$T/inbox.log" "$T/inbox-body.txt" "$T/posted.md"
  rm -f "$T/comment-fail" "$T/edit-fail" "$T/inbox-fail"
  rm -f "$T/stdout.txt" "$T/stderr.txt"
  mkdir -p "$T/fbin"
  cp "$POST" "$T/fbin/post-ruling" || fail "cannot stage post-ruling"
  cat >"$T/fbin/inbox-send" <<STUB
#!/usr/bin/env bash
set -euo pipefail
[ ! -e "$T/inbox-fail" ] || { echo "fake inbox-send: failed" >&2; exit 1; }
{
  printf 'inbox-send'
  printf ' %s' "\$@"
  printf '\n'
} >>"$T/inbox.log"
cat >"$T/inbox-body.txt"
STUB
  chmod +x "$T/fbin/inbox-send"
}

run_post() {
  rm -f "$T/stdout.txt" "$T/stderr.txt"
  bash "$T/fbin/post-ruling" "$@" >"$T/stdout.txt" 2>"$T/stderr.txt"
  rc=$?
}

# --- case (a): the four steps in order
stage
RUN="$T/run-a"; mkdir -p "$RUN"
INBOX="$T/inbox-a"; mkdir -p "$INBOX"
printf 'ruling one\n' >"$T/ruling-a.md"
run_post 504 "$T/ruling-a.md" --repo aakshintala/switchyard --run "$RUN" --remove-label needs-ruling --inbox "$INBOX" --sender surveyor
[ "$rc" = "0" ] || fail "four steps exits 0 (got $rc: $(cat "$T/stderr.txt"))"
COPY="$RUN/switchyard-504-ruling-1.md"
[ -f "$COPY" ] || fail "four steps writes $COPY"
cmp -s "$T/ruling-a.md" "$COPY" || fail "the copy holds identical bytes"
cmp -s "$T/ruling-a.md" "$T/posted.md" || fail "the comment body equals the file"
[ "$(cat "$T/stdout.txt")" = "RULING url=$URL copy=$COPY" ] || fail "stdout names the url and the copy (got: $(cat "$T/stdout.txt"))"
grep -q -F "gh issue comment 504 --repo aakshintala/switchyard --body-file $T/ruling-a.md" "$T/gh.log" || fail "step 1 posts the file as a comment"
grep -q -F "gh issue edit 504 --repo aakshintala/switchyard --remove-label needs-ruling" "$T/gh.log" || fail "step 3 removes the label"
[ "$(cat "$T/inbox-body.txt")" = "ruling for #504 posted: $URL; copy: $COPY" ] || fail "step 4 sends the inbox line (got: $(cat "$T/inbox-body.txt"))"
grep -q -F "inbox-send $INBOX surveyor" "$T/inbox.log" || fail "step 4 calls inbox-send with the dir and sender"
lc="$(grep -n -F 'gh issue comment' "$T/gh.log" | cut -d: -f1)"
le="$(grep -n -F 'gh issue edit' "$T/gh.log" | cut -d: -f1)"
[ "$lc" -lt "$le" ] || fail "the comment lands before the label edit"

# --- case (b): no --inbox skips step 4
stage
RUN="$T/run-b"; mkdir -p "$RUN"
printf 'ruling two\n' >"$T/ruling-b.md"
run_post 505 "$T/ruling-b.md" --repo aakshintala/switchyard --run "$RUN" --remove-label needs-ruling
[ "$rc" = "0" ] || fail "no inbox exits 0 (got $rc: $(cat "$T/stderr.txt"))"
[ ! -e "$T/inbox.log" ] || fail "no inbox makes no inbox call"
[ ! -e "$T/inbox-body.txt" ] || fail "no inbox sends no inbox line"
[ -f "$RUN/switchyard-505-ruling-1.md" ] || fail "no inbox still writes the copy"

# --- case (c): a failing comment stops before the copy
stage
RUN="$T/run-c"; mkdir -p "$RUN"
printf 'ruling three\n' >"$T/ruling-c.md"
touch "$T/comment-fail"
run_post 506 "$T/ruling-c.md" --repo aakshintala/switchyard --run "$RUN" --remove-label needs-ruling
[ "$rc" = "1" ] || fail "failed comment exits 1 (got $rc)"
[ ! -e "$RUN/switchyard-506-ruling-1.md" ] || fail "failed comment writes no copy"
if [ -e "$T/gh.log" ]; then grep -q -F 'issue edit' "$T/gh.log" && fail "failed comment makes no label edit"; fi

# --- case (d): a second ruling for the same issue increments k
stage
RUN="$T/run-d"; mkdir -p "$RUN"
printf 'first\n' >"$T/ruling-d1.md"
printf 'second\n' >"$T/ruling-d2.md"
run_post 507 "$T/ruling-d1.md" --repo aakshintala/switchyard --run "$RUN"
[ "$rc" = "0" ] || fail "first ruling exits 0 (got $rc: $(cat "$T/stderr.txt"))"
[ "$(cat "$T/stdout.txt")" = "RULING url=$URL copy=$RUN/switchyard-507-ruling-1.md" ] || fail "first ruling gets k=1 (got: $(cat "$T/stdout.txt"))"
run_post 507 "$T/ruling-d2.md" --repo aakshintala/switchyard --run "$RUN"
[ "$rc" = "0" ] || fail "second ruling exits 0 (got $rc: $(cat "$T/stderr.txt"))"
[ "$(cat "$T/stdout.txt")" = "RULING url=$URL copy=$RUN/switchyard-507-ruling-2.md" ] || fail "second ruling gets k=2 (got: $(cat "$T/stdout.txt"))"
cmp -s "$T/ruling-d2.md" "$RUN/switchyard-507-ruling-2.md" || fail "second copy holds its own bytes"

# --- case: k follows the largest existing k, ignoring decoys
stage
RUN="$T/run-k"; mkdir -p "$RUN"
printf 'x' >"$RUN/switchyard-508-ruling-1.md"
printf 'x' >"$RUN/switchyard-508-ruling-3.md"
printf 'x' >"$RUN/switchyard-509-ruling-9.md"
printf 'x' >"$RUN/switchyard-508-ruling-x.md"
printf 'new\n' >"$T/ruling-k.md"
run_post 508 "$T/ruling-k.md" --repo aakshintala/switchyard --run "$RUN"
[ "$rc" = "0" ] || fail "gap ruling exits 0 (got $rc: $(cat "$T/stderr.txt"))"
[ -f "$RUN/switchyard-508-ruling-4.md" ] || fail "k is one more than the largest existing k"
cmp -s "$T/ruling-k.md" "$RUN/switchyard-508-ruling-4.md" || fail "gap copy holds identical bytes"

# --- case: file and run paths with spaces
stage
RUN="$T/run dir"; mkdir -p "$RUN"
printf 'spaced\n' >"$T/my ruling.md"
run_post 510 "$T/my ruling.md" --repo aakshintala/switchyard --run "$RUN"
[ "$rc" = "0" ] || fail "spaced paths exit 0 (got $rc: $(cat "$T/stderr.txt"))"
[ -f "$RUN/switchyard-510-ruling-1.md" ] || fail "spaced paths write the copy"
cmp -s "$T/my ruling.md" "$RUN/switchyard-510-ruling-1.md" || fail "spaced copy holds identical bytes"

# --- case (e): usage errors exit 2 and post nothing
stage
RUN="$T/run-e"; mkdir -p "$RUN"
printf 'ruling\n' >"$T/ruling-e.md"
usage_fails() {
  run_post "$@"
  [ "$rc" = "2" ] || fail "usage [$*] exits 2 (got $rc)"
  if [ -e "$T/gh.log" ]; then grep -q -F 'issue comment' "$T/gh.log" && fail "usage [$*] posts nothing"; fi
  [ -z "$(ls "$RUN"/switchyard-*-ruling-*.md 2>/dev/null)" ] || fail "usage [$*] writes no copy"
}
usage_fails
usage_fails 504
usage_fails 504 "$T/ruling-e.md"
usage_fails 504 "$T/ruling-e.md" --repo aakshintala/switchyard
usage_fails 504 "$T/ruling-e.md" --run "$RUN"
usage_fails abc "$T/ruling-e.md" --repo aakshintala/switchyard --run "$RUN"
usage_fails 504 "$T/ruling-e.md" --repo aakshintala/switchyard --run "$RUN" --bogus x
usage_fails 504 "$T/ruling-e.md" --repo aakshintala/switchyard --run "$RUN" --inbox "$T/inbox-e"
usage_fails 504 "$T/ruling-e.md" --repo aakshintala/switchyard --run "$RUN" --sender surveyor

# --- case: a missing --run or --inbox dir exits 1 with nothing posted
stage
printf 'ruling\n' >"$T/ruling-p.md"
run_post 511 "$T/ruling-p.md" --repo aakshintala/switchyard --run "$T/no-such-run"
[ "$rc" = "1" ] || fail "missing run exits 1 (got $rc)"
if [ -e "$T/gh.log" ]; then grep -q -F 'issue comment' "$T/gh.log" && fail "missing run posts nothing"; fi
[ ! -e "$T/no-such-run" ] || fail "missing run is not created"
RUN="$T/run-p"; mkdir -p "$RUN"
run_post 511 "$T/ruling-p.md" --repo aakshintala/switchyard --run "$RUN" --inbox "$T/no-such-inbox" --sender surveyor
[ "$rc" = "1" ] || fail "missing inbox exits 1 (got $rc)"
if [ -e "$T/gh.log" ]; then grep -q -F 'issue comment' "$T/gh.log" && fail "missing inbox posts nothing"; fi
[ -z "$(ls "$RUN"/switchyard-*-ruling-*.md 2>/dev/null)" ] || fail "missing inbox writes no copy"

# --- case: a failed label removal or inbox keeps the earlier results printed
stage
RUN="$T/run-f"; mkdir -p "$RUN"
INBOX="$T/inbox-f"; mkdir -p "$INBOX"
printf 'ruling\n' >"$T/ruling-f.md"
touch "$T/edit-fail"
run_post 512 "$T/ruling-f.md" --repo aakshintala/switchyard --run "$RUN" --remove-label needs-ruling --inbox "$INBOX" --sender surveyor
[ "$rc" = "1" ] || fail "failed label edit exits 1 (got $rc)"
[ "$(cat "$T/stdout.txt")" = "RULING url=$URL copy=$RUN/switchyard-512-ruling-1.md" ] || fail "failed label edit keeps the results printed (got: $(cat "$T/stdout.txt"))"
[ -f "$RUN/switchyard-512-ruling-1.md" ] || fail "failed label edit keeps the copy"
[ ! -e "$T/inbox.log" ] || fail "failed label edit skips the inbox"
rm -f "$T/edit-fail"
touch "$T/inbox-fail"
run_post 513 "$T/ruling-f.md" --repo aakshintala/switchyard --run "$RUN" --remove-label needs-ruling --inbox "$INBOX" --sender surveyor
[ "$rc" = "1" ] || fail "failed inbox exits 1 (got $rc)"
[ "$(cat "$T/stdout.txt")" = "RULING url=$URL copy=$RUN/switchyard-513-ruling-1.md" ] || fail "failed inbox keeps the results printed (got: $(cat "$T/stdout.txt"))"
[ -f "$RUN/switchyard-513-ruling-1.md" ] || fail "failed inbox keeps the copy"

echo "post-ruling: all cases passed"

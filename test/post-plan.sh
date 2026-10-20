#!/usr/bin/env bash
# Tests for bin/post-plan, with a fake gh function serving canned JSON and
# recording every call (no network).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POST="$SCRIPT_DIR/../bin/post-plan"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-post-plan.XXXXXX")"
trap 'rm -rf "$T"' EXIT

ME="plan-bot"
REPO="O/N"
export T ME REPO

# --- fake gh: serves canned JSON, records each call and every posted body
gh() (
  set -euo pipefail
  {
    printf 'gh'
    printf ' %s' "$@"
    printf '\n'
  } >>"$T/calls.log"
  if [ "${1:-}" = "repo" ]; then
    printf '%s\n' "$REPO"
    exit 0
  fi
  [ "${1:-}" = "api" ] || { echo "fake gh: expected api, got ${1:-}" >&2; exit 2; }
  shift
  method=""; endpoint=""; bodyfile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -X) method="$2"; shift 2;;
      -F) case "$2" in
            body=@*) bodyfile="${2#body=@}";;
            *) echo "fake gh: bad -F $2" >&2; exit 2;;
          esac
          shift 2;;
      --jq) shift 2;;
      --paginate) shift;;
      *) if [ -z "$endpoint" ]; then endpoint="$1"; shift
         else echo "fake gh: unexpected $1" >&2; exit 2; fi;;
    esac
  done
  case "$endpoint" in
    user) printf '%s\n' "$ME";;
    repos/*/issues/*/comments)
      if [ -n "$bodyfile" ]; then
        n="$(cat "$T/next-new.txt")"
        printf '%s' "$((n + 1))" >"$T/next-new.txt"
        cp "$bodyfile" "$T/created-$n.md"
        printf '{"html_url":"https://example.invalid/comment/new-%s"}\n' "$n"
      else
        cat "$T/comments.json"
      fi;;
    repos/*/issues/comments/*)
      id="${endpoint##*/}"
      if [ "$method" = "PATCH" ]; then
        cp "$bodyfile" "$T/patched-$id.md"
        printf '{"html_url":"https://example.invalid/comment/%s"}\n' "$id"
      elif [ "$method" = "DELETE" ]; then
        : >"$T/deleted-$id"
      else
        echo "fake gh: bad method [$method] for $endpoint" >&2; exit 2
      fi;;
    *) echo "fake gh: unknown endpoint $endpoint" >&2; exit 2;;
  esac
)
export -f gh

reset_state() {
  rm -f "$T/calls.log" "$T"/patched-*.md "$T"/created-*.md "$T"/deleted-*
  rm -f "$T/stdout.txt" "$T/stderr.txt"
  printf '1' >"$T/next-new.txt"
  printf '[]\n' >"$T/comments.json"
}

run_post() {
  bash "$POST" "$@" >"$T/stdout.txt" 2>"$T/stderr.txt"
  rc=$?
}

# --- fixtures: a small plan, a ~150k plan, and a one-section oversized plan
reset_state
printf '# Title\n\nSome intro.\n\n## Design\n\nDetails here.\n\n## Risks\n\nNone.\n' >"$T/plan1.md"
{
  printf '# Fiber plan\n\nIntro line.\n\n'
  i=1
  while [ "$i" -le 30 ]; do
    printf '## Section %d\n\n' "$i"
    j=1
    while [ "$j" -le 42 ]; do
      printf 'filler %02d-%02d abcdefghijklmnopqrstuvwxyz0123456789 abcdefghijklmnopqrstuvwxyz0123456789 abcdefghijklmnopqrstuvwxyz01\n' "$i" "$j"
      j=$((j + 1))
    done
    printf '\n'
    i=$((i + 1))
  done
} >"$T/plan2.md"
[ "$(wc -c <"$T/plan2.md" | tr -d ' ')" -gt 140000 ] || fail "fixture plan2 is about 150k chars"
{
  printf '## Huge\n\n'
  i=1
  while [ "$i" -le 610 ]; do
    printf 'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\n'
    i=$((i + 1))
  done
} >"$T/huge.md"
# every fixture plan carries a valid ## Gate, which post-plan checks before posting
for f in plan1 plan2 huge; do printf '\n## Gate\n\nbash test/run\n' >>"$T/$f.md"; done

# --- case: a plan without a ## Gate posts nothing and exits 1
reset_state
printf '# Title\n\nNo gate here.\n' >"$T/nogate.md"
run_post 7 "$T/nogate.md" --repo "$REPO"
[ "$rc" = "1" ] || fail "plan without a gate exits 1 (got $rc)"
grep -q 'plan-gate failed; nothing posted' "$T/stderr.txt" || fail "plan without a gate says nothing was posted"
[ ! -e "$T/calls.log" ] || fail "plan without a gate makes no gh calls"

# --- case: a plan under the limit with no prior comments posts one comment
reset_state
run_post 7 "$T/plan1.md"
[ "$rc" = "0" ] || fail "small plan exits 0 (got $rc: $(cat "$T/stderr.txt"))"
[ "$(wc -l <"$T/stdout.txt" | tr -d ' ')" = "1" ] || fail "small plan prints one URL"
[ "$(cat "$T/stdout.txt")" = "https://example.invalid/comment/new-1" ] || fail "small plan prints the created URL"
grep -q 'repo view' "$T/calls.log" || fail "without --repo the repo comes from gh repo view"
[ "$(sed -n '1p' "$T/created-1.md")" = "<!-- post-plan 1/1 -->" ] || fail "created body starts with the 1/1 marker"
tail -n +2 "$T/created-1.md" | cmp -s - "$T/plan1.md" || fail "created body after the marker equals the plan"

# --- case: about 150k chars across many ## sections posts three parts
reset_state
run_post 7 "$T/plan2.md" --repo "$REPO"
[ "$rc" = "0" ] || fail "big plan exits 0 (got $rc: $(cat "$T/stderr.txt"))"
[ "$(wc -l <"$T/stdout.txt" | tr -d ' ')" = "3" ] || fail "big plan prints three URLs"
k=1
while [ "$k" -le 3 ]; do
  [ -f "$T/created-$k.md" ] || fail "part $k is created"
  [ "$(sed -n '1p' "$T/created-$k.md")" = "<!-- post-plan $k/3 -->" ] || fail "part $k marker is $k/3"
  [ "$(wc -m <"$T/created-$k.md" | tr -d ' ')" -le 60000 ] || fail "part $k fits in 60000 characters"
  k=$((k + 1))
done
[ "$(sed -n '2p' "$T/created-1.md")" = "$(sed -n '1p' "$T/plan2.md")" ] || fail "part 1 starts at the plan start"
case "$(sed -n '2p' "$T/created-2.md")" in '## '*) ;; *) fail "part 2 starts before a ## heading";; esac
case "$(sed -n '2p' "$T/created-3.md")" in '## '*) ;; *) fail "part 3 starts before a ## heading";; esac
{ tail -n +2 "$T/created-1.md"; tail -n +2 "$T/created-2.md"; tail -n +2 "$T/created-3.md"; } \
  | cmp -s - "$T/plan2.md" || fail "parts joined without markers equal the plan"
grep -q -- '-X PATCH' "$T/calls.log" && fail "big plan edits nothing"
grep -q -- '-X DELETE' "$T/calls.log" && fail "big plan deletes nothing"

# --- case: two marked comments exist and the plan needs three parts
reset_state
cat >"$T/comments.json" <<'EOF'
[
  {"id":100,"body":"looks good","user":{"login":"plan-bot"},"html_url":"https://example.invalid/comment/100"},
  {"id":101,"body":"<!-- post-plan 1/2 -->\nold part 1","user":{"login":"plan-bot"},"html_url":"https://example.invalid/comment/101"},
  {"id":102,"body":"<!-- post-plan 2/2 -->\nold part 2","user":{"login":"plan-bot"},"html_url":"https://example.invalid/comment/102"}
]
EOF
run_post 7 "$T/plan2.md" --repo "$REPO"
[ "$rc" = "0" ] || fail "re-post exits 0 (got $rc: $(cat "$T/stderr.txt"))"
[ "$(wc -l <"$T/stdout.txt" | tr -d ' ')" = "3" ] || fail "re-post prints three URLs"
[ "$(sed -n '1p' "$T/stdout.txt")" = "https://example.invalid/comment/101" ] || fail "re-post prints the first edited URL"
[ "$(sed -n '1p' "$T/patched-101.md")" = "<!-- post-plan 1/3 -->" ] || fail "first comment is edited with part 1"
[ "$(sed -n '1p' "$T/patched-102.md")" = "<!-- post-plan 2/3 -->" ] || fail "second comment is edited with part 2"
[ "$(sed -n '1p' "$T/created-1.md")" = "<!-- post-plan 3/3 -->" ] || fail "part 3 is created"
{ tail -n +2 "$T/patched-101.md"; tail -n +2 "$T/patched-102.md"; tail -n +2 "$T/created-1.md"; } \
  | cmp -s - "$T/plan2.md" || fail "re-post parts joined equal the plan"
[ ! -e "$T/patched-100.md" ] || fail "the unmarked comment is not edited"
[ ! -e "$T/deleted-100" ] || fail "the unmarked comment is not deleted"
l1="$(grep -n 'issues/comments/101' "$T/calls.log" | cut -d: -f1)"
l2="$(grep -n 'issues/comments/102' "$T/calls.log" | cut -d: -f1)"
l3="$(grep -n 'issues/7/comments -F' "$T/calls.log" | cut -d: -f1)"
[ "$l1" -lt "$l2" ] && [ "$l2" -lt "$l3" ] || fail "both comments are edited in order before the create"

# --- case: three marked comments exist and the plan needs one part
reset_state
cat >"$T/comments.json" <<'EOF'
[
  {"id":201,"body":"<!-- post-plan 1/3 -->\nold part 1","user":{"login":"plan-bot"},"html_url":"https://example.invalid/comment/201"},
  {"id":202,"body":"<!-- post-plan 2/3 -->\nold part 2","user":{"login":"plan-bot"},"html_url":"https://example.invalid/comment/202"},
  {"id":203,"body":"<!-- post-plan 3/3 -->\nold part 3","user":{"login":"plan-bot"},"html_url":"https://example.invalid/comment/203"}
]
EOF
run_post 7 "$T/plan1.md" --repo "$REPO"
[ "$rc" = "0" ] || fail "shrinking re-post exits 0 (got $rc: $(cat "$T/stderr.txt"))"
[ "$(wc -l <"$T/stdout.txt" | tr -d ' ')" = "1" ] || fail "shrinking re-post prints one URL"
[ "$(cat "$T/stdout.txt")" = "https://example.invalid/comment/201" ] || fail "shrinking re-post prints the edited URL"
[ "$(sed -n '1p' "$T/patched-201.md")" = "<!-- post-plan 1/1 -->" ] || fail "the oldest comment is edited with the single part"
tail -n +2 "$T/patched-201.md" | cmp -s - "$T/plan1.md" || fail "edited body after the marker equals the plan"
[ -e "$T/deleted-202" ] || fail "the second comment is deleted"
[ -e "$T/deleted-203" ] || fail "the third comment is deleted"
[ ! -e "$T/created-1.md" ] || fail "shrinking re-post creates nothing"
[ ! -e "$T/patched-202.md" ] || fail "only the oldest comment is edited"

# --- case: a marked comment by another user is left alone
reset_state
cat >"$T/comments.json" <<'EOF'
[
  {"id":301,"body":"<!-- post-plan 1/1 -->\nold part","user":{"login":"plan-bot"},"html_url":"https://example.invalid/comment/301"},
  {"id":302,"body":"<!-- post-plan 1/1 -->\nsomeone else's post","user":{"login":"someone-else"},"html_url":"https://example.invalid/comment/302"}
]
EOF
run_post 7 "$T/plan1.md" --repo "$REPO"
[ "$rc" = "0" ] || fail "other-user re-post exits 0 (got $rc: $(cat "$T/stderr.txt"))"
[ -f "$T/patched-301.md" ] || fail "my marked comment is edited"
[ ! -e "$T/patched-302.md" ] || fail "another user's marked comment is not edited"
[ ! -e "$T/deleted-302" ] || fail "another user's marked comment is not deleted"
[ ! -e "$T/created-1.md" ] || fail "other-user re-post creates nothing"

# --- case: one section over the limit exits 1 naming the heading, posting nothing
reset_state
run_post 7 "$T/huge.md" --repo "$REPO"
[ "$rc" = "1" ] || fail "oversized section exits 1 (got $rc)"
grep -q '## Huge' "$T/stderr.txt" || fail "oversized names the heading on stderr"
if [ -e "$T/calls.log" ]; then
  grep -qE -- '-X (PATCH|DELETE)| -F ' "$T/calls.log" && fail "oversized makes no gh write calls"
fi

# --- case: bad usage exits 2, --help exits 0
run_post
[ "$rc" = "2" ] || fail "no arguments exits 2 (got $rc)"
bash "$POST" --help >"$T/stdout.txt" 2>"$T/stderr.txt"; rc=$?
[ "$rc" = "0" ] || fail "--help exits 0 (got $rc)"
grep -q 'usage: post-plan' "$T/stdout.txt" || fail "--help prints usage to stdout"
bash "$POST" -h >"$T/stdout.txt" 2>"$T/stderr.txt"; rc=$?
[ "$rc" = "0" ] || fail "-h exits 0 (got $rc)"
run_post 7 "$T/missing.md" --repo "$REPO"
[ "$rc" = "2" ] || fail "unreadable plan file exits 2 (got $rc)"

# --- case: --part edits only its own labelled comment, never the unlabelled one
reset_state
cat >"$T/comments.json" <<'EOF'
[
  {"id":401,"body":"<!-- post-plan 1/1 -->\nold unlabelled","user":{"login":"plan-bot"},"html_url":"https://example.invalid/comment/401"},
  {"id":402,"body":"<!-- post-plan P2 1/1 -->\nold part two","user":{"login":"plan-bot"},"html_url":"https://example.invalid/comment/402"}
]
EOF
run_post 7 "$T/plan1.md" --repo "$REPO" --part P2
[ "$rc" = "0" ] || fail "--part P2 exits 0 (got $rc: $(cat "$T/stderr.txt"))"
[ "$(sed -n '1p' "$T/patched-402.md")" = "<!-- post-plan P2 1/1 -->" ] || fail "--part P2 edits the P2 comment with a P2 header"
[ ! -e "$T/patched-401.md" ] || fail "--part P2 does not edit the unlabelled comment"
[ ! -e "$T/deleted-401" ] || fail "--part P2 does not delete the unlabelled comment"
[ ! -e "$T/created-1.md" ] || fail "--part P2 creates nothing when its comment is reused"

# --- case: an unlabelled run never touches a labelled comment
reset_state
cat >"$T/comments.json" <<'EOF'
[
  {"id":411,"body":"<!-- post-plan P1 1/1 -->\nold part one","user":{"login":"plan-bot"},"html_url":"https://example.invalid/comment/411"}
]
EOF
run_post 7 "$T/plan1.md" --repo "$REPO"
[ "$rc" = "0" ] || fail "unlabelled run exits 0 (got $rc: $(cat "$T/stderr.txt"))"
[ "$(sed -n '1p' "$T/created-1.md")" = "<!-- post-plan 1/1 -->" ] || fail "unlabelled run creates a comment with an unlabelled header"
[ ! -e "$T/patched-411.md" ] || fail "unlabelled run does not edit a labelled comment"
[ ! -e "$T/deleted-411" ] || fail "unlabelled run does not delete a labelled comment"

# --- case: --part deletes its extra labelled comments, edits the oldest
reset_state
cat >"$T/comments.json" <<'EOF'
[
  {"id":421,"body":"<!-- post-plan P1 1/2 -->\nold one","user":{"login":"plan-bot"},"html_url":"https://example.invalid/comment/421"},
  {"id":422,"body":"<!-- post-plan P1 2/2 -->\nold two","user":{"login":"plan-bot"},"html_url":"https://example.invalid/comment/422"}
]
EOF
run_post 7 "$T/plan1.md" --repo "$REPO" --part P1
[ "$rc" = "0" ] || fail "--part P1 re-post exits 0 (got $rc: $(cat "$T/stderr.txt"))"
[ "$(sed -n '1p' "$T/patched-421.md")" = "<!-- post-plan P1 1/1 -->" ] || fail "--part P1 edits the oldest P1 comment"
[ ! -e "$T/patched-422.md" ] || fail "--part P1 does not edit the second P1 comment"
[ -e "$T/deleted-422" ] || fail "--part P1 deletes the second P1 comment"

# --- case: a bad --part label is bad usage and makes no gh calls
reset_state
run_post 7 "$T/plan1.md" --repo "$REPO" --part 'bad label'
[ "$rc" = "2" ] || fail "--part with a space exits 2 (got $rc)"
[ ! -e "$T/calls.log" ] || fail "bad --part makes no gh calls"

echo "post-plan: all cases passed"

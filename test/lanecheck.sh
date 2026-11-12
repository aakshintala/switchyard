#!/bin/bash
# test-lanecheck.sh: exercise bin/lanecheck against a sandbox roster.
#
# No network: `ssh` and `gh` are stubbed on PATH, because lanecheck calls both
# by bare name (lanecheck:177,182 and the `gh pr list` in the done guard) and
# neither is parameterised.
#
# The case this file exists for is `two-sessions-first-retired-keeps-fence`.
# The fence-retirement fix shipped on 2026-11-04 keyed on the session rather
# than the ticket and pulled the grants out from under two running builds the
# minute it landed. The sandbox that cleared it had one session per ticket --
# the one shape that cannot show the bug. A case is only worth its line if it
# is the case that would fail.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
BIN=${FW_TEST_BIN:-$here/../bin}
T=$(mktemp -d "${TMPDIR:-/tmp}/lctest.XXXXXX")
trap 'rm -rf "${T:?}"' EXIT
trap 'exit 130' INT TERM
rc=0
ok() { printf 'ok %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; rc=1; }

mkdir -p "$T/stub" "$T/home/.local/bin/cards"
HOME="$T/home"
export HOME
unset FW_OWNER_ASK
# Quiet stubs. `gh` serves the open-PR list from $T/prs so a case can seed it;
# an empty list means no PR guard. `ssh` serves the two scan probes from files.
#
# `gh pr view <n>` is dispatched separately from `gh pr list`: the retirement
# report resolves a `pr#<n>` claim holder through its PR's head branch, and it
# must work for a merged PR, which is absent from the open-PR list. The branch
# comes from $STUBD/prbranch-<n>, so a case seeds one file per PR it names. A
# missing file exits 1 with no output, which is the real tool's shape for a PR
# it cannot read and the input the UNRESOLVED case needs.
cat > "$T/stub/gh" <<'EOF'
#!/bin/bash
if [ -n "${GH_BOOM:-}" ]; then echo "HTTP 502" >&2; exit 1; fi
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  cat "$STUBD/prbranch-${3:-}" 2>/dev/null || exit 1
  exit 0
fi
case " $* " in
  *" --state merged "*)
    [ "${GH_MERGED_BOOM:-0}" != 1 ] || { echo "HTTP 502" >&2; exit 1; }
    cat "$STUBD/merged-prs" 2>/dev/null || echo '[]'
    exit 0
    ;;
esac
cat "$STUBD/prs" 2>/dev/null || true
exit 0
EOF
cat > "$T/stub/ssh" <<'EOF'
#!/bin/bash
case " $* " in
  *"claude agents"*) cat "$STUBD/cagents" 2>/dev/null || echo '[]';;
  *"delegate session list"*) cat "$STUBD/dsess" 2>/dev/null || echo '{"ok":true,"sessions":[]}';;
  *"ps -eo args"*) cat "$STUBD/pending" 2>/dev/null || true;;
  *"delegate-jobs"*) cat "$STUBD/asking" 2>/dev/null || true;;
  *) echo '[]';;
esac
exit 0
EOF
cat > "$T/stub/owner-ask" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$STUBD/owner-ask.log"
[ "${1:-}" = list ] || exit 2
[ "${OWNER_ASK_BOOM:-0}" != 1 ] || exit 1
cat "$STUBD/owner-ask-list" 2>/dev/null || true
EOF
cat > "$T/stub/claude" <<'EOF'
#!/bin/sh
[ "${1:-}" = agents ] && [ "${2:-}" = --json ] || exit 2
cat "$STUBD/cagents" 2>/dev/null || echo '[]'
EOF
cat > "$T/stub/delegate" <<'EOF'
#!/bin/sh
if [ "${1:-}" = version ] && [ "${DELEGATE_STALE_TEST:-0}" = 1 ]; then
  printf '%s\n' 'delegate 0.0.0 (built from 1111111111111111111111111111111111111111)' \
    'warn  delegate binary is stale: built from 1111111111111111111111111111111111111111, but delegate/ is at 2222222222222222222222222222222222222222'
  exit 0
fi
[ "${1:-}" = session ] && [ "${2:-}" = list ] || exit 2
cat "$STUBD/dsess" 2>/dev/null || echo '{"ok":true,"sessions":[]}'
EOF
cat > "$T/stub/file-claim" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$STUBD/file-claim.log"
[ "${1:-}" = list ] && exit 0
[ "${1:-}" = release ] && exit 0
if [ "${1:-}" = prune ]; then
  [ "${STUB_PRUNE_FAIL:-0}" != 1 ] || { echo 'stub file-claim prune: unreachable' >&2; exit 2; }
  lane=""
  while [ $# -gt 0 ]; do
    [ "$1" != --lane ] || { lane="$2"; shift 2; continue; }
    shift
  done
  awk -F '\t' -v lane="$lane" '$2 != lane' "$STUBD/claim-rows" >"$STUBD/claim-rows.new"
  mv "$STUBD/claim-rows.new" "$STUBD/claim-rows"
  exit 0
fi
exit 2
EOF
cat > "$T/stub/inbox-watchers" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$T/stub/boxstale" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/stub/gh" "$T/stub/ssh" "$T/stub/claude" "$T/stub/delegate" \
  "$T/stub/file-claim" "$T/stub/owner-ask" "$T/stub/inbox-watchers" "$T/stub/boxstale"
cp "$T/stub/owner-ask" "$HOME/.local/bin/owner-ask"
chmod +x "$HOME/.local/bin/owner-ask"
export STUBD=$T PATH=$T/stub:$PATH
: > "$T/claim-rows"
export BOX_SSH=$T/stub/ssh FW_DELEGATE=$T/stub/delegate \
  FW_FILE_CLAIM=$T/stub/file-claim FW_INBOX_WATCHERS=$T/stub/inbox-watchers \
  FW_BOXSTALE=$T/stub/boxstale
printf '[]' > "$T/cagents"
printf '{"ok":true,"sessions":[]}' > "$T/dsess"
: > "$T/prs"
: > "$T/merged-prs"
: > "$T/owner-ask-list"
: > "$T/file-claim.log"
: > "$T/pending"
: > "$T/asking"

old() { # $1 like 3H or 40M
  python3 - "$1" <<'PY'
import datetime, sys
n, unit = int(sys.argv[1][:-1]), sys.argv[1][-1]
delta = datetime.timedelta(hours=n) if unit == "H" else datetime.timedelta(minutes=n)
print((datetime.datetime.now(datetime.timezone.utc) - delta).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}
age_file() { # set path mtime to N minutes ago, portably
  python3 - "$1" "$2" <<'PY'
import os, sys, time
stamp = time.time() - int(sys.argv[2]) * 60
os.utime(sys.argv[1], (stamp, stamp))
PY
}
future() { # print an ISO UTC timestamp N minutes from now, portably
  python3 - "$1" <<'PY'
import datetime, sys
stamp = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=int(sys.argv[1]))
print(stamp.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

# Each case gets its own run dir: retirement appends, so a shared one carries
# the previous case's roster-done into the next and the fence cases stop being
# independent.
newrun() {
  r=$T/run$1; rm -rf "$r"; mkdir -p "$r/done"; : > "$r/roster"; : > "$r/roster-done"
  printf '%s\n' "$r"
}
lane() { # lane <run> <ticket> <name> <id> [age, default 3H]
  printf '%s\t%s\tmuse\t%s\t%s\n' "$(old "${5:-3H}")" "$2" "$3" "$4" >> "$1/roster"
}
grant() { # grant <run> <ticket>
  printf 'GRANT\n' > "$1/fiber-$2-fence-grant-20261104T0000Z.md"
}
write_owner_card() { # id title body
  python3 - "$HOME/.local/bin/cards/$1.json" "$1" "$2" "$3" <<'PY'
import json, sys
path, card_id, title, body = sys.argv[1:]
with open(path, "w") as f:
    json.dump({"id": card_id, "title": title, "context": body}, f)
PY
}
write_merged_pr() { # number branch mergedAt
  printf '[{"number":%s,"headRefName":"%s","mergedAt":"%s"}]\n' "$1" "$2" "$3" > "$T/merged-prs"
}

# The retired-lane query lists only tickets whose roster entries are all retired.
r=$(newrun retired-query)
lane "$r" 2001 fiber-2001-plan jid-plan
lane "$r" 2001 fiber-2001-build jid-build
latest_done=$(old 1H)
printf '%s\t2001\tfiber-2001-plan\n' "$(old 2H)" >"$r/roster-done"
printf '%s\t2001\tfiber-2001-build\n' "$latest_done" >>"$r/roster-done"
lane "$r" 2002 fiber-2002-plan jid-plan
lane "$r" 2002 fiber-2002-build jid-build
printf '%s\t2002\tfiber-2002-plan\n' "$(old 2H)" >>"$r/roster-done"
lane "$r" 2003 fiber-2003-build jid-build
printf '%s\t2003\n' "$(old 2H)" >>"$r/roster-done"
lane "$r" 2004 fiber-2004-build jid-build
printf '%s\t2004\t\thanded-to-owner handoff-2004 PR #4170\n' "$(old 2H)" >>"$r/roster-done"
lane "$r" 2005 fiber-2005-build jid-build
printf 'not-a-timestamp\t2005\n' >>"$r/roster-done"
out=$(FW_RUN=$r bash "$BIN/lanecheck" retired 2>"$T/retired-query.err"); grc=$?
if [ "$grc" = 0 ] && [ "$(printf '%s\n' "$out" | cut -f1)" = "$(printf 'fiber-2001\nfiber-2003')" ] \
  && [ "$(printf '%s\n' "$out" | awk -F '\t' '$1 == "fiber-2001" {print $2}')" = "$latest_done" ]; then
  ok retired-query-lists-only-fully-retired-ticket-lanes
else
  fail "retired-query-lists-only-fully-retired-ticket-lanes (rc=$grc; $out; $(cat "$T/retired-query.err"))"
fi
r=$(newrun retired-query-missing); rm -f "$r/roster"
FW_RUN=$r bash "$BIN/lanecheck" retired >/dev/null 2>&1; grc=$?
if [ "$grc" -ne 0 ]; then ok retired-query-fails-when-roster-cannot-be-read; else fail retired-query-fails-when-roster-cannot-be-read; fi

# lanecheck forwards a stale-install warning from delegate version exactly once.
# A binary predating `version` exits nonzero and remains a silent, non-fatal skip.
r=$(newrun 0)
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 DELEGATE_STALE_TEST=1 bash "$BIN/lanecheck" 2>&1); grc=$?
warning='warn  delegate binary is stale: built from 1111111111111111111111111111111111111111, but delegate/ is at 2222222222222222222222222222222222222222'
if [ "$grc" = 0 ] && [ "$(printf '%s\n' "$out" | grep -Fc "$warning")" = 1 ]; then
  ok stale-delegate-warning-once
else
  fail "stale-delegate-warning-once (rc=$grc) $out"
fi
r=$(newrun 0-old)
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1); grc=$?
if [ "$grc" = 0 ] && ! printf '%s\n' "$out" | grep -qF 'delegate binary is stale'; then
  ok old-delegate-version-is-optional
else
  fail "old-delegate-version-is-optional (rc=$grc) $out"
fi

# --- the two-session fence cases ---------------------------------------------
# A ticket runs several sessions across its phases and the fence belongs to the
# ticket, so the first session retiring must not drop it.
r=$(newrun 1); lane "$r" 4089 fiber-4089-plan aaa11111; lane "$r" 4089 fiber-4089-build bbb22222; grant "$r" 4089
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 4089:fiber-4089-plan 2>&1)
if [ -e "$r/fiber-4089-fence-grant-20261104T0000Z.md" ] && printf '%s' "$out" | grep -q 'fence kept for #4089: 1 session'; then
  ok two-sessions-first-retired-keeps-fence
else
  fail "two-sessions-first-retired-keeps-fence ($out)"
fi
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 4089:fiber-4089-build 2>&1)
if [ -e "$r/done/fiber-4089-fence-grant-20261104T0000Z.md" ] && [ ! -e "$r/fiber-4089-fence-grant-20261104T0000Z.md" ]; then
  ok two-sessions-last-retired-retires-fence
else
  fail "two-sessions-last-retired-retires-fence ($out)"
fi

# A bare-ticket retirement ends the ticket outright, however many sessions ran.
r=$(newrun 2); lane "$r" 4152 fiber-4152-plan ccc33333; lane "$r" 4152 fiber-4152-build ddd44444; grant "$r" 4152
FW_RUN=$r bash "$BIN/lanecheck" done 4152 >/dev/null 2>&1
if [ -e "$r/done/fiber-4152-fence-grant-20261104T0000Z.md" ]; then ok bare-ticket-retires-fence; else fail bare-ticket-retires-fence; fi

# Repeating done for an exact-session retirement is a quiet no-op: do not stop
# its session and do not append another retirement row.
r=$(newrun 2a); lane "$r" 1401 fiber-1401-plan deadbeef
printf '%s\t1401\tfiber-1401-plan\n' "$(old 2H)" > "$r/roster-done"
printf '{"ok":true,"sessions":[{"id":"deadbeef","activeTurnId":null,"status":"idle"}]}' > "$T/dsess"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 1401:fiber-1401-plan 2>&1); grc=$?
if [ "$grc" = 0 ] && [ "$out" = 'already retired: #1401:fiber-1401-plan' ] \
  && [ "$(wc -l < "$r/roster-done" | tr -d ' ')" = 1 ]; then
  ok done-exact-session-already-retired-is-no-op
else
  fail "done-exact-session-already-retired-is-no-op (rc=$grc; $out; $(cat "$r/roster-done"))"
fi

# A ticket-wide roster-done row already retires each earlier target session.
r=$(newrun 2b); lane "$r" 1402 fiber-1402-plan deadbeef
printf '%s\t1402\n' "$(old 2H)" > "$r/roster-done"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 1402 2>&1); grc=$?
if [ "$grc" = 0 ] && [ "$out" = 'already retired: #1402:fiber-1402-plan' ] \
  && [ "$(wc -l < "$r/roster-done" | tr -d ' ')" = 1 ]; then
  ok done-ticket-wide-already-retired-is-no-op
else
  fail "done-ticket-wide-already-retired-is-no-op (rc=$grc; $out; $(cat "$r/roster-done"))"
fi

# A handoff on an already-retired target still checks the card and records its
# PR on the existing row, rather than silently returning or duplicating it.
r=$(newrun 2b1); lane "$r" 1405 fiber-1405-build deadbabe
printf '%s\t1405\tfiber-1405-build\n' "$(old 2H)" > "$r/roster-done"
printf '4175 tests/1405-owner-handoff\n' > "$T/prs"
write_owner_card 0610-fly-1589 'Review PR #4175' 'Please merge PR #4175 after review.'
printf '0610-fly-1589 flywheel Review PR #4175\n' > "$T/owner-ask-list"
: > "$T/owner-ask.log"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 1405 --handed-to-owner 0610-fly-1589 2>&1); grc=$?
if [ "$grc" = 0 ] && printf '%s' "$out" | grep -qF 'handed-to-owner 0610-fly-1589 PR #4175' \
  && grep -qF 'handed-to-owner 0610-fly-1589 PR #4175' "$r/roster-done" \
  && [ "$(wc -l < "$r/roster-done" | tr -d ' ')" = 1 ] \
  && grep -qx 'list' "$T/owner-ask.log"; then
  ok done-already-retired-records-owner-handoff
else
  fail "done-already-retired-records-owner-handoff (rc=$grc; $out; $(cat "$r/roster-done"))"
fi

# A session-scoped handoff annotates that session's retirement row even when
# a later row for another session of the ticket follows it.
r=$(newrun 2b1a)
printf '%s\t1406\tmuse\tfiber-1406-plan\tplanjid\n' "$(old 4H)" > "$r/roster"
printf '%s\t1406\tmuse\tfiber-1406-build\tbuildjid\n' "$(old 3H)" >> "$r/roster"
printf '%s\t1406\tfiber-1406-plan\n' "$(old 3H)" > "$r/roster-done"
printf '%s\t1406\tfiber-1406-build\n' "$(old 2H)" >> "$r/roster-done"
printf '4176 tests/1406-owner-handoff\n' > "$T/prs"
write_owner_card 0610-fly-1590 'Review PR #4176' 'Please merge PR #4176 after review.'
printf '0610-fly-1590 flywheel Review PR #4176\n' > "$T/owner-ask-list"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 1406:fiber-1406-plan --handed-to-owner 0610-fly-1590 2>&1); grc=$?
first_row=$(sed -n '1p' "$r/roster-done")
second_row=$(sed -n '2p' "$r/roster-done")
if [ "$grc" = 0 ] && printf '%s' "$first_row" | grep -qF 'handed-to-owner 0610-fly-1590 PR #4176' \
  && ! printf '%s' "$second_row" | grep -qF 'handed-to-owner 0610-fly-1590 PR #4176'; then
  ok done-session-scoped-handoff-annotates-matching-row
else
  fail "done-session-scoped-handoff-annotates-matching-row (rc=$grc; $out; $first_row / $second_row)"
fi

# FW_DONE_FORCE does not make an already-retired handoff record an annotation.
r=$(newrun 2b1b); lane "$r" 1407 fiber-1407-build forcejid
printf '%s\t1407\n' "$(old 2H)" > "$r/roster-done"
printf '4177 tests/1407-owner-handoff\n' > "$T/prs"
write_owner_card 0610-fly-1591 'Review PR #4177' 'Please merge PR #4177 after review.'
printf '0610-fly-1591 flywheel Review PR #4177\n' > "$T/owner-ask-list"
out=$(FW_RUN=$r FW_DONE_FORCE=1 bash "$BIN/lanecheck" done 1407 --handed-to-owner 0610-fly-1591 2>&1); grc=$?
warning='WARNING: handed-to-owner card 0610-fly-1591 was not recorded on a retirement row.'
if [ "$grc" = 0 ] && [ "$(printf '%s\n' "$out" | grep -Fc "$warning")" = 1 ] \
  && ! grep -qF 'handed-to-owner 0610-fly-1591' "$r/roster-done"; then
  ok done-force-already-retired-handoff-warns-when-unrecorded
else
  fail "done-force-already-retired-handoff-warns-when-unrecorded (rc=$grc; $out; $(cat "$r/roster-done"))"
fi

# Repeating done after a partial retirement completes fence and claim cleanup,
# while preserving the existing row and the established no-op message.
r=$(newrun 2b2); lane "$r" 1410 fiber-1410-build deadcafe; grant "$r" 1410
printf '%s\t1410\n' "$(old 2H)" > "$r/roster-done"
: > "$T/file-claim.log"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 1410 2>&1); grc=$?
if [ "$grc" = 0 ] && printf '%s' "$out" | grep -qF 'already retired: #1410:fiber-1410-build' \
  && [ -e "$r/done/fiber-1410-fence-grant-20261104T0000Z.md" ] \
  && [ ! -e "$r/fiber-1410-fence-grant-20261104T0000Z.md" ] \
  && [ "$(wc -l < "$r/roster-done" | tr -d ' ')" = 1 ] \
  && grep -qx 'prune --lane fiber-1410' "$T/file-claim.log" \
  && grep -qx 'prune --lane fiber-1410-build' "$T/file-claim.log"; then
  ok done-already-retired-completes-fence-and-claim-cleanup
else
  fail "done-already-retired-completes-fence-and-claim-cleanup (rc=$grc; $out; claims=$(cat "$T/file-claim.log"))"
fi

# Ticket-wide retirement prunes the retired lane's claims, and a failed prune is only a warning.
r=$(newrun 2d-prune); lane "$r" 1411 fiber-1411-build eee55555
printf 'path.txt\tfiber-1411\n' >"$T/claim-rows"
: >"$T/file-claim.log"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 1411 2>&1); grc=$?
if [ "$grc" = 0 ] && [ ! -s "$T/claim-rows" ] \
  && grep -qx 'prune --lane fiber-1411' "$T/file-claim.log"; then
  ok done-prunes-claims-for-retired-lane
else
  fail "done-prunes-claims-for-retired-lane (rc=$grc; $out; rows=$(cat "$T/claim-rows"); calls=$(cat "$T/file-claim.log"))"
fi
r=$(newrun 2e-prune); lane "$r" 1412 fiber-1412-build fff66666
printf 'path.txt\tfiber-1412\n' >"$T/claim-rows"
: >"$T/file-claim.log"
out=$(FW_RUN=$r STUB_PRUNE_FAIL=1 bash "$BIN/lanecheck" done 1412 >"$T/done-prune.out" 2>"$T/done-prune.err"); grc=$?
out="$(cat "$T/done-prune.out")"
err="$(cat "$T/done-prune.err")"
if [ "$grc" = 0 ] && printf '%s' "$out" | grep -qF 'CLAIMS NOT RELEASED for fiber-1412' \
  && [ "$(wc -l < "$r/roster-done" | tr -d ' ')" = 1 ]; then
  ok done-continues-when-file-claim-prune-fails
else
  fail "done-continues-when-file-claim-prune-fails (rc=$grc; stdout=$out; stderr=$err)"
fi

# A JID-prefix retirement matches the full session id in the roster.
r=$(newrun 2c); lane "$r" 1403 fiber-1403-plan abcd1234
printf '%s\t1403\tabcd\n' "$(old 2H)" > "$r/roster-done"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 1403:abcd123 2>&1); grc=$?
if [ "$grc" = 0 ] && [ "$out" = 'already retired: #1403:fiber-1403-plan' ] \
  && [ "$(wc -l < "$r/roster-done" | tr -d ' ')" = 1 ]; then
  ok done-jid-prefix-already-retired-is-no-op
else
  fail "done-jid-prefix-already-retired-is-no-op (rc=$grc; $out; $(cat "$r/roster-done"))"
fi

# The old plan row is retired, but done on a newer unretired plan row must use
# the ordinary retirement path rather than mistaking the ticket for complete.
r=$(newrun 2d)
printf '%s\t1404\tmuse\tfiber-1404-plan-old\toldjid\n' "$(old 4H)" > "$r/roster"
printf '%s\t1404\tmuse\tfiber-1404-plan-new\tnewjid\n' "$(old 1H)" >> "$r/roster"
printf '%s\t1404\tfiber-1404-plan-old\n' "$(old 2H)" > "$r/roster-done"
printf '{"ok":true,"sessions":[]}' > "$T/dsess"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 1404:fiber-1404-plan-new 2>&1); grc=$?
if [ "$grc" = 0 ] && printf '%s' "$out" | grep -q '^retired: 1404:fiber-1404-plan-new$' \
  && ! printf '%s' "$out" | grep -q '^already retired:' \
  && [ "$(wc -l < "$r/roster-done" | tr -d ' ')" = 2 ] \
  && grep -Fq $'\t1404\tfiber-1404-plan-new' "$r/roster-done"; then
  ok done-newer-unretired-plan-still-retires
else
  fail "done-newer-unretired-plan-still-retires (rc=$grc; $out; $(cat "$r/roster-done"))"
fi

# A session id retires the same row its name would: the roster records both and
# the operator has whichever one the report printed.
r=$(newrun 3); lane "$r" 4026 fiber-4026-build eee55555; grant "$r" 4026
FW_RUN=$r bash "$BIN/lanecheck" done 4026:eee55555 >/dev/null 2>&1
if [ -e "$r/done/fiber-4026-fence-grant-20261104T0000Z.md" ]; then ok retire-by-session-id; else fail retire-by-session-id; fi

# Another ticket's grant is untouched by this ticket's retirement.
r=$(newrun 4); lane "$r" 4026 fiber-4026-build fff66666; grant "$r" 4026; grant "$r" 4099
FW_RUN=$r bash "$BIN/lanecheck" done 4026 >/dev/null 2>&1
if [ -e "$r/fiber-4099-fence-grant-20261104T0000Z.md" ]; then ok other-ticket-fence-untouched; else fail other-ticket-fence-untouched; fi

# --- the age guard -----------------------------------------------------------
r=$(newrun 5); lane "$r" 3975 fiber-3975-build 777 10M; grant "$r" 3975
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 3975 2>&1); grc=$?
if [ "$grc" = 2 ] && printf '%s' "$out" | grep -q 'REFUSING to retire 3975' && [ "$(grep -c '' "$r/roster-done")" = 0 ]; then
  ok age-guard-refuses-young-lane
else
  fail "age-guard-refuses-young-lane (rc=$grc) $out"
fi
out=$(FW_RUN=$r FW_DONE_FORCE=1 bash "$BIN/lanecheck" done 3975 2>&1); grc=$?
if [ "$grc" = 0 ] && printf '%s' "$out" | grep -q 'FORCING retire of 3975' && [ "$(grep -c '' "$r/roster-done")" = 1 ]; then
  ok age-guard-force-overrides
else
  fail "age-guard-force-overrides (rc=$grc) $out"
fi

# The #4097 case: a plan session that has reported while the build session it
# handed off to was launched seconds ago. Scoping to the session must not read
# the ticket's newest entry, or the form exists and cannot be used.
r=$(newrun 6); lane "$r" 4097 fiber-4097-plan 888 3H; lane "$r" 4097 fiber-4097-build 999 1M
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 4097:fiber-4097-plan 2>&1); grc=$?
if [ "$grc" = 0 ] && ! printf '%s' "$out" | grep -q REFUSING; then ok age-check-scoped-to-session; else fail "age-check-scoped-to-session (rc=$grc) $out"; fi

# A newly merged no-prefix fiber branch can release its own young session.
r=$(newrun 5a); lane "$r" 3975 fiber-3975-build 777 10M
: > "$T/prs"; write_merged_pr 4171 fiber-3975 "$(old 5M)"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 3975:fiber-3975-build 2>&1); grc=$?
if [ "$grc" = 0 ] \
  && printf '%s' "$out" | grep -qF 'age guard skipped for 3975:fiber-3975-build — PR #4171 merged' \
  && grep -qF '3975' "$r/roster-done"; then
  ok age-guard-skips-for-newer-fiber-branch-merge
else
  fail "age-guard-skips-for-newer-fiber-branch-merge (rc=$grc) $out"
fi

# A part PR can use the exact branch stored in that ticket's current state.
r=$(newrun 5b); lane "$r" 3976 fiber-3976-build 778 10M
printf 'branch=feature/3976-part-two\npart=2\n' > "$r/switchyard-3976.state"
: > "$T/prs"; write_merged_pr 4172 feature/3976-part-two "$(old 5M)"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 3976:fiber-3976-build 2>&1); grc=$?
if [ "$grc" = 0 ] \
  && printf '%s' "$out" | grep -qF 'age guard skipped for 3976:fiber-3976-build — PR #4172 merged'; then
  ok age-guard-matches-state-branch-for-part
else
  fail "age-guard-matches-state-branch-for-part (rc=$grc) $out"
fi

# An earlier part's merge cannot excuse a young session on a later part.
r=$(newrun 5c); lane "$r" 3977 fiber-3977-build 779 10M
: > "$T/prs"; write_merged_pr 4173 fiber-3977 "$(old 20M)"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 3977:fiber-3977-build 2>&1); grc=$?
if [ "$grc" = 2 ] && printf '%s' "$out" | grep -qF 'REFUSING to retire 3977:fiber-3977-build' \
  && [ "$(grep -c '' "$r/roster-done")" = 0 ]; then
  ok age-guard-refuses-older-merged-pr
else
  fail "age-guard-refuses-older-merged-pr (rc=$grc) $out"
fi

# The bypass is session-scoped; a bare ticket still sees the age guard.
r=$(newrun 5d); lane "$r" 3978 fiber-3978-build 780 10M
: > "$T/prs"; write_merged_pr 4174 fiber-3978 "$(old 5M)"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 3978 2>&1); grc=$?
if [ "$grc" = 2 ] && printf '%s' "$out" | grep -qF 'REFUSING to retire 3978' \
  && [ "$(grep -c '' "$r/roster-done")" = 0 ]; then
  ok age-guard-refuses-bare-ticket-after-merge
else
  fail "age-guard-refuses-bare-ticket-after-merge (rc=$grc) $out"
fi

# An open but unmerged ticket still refuses a young scoped retirement.
r=$(newrun 5e); lane "$r" 3979 fiber-3979-build 781 10M
: > "$T/merged-prs"; printf '4175 fix/3979-part-two\n' > "$T/prs"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 3979:fiber-3979-build 2>&1); grc=$?
if [ "$grc" = 2 ] && printf '%s' "$out" | grep -qF 'REFUSING to retire 3979:fiber-3979-build' \
  && [ "$(grep -c '' "$r/roster-done")" = 0 ]; then
  ok age-guard-refuses-unmerged-ticket
else
  fail "age-guard-refuses-unmerged-ticket (rc=$grc) $out"
fi

# A failed merged-PR lookup never authorizes a young scoped retirement.
r=$(newrun 5f); lane "$r" 3980 fiber-3980-build 782 10M
: > "$T/prs"; write_merged_pr 4176 fiber-3980 "$(old 5M)"
out=$(FW_RUN=$r GH_MERGED_BOOM=1 bash "$BIN/lanecheck" done 3980:fiber-3980-build 2>&1); grc=$?
if [ "$grc" = 2 ] && printf '%s' "$out" | grep -qF 'REFUSING to retire 3980:fiber-3980-build' \
  && [ "$(grep -c '' "$r/roster-done")" = 0 ]; then
  ok age-guard-refuses-merged-pr-lookup-failure
else
  fail "age-guard-refuses-merged-pr-lookup-failure (rc=$grc) $out"
fi

# --- the open-PR guard -------------------------------------------------------
# The lane's last step is the ship, not the green PR, so an open PR on this
# ticket's branch refuses retirement.
r=$(newrun 7); lane "$r" 4155 fiber-4155-build abc
printf '4170 tests/4155-selector\n' > "$T/prs"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 4155 2>&1); grc=$?
if [ "$grc" = 2 ] && printf '%s' "$out" | grep -q 'PR(s) 4170 still open'; then ok pr-guard-refuses-open-pr; else fail "pr-guard-refuses-open-pr (rc=$grc) $out"; fi

# FW_OWNER_ASK does not waive the ordinary open-PR guard for done.
r=$(newrun 7aa); lane "$r" 4155 fiber-4155-build abc
printf '4170 tests/4155-selector\n' > "$T/prs"
out=$(FW_RUN=$r FW_OWNER_ASK="$T/stub/owner-ask" bash "$BIN/lanecheck" done 4155 2>&1); grc=$?
if [ "$grc" = 2 ] && printf '%s' "$out" | grep -q 'PR(s) 4170 still open' \
  && [ "$(wc -l < "$r/roster-done" | tr -d ' ')" = 0 ]; then
  ok fw-owner-ask-does-not-waive-open-pr-guard
else
  fail "fw-owner-ask-does-not-waive-open-pr-guard (rc=$grc) $out"
fi

# An open owner card naming this PR waives only the open-PR guard. Retirement
# records the handoff and leaves both the grant and file claims in place.
r=$(newrun 7a); lane "$r" 4155 fiber-4155-build abc; grant "$r" 4155
printf '4170 tests/4155-selector\n' > "$T/prs"
write_owner_card 0610-fly-1234 'Review PR #4170' 'Please merge PR #4170 after label review.'
printf '0610-fly-1234 flywheel Review PR #4170\n' > "$T/owner-ask-list"
: > "$T/file-claim.log"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 4155 --handed-to-owner 0610-fly-1234 2>&1); grc=$?
if [ "$grc" = 0 ] && printf '%s' "$out" | grep -qF 'handed-to-owner 0610-fly-1234 PR #4170' \
  && grep -qF 'handed-to-owner 0610-fly-1234 PR #4170' "$r/roster-done" \
  && [ -f "$r/fiber-4155-fence-grant-20261104T0000Z.md" ] \
  && ! grep -q '^release ' "$T/file-claim.log"; then
  ok handed-to-owner-pr-card-keeps-claims
else
  fail "handed-to-owner-pr-card-keeps-claims (rc=$grc) $out"
fi

# FW_OWNER_ASK is never honored as an alternate owner authority.
r=$(newrun 7f); lane "$r" 4155 fiber-4155-build abc
override_card="untrusted-test-$$"
write_owner_card "$override_card" 'Review PR #4170' 'Please merge PR #4170.'
printf '%s flywheel Review PR #4170\n' "$override_card" > "$T/owner-ask-list"
: > "$T/owner-ask.log"
out=$(FW_RUN=$r FW_OWNER_ASK="$T/stub/owner-ask" bash "$BIN/lanecheck" done 4155 --handed-to-owner "$override_card" 2>&1); grc=$?
if [ "$grc" = 2 ] && printf '%s' "$out" | grep -qF 'FW_OWNER_ASK is not honoured for --handed-to-owner' \
  && [ ! -s "$T/owner-ask.log" ] \
  && [ "$(wc -l < "$r/roster-done" | tr -d ' ')" = 0 ]; then
  ok handed-to-owner-rejects-fw-owner-ask
else
  fail "handed-to-owner-rejects-fw-owner-ask (rc=$grc) $out"
fi

# A missing fixed owner-ask binary names its path instead of looking like a
# closed card. Restore it immediately after this isolated invocation.
r=$(newrun 7g); lane "$r" 4155 fiber-4155-build abc
printf '%s flywheel Review PR #4170\n' "$override_card" > "$T/owner-ask-list"
owner_ask_bin="$HOME/.local/bin/owner-ask"
mv "$owner_ask_bin" "$T/owner-ask.saved"
out=$(env -u FW_OWNER_ASK FW_RUN="$r" bash "$BIN/lanecheck" done 4155 --handed-to-owner "$override_card" 2>&1); grc=$?
mv "$T/owner-ask.saved" "$owner_ask_bin"
if [ "$grc" = 2 ] && printf '%s' "$out" | grep -qF "owner-ask not found at $owner_ask_bin; --handed-to-owner needs the Mac's owner-ask" \
  && ! printf '%s' "$out" | grep -qF 'is not open' \
  && [ "$(wc -l < "$r/roster-done" | tr -d ' ')" = 0 ]; then
  ok handed-to-owner-missing-owner-ask-names-path
else
  fail "handed-to-owner-missing-owner-ask-names-path (rc=$grc) $out"
fi

# An answered card is absent from owner-ask list, so it cannot authorize the
# open-PR waiver.
r=$(newrun 7b); lane "$r" 4155 fiber-4155-build abc; grant "$r" 4155
: > "$T/owner-ask-list"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 4155 --handed-to-owner 0610-fly-1234 2>&1); grc=$?
if [ "$grc" = 2 ] && printf '%s' "$out" | grep -qF 'card 0610-fly-1234 is not open' \
  && [ "$(wc -l < "$r/roster-done" | tr -d ' ')" = 0 ]; then
  ok handed-to-owner-closed-card-refuses
else
  fail "handed-to-owner-closed-card-refuses (rc=$grc) $out"
fi

# An open card that names neither the PR nor ticket also refuses.
r=$(newrun 7c); lane "$r" 4155 fiber-4155-build abc
write_owner_card 0610-fly-5678 'Review lane' 'Review the current changes.'
printf '0610-fly-5678 flywheel Review lane\n' > "$T/owner-ask-list"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 4155 --handed-to-owner 0610-fly-5678 2>&1); grc=$?
if [ "$grc" = 2 ] && printf '%s' "$out" | grep -qF 'title/body does not name open PR(s) 4170 or ticket #4155' \
  && [ "$(wc -l < "$r/roster-done" | tr -d ' ')" = 0 ]; then
  ok handed-to-owner-unrelated-card-refuses
else
  fail "handed-to-owner-unrelated-card-refuses (rc=$grc) $out"
fi

# Naming the ticket is an alternate card match.
r=$(newrun 7d); lane "$r" 4155 fiber-4155-build abc
write_owner_card 0610-fly-5679 'Take over #4155' 'The owner will review this ticket.'
printf '0610-fly-5679 flywheel Take over #4155\n' > "$T/owner-ask-list"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 4155 --handed-to-owner 0610-fly-5679 2>&1); grc=$?
if [ "$grc" = 0 ] && printf '%s' "$out" | grep -qF 'handed-to-owner 0610-fly-5679 PR #4170'; then
  ok handed-to-owner-ticket-card-accepted
else
  fail "handed-to-owner-ticket-card-accepted (rc=$grc) $out"
fi

# A valid owner card cannot waive the age guard.
r=$(newrun 7e); lane "$r" 4155 fiber-4155-build abc 1M
write_owner_card 0610-fly-5680 'Review PR #4170' 'Please merge PR #4170.'
printf '0610-fly-5680 flywheel Review PR #4170\n' > "$T/owner-ask-list"
out=$(FW_RUN=$r FW_DONE_MIN=1800 bash "$BIN/lanecheck" done 4155 --handed-to-owner 0610-fly-5680 2>&1); grc=$?
if [ "$grc" = 2 ] && printf '%s' "$out" | grep -q 'REFUSING to retire 4155 — its newest roster entry' \
  && [ "$(wc -l < "$r/roster-done" | tr -d ' ')" = 0 ]; then
  ok handed-to-owner-does-not-waive-age-guard
else
  fail "handed-to-owner-does-not-waive-age-guard (rc=$grc) $out"
fi

# #4042's false refusal: a PR whose body merely mentioned the number used to
# block it. The guard matches the head branch, so another ticket's branch is
# not this ticket's PR.
r=$(newrun 8); lane "$r" 4042 fiber-4042-build def
printf '4116 feat/3890-keeper-shell-path\n' > "$T/prs"
out=$(FW_RUN=$r bash "$BIN/lanecheck" done 4042 2>&1); grc=$?
if [ "$grc" = 0 ] && ! printf '%s' "$out" | grep -q REFUSING; then ok pr-guard-ignores-other-branch; else fail "pr-guard-ignores-other-branch (rc=$grc) $out"; fi

# A gh failure fails open, and says so, so the log cannot be read as a pass.
r=$(newrun 9); lane "$r" 4100 fiber-4100-build ghi
: > "$T/prs"
out=$(FW_RUN=$r GH_BOOM=1 bash "$BIN/lanecheck" done 4100 2>&1); grc=$?
if [ "$grc" = 0 ] && printf '%s' "$out" | grep -q 'open-PR guard did not run for 4100'; then ok pr-guard-fails-open-and-says-so; else fail "pr-guard-fails-open-and-says-so (rc=$grc) $out"; fi

# --- usage and the scan path -------------------------------------------------
out=$(FW_RUN=$T/run9 bash "$BIN/lanecheck" done 2>&1); grc=$?
if [ "$grc" = 2 ] && printf '%s' "$out" | grep -q '^usage: lanecheck done'; then ok done-needs-a-ticket; else fail "done-needs-a-ticket (rc=$grc)"; fi

r=$T/norost; mkdir -p "$r"
out=$(FW_RUN=$r bash "$BIN/lanecheck" 2>&1); grc=$?
if [ "$grc" = 0 ] && printf '%s' "$out" | grep -q "no roster at $r/roster"; then ok scan-no-roster-exits-0; else fail "scan-no-roster-exits-0 (rc=$grc) $out"; fi

# The sampler guard: a scan with no liveness log says so, and the knob the
# sandbox uses to silence it actually silences it.
r=$(newrun A); lane "$r" 4161 fiber-4161-plan jkl
out=$(FW_RUN=$r bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q 'SAMPLER ABSENT'; then ok scan-warns-sampler-absent; else fail "scan-warns-sampler-absent ($out)"; fi
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if ! printf '%s' "$out" | grep -q 'SAMPLER'; then ok scan-sampler-check-skippable; else fail "scan-sampler-check-skippable ($out)"; fi

# A retired ticket leaves the scan's view; a live one stays in it.
# LIVE needs an active turn, not just `status: running`: a muse lane with no
# activeTurnId has stopped and nothing wakes it (the #4097 stall), which is why
# the fixture carries one and the next case drops it.
r=$(newrun B); lane "$r" 4161 fiber-4161-plan jkl; lane "$r" 4099 fiber-4099-build mno
printf '{"ok":true,"sessions":[{"id":"jkl","status":"running","activeTurnId":"t1","turnCount":3}]}' > "$T/dsess"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^LIVE 4161' && printf '%s' "$out" | grep -qE '^(STALL|MISSING) 4099'; then
  ok scan-separates-live-from-stalled
else
  fail "scan-separates-live-from-stalled ($out)"
fi
FW_RUN=$r FW_DONE_FORCE=1 bash "$BIN/lanecheck" done 4099 >/dev/null 2>&1
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if ! printf '%s' "$out" | grep -q ' 4099 '; then ok scan-drops-retired-ticket; else fail "scan-drops-retired-ticket ($out)"; fi

# The #4097 stall: `running` with no active turn is a lane nothing will wake.
# `status` alone cannot tell it from a working lane, so LIVE must not cover it.
r=$(newrun C); lane "$r" 4097 fiber-4097-build pqr
printf '{"ok":true,"sessions":[{"id":"pqr","status":"running","turnCount":4}]}' > "$T/dsess"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 4097' && printf '%s' "$out" | grep -q 'no active turn'; then
  ok scan-calls-a-turnless-running-lane-a-stall
else
  fail "scan-calls-a-turnless-running-lane-a-stall ($out)"
fi

# --- a report written in place, with no inbox message -------------------------
# The #4040 stall on 2026-11-06. A mac delegate lane has no inbox to send to, so
# it wrote run/fiber-4040-report.md and sent nothing. `reported` scanned only the
# two inbox directories, so the row could not tell a landed report from no report
# and printed the bare remedy "retire it if its report landed" either way. It had
# landed: REVIEWED, CI green, PR #4298 ready to ship. Nine hours.
#
# Note the status line here asks for nothing -- no BLOCKED, no question mark --
# which is why NEEDS-RULING cannot cover this and why the fix had to reach the
# STALL branch itself. A case seeded with a BLOCKED report passes without the
# fix and would have proved nothing.
r=$(newrun R2); lane "$r" 4040 fiber-4040-build rpt1
printf '{"ok":true,"sessions":[{"id":"rpt1","status":"completed","turnCount":2}]}' > "$T/dsess"
: > "$T/pending"; : > "$T/asking"
printf 'ASKING: nothing\n\nSTATUS: REVIEWED — PR #4298 ready to mark ready and ship\n' \
  > "$r/fiber-4040-report.md"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 4040' \
   && printf '%s' "$out" | grep -q 'fiber-4040-report.md' \
   && printf '%s' "$out" | grep -q 'STATUS: REVIEWED'; then
  ok a-report-written-in-place-is-named-on-the-stall-row
else
  fail "a-report-written-in-place-is-named-on-the-stall-row ($out)"
fi
rm -f "$r/fiber-4040-report.md"

# --- the named report has to be a path that opens -----------------------------
# The row is a command I act on. On 2026-11-06 #4318's row named
# box-prep-4318-....md and `cat` on it failed from the flywheel dir, because the
# file was under run/inbox/ and only the basename was printed. So this case does
# not check for a name: it extracts whatever path the row names and opens it.
# A basename-only row fails here even though it reads perfectly.
r=$(newrun R3); mkdir -p "$r/inbox"; lane "$r" 4318 fiber-4318-plan rpt2
printf '{"ok":true,"sessions":[{"id":"rpt2","status":"completed","turnCount":1}]}' > "$T/dsess"
: > "$T/pending"; : > "$T/asking"
printf 'STATUS: PREPPED — notes written\n' > "$r/inbox/box-prep-4318-20261106T000000Z-1-2.md"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
named=$(printf '%s' "$out" | grep -o '/[^ ]*box-prep-4318[^ ]*\.md' | head -1)
if [ -n "$named" ] && [ -f "$named" ]; then
  ok the-report-path-on-the-row-opens
else
  fail "the-report-path-on-the-row-opens (named='$named') ($out)"
fi

# --- an ask inside a non-asking status line ------------------------------------
# #3635 on 2026-11-06. The report's last STATUS line carried both the verdict
# and two asks, and none of BLOCKED/READY/AWAIT/`?` is in it -- REVIEWED is not
# READY. So wants was false, the row read as a finished lane, and both asks sat
# unread for 2.5 hours. The status line below is that one, shortened.
r=$(newrun R4); mkdir -p "$r/inbox"; lane "$r" 3635 fiber-3635-build rpt3
printf '{"ok":true,"sessions":[{"id":"rpt3","status":"completed","turnCount":4}]}' > "$T/dsess"
: > "$T/pending"; : > "$T/asking"
printf 'STATUS: REVIEWED head=a2a32bb last=FIX-OK PR #4308. ASKING: merge-term call on the new sandbox notice code, and a fence for the crates/hub follow-up\n' \
  > "$r/inbox/box-box-3635-20261106T144919Z-1-2.md"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^NEEDS-RULING 3635' \
   && printf '%s' "$out" | grep -q 'do not retire it'; then
  ok an-ask-inside-a-verdict-status-line-still-needs-a-ruling
else
  fail "an-ask-inside-a-verdict-status-line-still-needs-a-ruling ($out)"
fi

# The content after the colon is what retires an ask, not the keyword. A lane
# that writes `ASKING: nothing` beside a finished verdict is done, and must not
# be dragged back into NEEDS-RULING by the word alone -- which is what a fix
# keying on the keyword would do, and what the #4040 case above would not catch
# on its own, since its verdict line is the one picked by precedence.
printf 'ASKING: nothing\n\nSTATUS: REVIEWED PR #4298 shipped\n' \
  > "$r/inbox/box-box-3635-20261106T144919Z-1-2.md"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 3635'; then
  ok asking-nothing-is-not-an-ask
else
  fail "asking-nothing-is-not-an-ask ($out)"
fi

# --- the abandoned wait --------------------------------------------------------
# The two causes of a turnless lane want opposite remedies, so the report has to
# separate them. Four lanes did this on 2026-11-04: dispatched long work, wrote
# that a watch would wake them, ended the turn, and nothing woke them.
r=$(newrun D); lane "$r" 4099 fiber-4099-build stu
printf '{"ok":true,"sessions":[{"id":"stu","status":"running","turnCount":9}]}' > "$T/dsess"
printf '/bin/bash /home/a/.agents/bin/tkt-build /srv/lanes/run/fiber-4099.state --phase build\n' > "$T/pending"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^ABANDONED 4099' \
   && printf '%s' "$out" | grep -q 'work is still running for it' \
   && printf '%s' "$out" | grep -q 'tkt-build'; then
  ok turnless-lane-with-pending-work-is-abandoned
else
  fail "turnless-lane-with-pending-work-is-abandoned ($out)"
fi

# The same lane with nothing running is an ordinary stall, and the line says so
# rather than sending the reader to look for work that is not there.
: > "$T/pending"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 4099' \
   && printf '%s' "$out" | grep -q 'no work running for it'; then
  ok turnless-lane-with-no-pending-work-is-a-stall
else
  fail "turnless-lane-with-no-pending-work-is-a-stall ($out)"
fi

# Another ticket's pending work is not this one's. A state-file number is the
# key, not any other number on the command line.
printf '/bin/bash /home/a/.agents/bin/tkt-build /srv/lanes/run/fiber-4152.state\n' > "$T/pending"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 4099'; then
  ok pending-work-is-matched-to-its-own-ticket
else
  fail "pending-work-is-matched-to-its-own-ticket ($out)"
fi

# A part-ticket lane's state file carries a -p<n> suffix (fiber-4099-p2.state).
# Its pending work still belongs to ticket 4099, so the lane is not a STALL.
printf '/bin/bash /home/a/.agents/bin/tkt-build /srv/lanes/run/fiber-4099-p2.state --phase build\n' > "$T/pending"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^ABANDONED 4099' \
   && printf '%s' "$out" | grep -q 'work is still running for it'; then
  ok part-ticket-state-file-counts-as-pending
else
  fail "part-ticket-state-file-counts-as-pending ($out)"
fi

# A failed probe leaves the pending map empty, and an absent probe is not
# evidence that nothing is running: the lane still gets a line, never silence.
rm -f "$T/pending"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -qE '^(STALL|ABANDONED) 4099'; then
  ok absent-pending-probe-still-reports-the-lane
else
  fail "absent-pending-probe-still-reports-the-lane ($out)"
fi
: > "$T/pending"

# A number in a command's note is not a ticket key. The process belongs to
# 4444 because its argv names fiber-4444.state; the heredoc note's 3897 is just
# text and must not make that stopped lane look like it has work.
r=$(newrun pending-state-key); lane "$r" 4444 fiber-4444-build pnd44444; lane "$r" 3897 fiber-3897-build pnd38977
printf '{"ok":true,"sessions":[{"id":"pnd44444","status":"running","turnCount":9},{"id":"pnd38977","status":"running","turnCount":9}]}' > "$T/dsess"
printf 'tkt-build run/fiber-4444.state ... <<EOF note about fiber-3897 EOF\n' > "$T/pending"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^ABANDONED 4444' \
   && ! printf '%s' "$out" | grep -q '^ABANDONED 3897' \
   && printf '%s' "$out" | grep -q '^STALL 3897'; then
  ok pending-work-is-keyed-by-state-file-not-arbitrary-argv-numbers
else
  fail "pending-work-is-keyed-by-state-file-not-arbitrary-argv-numbers ($out)"
fi
: > "$T/pending"

# --- a job waiting on an answer ------------------------------------------------
# #4099 on 2026-11-04: turnless lane, no process, and a build job sitting in
# NEEDS_CONTEXT with a question nobody had answered. The STALL line told the
# reader to retire it or wake it, and the lane needed neither -- it needed a
# ruling and a resume. The four cases above all seed a process, which is the one
# shape that cannot show this.
r=$(newrun E); lane "$r" 4099 fiber-4099-build stu
printf '{"ok":true,"sessions":[{"id":"stu","status":"running","turnCount":4}]}' > "$T/dsess"
: > "$T/pending"
printf '4099\t7545a3bc-dab9-4c57-8c7c-3f36673c78f4\n' > "$T/asking"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^NEEDS-ANSWER 4099' \
   && printf '%s' "$out" | grep -q 'delegate resume 7545a3bc' \
   && ! printf '%s' "$out" | grep -q '^STALL 4099'; then
  ok turnless-lane-with-a-needs-context-job-needs-an-answer
else
  fail "turnless-lane-with-a-needs-context-job-needs-an-answer ($out)"
fi

# A question beats a running process in the report: resume is the remedy, and an
# ABANDONED line would send the reader to re-attach to work that is not what is
# stuck.
printf '/bin/bash /home/a/.agents/bin/tkt-build /srv/lanes/run/fiber-4099.state\n' > "$T/pending"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^NEEDS-ANSWER 4099'; then
  ok a-needs-context-job-outranks-a-running-process
else
  fail "a-needs-context-job-outranks-a-running-process ($out)"
fi

# Another ticket's question is not this one's, and a job the probe could not key
# to a ticket ("?") is dropped rather than attached to whatever lane sorts first.
printf '4152\tjob-a\n?\tjob-b\n' > "$T/asking"
: > "$T/pending"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 4099' \
   && ! printf '%s' "$out" | grep -q 'NEEDS-ANSWER'; then
  ok a-needs-context-job-is-matched-to-its-own-ticket
else
  fail "a-needs-context-job-is-matched-to-its-own-ticket ($out)"
fi

# An unreadable probe is not evidence that nobody is waiting: the lane still
# gets a line.
rm -f "$T/asking"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -qE '^(STALL|ABANDONED|NEEDS-ANSWER) 4099'; then
  ok absent-asking-probe-still-reports-the-lane
else
  fail "absent-asking-probe-still-reports-the-lane ($out)"
fi
: > "$T/asking"

# A job record never expires, so a question from a previous lane for the same
# ticket outlives it. Job written 3h before a lane launched 40m ago: that is a
# retired round's question, and pointing the orchestrator at it would send them
# to resume a dead job.
r=$(newrun F); lane "$r" 3890 fiber-3890-build vwx 40M
printf '{"ok":true,"sessions":[{"id":"vwx","status":"running","turnCount":2}]}' > "$T/dsess"
: > "$T/pending"
printf '3890\told-job\t%s\n' "$(( $(date +%s) - 10800 ))" > "$T/asking"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 3890' \
   && ! printf '%s' "$out" | grep -q 'old-job'; then
  ok a-question-older-than-the-lane-is-stale
else
  fail "a-question-older-than-the-lane-is-stale ($out)"
fi

# The same lane with a question asked after it launched: that one is live.
printf '3890\tnew-job\t%s\n' "$(date +%s)" > "$T/asking"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^NEEDS-ANSWER 3890' \
   && printf '%s' "$out" | grep -q 'new-job'; then
  ok a-question-newer-than-the-lane-counts
else
  fail "a-question-newer-than-the-lane-counts ($out)"
fi

# Two questions on one ticket: the newest is the live one.
printf '3890\told-job\t%s\n3890\tnew-job\t%s\n' "$(( $(date +%s) - 10800 ))" "$(date +%s)" > "$T/asking"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q 'new-job' && ! printf '%s' "$out" | grep -q 'old-job'; then
  ok the-newest-question-for-a-ticket-wins
else
  fail "the-newest-question-for-a-ticket-wins ($out)"
fi

# A question with no stamp fails open: reporting one that turns out stale costs
# a `delegate status`, swallowing a live one costs the lane its round.
printf '3890\tno-stamp\n' > "$T/asking"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^NEEDS-ANSWER 3890'; then
  ok a-question-with-no-stamp-is-still-reported
else
  fail "a-question-with-no-stamp-is-still-reported ($out)"
fi
: > "$T/asking"

# --- a lane parked on an external event ----------------------------------------
# #4099 again, at 11:25Z on 2026-11-04 and for a different reason: it had
# finished its leg, reported, and was waiting for PR #4153 to merge. No process,
# no question, so both probes were blind and STALL offered two wrong remedies
# for the second time in one morning -- retiring it loses the remaining leg,
# waking it makes it re-read its context to discover it is still blocked.
# Every case above seeds either a process or a question, which is why neither
# could show this.
r=$(newrun F); lane "$r" 4099 fiber-4099-build vwx
printf '{"ok":true,"sessions":[{"id":"vwx","status":"running","turnCount":5}]}' > "$T/dsess"
: > "$T/pending"; : > "$T/asking"
printf 'pr 4153 to merge, for the main.rs registration leg\n' > "$r/fiber-4099-waiting-on.md"
printf '4153 ci/3899-nightly\n' > "$T/prs"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^WAITING 4099' \
   && printf '%s' "$out" | grep -q 'pr 4153 to merge' \
   && ! printf '%s' "$out" | grep -q '^STALL 4099'; then
  ok a-parked-lane-waiting-on-an-open-pr-is-not-a-stall
else
  fail "a-parked-lane-waiting-on-an-open-pr-is-not-a-stall ($out)"
fi

# The wait ends when the PR leaves the open list, merged or closed: either way
# nothing more will happen to it, so the lane is the thing holding up the leg.
: > "$T/prs"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^WAKE 4099' \
   && printf '%s' "$out" | grep -q 'delegate session send vwx' \
   && printf '%s' "$out" | grep -q 'fiber-4099-waiting-on.md'; then
  ok a-parked-lane-whose-pr-closed-is-ready-to-wake
else
  fail "a-parked-lane-whose-pr-closed-is-ready-to-wake ($out)"
fi

# The fail-safe that cost the NEEDS_CONTEXT bound two tries to get right: a
# fetch that failed must not read as "nothing is open". Without the marker file
# a network blip wakes every parked lane at once.
out=$(GH_BOOM=1 FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^WAITING 4099' \
   && printf '%s' "$out" | grep -q 'could not be fetched' \
   && ! printf '%s' "$out" | grep -q '^WAKE 4099'; then
  ok a-failed-pr-fetch-never-resolves-a-wait-as-over
else
  fail "a-failed-pr-fetch-never-resolves-a-wait-as-over ($out)"
fi

# A condition this script cannot resolve is still worth reporting as a wait:
# the point is to stop the reader acting on a wrong remedy, not to adjudicate
# every condition a lane can be parked on.
printf 'switchyard#1009 to land\n' > "$r/fiber-4099-waiting-on.md"
: > "$T/prs"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^WAITING 4099' \
   && printf '%s' "$out" | grep -q 'switchyard#1009 to land' \
   && ! printf '%s' "$out" | grep -q '^WAKE 4099'; then
  ok an-unresolvable-wait-condition-still-suppresses-the-stall
else
  fail "an-unresolvable-wait-condition-still-suppresses-the-stall ($out)"
fi

# run/ files outlive the lanes that wrote them, so a flag from a previous lane
# for this ticket must not silence a real stall -- the same bound, and the same
# reason, as the NEEDS_CONTEXT staleness check.
touch -t 202601010000 "$r/fiber-4099-waiting-on.md"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 4099' \
   && ! printf '%s' "$out" | grep -qE '^(WAITING|WAKE) 4099'; then
  ok a-wait-flag-older-than-the-lane-is-stale
else
  fail "a-wait-flag-older-than-the-lane-is-stale ($out)"
fi

# An empty flag file says nothing, so it must not be read as a wait.
: > "$r/fiber-4099-waiting-on.md"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 4099'; then
  ok an-empty-wait-flag-is-not-a-wait
else
  fail "an-empty-wait-flag-is-not-a-wait ($out)"
fi

# Precedence: the park flag, then NEEDS-ANSWER, then ABANDONED. The flag is
# the orchestrator's own declaration that the lane is not to be acted on —
# #4161 was parked on 2026-11-04 and went on printing NEEDS-ANSWER, nudging me
# to do the thing I had just deferred. This reverses cycle 13's
# a-running-process-outranks-a-wait-flag, whose reason was that running work
# means the lane is not actually parked. It does not: the work writes its
# verdict to the ticket's state file and the lane reads it on waking, which is
# what parking is for. Nothing is lost only because the park line names the
# running work, which the next case pins.
printf 'the owner to rule on the fence\n' > "$r/fiber-4099-waiting-on.md"
printf '/bin/bash /home/a/.agents/bin/tkt-build /srv/lanes/run/fiber-4099.state\n' > "$T/pending"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^WAITING 4099' \
   && ! printf '%s' "$out" | grep -q '^ABANDONED 4099'; then
  ok a-wait-flag-outranks-a-running-process
else
  fail "a-wait-flag-outranks-a-running-process ($out)"
fi
if printf '%s' "$out" | grep -q 'work is still running for it: /bin/bash'; then
  ok a-parked-lane-with-running-work-names-that-work
else
  fail "a-parked-lane-with-running-work-names-that-work ($out)"
fi
: > "$T/pending"
printf 'the owner to rule on the fence\n' > "$r/fiber-4099-waiting-on.md"
printf '4099\tjob-live\n' > "$T/asking"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^WAITING 4099' \
   && ! printf '%s' "$out" | grep -q '^NEEDS-ANSWER 4099'; then
  ok a-wait-flag-outranks-a-live-question
else
  fail "a-wait-flag-outranks-a-live-question ($out)"
fi
# Nothing is lost by that order only if the park line carries the question and
# the command that answers it. A park printing `delegate session send` would
# give the lane a turn with its question still open.
if printf '%s' "$out" | grep -q 'job-live is still NEEDS_CONTEXT' \
   && printf '%s' "$out" | grep -q 'delegate resume job-live -' \
   && ! printf '%s' "$out" | grep -q 'delegate session send'; then
  ok a-parked-lane-with-a-question-names-it-and-the-resume-command
else
  fail "a-parked-lane-with-a-question-names-it-and-the-resume-command ($out)"
fi
rm -f "$r/fiber-4099-waiting-on.md"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^NEEDS-ANSWER 4099'; then
  ok a-live-question-with-no-flag-is-still-needs-answer
else
  fail "a-live-question-with-no-flag-is-still-needs-answer ($out)"
fi
: > "$T/asking"
printf 'pr 4153 to merge\n' > "$r/fiber-4099-waiting-on.md"

# The flag's first line is prose, and on its first real run #4099's ran long
# enough to push the remedy off the end of the terminal. The remedy is the part
# the reader acts on, so it must survive however verbose the condition.
printf 'pr 4153 to merge, then the main.rs registration leg (mod lines, 2 arms, Commands docs), trio re-run, gate, draft PR with --label mutants, and a partridge in a pear tree\n' > "$r/fiber-4099-waiting-on.md"
: > "$T/prs"; printf '4153 ci/x\n' > "$T/prs"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^WAITING 4099' \
   && printf '%s' "$out" | grep -q 'delegate session send' \
   && printf '%s' "$out" | grep -q 'and remove' \
   && ! printf '%s' "$out" | grep -q 'partridge'; then
  ok a-long-wait-condition-is-capped-so-the-remedy-survives
else
  fail "a-long-wait-condition-is-capped-so-the-remedy-survives ($out)"
fi

# A muse lane's session lives on the box, so a bare `delegate session send <id>`
# printed here fails from the orchestrator's session with "no such session" —
# which is what happened waking #4099 on 2026-11-04. The printed remedy has to
# be the command that runs, host and stdin redirect included, or the reader
# pays a failed command and a re-derivation.
out=$(FW_RUN=$r FW_BOX_HOST=test-box.local FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q 'ssh test-box.local' \
   && printf '%s' "$out" | grep -q 'delegate session send' \
   && printf '%s' "$out" | grep -q '< <file>'; then
  ok a-muse-wake-command-names-the-box-and-the-stdin-redirect
else
  fail "a-muse-wake-command-names-the-box-and-the-stdin-redirect ($out)"
fi
# Same for the resume form, which a parked lane with an open question prints.
printf '4099\tjob-live\n' > "$T/asking"
out=$(FW_RUN=$r FW_BOX_HOST=test-box.local FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q 'ssh test-box.local' \
   && printf '%s' "$out" | grep -q 'delegate resume job-live -' \
   && printf '%s' "$out" | grep -q '< <file>'; then
  ok a-muse-resume-command-names-the-box-and-the-stdin-redirect
else
  fail "a-muse-resume-command-names-the-box-and-the-stdin-redirect ($out)"
fi
: > "$T/asking"

# A lane with no flag is unaffected: the probe must add a state, not reinterpret
# the lanes that were already reported correctly.
rm -f "$r/fiber-4099-waiting-on.md"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 4099' \
   && ! printf '%s' "$out" | grep -qE '^(WAITING|WAKE)'; then
  ok no-wait-flag-leaves-the-lane-reported-as-before
else
  fail "no-wait-flag-leaves-the-lane-reported-as-before ($out)"
fi

# --- a lane waiting on a ruling ------------------------------------------------
# The fourth waiting state. #4152 and #3899 both sat this way: a muse lane
# reports `STATUS: BLOCKED` through the inbox, the report is drained to read/,
# and the lane ends its turn. No process, no NEEDS_CONTEXT job, and no flag --
# it parked itself, so I never wrote one -- which is why every probe above is
# blind to it and STALL told the reader to retire a lane that had asked a
# question. Losing the question is the expensive failure, so these cases seed
# nothing else.
rep() { # rep <run> <ticket> <status line> [age in minutes, default 10]
  mkdir -p "$1/inbox/read"
  f=$1/inbox/read/box-box-$2-20261104T120000Z-1-1.md
  printf '# %s report\n\n%s\n' "$2" "$3" > "$f"
  age_file "$f" "${4:-10}"
}
ruling() { # ruling <run> <ticket> <n> [age in minutes, default 1]
  mkdir -p "$1/rulings"
  f=$1/rulings/ruling-$2-$3.md
  printf 'RULING-%s-%s\n' "$2" "$3" > "$f"
  age_file "$f" "${4:-1}"
}

# At the plan-to-build handoff, both sessions use one ticket state file. The
# pending tkt-build belongs to the newer live build session, not the plan that
# has already reported PLANNED and ended its turn.
r=$(newrun 1518); lane "$r" 1518 fiber-1518-plan plan1518 3H; lane "$r" 1518 fiber-1518-build build1518 1M
printf '{"ok":true,"sessions":[{"id":"plan1518","status":"completed","turnCount":2},{"id":"build1518","status":"running","activeTurnId":"t1","turnCount":1}]}' > "$T/dsess"
printf '/bin/bash /home/a/.agents/bin/tkt-build /srv/lanes/run/fiber-1518.state --phase build\n' > "$T/pending"
rep "$r" 1518 'STATUS: PLANNED — plan handed off to build.'
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 1518 muse fiber-1518-plan' \
   && printf '%s' "$out" | grep -q 'STATUS: PLANNED' \
   && printf '%s' "$out" | grep -q 'retire it if its report landed' \
   && printf '%s' "$out" | grep -q 'newer roster entry muse/fiber-1518-build' \
   && printf '%s' "$out" | grep -q 'shared-state pending work is credited to that newer session: /bin/bash.*tkt-build' \
   && printf '%s' "$out" | grep -q '^LIVE 1518 muse fiber-1518-build' \
   && ! printf '%s' "$out" | grep -q '^ABANDONED 1518 muse fiber-1518-plan'; then
  ok planned-session-is-retirable-after-build-handoff
else
  fail "planned-session-is-retirable-after-build-handoff ($out)"
fi
: > "$T/pending"

# A retired newer build entry cannot own pending work on the shared state file.
r=$(newrun 1519); lane "$r" 1519 fiber-1519-plan plan1519 3H; lane "$r" 1519 fiber-1519-build build1519 1M
printf '%s\t1519\tfiber-1519-build\n' "$(future 1)" > "$r/roster-done"
printf '{"ok":true,"sessions":[{"id":"plan1519","status":"completed","turnCount":2}]}' > "$T/dsess"
printf '/bin/bash /home/a/.agents/bin/tkt-build /srv/lanes/run/fiber-1519.state --phase build\n' > "$T/pending"
rep "$r" 1519 'STATUS: PLANNED — plan handed off to build.'
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^ABANDONED 1519 muse fiber-1519-plan' \
   && ! printf '%s' "$out" | grep -q '^STALL 1519 muse fiber-1519-plan' \
   && ! printf '%s' "$out" | grep -q 'newer roster entry muse/fiber-1519-build'; then
  ok retired-newer-roster-entry-does-not-own-shared-state-work
else
  fail "retired-newer-roster-entry-does-not-own-shared-state-work ($out)"
fi
: > "$T/pending"

r=$(newrun G); lane "$r" 4152 fiber-4152-build yz1
printf '{"ok":true,"sessions":[{"id":"yz1","status":"running","turnCount":7}]}' > "$T/dsess"
: > "$T/pending"; : > "$T/asking"; : > "$T/prs"
rep "$r" 4152 'STATUS: BLOCKED awaiting flywheel all-clear before Task 3.'
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^NEEDS-RULING 4152' \
   && printf '%s' "$out" | grep -q 'awaiting flywheel all-clear' \
   && printf '%s' "$out" | grep -q 'ruled.sh 4152' \
   && ! printf '%s' "$out" | grep -q '^STALL 4152'; then
  ok a-lane-that-reported-blocked-and-stopped-is-waiting-on-a-ruling
else
  fail "a-lane-that-reported-blocked-and-stopped-is-waiting-on-a-ruling ($out)"
fi

# A planner QUESTIONS status is an open ruling request, not a completed plan.
rq=$(newrun GQ); lane "$rq" 4180 fiber-4180-plan qst1
printf '{"ok":true,"sessions":[{"id":"qst1","status":"running","turnCount":2}]}' > "$T/dsess"
: > "$T/pending"; : > "$T/asking"; : > "$T/prs"
rep "$rq" 4180 'STATUS: QUESTIONS — planner has open design choices.'
out=$(FW_RUN=$rq FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^NEEDS-RULING 4180' \
   && printf '%s' "$out" | grep -q 'open design choices' \
   && ! printf '%s' "$out" | grep -q '^STALL 4180'; then
  ok planner-questions-status-needs-a-ruling
else
  fail "planner-questions-status-needs-a-ruling ($out)"
fi
printf '{"ok":true,"sessions":[{"id":"yz1","status":"running","turnCount":7}]}' > "$T/dsess"

# A ruling newer than the report means the lane was answered and stopped
# anyway. That is a genuine stall with the opposite remedy, and the line has to
# say which it is or the reader re-rules a question already answered.
ruling "$r" 4152 2
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 4152' \
   && printf '%s' "$out" | grep -q 'a ruling already postdates it' \
   && ! printf '%s' "$out" | grep -q '^NEEDS-RULING 4152'; then
  ok a-ruling-newer-than-the-report-turns-the-wait-back-into-a-stall
else
  fail "a-ruling-newer-than-the-report-turns-the-wait-back-into-a-stall ($out)"
fi

# A ruling OLDER than the report is the trap this probe exists for: the lane
# was answered once, worked, and reported a new block. Testing for a ruling's
# presence instead of its time would call that answered.
rm -rf "$r/rulings"; ruling "$r" 4152 2 90
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^NEEDS-RULING 4152'; then
  ok a-ruling-older-than-the-report-does-not-answer-it
else
  fail "a-ruling-older-than-the-report-does-not-answer-it ($out)"
fi
rm -rf "$r/rulings"

# The trap the time test cannot see, and the one that actually cost a ruling:
# #4131 on 2026-11-05. Its report landed 16:04:33Z; RULING-4131-3 was archived
# 16:08:37Z, four minutes LATER, so the time rule called the lane answered --
# but that ruling answered an earlier question and said nothing about the
# harness defect the 16:04Z report raised. The new ask read as a settled lane
# and was found by accident, after it had held up PR #4205 and #3891 behind it.
#
# So a ruling's time cannot stand in for which report it answers. bin/ruled.sh
# stamps each archived ruling with the report it answered, and a newest report
# that no trailer names is unanswered however new the rulings are.
repat() { # repat <run> <ticket> <stamp> <status line> [age in minutes, default 10]
  mkdir -p "$1/inbox/read"
  f=$1/inbox/read/box-box-$2-$3-1-1.md
  printf '# %s report\n\n%s\n' "$2" "$4" > "$f"
  age_file "$f" "${5:-10}"
}
answering() { # answering <run> <ticket> <n> <report basename> [age in minutes, default 1]
  mkdir -p "$1/rulings"
  f=$1/rulings/ruling-$2-$3.md
  printf 'RULING-%s-%s\n\n<!-- answers-report: %s -->\n' "$2" "$3" "$4" > "$f"
  age_file "$f" "${5:-1}"
}

rm -rf "$r/inbox" "$r/rulings"
repat "$r" 4152 20261105T160000Z 'STATUS: BLOCKED on the first question.' 40
repat "$r" 4152 20261105T170000Z 'STATUS: BLOCKED on a second, different question.' 10
answering "$r" 4152 3 box-box-4152-20261105T160000Z-1-1.md 1
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^NEEDS-RULING 4152' \
   && printf '%s' "$out" | grep -q 'second, different question' \
   && ! printf '%s' "$out" | grep -q '^STALL 4152'; then
  ok a-ruling-naming-an-older-report-does-not-answer-a-newer-one
else
  fail "a-ruling-naming-an-older-report-does-not-answer-a-newer-one ($out)"
fi

# The other half: a trailer that names the newest report does answer it, even
# though the file times are the same shape as the case above. Without this the
# fix could pass by calling every lane unanswered.
answering "$r" 4152 4 box-box-4152-20261105T170000Z-1-1.md 1
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 4152' \
   && ! printf '%s' "$out" | grep -q '^NEEDS-RULING 4152'; then
  ok a-ruling-naming-the-newest-report-answers-it
else
  fail "a-ruling-naming-the-newest-report-answers-it ($out)"
fi
rm -rf "$r/inbox" "$r/rulings"
rep "$r" 4152 'STATUS: BLOCKED awaiting flywheel all-clear before Task 3.'

# A report that asks for nothing is a finished lane, and retiring it is the
# right remedy: the probe must add a state, not turn every stopped lane into a
# question.
rm -rf "$r/inbox"; rep "$r" 4152 'STATUS: MERGED abc1234'
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 4152' \
   && ! printf '%s' "$out" | grep -q '^NEEDS-RULING' \
   && ! printf '%s' "$out" | grep -q 'already postdates'; then
  ok a-merged-report-is-a-retirement-not-a-ruling-request
else
  fail "a-merged-report-is-a-retirement-not-a-ruling-request ($out)"
fi

# Inbox files outlive the lanes that wrote them, like run/ files: a previous
# lane's report for this ticket must not read as this lane's question. Same
# bound, same reason, as the question and flag probes.
rm -rf "$r/inbox"; rep "$r" 4152 'STATUS: BLOCKED on the last round question' 400
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 4152' \
   && ! printf '%s' "$out" | grep -q '^NEEDS-RULING'; then
  ok a-report-older-than-the-lane-is-stale
else
  fail "a-report-older-than-the-lane-is-stale ($out)"
fi

# Precedence, both ways. Running work means the lane is not waiting on me, and
# a live NEEDS_CONTEXT job is a question with a different remedy -- `delegate
# resume`, not a ruling file.
rm -rf "$r/inbox"; rep "$r" 4152 'STATUS: BLOCKED on a ruling'
printf '/bin/bash /home/a/.agents/bin/tkt-build /srv/lanes/run/fiber-4152.state\n' > "$T/pending"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^ABANDONED 4152' \
   && ! printf '%s' "$out" | grep -q '^NEEDS-RULING'; then
  ok running-work-outranks-a-blocked-report
else
  fail "running-work-outranks-a-blocked-report ($out)"
fi
: > "$T/pending"
printf '4152\tjob-live\n' > "$T/asking"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^NEEDS-ANSWER 4152' \
   && ! printf '%s' "$out" | grep -q '^NEEDS-RULING'; then
  ok a-live-delegate-question-outranks-a-blocked-report
else
  fail "a-live-delegate-question-outranks-a-blocked-report ($out)"
fi
: > "$T/asking"

# A lane still taking turns is LIVE whatever its last report said: the probe
# reads a stopped lane's silence, not every lane's mail.
printf '{"ok":true,"sessions":[{"id":"yz1","status":"running","turnCount":7,"activeTurnId":"t9"}]}' > "$T/dsess"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^LIVE 4152' \
   && ! printf '%s' "$out" | grep -q '^NEEDS-RULING'; then
  ok a-working-lane-with-a-blocked-report-is-still-live
else
  fail "a-working-lane-with-a-blocked-report-is-still-live ($out)"
fi
printf '{"ok":true,"sessions":[{"id":"yz1","status":"running","turnCount":7}]}' > "$T/dsess"

# A wait flag still outranks a report: the flag names a condition the script
# can resolve, and the report cannot be re-answered until that condition does.
printf 'pr 4153 to merge\n' > "$r/fiber-4152-waiting-on.md"
printf '4153 ci/x\n' > "$T/prs"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^WAITING 4152' \
   && ! printf '%s' "$out" | grep -q '^NEEDS-RULING'; then
  ok a-wait-flag-outranks-a-blocked-report
else
  fail "a-wait-flag-outranks-a-blocked-report ($out)"
fi
rm -f "$r/fiber-4152-waiting-on.md"; : > "$T/prs"

# Before 2026-11-04 12:00Z rulings were delivered by hand and never archived,
# so an absent ruling for an older report is unknown, not unanswered. The line
# must carry that caveat or the reader rules a question twice.
# Its own run dir and its own lane: reusing the G block's left the roster
# holding yz1, and a roster lane whose session the fixture no longer lists
# reads MISSING or STALL, both of which outrank NEEDS-RULING, so the case
# asserted against a line it is not about.
r=$(newrun H); lane "$r" 4152 fiber-4152-old yz9
printf '{"ok":true,"sessions":[{"id":"yz9","status":"running","turnCount":2}]}' > "$T/dsess"
: > "$T/pending"; : > "$T/asking"; : > "$T/prs"
rep "$r" 4152 'STATUS: BLOCKED on a ruling'
# The branch needs a report newer than its lane and older than the archive
# cutoff. Pin the cutoff just after the report instead of dating the fixtures
# against the real 2026-11-04 12:00Z: with the cutoff fixed and the lane aged
# backwards from now, the window between them closed as real time passed and
# the case quietly started asserting on a different line.
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 FW_RULING_ARCHIVE_FROM=$(python3 -c 'import time; print(int(time.time()) + 60)') \
  bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^NEEDS-RULING 4152' \
   && printf '%s' "$out" | grep -q 'predates the ruling archive'; then
  ok a-pre-archive-report-carries-the-unknown-ruling-caveat
else
  fail "a-pre-archive-report-carries-the-unknown-ruling-caveat ($out)"
fi


# --- the snapshot race -------------------------------------------------------
# A lane launched after the liveness snapshots were taken cannot appear in
# them. On 2026-11-05 the sampler printed
# `MISSING 3895 muse fiber-3895-build ... launched 2026-11-05T15:07:06Z` from a
# sample that began at 15:07:00Z: the line carried its own refutation, and the
# remedy it offered (relaunch) would have started a second lane on one fence.
r=$(newrun 20)
printf '%s\t%s\tmuse\t%s\t%s\n' "$(future 1)" 4300 fiber-4300-build ccc33333 >> "$r/roster"
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^NEW 4300' \
   && ! printf '%s' "$out" | grep -q '^MISSING 4300' \
   && printf '%s' "$out" | grep -q '0 missing'; then
  ok a-lane-launched-after-the-snapshot-is-new-not-missing
else
  fail "a-lane-launched-after-the-snapshot-is-new-not-missing ($out)"
fi

# The other direction, which is the one the fix must not break: an absent lane
# that was launched before the snapshot is still MISSING, and still counted.
r=$(newrun 21); lane "$r" 4301 fiber-4301-build ddd44444
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^MISSING 4301' \
   && ! printf '%s' "$out" | grep -q '^NEW 4301' \
   && printf '%s' "$out" | grep -q '1 missing'; then
  ok an-absent-lane-older-than-the-snapshot-is-still-missing
else
  fail "an-absent-lane-older-than-the-snapshot-is-still-missing ($out)"
fi


# --- a ruling with no report -------------------------------------------------
# A ruling whose trailer names a report, for a ticket that has no report at all.
# On 2026-11-05 this crashed the whole board with `TypeError: 'NoneType' object
# is not subscriptable`: the answered-report comparison ran whenever a ruling
# named an answer, without checking the ticket had a report to compare against.
# The board is the capacity read that decides whether a lane launches, so a
# crash here stops the round -- worse than any wrong line it could print.
#
# Reports vanish while rulings persist: run-archive.sh sweeps inbox/read and
# run/rulings is never swept, so this pairing arrives on its own with time.
#
# Its own run dir and lane, per the H block: a reused roster puts a MISSING or
# STALL line in front of the branch under test.
r=$(newrun I); lane "$r" 4152 fiber-4152-noreport yz8
printf '{"ok":true,"sessions":[{"id":"yz8","status":"running","turnCount":2}]}' > "$T/dsess"
: > "$T/pending"; : > "$T/asking"; : > "$T/prs"
answering "$r" 4152 9 box-box-4152-20261105T160000Z-1-1.md 1
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1); lrc=$?
if [ "$lrc" != 2 ] && ! printf '%s' "$out" | grep -q 'Traceback\|NoneType' \
   && printf '%s' "$out" | grep -q 'roster entries'; then
  ok a-ruling-with-no-report-does-not-crash-the-board
else
  fail "a-ruling-with-no-report-does-not-crash-the-board (rc=$lrc) $out"
fi

# --- retirement prunes the lane's claims -------------------------------------
# Retiring the last lane for a ticket prunes claims alongside its fence records,
# so an open ticket does not keep paths held after its holder is gone.
# The stub records every call and serves RELEASE lines per holder from $T/fcheld,
# so a case can assert which holder shapes were tried, not merely that something
# was called.
cat > "$T/stub/file-claim" <<'EOF'
#!/bin/bash
if [ -n "${FC_BOOM:-}" ]; then echo "cannot push refs/claims: rejected" >&2; exit 2; fi
# `list` serves the same $FC_HELD table the release path reads, transposed into
# the real tool's column order (path first, holder second), so a case that
# `held`s a holder gets it in both views from one line of setup. It logs
# nothing: FC_LOG records release attempts, and a case that asserts "released
# nothing" counts lines in it.
if [ "${1:-}" = list ]; then
  awk -F'\t' 'NF >= 2 { printf "%s\t%s\tgrant\t0\t-\n", $2, $1 }' "$FC_HELD" 2>/dev/null
  exit 0
fi
lane=""
while [ $# -gt 0 ]; do case $1 in --lane) lane=$2; shift 2;; *) shift;; esac; done
printf '%s\n' "$lane" >> "$FC_LOG"
grep -F "$lane	" "$FC_HELD" 2>/dev/null | cut -f2 | while read -r p; do
  [ -n "$p" ] && printf 'RELEASE %s\n' "$p"
done
exit 0
EOF
chmod +x "$T/stub/file-claim"
held() { printf '%s\t%s\n' "$1" "$2" >> "$T/fcheld"; }   # held <holder> <path>

# A whole-ticket retirement releases the bare `fiber-<n>` holder.
r=$(newrun C1); lane "$r" 4275 fiber-4275-build h1; grant "$r" 4275
: > "$T/fclog"; : > "$T/fcheld"; held fiber-4275 crates/loop/src/x.rs
out=$(FW_RUN=$r FW_FILE_CLAIM=$T/stub/file-claim FC_LOG=$T/fclog FC_HELD=$T/fcheld \
  bash "$BIN/lanecheck" done 4275 2>&1)
if printf '%s' "$out" | grep -q 'claims pruned: fiber-4275 (1)' \
   && grep -qx 'fiber-4275' "$T/fclog"; then
  ok done-prunes-the-bare-holder
else
  fail "done-prunes-the-bare-holder ($out)"
fi

# ...and every session name on the roster, because a lane launched by phase
# claims as `fiber-<n>-plan` or `-build`. A fix that releases only the bare form
# leaves these behind, which is the half of #1313 that is mine; #4275's own
# claims were written under two phase names.
r=$(newrun C2); lane "$r" 4307 fiber-4307-plan h2; lane "$r" 4307 fiber-4307-build h3
grant "$r" 4307
: > "$T/fclog"; : > "$T/fcheld"
held fiber-4307-plan docs/ci.md; held fiber-4307-build crates/main/src/y.rs
out=$(FW_RUN=$r FW_FILE_CLAIM=$T/stub/file-claim FC_LOG=$T/fclog FC_HELD=$T/fcheld \
  bash "$BIN/lanecheck" done 4307 2>&1)
if printf '%s' "$out" | grep -q 'claims pruned: fiber-4307-plan (1)' \
   && printf '%s' "$out" | grep -q 'claims pruned: fiber-4307-build (1)'; then
  ok done-prunes-every-phase-holder
else
  fail "done-prunes-every-phase-holder ($out)"
fi

# A fence kept is a claim kept. The first of two sessions retiring must prune
# nothing, or the prune reopens the running build's files -- the exact defect
# the 2026-11-04 fence fix was written for, one level down.
r=$(newrun C3); lane "$r" 4089 fiber-4089-plan h4; lane "$r" 4089 fiber-4089-build h5
grant "$r" 4089
: > "$T/fclog"; : > "$T/fcheld"; held fiber-4089 crates/loop/src/z.rs
out=$(FW_RUN=$r FW_FILE_CLAIM=$T/stub/file-claim FC_LOG=$T/fclog FC_HELD=$T/fcheld \
  bash "$BIN/lanecheck" done 4089:fiber-4089-plan 2>&1)
if [ "$(grep -c '' "$T/fclog")" = 0 ] && printf '%s' "$out" | grep -q 'fence kept for #4089'; then
  ok fence-kept-releases-nothing
else
  fail "fence-kept-releases-nothing (log=$(cat "$T/fclog")) ($out)"
fi

# An old whole-ticket retirement cannot retire a session launched afterward.
# Finishing the older plan session must leave the newer build's fence and claim.
r=$(newrun C10)
printf '2019-12-31T00:00:00Z\t1543\tmuse\tfiber-1543-plan\tplan1543\n2020-01-02T00:00:00Z\t1543\tmuse\tfiber-1543-build\tbuild1543\n' > "$r/roster"
printf '2020-01-01T00:00:00Z\t1543\n' > "$r/roster-done"
grant "$r" 1543
: > "$T/fclog"; : > "$T/fcheld"; held fiber-1543 crates/loop/src/1543.rs
out=$(FW_RUN=$r FW_FILE_CLAIM=$T/stub/file-claim FC_LOG=$T/fclog FC_HELD=$T/fcheld \
  bash "$BIN/lanecheck" "done" 1543:fiber-1543-plan 2>&1)
if [ -e "$r/fiber-1543-fence-grant-20261104T0000Z.md" ] \
   && [ ! -e "$r/done/fiber-1543-fence-grant-20261104T0000Z.md" ] \
   && printf '%s' "$out" | grep -q 'already retired: #1543:fiber-1543-plan' \
   && [ "$(grep -c '' "$r/roster-done")" = 1 ] \
   && [ "$(grep -c '' "$T/fclog")" = 0 ] \
   && grep -q '^fiber-1543[[:space:]]' "$T/fcheld"; then
  ok old-ticket-retirement-no-op-keeps-new-session-claims
else
  fail "old-ticket-retirement-no-op-keeps-new-session-claims (log=$(cat "$T/fclog")) ($out)"
fi

# A failed release names the hand command and does not stop the retirement. The
# fence record still moves: a retirement that half-ran and said nothing is how
# the 17 claims went unnoticed in the first place.
r=$(newrun C4); lane "$r" 4162 fiber-4162-build h6; grant "$r" 4162
: > "$T/fclog"; : > "$T/fcheld"; held fiber-4162 crates/log/src/diag.rs
out=$(FW_RUN=$r FW_FILE_CLAIM=$T/stub/file-claim FC_LOG=$T/fclog FC_HELD=$T/fcheld \
  FC_BOOM=1 bash "$BIN/lanecheck" done 4162 2>&1)
if printf '%s' "$out" | grep -q 'CLAIMS NOT RELEASED for fiber-4162' \
   && printf '%s' "$out" | grep -q 'prune --lane fiber-4162' \
   && [ -e "$r/done/fiber-4162-fence-grant-20261104T0000Z.md" ]; then
  ok failed-prune-is-warned-and-retirement-continues
else
  fail "failed-prune-is-warned-and-retirement-continues ($out)"
fi

# A branch-shaped holder is NAMED, with its path count and a paste-ready
# command, and deliberately not released: a branch-shaped `--lane` is
# classifier-denied to an orchestrator session, so releasing it from here would
# be doing through a script what the session may not do directly. Before this,
# the retirement printed only the `fiber-<n>` release and said nothing, which is
# how `docs/4271-needs-plan-label` kept two paths after #4271 retired and how
# six paths across two closed tickets reached the owner's queue.
r=$(newrun C5); lane "$r" 4271 fiber-4271-build h7; grant "$r" 4271
: > "$T/fclog"; : > "$T/fcheld"
held fiber-4271 docs/ci.md
held docs/4271-needs-plan-label docs/agents/triage-labels.md
held docs/4271-needs-plan-label docs/workflow.md
out=$(FW_RUN=$r FW_FILE_CLAIM=$T/stub/file-claim FC_LOG=$T/fclog FC_HELD=$T/fcheld \
  bash "$BIN/lanecheck" done 4271 2>&1)
if printf '%s' "$out" | grep -q 'BRANCH-SHAPED CLAIMS LEFT for docs/4271-needs-plan-label (2 path(s))' \
   && printf '%s' "$out" | grep -q 'file-claim release --lane docs/4271-needs-plan-label' \
   && ! grep -qx 'docs/4271-needs-plan-label' "$T/fclog"; then
  ok branch-shaped-claims-are-named-not-released
else
  fail "branch-shaped-claims-are-named-not-released (log=$(cat "$T/fclog")) ($out)"
fi

# When the flywheel itself is the Box, the remedy must be a local command,
# not an ssh hop back to the same host.
r=$(newrun C5L); lane "$r" 4271 fiber-4271-build h12; grant "$r" 4271
: > "$T/fclog"; : > "$T/fcheld"
held fiber-4271 docs/ci.md
held docs/4271-needs-plan-label docs/agents/triage-labels.md
out=$(FW_RUN=$r FW_LOCAL_BOX=1 FW_FILE_CLAIM=$T/stub/file-claim \
  FC_LOG=$T/fclog FC_HELD=$T/fcheld bash "$BIN/lanecheck" done 4271 2>&1)
if printf '%s' "$out" | grep -Fq "PATH=\$HOME/.agents/bin:\$PATH file-claim release --lane docs/4271-needs-plan-label" \
   && ! printf '%s' "$out" | grep -q 'ssh roundhouse-7010-plus-1.local' \
   && ! grep -qx 'docs/4271-needs-plan-label' "$T/fclog"; then
  ok local-box-claim-remedy-does-not-ssh-to-itself
else
  fail "local-box-claim-remedy-does-not-ssh-to-itself (log=$(cat "$T/fclog")) ($out)"
fi

# The scoping that makes the report safe to act on: another ticket's branch
# holder is not named. A report that listed every branch-shaped claim on the
# repo would hand the owner a command releasing a LIVE lane's files -- #4162 and
# #4250 both hold 35 and 12 paths under branch names while their lanes run.
r=$(newrun C6); lane "$r" 4318 fiber-4318-build h8; grant "$r" 4318
: > "$T/fclog"; : > "$T/fcheld"
held tests/4318-terminal-resume-list crates/main/tests/terminal.rs
held contract/4162-kind-private crates/contract/src/envelope.rs
out=$(FW_RUN=$r FW_FILE_CLAIM=$T/stub/file-claim FC_LOG=$T/fclog FC_HELD=$T/fcheld \
  bash "$BIN/lanecheck" done 4318 2>&1)
if printf '%s' "$out" | grep -q 'BRANCH-SHAPED CLAIMS LEFT for tests/4318-terminal-resume-list (1 path(s))' \
   && ! printf '%s' "$out" | grep -q '4162-kind-private'; then
  ok branch-shaped-report-is-scoped-to-the-retiring-ticket
else
  fail "branch-shaped-report-is-scoped-to-the-retiring-ticket ($out)"
fi

# The third holder shape, and the one that held the most paths. `file-claim`
# also claims under `pr#<number>`: on 2026-11-06 #4162 held 36 paths under
# `pr#4328` against 35 under its branch, and the first version of this report
# could not see any of them, because it searched for the ticket number inside
# the holder name and a `pr#` name carries the PR's number instead. The holder
# is resolved through its PR's head branch, which does carry the ticket.
r=$(newrun C7); lane "$r" 4162 fiber-4162-build h9; grant "$r" 4162
: > "$T/fclog"; : > "$T/fcheld"
printf 'contract/4162-kind-private\n' > "$T/prbranch-4328"
held pr#4328 crates/contract/src/kind.rs
held pr#4328 crates/contract/src/envelope.rs
out=$(FW_RUN=$r FW_FILE_CLAIM=$T/stub/file-claim FC_LOG=$T/fclog FC_HELD=$T/fcheld \
  bash "$BIN/lanecheck" done 4162 2>&1)
if printf '%s' "$out" | grep -q 'PR-SHAPED CLAIMS LEFT for pr#4328 on contract/4162-kind-private (2 path(s))' \
   && printf '%s' "$out" | grep -q 'file-claim release --lane pr#4328' \
   && ! grep -qx 'pr#4328' "$T/fclog"; then
  ok pr-shaped-claims-are-named-via-their-head-branch
else
  fail "pr-shaped-claims-are-named-via-their-head-branch (log=$(cat "$T/fclog")) ($out)"
fi

# Same scoping as the branch-shaped report, and it needs its own case because
# the two reports decide membership by different means: the branch holder by its
# own name, the PR holder by a branch fetched over the network. A `pr#` holder
# belonging to another ticket must not be named, or the printed command would
# release a live lane's files.
r=$(newrun C8); lane "$r" 4318 fiber-4318-build h10; grant "$r" 4318
: > "$T/fclog"; : > "$T/fcheld"
printf 'contract/4162-kind-private\n' > "$T/prbranch-4328"
held pr#4328 crates/contract/src/kind.rs
out=$(FW_RUN=$r FW_FILE_CLAIM=$T/stub/file-claim FC_LOG=$T/fclog FC_HELD=$T/fcheld \
  bash "$BIN/lanecheck" done 4318 2>&1)
if ! printf '%s' "$out" | grep -q 'pr#4328'; then
  ok pr-shaped-report-is-scoped-to-the-retiring-ticket
else
  fail "pr-shaped-report-is-scoped-to-the-retiring-ticket ($out)"
fi

# A holder whose branch cannot be read is REPORTED, never skipped. The whole
# block exists because silence let claims leak, and resolving this shape over
# the network introduces a new way to fall silent: a gh failure would drop the
# holder that carries the most paths, with no line saying so.
r=$(newrun C9); lane "$r" 4162 fiber-4162-build h11; grant "$r" 4162
: > "$T/fclog"; : > "$T/fcheld"; rm -f "$T/prbranch-4328"
held pr#4328 crates/contract/src/kind.rs
out=$(FW_RUN=$r FW_FILE_CLAIM=$T/stub/file-claim FC_LOG=$T/fclog FC_HELD=$T/fcheld \
  bash "$BIN/lanecheck" done 4162 2>&1)
if printf '%s' "$out" | grep -q 'PR-SHAPED HOLDER UNRESOLVED: pr#4328 (1 path(s))' \
   && printf '%s' "$out" | grep -q 'gh pr view 4328'; then
  ok pr-shaped-holder-that-cannot-be-resolved-is-reported
else
  fail "pr-shaped-holder-that-cannot-be-resolved-is-reported ($out)"
fi

# --- a box Claude lane reaches the waiting states -----------------------------
# Every case above seeds a `muse` roster line, so every one of them goes through
# the delegate branch. That is the one shape that cannot show this bug: the
# whole NEEDS-RULING / WAITING / ABANDONED / STALL block was gated on
# `deleg and not working`, and `deleg` is None for a Claude session, so a box
# Claude lane fell to LIVE whatever it had reported.
#
# 2026-11-06, #4271: the lane reported "STATUS: BLOCKED tkt-ship denied by the
# classifier" and ended its turn, and lanecheck printed
# `LIVE 4271 box fiber-4271-build`. The ask surfaced only because
# bin/inbox-wait.sh happened to fire; the sweep I actually use said the lane was
# fine. Earlier the same day #4256 did the same thing, and bin/ruled.sh on that
# lane printed STOPPED while lanecheck printed LIVE -- two tools in one
# toolchain disagreeing about one lane.
#
# `claude agents --json` reports state in {working, done, blocked} and status in
# {busy, idle}, so the signal was always there. `status == "busy"` is a Claude
# lane's activeTurnId.
boxlane() { # boxlane <run> <ticket> <name> [age, default 3H]
  printf '%s\t%s\tbox\t%s\t-\n' "$(old "${4:-3H}")" "$2" "$3" >> "$1/roster"
}
r=$(newrun H); boxlane "$r" 4271 fiber-4271-build
printf '[{"name":"fiber-4271-build","state":"blocked","status":"idle"}]' > "$T/cagents"
printf '{"ok":true,"sessions":[]}' > "$T/dsess"
: > "$T/pending"; : > "$T/asking"; : > "$T/prs"
rep "$r" 4271 'STATUS: BLOCKED tkt-ship denied by the classifier; PR #4322 ready to ship.'
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^NEEDS-RULING 4271' \
   && printf '%s' "$out" | grep -q 'tkt-ship denied by the classifier' \
   && printf '%s' "$out" | grep -q 'ruled.sh 4271' \
   && ! printf '%s' "$out" | grep -q '^LIVE 4271'; then
  ok a-box-claude-lane-that-reported-and-stopped-needs-a-ruling
else
  fail "a-box-claude-lane-that-reported-and-stopped-needs-a-ruling ($out)"
fi

# The other half of the same gate: a box Claude lane mid-turn is LIVE, and must
# not be dragged into the waiting states by the fix. `busy` is the only status
# that means a turn is running, so a test that only pinned the idle case would
# pass with `working` hardcoded False.
r=$(newrun H2); boxlane "$r" 4271 fiber-4271-build
printf '[{"name":"fiber-4271-build","state":"working","status":"busy"}]' > "$T/cagents"
rep "$r" 4271 'STATUS: BLOCKED tkt-ship denied by the classifier; PR #4322 ready to ship.'
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^LIVE 4271' \
   && ! printf '%s' "$out" | grep -q '^NEEDS-RULING 4271' \
   && ! printf '%s' "$out" | grep -q '^STALL 4271'; then
  ok a-box-claude-lane-mid-turn-is-still-live
else
  fail "a-box-claude-lane-mid-turn-is-still-live ($out)"
fi
# And the half the gate fix left open. A busy lane is correctly LIVE, but the
# report it is waiting on a ruling for went nowhere: #4250 reported "Rule where
# the pure fold lives" at 14:49Z on 2026-11-06 and printed `LIVE 4250 box
# fiber-4250-plan working/busy` for five hours, and #4162 had been doing the
# same since 11:00Z. NEEDS-ANSWER keys on a NEEDS_CONTEXT job, which a lane
# reporting in a file does not have, so nothing read the report at all.
if printf '%s' "$out" | grep -q 'ASK-OPEN' \
   && printf '%s' "$out" | grep -q 'tkt-ship denied by the classifier' \
   && printf '%s' "$out" | grep -q 'ruled.sh 4271'; then
  ok a-busy-lanes-open-ask-rides-the-live-row
else
  fail "a-busy-lanes-open-ask-rides-the-live-row ($out)"
fi
# The negative control, so the note cannot be hardcoded on: a busy lane whose
# report asks for nothing prints a bare LIVE. REVIEWED is not an ask.
r=$(newrun H2b); boxlane "$r" 4271 fiber-4271-build
printf '[{"name":"fiber-4271-build","state":"working","status":"busy"}]' > "$T/cagents"
rep "$r" 4271 'STATUS: REVIEWED, PR green.'
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^LIVE 4271' \
   && ! printf '%s' "$out" | grep -q 'ASK-OPEN'; then
  ok a-busy-lane-with-nothing-to-ask-prints-a-bare-live
else
  fail "a-busy-lane-with-nothing-to-ask-prints-a-bare-live ($out)"
fi
# And an answered ask does not come back. The whole point of the stamp is that
# a ruling naming the report retires it; a note that stayed up after I ruled
# would be the #4161 park problem again -- a line I learn to ignore.
r=$(newrun H2c); boxlane "$r" 4271 fiber-4271-build
printf '[{"name":"fiber-4271-build","state":"working","status":"busy"}]' > "$T/cagents"
rep "$r" 4271 'STATUS: BLOCKED on a ruling.'
ruling "$r" 4271 1
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^LIVE 4271' \
   && ! printf '%s' "$out" | grep -q 'ASK-OPEN'; then
  ok a-busy-lanes-answered-ask-prints-no-note
else
  fail "a-busy-lanes-answered-ask-prints-no-note ($out)"
fi

# The remedy a Claude lane's line prints has to be the one that works on it. A
# Claude session has no delegate session at all, so `delegate session send`
# against it fails with "no such session" -- the same defect as the bare
# `delegate` line #4099 cost a re-derivation to, and the reason this fix needed
# more than flipping the gate. Its roster id column is `-`.
r=$(newrun H3); boxlane "$r" 4271 fiber-4271-build
printf '[{"name":"fiber-4271-build","state":"done","status":"idle"}]' > "$T/cagents"
rep "$r" 4271 'STATUS: REVIEWED, PR green.'
ruling "$r" 4271 1
out=$(FW_RUN=$r FW_SKIP_SAMPLER_CHECK=1 bash "$BIN/lanecheck" 2>&1)
if printf '%s' "$out" | grep -q '^STALL 4271' \
   && printf '%s' "$out" | grep -q "SendMessage to 'fiber-4271-build'" \
   && ! printf '%s' "$out" | grep -q 'delegate session send' \
   && ! printf '%s' "$out" | grep -q 'session send -'; then
  ok a-claude-lanes-wake-is-sendmessage-not-delegate-session-send
else
  fail "a-claude-lanes-wake-is-sendmessage-not-delegate-session-send ($out)"
fi
printf '[]' > "$T/cagents"

exit "$rc"

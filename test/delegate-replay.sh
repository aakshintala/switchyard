#!/usr/bin/env bash
# Tests for delegate/scripts/replay.sh, against fixture job dirs, sessions and
# remotes (never the real $TMPDIR/delegate-jobs, ~/.pi, ~/.fiber or live checkouts).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPLAY="$SCRIPT_DIR/../delegate/scripts/replay.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

T="$(mktemp -d "${TMPDIR:-/tmp}/test-delegate-replay.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" TMPDIR="$T/tmp" JOB_RECORD_SYSTEM_DIR="$T/no-system-jobs"
export XDG_CACHE_HOME="$T/inherited-cache"
mkdir -p "$HOME" "$TMPDIR" "$XDG_CACHE_HOME" "$JOB_RECORD_SYSTEM_DIR"

JOBS="$T/jobs"
SESS="$T/sessions"
OUT="$T/out"
BRIEFS="$T/briefs"
REMOTES="$T/remotes"
mkdir -p "$JOBS" "$SESS" "$BRIEFS" "$REMOTES"

# --- fixture git remote with one commit (the only base sha mirrors know) ---
SRC="$T/src"
mkdir -p "$SRC"
git init -q "$SRC"
git -C "$SRC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
SHA="$(git -C "$SRC" rev-parse HEAD)"
mkdir -p "$REMOTES/aakshintala"
git clone -q --bare "$SRC" "$REMOTES/aakshintala/fiber.git"
export REPLAY_REMOTE_BASE="$REMOTES"
printf '%s\taakshintala/fiber\n' "$T/wt/" >"$T/repo-map.tsv"
export REPLAY_REPO_MAP="$T/repo-map.tsv"
export REPLAY_JOBS_DIR="$JOBS"
export REPLAY_PI_SESSIONS="$SESS"

# Shared brief ref, older than every fixture session.
printf '# shared brief\n' >"$BRIEFS/shared.md"
touch -d '2026-09-01T00:00:00Z' "$BRIEFS/shared.md"

# make_session SID TS CWD BRIEF [array|string]: session file with a first user message.
make_session() {
  local sid="$1" ts="$2" cwd="$3" brief="$4" kind="${5:-array}"
  local dir="$SESS/--sess-$sid--"
  mkdir -p "$dir"
  local file="$dir/${ts}_${sid}.jsonl"
  local content esc
  # JSON-escape bare double quotes; the brief's \n sequences pass through
  # as JSON escapes (printf %s) and decode to newlines.
  esc="${brief//\"/\\\"}"
  if [ "$kind" = string ]; then
    content="$(printf '{"role":"user","content":"%s"}' "$esc")"
  else
    content="$(printf '{"role":"user","content":[{"type":"text","text":"%s"}]}' "$esc")"
  fi
  {
    printf '{"type":"session","version":3,"id":"%s","timestamp":"%s","cwd":"%s"}\n' "$sid" "$ts" "$cwd"
    printf '{"type":"thinking_level_change","id":"t1","parentId":null,"timestamp":"%s","thinkingLevel":"high"}\n' "$ts"
    printf '{"type":"message","id":"m1","parentId":"t1","timestamp":"%s","message":%s}\n' "$ts" "$content"
    printf '{"type":"custom","customType":"pi-stamp","data":{"version":1,"startedAt":1000,"endedAt":2000},"id":"c1","parentId":"m1","timestamp":"%s"}\n' "$ts"
  } >"$file"
}

# make_record ID MODEL STATUS GATE HEADBEFORE SID CWD
make_record() {
  local id="$1" model="$2" status="$3" gate="$4" head="$5" sid="$6" cwd="$7"
  jq -n --arg status "$status" --arg model "$model" --arg gate "$gate" \
    --arg head "$head" --arg sid "$sid" --arg cwd "$cwd" \
    '{status:$status,
      result:{status:$status,model:$model,sessionId:$sid,backend:"pi",
        usage:{inputTokens:100,outputTokens:10,cacheReadTokens:50,cacheWriteTokens:0},
        costUsd:0.001,durationMs:null,
        gateResult:{passed:true,command:$gate,exitCode:0,outputTail:"ok"},
        changeSet:{headBefore:$head,headAfter:$head}},
      supervisorPid:1,
      resume:{model:$model,backend:"pi",cwd:$cwd,sessionId:$sid,gate:$gate}}' \
    >"$JOBS/$id.json"
}

# Eligible jobs: 20 sol, 10 muse, 5 luna; ts newest with index.
gen_eligible() {
  local model="$1" prefix="$2" count="$3" min="$4"
  local i ts sid cwd brief
  for ((i = 0; i < count; i++)); do
    ts="$(printf '2026-10-01T00:%02d:00.000Z' $((min + i)))"
    sid="sid-$prefix-$i"
    cwd="$T/wt/fiber-worktrees/job-$prefix-$i"
    brief="Do task $i in $cwd. See $BRIEFS/shared.md for details.\\n\\n---\\n\\nEnd your final message with STATUS: DONE"
    make_session "$sid" "$ts" "$cwd" "$brief" >/dev/null
    make_record "$prefix-$(printf '%02d' "$i")" "$model" DONE "true" "$SHA" "$sid" "$cwd"
  done
}
gen_eligible "openai/gpt-6.1-sol" sol 20 0
gen_eligible "opencode-go/muse-spark-1.3-contributor" muse 10 0
gen_eligible "openai/gpt-6-luna:xhigh" luna 5 0
# One muse session whose user content is a plain string, newest of all muse rows.
make_session "sid-muse-str" "2026-10-01T01:00:00.000Z" "$T/wt/fiber-worktrees/job-str" \
  "String brief in $T/wt/fiber-worktrees/job-str. See $BRIEFS/shared.md.\\n\\n---\\n\\nEnd your final message with STATUS: DONE" string >/dev/null
make_record "muse-str" "opencode-go/muse-spark-1.3-contributor" DONE "true" "$SHA" "sid-muse-str" "$T/wt/fiber-worktrees/job-str"

# --- ineligible jobs, each failing exactly one check ---
make_session "sid-run" "2026-10-01T00:00:00.000Z" "$T/wt/a" "hi $BRIEFS/shared.md" >/dev/null
make_record "job-running" "openai/gpt-6.1-sol" RUNNING "true" "$SHA" "sid-run" "$T/wt/a"
make_session "sid-res" "2026-10-01T00:00:00.000Z" "$T/wt/b" "hi $BRIEFS/shared.md" >/dev/null
make_record "job-resumed" "openai/gpt-6.1-sol" DONE "true" "$SHA" "sid-res" "$T/wt/b"
jq '.resumedFrom="older-id"' "$JOBS/job-resumed.json" >"$T/tmp.json" && mv "$T/tmp.json" "$JOBS/job-resumed.json"
make_session "sid-cl" "2026-10-01T00:00:00.000Z" "$T/wt/c" "hi $BRIEFS/shared.md" >/dev/null
make_record "job-claude" "openai/gpt-6.1-sol" DONE "true" "$SHA" "sid-cl" "$T/wt/c"
jq '.resume.backend="claude"' "$JOBS/job-claude.json" >"$T/tmp.json" && mv "$T/tmp.json" "$JOBS/job-claude.json"
make_session "sid-ng" "2026-10-01T00:00:00.000Z" "$T/wt/d" "hi $BRIEFS/shared.md" >/dev/null
make_record "job-nogate" "openai/gpt-6.1-sol" DONE "" "$SHA" "sid-ng" "$T/wt/d"
make_session "sid-nb" "2026-10-01T00:00:00.000Z" "$T/wt/e" "hi $BRIEFS/shared.md" >/dev/null
make_record "job-nobase" "openai/gpt-6.1-sol" DONE "true" "" "sid-nb" "$T/wt/e"
make_record "job-noses" "openai/gpt-6.1-sol" DONE "true" "$SHA" "sid-absent" "$T/wt/f"
make_session "sid-tmp" "2026-10-01T00:00:00.000Z" "/var/folders/x/T/review-pr.run.abc123/wt-review" "hi $BRIEFS/shared.md" >/dev/null
make_record "job-tempcwd" "openai/gpt-6.1-sol" DONE "true" "$SHA" "sid-tmp" "/var/folders/x/T/review-pr.run.abc123/wt-review"
make_session "sid-nr" "2026-10-01T00:00:00.000Z" "/nonexistent/nowhere/xyz" "hi $BRIEFS/shared.md" >/dev/null
make_record "job-norepo" "openai/gpt-6.1-sol" DONE "true" "$SHA" "sid-nr" "/nonexistent/nowhere/xyz"
make_session "sid-mb" "2026-10-01T00:00:00.000Z" "$T/wt/g" "hi $BRIEFS/shared.md" >/dev/null
make_record "job-missingbase" "openai/gpt-6.1-sol" DONE "true" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "sid-mb" "$T/wt/g"
make_session "sid-bm" "2026-10-01T00:00:00.000Z" "$T/wt/h" "hi /absent/brief.md" >/dev/null
make_record "job-briefmissing" "openai/gpt-6.1-sol" DONE "true" "$SHA" "sid-bm" "$T/wt/h"
printf '# new brief\n' >"$BRIEFS/new.md"
touch -d '2026-11-01T00:00:00Z' "$BRIEFS/new.md"
make_session "sid-bn" "2026-10-01T00:00:00.000Z" "$T/wt/i" "hi $BRIEFS/new.md" >/dev/null
make_record "job-briefnewer" "openai/gpt-6.1-sol" DONE "true" "$SHA" "sid-bn" "$T/wt/i"
# pi-backend model outside the replay set
make_session "sid-om" "2026-10-01T00:00:00.000Z" "$T/wt/j" "hi $BRIEFS/shared.md" >/dev/null
make_record "job-othermodel" "openai/gpt-6-astra" DONE "true" "$SHA" "sid-om" "$T/wt/j"

# --- select on a missing jobs dir exits 2 ---
if REPLAY_JOBS_DIR="$T/no-such-dir" bash "$REPLAY" select --out "$T/out-missing" 2>"$T/missing-err.txt"; then
  fail "select on missing jobs dir should fail"
else
  [ $? -eq 2 ] || fail "select on missing jobs dir exits 2"
fi

# --- full select: 18 sol / 9 muse / 3 luna ---
bash "$REPLAY" select --out "$OUT" >"$T/select-out.txt" || fail "select exits 0"
[ -f "$OUT/manifest.tsv" ] || fail "select writes manifest.tsv"
[ -f "$OUT/skipped.tsv" ] || fail "select writes skipped.tsv"
[ "$(wc -l <"$OUT/manifest.tsv")" -eq 30 ] || fail "manifest has 30 rows (got $(wc -l <"$OUT/manifest.tsv"))"
[ "$(awk -F'\t' '$2=="codex"{c++} END{print c+0}' "$OUT/manifest.tsv")" -eq 21 ] || fail "manifest has 21 codex rows (18 sol + 3 luna)"
[ "$(grep -c 'openai/gpt-6.1-sol' "$OUT/manifest.tsv")" -eq 18 ] || fail "manifest has 18 sol rows"
[ "$(grep -c 'openai/gpt-6-luna:xhigh' "$OUT/manifest.tsv")" -eq 3 ] || fail "manifest has 3 luna rows"
[ "$(grep -c 'muse-spark' "$OUT/manifest.tsv")" -eq 9 ] || fail "manifest has 9 muse rows"
# quota cut: oldest sol rows (sol-00, sol-01) and oldest muse/luna rows are out
grep -q $'^sol-00\t' "$OUT/manifest.tsv" && fail "quota cuts oldest sol-00"
grep -q $'^sol-01\t' "$OUT/manifest.tsv" && fail "quota cuts oldest sol-01"
grep -q $'^sol-19\t' "$OUT/manifest.tsv" || fail "manifest keeps newest sol-19"
grep -q $'^muse-str\t' "$OUT/manifest.tsv" || fail "manifest keeps newest muse-str"
# newest-first within a model: first sol row is sol-19
first_sol="$(awk -F'\t' '$3=="openai/gpt-6.1-sol"{print $1; exit}' "$OUT/manifest.tsv")"
[ "$first_sol" = "sol-19" ] || fail "sol rows newest-first (got $first_sol)"
# manifest columns: job share pi_model fiber_model repo base_sha session cwd started_at
awk -F'\t' 'NF!=9{print "bad columns: "$0; bad=1} END{exit bad}' "$OUT/manifest.tsv" || fail "manifest has 9 columns"
grep -q $'^muse-str\tmuse\topencode-go/muse-spark-1.3-contributor\tfiber/opencode-go/muse-spark-1.3-contributor\taakshintala/fiber\t'"$SHA" "$OUT/manifest.tsv" || fail "muse row maps to fiber model"
grep -q $'^sol-19\tcodex\topenai/gpt-6.1-sol\t\taakshintala/fiber\t'"$SHA" "$OUT/manifest.tsv" || fail "sol row has empty fiber model"

# --- every exclusion logged with its reason ---
for pair in "job-running:still running" "job-resumed:resumed turn" "job-claude:backend" \
    "job-nogate:no gate" "job-nobase:no base commit" "job-noses:no pi session" \
    "job-tempcwd:review-pr temp" "job-norepo:no repo" "job-missingbase:base commit missing" \
    "job-briefmissing:brief .* missing" "job-briefnewer:brief .* newer" "job-othermodel:model not in"; do
  id="${pair%%:*}"
  want="${pair#*:}"
  grep -q "^$id"$'\t' "$OUT/skipped.tsv" || fail "skipped.tsv logs $id"
  grep "^$id"$'\t' "$OUT/skipped.tsv" | grep -Eq "$want" || fail "$id reason matches $want"
done

# --- snapshots exist; prompt stripped of the delegate status block ---
[ -f "$OUT/jobs/muse-str/prompt.md" ] || fail "select snapshots prompt.md"
[ -f "$OUT/jobs/muse-str/gate.txt" ] || fail "select snapshots gate.txt"
grep -q "STATUS: DONE" "$OUT/jobs/muse-str/prompt.md" && fail "prompt snapshot strips the status block"
grep -q "String brief" "$OUT/jobs/muse-str/prompt.md" || fail "prompt snapshot keeps the brief"
[ -f "$OUT/jobs/muse-str/briefs/1-shared.md" ] || fail "select copies brief files"
grep -q $'^'"$BRIEFS"'/shared.md'$'\t''1-shared.md' "$OUT/jobs/muse-str/briefs/map.tsv" || fail "brief map records original path"

# --- rerun without --force refuses; with --force reproduces ---
cp "$OUT/manifest.tsv" "$T/manifest-first.tsv"
if bash "$REPLAY" select --out "$OUT" 2>"$T/refoo.txt"; then
  fail "select without --force should refuse"
else
  [ $? -eq 2 ] || fail "select overwrite refusal exits 2"
fi
bash "$REPLAY" select --out "$OUT" --force >/dev/null || fail "select --force exits 0"
cmp "$T/manifest-first.tsv" "$OUT/manifest.tsv" || fail "select is deterministic"

# --- Task 2: brief recovery against a second fixture tree ---
JOBS2="$T/jobs2"
SESS2="$T/sessions2"
OUT2="$T/out2"
mkdir -p "$JOBS2" "$SESS2"

# paths with spaces, outside the cwd
printf '# spaced brief\n' >"$BRIEFS/my brief.md"
touch -d '2026-09-01T00:00:00Z' "$BRIEFS/my brief.md"
SPCWD="$T/wt/with space/job1"
SPBRIEF="Work in $SPCWD. Read \"$BRIEFS/my brief.md\" and \"$BRIEFS/my brief.md\" again. In-repo notes at \"$SPCWD/NOTES.md\".\\n\\n---\\n\\nEnd your final message with STATUS: DONE"
# reuse the builders with SESS2: temporarily point SESS at SESS2
SESS_SAVED="$SESS"
SESS="$SESS2"
make_session "sid-sp" "2026-10-02T00:00:00.000Z" "$SPCWD" "$SPBRIEF" >/dev/null
# brief with its own --- rule plus delegate's trailing block
HRBRIEF="Fix the bug.\\n\\n---\\n\\nA rule inside the brief.\\n\\n---\\n\\nEnd your final message with STATUS: DONE"
make_session "sid-hr" "2026-10-02T00:01:00.000Z" "$T/wt/jobhr" "$HRBRIEF" >/dev/null
# brief whose mtime equals the session start second: admitted
printf '# edge brief\n' >"$BRIEFS/edge.md"
touch -d '2026-10-02T00:02:00Z' "$BRIEFS/edge.md"
make_session "sid-eq" "2026-10-02T00:02:00.000Z" "$T/wt/jobeq" "Read $BRIEFS/edge.md.\\n\\n---\\n\\nEnd STATUS: DONE" >/dev/null
# trailing-slash cwd with an in-cwd ref: admitted, nothing copied
make_session "sid-ts" "2026-10-02T00:03:00.000Z" "$T/wt/jobts/" "See $T/wt/jobts/NOTES.md.\\n\\n---\\n\\nEnd STATUS: DONE" >/dev/null
SESS="$SESS_SAVED"

# make_record writes to $JOBS; run it in a subshell with JOBS redirected:
MUSE_ID="opencode-go/muse-spark-1.3-contributor"
for spec in "job-space|$MUSE_ID|sid-sp|$SPCWD|bash $SPCWD/gate.sh" \
    "job-hr|$MUSE_ID|sid-hr|$T/wt/jobhr|true" \
    "job-eq|$MUSE_ID|sid-eq|$T/wt/jobeq|true" \
    "job-ts|$MUSE_ID|sid-ts|$T/wt/jobts/|true"; do
  id="${spec%%|*}"; rest="${spec#*|}"
  model="${rest%%|*}"; rest="${rest#*|}"
  sid="${rest%%|*}"; rest="${rest#*|}"
  cwd="${rest%%|*}"; gate="${rest#*|}"
  ( JOBS="$JOBS2"; make_record "$id" "$model" DONE "$gate" "$SHA" "$sid" "$cwd" )
done

REPLAY_JOBS_DIR="$JOBS2" REPLAY_PI_SESSIONS="$SESS2" \
  bash "$REPLAY" select --out "$OUT2" --total 30 >/dev/null || fail "select recovery tree exits 0"
[ "$(wc -l <"$OUT2/manifest.tsv")" -eq 4 ] || fail "recovery tree admits 4 rows"
# spaced cwd and brief: snapshot keeps spaces, one copy for a double ref
[ -f "$OUT2/jobs/job-space/briefs/1-my brief.md" ] || fail "spaced brief copied once"
[ "$(wc -l <"$OUT2/jobs/job-space/briefs/map.tsv")" -eq 1 ] || fail "double ref maps once"
grep -qF "$BRIEFS/my brief.md" "$OUT2/jobs/job-space/briefs/map.tsv" || fail "brief map keeps spaced path"
grep -qF "$SPCWD" "$OUT2/jobs/job-space/prompt.md" || fail "spaced cwd kept in prompt snapshot"
grep -qF "$SPCWD/NOTES.md" "$OUT2/jobs/job-space/prompt.md" || fail "in-cwd ref kept in prompt"
[ -f "$OUT2/jobs/job-space/gate.txt" ] || fail "gate snapshot exists"
grep -qF "bash $SPCWD/gate.sh" "$OUT2/jobs/job-space/gate.txt" || fail "gate snapshot is verbatim"
# inner --- rule survives, trailing status block goes
[ -f "$OUT2/jobs/job-hr/prompt.md" ] || fail "hr prompt snapshot exists"
grep -q "A rule inside the brief" "$OUT2/jobs/job-hr/prompt.md" || fail "inner --- block kept"
grep -q "STATUS: DONE" "$OUT2/jobs/job-hr/prompt.md" && fail "trailing status block stripped"
# edge-mtime brief admitted and copied
[ -f "$OUT2/jobs/job-eq/briefs/1-edge.md" ] || fail "edge-mtime brief copied"
# trailing-slash cwd: in-cwd ref means no copies, empty map
[ ! -s "$OUT2/jobs/job-ts/briefs/map.tsv" ] || fail "in-cwd ref copies nothing"
[ "$(ls "$OUT2/jobs/job-ts/briefs" | wc -l)" -eq 1 ] || fail "only map.tsv in briefs"

echo "select cases passed"

# --- Task 3: run ---
FBIN="$T/fakebin"
FLOG="$T/fakelog"
mkdir -p "$FBIN" "$FLOG"
cat >"$FBIN/delegate" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
cmd="${1:-}"
if [ $# -gt 0 ]; then shift; fi
case "$cmd" in
  models)
    printf '%s' "${FAKE_MODELS:-}" ;;
  run)
    model=""; cwd=""; gate=""; prompt=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --model) model="$2"; shift 2 ;;
        --cwd) cwd="$2"; shift 2 ;;
        --gate) gate="$2"; shift 2 ;;
        --prompt-file) prompt="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    id="fake-$$"
    {
      printf 'model=%s\n' "$model"
      printf 'cwd=%s\n' "$cwd"
      printf 'gate=%s\n' "$gate"
      printf 'prompt=%s\n' "$prompt"
      printf 'TMPDIR=%s\n' "${TMPDIR:-}"
      printf 'XDG_CACHE_HOME=%s\n' "${XDG_CACHE_HOME:-}"
      printf 'FIBER_BIN=%s\n' "${FIBER_BIN:-}"
      printf 'FIBER_HOME=%s\n' "${FIBER_HOME:-}"
      printf 'GH_TOKEN=%s\n' "${GH_TOKEN:-}"
      printf 'GITHUB_TOKEN=%s\n' "${GITHUB_TOKEN:-}"
      printf 'GIT_SSH_COMMAND=%s\n' "${GIT_SSH_COMMAND:-}"
      printf 'GIT_CONFIG_GLOBAL=%s\n' "${GIT_CONFIG_GLOBAL:-}"
      printf 'CARGO_TARGET_DIR=%s\n' "${CARGO_TARGET_DIR:-}"
      printf 'PATH0=%s\n' "${PATH%%:*}"
    } >"$FAKE_LOGDIR/run-$id.env"
    sid="fsid-$$"
    mkdir -p "$TMPDIR/delegate-jobs" "$XDG_CACHE_HOME/delegate/locators" || exit 1
    record="$TMPDIR/delegate-jobs/$id.json"
    jq -n --arg sid "$sid" --arg model "$model" --arg cwd "$cwd" --arg gate "$gate" \
      '{status:"DONE",
        result:{status:"DONE",model:$model,sessionId:$sid,backend:"fiber",
          usage:{inputTokens:100,outputTokens:10,cacheReadTokens:50,cacheWriteTokens:0},
          costUsd:0.002,durationMs:null,
          gateResult:{passed:true,command:$gate,exitCode:0,outputTail:"ok"},
          changeSet:{headBefore:"abc",headAfter:"abc"}},
        supervisorPid:1,
        resume:{model:$model,backend:"fiber",cwd:$cwd,sessionId:$sid,gate:$gate}}' \
      >"$record" || exit 1
    printf '%s\n' "$record" >"$XDG_CACHE_HOME/delegate/locators/$id" || exit 1
    if [ -n "${FAKE_EVENTS:-}" ]; then
      mkdir -p "$FIBER_HOME/projects/p/sessions/$sid"
      cp "$FAKE_EVENTS" "$FIBER_HOME/projects/p/sessions/$sid/events.jsonl"
    fi
    printf '%s\n' "$id" ;;
  watch) exit 0 ;;
  *) echo "fake delegate: unknown command $cmd" >&2; exit 2 ;;
esac
EOF
chmod +x "$FBIN/delegate"
cat >"$FBIN/cargo" <<'EOF'
#!/bin/sh
printf 'cargo argv: %s\n' "$*" >>"$FAKE_LOGDIR/cargo.log"
printf 'CARGO_TARGET_DIR=%s\n' "$CARGO_TARGET_DIR" >>"$FAKE_LOGDIR/cargo.log"
mkdir -p "$CARGO_TARGET_DIR/release"
cat >"$CARGO_TARGET_DIR/release/fiber" <<'INNER'
#!/bin/sh
if [ "$1" = "version" ]; then echo "fiber 0.0.0 (testhash)"; else echo "fake fiber"; fi
INNER
chmod +x "$CARGO_TARGET_DIR/release/fiber"
EOF
chmod +x "$FBIN/cargo"
cat >"$FBIN/sandbox-allow" <<'EOF'
#!/bin/sh
if [ "$1" = "-f" ]; then shift 2; fi
exec "$@"
EOF
chmod +x "$FBIN/sandbox-allow"
cat >"$FBIN/sandbox-deny" <<'EOF'
#!/bin/sh
# usage: sandbox-deny -f PROFILE env VAR=... CMD ...
# allowlist delegate and fiber (runs them with the env applied); deny rest.
if [ "$1" = "-f" ]; then shift 2; fi
if [ "$1" = "env" ]; then shift; fi
while [ $# -gt 0 ]; do
  case "$1" in
    *=*) export "$1"; shift ;;
    *) break ;;
  esac
done
case "$(basename "${1:-none}")" in
  delegate|fiber) exec "$@" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FBIN/sandbox-deny"
PATH="$FBIN:$PATH"
DELEGATE_BIN="$FBIN/delegate"
FAKE_LOGDIR="$FLOG"
MUSE_FIBER="fiber/opencode-go/muse-spark-1.3-contributor"
FAKE_MODELS="$(printf 'ID BACKEND\n%s fiber\n%s pi' "$MUSE_FIBER" "$MUSE_ID")"
export PATH DELEGATE_BIN FAKE_LOGDIR FAKE_MODELS
# fake fiber source: clone of a local origin, one commit behind it
mkdir -p "$T/fiberwork"
git init -q -b main "$T/fiberwork"
git -C "$T/fiberwork" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
git clone -q --bare "$T/fiberwork" "$T/fiber-origin.git"
git clone -q "$T/fiber-origin.git" "$T/fiber-src"
git -C "$T/fiberwork" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
git -C "$T/fiberwork" push -q "$T/fiber-origin.git" main 2>/dev/null
REPLAY_FIBER_SRC="$T/fiber-src"
export REPLAY_FIBER_SRC
mkdir -p "$HOME/.fiber/credentials" "$HOME/.fiber/extensions"
printf '{"model":"m"}' >"$HOME/.fiber/config.json"
printf 'secret' >"$HOME/.fiber/credentials/tok"
printf '{"ext":"e"}' >"$HOME/.fiber/extensions/ext.json"
printf 'rule' >"$HOME/.fiber/rules"
export REPLAY_SANDBOX_EXEC="$FBIN/sandbox-deny"

# usage errors first: no source, live source, batch+job, bad share
if env -u REPLAY_FIBER_SRC bash "$REPLAY" run --out "$OUT2" --job job-ts --fresh 2>/dev/null; then
  fail "run without REPLAY_FIBER_SRC should fail"
else
  [ $? -eq 2 ] || fail "run without REPLAY_FIBER_SRC exits 2"
fi
if REPLAY_FIBER_SRC="$HOME/work/fiber" bash "$REPLAY" run --out "$OUT2" --job job-ts --fresh 2>/dev/null; then
  fail "run with live fiber source should fail"
else
  [ $? -eq 2 ] || fail "run with live fiber source exits 2"
fi
if bash "$REPLAY" run --out "$OUT2" --batch 1 --job job-ts 2>/dev/null; then
  fail "run with batch+job should fail"
else
  [ $? -eq 2 ] || fail "run with batch+job exits 2"
fi
bash "$REPLAY" run --out "$OUT2" --share bogus 2>/dev/null && fail "run with bad share exits 2"

# main batch: first 3 muse rows of OUT2
bash "$REPLAY" run --out "$OUT2" --share muse --batch 3 >/dev/null || fail "run batch exits 0"
[ -x "$OUT2/fiber-target/release/fiber" ] || fail "fiber binary built"
[ -f "$OUT2/fiber-build.log" ] || fail "fiber build log written"
[ "$(git -C "$T/fiber-src" rev-parse HEAD)" = "$(git -C "$T/fiber-src" rev-parse origin/main)" ] || fail "fiber src at origin/main"
grep -q "cargo argv: build --manifest-path" "$FLOG/cargo.log" || fail "cargo build uses manifest-path"
grep -qF "$T/fiber-src/Cargo.toml" "$FLOG/cargo.log" || fail "cargo builds the fiber source clone"
grep -q "cargo argv:.*--release --bin fiber" "$FLOG/cargo.log" || fail "cargo build invoked"
grep -qF "CARGO_TARGET_DIR=$OUT2/fiber-target" "$FLOG/cargo.log" || fail "fiber target under OUT"
for id in job-ts job-eq job-hr; do [ -d "$OUT2/runs/$id" ] || fail "$id ran"; done
[ ! -e "$OUT2/runs/job-space" ] || fail "batch stops at 3"
[ "$(git -C "$OUT2/runs/job-hr/scratch" rev-parse HEAD)" = "$SHA" ] || fail "scratch at base commit"
[ -z "$(git -C "$OUT2/runs/job-hr/scratch" remote)" ] || fail "scratch has no remote"
grep -qF "$OUT2/runs/job-ts/scratch" "$OUT2/runs/job-ts/prompt.md" || fail "prompt rewritten to scratch"
grep -qF "$OUT2/runs/job-ts/scratch/NOTES.md" "$OUT2/runs/job-ts/prompt.md" || fail "trailing-slash cwd keeps the path separator"
grep -qF "$T/wt/jobts" "$OUT2/runs/job-ts/prompt.md" && fail "original cwd gone from prompt"
[ "$(ls "$FLOG"/run-fake-*.env 2>/dev/null | wc -l | tr -d ' ')" -eq 3 ] || fail "3 delegate runs"
HRENV="$(grep -lF "cwd=$OUT2/runs/job-hr/scratch" "$FLOG"/run-fake-*.env | head -1)"
[ -n "$HRENV" ] || fail "delegate saw the scratch cwd"
grep -qF "model=$MUSE_FIBER" "$HRENV" || fail "delegate ran the fiber model"
grep -qF "prompt=$OUT2/runs/job-hr/prompt.md" "$HRENV" || fail "delegate read the run prompt"
grep -qF "gate=true" "$HRENV" || fail "delegate got the gate"
HRTMP="$(grep '^TMPDIR=' "$HRENV" | cut -d= -f2)"
[ "${HRTMP#/tmp/frp-}" != "$HRTMP" ] && [ "${#HRTMP}" -lt 20 ] || fail "replay TMPDIR is a short /tmp/frp- dir (got $HRTMP)"
grep -qF "XDG_CACHE_HOME=$HRTMP/cache" "$HRENV" || fail "locator cache is inside the sealed run TMPDIR"
[ ! -e "$HOME/.cache/delegate/locators" ] || fail "replay did not write locators under HOME"
[ ! -e "$T/inherited-cache/delegate/locators" ] || fail "replay did not write locators under inherited XDG cache"
[ "$(cat "$OUT2/runs/job-hr/tmpdir")" = "$HRTMP" ] || fail "run tmpdir file matches TMPDIR"
[ -d "$HRTMP" ] || fail "replay TMPDIR exists"
# two preps of the same job id in two out dirs get different TMPDIRs; the first survives the second prep
sed -n '/^sb_quote() {/,/^}/p;/^sh_quote() {/,/^}/p;/^run_tmp() {/,/^}/p;/^write_seal() {/,/^}/p' "$REPLAY" >"$T/tmpdir-funcs.sh"
mkdir -p "$T/tmpA/runs/job-hr" "$T/tmpB/runs/job-hr"
RUN_OUT="$T/tmpA" RUN_REALTMP="${TMPDIR:-/tmp}" bash -c '. "$1"; write_seal "$2"' _ "$T/tmpdir-funcs.sh" "$T/tmpA/runs/job-hr" || fail "write_seal A runs"
RUN_OUT="$T/tmpB" RUN_REALTMP="${TMPDIR:-/tmp}" bash -c '. "$1"; write_seal "$2"' _ "$T/tmpdir-funcs.sh" "$T/tmpB/runs/job-hr" || fail "write_seal B runs"
ATMP="$(cat "$T/tmpA/runs/job-hr/tmpdir")"; BTMP="$(cat "$T/tmpB/runs/job-hr/tmpdir")"
[ -n "$ATMP" ] && [ -n "$BTMP" ] || fail "both preps record a TMPDIR"
[ "$ATMP" != "$BTMP" ] || fail "same job id in two out dirs gets different TMPDIRs"
[ -d "$ATMP" ] || fail "first prep dir survives second prep"
rm -rf "$ATMP" "$BTMP"
# a failed TMPDIR allocation fails write_seal, and prep_job propagates it
mkdir -p "$T/nomktemp" "$T/tmpC/runs/job-hr"
printf '#!/bin/sh\nexit 1\n' >"$T/nomktemp/mktemp"
chmod +x "$T/nomktemp/mktemp"
PATH="$T/nomktemp:$PATH" RUN_OUT="$T/tmpC" bash -c '. "$1"; write_seal "$2"' _ "$T/tmpdir-funcs.sh" "$T/tmpC/runs/job-hr" && fail "write_seal fails when mktemp fails"
grep -qF 'write_seal "$rundir" || {' "$REPLAY" || fail "prep_job propagates a write_seal failure"
# --- --fresh leaves an untrusted recorded tmpdir alone ---
sed -n '/^err() {/,/^}/p;/^sh_quote() {/,/^}/p;/^clean_recorded_tmpdir() {/,/^}/p' "$REPLAY" >"$T/clean-tmp.sh"
SENT="$T/sentinel"; mkdir -p "$SENT"; printf 'keep' >"$SENT/keep.txt"
RCLEAN="$T/cleanrun"; mkdir -p "$RCLEAN"
# traversal past the old prefix check resolves to the sentinel
printf '%s' "/tmp/frp-ABCDEF/../..$SENT" >"$RCLEAN/tmpdir"
clean_warn="$(bash -c '. "$1"; clean_recorded_tmpdir "$2"' _ "$T/clean-tmp.sh" "$RCLEAN" 2>&1)"
[ -f "$SENT/keep.txt" ] || fail "traversal tmpdir left untouched"
case "$clean_warn" in *warning*) ;; *) fail "traversal tmpdir warns" ;; esac
# non-matching name in the suite temp dir
mkdir -p "$T/nope"; printf 'keep' >"$T/nope/k.txt"
printf '%s' "$T/nope" >"$RCLEAN/tmpdir"
clean_warn="$(bash -c '. "$1"; clean_recorded_tmpdir "$2"' _ "$T/clean-tmp.sh" "$RCLEAN" 2>&1)"
[ -f "$T/nope/k.txt" ] || fail "non-matching tmpdir left untouched"
case "$clean_warn" in *warning*) ;; *) fail "non-matching tmpdir warns" ;; esac
# symlink at mktemp form pointing at a real dir
SYMREAL="$T/symreal"; mkdir -p "$SYMREAL"; printf 'keep' >"$SYMREAL/k.txt"
SYMLINK="$(mktemp -u /tmp/frp-XXXXXX)"
ln -s "$SYMREAL" "$SYMLINK"
printf '%s' "$SYMLINK" >"$RCLEAN/tmpdir"
clean_warn="$(bash -c '. "$1"; clean_recorded_tmpdir "$2"' _ "$T/clean-tmp.sh" "$RCLEAN" 2>&1)"
[ -f "$SYMREAL/k.txt" ] || fail "symlink target left untouched"
[ -L "$SYMLINK" ] || fail "symlink itself left untouched"
case "$clean_warn" in *warning*) ;; *) fail "symlink tmpdir warns" ;; esac
rm -f "$SYMLINK"
# an exact-form dir owned by us is still cleaned
VALIDTMP="$(mktemp -d /tmp/frp-XXXXXX)"; printf 'x' >"$VALIDTMP/f.txt"
printf '%s' "$VALIDTMP" >"$RCLEAN/tmpdir"
bash -c '. "$1"; clean_recorded_tmpdir "$2"' _ "$T/clean-tmp.sh" "$RCLEAN" 2>/dev/null || fail "valid tmpdir cleans"
[ -e "$VALIDTMP" ] && fail "valid tmpdir removed"
grep -qF "FIBER_BIN=$OUT2/fiber-target/release/fiber" "$HRENV" || fail "FIBER_BIN is the built fiber"
grep -qF "FIBER_HOME=$OUT2/fiber-home" "$HRENV" || fail "FIBER_HOME under OUT"
grep -qF "GH_TOKEN=replay-invalid" "$HRENV" || fail "GH_TOKEN invalid"
grep -qF "GITHUB_TOKEN=replay-invalid" "$HRENV" || fail "GITHUB_TOKEN invalid"
grep -qF "GIT_SSH_COMMAND=false" "$HRENV" || fail "git ssh disabled"
grep -qF "GIT_CONFIG_GLOBAL=$OUT2/runs/job-hr/gitconfig" "$HRENV" || fail "gitconfig pinned"
grep -qF "CARGO_TARGET_DIR=$OUT2/target/aakshintala_fiber" "$HRENV" || fail "cargo target per repo"
grep -qF "PATH0=$OUT2/runs/job-hr/shim" "$HRENV" || fail "shim first on PATH"
[ -f "$OUT2/runs/job-hr/record.json" ] || fail "record copied out of sealed tmp"
HRMATCH=0
HR_SOURCE=""
for f in "$HRTMP/delegate-jobs/"*.json; do
  [ -e "$f" ] || continue
  HR_SOURCE="$f"
  cmp -s "$f" "$OUT2/runs/job-hr/record.json" && HRMATCH=1
done
[ "$HRMATCH" -eq 1 ] || fail "record copied from TMPDIR/delegate-jobs"
[ -n "$HR_SOURCE" ] || fail "fake delegate record source was found"
HR_ID="${HR_SOURCE##*/}"
HR_ID="${HR_ID%.json}"
HRLOC="$HRTMP/cache/delegate/locators/$HR_ID"
[ -f "$HRLOC" ] || fail "fake locator is in the current sealed run cache"
[ "$(cat "$HRLOC")" = "$HR_SOURCE" ] || fail "fake locator targets TMPDIR/delegate-jobs"
grep -qF '"backend": "fiber"' "$OUT2/runs/job-hr/record.json" || fail "record is the replay record"
if ls "${TMPDIR:-/tmp}/delegate-jobs/fake-"* >/dev/null 2>&1; then fail "replay record leaked to real jobs dir"; fi
[ "$(head -n 1 "$OUT2/runs/job-hr/seal.sb")" = "(version 1)" ] || fail "seal profile starts with (version 1)"
grep -qF "$OUT2" "$OUT2/runs/job-hr/seal.sb" || fail "seal profile names OUT"
grep -qF "${TMPDIR:-/tmp}/delegate-jobs" "$OUT2/runs/job-hr/seal.sb" || fail "seal denies real jobs dir"
"$OUT2/runs/job-hr/shim/gh" >/dev/null 2>&1 && fail "shim gh exits 1"
grep -q "fiber 0.0.0 (testhash)" "$OUT2/runs/job-hr/version.txt" || fail "fiber version recorded"
[ -f "$OUT2/fiber-home/config.json" ] || fail "fiber home copied"
[ -f "$OUT2/fiber-home/extensions/ext.json" ] || fail "fiber home copies extensions"
[ -f "$OUT2/fiber-home/rules" ] || fail "fiber home copies rules file"
if [ "$(uname)" = "Darwin" ]; then fibhome_mode="$(stat -f %Lp "$OUT2/fiber-home")"; else fibhome_mode="$(stat -c %a "$OUT2/fiber-home")"; fi
[ "$fibhome_mode" = "700" ] || fail "fiber home mode 700"
grep -q "events missing" "$OUT2/runs/job-hr/notes.txt" || fail "missing events noted"

# live brief edited after select has no effect; path-outside events plant notes
# (command text alone is not outward: detection is by shim execution)
printf '# changed after select\n' >"$BRIEFS/my brief.md"
cat >"$T/events.jsonl" <<EOF
{"kind":"tool_call_requested","session_id":"s","ts":1,"schema_version":1,"action_id":"a1","payload":{"name":"shell","arguments":{"command":"git push origin main"}}}
{"kind":"tool_call_requested","session_id":"s","ts":2,"schema_version":1,"action_id":"a2","payload":{"name":"read","arguments":{"path":"$HOME/work/other/file.ts"}}}
{"kind":"tool_call_requested","session_id":"s","ts":3,"schema_version":1,"action_id":"a3","payload":{"name":"read","arguments":{"path":"$OUT2/runs/job-space/scratch/file.ts"}}}
EOF
FAKE_EVENTS="$T/events.jsonl" bash "$REPLAY" run --out "$OUT2" --share muse --batch 3 >/dev/null || fail "second batch exits 0"
[ -d "$OUT2/runs/job-space" ] || fail "second batch runs job-space"
grep -q "spaced brief" "$OUT2/runs/job-space/briefs/1-my brief.md" || fail "run reads the snapshot, not the live brief"
grep -q "changed after select" "$OUT2/runs/job-space/briefs/1-my brief.md" && fail "live brief edit leaks into the run"
grep -qF "$OUT2/runs/job-space/briefs/1-my brief.md" "$OUT2/runs/job-space/prompt.md" || fail "prompt re-pointed at run brief"
grep -qF "$OUT2/runs/job-space/scratch" "$OUT2/runs/job-space/gate.txt" || fail "gate rewritten to scratch"
grep -qF "$SPCWD" "$OUT2/runs/job-space/gate.txt" && fail "original cwd gone from gate"
grep -q "git push origin main" "$OUT2/runs/job-space/notes.txt" && fail "command text alone is not outward"
grep -q "work/other/file.ts" "$OUT2/runs/job-space/notes.txt" || fail "home work path noted"
grep -q "scratch/file.ts" "$OUT2/runs/job-space/notes.txt" && fail "scratch path is not outward"
unset FAKE_EVENTS

# --job reruns exactly one row with --fresh; without --fresh it refuses
bash "$REPLAY" run --out "$OUT2" --job job-ts --fresh >/dev/null || fail "--job --fresh exits 0"
[ -f "$OUT2/runs/job-ts/record.json" ] || fail "--job reran the row"
if bash "$REPLAY" run --out "$OUT2" --job job-ts 2>/dev/null; then
  fail "--job on existing dir should refuse"
else
  [ $? -eq 1 ] || fail "--job refusal exits 1"
fi
bash "$REPLAY" run --out "$OUT2" --job nope 2>/dev/null && fail "--job unknown id exits 2"

# codex row with no fiber model stays pending and is never run
JOBS4="$T/jobs4"; SESS4="$T/sessions4"; OUT4="$T/out4"
mkdir -p "$JOBS4" "$SESS4"
SESS_SAVED="$SESS"; SESS="$SESS4"; JOBS_SAVED="$JOBS"; JOBS="$JOBS4"
make_session "sid-sol1" "2026-10-03T00:00:00.000Z" "$T/wt/sol1" "Sol brief.\\n\\n---\\n\\nEnd STATUS: DONE" >/dev/null
make_record "sol-only" "openai/gpt-6.1-sol" DONE "true" "$SHA" "sid-sol1" "$T/wt/sol1"
SESS="$SESS_SAVED"; JOBS="$JOBS_SAVED"
REPLAY_JOBS_DIR="$JOBS4" REPLAY_PI_SESSIONS="$SESS4" bash "$REPLAY" select --out "$OUT4" --total 30 >/dev/null || fail "select codex tree"
# cargo runs in the fiber source clone even when the caller is elsewhere
mkdir -p "$T/other-cwd"
(cd "$T/other-cwd" && bash "$REPLAY" run --out "$OUT4" --share codex --batch 3 >/dev/null) || fail "codex run exits 0"
grep -qF "$T/fiber-src/Cargo.toml" "$FLOG/cargo.log" || fail "cargo builds the fiber source from another cwd"
grep -qF "CARGO_TARGET_DIR=$OUT4/fiber-target" "$FLOG/cargo.log" || fail "cargo target stays under OUT from another cwd"
grep -q "no fiber model" "$OUT4/runs/sol-only/pending.txt" || fail "codex row pending"
[ ! -d "$OUT4/runs/sol-only/scratch" ] || fail "pending row never runs"
[ "$(ls "$FLOG"/run-fake-*.env | wc -l | tr -d ' ')" -eq 5 ] || fail "no delegate run for pending"

# muse row whose fiber id delegate models lacks stays pending
JOBS5="$T/jobs5"; SESS5="$T/sessions5"; OUT5="$T/out5"
mkdir -p "$JOBS5" "$SESS5"
SESS_SAVED="$SESS"; SESS="$SESS5"; JOBS_SAVED="$JOBS"; JOBS="$JOBS5"
make_session "sid-m5" "2026-10-03T00:00:00.000Z" "$T/wt/m5" "Muse brief.\\n\\n---\\n\\nEnd STATUS: DONE" >/dev/null
make_record "muse-only" "$MUSE_ID" DONE "true" "$SHA" "sid-m5" "$T/wt/m5"
SESS="$SESS_SAVED"; JOBS="$JOBS_SAVED"
REPLAY_JOBS_DIR="$JOBS5" REPLAY_PI_SESSIONS="$SESS5" bash "$REPLAY" select --out "$OUT5" --total 30 >/dev/null || fail "select muse tree"
FAKE_MODELS="$(printf 'ID BACKEND\n%s pi' "$MUSE_ID")" bash "$REPLAY" run --out "$OUT5" --share muse --batch 3 >/dev/null || fail "unavailable-model run exits 0"
grep -q "unavailable" "$OUT5/runs/muse-only/pending.txt" || fail "missing fiber id pending"
[ "$(ls "$FLOG"/run-fake-*.env | wc -l | tr -d ' ')" -eq 5 ] || fail "no delegate run when model unavailable"

# a failing fiber build stops the run before any replay
JOBS6="$T/jobs6"; SESS6="$T/sessions6"; OUT6="$T/out6"
mkdir -p "$JOBS6" "$SESS6" "$T/failbin"
printf '#!/bin/sh\nexit 1\n' >"$T/failbin/cargo"
chmod +x "$T/failbin/cargo"
SESS_SAVED="$SESS"; SESS="$SESS6"; JOBS_SAVED="$JOBS"; JOBS="$JOBS6"
make_session "sid-m6" "2026-10-03T00:00:00.000Z" "$T/wt/m6" "Muse brief.\\n\\n---\\n\\nEnd STATUS: DONE" >/dev/null
make_record "muse-fail" "$MUSE_ID" DONE "true" "$SHA" "sid-m6" "$T/wt/m6"
SESS="$SESS_SAVED"; JOBS="$JOBS_SAVED"
REPLAY_JOBS_DIR="$JOBS6" REPLAY_PI_SESSIONS="$SESS6" bash "$REPLAY" select --out "$OUT6" --total 30 >/dev/null || fail "select fail tree"
before="$(ls "$FLOG"/run-fake-*.env 2>/dev/null | wc -l | tr -d ' ')"
if PATH="$T/failbin:$PATH" bash "$REPLAY" run --out "$OUT6" --share muse --batch 3 2>/dev/null; then
  fail "failing build should stop the run"
else
  [ $? -eq 1 ] || fail "failing build exits 1"
fi
[ "$(ls "$FLOG"/run-fake-*.env 2>/dev/null | wc -l | tr -d ' ')" = "$before" ] || fail "no replay after build failure"

# an open seal stops the run before any replay
if REPLAY_SANDBOX_EXEC="$FBIN/sandbox-allow" bash "$REPLAY" run --out "$OUT6" --share muse --batch 3 2>/dev/null; then
  fail "open seal should stop the run"
else
  [ $? -eq 1 ] || fail "open seal exits 1"
fi
[ "$(ls "$FLOG"/run-fake-*.env 2>/dev/null | wc -l | tr -d ' ')" = "$before" ] || fail "no replay with open seal"
[ ! -e "$HOME/.replay-seal-probe" ] || fail "seal probe cleaned up"

# sibling-prefix paths survive the cwd rewrite; in-cwd paths keep their separator
JOBS7="$T/jobs7"; SESS7="$T/sessions7"; OUT7="$T/out7"
mkdir -p "$JOBS7" "$SESS7" "$T/wt/job-2"
printf '# sibling brief\n' >"$T/wt/job-2/other.md"
touch -d '2026-09-01T00:00:00Z' "$T/wt/job-2/other.md"
SESS_SAVED="$SESS"; SESS="$SESS7"; JOBS_SAVED="$JOBS"; JOBS="$JOBS7"
make_session "sid-sib" "2026-10-02T00:04:00.000Z" "$T/wt/job" "See $T/wt/job/NOTES.md and $T/wt/job-2/other.md.\\n\\n---\\n\\nEnd STATUS: DONE" >/dev/null
make_record "job-sib" "$MUSE_ID" DONE "true" "$SHA" "sid-sib" "$T/wt/job"
SESS="$SESS_SAVED"; JOBS="$JOBS_SAVED"
REPLAY_JOBS_DIR="$JOBS7" REPLAY_PI_SESSIONS="$SESS7" bash "$REPLAY" select --out "$OUT7" --total 30 >/dev/null || fail "select sibling tree"
bash "$REPLAY" run --out "$OUT7" --share muse --batch 3 >/dev/null || fail "sibling run exits 0"
grep -qF "$OUT7/runs/job-sib/scratch/NOTES.md" "$OUT7/runs/job-sib/prompt.md" || fail "in-cwd path keeps separator"
grep -qF "$OUT7/runs/job-sib/briefs/1-other.md" "$OUT7/runs/job-sib/prompt.md" || fail "sibling ref re-pointed at run brief"
grep -q "scratch-2" "$OUT7/runs/job-sib/prompt.md" && fail "sibling prefix corrupted"
grep -qF "$T/wt/job-2/other.md" "$OUT7/runs/job-sib/prompt.md" && fail "sibling ref original gone from prompt"

# replace_cwd rewrites only complete path prefixes: any sibling continuation
# (ASCII or not) survives; explicit delimiters and a sentence-ending "." bound.
sed -n '/^replace_cwd() {/,/^}/p' "$REPLAY" >"$T/replace_cwd.sh"
printf 'a /old/job/x /old/job-2/y /old/job+2/z /old/job\303\251/w `/old/job` (/old/job) /old/job. /old/job.bak "/old/job" /old/job\n/old/job' >"$T/rc.txt"
bash -c '. "$1"; replace_cwd "$2" /old/job /S' _ "$T/replace_cwd.sh" "$T/rc.txt" || fail "replace_cwd runs"
printf 'a /S/x /old/job-2/y /old/job+2/z /old/job\303\251/w `/S` (/S) /S. /old/job.bak "/S" /S\n/S' >"$T/rc.want"
cmp -s "$T/rc.txt" "$T/rc.want" || fail "replace_cwd rewrites only complete prefixes (got: $(cat "$T/rc.txt"))"

# --- seal probe: a pre-existing fixed-path file survives a sealed run ---
printf 'sentinel' >"$HOME/.replay-seal-probe"
bash "$REPLAY" run --out "$OUT7" --job job-sib --fresh >/dev/null || fail "sentinel run exits 0"
[ "$(cat "$HOME/.replay-seal-probe")" = "sentinel" ] || fail "pre-existing seal probe survives"
rm -f "$HOME/.replay-seal-probe"
[ -z "$(ls "$HOME"/.replay-seal-probe.* 2>/dev/null)" ] || fail "unique seal probe cleaned up"

# --- session header cwd wins over resume.cwd ---
JOBSH="$T/jobsh"; SESSH="$T/sessh"; OUTH="$T/outh"
mkdir -p "$JOBSH" "$SESSH"
HDRCWD="$T/wt/header-job"
SESS_SAVED="$SESS"; SESS="$SESSH"; JOBS_SAVED="$JOBS"; JOBS="$JOBSH"
make_session "sid-hdr" "2026-10-02T00:05:00.000Z" "$HDRCWD" "See $HDRCWD/NOTES.md.\\n\\n---\\n\\nEnd STATUS: DONE" >/dev/null
make_record "job-hdr" "$MUSE_ID" DONE "true" "$SHA" "sid-hdr" "/nonexistent/nowhere/xyz"
SESS="$SESS_SAVED"; JOBS="$JOBS_SAVED"
REPLAY_JOBS_DIR="$JOBSH" REPLAY_PI_SESSIONS="$SESSH" \
  bash "$REPLAY" select --out "$OUTH" --total 30 >/dev/null || fail "select header-cwd tree exits 0"
[ "$(wc -l <"$OUTH/manifest.tsv" | tr -d ' ')" -eq 1 ] || fail "header-cwd tree admits 1 row"
grep -q "^job-hdr"$'\t' "$OUTH/manifest.tsv" || fail "header-cwd row admitted"
grep -qF "$HDRCWD" "$OUTH/manifest.tsv" || fail "manifest records the header cwd"
grep -qF "aakshintala/fiber" "$OUTH/manifest.tsv" || fail "header cwd resolves the header repo"
grep -q "^job-hdr"$'\t' "$OUTH/skipped.tsv" && fail "header-cwd row not skipped"
bash "$REPLAY" run --out "$OUTH" --share muse --batch 3 >/dev/null || fail "header-cwd run exits 0"
grep -qF "$OUTH/runs/job-hdr/scratch" "$OUTH/runs/job-hdr/prompt.md" || fail "header path rewritten to scratch"
grep -qF "$HDRCWD" "$OUTH/runs/job-hdr/prompt.md" && fail "header original gone from prompt"
grep -qF "/nonexistent/nowhere/xyz" "$OUTH/runs/job-hdr/prompt.md" && fail "resume cwd never leaks into prompt"

# --- outward actions are detected by shim execution, not command text ---
sed -n '/^err() {/,/^}/p;/^sb_quote() {/,/^}/p;/^sh_quote() {/,/^}/p;/^clean_recorded_tmpdir() {/,/^}/p;/^write_seal() {/,/^}/p;/^collect_notes() {/,/^}/p;/^run_tmp() {/,/^}/p' "$REPLAY" >"$T/shim-funcs.sh"
SHIMT="$T/shimfix"
mkdir -p "$SHIMT/fakereal" "$SHIMT/runs/s1" "$SHIMT/out"
cat >"$SHIMT/fakereal/git" <<EOF
#!/bin/sh
printf 'real-git %s\n' "\$*" >>"$SHIMT/calls.log"
exit 0
EOF
cat >"$SHIMT/fakereal/curl" <<EOF
#!/bin/sh
printf 'real-curl %s\n' "\$*" >>"$SHIMT/calls.log"
exit 0
EOF
cat >"$SHIMT/fakereal/wget" <<EOF
#!/bin/sh
printf 'real-wget %s\n' "\$*" >>"$SHIMT/calls.log"
exit 0
EOF
chmod +x "$SHIMT/fakereal/git" "$SHIMT/fakereal/curl" "$SHIMT/fakereal/wget"
RUN_OUT="$SHIMT/out" RUN_REALTMP="${TMPDIR:-/tmp}" PATH="$SHIMT/fakereal:$PATH" \
  bash -c '. "$1"; write_seal "$2"' _ "$T/shim-funcs.sh" "$SHIMT/runs/s1" || fail "write_seal fixture runs"
[ -x "$SHIMT/runs/s1/shim/gh" ] || fail "gh shim written"
[ -x "$SHIMT/runs/s1/shim/git" ] || fail "git shim written"
[ -x "$SHIMT/runs/s1/shim/curl" ] || fail "curl shim written"
[ -x "$SHIMT/runs/s1/shim/wget" ] || fail "wget shim written"
grep -qF "$SHIMT/fakereal/git" "$SHIMT/runs/s1/shim/git" || fail "git shim bakes the real path"
SAVED_SHIM_PATH="$PATH"
PATH="$SHIMT/runs/s1/shim:$SHIMT/fakereal:$PATH"
(cd "$SHIMT" && git -C . push origin HEAD) || fail "git push passes to the real git"
grep -qF "git -C . push origin HEAD" "$SHIMT/runs/s1/outward.log" || fail "git -C . push logged"
grep -qF "real-git -C . push origin HEAD" "$SHIMT/calls.log" || fail "git push reaches the real git"
(cd "$SHIMT" && env git push) || fail "env git push passes through"
grep -qF "git push" "$SHIMT/runs/s1/outward.log" || fail "env git push logged"
grep -qF "real-git push" "$SHIMT/calls.log" || fail "env git push reaches the real git"
: >"$SHIMT/runs/s1/outward.log"; : >"$SHIMT/calls.log"
(cd "$SHIMT" && git status) || fail "git status passes through"
grep -q "status" "$SHIMT/runs/s1/outward.log" && fail "git status is not outward"
grep -qF "real-git status" "$SHIMT/calls.log" || fail "git status reaches the real git"
(cd "$SHIMT" && gh pr create) >/dev/null 2>&1 && fail "gh shim exits 1"
grep -qF "gh pr create" "$SHIMT/runs/s1/outward.log" || fail "gh pr create logged"
(cd "$SHIMT" && curl -s https://example.com) || fail "curl passes through"
grep -qF "curl -s https://example.com" "$SHIMT/runs/s1/outward.log" || fail "curl logged"
grep -qF "real-curl -s https://example.com" "$SHIMT/calls.log" || fail "curl reaches the real curl"
(cd "$SHIMT" && wget -q https://example.com) || fail "wget passes through"
grep -qF "wget -q https://example.com" "$SHIMT/runs/s1/outward.log" || fail "wget logged"
PATH="$SAVED_SHIM_PATH"
# a missing real binary logs and exits 127
mkdir -p "$SHIMT/nocurl" "$SHIMT/tools" "$SHIMT/runs/s2"
ln -s "$SHIMT/fakereal/git" "$SHIMT/nocurl/git"
ln -s "$SHIMT/fakereal/wget" "$SHIMT/nocurl/wget"
for t in mkdir cat chmod mktemp rm bash sed; do ln -s "$(command -v "$t")" "$SHIMT/tools/$t"; done
RUN_OUT="$SHIMT/out" RUN_REALTMP="${TMPDIR:-/tmp}" PATH="$SHIMT/nocurl:$SHIMT/tools" \
  bash -c '. "$1"; write_seal "$2"' _ "$T/shim-funcs.sh" "$SHIMT/runs/s2" || fail "write_seal without curl runs"
SAVED_SHIM_PATH="$PATH"
PATH="$SHIMT/runs/s2/shim:$SHIMT/nocurl:$PATH"
if (cd "$SHIMT" && curl -s https://example.com) >/dev/null 2>&1; then fail "curl without a real binary exits 127"; else [ $? -eq 127 ] || fail "curl without a real binary exits 127"; fi
grep -qF "curl -s https://example.com" "$SHIMT/runs/s2/outward.log" || fail "missing curl still logged"
PATH="$SAVED_SHIM_PATH"
# collect_notes: the execution log becomes notes, command text alone does not
CNOTES="$T/cnotes"; RCOUT="$T/cnotes-out"
mkdir -p "$CNOTES/scratch" "$RCOUT/runs/cn1"
printf '{"status":"DONE","resume":{"sessionId":"cn-sid-1"}}' >"$RCOUT/runs/cn1/record.json"
mkdir -p "$RCOUT/fiber-home/projects/p/sessions/cn-sid-1"
cat >"$RCOUT/fiber-home/projects/p/sessions/cn-sid-1/events.jsonl" <<EOF
{"kind":"tool_call_requested","session_id":"cn-sid-1","ts":1,"schema_version":1,"action_id":"c1","payload":{"name":"shell","arguments":{"command":"echo \\"example; gh pr create\\""}}}
{"kind":"tool_call_requested","session_id":"cn-sid-1","ts":2,"schema_version":1,"action_id":"c2","payload":{"name":"shell","arguments":{"command":"git push origin HEAD"}}}
{"kind":"tool_call_requested","session_id":"cn-sid-1","ts":3,"schema_version":1,"action_id":"c3","payload":{"name":"read","arguments":{"path":"$HOME/work/other/file.ts"}}}
{"kind":"tool_call_requested","session_id":"cn-sid-1","ts":4,"schema_version":1,"action_id":"c4","payload":{"name":"read","arguments":{"path":"$CNOTES/scratch/file.ts"}}}
EOF
printf 'gh pr create\ncurl -s u\n' >"$RCOUT/runs/cn1/outward.log"
RUN_OUT="$RCOUT" bash -c '. "$1"; collect_notes cn1 "$2/runs/cn1" "$3/scratch"' _ "$T/shim-funcs.sh" "$RCOUT" "$CNOTES" || fail "collect_notes runs"
grep -qF "note: outward: gh pr create" "$RCOUT/runs/cn1/notes.txt" || fail "outward log becomes notes"
grep -qF "note: outward: curl -s u" "$RCOUT/runs/cn1/notes.txt" || fail "curl log becomes notes"
grep -q "example;" "$RCOUT/runs/cn1/notes.txt" && fail "quoted gh text is not outward"
grep -q "push origin HEAD" "$RCOUT/runs/cn1/notes.txt" && fail "command text alone is not outward"
grep -q "work/other/file.ts" "$RCOUT/runs/cn1/notes.txt" || fail "outside-scratch path still noted"
grep -q "scratch/file.ts" "$RCOUT/runs/cn1/notes.txt" && fail "scratch path is not outward"

echo "run cases passed"

# --- Task 4: report and all ---
RJOBS="$T/rjobs"
RSESS="$T/rsessions"
ROUT="$T/rout"
mkdir -p "$RJOBS" "$RSESS" "$ROUT"
# pi session with a pi-stamp wall of 1.0s and thinking level LEVEL
mk_rsession() {
  local sid ts lvl stamp dir
  sid="$1"; ts="$2"; lvl="$3"; stamp="$4"
  dir="$RSESS/--$sid--"
  mkdir -p "$dir"
  {
    printf '{"type":"session","version":3,"id":"%s","timestamp":"%s","cwd":"/repo"}\n' "$sid" "$ts"
    printf '{"type":"thinking_level_change","id":"t","parentId":null,"timestamp":"%s","thinkingLevel":"%s"}\n' "$ts" "$lvl"
    [ -n "$stamp" ] && printf '{"type":"custom","customType":"pi-stamp","data":{"version":1,"startedAt":1000,"endedAt":%s},"id":"c","parentId":"t","timestamp":"%s"}\n' "$stamp" "$ts"
  } >"$dir/${ts}_${sid}.jsonl"
  printf '%s' "$dir/${ts}_${sid}.jsonl"
}
# pi record: ID STATUS GATEPASS COST IN OUT CR CW DUR
mk_pirec() {
  local id="$1" status="$2" gate="$3" cost="$4" in="$5" out="$6" cr="$7" cw="$8" dur="$9"
  local sid="rs-$id" gatejson
  if [ "$gate" = "none" ]; then gatejson="null"; else gatejson="{\"passed\":$gate,\"command\":\"g\",\"exitCode\":0,\"outputTail\":\"\"}"; fi
  jq -n --arg status "$status" --arg sid "$sid" --arg cost "$cost" \
    --argjson in "$in" --argjson out "$out" --argjson cr "$cr" --argjson cw "$cw" \
    --argjson dur "$dur" --argjson gate "$gatejson" \
    '{status:$status,
      result:{status:$status,model:"m",sessionId:$sid,backend:"pi",
        usage:{inputTokens:$in,outputTokens:$out,cacheReadTokens:$cr,cacheWriteTokens:$cw},
        costUsd:(if $cost=="null" then null else ($cost|tonumber) end),
        durationMs:$dur,gateResult:$gate,
        changeSet:{headBefore:"abc",headAfter:"abc"}},
      supervisorPid:1,
      resume:{model:"m",backend:"pi",cwd:"/repo",sessionId:$sid,gate:"g"}}' \
    >"$RJOBS/$id.json"
}
# fiber record: ID STATUS GATEPASS COST IN OUT CR DUR FSID
mk_frec() {
  local id="$1" status="$2" gate="$3" cost="$4" in="$5" out="$6" cr="$7" dur="$8" fsid="$9"
  local gatejson
  if [ "$gate" = "none" ]; then gatejson="null"; else gatejson="{\"passed\":$gate,\"command\":\"g\",\"exitCode\":0,\"outputTail\":\"\"}"; fi
  jq -n --arg status "$status" --arg fsid "$fsid" --arg cost "$cost" \
    --argjson in "$in" --argjson out "$out" --argjson cr "$cr" \
    --argjson dur "$dur" --argjson gate "$gatejson" \
    --arg model "fiber/opencode-go/muse-spark-1.3-contributor" --arg cwd "$ROUT/runs/$id/scratch" \
    '{status:$status,
      result:{status:$status,model:$model,sessionId:$fsid,backend:"fiber",
        usage:{inputTokens:$in,outputTokens:$out,cacheReadTokens:$cr,cacheWriteTokens:0},
        costUsd:($cost|tonumber),durationMs:$dur,gateResult:$gate,
        changeSet:{headBefore:"abc",headAfter:"abc"}},
      supervisorPid:1,
      resume:{model:$model,backend:"fiber",cwd:$cwd,sessionId:$fsid,gate:"g"}}' \
    >"$ROUT/runs/$id/record.json"
}
# manifest rows for seven jobs (E has no pi record and no fiber run)
SA="$(mk_rsession rs-jobA 2026-10-04T00:00:00.000Z high 2000)"
SB="$(mk_rsession rs-jobB 2026-10-04T00:01:00.000Z medium 2000)"
SC="$(mk_rsession rs-jobC 2026-10-04T00:02:00.000Z high '')"
SD="$(mk_rsession rs-jobD 2026-10-04T00:03:00.000Z high 2000)"
SF="$(mk_rsession rs-jobF 2026-10-04T00:04:00.000Z high 2000)"
SG="$(mk_rsession rs-jobG 2026-10-04T00:05:00.000Z high 2000)"
mk_pirec jobA DONE true 0.01 1000 100 500 0 null
mk_pirec jobB DONE true 0.02 2000 200 1000 0 null
mk_pirec jobC DONE false 0.03 3000 300 0 0 4000
mk_pirec jobD DONE true 0.04 4000 400 2000 0 null
mk_pirec jobF DONE true 0.04 4000 400 2000 0 null
mk_pirec jobG DONE true 0.05 5000 500 2500 0 null
FM="fiber/opencode-go/muse-spark-1.3-contributor"
{
  printf 'jobA\tmuse\tm\t%s\tr/ac\taaa\t%s\t/repo\t2026-10-04T00:00:00.000Z\n' "$FM" "$SA"
  printf 'jobB\tmuse\tm\t%s\tr/ac\taaa\t%s\t/repo\t2026-10-04T00:01:00.000Z\n' "$FM" "$SB"
  printf 'jobC\tmuse\tm\t%s\tr/ac\taaa\t%s\t/repo\t2026-10-04T00:02:00.000Z\n' "$FM" "$SC"
  printf 'jobD\tcodex\tm\t\tr/ac\taaa\t%s\t/repo\t2026-10-04T00:03:00.000Z\n' "$SD"
  printf 'jobE\tmuse\tm\t%s\tr/ac\taaa\t/none\t/repo\t2026-10-04T00:04:00.000Z\n' "$FM"
  printf 'jobF\tmuse\tm\t%s\tr/ac\taaa\t%s\t/repo\t2026-10-04T00:05:00.000Z\n' "$FM" "$SF"
  printf 'jobG\tmuse\tm\t%s\tr/ac\taaa\t%s\t/repo\t2026-10-04T00:06:00.000Z\n' "$FM" "$SG"
} >"$ROUT/manifest.tsv"
# mk_rsession with empty stamp must skip the custom line
[ "$(wc -l <"$SC")" -eq 2 ] || fail "empty stamp skips pi-stamp"
printf 'sx1\tsome reason\nsx2\tother reason\n' >"$ROUT/skipped.tsv"
mkdir -p "$ROUT/runs/jobA" "$ROUT/runs/jobB" "$ROUT/runs/jobC" "$ROUT/runs/jobF" "$ROUT/runs/jobG" "$ROUT/runs/jobD"
mk_frec jobA DONE true 0.02 1000 100 500 null fs-A
mk_frec jobB DONE false 0.03 2000 200 1000 null fs-B
mk_frec jobC ERROR none 0.05 3000 300 0 9000 fs-C
mk_frec jobF DONE true 0.05 4000 400 2000 null fs-F
mk_frec jobG DONE true 0.06 5000 500 2500 null fs-G
printf 'pending: no fiber model until aakshintala/fiber#311\n' >"$ROUT/runs/jobD/pending.txt"
printf 'fiber 0.0.0 (abc)\n' >"$ROUT/runs/jobA/version.txt"
printf 'note: outward attempt\n' >"$ROUT/runs/jobB/notes.txt"
mk_ev() {
  mkdir -p "$ROUT/fiber-home/projects/p/sessions/$1"
  printf '%s' "$2" >"$ROUT/fiber-home/projects/p/sessions/$1/events.jsonl"
}
mk_ev fs-A '{"kind":"fiber_started","session_id":"fs-A","ts":5000,"schema_version":1,"payload":{"version":"0.0.0","resumed":false}}
{"kind":"usage_recorded","session_id":"fs-A","ts":6000,"schema_version":1,"payload":{"tokens":{"input":1}}}
{"kind":"fiber_exited","session_id":"fs-A","ts":8000,"schema_version":1,"payload":{"exit_code":0}}'
mk_ev fs-B '{"kind":"fiber_started","session_id":"fs-B","ts":5000,"schema_version":1,"payload":{"version":"0.0.0","resumed":false}}
{"kind":"usage_recorded","session_id":"fs-B","ts":6000,"schema_version":1,"payload":{"thinkingLevel":"high","tokens":{"input":1}}}
{"kind":"tool_call_requested","session_id":"fs-B","ts":6100,"schema_version":1,"action_id":"a1","payload":{"name":"shell","arguments":{"command":"rm -rf /tmp/x"}}}
{"kind":"permission_resolved","session_id":"fs-B","ts":6200,"schema_version":1,"action_id":"a1","payload":{"decision":"deny","decided_by":"reviewer","reason":"dangerous"}}
{"kind":"permission_resolved","session_id":"fs-B","ts":6300,"schema_version":1,"action_id":"a9","payload":{"decision":"deny","decided_by":"standing_rule","reason":"rule match"}}
{"kind":"fiber_exited","session_id":"fs-B","ts":8000,"schema_version":1,"payload":{"exit_code":0}}'
mk_ev fs-C '{"kind":"fiber_started","session_id":"fs-C","ts":5000,"schema_version":1,"payload":{"version":"0.0.0","resumed":false}}'
mk_ev fs-F '{"kind":"fiber_started","session_id":"fs-F","ts":1000,"schema_version":1,"payload":{"version":"0.0.0","resumed":false}}
{"kind":"usage_recorded","session_id":"fs-F","ts":1100,"schema_version":1,"payload":{"tokens":{"input":1}}}
{"kind":"fiber_exited","session_id":"fs-F","ts":2000,"schema_version":1,"payload":{"exit_code":0}}'
mk_ev fs-G '{"kind":"fiber_started","session_id":"fs-G","ts":1000,"schema_version":1,"payload":{"version":"0.0.0","resumed":false}}
{"kind":"usage_recorded","session_id":"fs-G","ts":1100,"schema_version":1,"payload":{"tokens":{"input":1}}}
{"kind":"fiber_exited","session_id":"fs-G","ts":2000,"schema_version":1,"payload":{"exit_code":0}}'
cat >"$T/verdicts.tsv" <<'EOF'
jobB	failure	not-fiber	external outage
jobC	failure	not-fiber	pre-existing crash
jobB	a1	right	agreed
jobB	a9	right	agreed
EOF
REPLAY_JOBS_DIR="$RJOBS" bash "$REPLAY" report --out "$ROUT" --verdicts "$T/verdicts.tsv" >"$T/report-out.txt" || fail "report exits 0"
[ -f "$ROUT/results.md" ] || fail "report writes results.md"
cmp "$T/report-out.txt" "$ROUT/results.md" || fail "stdout equals results.md"
R="$T/report-out.txt"
grep -q '\$0\.010000' "$R" || fail "pi cost renders"
grep -q '\$0\.020000' "$R" || fail "fiber cost renders"
grep -q '33\.3%' "$R" || fail "cache-read share renders"
grep -q '1\.0s' "$R" || fail "pi-stamp wall renders"
grep -q '3\.0s' "$R" || fail "fiber wall renders"
grep -q '9\.0s' "$R" || fail "durationMs fallback renders"
grep -q '4\.0s' "$R" || fail "pi durationMs fallback renders"
grep -q '0\.0%' "$R" || fail "zero share renders"
grep -q 'fiber 3 passes vs pi 4 passes (need >= 3): met' "$R" || fail "gate criterion met"
grep -q 'median fiber \$0\.040000 vs median pi \$0\.030000 (need <= 1.2x): not met' "$R" || fail "cost criterion not met"
grep -q 'no fiber-caused failures: met' "$R" || fail "failure criterion met"
grep -q '2 denials, zero wrong: met' "$R" || fail "denial criterion met"
grep -q 'jobB a1: `shell {"command":"rm -rf /tmp/x"}` (decided by reviewer, reason: dangerous) verdict: right (agreed)' "$R" || fail "denial joins command"
grep -q 'jobB a9: `unknown`' "$R" || fail "unmatched denial renders unknown"
grep -q 'jobA: pi high / fiber fiber default' "$R" || fail "levels render"
grep -q 'jobB: pi medium / fiber high' "$R" || fail "fiber level from events"
grep -q 'jobB: note: outward attempt' "$R" || fail "row notes render"
grep -q '\- sx1: some reason' "$R" || fail "skip log renders"
grep -q 'pending: no fiber model' "$R" || fail "pending renders"
grep -q 'not run' "$R" || fail "unrun renders"
grep -q 'fiber 0.0.0 (abc)' "$R" || fail "fiber versions render"
# a genuine false gate renders as fail, never n/a
[ "$(awk -F'|' '$2==" jobC "{gsub(/ /,"",$5); print $5}' "$R")" = "fail" ] || fail "pi false gate renders fail"
[ "$(awk -F'|' '$2==" jobB "{gsub(/ /,"",$11); print $11}' "$R")" = "fail" ] || fail "fiber false gate renders fail"
[ "$(awk -F'|' '$2==" jobC "{gsub(/ /,"",$11); print $11}' "$R")" = "n/a" ] || fail "missing fiber gate renders n/a"
# tokens and cost are unknown without a usage_recorded event
[ "$(awk -F'|' '$2==" jobC "{gsub(/ /,"",$12); print $12}' "$R")" = "unknown" ] || fail "fiber cost unknown without usage_recorded"
# without verdicts the failure and denial criteria are unread
REPLAY_JOBS_DIR="$RJOBS" bash "$REPLAY" report --out "$ROUT" >"$T/report-bare.txt" || fail "bare report exits 0"
RB="$T/report-bare.txt"
grep -q '2 unread: not met' "$RB" || fail "unread failures block the bar"
grep -q 'unread: not met' "$RB" || fail "unread denials block the bar"
grep -q 'verdict: unread' "$RB" || fail "unread verdicts render"
# typo verdicts fail closed: neither failure nor denial counts as read
cat >"$T/verdicts-typo.tsv" <<'EOF'
jobB	failure	fibre	typo for fiber
jobC	failure	not-fiber	pre-existing crash
jobB	a1	rightt	typo for right
jobB	a9	right	agreed
EOF
REPLAY_JOBS_DIR="$RJOBS" bash "$REPLAY" report --out "$ROUT" --verdicts "$T/verdicts-typo.tsv" >"$T/report-typo.txt" || fail "typo report exits 0"
RT="$T/report-typo.txt"
grep -q 'invalid verdict: fibre' "$RT" || fail "failure typo renders invalid"
grep -q 'invalid verdict: rightt' "$RT" || fail "denial typo renders invalid"
grep -q 'Failures: .*unread.*: not met' "$RT" || fail "failure typo blocks the bar"
grep -q 'Denials: .*unread.*: not met' "$RT" || fail "denial typo blocks the bar"

# missing or ambiguous events leave fiber tokens and cost unknown
RJOBSH="$T/rjobsh"; RSESH="$T/rsesh"; ROUTH="$T/rout-h"
mkdir -p "$RJOBSH" "$RSESH" "$ROUTH" "$ROUTH/runs/jobH1" "$ROUTH/runs/jobH2"
OLD_RJOBS="$RJOBS"; OLD_ROUT="$ROUT"; OLD_RSESS="$RSESS"
RJOBS="$RJOBSH"; ROUT="$ROUTH"; RSESS="$RSESH"
SAH1="$(mk_rsession rs-jobH1 2026-10-04T00:00:00.000Z high 2000)"
SAH2="$(mk_rsession rs-jobH2 2026-10-04T00:01:00.000Z high 2000)"
mk_pirec jobH1 DONE true 0.01 100 10 50 0 null
mk_pirec jobH2 DONE true 0.01 100 10 50 0 null
mk_frec jobH1 DONE true 0.05 100 10 50 null fs-H1
mk_frec jobH2 DONE true 0.05 100 10 50 null fs-H2
RJOBS="$OLD_RJOBS"; ROUT="$OLD_ROUT"; RSESS="$OLD_RSESS"
{
  printf 'jobH1\tmuse\tm\t%s\tr/ac\taaa\t%s\t/repo\t2026-10-04T00:00:00.000Z\n' "$FM" "$SAH1"
  printf 'jobH2\tmuse\tm\t%s\tr/ac\taaa\t%s\t/repo\t2026-10-04T00:01:00.000Z\n' "$FM" "$SAH2"
} >"$ROUTH/manifest.tsv"
: >"$ROUTH/skipped.tsv"
mkdir -p "$ROUTH/fiber-home/projects/p1/sessions/fs-H2" "$ROUTH/fiber-home/projects/p2/sessions/fs-H2"
printf '%s' '{"kind":"usage_recorded","session_id":"fs-H2","ts":1,"schema_version":1,"payload":{}}' >"$ROUTH/fiber-home/projects/p1/sessions/fs-H2/events.jsonl"
printf '%s' '{"kind":"usage_recorded","session_id":"fs-H2","ts":1,"schema_version":1,"payload":{}}' >"$ROUTH/fiber-home/projects/p2/sessions/fs-H2/events.jsonl"
REPLAY_JOBS_DIR="$RJOBSH" bash "$REPLAY" report --out "$ROUTH" >"$T/report-h.txt" || fail "unknown-usage report exits 0"
[ "$(awk -F'|' '$2==" jobH1 "{gsub(/ /,"",$12); print $12}' "$T/report-h.txt")" = "unknown" ] || fail "missing events leave fiber cost unknown"
[ "$(awk -F'|' '$2==" jobH1 "{gsub(/ /,"",$13); print $13}' "$T/report-h.txt")" = "unknown/unknown/unknown" ] || fail "missing events leave fiber tokens unknown"
[ "$(awk -F'|' '$2==" jobH2 "{gsub(/ /,"",$12); print $12}' "$T/report-h.txt")" = "unknown" ] || fail "ambiguous events leave fiber cost unknown"
[ "$(awk -F'|' '$2==" jobH2 "{gsub(/ /,"",$13); print $13}' "$T/report-h.txt")" = "unknown/unknown/unknown" ] || fail "ambiguous events leave fiber tokens unknown"

# single-row median
ROUT8="$T/rout8"
mkdir -p "$ROUT8"
SA8="$(mk_rsession rs-jobS 2026-10-04T00:00:00.000Z high 2000)"
# mk_rsession writes under RSESS; move the pieces rout8 needs by hand:
cp "$SA8" "$ROUT8/sess.jsonl"
mk_pirec jobS DONE true 0.10 100 10 50 0 null
cp "$RJOBS/jobS.json" "$T/s8.json"
mkdir -p "$T/rjobs8"
cp "$T/s8.json" "$T/rjobs8/jobS.json"
{
  printf 'jobS\tmuse\tm\t%s\tr/ac\taaa\t%s\t/repo\t2026-10-04T00:00:00.000Z\n' "$FM" "$ROUT8/sess.jsonl"
} >"$ROUT8/manifest.tsv"
: >"$ROUT8/skipped.tsv"
mkdir -p "$ROUT8/runs/jobS"
# fiber record + events for the single row
OLDROUT="$ROUT"
ROUT="$ROUT8"
mk_frec jobS DONE true 0.11 100 10 50 null fs-S
ROUT="$OLDROUT"
mkdir -p "$ROUT8/fiber-home/projects/p/sessions/fs-S"
printf '%s' '{"kind":"usage_recorded","session_id":"fs-S","ts":1,"schema_version":1,"payload":{}}' >"$ROUT8/fiber-home/projects/p/sessions/fs-S/events.jsonl"
REPLAY_JOBS_DIR="$T/rjobs8" bash "$REPLAY" report --out "$ROUT8" >"$T/report8.txt" || fail "single-row report exits 0"
grep -q 'median fiber \$0\.110000 vs median pi \$0\.100000 (need <= 1.2x): met' "$T/report8.txt" || fail "single-row median compares"

# all: select, one batch, report on a fresh out
ROUT9="$T/rou t9"
REPLAY_JOBS_DIR="$JOBS6" REPLAY_PI_SESSIONS="$SESS6" \
  bash "$REPLAY" all --out "$ROUT9" --share muse >/dev/null || fail "all exits 0"
[ -f "$ROUT9/manifest.tsv" ] || fail "all selects"
[ -f "$ROUT9/runs/muse-fail/record.json" ] || fail "all runs one batch"
[ -f "$ROUT9/results.md" ] || fail "all reports"

echo "report cases passed"

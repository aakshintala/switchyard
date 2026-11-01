#!/usr/bin/env bash
# Tests for delegate/scripts/canary.sh, offline: a fake delegate, fake Fiber
# event logs and local git remotes (never the real ~/.fiber, ~/.cache, a live
# model or a real checkout). HOME and TMPDIR are temp dirs set here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CANARY="$SCRIPT_DIR/../delegate/scripts/canary.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# assert_clean_leaves_nothing TICKET OUT: clean exits 0 and leaves no
# canary/<ticket>-* branch, worktree or tracking file; a second clean exits 0.
assert_clean_leaves_nothing() {
  local ticket="$1" out="$2" clone="$HOME/work/fiber" side
  bash "$CANARY" clean "$ticket" --out "$out" || fail "clean $ticket exits 0"
  for side in pi fiber; do
    git -C "$clone" show-ref --verify --quiet "refs/heads/canary/$ticket-$side" \
      && fail "clean $ticket leaves no $side branch"
    [ ! -e "$HOME/work/fiber-canary-$ticket-$side" ] || fail "clean $ticket leaves no $side worktree"
    [ ! -f "$out/$side/worktree" ] || fail "clean $ticket removes $side/worktree"
  done
  git -C "$clone" worktree list --porcelain | grep -q "canary-$ticket-" \
    && fail "clean $ticket leaves no registered worktree"
  bash "$CANARY" clean "$ticket" --out "$out" || fail "second clean $ticket exits 0"
}

# Keep the test root outside /tmp and /private/tmp: canary.sh treats those
# as blanket allowed roots, so a HOME under /tmp (mktemp's default when the
# outer TMPDIR is unset, as on CI) would make the task-3 `$HOME/x` write
# contained instead of needs_out. $HOME is never under /tmp in practice.
T="$(mktemp -d "$(cd -P "${TMPDIR:-/tmp}" && pwd -P)/test-delegate-canary.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" TMPDIR="$T/tmp" XDG_CACHE_HOME="$T/cache" JOB_RECORD_SYSTEM_DIR="$T/no-system-jobs"
mkdir -p "$HOME" "$TMPDIR" "$XDG_CACHE_HOME" "$JOB_RECORD_SYSTEM_DIR"
# seed_extension ROOT PROVIDER EXT: ROOT/extensions/EXT holds exactly two
# regular files, providers/PROVIDER.json and extension.json.
seed_extension() {
  local root="$1" provider="$2" ext="$3"
  mkdir -p "$root/extensions/$ext/providers"
  printf '{"name": "%s"}\n' "$ext" >"$root/extensions/$ext/extension.json"
  printf '{"id": "%s"}\n' "$provider" >"$root/extensions/$ext/providers/$provider.json"
}

export FIBER_HOME="$T/fiber-home"
mkdir -p "$FIBER_HOME"
# The fake real home holds an opencode and a codex extension, so every run
# below finds its fiber arm's provider there (#830). Both providers read
# their credential from the environment, so the credential fail-fast lets
# every run below through.
seed_extension "$FIBER_HOME" opencode-go opencode
seed_extension "$FIBER_HOME" codex codex
printf '{"credential":{"env":"OPENCODE_API_KEY"},"reviewer_model":"test-reviewer"}\n' >"$FIBER_HOME/extensions/opencode/providers/opencode-go.json"
printf '{"credential":{"env":"CODEX_API_KEY"},"reviewer_model":"test-reviewer"}\n' >"$FIBER_HOME/extensions/codex/providers/codex.json"

# --- local origin (bare) and clone at $HOME/work/fiber (the defaults) ---
git init -q --bare "$T/upstream.git"
git init -q -b main "$T/seed"
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$T/seed" remote add origin "$T/upstream.git"
git -C "$T/seed" push -q origin main
git -C "$T/seed" branch --set-upstream-to=origin/main main 2>/dev/null || true
mkdir -p "$HOME/work"
git clone -q "$T/upstream.git" "$HOME/work/fiber"
BASE="$(git -C "$HOME/work/fiber" rev-parse origin/main)"

# --- fakes: delegate (run/watch), gh (logs, exits 1), git (logs, execs real) ---
FBIN="$T/fakebin"
FLOG="$T/fakelog"
mkdir -p "$FBIN" "$FLOG"
export FAKE_LOGDIR="$FLOG"
REAL_GIT="$(command -v git)"
cat >"$FBIN/delegate" <<EOF
#!/usr/bin/env bash
set -uo pipefail
REAL_GIT="$REAL_GIT"
cmd="\${1:-}"
if [ \$# -gt 0 ]; then shift; fi
case "\$cmd" in
  run)
    model=""; cwd=""; prompt=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --model) model="\$2"; shift 2 ;;
        --cwd) cwd="\$2"; shift 2 ;;
        --prompt-file) prompt="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'run %s %s\n' "\$model" "\$cwd" >>"\$FAKE_LOGDIR/calls.log"
    case "\$model" in
      fiber/*)
        printf '%s\n' "\${FIBER_HOME:-UNSET}" >>"\$FAKE_LOGDIR/fiber-home.log"
        if [ -n "\${FAKE_RESOLVE_HOME:-}" ]; then
          case "\${FIBER_HOME:-}" in
            /*) printf '%s\n' "\$FIBER_HOME" >>"\$FAKE_LOGDIR/fiber-home-resolved.log" ;;
            *) printf '%s\n' "\$(cd "\$cwd" && pwd)/\${FIBER_HOME:-UNSET}" >>"\$FAKE_LOGDIR/fiber-home-resolved.log" ;;
          esac
        fi ;;
    esac
    case "\$model" in
      fiber/*)
        if [ "\${CANARY_FAKE_FAIL:-}" = "fiber" ]; then exit 1; fi ;;
    esac
    id="job-\$\$-\$RANDOM"
    printf 'work by %s\n' "\$id" >"\$cwd/work.txt"
    touch "\$cwd/work-marker"
    case "\$model" in
      fiber/*) ;;
      *) touch "\$cwd/pass-marker" ;;
    esac
    "\$REAL_GIT" -C "\$cwd" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
    "\$REAL_GIT" -C "\$cwd" -c user.email=t@t -c user.name=t commit -qm "fake \$id" >/dev/null 2>&1
    sid="sid-\$id"
    mkdir -p "\$TMPDIR/delegate-jobs"
    case "\$model" in
      fiber/*) cost="\${FAKE_FIBER_COST:-0.04}" ;;
      *) cost="0.05" ;;
    esac
    # The job is RUNNING until its watch: run writes no result.
    jq -n --arg sid "\$sid" --arg model "\$model" --arg cwd "\$cwd" \
      --arg cost "\$cost" \
      '{status:"RUNNING", result:null, fakeCost:\$cost,
        supervisorPid:1,
        resume:{model:\$model,backend:"x",cwd:\$cwd,sessionId:\$sid,gate:"g"}}' \
      >"\$TMPDIR/delegate-jobs/\$id.json"
    case "\$model" in
      fiber/*)
        if [ -n "\${FAKE_EVENTS:-}" ]; then
          mkdir -p "\$FIBER_HOME/projects/p/sessions/\$sid"
          cp "\$FAKE_EVENTS" "\$FIBER_HOME/projects/p/sessions/\$sid/events.jsonl"
        fi ;;
    esac
    printf '%s\n' "\$id" ;;
  watch)
    # The delay is 0 unless a scenario sets FAKE_WATCH_SLEEP. Task 2 sets it
    # to 1 so the ordering check can see a backgrounded watch.
    printf 'watch %s\n' "\$*" >>"\$FAKE_LOGDIR/calls.log"
    sleep "\${FAKE_WATCH_SLEEP:-0}"
    job="\$TMPDIR/delegate-jobs/\$1.json"
    jq '.status="DONE" | .result={status:"DONE",model:.resume.model,sessionId:.resume.sessionId,backend:"x",
          usage:{inputTokens:1000,outputTokens:100,cacheReadTokens:500,cacheWriteTokens:0},
          costUsd:(.fakeCost|tonumber),durationMs:null,
          gateResult:null,
          changeSet:{headBefore:"abc",headAfter:"abc"}}' "\$job" >"\$job.tmp" \
      && mv "\$job.tmp" "\$job"
    printf 'watch-done %s\n' "\$*" >>"\$FAKE_LOGDIR/calls.log"
    exit 0 ;;
  *)
    echo "fake delegate: unknown command \$cmd" >&2
    exit 2 ;;
esac
EOF
chmod +x "$FBIN/delegate"
cat >"$FBIN/gh" <<EOF
#!/bin/sh
printf 'gh %s\n' "\$*" >>"$FAKE_LOGDIR/gh.log"
echo "gh disabled in test" >&2
exit 1
EOF
chmod +x "$FBIN/gh"
cat >"$FBIN/git" <<EOF
#!/bin/sh
printf 'git %s\n' "\$*" >>"$FAKE_LOGDIR/git.log"
# Simulate a branch deletion that fails (e.g. a locked ref).
if [ -n "\${CANARY_FAKE_BRANCH_DELETE_FAIL:-}" ]; then
  case " \$* " in
    *" branch -D "*) echo "fake git: cannot delete branch" >&2; exit 1 ;;
  esac
fi
# Simulate native 'worktree add -b' leaving its branch when checkout fails
# (e.g. an unwritable target): create the branch, then fail without a worktree.
fail_side="\${CANARY_FAKE_WORKTREE_FAIL:-}"
if [ -n "\$fail_side" ]; then
  case " \$* " in
    *" worktree add "*)
      case " \$* " in
        *"-\$fail_side "*|*"-\$fail_side")
          clone=""; branch=""; base=""
          prev=""
          for a in "\$@"; do
            case "\$prev" in
              -C) clone="\$a" ;;
              -b) branch="\$a" ;;
            esac
            prev="\$a"
          done
          for a in "\$@"; do base="\$a"; done
          if [ -n "\$clone" ] && [ -n "\$branch" ] && [ -n "\$base" ]; then
            $REAL_GIT -C "\$clone" branch "\$branch" "\$base" >/dev/null 2>&1 || true
          fi
          exit 1 ;;
      esac ;;
  esac
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$FBIN/git"
PATH="$FBIN:$PATH"
export PATH
export DELEGATE_BIN="$FBIN/delegate"

# --- Fiber stand-in: the binary every run uses (FIBER_BIN), which prints a
# version for `--version`. Kept off PATH so the no-binary case can drop it.
FIBER_STUB_DIR="$T/fiber-stub"
FIBER_STUB="$FIBER_STUB_DIR/fiber"
mkdir -p "$FIBER_STUB_DIR"
cat >"$FIBER_STUB" <<'EOF'
#!/bin/sh
if [ "$1" = "--version" ]; then echo "fiber 9.9.9-canary-test"; exit 0; fi
exit 1
EOF
chmod +x "$FIBER_STUB"
export FIBER_BIN="$FIBER_STUB"

printf 'Do the thing.\n' >"$T/brief.md"

# --- Task 2 fixture: main lines, reviewer lines, an extension line, a dupe generation_id ---
FAKE_TMPDIR="$TMPDIR"
cat >"$T/ev2.jsonl" <<EOF
{"kind":"usage_recorded","session_id":"s1","ts":1,"schema_version":1,"action_id":"a1","seq":1,"payload":{"generation_id":"g1","model":"m","tokens":{"input":10,"output":1,"cache_read":1,"cache_write":{}},"cost":0.25}}
{"kind":"usage_recorded","session_id":"s1","ts":2,"schema_version":1,"seq":2,"payload":{"generation_id":"gR","model":"m","tokens":{"input":200,"output":20,"cache_read":30,"cache_write":{"ephemeral":10}},"cost":0.125}}
{"kind":"usage_recorded","session_id":"s1","ts":3,"schema_version":1,"action_id":"a2","seq":3,"payload":{"generation_id":"gE","model":"m","tokens":{"input":10,"output":1,"cache_read":1,"cache_write":{}},"cost":0.25,"extension":"ext1"}}
{"kind":"usage_recorded","session_id":"s1","ts":4,"schema_version":1,"action_id":"a3","seq":4,"payload":{"generation_id":"g1","model":"m","tokens":{"input":100,"output":10,"cache_read":50,"cache_write":{}},"cost":0.5}}
{"kind":"usage_recorded","session_id":"s1","ts":5,"schema_version":1,"action_id":"a4","seq":5,"payload":{"generation_id":"gC","model":"m","tokens":{"input":1,"output":1,"cache_read":1,"cache_write":{}},"cost":0.125,"origin_session_id":"s-del"}}
{"kind":"tool_call_requested","session_id":"s1","ts":6,"schema_version":1,"action_id":"r1","seq":6,"payload":{"name":"bash","arguments":{"command":"cargo test"}}}
{"kind":"permission_resolved","session_id":"s1","ts":7,"schema_version":1,"action_id":"r1","seq":7,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":8,"schema_version":1,"action_id":"r2","seq":8,"payload":{"name":"write","arguments":{"path":"$FAKE_TMPDIR/note.txt"}}}
{"kind":"permission_resolved","session_id":"s1","ts":9,"schema_version":1,"action_id":"r2","seq":9,"payload":{"decision":"allow","decided_by":"reviewer"}}
EOF

# --- Task 2: happy-path run ---
OUT="$T/out"
FAKE_WATCH_SLEEP=1 FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 223 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUT" || fail "canary run exits 0"

# layout
for side in pi fiber; do
  for f in worktree diff.patch gate.log gate.exit metrics.json prompt.md; do
    [ -f "$OUT/$side/$f" ] || fail "$side/$f exists"
  done
done
[ -f "$OUT/summary.md" ] || fail "summary.md exists"

# worktree files point at the two fresh worktrees
PI_WT="$(cat "$OUT/pi/worktree")"
FIBER_WT="$(cat "$OUT/fiber/worktree")"
[ "$PI_WT" = "$HOME/work/fiber-canary-223-pi" ] || fail "pi worktree path ($PI_WT)"
[ "$FIBER_WT" = "$HOME/work/fiber-canary-223-fiber" ] || fail "fiber worktree path ($FIBER_WT)"
[ -d "$PI_WT" ] && [ -d "$FIBER_WT" ] || fail "worktrees exist"
[ "$(git -C "$PI_WT" rev-parse HEAD)" != "$BASE" ] || fail "pi worktree has the fake commit"
[ "$(git -C "$FIBER_WT" rev-parse HEAD)" != "$BASE" ] || fail "fiber worktree has the fake commit"
[ -s "$OUT/pi/diff.patch" ] && [ -s "$OUT/fiber/diff.patch" ] || fail "diffs are non-empty"
[ "$(cat "$OUT/pi/gate.exit")" = "0" ] || fail "pi gate passes"
[ "$(cat "$OUT/fiber/gate.exit")" = "0" ] || fail "fiber gate passes"

# prompt wrapper: brief text, no-push line, own worktree and branch
for spec in "pi:$PI_WT" "fiber:$FIBER_WT"; do
  side="${spec%%:*}"; wt="${spec#*:}"
  grep -q "Do the thing" "$OUT/$side/prompt.md" || fail "$side prompt keeps the brief"
  grep -q "Canary run: work only in $wt" "$OUT/$side/prompt.md" || fail "$side prompt names its worktree"
  grep -q "canary/223-$side" "$OUT/$side/prompt.md" || fail "$side prompt names its branch"
  grep -q "Do not push" "$OUT/$side/prompt.md" || fail "$side prompt forbids pushing"
done

# every metrics.json key, both sides
for side in pi fiber; do
  jq -e 'has("side") and has("outcome") and has("job_id") and has("model")
    and has("base") and has("dirty") and has("wall_ms") and has("tokens")
    and has("cost") and has("reviewed_calls") and has("denials")
    and has("sandbox") and has("per_review_tokens_est") and has("notes")' \
    "$OUT/$side/metrics.json" >/dev/null || fail "$side metrics has every key"
  jq -e '.tokens | has("input") and has("output") and has("cache_read")' \
    "$OUT/$side/metrics.json" >/dev/null || fail "$side tokens keys"
  jq -e '.cost | has("total") and has("main") and has("reviewer")' \
    "$OUT/$side/metrics.json" >/dev/null || fail "$side cost keys"
  jq -e '.sandbox.contained.count != null and .sandbox.needs_out.count != null
    and .sandbox.unknown.count != null' \
    "$OUT/$side/metrics.json" >/dev/null || fail "$side sandbox keys"
done

# shared base, clean tree, job records
[ "$(jq -r .base "$OUT/pi/metrics.json")" = "$BASE" ] || fail "pi base is origin/main"
[ "$(jq -r .base "$OUT/fiber/metrics.json")" = "$BASE" ] || fail "fiber base matches pi"
[ "$(jq -r .dirty "$OUT/pi/metrics.json")" = "false" ] || fail "pi tree clean"
[ "$(jq -r .dirty "$OUT/fiber/metrics.json")" = "false" ] || fail "fiber tree clean"
[ "$(jq -r .outcome "$OUT/pi/metrics.json")" = "DONE" ] || fail "pi outcome DONE"
[ "$(jq -r .outcome "$OUT/fiber/metrics.json")" = "DONE" ] || fail "fiber outcome DONE"
[ "$(jq -r .model "$OUT/pi/metrics.json")" = "opencode-go/muse-spark-1.3-contributor" ] || fail "pi model"
[ "$(jq -r .model "$OUT/fiber/metrics.json")" = "fiber/opencode-go/muse-spark-1.3-contributor" ] || fail "fiber model"
PI_ID="$(jq -r .job_id "$OUT/pi/metrics.json")"
FIBER_ID="$(jq -r .job_id "$OUT/fiber/metrics.json")"
[ -n "$PI_ID" ] && [ -f "$TMPDIR/delegate-jobs/$PI_ID.json" ] || fail "pi record exists"
[ -n "$FIBER_ID" ] && [ -f "$TMPDIR/delegate-jobs/$FIBER_ID.json" ] || fail "fiber record exists"
jq -e '(.wall_ms | type) == "number"' "$OUT/pi/metrics.json" >/dev/null || fail "pi wall is a number"
jq -e '(.wall_ms | type) == "number"' "$OUT/fiber/metrics.json" >/dev/null || fail "fiber wall is a number"

# tokens and total cost come from the record
[ "$(jq -r .tokens.input "$OUT/pi/metrics.json")" = "1000" ] || fail "pi tokens in"
[ "$(jq -r .tokens.output "$OUT/fiber/metrics.json")" = "100" ] || fail "fiber tokens out"
[ "$(jq -r .tokens.cache_read "$OUT/pi/metrics.json")" = "500" ] || fail "pi tokens cache-read"
[ "$(jq -r .cost.total "$OUT/pi/metrics.json")" = "0.05" ] || fail "pi total cost"
[ "$(jq -r .cost.total "$OUT/fiber/metrics.json")" = "0.04" ] || fail "fiber total cost"

# reviewer split: dupe g1 folds to its latest line; extension and delegate copy count as main
[ "$(jq -r .cost.main "$OUT/fiber/metrics.json")" = "0.875" ] || fail "fiber main cost 0.875"
[ "$(jq -r .cost.reviewer "$OUT/fiber/metrics.json")" = "0.125" ] || fail "fiber reviewer cost"
[ "$(jq -r .cost.main "$OUT/pi/metrics.json")" = "0.05" ] || fail "pi main equals total"
[ "$(jq -r .cost.reviewer "$OUT/pi/metrics.json")" = "0" ] || fail "pi reviewer is 0"
[ "$(jq -r .reviewed_calls "$OUT/fiber/metrics.json")" = "2" ] || fail "fiber reviewed calls"
[ "$(jq -r .reviewed_calls "$OUT/pi/metrics.json")" = "0" ] || fail "pi reviewed calls 0"
[ "$(jq -r .per_review_tokens_est "$OUT/fiber/metrics.json")" = "130" ] || fail "fiber per-review tokens"
[ "$(jq -r .per_review_tokens_est "$OUT/pi/metrics.json")" = "null" ] || fail "pi per-review null"
[ "$(jq -r '.denials | length' "$OUT/fiber/metrics.json")" = "0" ] || fail "fiber no denials"
[ "$(jq -r '.denials | length' "$OUT/pi/metrics.json")" = "0" ] || fail "pi no denials"
[ "$(jq -r .sandbox.contained.count "$OUT/fiber/metrics.json")" = "2" ] || fail "fiber contained 2"
[ "$(jq -r .sandbox.needs_out.count "$OUT/fiber/metrics.json")" = "0" ] || fail "fiber needs_out 0"
[ "$(jq -r .sandbox.unknown.count "$OUT/fiber/metrics.json")" = "0" ] || fail "fiber unknown 0"
[ "$(jq -r .sandbox.contained.count "$OUT/pi/metrics.json")" = "0" ] || fail "pi sandbox zeros"
[ "$(jq -r '.notes | length' "$OUT/pi/metrics.json")" = "0" ] || fail "pi notes empty"

# sequential (#244): Fiber's run starts only after pi's job has finished.
# assert_order PI_MODEL FIBER_MODEL PI_ID FIBER_ID PI_WT FIBER_WT: the call
# log holds exactly run pi, watch pi, watch-done pi, run fiber, watch fiber,
# watch-done fiber, in that order.
assert_order() {
  local log="$FLOG/calls.log"
  [ "$(wc -l <"$log" | tr -d ' ')" = "6" ] || fail "six delegate calls per canary run"
  [ "$(sed -n 1p "$log")" = "run $1 $5" ] || fail "pi run is the first call"
  [ "$(sed -n 2p "$log")" = "watch $3" ] || fail "pi watch follows pi run"
  [ "$(sed -n 3p "$log")" = "watch-done $3" ] || fail "pi job finishes before Fiber starts"
  [ "$(sed -n 4p "$log")" = "run $2 $6" ] || fail "fiber run starts after pi's job finished"
  [ "$(sed -n 5p "$log")" = "watch $4" ] || fail "fiber watch follows fiber run"
  [ "$(sed -n 6p "$log")" = "watch-done $4" ] || fail "fiber job finishes"
}
assert_order "opencode-go/muse-spark-1.3-contributor" \
  "fiber/opencode-go/muse-spark-1.3-contributor" "$PI_ID" "$FIBER_ID" "$PI_WT" "$FIBER_WT"

# summary table
grep -q '^# Canary 223' "$OUT/summary.md" || fail "summary heading"
grep -q "$BASE" "$OUT/summary.md" || fail "summary base"
grep -q '| outcome | DONE | DONE |' "$OUT/summary.md" || fail "summary outcome row"
grep -q '| gate | pass | pass |' "$OUT/summary.md" || fail "summary gate row"
grep -q '| reviewed calls | 0 | 2 |' "$OUT/summary.md" || fail "summary reviewed row"

echo "task 2 cases passed"

# --- Models (#244): --pi-model and --fiber-model reach delegate run; the
# metrics and the summary name each side's model; a report of a run whose
# metrics.json has no model still rebuilds, naming it unknown.
: >"$FLOG/calls.log"
OUT2="$T/out-models"
FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 224 "$T/brief.md" \
  --gate 'test -f work-marker' \
  --pi-model openai/gpt-6-luna:medium --fiber-model fiber/codex/gpt-6-luna \
  --out "$OUT2" || fail "canary run with model flags exits 0"
PI_WT2="$(cat "$OUT2/pi/worktree")"
FIBER_WT2="$(cat "$OUT2/fiber/worktree")"
PI_ID2="$(jq -r .job_id "$OUT2/pi/metrics.json")"
FIBER_ID2="$(jq -r .job_id "$OUT2/fiber/metrics.json")"
[ "$(jq -r .model "$OUT2/pi/metrics.json")" = "openai/gpt-6-luna:medium" ] || fail "pi metrics model from --pi-model"
[ "$(jq -r .model "$OUT2/fiber/metrics.json")" = "fiber/codex/gpt-6-luna" ] || fail "fiber metrics model from --fiber-model"
# This check is not race-sensitive: the fake watch has no delay here (FAKE_WATCH_SLEEP unset).
# Task 2 alone pins backgrounded-watch ordering.
assert_order "openai/gpt-6-luna:medium" "fiber/codex/gpt-6-luna" \
  "$PI_ID2" "$FIBER_ID2" "$PI_WT2" "$FIBER_WT2"
grep -q '| model | openai/gpt-6-luna:medium | fiber/codex/gpt-6-luna |' "$OUT2/summary.md" \
  || fail "summary names each side's model"

# a run with no model in its metrics.json: report still rebuilds it
REPM2="$T/rep-no-model"
cp -R "$OUT2" "$REPM2"
jq 'del(.model)' "$OUT2/pi/metrics.json" >"$REPM2/pi/metrics.json"
bash "$CANARY" report 224 --out "$REPM2" || fail "report of a run without model exits 0"
grep -q '| model | unknown | fiber/codex/gpt-6-luna |' "$REPM2/summary.md" \
  || fail "report names a missing model unknown"
assert_clean_leaves_nothing 224 "$OUT2"

echo "model cases passed"

# --- Thinking levels: --thinking L appends :L to both arms' models. A run
# without the flag appends nothing, already pinned by the Task 2 happy path's
# assert_order on the unsuffixed ids. ---
: >"$FLOG/calls.log"
OUT_THINK="$T/out-thinking"
FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 245 "$T/brief.md" \
  --gate 'test -f work-marker' --thinking high --out "$OUT_THINK" || fail "canary run with --thinking high exits 0"
PI_WT_THINK="$(cat "$OUT_THINK/pi/worktree")"
FIBER_WT_THINK="$(cat "$OUT_THINK/fiber/worktree")"
[ "$(jq -r .model "$OUT_THINK/pi/metrics.json")" = "opencode-go/muse-spark-1.3-contributor:high" ] || fail "pi metrics model has :high"
[ "$(jq -r .model "$OUT_THINK/fiber/metrics.json")" = "fiber/opencode-go/muse-spark-1.3-contributor:high" ] || fail "fiber metrics model has :high"
# Ordering is pinned by the Task 2 happy path alone; these cases assert
# recorded model arguments and must not depend on the watch delay.
grep -q "^run opencode-go/muse-spark-1.3-contributor:high $PI_WT_THINK$" "$FLOG/calls.log" \
  || fail "pi run records the :high model"
grep -q "^run fiber/opencode-go/muse-spark-1.3-contributor:high $FIBER_WT_THINK$" "$FLOG/calls.log" \
  || fail "fiber run records the :high model"
grep -q '| model | opencode-go/muse-spark-1.3-contributor:high | fiber/opencode-go/muse-spark-1.3-contributor:high |' "$OUT_THINK/summary.md" \
  || fail "summary names the suffixed models"
assert_clean_leaves_nothing 245 "$OUT_THINK"

# The flag applies wherever it sits among the model flags, so both arms get
# it even when named before them.
: >"$FLOG/calls.log"
OUT_LOW="$T/out-low"
FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 246 "$T/brief.md" \
  --gate 'test -f work-marker' \
  --thinking low --pi-model opencode-go/muse-spark-1.3-contributor --fiber-model fiber/opencode-go/muse-spark-1.3-contributor \
  --out "$OUT_LOW" || fail "canary run with --thinking low exits 0"
PI_WT_LOW="$(cat "$OUT_LOW/pi/worktree")"
FIBER_WT_LOW="$(cat "$OUT_LOW/fiber/worktree")"
[ "$(jq -r .model "$OUT_LOW/pi/metrics.json")" = "opencode-go/muse-spark-1.3-contributor:low" ] || fail "pi metrics model has :low"
[ "$(jq -r .model "$OUT_LOW/fiber/metrics.json")" = "fiber/opencode-go/muse-spark-1.3-contributor:low" ] || fail "fiber metrics model has :low"
# Ordering is pinned by the Task 2 happy path alone; these cases assert
# recorded model arguments and must not depend on the watch delay.
grep -q "^run opencode-go/muse-spark-1.3-contributor:low $PI_WT_LOW$" "$FLOG/calls.log" \
  || fail "pi run records the :low model"
grep -q "^run fiber/opencode-go/muse-spark-1.3-contributor:low $FIBER_WT_LOW$" "$FLOG/calls.log" \
  || fail "fiber run records the :low model"
assert_clean_leaves_nothing 246 "$OUT_LOW"

# A missing or empty value is a usage error before any worktree is cut.
if bash "$CANARY" run 247 "$T/brief.md" --gate true --out "$T/out-bad" --thinking 2>/dev/null; then
  fail "missing --thinking value should not exit 0"
else
  [ $? -eq 2 ] || fail "missing --thinking value exits 2"
fi
[ ! -e "$T/out-bad/pi" ] || fail "missing --thinking value cuts no worktree"
if bash "$CANARY" run 247 "$T/brief.md" --gate true --out "$T/out-bad" --thinking "" 2>/dev/null; then
  fail "empty --thinking value should not exit 0"
else
  [ $? -eq 2 ] || fail "empty --thinking value exits 2"
fi
[ ! -e "$T/out-bad/pi" ] || fail "empty --thinking value cuts no worktree"

echo "thinking cases passed"

# --- Task 3 fixture: every sandbox class, plus one deny ---
cat >"$T/ev3.jsonl" <<EOF
{"kind":"usage_recorded","session_id":"s1","ts":1,"schema_version":1,"action_id":"a0","seq":1,"payload":{"generation_id":"gM","model":"m","tokens":{"input":10,"output":1,"cache_read":1,"cache_write":{}},"cost":1}}
{"kind":"usage_recorded","session_id":"s1","ts":2,"schema_version":1,"seq":2,"payload":{"generation_id":"gR","model":"m","tokens":{"input":2000,"output":100,"cache_read":150,"cache_write":{"warm":50}},"cost":0.5}}
{"kind":"tool_call_requested","session_id":"s1","ts":3,"schema_version":1,"action_id":"c1","seq":3,"payload":{"name":"bash","arguments":{"command":"cargo test"}}}
{"kind":"permission_resolved","session_id":"s1","ts":4,"schema_version":1,"action_id":"c1","seq":4,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":5,"schema_version":1,"action_id":"c2","seq":5,"payload":{"name":"write","arguments":{"path":"\$TMPDIR/x.txt"}}}
{"kind":"permission_resolved","session_id":"s1","ts":6,"schema_version":1,"action_id":"c2","seq":6,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":7,"schema_version":1,"action_id":"n1","seq":7,"payload":{"name":"bash","arguments":{"command":"curl https://example.com"}}}
{"kind":"permission_resolved","session_id":"s1","ts":8,"schema_version":1,"action_id":"n1","seq":8,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":9,"schema_version":1,"action_id":"n2","seq":9,"payload":{"name":"bash","arguments":{"command":"git push origin main"}}}
{"kind":"permission_resolved","session_id":"s1","ts":10,"schema_version":1,"action_id":"n2","seq":10,"payload":{"decision":"deny","decided_by":"reviewer","reason":"no pushing"}}
{"kind":"tool_call_requested","session_id":"s1","ts":11,"schema_version":1,"action_id":"n3","seq":11,"payload":{"name":"bash","arguments":{"command":"echo x > /etc/foo"}}}
{"kind":"permission_resolved","session_id":"s1","ts":12,"schema_version":1,"action_id":"n3","seq":12,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":13,"schema_version":1,"action_id":"n4","seq":13,"payload":{"name":"write","arguments":{"path":"\$HOME/x"}}}
{"kind":"permission_resolved","session_id":"s1","ts":14,"schema_version":1,"action_id":"n4","seq":14,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":15,"schema_version":1,"action_id":"u1","seq":15,"payload":{"name":"bash","arguments":{"command":"cat /etc/hosts | python3 -"}}}
{"kind":"permission_resolved","session_id":"s1","ts":16,"schema_version":1,"action_id":"u1","seq":16,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":17,"schema_version":1,"action_id":"n5","seq":17,"payload":{"name":"bash","arguments":{"command":"git -C \$PWD fetch origin"}}}
{"kind":"permission_resolved","session_id":"s1","ts":18,"schema_version":1,"action_id":"n5","seq":18,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":19,"schema_version":1,"action_id":"n6","seq":19,"payload":{"name":"bash","arguments":{"command":"git -c foo.bar=baz fetch origin"}}}
{"kind":"permission_resolved","session_id":"s1","ts":20,"schema_version":1,"action_id":"n6","seq":20,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":21,"schema_version":1,"action_id":"n7","seq":21,"payload":{"name":"bash","arguments":{"command":"git --git-dir=\$TMPDIR/g.git fetch origin"}}}
{"kind":"permission_resolved","session_id":"s1","ts":22,"schema_version":1,"action_id":"n7","seq":22,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":23,"schema_version":1,"action_id":"n8","seq":23,"payload":{"name":"bash","arguments":{"command":"git --work-tree \$TMPDIR/wt pull"}}}
{"kind":"permission_resolved","session_id":"s1","ts":24,"schema_version":1,"action_id":"n8","seq":24,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":25,"schema_version":1,"action_id":"n9","seq":25,"payload":{"name":"bash","arguments":{"command":"git --no-pager push origin main"}}}
{"kind":"permission_resolved","session_id":"s1","ts":26,"schema_version":1,"action_id":"n9","seq":26,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":27,"schema_version":1,"action_id":"u2","seq":27,"payload":{"name":"bash","arguments":{"command":"cat </etc/hosts"}}}
{"kind":"permission_resolved","session_id":"s1","ts":28,"schema_version":1,"action_id":"u2","seq":28,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":29,"schema_version":1,"action_id":"n10","seq":29,"payload":{"name":"bash","arguments":{"command":"echo hi>/etc/out"}}}
{"kind":"permission_resolved","session_id":"s1","ts":30,"schema_version":1,"action_id":"n10","seq":30,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":31,"schema_version":1,"action_id":"n11","seq":31,"payload":{"name":"bash","arguments":{"command":"echo hi >>/etc/out"}}}
{"kind":"permission_resolved","session_id":"s1","ts":32,"schema_version":1,"action_id":"n11","seq":32,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":33,"schema_version":1,"action_id":"n12","seq":33,"payload":{"name":"bash","arguments":{"command":"echo hi 2>/etc/err"}}}
{"kind":"permission_resolved","session_id":"s1","ts":34,"schema_version":1,"action_id":"n12","seq":34,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":35,"schema_version":1,"action_id":"c3","seq":35,"payload":{"name":"bash","arguments":{"command":"echo hi 2>/dev/null"}}}
{"kind":"permission_resolved","session_id":"s1","ts":36,"schema_version":1,"action_id":"c3","seq":36,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":37,"schema_version":1,"action_id":"u3","seq":37,"payload":{"name":"bash","arguments":{"command":"cat /etc/hosts|cat"}}}
{"kind":"permission_resolved","session_id":"s1","ts":38,"schema_version":1,"action_id":"u3","seq":38,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":39,"schema_version":1,"action_id":"u4","seq":39,"payload":{"name":"bash","arguments":{"command":"echo a;cat /etc/hosts"}}}
{"kind":"permission_resolved","session_id":"s1","ts":40,"schema_version":1,"action_id":"u4","seq":40,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":41,"schema_version":1,"action_id":"u5","seq":41,"payload":{"name":"bash","arguments":{"command":"true && cat /etc/hosts"}}}
{"kind":"permission_resolved","session_id":"s1","ts":42,"schema_version":1,"action_id":"u5","seq":42,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":43,"schema_version":1,"action_id":"u6","seq":43,"payload":{"name":"bash","arguments":{"command":"(cat /etc/hosts)"}}}
{"kind":"permission_resolved","session_id":"s1","ts":44,"schema_version":1,"action_id":"u6","seq":44,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":45,"schema_version":1,"action_id":"u7","seq":45,"payload":{"name":"bash","arguments":{"command":"x=/etc/y"}}}
{"kind":"permission_resolved","session_id":"s1","ts":46,"schema_version":1,"action_id":"u7","seq":46,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"permission_resolved","session_id":"s1","ts":47,"schema_version":1,"action_id":"u9","seq":47,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":48,"schema_version":1,"action_id":"n13","seq":48,"payload":{"name":"bash","arguments":{"command":"git -C/tmp fetch origin"}}}
{"kind":"permission_resolved","session_id":"s1","ts":49,"schema_version":1,"action_id":"n13","seq":49,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":50,"schema_version":1,"action_id":"n14","seq":50,"payload":{"name":"bash","arguments":{"command":"git -cfoo.bar=baz fetch origin"}}}
{"kind":"permission_resolved","session_id":"s1","ts":51,"schema_version":1,"action_id":"n14","seq":51,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":52,"schema_version":1,"action_id":"n15","seq":52,"payload":{"name":"bash","arguments":{"command":"git -C \"/tmp/a b\" fetch origin"}}}
{"kind":"permission_resolved","session_id":"s1","ts":53,"schema_version":1,"action_id":"n15","seq":53,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":54,"schema_version":1,"action_id":"c4","seq":54,"payload":{"name":"bash","arguments":{"command":"git log --oneline"}}}
{"kind":"permission_resolved","session_id":"s1","ts":55,"schema_version":1,"action_id":"c4","seq":55,"payload":{"decision":"allow","decided_by":"reviewer"}}
EOF

# --- Task 3: the gate passes on pi only; the run still exits 0 ---
OUT3="$T/out3"
FAKE_EVENTS="$T/ev3.jsonl" bash "$CANARY" run 224 "$T/brief.md" \
  --gate 'test -f pass-marker' --out "$OUT3" || fail "canary run exits 0 with a failing gate"
[ "$(cat "$OUT3/pi/gate.exit")" = "0" ] || fail "pi gate passes"
[ "$(cat "$OUT3/fiber/gate.exit")" = "1" ] || fail "fiber gate fails"
grep -q '| gate | pass | fail |' "$OUT3/summary.md" || fail "summary gate row"

M3="$OUT3/fiber/metrics.json"
[ "$(jq -r .cost.main "$M3")" = "1" ] || fail "task3 main cost"
[ "$(jq -r .cost.reviewer "$M3")" = "0.5" ] || fail "task3 reviewer cost"
[ "$(jq -r .reviewed_calls "$M3")" = "27" ] || fail "task3 reviewed calls"
[ "$(jq -r .per_review_tokens_est "$M3")" = "85.18518518518519" ] || fail "task3 per-review tokens"
[ "$(jq -r .sandbox.contained.count "$M3")" = "4" ] || fail "task3 contained 4"
[ "$(jq -r .sandbox.needs_out.count "$M3")" = "15" ] || fail "task3 needs_out 15"
[ "$(jq -r .sandbox.unknown.count "$M3")" = "8" ] || fail "task3 unknown 8"
jq -e '.sandbox.contained.commands | any(contains("cargo test"))' "$M3" >/dev/null || fail "contained lists cargo test"
jq -e '.sandbox.contained.commands | any(contains("x.txt"))' "$M3" >/dev/null || fail "contained lists tmp write"
jq -e '.sandbox.needs_out.commands | any(contains("curl"))' "$M3" >/dev/null || fail "needs_out lists curl"
jq -e '.sandbox.needs_out.commands | any(contains("git push"))' "$M3" >/dev/null || fail "needs_out lists git push"
jq -e '.sandbox.needs_out.commands | any(contains("/etc/foo"))' "$M3" >/dev/null || fail "needs_out lists outside redirect"
jq -e '.sandbox.unknown.commands | any(contains("python3"))' "$M3" >/dev/null || fail "unknown lists piped interpreter"
jq -e '.sandbox.unknown.commands | any(. == "unknown")' "$M3" >/dev/null || fail "unknown lists the unmatched call"
jq -e '.sandbox.needs_out.commands | any(contains("git -C"))' "$M3" >/dev/null || fail "needs_out lists git -C"
jq -e '.sandbox.needs_out.commands | any(contains("--no-pager"))' "$M3" >/dev/null || fail "needs_out lists git --no-pager"
jq -e '.sandbox.needs_out.commands | any(contains("/etc/err"))' "$M3" >/dev/null || fail "needs_out lists 2> outside redirect"
jq -e '.sandbox.contained.commands | any(contains("2>/dev/null"))' "$M3" >/dev/null || fail "contained keeps 2>/dev/null"
jq -e '.sandbox.unknown.commands | any(contains("</etc/hosts"))' "$M3" >/dev/null || fail "unknown lists < redirect path"
jq -e '.sandbox.unknown.commands | any(contains("x=/etc/y"))' "$M3" >/dev/null || fail "unknown lists =-attached path"
jq -e '.sandbox.needs_out.commands | any(contains("git -C/tmp"))' "$M3" >/dev/null || fail "needs_out lists git -C/tmp"
jq -e '.sandbox.needs_out.commands | any(contains("git -cfoo"))' "$M3" >/dev/null || fail "needs_out lists git -cfoo"
jq -e '.sandbox.needs_out.commands | any(contains("/tmp/a b"))' "$M3" >/dev/null || fail "needs_out lists quoted git -C path"
jq -e '.sandbox.contained.commands | any(contains("git log --oneline"))' "$M3" >/dev/null || fail "contained keeps git log"
[ "$(jq -r '.denials | length' "$M3")" = "1" ] || fail "one denial"
[ "$(jq -r '.denials[0].action_id' "$M3")" = "n2" ] || fail "denial action"
[ "$(jq -r '.denials[0].decided_by' "$M3")" = "reviewer" ] || fail "denial decider"
[ "$(jq -r '.denials[0].reason' "$M3")" = "no pushing" ] || fail "denial reason"
jq -e '.denials[0].command | contains("git push")' "$M3" >/dev/null || fail "denial command"
[ "$(jq -r '.denials | length' "$OUT3/pi/metrics.json")" = "0" ] || fail "pi denials empty"

echo "task 3 cases passed"

# --- Task 4: harness error on the fiber side ---
OUT4="$T/out4"
if FAKE_EVENTS="$T/ev2.jsonl" CANARY_FAKE_FAIL=fiber bash "$CANARY" run 225 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUT4"; then
  fail "canary run exits 1 on harness error"
else
  [ $? -eq 1 ] || fail "harness error exits 1"
fi
[ "$(jq -r .outcome "$OUT4/pi/metrics.json")" = "DONE" ] || fail "pi side completes"
[ "$(jq -r .outcome "$OUT4/fiber/metrics.json")" = "harness_error" ] || fail "fiber harness_error"
[ "$(jq -r .job_id "$OUT4/fiber/metrics.json")" = "null" ] || fail "fiber job id null"
jq -e '.notes | any(contains("delegate run failed"))' "$OUT4/fiber/metrics.json" >/dev/null || fail "fiber note"
for f in worktree diff.patch gate.log gate.exit metrics.json prompt.md; do
  [ -f "$OUT4/fiber/$f" ] || fail "failed side still writes $f"
done
[ "$(cat "$OUT4/pi/gate.exit")" = "0" ] || fail "pi gate passes after fiber failure"
[ "$(jq -r .reviewed_calls "$OUT4/fiber/metrics.json")" = "null" ] || fail "fiber reviewed null"
[ "$(jq -r .cost.main "$OUT4/fiber/metrics.json")" = "null" ] || fail "fiber main null"

# nothing is ever pushed: no git push argv, no gh pr call, in any run so far
grep -q '^git push' "$FLOG/git.log" && fail "no git push is ever run"
if [ -f "$FLOG/gh.log" ]; then grep -q '^gh pr' "$FLOG/gh.log" && fail "no gh pr is ever run"; fi
[ -s "$FLOG/git.log" ] || fail "git wrapper logged calls"
grep -q 'fetch origin' "$FLOG/git.log" || fail "clone was fetched"

# a second run refuses until clean
if FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 225 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUT4" 2>/dev/null; then
  fail "second run should refuse"
else
  [ $? -eq 2 ] || fail "rerun refusal exits 2"
fi

# usage errors exit 2
bash "$CANARY" run 'a/b' "$T/brief.md" --gate true --out "$T/out-bad" 2>/dev/null && fail "bad ticket exits 2"
bash "$CANARY" run 226 "$T/no-such-brief.md" --gate true --out "$T/out-bad" 2>/dev/null && fail "missing brief exits 2"
bash "$CANARY" run 226 "$T/brief.md" --out "$T/out-bad" 2>/dev/null && fail "missing gate exits 2"
bash "$CANARY" frobnicate 2>/dev/null && fail "bad subcommand exits 2"
bash "$CANARY" clean 2>/dev/null && fail "clean without ticket exits 2"

# clean removes both worktrees and branches, keeps the metrics
bash "$CANARY" clean 225 --out "$OUT4" || fail "clean exits 0"
[ ! -e "$HOME/work/fiber-canary-225-pi" ] || fail "pi worktree removed"
[ ! -e "$HOME/work/fiber-canary-225-fiber" ] || fail "fiber worktree removed"
git -C "$HOME/work/fiber" show-ref --verify --quiet refs/heads/canary/225-pi && fail "pi branch removed"
git -C "$HOME/work/fiber" show-ref --verify --quiet refs/heads/canary/225-fiber && fail "fiber branch removed"
[ ! -f "$OUT4/pi/worktree" ] && [ ! -f "$OUT4/fiber/worktree" ] || fail "worktree files removed"
[ -f "$OUT4/pi/metrics.json" ] && [ -f "$OUT4/summary.md" ] || fail "metrics stay after clean"
git -C "$HOME/work/fiber" worktree list --porcelain | grep -q -- '-canary-225-' && fail "225 worktrees unregistered"

# a cleaned ticket runs again
FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 225 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUT4" || fail "run works again after clean"
[ "$(jq -r .outcome "$OUT4/pi/metrics.json")" = "DONE" ] || fail "rerun pi DONE"
[ "$(jq -r .outcome "$OUT4/fiber/metrics.json")" = "DONE" ] || fail "rerun fiber DONE"
bash "$CANARY" clean 225 --out "$OUT4" || fail "second clean exits 0"

# clean with nothing to remove still exits 0
bash "$CANARY" clean 999 --out "$T/out-empty" || fail "clean of a fresh ticket exits 0"

# --- Partial setup rollback: fiber worktree add fails after pi succeeds ---
# The fake git leaves the fiber branch (like native git on checkout failure);
# canary.sh must remove both branches and the pi worktree so a rerun works.
OUT5="$T/out5"
if CANARY_FAKE_WORKTREE_FAIL=fiber FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 227 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUT5" 2>/dev/null; then
  fail "fiber worktree failure should not exit 0"
else
  [ $? -eq 2 ] || fail "fiber worktree failure exits 2"
fi
git -C "$HOME/work/fiber" show-ref --verify --quiet refs/heads/canary/227-pi && fail "failed fiber add leaves no pi branch"
git -C "$HOME/work/fiber" show-ref --verify --quiet refs/heads/canary/227-fiber && fail "failed fiber add leaves no fiber branch"
[ ! -e "$HOME/work/fiber-canary-227-pi" ] || fail "failed fiber add removes pi worktree"
[ ! -e "$HOME/work/fiber-canary-227-fiber" ] || fail "failed fiber add creates no fiber worktree"
[ ! -f "$OUT5/pi/worktree" ] || fail "failed fiber add keeps no pi tracking"
[ "$(cat "$OUT5/clone")" = "$HOME/work/fiber" ] || fail "run records the clone"
assert_clean_leaves_nothing 227 "$OUT5"
FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 227 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUT5" || fail "rerun works after fiber worktree failure"
[ "$(jq -r .outcome "$OUT5/pi/metrics.json")" = "DONE" ] || fail "rerun pi DONE after worktree failure"
[ "$(jq -r .outcome "$OUT5/fiber/metrics.json")" = "DONE" ] || fail "rerun fiber DONE after worktree failure"
bash "$CANARY" clean 227 --out "$OUT5" || fail "clean after rerun exits 0"

# --- Partial setup rollback: pi worktree add fails ---
OUT6="$T/out6"
if CANARY_FAKE_WORKTREE_FAIL=pi FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 228 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUT6" 2>/dev/null; then
  fail "pi worktree failure should not exit 0"
else
  [ $? -eq 2 ] || fail "pi worktree failure exits 2"
fi
git -C "$HOME/work/fiber" show-ref --verify --quiet refs/heads/canary/228-pi && fail "failed pi add leaves no pi branch"
git -C "$HOME/work/fiber" show-ref --verify --quiet refs/heads/canary/228-fiber && fail "failed pi add leaves no fiber branch"
assert_clean_leaves_nothing 228 "$OUT6"
FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 228 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUT6" || fail "rerun works after pi worktree failure"
[ "$(jq -r .outcome "$OUT6/pi/metrics.json")" = "DONE" ] || fail "rerun pi DONE after pi failure"
bash "$CANARY" clean 228 --out "$OUT6" || fail "clean after pi rerun exits 0"

# --- Partial setup: fiber add fails, then branch deletion fails after the
# pi worktree is removed. run exits 2; a later clean finishes the job. ---
OUT7="$T/out7"
if CANARY_FAKE_WORKTREE_FAIL=fiber CANARY_FAKE_BRANCH_DELETE_FAIL=1 FAKE_EVENTS="$T/ev2.jsonl" \
  bash "$CANARY" run 229 "$T/brief.md" --gate 'test -f work-marker' --out "$OUT7" 2>/dev/null; then
  fail "branch delete failure should not exit 0"
else
  [ $? -eq 2 ] || fail "branch delete failure exits 2"
fi
assert_clean_leaves_nothing 229 "$OUT7"
FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 229 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUT7" || fail "rerun works after branch delete failure"
[ "$(jq -r .outcome "$OUT7/fiber/metrics.json")" = "DONE" ] || fail "rerun fiber DONE after branch delete failure"

# clean refuses a dirty worktree (exit 1), then works once it is clean
printf 'dirty\n' >"$HOME/work/fiber-canary-229-pi/uncommitted.txt"
if bash "$CANARY" clean 229 --out "$OUT7" 2>/dev/null; then
  fail "clean of a dirty worktree should not exit 0"
else
  [ $? -eq 1 ] || fail "clean of a dirty worktree exits 1"
fi
[ -d "$HOME/work/fiber-canary-229-pi" ] || fail "dirty worktree is kept"
rm -f "$HOME/work/fiber-canary-229-pi/uncommitted.txt"
assert_clean_leaves_nothing 229 "$OUT7"

# clean with no recorded clone says so and exits 0
msg="$(bash "$CANARY" clean 998 --out "$T/out-none" 2>&1)" || fail "clean without a clone file exits 0"
printf '%s' "$msg" | grep -q 'nothing to clean' || fail "clean without a clone file says nothing to clean"

echo "setup rollback cases passed"

# --- Fiber binary preflight ---
# (a) No FIBER_BIN and no fiber on PATH: run exits 2 naming FIBER_BIN, before
# any worktree, job or output dir exists for the ticket.
NOFIBER_PATH=""
IFS=: read -ra path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  [ -n "$d" ] && [ -x "$d/fiber" ] && continue
  NOFIBER_PATH="${NOFIBER_PATH:+$NOFIBER_PATH:}$d"
done
OUT8="$T/out8"
env -u FIBER_BIN PATH="$NOFIBER_PATH" FAKE_EVENTS="$T/ev2.jsonl" \
  bash "$CANARY" run 230 "$T/brief.md" --gate 'test -f work-marker' \
  --out "$OUT8" >/dev/null 2>"$T/nofiber.err"
rc=$?
[ "$rc" -eq 2 ] || fail "run with no Fiber binary exits 2 (got $rc)"
grep -q 'FIBER_BIN' "$T/nofiber.err" || fail "no-binary message names FIBER_BIN"
[ ! -e "$HOME/work/fiber-canary-230-pi" ] || fail "no-binary run creates no pi worktree"
[ ! -e "$HOME/work/fiber-canary-230-fiber" ] || fail "no-binary run creates no fiber worktree"
git -C "$HOME/work/fiber" show-ref --verify --quiet refs/heads/canary/230-pi && fail "no-binary run creates no pi branch"
git -C "$HOME/work/fiber" show-ref --verify --quiet refs/heads/canary/230-fiber && fail "no-binary run creates no fiber branch"
[ ! -e "$OUT8" ] || fail "no-binary run creates no output dir"

# (b) The summary records the binary's path and its --version output. Case
# 223 used FIBER_BIN; case 231 has no FIBER_BIN and finds the stand-in on PATH.
grep -qF "$FIBER_STUB" "$OUT/summary.md" || fail "summary records the Fiber binary path"
grep -qF 'fiber 9.9.9-canary-test' "$OUT/summary.md" || fail "summary records fiber --version"
OUT9="$T/out9"
env -u FIBER_BIN PATH="$FIBER_STUB_DIR:$PATH" FAKE_EVENTS="$T/ev2.jsonl" \
  bash "$CANARY" run 231 "$T/brief.md" --gate 'test -f work-marker' --out "$OUT9" \
  || fail "run finds fiber on PATH"
grep -qF "$FIBER_STUB" "$OUT9/summary.md" || fail "PATH-found binary path is recorded"
grep -qF 'fiber 9.9.9-canary-test' "$OUT9/summary.md" || fail "PATH-found binary version is recorded"
bash "$CANARY" clean 231 --out "$OUT9" || fail "clean 231 exits 0"

# (c) No FIBER_BIN and no fiber on PATH, but $HOME/.local/bin/fiber exists:
# delegate's last resort, so the run uses it and the summary records it.
mkdir -p "$HOME/.local/bin"
cp "$FIBER_STUB" "$HOME/.local/bin/fiber"
OUT10="$T/out10"
env -u FIBER_BIN PATH="$NOFIBER_PATH" FAKE_EVENTS="$T/ev2.jsonl" \
  bash "$CANARY" run 232 "$T/brief.md" --gate 'test -f work-marker' --out "$OUT10" \
  || fail "run finds fiber in HOME/.local/bin"
grep -qF "$HOME/.local/bin/fiber" "$OUT10/summary.md" || fail "HOME/.local/bin binary path is recorded"
grep -qF 'fiber 9.9.9-canary-test' "$OUT10/summary.md" || fail "HOME/.local/bin binary version is recorded"
bash "$CANARY" clean 232 --out "$OUT10" || fail "clean 232 exits 0"
rm -f "$HOME/.local/bin/fiber"

# (d) A relative FIBER_BIN, run from the directory that holds it: the worktree
# runs elsewhere, so the summary and the exported FIBER_BIN must be absolute.
mkdir -p "$T/relfb"
cp "$FIBER_STUB" "$T/relfb/fiber"
REL_FB_ABS="$(cd "$T/relfb" && pwd -P)/fiber"
OUT11="$T/out11"
( cd "$T/relfb" && env FIBER_BIN=./fiber FAKE_EVENTS="$T/ev2.jsonl" \
  bash "$CANARY" run 234 "$T/brief.md" --gate 'test -f work-marker' --out "$OUT11" ) \
  || fail "relative FIBER_BIN run exits 0"
grep -qF "$REL_FB_ABS" "$OUT11/summary.md" || fail "relative FIBER_BIN is recorded as an absolute path"
grep -qF '`./fiber`' "$OUT11/summary.md" && fail "relative FIBER_BIN is not recorded as given"
bash "$CANARY" clean 234 --out "$OUT11" || fail "clean 234 exits 0"

# (e) A relative PATH entry: the binary found there is recorded as absolute.
mkdir -p "$T/relbin"
cp "$FIBER_STUB" "$T/relbin/fiber"
REL_PATH_ABS="$(cd "$T/relbin" && pwd -P)/fiber"
OUT12="$T/out12"
( cd "$T" && env -u FIBER_BIN PATH="relbin:$NOFIBER_PATH" FAKE_EVENTS="$T/ev2.jsonl" \
  bash "$CANARY" run 235 "$T/brief.md" --gate 'test -f work-marker' --out "$OUT12" ) \
  || fail "relative PATH entry run exits 0"
grep -qF "$REL_PATH_ABS" "$OUT12/summary.md" || fail "relative PATH binary is recorded as an absolute path"
bash "$CANARY" clean 235 --out "$OUT12" || fail "clean 235 exits 0"

echo "fiber preflight cases passed"

# final no-push guarantee across every run above
grep -q '^git push' "$FLOG/git.log" && fail "no git push is ever run"
if [ -f "$FLOG/gh.log" ]; then grep -q '^gh pr' "$FLOG/gh.log" && fail "no gh pr is ever run"; fi

echo "task 4 cases passed"

# --- Fiber tool names (#238): shell takes .arguments.command, write and
# edit take .arguments.path. Each classifies as bash or write/edit would.
cat >"$T/ev5.jsonl" <<'EOF'
{"kind":"tool_call_requested","session_id":"s1","ts":1,"schema_version":1,"action_id":"f1","seq":1,"payload":{"name":"shell","arguments":{"command":"gh issue view 1616 --repo aakshintala/fiber"}}}
{"kind":"permission_resolved","session_id":"s1","ts":2,"schema_version":1,"action_id":"f1","seq":2,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":3,"schema_version":1,"action_id":"f2","seq":3,"payload":{"name":"shell","arguments":{"command":"git log --oneline -8"}}}
{"kind":"permission_resolved","session_id":"s1","ts":4,"schema_version":1,"action_id":"f2","seq":4,"payload":{"decision":"allow","decided_by":"reviewer"}}
{"kind":"tool_call_requested","session_id":"s1","ts":5,"schema_version":1,"action_id":"f3","seq":5,"payload":{"name":"write","arguments":{"path":"/etc/fiber-canary-test.txt","content":"x"}}}
{"kind":"permission_resolved","session_id":"s1","ts":6,"schema_version":1,"action_id":"f3","seq":6,"payload":{"decision":"allow","decided_by":"reviewer"}}
EOF
OUT5B="$T/out-tools"
FAKE_EVENTS="$T/ev5.jsonl" bash "$CANARY" run 240 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUT5B" || fail "tool-name run exits 0"
M5B="$OUT5B/fiber/metrics.json"
[ "$(jq -r .reviewed_calls "$M5B")" = "3" ] || fail "tool-name run reviewed 3 calls"
[ "$(jq -r .sandbox.unknown.count "$M5B")" = "0" ] || fail "shell and write calls are not unknown"
[ "$(jq -r .sandbox.needs_out.count "$M5B")" = "2" ] || fail "shell gh and write outside are needs_out"
[ "$(jq -r .sandbox.contained.count "$M5B")" = "1" ] || fail "shell git log is contained"
jq -e '.sandbox.needs_out.commands | any(contains("gh issue view"))' "$M5B" >/dev/null || fail "needs_out lists shell gh"
jq -e '.sandbox.needs_out.commands | any(contains("/etc/fiber-canary-test.txt"))' "$M5B" >/dev/null || fail "needs_out lists write outside"
jq -e '.sandbox.contained.commands | any(contains("git log --oneline"))' "$M5B" >/dev/null || fail "contained lists shell git log"
bash "$CANARY" clean 240 --out "$OUT5B" || fail "clean 240 exits 0"

echo "fiber tool name cases passed"

# --- Fiber main cost (#238): a main usage line with a null cost makes the
# split's main null; with total and reviewer numbers, main = total - reviewer.
cat >"$T/ev6.jsonl" <<'EOF'
{"kind":"usage_recorded","session_id":"s1","ts":1,"schema_version":1,"action_id":"m1","seq":1,"payload":{"generation_id":"gN","model":"m","tokens":{"input":0,"output":0,"cache_read":0,"cache_write":{}},"cost":null}}
{"kind":"usage_recorded","session_id":"s1","ts":2,"schema_version":1,"action_id":"m2","seq":2,"payload":{"generation_id":"gM","model":"m","tokens":{"input":10,"output":5,"cache_read":0,"cache_write":{}},"cost":0.25}}
{"kind":"usage_recorded","session_id":"s1","ts":3,"schema_version":1,"seq":3,"payload":{"generation_id":"gR","model":"m","tokens":{"input":4,"output":2,"cache_read":1,"cache_write":{}},"cost":0.125}}
{"kind":"tool_call_requested","session_id":"s1","ts":4,"schema_version":1,"action_id":"r1","seq":4,"payload":{"name":"bash","arguments":{"command":"cargo test"}}}
{"kind":"permission_resolved","session_id":"s1","ts":5,"schema_version":1,"action_id":"r1","seq":5,"payload":{"decision":"allow","decided_by":"reviewer"}}
EOF
OUT6B="$T/out-null-main"
FAKE_FIBER_COST=0.5 FAKE_EVENTS="$T/ev6.jsonl" bash "$CANARY" run 241 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUT6B" || fail "null-main run exits 0"
M6B="$OUT6B/fiber/metrics.json"
[ "$(jq -r .cost.total "$M6B")" = "0.5" ] || fail "null-main total cost 0.5"
[ "$(jq -r .cost.reviewer "$M6B")" = "0.125" ] || fail "null-main reviewer cost 0.125"
[ "$(jq -r .cost.main "$M6B")" = "0.375" ] || fail "main is total minus reviewer when the split leaves it null"
grep -q '| cost main | \$0.050000 | \$0.375000 |' "$OUT6B/summary.md" || fail "summary shows derived main cost"

# --- Fiber tokens (#238): main and reviewer tokens on separate rows. Main
# usage has an action_id; reviewer usage has none.
[ "$(jq -r .tokens_main.input "$M6B")" = "10" ] || fail "fiber main input"
[ "$(jq -r .tokens_main.output "$M6B")" = "5" ] || fail "fiber main output"
[ "$(jq -r .tokens_main.cache_read "$M6B")" = "0" ] || fail "fiber main cache-read"
[ "$(jq -r .tokens_reviewer.input "$M6B")" = "4" ] || fail "fiber reviewer input"
[ "$(jq -r .tokens_reviewer.output "$M6B")" = "2" ] || fail "fiber reviewer output"
[ "$(jq -r .tokens_reviewer.cache_read "$M6B")" = "1" ] || fail "fiber reviewer cache-read"
[ "$(jq -r .tokens.output "$M6B")" = "100" ] || fail "fiber total output stays the record's total"
[ "$(jq -r .tokens_main.output "$OUT6B/pi/metrics.json")" = "100" ] || fail "pi main tokens are its total"
[ "$(jq -r .tokens_reviewer.output "$OUT6B/pi/metrics.json")" = "0" ] || fail "pi reviewer tokens are zero"
grep -q '| tokens main in/out/cache-read | 1000/100/500 | 10/5/0 |' "$OUT6B/summary.md" || fail "summary main tokens row"
grep -q '| tokens reviewer in/out/cache-read | 0/0/0 | 4/2/1 |' "$OUT6B/summary.md" || fail "summary reviewer tokens row"
grep -q '| tokens in/out/cache-read' "$OUT6B/summary.md" && fail "summary has no combined tokens row"

bash "$CANARY" clean 241 --out "$OUT6B" || fail "clean 241 exits 0"

echo "fiber main cost cases passed"

# --- report (#238): rebuild metrics.json and summary.md from a finished
# run's saved outputs and the Fiber event log, without rerunning anything.
REP="$T/rep"
cp -R "$OUT" "$REP"
jq '.reviewed_calls = 0 | .cost.main = null | .tokens_reviewer = null' \
  "$REP/fiber/metrics.json" >"$T/stale.json" && mv "$T/stale.json" "$REP/fiber/metrics.json"
echo "| stale | stale | stale |" >>"$REP/summary.md"
bash "$CANARY" report 223 --out "$REP" || fail "report exits 0"
[ "$(jq -r .cost.main "$REP/fiber/metrics.json")" = "0.875" ] || fail "report rebuilds fiber main cost"
[ "$(jq -r .reviewed_calls "$REP/fiber/metrics.json")" = "2" ] || fail "report rebuilds reviewed calls"
[ "$(jq -r .tokens_reviewer.output "$REP/fiber/metrics.json")" = "20" ] || fail "report rebuilds reviewer tokens"
[ "$(jq -r .job_id "$REP/fiber/metrics.json")" = "$FIBER_ID" ] || fail "report keeps the job id"
[ "$(jq -r .cost.total "$REP/fiber/metrics.json")" = "0.04" ] || fail "report keeps the recorded total"
grep -q '| reviewed calls | 0 | 2 |' "$REP/summary.md" || fail "report summary reviewed row"
grep -q '| stale' "$REP/summary.md" && fail "report replaces summary.md"
grep -qF "$FIBER_STUB" "$REP/summary.md" || fail "report keeps the recorded Fiber binary"
grep -qF 'fiber 9.9.9-canary-test' "$REP/summary.md" || fail "report keeps the recorded Fiber version"

# a worktree that is gone keeps its diff and dirty flag from the saved run
jq '.dirty = true' "$REP/fiber/metrics.json" >"$T/dirty.json" && mv "$T/dirty.json" "$REP/fiber/metrics.json"
echo "$T/gone-fiber" >"$REP/fiber/worktree"
bash "$CANARY" report 223 --out "$REP" || fail "report exits 0 with a gone worktree"
[ -s "$REP/fiber/diff.patch" ] || fail "report keeps diff.patch when the worktree is gone"
[ "$(jq -r .dirty "$REP/fiber/metrics.json")" = "true" ] || fail "report keeps dirty when the worktree is gone"
[ "$(jq -r .cost.main "$REP/fiber/metrics.json")" = "0.875" ] || fail "report with a gone worktree still rebuilds main"

if bash "$CANARY" report 999 --out "$T/none" 2>/dev/null; then
  fail "report with no run should not exit 0"
else
  [ $? -eq 2 ] || fail "report with no run exits 2"
fi

# --- report sources (#238 fix round). Red: with the job record gone from
# both the saved copy and $TMPDIR, report exits 1 and touches nothing.
REPM="$T/rep-missing"
cp -R "$OUT" "$REPM"
rm -f "$REPM/pi/job.json" "$REPM/fiber/job.json"
mkdir -p "$T/aside"
mv "$TMPDIR/delegate-jobs/$PI_ID.json" "$T/aside/pi.json"
mv "$TMPDIR/delegate-jobs/$FIBER_ID.json" "$T/aside/fiber.json"
SNAPM="$T/snap-missing"
cp -R "$REPM" "$SNAPM"
bash "$CANARY" report 223 --out "$REPM" >/dev/null 2>"$T/rep-missing.err"
RC_MISS=$?
mv "$T/aside/pi.json" "$TMPDIR/delegate-jobs/$PI_ID.json"
mv "$T/aside/fiber.json" "$TMPDIR/delegate-jobs/$FIBER_ID.json"
[ "$RC_MISS" -eq 1 ] || fail "report with no job record exits 1 (got $RC_MISS)"
grep -q 'job record' "$T/rep-missing.err" || fail "report names the missing job record"
cmp -s "$SNAPM/pi/metrics.json" "$REPM/pi/metrics.json" || fail "report leaves pi metrics.json unchanged"
cmp -s "$SNAPM/fiber/metrics.json" "$REPM/fiber/metrics.json" || fail "report leaves fiber metrics.json unchanged"
cmp -s "$SNAPM/summary.md" "$REPM/summary.md" || fail "report leaves summary.md unchanged"

# Green: a run's saved job record and event log are enough. Tmp records
# and the Fiber home are both gone; the report still succeeds.
REPG="$T/rep-saved"
cp -R "$OUT" "$REPG"
[ -f "$REPG/pi/job.json" ] && [ -f "$REPG/fiber/job.json" ] || fail "run saves a job record copy per side"
[ -f "$REPG/fiber/events.jsonl" ] || fail "run saves the Fiber event log"
mv "$TMPDIR/delegate-jobs/$PI_ID.json" "$T/aside/pi.json"
mv "$TMPDIR/delegate-jobs/$FIBER_ID.json" "$T/aside/fiber.json"
FIBER_HOME="$T/no-fiber" bash "$CANARY" report 223 --out "$REPG" \
  || fail "report succeeds from saved copies alone"
mv "$T/aside/pi.json" "$TMPDIR/delegate-jobs/$PI_ID.json"
mv "$T/aside/fiber.json" "$TMPDIR/delegate-jobs/$FIBER_ID.json"
[ "$(jq -r .cost.main "$REPG/fiber/metrics.json")" = "0.875" ] || fail "saved-copy report rebuilds fiber main cost"
[ "$(jq -r .reviewed_calls "$REPG/fiber/metrics.json")" = "2" ] || fail "saved-copy report rebuilds reviewed calls"

# --- report never replaces saved files with a bad rebuild (#240 round 3).
# Red: a malformed or status-less job record exits 1 and every saved file
# stays byte-identical (the pre-check passes both: the files exist).
report_unchanged() { # DIR LABEL
  local d="$1" label="$2" snap="$T/snap-$2"
  rm -rf "$snap"; cp -R "$d" "$snap"
  bash "$CANARY" report 223 --out "$d" >/dev/null 2>"$T/rep-$2.err"
  local rc=$?
  [ "$rc" -eq 1 ] || fail "report with $label exits 1 (got $rc)"
  cmp -s "$snap/pi/metrics.json" "$d/pi/metrics.json" || fail "report with $label leaves pi metrics.json unchanged"
  cmp -s "$snap/fiber/metrics.json" "$d/fiber/metrics.json" || fail "report with $label leaves fiber metrics.json unchanged"
  cmp -s "$snap/summary.md" "$d/summary.md" || fail "report with $label leaves summary.md unchanged"
}
REPB="$T/rep-badjob"
cp -R "$OUT" "$REPB"
printf '{' >"$REPB/pi/job.json"
report_unchanged "$REPB" malformed-job
REPN="$T/rep-nostatus"
cp -R "$OUT" "$REPN"
jq 'del(.status)' "$OUT/pi/job.json" >"$REPN/pi/job.json"
report_unchanged "$REPN" nostatus-job

echo "report cases passed"

# --- Fiber home isolation (#626): canary.sh run exports FIBER_HOME under
# its out dir, so the Fiber lane never sees the caller's home. The fake
# delegate logs the FIBER_HOME each fiber run inherits (the fiber/* branch
# of fake run above). The run below passes a decoy home, and the case
# asserts the lane saw <out>/fiber-home instead, that the directory exists,
# and that the real $HOME/.fiber was neither created nor changed.
: >"$FLOG/fiber-home.log"
OUTFH="$T/out-fiber-home"
# The decoy home is this run's real home, so it holds the opencode
# extension too (#830), with an env credential for the fail-fast.
seed_extension "$T/decoy-fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"},"reviewer_model":"test-reviewer"}\n' >"$T/decoy-fiber/extensions/opencode/providers/opencode-go.json"
if [ -e "$HOME/.fiber" ]; then
  FIBER_REAL_BEFORE="$(find "$HOME/.fiber" | sort)"
else
  FIBER_REAL_BEFORE="absent"
fi
FIBER_HOME="$T/decoy-fiber" FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 242 "$T/brief.md" \
  --gate 'test -f work-marker' --out "$OUTFH" || fail "fiber-home run exits 0"
[ "$(cat "$FLOG/fiber-home.log")" = "$OUTFH/fiber-home" ] || fail "fiber lane saw the isolated home ($OUTFH/fiber-home)"
[ -d "$OUTFH/fiber-home" ] || fail "isolated fiber home exists"
if [ -e "$HOME/.fiber" ]; then
  FIBER_REAL_AFTER="$(find "$HOME/.fiber" | sort)"
else
  FIBER_REAL_AFTER="absent"
fi
[ "$FIBER_REAL_AFTER" = "$FIBER_REAL_BEFORE" ] || fail "real fiber home untouched"
bash "$CANARY" clean 242 --out "$OUTFH" || fail "clean 242 exits 0"

echo "fiber home cases passed"

# --- Relative --out (#626 fix round): a relative --out still gives the
# Fiber lane and the metrics one absolute home. The run starts in a
# different cwd with --out as a bare directory name; the fake resolves the
# inherited FIBER_HOME against the lane worktree it is given, the way Fiber
# would from the lane cwd. The case asserts the lane's resolved home equals
# the out dir resolved from the starting cwd, and that the metrics read the
# same ev2 events through it.
: >"$FLOG/fiber-home-resolved.log"
mkdir -p "$T/relcwd"
( cd "$T/relcwd" && FAKE_RESOLVE_HOME=1 FAKE_EVENTS="$T/ev2.jsonl" bash "$CANARY" run 243 "$T/brief.md" \
  --gate 'test -f work-marker' --out "out-rel" ) || fail "relative-out run exits 0"
ABSREL="$(cd "$T/relcwd/out-rel" && pwd)"
[ "$(cat "$FLOG/fiber-home-resolved.log")" = "$ABSREL/fiber-home" ] || fail "lane and metrics share one absolute home ($ABSREL/fiber-home)"
[ "$(jq -r .cost.main "$ABSREL/fiber/metrics.json")" = "0.875" ] || fail "relative-out metrics read the isolated ev2 events"
bash "$CANARY" clean 243 --out "$ABSREL" || fail "clean 243 exits 0"

echo "relative out cases passed"

# --- Provider extension copy (#830): the run seeds the isolated home with
# only the fiber arm's provider extension, copied from the real home. With
# FIBER_HOME unset the real home is $HOME/.fiber, so each case below sets
# HOME to a temp real home and points --clone at the test clone.
CLONE830="$HOME/work/fiber"
REAL830="$T/real830"
mkdir -p "$REAL830/.fiber"
seed_extension "$REAL830/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"},"reviewer_model":"test-reviewer"}\n' >"$REAL830/.fiber/extensions/opencode/providers/opencode-go.json"
REAL830_BEFORE="$(find "$REAL830/.fiber" | sort)"
OUT830="$T/out-ext"
: >"$FLOG/calls.log"
env -u FIBER_HOME HOME="$REAL830" bash "$CANARY" run 248 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT830" \
  || fail "extension run exits 0"
# the isolated home holds exactly the opencode extension: its two files and
# their directories, every file a real copy, no symlink into the real home
[ -d "$OUT830/fiber-home/extensions/opencode" ] || fail "isolated home holds the opencode extension"
[ "$(find "$OUT830/fiber-home" -type f | wc -l | tr -d ' ')" = "2" ] || fail "isolated home holds two files"
[ -z "$(find "$OUT830/fiber-home" -type l)" ] || fail "isolated home holds no symlink"
cmp -s "$REAL830/.fiber/extensions/opencode/extension.json" \
  "$OUT830/fiber-home/extensions/opencode/extension.json" || fail "extension.json is copied"
cmp -s "$REAL830/.fiber/extensions/opencode/providers/opencode-go.json" \
  "$OUT830/fiber-home/extensions/opencode/providers/opencode-go.json" || fail "provider file is copied"
[ "$(find "$OUT830/fiber-home" -mindepth 1 | sort)" = "$(printf '%s\n' \
  "$OUT830/fiber-home/extensions" \
  "$OUT830/fiber-home/extensions/opencode" \
  "$OUT830/fiber-home/extensions/opencode/extension.json" \
  "$OUT830/fiber-home/extensions/opencode/providers" \
  "$OUT830/fiber-home/extensions/opencode/providers/opencode-go.json")" ] \
  || fail "isolated home holds only the extension tree"
[ "$(find "$REAL830/.fiber" | sort)" = "$REAL830_BEFORE" ] || fail "real home is unchanged"
bash "$CANARY" clean 248 --out "$OUT830" || fail "clean 248 exits 0"

echo "extension copy cases passed"

# --- Provider extension override (#830): a codex fiber model copies only
# the codex extension. Its provider file names an env credential, so the
# credential fail-fast lets the run through.
REAL831="$T/real831"
mkdir -p "$REAL831/.fiber"
seed_extension "$REAL831/.fiber" opencode-go opencode
seed_extension "$REAL831/.fiber" codex codex
printf '{"credential":{"env":"CODEX_API_KEY"},"reviewer_model":"test-reviewer"}\n' >"$REAL831/.fiber/extensions/codex/providers/codex.json"
OUT831="$T/out-codex"
: >"$FLOG/calls.log"
env -u FIBER_HOME HOME="$REAL831" bash "$CANARY" run 249 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" \
  --fiber-model fiber/codex/gpt-6-luna --out "$OUT831" \
  || fail "codex run exits 0"
[ -d "$OUT831/fiber-home/extensions/codex" ] || fail "isolated home holds the codex extension"
[ ! -e "$OUT831/fiber-home/extensions/opencode" ] || fail "isolated home holds no opencode extension"
[ "$(find "$OUT831/fiber-home" -type f | wc -l | tr -d ' ')" = "2" ] || fail "codex home holds two files"
[ -z "$(find "$OUT831/fiber-home" -type l)" ] || fail "codex home holds no symlink"
cmp -s "$REAL831/.fiber/extensions/codex/extension.json" \
  "$OUT831/fiber-home/extensions/codex/extension.json" || fail "codex extension.json is copied"
cmp -s "$REAL831/.fiber/extensions/codex/providers/codex.json" \
  "$OUT831/fiber-home/extensions/codex/providers/codex.json" || fail "codex provider file is copied"
bash "$CANARY" clean 249 --out "$OUT831" || fail "clean 249 exits 0"

echo "extension override cases passed"

# --- Missing provider extension (#830): no extension provides opencode-go,
# so the run exits 2 before any delegate call, worktree or tracking file.
REAL832="$T/real832"
mkdir -p "$REAL832/.fiber"
OUT832="$T/out-missing"
: >"$FLOG/calls.log"
if env -u FIBER_HOME HOME="$REAL832" bash "$CANARY" run 250 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT832" 2>"$T/missing.err"; then
  fail "missing extension should not exit 0"
else
  [ $? -eq 2 ] || fail "missing extension exits 2"
fi
grep -q 'opencode-go' "$T/missing.err" || fail "missing message names the provider"
grep -q 'fiber extension install opencode' "$T/missing.err" || fail "missing message names the install"
[ -s "$FLOG/calls.log" ] && fail "missing extension makes no delegate call"
[ ! -e "$CLONE830-canary-250-pi" ] || fail "missing extension cuts no pi worktree"
[ ! -e "$CLONE830-canary-250-fiber" ] || fail "missing extension cuts no fiber worktree"
[ ! -f "$OUT832/pi/worktree" ] || fail "missing extension records no pi worktree"
[ ! -f "$OUT832/fiber/worktree" ] || fail "missing extension records no fiber worktree"

echo "missing extension cases passed"

# --- Extension symlink (#830): a symlink anywhere in the provider's
# extension tree exits 2 before any delegate call, worktree or tracking file.
REAL833="$T/real833"
mkdir -p "$REAL833/.fiber"
seed_extension "$REAL833/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"}}\n' >"$REAL833/.fiber/extensions/opencode/providers/opencode-go.json"
ln -s "$REAL833/.fiber/extensions/opencode/providers/opencode-go.json" \
  "$REAL833/.fiber/extensions/opencode/providers/extra-link.json"
OUT833="$T/out-symlink"
: >"$FLOG/calls.log"
if env -u FIBER_HOME HOME="$REAL833" bash "$CANARY" run 251 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT833" 2>"$T/symlink.err"; then
  fail "symlink extension should not exit 0"
else
  [ $? -eq 2 ] || fail "symlink extension exits 2"
fi
grep -qi 'symlink' "$T/symlink.err" || fail "symlink message names symlinks"
[ -s "$FLOG/calls.log" ] && fail "symlink extension makes no delegate call"
[ ! -e "$CLONE830-canary-251-pi" ] || fail "symlink run cuts no pi worktree"
[ ! -e "$CLONE830-canary-251-fiber" ] || fail "symlink run cuts no fiber worktree"
[ ! -f "$OUT833/pi/worktree" ] || fail "symlink run records no pi worktree"
[ ! -f "$OUT833/fiber/worktree" ] || fail "symlink run records no fiber worktree"

echo "extension symlink cases passed"

# --- Provider credential fail-fast (#830): the provider file names no env
# credential, so the run exits 2 before any delegate call, worktree or
# tracking file, without copying anything from the real home.
REAL834="$T/real834"
mkdir -p "$REAL834/.fiber"
seed_extension "$REAL834/.fiber" opencode-go opencode
printf '{}\n' >"$REAL834/.fiber/extensions/opencode/providers/opencode-go.json"
OUT834="$T/out-cred"
: >"$FLOG/calls.log"
if env -u FIBER_HOME HOME="$REAL834" bash "$CANARY" run 252 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT834" 2>"$T/cred.err"; then
  fail "credential-missing run should not exit 0"
else
  [ $? -eq 2 ] || fail "credential-missing run exits 2"
fi
grep -q 'The provider opencode-go needs a credential file under' "$T/cred.err" || fail "credential message names the provider"
grep -q 'Not copied; owner ruling needed' "$T/cred.err" || fail "credential message says owner ruling needed"
[ -s "$FLOG/calls.log" ] && fail "credential-missing run makes no delegate call"
[ ! -e "$CLONE830-canary-252-pi" ] || fail "credential-missing run cuts no pi worktree"
[ ! -e "$CLONE830-canary-252-fiber" ] || fail "credential-missing run cuts no fiber worktree"
[ ! -f "$OUT834/pi/worktree" ] || fail "credential-missing run records no pi worktree"
[ ! -f "$OUT834/fiber/worktree" ] || fail "credential-missing run records no fiber worktree"

echo "credential fail-fast cases passed"

# --- Reviewer flag validation (#833): an empty, whitespace-holding or
# missing --fiber-reviewer-model value exits 2 naming the flag with its
# "needs a value" text, before any delegate call, fiber home or worktree.
TABV="a$(printf '\t')b"
for REVVAL in "" "a b" "$TABV"; do
  OUTJ="$T/out-revflag"
  rm -rf "$OUTJ"
  : >"$FLOG/calls.log"
  if env -u FIBER_HOME HOME="$REAL830" bash "$CANARY" run 253 "$T/brief.md" \
    --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTJ" \
    --fiber-reviewer-model "$REVVAL" 2>"$T/revflag.err"; then
    fail "reviewer flag value '$REVVAL' should not exit 0"
  else
    [ $? -eq 2 ] || fail "reviewer flag value '$REVVAL' exits 2"
  fi
  grep -q -- '--fiber-reviewer-model needs a value' "$T/revflag.err" \
    || fail "reviewer flag value '$REVVAL' names the flag with its needs-a-value text"
  [ -s "$FLOG/calls.log" ] && fail "reviewer flag value '$REVVAL' makes no delegate call"
  [ ! -e "$OUTJ/fiber-home" ] || fail "reviewer flag value '$REVVAL' creates no fiber home"
  [ ! -e "$CLONE830-canary-253-pi" ] || fail "reviewer flag value '$REVVAL' cuts no pi worktree"
  [ ! -e "$CLONE830-canary-253-fiber" ] || fail "reviewer flag value '$REVVAL' cuts no fiber worktree"
  [ ! -f "$OUTJ/pi/worktree" ] || fail "reviewer flag value '$REVVAL' records no pi worktree"
  [ ! -f "$OUTJ/fiber/worktree" ] || fail "reviewer flag value '$REVVAL' records no fiber worktree"
done
OUTJ="$T/out-revflag"
rm -rf "$OUTJ"
: >"$FLOG/calls.log"
if env -u FIBER_HOME HOME="$REAL830" bash "$CANARY" run 253 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTJ" \
  --fiber-reviewer-model 2>"$T/revflag.err"; then
  fail "trailing reviewer flag should not exit 0"
else
  [ $? -eq 2 ] || fail "trailing reviewer flag exits 2"
fi
grep -q -- '--fiber-reviewer-model needs a value' "$T/revflag.err" \
  || fail "trailing reviewer flag names the flag with its needs-a-value text"
[ -s "$FLOG/calls.log" ] && fail "trailing reviewer flag makes no delegate call"
[ ! -e "$OUTJ/fiber-home" ] || fail "trailing reviewer flag creates no fiber home"
[ ! -e "$CLONE830-canary-253-pi" ] || fail "trailing reviewer flag cuts no pi worktree"
[ ! -e "$CLONE830-canary-253-fiber" ] || fail "trailing reviewer flag cuts no fiber worktree"

echo "reviewer flag validation cases passed"

# --- Reviewer resolution failures (#833): with the flag absent and no
# source naming a reviewer, the run exits 2 naming the flag before any
# delegate call, worktree or fiber home.
# d. No source at all: no real config.json, and a provider file and
# extension.json with no reviewer_model.
REALD="$T/real-rev-none"
mkdir -p "$REALD/.fiber"
seed_extension "$REALD/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"}}\n' >"$REALD/.fiber/extensions/opencode/providers/opencode-go.json"
OUTD="$T/out-rev-none"
: >"$FLOG/calls.log"
if env -u FIBER_HOME HOME="$REALD" bash "$CANARY" run 254 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTD" 2>"$T/revnone.err"; then
  fail "reviewer-less run should not exit 0"
else
  [ $? -eq 2 ] || fail "reviewer-less run exits 2"
fi
grep -q -- '--fiber-reviewer-model' "$T/revnone.err" || fail "reviewer-less message names the flag"
[ -s "$FLOG/calls.log" ] && fail "reviewer-less run makes no delegate call"
[ ! -e "$OUTD/fiber-home" ] || fail "reviewer-less run creates no fiber home"
[ ! -e "$CLONE830-canary-254-pi" ] || fail "reviewer-less run cuts no pi worktree"
[ ! -e "$CLONE830-canary-254-fiber" ] || fail "reviewer-less run cuts no fiber worktree"
[ ! -f "$OUTD/pi/worktree" ] || fail "reviewer-less run records no pi worktree"
[ ! -f "$OUTD/fiber/worktree" ] || fail "reviewer-less run records no fiber worktree"

# i. No usable real-config pick and no package default: invalid JSON (its
# contents never reach stderr), a numeric, empty, null or object pick, a
# providers array, a string provider entry, and a top-level array.
REALI="$T/real-rev-bad"
mkdir -p "$REALI/.fiber"
seed_extension "$REALI/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"}}\n' >"$REALI/.fiber/extensions/opencode/providers/opencode-go.json"
OUTI="$T/out-rev-bad"
rev_bad_case() { # CONFIG LABEL
  printf '%s\n' "$1" >"$REALI/.fiber/config.json"
  rm -rf "$OUTI"
  : >"$FLOG/calls.log"
  if env -u FIBER_HOME HOME="$REALI" bash "$CANARY" run 255 "$T/brief.md" \
    --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTI" 2>"$T/revbad.err"; then
    fail "bad config ($2) should not exit 0"
  else
    [ $? -eq 2 ] || fail "bad config ($2) exits 2"
  fi
  grep -q -- '--fiber-reviewer-model' "$T/revbad.err" || fail "bad config ($2) names the flag"
  [ -s "$FLOG/calls.log" ] && fail "bad config ($2) makes no delegate call"
  [ ! -e "$OUTI/fiber-home" ] || fail "bad config ($2) creates no fiber home"
  [ ! -e "$CLONE830-canary-255-pi" ] || fail "bad config ($2) cuts no pi worktree"
  [ ! -e "$CLONE830-canary-255-fiber" ] || fail "bad config ($2) cuts no fiber worktree"
}
rev_bad_case '{"providers":{"opencode-go":{"reviewer_model":"SENTINEL-BAD-JSON"}}' invalid-json
grep -q 'SENTINEL-BAD-JSON' "$T/revbad.err" && fail "invalid config leaks its contents to stderr"
rev_bad_case 'not json at all' non-json
rev_bad_case '{"providers":{"opencode-go":{"reviewer_model":42}}}' numeric-pick
rev_bad_case '{"providers":{"opencode-go":{"reviewer_model":""}}}' empty-pick
rev_bad_case '{"providers":{"opencode-go":{"reviewer_model":null}}}' null-pick
rev_bad_case '{"providers":{"opencode-go":{"reviewer_model":{}}}}' object-pick
rev_bad_case '{"providers":[]}' providers-array
rev_bad_case '{"providers":{"opencode-go":"local-id"}}' string-provider
rev_bad_case '[]' top-level-array
rev_bad_case '{"reviewer":{"model":"top-only"}}' top-level-reviewer-only

# k. A valid real config with no reviewer_model for the provider and no
# package default exits 2 naming the flag, with no null written anywhere.
REALK="$T/real-rev-k"
mkdir -p "$REALK/.fiber"
seed_extension "$REALK/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"}}\n' >"$REALK/.fiber/extensions/opencode/providers/opencode-go.json"
printf '{"providers":{"opencode-go":{"credential":{"env":"OPENCODE_API_KEY"}}}}\n' >"$REALK/.fiber/config.json"
OUTK="$T/out-rev-k"
: >"$FLOG/calls.log"
if env -u FIBER_HOME HOME="$REALK" bash "$CANARY" run 256 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTK" 2>"$T/revk.err"; then
  fail "pick-less run should not exit 0"
else
  [ $? -eq 2 ] || fail "pick-less run exits 2"
fi
grep -q -- '--fiber-reviewer-model' "$T/revk.err" || fail "pick-less message names the flag"
[ -s "$FLOG/calls.log" ] && fail "pick-less run makes no delegate call"
[ ! -e "$OUTK/fiber-home" ] || fail "pick-less run creates no fiber home"
[ ! -e "$OUTK/fiber-home/config.json" ] || ! grep -q 'null' "$OUTK/fiber-home/config.json" \
  || fail "pick-less run writes no null config"
[ ! -e "$CLONE830-canary-256-pi" ] || fail "pick-less run cuts no pi worktree"
[ ! -e "$CLONE830-canary-256-fiber" ] || fail "pick-less run cuts no fiber worktree"

echo "reviewer resolution cases passed"

# --- Reviewer seeding (#833): a flag or config pick writes the isolated
# config.json; a package default leaves Fiber's own fallback alone.
# a. Flag with a same-provider id: the isolated config.json holds exactly
# the flag's reviewer.model, next to the copied extension tree.
REALA="$T/real-rev-a"
mkdir -p "$REALA/.fiber"
seed_extension "$REALA/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"},"reviewer_model":"test-reviewer"}\n' >"$REALA/.fiber/extensions/opencode/providers/opencode-go.json"
OUTA="$T/out-rev-a"
: >"$FLOG/calls.log"
: >"$FLOG/fiber-home.log"
env -u FIBER_HOME HOME="$REALA" bash "$CANARY" run 257 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTA" \
  --fiber-reviewer-model opencode-go/test-reviewer 2>"$T/rev257.err" \
  || fail "flag run exits 0"
grep -qi warning "$T/rev257.err" && fail "same-provider flag run warns nothing"
[ "$(jq -c . "$OUTA/fiber-home/config.json")" = '{"reviewer":{"model":"opencode-go/test-reviewer"}}' ] \
  || fail "flag run writes the flag's reviewer model"
[ "$(find "$OUTA/fiber-home" -type f | wc -l | tr -d ' ')" = "3" ] || fail "flag run home holds three files"
[ -z "$(find "$OUTA/fiber-home" -type l)" ] || fail "flag run home holds no symlink"
[ "$(cat "$FLOG/fiber-home.log")" = "$OUTA/fiber-home" ] || fail "flag run lane saw the isolated home"
bash "$CANARY" clean 257 --out "$OUTA" || fail "clean 257 exits 0"

# b. A flag value with quotes, $ and backslash is written verbatim: the
# value reaches jq as one argument and no shell evaluates it.
REALB="$T/real-rev-b"
mkdir -p "$REALB/.fiber"
seed_extension "$REALB/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"},"reviewer_model":"test-reviewer"}\n' >"$REALB/.fiber/extensions/opencode/providers/opencode-go.json"
seed_extension "$REALB/.fiber" p p
printf '{"credential":{"env":"P_API_KEY"}}\n' >"$REALB/.fiber/extensions/p/providers/p.json"
REVB='p/m"$(>SENT-B)\x'
OUTB="$T/out-rev-b"
: >"$FLOG/calls.log"
env -u FIBER_HOME HOME="$REALB" P_API_KEY=SENTINEL-P-CRED bash "$CANARY" run 258 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTB" \
  --fiber-reviewer-model "$REVB" 2>"$T/rev258.err" \
  || fail "quoted flag run exits 0"
[ "$(jq -r .reviewer.model "$OUTB/fiber-home/config.json")" = "$REVB" ] \
  || fail "quoted flag value is written verbatim"
[ ! -e SENT-B ] || fail "quoted flag value starts no shell"
grep -rqF SENTINEL-P-CRED "$OUTB/fiber-home" && fail "isolated home leaks the reviewer credential"
grep -qF SENTINEL-P-CRED "$T/rev258.err" && fail "stderr leaks the reviewer credential"
grep -rF SENTINEL-P-CRED "$OUTB/pi/delegate.log" "$OUTB/fiber/delegate.log" \
  && fail "delegate logs leak the reviewer credential"
bash "$CANARY" clean 258 --out "$OUTB" || fail "clean 258 exits 0"

# c. The flag wins over a real-config pick and a package default: the
# isolated file holds only the flag's reviewer.model.
REALC="$T/real-rev-c"
mkdir -p "$REALC/.fiber"
seed_extension "$REALC/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"},"reviewer_model":"test-reviewer"}\n' >"$REALC/.fiber/extensions/opencode/providers/opencode-go.json"
printf '{"providers":{"opencode-go":{"reviewer_model":"config-pick-c"}}}\n' >"$REALC/.fiber/config.json"
OUTC="$T/out-rev-c"
: >"$FLOG/calls.log"
env -u FIBER_HOME HOME="$REALC" bash "$CANARY" run 259 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTC" \
  --fiber-reviewer-model opencode-go/flag-pick-c \
  || fail "flag-wins run exits 0"
[ "$(jq -c . "$OUTC/fiber-home/config.json")" = '{"reviewer":{"model":"opencode-go/flag-pick-c"}}' ] \
  || fail "flag wins over the config pick and package default"
bash "$CANARY" clean 259 --out "$OUTC" || fail "clean 259 exits 0"

# e. Flag absent, real-config pick: the isolated config.json holds exactly
# that one key, and no other real-config content reaches the isolated home.
REALE="$T/real-rev-e"
mkdir -p "$REALE/.fiber"
seed_extension "$REALE/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"},"reviewer_model":"test-reviewer"}\n' >"$REALE/.fiber/extensions/opencode/providers/opencode-go.json"
printf '{"model":"SENTINEL-TOP-MODEL","credential":"SENTINEL-TOP-CRED","credentials":{"x":"SENTINEL-TOP-CREDS"},"reviewer":{"model":"SENTINEL-TOP-REVIEWER"},"providers":{"opencode-go":{"reviewer_model":"local-id","credential":"SENTINEL-PROV-CRED","credentials":{"x":"SENTINEL-PROV-CREDS"}},"codex":{"reviewer_model":"SENTINEL-OTHER-PROV"}}}\n' >"$REALE/.fiber/config.json"
OUTE="$T/out-rev-e"
: >"$FLOG/calls.log"
env -u FIBER_HOME HOME="$REALE" bash "$CANARY" run 260 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTE" \
  || fail "config-pick run exits 0"
[ "$(jq -c . "$OUTE/fiber-home/config.json")" = '{"providers":{"opencode-go":{"reviewer_model":"local-id"}}}' ] \
  || fail "config pick is copied with its key and provider only"
for SENTE in SENTINEL-TOP-MODEL SENTINEL-TOP-CRED SENTINEL-TOP-CREDS \
  SENTINEL-TOP-REVIEWER SENTINEL-PROV-CRED SENTINEL-PROV-CREDS SENTINEL-OTHER-PROV; do
  grep -rqF "$SENTE" "$OUTE/fiber-home" && fail "isolated home leaks $SENTE"
done
bash "$CANARY" clean 260 --out "$OUTE" || fail "clean 260 exits 0"

# f. Flag absent, config pick plus package default: the config pick wins.
REALF="$T/real-rev-f"
mkdir -p "$REALF/.fiber"
seed_extension "$REALF/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"},"reviewer_model":"package-pick-f"}\n' >"$REALF/.fiber/extensions/opencode/providers/opencode-go.json"
printf '{"providers":{"opencode-go":{"reviewer_model":"config-pick-f"}}}\n' >"$REALF/.fiber/config.json"
OUTF="$T/out-rev-f"
: >"$FLOG/calls.log"
env -u FIBER_HOME HOME="$REALF" bash "$CANARY" run 261 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTF" \
  || fail "config-over-package run exits 0"
[ "$(jq -c . "$OUTF/fiber-home/config.json")" = '{"providers":{"opencode-go":{"reviewer_model":"config-pick-f"}}}' ] \
  || fail "config pick wins over the package default"
bash "$CANARY" clean 261 --out "$OUTF" || fail "clean 261 exits 0"

# g. Flag absent, package default only: exit 0 with no config.json, so
# Fiber's own fallback applies.
REALG="$T/real-rev-g"
mkdir -p "$REALG/.fiber"
seed_extension "$REALG/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"},"reviewer_model":"test-reviewer"}\n' >"$REALG/.fiber/extensions/opencode/providers/opencode-go.json"
OUTG="$T/out-rev-g"
: >"$FLOG/calls.log"
env -u FIBER_HOME HOME="$REALG" bash "$CANARY" run 262 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTG" \
  || fail "package-default run exits 0"
[ ! -e "$OUTG/fiber-home/config.json" ] || fail "package default writes no config.json"
bash "$CANARY" clean 262 --out "$OUTG" || fail "clean 262 exits 0"

# h. Stale config.json: a rerun after clean on a package-default home
# drops the earlier run's reviewer, and a new flag value replaces the old.
REALH="$T/real-rev-h"
mkdir -p "$REALH/.fiber"
seed_extension "$REALH/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"},"reviewer_model":"test-reviewer"}\n' >"$REALH/.fiber/extensions/opencode/providers/opencode-go.json"
OUTH="$T/out-rev-h"
: >"$FLOG/calls.log"
env -u FIBER_HOME HOME="$REALH" bash "$CANARY" run 263 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTH" \
  --fiber-reviewer-model opencode-go/round-one \
  || fail "stale first run exits 0"
[ "$(jq -c . "$OUTH/fiber-home/config.json")" = '{"reviewer":{"model":"opencode-go/round-one"}}' ] \
  || fail "stale first run writes round one"
bash "$CANARY" clean 263 --out "$OUTH" || fail "clean 263 exits 0"
env -u FIBER_HOME HOME="$REALH" bash "$CANARY" run 263 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTH" \
  || fail "stale second run exits 0"
[ ! -e "$OUTH/fiber-home/config.json" ] || fail "stale config.json is gone on rerun"
bash "$CANARY" clean 263 --out "$OUTH" || fail "clean 263 exits 0"
env -u FIBER_HOME HOME="$REALH" bash "$CANARY" run 263 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTH" \
  --fiber-reviewer-model opencode-go/round-two \
  || fail "stale third run exits 0"
[ "$(jq -c . "$OUTH/fiber-home/config.json")" = '{"reviewer":{"model":"opencode-go/round-two"}}' ] \
  || fail "second flag value replaces the first"
bash "$CANARY" clean 263 --out "$OUTH" || fail "clean 263 exits 0"

# l. A pre-existing symlinked config.json is replaced by a regular file the
# script wrote, and the link target's bytes are unchanged.
REALL="$T/real-rev-l"
mkdir -p "$REALL/.fiber"
seed_extension "$REALL/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"},"reviewer_model":"test-reviewer"}\n' >"$REALL/.fiber/extensions/opencode/providers/opencode-go.json"
OUTL="$T/out-rev-l"
mkdir -p "$OUTL/fiber-home"
printf 'decoy\n' >"$OUTL/decoy"
ln -s "$OUTL/decoy" "$OUTL/fiber-home/config.json"
: >"$FLOG/calls.log"
env -u FIBER_HOME HOME="$REALL" bash "$CANARY" run 264 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTL" \
  --fiber-reviewer-model opencode-go/link-test \
  || fail "symlinked-config run exits 0"
[ ! -L "$OUTL/fiber-home/config.json" ] || fail "symlinked config.json is replaced"
[ "$(jq -c . "$OUTL/fiber-home/config.json")" = '{"reviewer":{"model":"opencode-go/link-test"}}' ] \
  || fail "symlinked config.json holds the flag's reviewer model"
[ "$(cat "$OUTL/decoy")" = "decoy" ] || fail "link target bytes are unchanged"
bash "$CANARY" clean 264 --out "$OUTL" || fail "clean 264 exits 0"

echo "reviewer seeding cases passed"

# --- Cross-provider reviewer (#835): the flag names a reviewer on another
# provider, so the isolated home holds both extension trees and nothing else.
# Credentials, logs, recent.jsonl and the real config stay in the real home,
# and the credential value never reaches the isolated home or any log.
REAL265="$T/real-x265"
mkdir -p "$REAL265/.fiber"
seed_extension "$REAL265/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"}}\n' >"$REAL265/.fiber/extensions/opencode/providers/opencode-go.json"
seed_extension "$REAL265/.fiber" muse muse
printf '{"credential":{"env":"MUSE_API_KEY"}}\n' >"$REAL265/.fiber/extensions/muse/providers/muse.json"
mkdir -p "$REAL265/.fiber/credentials" "$REAL265/.fiber/logs"
printf 'SENTINEL-CRED\n' >"$REAL265/.fiber/credentials/SENTINEL-CRED"
printf 'SENTINEL-LOG\n' >"$REAL265/.fiber/logs/SENTINEL-LOG"
printf '{"recent":"SENTINEL-RECENT"}\n' >"$REAL265/.fiber/recent.jsonl"
printf '{"model":"SENTINEL-TOP-MODEL"}\n' >"$REAL265/.fiber/config.json"
REAL265_BEFORE="$(find "$REAL265/.fiber" | sort)"
OUT265="$T/out-x265"
: >"$FLOG/calls.log"
env -u FIBER_HOME HOME="$REAL265" MUSE_API_KEY=SENTINEL-MUSE-CRED bash "$CANARY" run 265 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT265" \
  --fiber-reviewer-model muse/muse-spark-1.3-contributor 2>"$T/x265.err" \
  || fail "cross-provider run exits 0"
[ "$(find "$OUT265/fiber-home" -mindepth 1 | sort)" = "$(printf '%s\n' \
  "$OUT265/fiber-home/config.json" \
  "$OUT265/fiber-home/extensions" \
  "$OUT265/fiber-home/extensions/muse" \
  "$OUT265/fiber-home/extensions/muse/extension.json" \
  "$OUT265/fiber-home/extensions/muse/providers" \
  "$OUT265/fiber-home/extensions/muse/providers/muse.json" \
  "$OUT265/fiber-home/extensions/opencode" \
  "$OUT265/fiber-home/extensions/opencode/extension.json" \
  "$OUT265/fiber-home/extensions/opencode/providers" \
  "$OUT265/fiber-home/extensions/opencode/providers/opencode-go.json")" ] \
  || fail "cross-provider home holds both trees, config.json and nothing else"
cmp -s "$REAL265/.fiber/extensions/muse/extension.json" \
  "$OUT265/fiber-home/extensions/muse/extension.json" || fail "muse extension.json is copied"
cmp -s "$REAL265/.fiber/extensions/muse/providers/muse.json" \
  "$OUT265/fiber-home/extensions/muse/providers/muse.json" || fail "muse provider file is copied"
cmp -s "$REAL265/.fiber/extensions/opencode/extension.json" \
  "$OUT265/fiber-home/extensions/opencode/extension.json" || fail "arm extension.json is copied"
cmp -s "$REAL265/.fiber/extensions/opencode/providers/opencode-go.json" \
  "$OUT265/fiber-home/extensions/opencode/providers/opencode-go.json" || fail "arm provider file is copied"
[ -z "$(find "$OUT265/fiber-home" -type l)" ] || fail "cross-provider home holds no symlink"
for SENTX in SENTINEL-CRED SENTINEL-LOG SENTINEL-RECENT SENTINEL-TOP-MODEL SENTINEL-MUSE-CRED; do
  grep -rqF "$SENTX" "$OUT265/fiber-home" && fail "isolated home leaks $SENTX"
  grep -qF "$SENTX" "$T/x265.err" && fail "stderr leaks $SENTX"
done
grep -rF SENTINEL-MUSE-CRED "$OUT265/pi/delegate.log" "$OUT265/fiber/delegate.log" \
  && fail "delegate logs leak the reviewer credential"
[ "$(jq -c . "$OUT265/fiber-home/config.json")" = '{"reviewer":{"model":"muse/muse-spark-1.3-contributor"}}' ] \
  || fail "cross-provider run writes the flag's reviewer model"
[ "$(find "$REAL265/.fiber" | sort)" = "$REAL265_BEFORE" ] || fail "cross-provider run leaves the real home unchanged"
bash "$CANARY" clean 265 --out "$OUT265" || fail "clean 265 exits 0"

# --- Cross-provider reviewer metrics (#835): the lane still reads the
# isolated home through FIBER_HOME, and the reviewer split still applies.
REAL266="$T/real-x266"
mkdir -p "$REAL266/.fiber"
seed_extension "$REAL266/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"}}\n' >"$REAL266/.fiber/extensions/opencode/providers/opencode-go.json"
seed_extension "$REAL266/.fiber" muse muse
printf '{"credential":{"env":"MUSE_API_KEY"}}\n' >"$REAL266/.fiber/extensions/muse/providers/muse.json"
OUT266="$T/out-x266"
: >"$FLOG/calls.log"
: >"$FLOG/fiber-home.log"
env -u FIBER_HOME HOME="$REAL266" MUSE_API_KEY=SENTINEL-MUSE-CRED FAKE_EVENTS="$T/ev2.jsonl" \
  bash "$CANARY" run 266 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT266" \
  --fiber-reviewer-model muse/muse-spark-1.3-contributor \
  || fail "cross-provider metrics run exits 0"
[ -d "$OUT266/fiber-home/extensions/muse" ] || fail "cross-provider home holds the muse extension"
[ "$(cat "$FLOG/fiber-home.log")" = "$OUT266/fiber-home" ] || fail "cross-provider lane saw the isolated home"
[ "$(jq -r .cost.main "$OUT266/fiber/metrics.json")" = "0.875" ] || fail "fiber main cost 0.875"
bash "$CANARY" clean 266 --out "$OUT266" || fail "clean 266 exits 0"

# --- Missing reviewer extension (#835): no extension provides the
# reviewer's provider, so the run exits 2 before any delegate call,
# worktree or tracking file.
REAL267="$T/real-x267"
mkdir -p "$REAL267/.fiber"
seed_extension "$REAL267/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"}}\n' >"$REAL267/.fiber/extensions/opencode/providers/opencode-go.json"
OUT267="$T/out-x267"
: >"$FLOG/calls.log"
if env -u FIBER_HOME HOME="$REAL267" bash "$CANARY" run 267 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT267" \
  --fiber-reviewer-model muse/m 2>"$T/x267.err"; then
  fail "missing reviewer extension should not exit 0"
else
  [ $? -eq 2 ] || fail "missing reviewer extension exits 2"
fi
grep -q 'muse' "$T/x267.err" || fail "missing reviewer message names the provider"
grep -q 'fiber extension install muse' "$T/x267.err" || fail "missing reviewer message names the install"
[ -s "$FLOG/calls.log" ] && fail "missing reviewer extension makes no delegate call"
[ ! -e "$OUT267/fiber-home" ] || fail "missing reviewer extension creates no fiber home"
[ ! -e "$CLONE830-canary-267-pi" ] || fail "missing reviewer run cuts no pi worktree"
[ ! -e "$CLONE830-canary-267-fiber" ] || fail "missing reviewer run cuts no fiber worktree"
[ ! -f "$OUT267/pi/worktree" ] || fail "missing reviewer run records no pi worktree"
[ ! -f "$OUT267/fiber/worktree" ] || fail "missing reviewer run records no fiber worktree"

# --- Reviewer tree symlink (#835): a symlink anywhere in the reviewer's
# extension tree exits 2, and the arm's tree is not copied either.
REAL268="$T/real-x268"
mkdir -p "$REAL268/.fiber"
seed_extension "$REAL268/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"}}\n' >"$REAL268/.fiber/extensions/opencode/providers/opencode-go.json"
seed_extension "$REAL268/.fiber" muse muse
printf '{"credential":{"env":"MUSE_API_KEY"}}\n' >"$REAL268/.fiber/extensions/muse/providers/muse.json"
ln -s "$REAL268/.fiber/extensions/muse/providers/muse.json" \
  "$REAL268/.fiber/extensions/muse/providers/extra-link.json"
OUT268="$T/out-x268"
: >"$FLOG/calls.log"
if env -u FIBER_HOME HOME="$REAL268" bash "$CANARY" run 268 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT268" \
  --fiber-reviewer-model muse/m 2>"$T/x268.err"; then
  fail "reviewer symlink should not exit 0"
else
  [ $? -eq 2 ] || fail "reviewer symlink exits 2"
fi
grep -qi 'symlink' "$T/x268.err" || fail "reviewer symlink message names symlinks"
[ -s "$FLOG/calls.log" ] && fail "reviewer symlink makes no delegate call"
[ ! -e "$OUT268/fiber-home" ] || fail "reviewer symlink creates no fiber home"
[ ! -e "$CLONE830-canary-268-pi" ] || fail "reviewer symlink run cuts no pi worktree"
[ ! -e "$CLONE830-canary-268-fiber" ] || fail "reviewer symlink run cuts no fiber worktree"
[ ! -f "$OUT268/pi/worktree" ] || fail "reviewer symlink run records no pi worktree"
[ ! -f "$OUT268/fiber/worktree" ] || fail "reviewer symlink run records no fiber worktree"

# --- Reviewer non-env credential (#835): the reviewer's provider file
# names no env credential, so the run exits 2 without copying anything.
REAL269="$T/real-x269"
mkdir -p "$REAL269/.fiber"
seed_extension "$REAL269/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"}}\n' >"$REAL269/.fiber/extensions/opencode/providers/opencode-go.json"
seed_extension "$REAL269/.fiber" muse muse
printf '{}\n' >"$REAL269/.fiber/extensions/muse/providers/muse.json"
OUT269="$T/out-x269"
: >"$FLOG/calls.log"
if env -u FIBER_HOME HOME="$REAL269" bash "$CANARY" run 269 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT269" \
  --fiber-reviewer-model muse/m 2>"$T/x269.err"; then
  fail "non-env reviewer credential should not exit 0"
else
  [ $? -eq 2 ] || fail "non-env reviewer credential exits 2"
fi
grep -q 'The provider muse needs a credential file under' "$T/x269.err" \
  || fail "non-env reviewer message names the provider"
grep -q 'Not copied; owner ruling needed' "$T/x269.err" \
  || fail "non-env reviewer message says owner ruling needed"
[ -s "$FLOG/calls.log" ] && fail "non-env reviewer credential makes no delegate call"
[ ! -e "$OUT269/fiber-home" ] || fail "non-env reviewer credential creates no fiber home"
[ ! -e "$CLONE830-canary-269-pi" ] || fail "non-env reviewer run cuts no pi worktree"
[ ! -e "$CLONE830-canary-269-fiber" ] || fail "non-env reviewer run cuts no fiber worktree"
[ ! -f "$OUT269/pi/worktree" ] || fail "non-env reviewer run records no pi worktree"
[ ! -f "$OUT269/fiber/worktree" ] || fail "non-env reviewer run records no fiber worktree"

# --- Reviewer invalid credential name (#835): the env name comes from a
# file, so a name outside the env-name form exits 2 before any side effect.
REAL270="$T/real-x270"
mkdir -p "$REAL270/.fiber"
seed_extension "$REAL270/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"}}\n' >"$REAL270/.fiber/extensions/opencode/providers/opencode-go.json"
seed_extension "$REAL270/.fiber" muse muse
printf '{"credential":{"env":"BAD NAME"}}\n' >"$REAL270/.fiber/extensions/muse/providers/muse.json"
OUT270="$T/out-x270"
: >"$FLOG/calls.log"
if env -u FIBER_HOME HOME="$REAL270" bash "$CANARY" run 270 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT270" \
  --fiber-reviewer-model muse/m 2>"$T/x270.err"; then
  fail "invalid reviewer credential name should not exit 0"
else
  [ $? -eq 2 ] || fail "invalid reviewer credential name exits 2"
fi
grep -q 'muse' "$T/x270.err" || fail "invalid reviewer name message names the provider"
[ -s "$FLOG/calls.log" ] && fail "invalid reviewer name makes no delegate call"
[ ! -e "$OUT270/fiber-home" ] || fail "invalid reviewer name creates no fiber home"
[ ! -e "$CLONE830-canary-270-pi" ] || fail "invalid reviewer run cuts no pi worktree"
[ ! -e "$CLONE830-canary-270-fiber" ] || fail "invalid reviewer run cuts no fiber worktree"
[ ! -f "$OUT270/pi/worktree" ] || fail "invalid reviewer run records no pi worktree"
[ ! -f "$OUT270/fiber/worktree" ] || fail "invalid reviewer run records no fiber worktree"

# --- Reviewer unset and empty credential (#835): each prints a one-line
# stderr warning naming the variable and the run goes on; a set variable
# prints no such line.
REAL271="$T/real-x271"
mkdir -p "$REAL271/.fiber"
seed_extension "$REAL271/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"}}\n' >"$REAL271/.fiber/extensions/opencode/providers/opencode-go.json"
seed_extension "$REAL271/.fiber" muse muse
printf '{"credential":{"env":"MUSE_API_KEY"}}\n' >"$REAL271/.fiber/extensions/muse/providers/muse.json"
OUT271="$T/out-x271"
: >"$FLOG/calls.log"
env -u FIBER_HOME -u MUSE_API_KEY HOME="$REAL271" bash "$CANARY" run 271 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT271" \
  --fiber-reviewer-model muse/m 2>"$T/x271.err" \
  || fail "unset-credential run exits 0"
grep -q '^run fiber' "$FLOG/calls.log" || fail "unset-credential run starts the fiber lane"
[ "$(grep -c MUSE_API_KEY "$T/x271.err")" = "1" ] || fail "unset warning names the variable once"
[ "$(grep -ci warning "$T/x271.err")" = "1" ] || fail "unset warning prints one warning line"
bash "$CANARY" clean 271 --out "$OUT271" || fail "clean 271 exits 0"
OUT272="$T/out-x272"
: >"$FLOG/calls.log"
env -u FIBER_HOME HOME="$REAL271" MUSE_API_KEY= bash "$CANARY" run 272 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT272" \
  --fiber-reviewer-model muse/m 2>"$T/x272.err" \
  || fail "empty-credential run exits 0"
grep -q '^run fiber' "$FLOG/calls.log" || fail "empty-credential run starts the fiber lane"
[ "$(grep -c MUSE_API_KEY "$T/x272.err")" = "1" ] || fail "empty warning names the variable once"
[ "$(grep -ci warning "$T/x272.err")" = "1" ] || fail "empty warning prints one warning line"
bash "$CANARY" clean 272 --out "$OUT272" || fail "clean 272 exits 0"
OUT273="$T/out-x273"
: >"$FLOG/calls.log"
env -u FIBER_HOME HOME="$REAL271" MUSE_API_KEY=SENTINEL-MUSE-CRED bash "$CANARY" run 273 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT273" \
  --fiber-reviewer-model muse/m 2>"$T/x273.err" \
  || fail "set-credential run exits 0"
grep -q MUSE_API_KEY "$T/x273.err" && fail "set credential warns nothing"
bash "$CANARY" clean 273 --out "$OUT273" || fail "clean 273 exits 0"

# --- Malformed reviewer form (#835): a value with a slash whose provider
# part fails fiber_provider_of exits 2 naming the flag, before any lookup.
REAL274="$T/real-x274"
mkdir -p "$REAL274/.fiber"
seed_extension "$REAL274/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"}}\n' >"$REAL274/.fiber/extensions/opencode/providers/opencode-go.json"
seed_extension "$REAL274/.fiber" muse muse
printf '{"credential":{"env":"MUSE_API_KEY"}}\n' >"$REAL274/.fiber/extensions/muse/providers/muse.json"
TICK274=274
for REVX in "/m" "muse/" "../x/m" "a.b/m"; do
  OUTX="$T/out-malform-$TICK274"
  rm -rf "$OUTX"
  : >"$FLOG/calls.log"
  if env -u FIBER_HOME HOME="$REAL274" bash "$CANARY" run "$TICK274" "$T/brief.md" \
    --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUTX" \
    --fiber-reviewer-model "$REVX" 2>"$T/malform.err"; then
    fail "malformed reviewer value '$REVX' should not exit 0"
  else
    [ $? -eq 2 ] || fail "malformed reviewer value '$REVX' exits 2"
  fi
  grep -q -- '--fiber-reviewer-model' "$T/malform.err" \
    || fail "malformed reviewer value '$REVX' names the flag"
  [ -s "$FLOG/calls.log" ] && fail "malformed reviewer value '$REVX' makes no delegate call"
  [ ! -e "$OUTX/fiber-home" ] || fail "malformed reviewer value '$REVX' creates no fiber home"
  [ ! -e "$CLONE830-canary-$TICK274-pi" ] || fail "malformed reviewer value '$REVX' cuts no pi worktree"
  [ ! -e "$CLONE830-canary-$TICK274-fiber" ] || fail "malformed reviewer value '$REVX' cuts no fiber worktree"
  [ ! -f "$OUTX/pi/worktree" ] || fail "malformed reviewer value '$REVX' records no pi worktree"
  [ ! -f "$OUTX/fiber/worktree" ] || fail "malformed reviewer value '$REVX' records no fiber worktree"
  TICK274=$((TICK274+1))
done

# --- No-slash reviewer value (#835): with no slash the flag names no
# second provider, so the run copies one tree and warns nothing.
REAL278="$T/real-x278"
mkdir -p "$REAL278/.fiber"
seed_extension "$REAL278/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"}}\n' >"$REAL278/.fiber/extensions/opencode/providers/opencode-go.json"
OUT278="$T/out-x278"
: >"$FLOG/calls.log"
env -u FIBER_HOME HOME="$REAL278" bash "$CANARY" run 278 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT278" \
  --fiber-reviewer-model bare-model 2>"$T/x278.err" \
  || fail "no-slash run exits 0"
[ "$(find "$OUT278/fiber-home" -type f | wc -l | tr -d ' ')" = "3" ] || fail "no-slash home holds three files"
[ "$(jq -r .reviewer.model "$OUT278/fiber-home/config.json")" = "bare-model" ] \
  || fail "no-slash value is written verbatim"
grep -qi warning "$T/x278.err" && fail "no-slash run warns nothing"
bash "$CANARY" clean 278 --out "$OUT278" || fail "clean 278 exits 0"

# --- Reviewer in the arm's extension (#835): a second provider from the
# same extension package copies the tree once and warns nothing.
REAL279="$T/real-x279"
mkdir -p "$REAL279/.fiber"
seed_extension "$REAL279/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"}}\n' >"$REAL279/.fiber/extensions/opencode/providers/opencode-go.json"
printf '{"credential":{"env":"OPENCODE_ALT_API_KEY"}}\n' >"$REAL279/.fiber/extensions/opencode/providers/opencode-alt.json"
OUT279="$T/out-x279"
: >"$FLOG/calls.log"
env -u FIBER_HOME HOME="$REAL279" OPENCODE_ALT_API_KEY=SENTINEL-ALT-CRED bash "$CANARY" run 279 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT279" \
  --fiber-reviewer-model opencode-alt/m 2>"$T/x279.err" \
  || fail "shared-tree run exits 0"
[ "$(find "$OUT279/fiber-home" -type f | wc -l | tr -d ' ')" = "4" ] || fail "shared tree home holds four files"
[ "$(find "$OUT279/fiber-home/extensions" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = "1" ] \
  || fail "shared tree copies one extension"
[ "$(jq -c . "$OUT279/fiber-home/config.json")" = '{"reviewer":{"model":"opencode-alt/m"}}' ] \
  || fail "shared-tree run writes the flag's reviewer model"
grep -qi warning "$T/x279.err" && fail "shared-tree run warns nothing"
bash "$CANARY" clean 279 --out "$OUT279" || fail "clean 279 exits 0"

# --- Malformed real config with a cross-provider flag (#835): the flag
# wins without reading the real config, so invalid JSON stops nothing.
REAL280="$T/real-x280"
mkdir -p "$REAL280/.fiber"
seed_extension "$REAL280/.fiber" opencode-go opencode
printf '{"credential":{"env":"OPENCODE_API_KEY"}}\n' >"$REAL280/.fiber/extensions/opencode/providers/opencode-go.json"
seed_extension "$REAL280/.fiber" muse muse
printf '{"credential":{"env":"MUSE_API_KEY"}}\n' >"$REAL280/.fiber/extensions/muse/providers/muse.json"
printf 'not json at all\n' >"$REAL280/.fiber/config.json"
OUT280="$T/out-x280"
: >"$FLOG/calls.log"
env -u FIBER_HOME HOME="$REAL280" MUSE_API_KEY=SENTINEL-MUSE-CRED bash "$CANARY" run 280 "$T/brief.md" \
  --gate 'test -f work-marker' --clone "$CLONE830" --out "$OUT280" \
  --fiber-reviewer-model muse/m \
  || fail "malformed-config flag run exits 0"
[ "$(jq -c . "$OUT280/fiber-home/config.json")" = '{"reviewer":{"model":"muse/m"}}' ] \
  || fail "malformed-config flag run writes the flag's reviewer model"
bash "$CANARY" clean 280 --out "$OUT280" || fail "clean 280 exits 0"

echo "cross-provider reviewer cases passed"

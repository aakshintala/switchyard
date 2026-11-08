# metrics.sh: shared cost/token/denial extraction and job record paths for
# replay.sh and canary.sh.
#
# Factored out of replay.sh (see #223). Sourced, never executed: it has no
# `set` lines and no top-level side effects (function definitions only).
# The Fiber events root defaults to ${FIBER_HOME:-$HOME/.fiber}; replay.sh
# sets FIBER_EVENTS_ROOT to $RUN_OUT/fiber-home before calling in.

# ---------- job records ----------

# delegate_jobs_dir: the directory delegate writes job records to, resolved
# as in delegate/src/status_record.rs: DELEGATE_JOBS_DIR when non-empty (a
# relative value against the current directory), else
# $XDG_CACHE_HOME/delegate/jobs when XDG_CACHE_HOME is absolute, else
# $HOME/.cache/delegate/jobs.
delegate_jobs_dir() {
  if [ -n "${DELEGATE_JOBS_DIR:-}" ]; then
    case "$DELEGATE_JOBS_DIR" in
      /*) printf '%s' "$DELEGATE_JOBS_DIR" ;;
      *) printf '%s/%s' "$PWD" "$DELEGATE_JOBS_DIR" ;;
    esac
    return 0
  fi
  case "${XDG_CACHE_HOME:-}" in
    /*) printf '%s/delegate/jobs' "$XDG_CACHE_HOME" ;;
    *) printf '%s/.cache/delegate/jobs' "${HOME:-}" ;;
  esac
}

# job_record_file JOBS_DIR ID: JOBS_DIR/ID.json, else the legacy
# $TMPDIR/delegate-jobs/ID.json a delegate from before #1374 wrote, else
# JOBS_DIR/ID.json (missing, for the caller's error).
job_record_file() {
  local legacy="${TMPDIR:-/tmp}/delegate-jobs/$2.json"
  if [ ! -f "$1/$2.json" ] && [ -f "$legacy" ]; then
    printf '%s' "$legacy"
  else
    printf '%s' "$1/$2.json"
  fi
}

# ---------- report ----------

fmt_money() {
  if [ -z "$1" ] || [ "$1" = "null" ]; then
    printf 'unknown'
  else
    printf '$%.6f' "$1"
  fi
}

fmt_share() {
  if [ -z "$1" ] || [ "$1" = "null" ]; then
    printf 'unknown'
  else
    awk -v s="$1" 'BEGIN{printf "%.1f%%", s * 100}'
  fi
}

fmt_wall() {
  if [ -z "$1" ] || [ "$1" = "null" ]; then
    printf 'unknown'
  else
    awk -v ms="$1" 'BEGIN{printf "%.1fs", ms / 1000}'
  fi
}

# pi_metrics RECORD SESSION: outcome gate cost in out cr share wall, one per line.
pi_metrics() {
  local rec="$1" session="$2" status gate cost in out cr cw share wall
  status="$(jq -r '.status // "unknown"' "$rec" 2>/dev/null)"
  [ "$status" = "null" ] && status="unknown"
  gate="$(jq -r 'if .result.gateResult.passed == null then "n/a" elif .result.gateResult.passed == true then "true" elif .result.gateResult.passed == false then "false" else "n/a" end' "$rec" 2>/dev/null)"
  case "$gate" in
    true) gate="pass" ;; false) gate="fail" ;; *) gate="n/a" ;;
  esac
  cost="$(jq -r '.result.costUsd // ""' "$rec" 2>/dev/null)"
  [ "$cost" = "null" ] && cost=""
  in="$(jq -r '.result.usage.inputTokens // ""' "$rec" 2>/dev/null)"
  out="$(jq -r '.result.usage.outputTokens // ""' "$rec" 2>/dev/null)"
  cr="$(jq -r '.result.usage.cacheReadTokens // ""' "$rec" 2>/dev/null)"
  cw="$(jq -r '.result.usage.cacheWriteTokens // ""' "$rec" 2>/dev/null)"
  for v in in out cr cw; do [ "${!v}" = "null" ] && eval "$v=\"\""; done
  share=""
  if [ -n "$in" ] && [ -n "$cr" ] && [ -n "$cw" ]; then
    share="$(awk -v i="$in" -v c="$cr" -v w="$cw" 'BEGIN{d=i+c+w; if (d>0) printf "%.4f", c/d}')"
  fi
  wall=""
  if [ -f "$session" ]; then
    wall="$(jq -rs '[.[] | select(.type=="custom" and .customType=="pi-stamp")
      | .data.endedAt - .data.startedAt][0] // ""' "$session" 2>/dev/null)"
  fi
  if [ -z "$wall" ] || [ "$wall" = "null" ]; then
    wall="$(jq -r '.result.durationMs // ""' "$rec" 2>/dev/null)"
    [ "$wall" = "null" ] && wall=""
  fi
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$status" "$gate" "$cost" "$in" "$out" "$cr" "$share" "$wall"
}

# fiber_events SID: the single events file, or "" when missing/ambiguous.
# report sets CANARY_FIBER_EVENTS to a run's saved copy of its event log.
fiber_events() {
  local sid="$1" ev="" f root="${FIBER_EVENTS_ROOT:-${FIBER_HOME:-$HOME/.fiber}}"
  if [ -n "${CANARY_FIBER_EVENTS:-}" ]; then
    printf '%s' "$CANARY_FIBER_EVENTS"
    return 0
  fi
  for f in "$root"/projects/*/sessions/"$sid"/events.jsonl; do
    [ -e "$f" ] || continue
    if [ -n "$ev" ]; then
      printf ''
      return 0
    fi
    ev="$f"
  done
  printf '%s' "$ev"
}

# fiber_metrics RECORD: outcome gate cost in out cr share wall, one per line.
# A session with no usage_recorded event renders tokens and cost unknown.
fiber_metrics() {
  local rec="$1" status gate cost in out cr cw share wall sid ev has_usage
  local started ended
  status="$(jq -r '.status // "unknown"' "$rec" 2>/dev/null)"
  [ "$status" = "null" ] && status="unknown"
  gate="$(jq -r 'if .result.gateResult.passed == null then "n/a" elif .result.gateResult.passed == true then "true" elif .result.gateResult.passed == false then "false" else "n/a" end' "$rec" 2>/dev/null)"
  case "$gate" in
    true) gate="pass" ;; false) gate="fail" ;; *) gate="n/a" ;;
  esac
  cost="$(jq -r '.result.costUsd // ""' "$rec" 2>/dev/null)"
  [ "$cost" = "null" ] && cost=""
  in="$(jq -r '.result.usage.inputTokens // ""' "$rec" 2>/dev/null)"
  out="$(jq -r '.result.usage.outputTokens // ""' "$rec" 2>/dev/null)"
  cr="$(jq -r '.result.usage.cacheReadTokens // ""' "$rec" 2>/dev/null)"
  cw="$(jq -r '.result.usage.cacheWriteTokens // ""' "$rec" 2>/dev/null)"
  for v in in out cr cw; do [ "${!v}" = "null" ] && eval "$v=\"\""; done
  sid="$(jq -r '.resume.sessionId // ""' "$rec" 2>/dev/null)"
  ev=""
  has_usage="unverified"
  if [ -n "$sid" ] && [ "$sid" != "null" ]; then
    ev="$(fiber_events "$sid")"
    if [ -n "$ev" ]; then
      if grep -q '"usage_recorded"' "$ev" 2>/dev/null; then
        has_usage="yes"
      else
        has_usage="no"
      fi
    fi
  fi
  if [ "$has_usage" != "yes" ]; then
    cost=""; in=""; out=""; cr=""; cw=""
  fi
  share=""
  if [ -n "$in" ] && [ -n "$cr" ] && [ -n "$cw" ]; then
    share="$(awk -v i="$in" -v c="$cr" -v w="$cw" 'BEGIN{d=i+c+w; if (d>0) printf "%.4f", c/d}')"
  fi
  wall=""
  if [ -n "$ev" ]; then
    started="$(jq -r 'select(.kind=="fiber_started") | .ts' "$ev" 2>/dev/null | head -n 1)"
    ended="$(jq -r 'select(.kind=="fiber_exited") | .ts' "$ev" 2>/dev/null | head -n 1)"
    if [ -n "$started" ] && [ -n "$ended" ]; then
      wall="$(awk -v a="$started" -v b="$ended" 'BEGIN{printf "%d", b - a}')"
    fi
  fi
  if [ -z "$wall" ]; then
    wall="$(jq -r '.result.durationMs // ""' "$rec" 2>/dev/null)"
    [ "$wall" = "null" ] && wall=""
  fi
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$status" "$gate" "$cost" "$in" "$out" "$cr" "$share" "$wall"
}

# denials_for RECORD: denial lines action_id decided_by reason command.
denials_for() {
  local rec="$1" sid ev aid decided reason cmd match
  sid="$(jq -r '.resume.sessionId // ""' "$rec" 2>/dev/null)"
  if [ -z "$sid" ] || [ "$sid" = "null" ]; then
    printf 'EVENTS_MISSING\n'
    return 0
  fi
  ev="$(fiber_events "$sid")"
  if [ -z "$ev" ]; then
    printf 'EVENTS_MISSING\n'
    return 0
  fi
  jq 'empty' "$ev" >/dev/null 2>&1 || { printf 'EVENTS_MISSING\n'; return 0; }
  for aid in $(jq -r 'select(.kind=="permission_resolved" and .payload.decision=="deny")
      | .action_id // ""' "$ev" 2>/dev/null); do
    [ -n "$aid" ] || continue
    decided="$(jq -r --arg a "$aid" 'select(.kind=="permission_resolved" and .action_id==$a)
      | .payload.decided_by // "unknown"' "$ev" 2>/dev/null | head -n 1)"
    reason="$(jq -r --arg a "$aid" 'select(.kind=="permission_resolved" and .action_id==$a)
      | .payload.reason // ""' "$ev" 2>/dev/null | head -n 1)"
    [ -n "$reason" ] || reason="unknown"
    match="$(jq -r --arg a "$aid" 'select(.kind=="tool_call_requested" and .action_id==$a)
      | .payload.name + " " + (.payload.arguments | if type=="string" then . else tojson end)' \
      "$ev" 2>/dev/null | head -n 1)"
    [ -n "$match" ] || match="unknown"
    cmd="$(printf '%s' "$match" | cut -c1-200)"
    printf '%s\t%s\t%s\t%s\n' "$aid" "$decided" "$reason" "$cmd"
  done
  return 0
}

# reviewer_split EVENTS: print {"main_cost":N|null,"reviewer_cost":N|null,
# "reviewer_tokens":N|null,"reviewed_calls":N}.
# Folds usage_recorded by generation_id (last line wins). A reviewer's call is
# a usage_recorded line with no envelope action_id, no payload.extension and
# no payload.origin_session_id (a delegate's copy counts as main); every
# other line counts as main. A null (or missing) cost on any line in a group
# makes that group's cost null; an empty group sums to 0. reviewer_tokens sums
# input + output + cache_read + cache_write (an object keyed by lifetime, or
# a number) over reviewer lines, null when any line's tokens are unknown.
# reviewed_calls counts permission_resolved with decided_by == reviewer.
# main_io and reviewer_io give {input, output, cache_read} per group (each
# null when a line's value is not a number; an empty group is 0).
# A missing or unparsable file prints all nulls (never 0).
reviewer_split() {
  local ev="$1" out
  if [ -z "${ev:-}" ] || [ ! -f "$ev" ]; then
    printf '{"main_cost":null,"reviewer_cost":null,"reviewer_tokens":null,"reviewed_calls":null}'
    return 0
  fi
  out="$(jq -cs '
    def toksum:
      (.payload.tokens) as $t
      | if ($t | type) != "object" then null
        elif ([$t.input, $t.output, $t.cache_read] | map(type) | any(. != "number")) then null
        elif ($t | has("cache_write") | not) then ($t.input + $t.output + $t.cache_read)
        elif ($t.cache_write | type) == "number" then ($t.input + $t.output + $t.cache_read + $t.cache_write)
        elif ($t.cache_write | type) == "object" then
          if ([$t.cache_write[]] | map(type) | any(. != "number")) then null
          else ($t.input + $t.output + $t.cache_read + ([$t.cache_write[]] | add // 0)) end
        else null end;
    def sumk($ls; $k):
      [$ls[] | (.payload.tokens | if type == "object" then .[$k] else null end)]
      | if any(type != "number") then null else add // 0 end;
    def io($ls): {input: sumk($ls; "input"), output: sumk($ls; "output"),
      cache_read: sumk($ls; "cache_read")};
    (reduce (.[] | select(type == "object" and .kind == "usage_recorded")) as $l
      ({}; .[$l.payload.generation_id // ""] = $l) | [.[]]) as $usage
    | ([.[] | select(type == "object" and .kind == "permission_resolved"
        and .payload.decided_by == "reviewer")] | length) as $rc
    | ([$usage[] | select((.action_id // null) == null
        and (.payload.extension // null) == null
        and (.payload.origin_session_id // null) == null)]) as $rev
    | ([$usage[] | select(.action_id != null
        or .payload.extension != null
        or .payload.origin_session_id != null)]) as $main
    | {
        main_cost: (if ($main | length) == 0 then 0
          elif ([$main[].payload.cost] | any(. == null)) then null
          else ([$main[].payload.cost] | add) end),
        reviewer_cost: (if ($rev | length) == 0 then 0
          elif ([$rev[].payload.cost] | any(. == null)) then null
          else ([$rev[].payload.cost] | add) end),
        reviewer_tokens: (if ($rev | length) == 0 then 0
          elif ([$rev[] | toksum] | any(. == null)) then null
          else ([$rev[] | toksum] | add) end),
        reviewed_calls: $rc,
        main_io: io($main),
        reviewer_io: io($rev)
      }' "$ev" 2>/dev/null)" || {
    printf '{"main_cost":null,"reviewer_cost":null,"reviewer_tokens":null,"reviewed_calls":null}'
    return 0
  }
  printf '%s' "$out"
}

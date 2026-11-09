#!/bin/bash
# lanesample — run lanecheck every 5 minutes and append one line per run to
# run/lane-liveness.log, so a lane's death time is exact rather than bounded by
# when the orchestrator last looked. Run as:
#
#   bash bin/lanesample.sh      # as a background task, never in the foreground
#
# lanecheck itself flags this log when its newest line is over 15 minutes old,
# so the sampler cannot die silently the way the lanewatch feeds did.
set -u
script_path=$0
while [ -L "$script_path" ]; do
  script_dir=$(cd "$(dirname "$script_path")" && pwd)
  link=$(readlink "$script_path")
  case "$link" in /*) script_path=$link;; *) script_path=$script_dir/$link;; esac
done
script_dir=$(cd "$(dirname "$script_path")" && pwd)
R=${FW_RUN:-${RUN_DIR:-$HOME/work/fiber-worktrees/flywheel/run}}
log="$R/lane-liveness.log"
interval=${FW_SAMPLE_SECONDS:-300}

while :; do
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  out=$(FW_SKIP_SAMPLER_CHECK=1 bash "$script_dir/lanecheck" 2>&1)
  summary=$(printf '%s\n' "$out" | grep '^--' | tail -1)
  printf '%s\t%s\n' "$ts" "${summary:-no summary}" >>"$log"
  printf '%s\n' "$out" | grep -E '^(MISSING|UNCHECKED|UNKNOWN)' | while IFS= read -r l; do
    printf '%s\t%s\n' "$ts" "$l" >>"$log"
  done
  sleep "$interval"
done

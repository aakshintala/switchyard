# job_walk: print id<TAB>record-path for a supersededBy chain, stopping on
# missing records and returning 1 on a cycle. Uses job-record's lookup order.
job_walk_superseded() {
  local id="$1" rec next seen='|'
  while [ -n "$id" ]; do
    case "$seen" in *"|$id|"*) return 1 ;; esac
    seen="$seen$id|"
    rec="$(bash "$script_dir/job-record" "$id" 2>/dev/null || true)"
    printf '%s\t%s\n' "$id" "$rec"
    [ -f "$rec" ] || return 0
    next="$(jq -r '.supersededBy // empty' "$rec" 2>/dev/null || true)"
    case "$next" in ''|*/*|.|..) return 0 ;; esac
    id="$next"
  done
}

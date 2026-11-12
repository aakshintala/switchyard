#!/usr/bin/env bash
# tkt-claims.sh: advisory changed-hunk claims after a ticket branch push.
_tkt_claim_source=${BASH_SOURCE[0]}
while [ -L "$_tkt_claim_source" ]; do
  _tkt_claim_source_dir=$(cd "$(dirname "$_tkt_claim_source")" && pwd)
  _tkt_claim_source_link=$(readlink "$_tkt_claim_source")
  case "$_tkt_claim_source_link" in
    /*) _tkt_claim_source=$_tkt_claim_source_link ;;
    *) _tkt_claim_source=$_tkt_claim_source_dir/$_tkt_claim_source_link ;;
  esac
done
_TKT_CLAIM_LIB_DIR=$(cd "$(dirname "$_tkt_claim_source")" && pwd)
unset _tkt_claim_source _tkt_claim_source_dir _tkt_claim_source_link

# Refresh plan-time whole-file claims with the pushed branch's old-side hunks.
# Ordinary OVERLAP lines are useful evidence, not a reason to fail a push.
tkt_claim_pushed_hunks() {
  local issue="$1" worktree="$2" repo="$3" file_claim host out rc overlaps
  file_claim=${FW_FILE_CLAIM:-$_TKT_CLAIM_LIB_DIR/../file-claim}
  host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf unknown)
  if out=$(bash "$file_claim" claim --lane "fiber-$issue" --diff "$worktree" \
      --worktree "$host:$worktree" --repo "$repo" 2>&1); then
    if [ -n "$out" ]; then
      overlaps="$(printf '%s\n' "$out" | awk '/^OVERLAP /')"
      [ -z "$overlaps" ] || printf '%s\n' "$overlaps" >&2
    fi
  else
    rc=$?
    printf 'WARN tkt: could not record pushed hunk claims for #%s (file-claim exit %s)%s\n' \
      "$issue" "$rc" "${out:+: $out}" >&2
  fi
  return 0
}

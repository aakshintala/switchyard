# Shared plan-verdict reads, writes and checks for tkt-plan, tkt-build and tkt-ship.

plan_verdict_read() {
  local state_tool="$1" state="$2" plan="$3" worktree="$4"
  plan_verdict="$("$state_tool" "$state" get plan_verdict 2>/dev/null || true)"
  plan_verdict_base="$("$state_tool" "$state" get plan_verdict_base 2>/dev/null || true)"
  plan_verdict_hash="$("$state_tool" "$state" get plan_verdict_hash 2>/dev/null || true)"
  plan_verdict_file_hash=""
  if [ -n "$plan" ]; then
    plan_verdict_file_hash="$(git -C "$worktree" hash-object "$plan" 2>/dev/null || true)"
  fi
  if [ -n "$plan_verdict_hash" ] && [ "$plan_verdict_hash" != "$plan_verdict_file_hash" ]; then
    plan_verdict=""
    plan_verdict_base=""
    plan_verdict_hash=""
  fi
}

plan_verdict_write() {
  local state_tool="$1" state="$2" verdict="$3" base="$4" plan="$5" worktree="$6" hash
  hash="$(git -C "$worktree" hash-object "$plan" 2>/dev/null)" || return 1
  "$state_tool" "$state" set plan_verdict "$verdict"
  "$state_tool" "$state" set plan_verdict_base "$base"
  "$state_tool" "$state" set plan_verdict_hash "$hash"
}

plan_verdict_check() {
  local policy="$1" state_tool="$2" state="$3" no_verifier="$4"
  local plan="$5" base="$6" worktree="$7" p verdict_ok=0
  shift 7
  local -a files=("$@")

  plan_verdict_read "$state_tool" "$state" "$plan" "$worktree"
  verdict_refusal="none"
  verdict_digest="plan_verdict=${plan_verdict:-none} plan_verdict_base=${plan_verdict_base:-none} plan_base=${base:-none}"

  if [ "$policy" = ship ]; then
    [ "$plan_verdict" = lines ] || return 0
    verdict_refusal=lines
    return 1
  fi

  if [ "$no_verifier" -eq 1 ] && { [ -z "$plan_verdict" ] || [ "$plan_verdict" = skipped ]; }; then
    plan_verdict_write "$state_tool" "$state" skipped "$base" "$plan" "$worktree" || return 1
    plan_verdict_read "$state_tool" "$state" "$plan" "$worktree"
  fi

  if [ "$plan_verdict" = ok ] || [ "$plan_verdict" = triaged ]; then
    if [ "$plan_verdict_base" = "$base" ]; then
      verdict_ok=1
    elif git -C "$worktree" merge-base --is-ancestor "$plan_verdict_base" "$base" 2>/dev/null &&
      { [ "${#files[@]}" -eq 0 ] || git -C "$worktree" diff --quiet "$plan_verdict_base..$base" -- "${files[@]}" 2>/dev/null; }; then
      verdict_ok=1
    fi
  elif [ "$plan_verdict" = skipped ] && [ "$plan_verdict_base" = "$base" ]; then
    verdict_ok=1
  fi
  [ "$verdict_ok" -eq 1 ] && return 0

  case "$plan_verdict" in
    "") verdict_refusal=none ;;
    ok|triaged|skipped) verdict_refusal=stale ;;
    *) verdict_refusal="$plan_verdict" ;;
  esac
  verdict_digest="plan_verdict=${plan_verdict:-none} plan_verdict_base=${plan_verdict_base:-none} plan_base=${base:-none}"
  return 1
}

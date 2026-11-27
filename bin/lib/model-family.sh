# Shared model-family mapping used by the delegate ladder and scoped-review guards.
# IDs that map_lane_provider cannot classify remain unclassified; family guards
# refuse only when both IDs have known, equal provider families.
map_lane_provider() {
  local id="$1" backend=""
  case "$id" in
    fiber/*)
      backend="${id#fiber/}"; backend="${backend%%/*}"
      ;;
    codex/*|openai/*) printf 'codex\n'; return 0 ;;
    claude/*|claude-*) printf 'claude\n'; return 0 ;;
    cursor/*|cursor-*) printf 'cursor\n'; return 0 ;;
    muse/*|muse-*) printf 'muse\n'; return 0 ;;
    opencode-go/*) printf 'opencode-go\n'; return 0 ;;
    *)
      backend="$(jq -r --arg id "$id" '.models[$id].backend // empty' "$models_file" 2>/dev/null || true)"
      ;;
  esac
  case "$backend" in
    claude|codex|cursor|muse|opencode-go) printf '%s\n' "$backend" ;;
    *) return 1 ;;
  esac
}

model_family_conflict() {
  local key_a="$1" id_a="$2" key_b="$3" id_b="$4" family_a family_b
  family_a="$(map_lane_provider "$id_a" 2>/dev/null || true)"
  family_b="$(map_lane_provider "$id_b" 2>/dev/null || true)"
  [ -n "$family_a" ] && [ "$family_a" = "$family_b" ] || return 1
  printf '%s=%s and %s=%s share provider family=%s\n' "$key_a" "$id_a" "$key_b" "$id_b" "$family_a"
}

model_family_conflict_with_any() {
  local scoped_key="$1" scoped_id="$2" pair implement_key implement_id detail
  shift 2
  for pair in "$@"; do
    implement_key="${pair%%=*}"
    implement_id="${pair#*=}"
    [ -n "$implement_key" ] && [ -n "$implement_id" ] || continue
    if detail="$(model_family_conflict "$scoped_key" "$scoped_id" "$implement_key" "$implement_id")"; then
      printf '%s\n' "$detail"
      return 0
    fi
  done
  return 1
}

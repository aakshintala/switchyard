# plan-tokens: shared token reader, path resolver and Files cover rules,
# sourced by bin/plan-check, bin/plan-sweep, bin/tkt-build, bin/tkt-plan and bin/tkt-gate.
# Source it from beside the calling script:
#   lib="$(cd "$(dirname "$0")" && pwd)/lib/plan-tokens.sh"
# Every function returns 0 unless stated, and is safe under `set -euo pipefail`.
# Globals, per function:
#   is_path: none. is_symbol: none.
#   exempt_new: reads plan.
#   in_files: reads FILES (|a|b| form), GLOBS (newline list).
#   plan_base: reads PLAN from its argument only.
#   plan_records: reads PLAN from its argument only.
#   expand_token: reads CUR_SEC, GLOBS, portre; appends to GLOBS; calls FN in
#     the current shell (FN must run in the caller's shell: no subshell here).
#   resolve_path: reads dir, rev, tree; sets RES, RES_KIND (found|ambiguous|none).
#   covered: reads FILES, GLOBS.
#   plan_files_pathspecs: reads PLAN from its argument only.
#   portre: a variable (not a function); expand_token reads it.

portre=':[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$'

# is_path TOKEN: no spaces, and a `/` or a known extension
is_path() {
  case "$1" in
    *" "*) return 1 ;;
    */*|*.rs|*.md|*.toml|*.lua|*.json|*.sh|*.yml|*.yaml|*.lock|*.txt|*.snap) return 0 ;;
  esac
  return 1
}

# is_symbol TOKEN: an identifier with `_`, `::` or an uppercase letter after its first character
is_symbol() {
  local s="$1" symre='^[A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)*$'
  case "$s" in *"()") s="${s%??}" ;; esac
  case "$s" in *"{"*) return 1 ;; esac
  [[ $s =~ $symre ]] || return 1
  case "$s" in *_*|*::*) return 0 ;; esac
  [[ ${s:1} =~ [A-Z] ]]
}

# exempt_new NAME: true when a plan line has the whole word `new`, `removed`, `remove`, `deleted`, `delete` or `example` and a backticked token holding NAME
# The `example` word exempts a line from check 3 only: check 1 keeps the shorter list.
exempt_new() {
  awk -v s="$1" '
    tolower($0) ~ /(^|[^a-z0-9_])(new|removed|remove|deleted|delete|example)([^a-z0-9_]|$)/ {
      n = split($0, parts, "`")
      for (i = 2; i <= n; i += 2)
        if (parts[i] ~ ("(^|[^A-Za-z0-9_])" s "([^A-Za-z0-9_]|$)")) found = 1
    }
    END { exit (found ? 0 : 1) }' "$plan"
}

# in_files PATH: true when a Files directory entry is a prefix of PATH,
# or a Files glob pattern matches it
in_files() {
  local f="$1" e g tmp
  tmp="${FILES#|}"
  while [ -n "$tmp" ]; do
    e="${tmp%%|*}"; tmp="${tmp#*|}"
    case "$e" in */) case "$f" in "$e"*) return 0 ;; esac ;; esac
  done
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    # Unquoted $g on purpose: the Files entry is a glob here, not a literal.
    case "$f" in $g) return 0 ;; esac
  done <<<"$GLOBS"
  return 1
}

# plan_base PLAN: the first token of the Base line with backticks stripped, so
# `Base: `abc`` reads as abc. Prints nothing when there is no Base line.
plan_base() {
  awk '/^Base:[[:space:]]/ { gsub(/`/, "", $2); print $2; exit }' "$1"
}

# plan_records PLAN: one record per backticked token outside fenced blocks and
# outside `## Gate`: section, line number, new mark, read mark, the token.
plan_records() {
  awk '
    /^[[:space:]]*```/ { infence = !infence; next }
    infence { next }
    /^## / {
      cur = "other"
      if ($0 ~ /^## Files([[:space:]]|$)/) cur = "files"
      else if ($0 ~ /^## Tasks([[:space:]]|$)/) cur = "tasks"
      else if ($0 ~ /^## Red commit([[:space:]]|$)/) cur = "red"
      else if ($0 ~ /^## Interfaces([[:space:]]|$)/) cur = "interfaces"
      else if ($0 ~ /^## Gate([[:space:]]|$)/) cur = "gate"
      next
    }
    cur == "gate" { next }
    {
      isnew = (tolower($0) ~ /(^|[^a-z0-9_])(new|removed|remove|deleted|delete)([^a-z0-9_]|$)/)
      isread = (tolower($0) ~ /(^|[^a-z0-9_])(reads|read-only|fixture)([^a-z0-9_]|$)/)
      n = split($0, parts, "`")
      for (i = 2; i <= n; i += 2)
        if (parts[i] != "") printf "%s\t%d\t%d\t%d\t%s\n", cur, NR, isnew, isread, parts[i]
    }
  ' "$1"
}

# _plan_plain TOKEN FN: the check_plain half of expand_token (no brace group left).
_plan_plain() {
  local p="$1" fn="$2"
  if [[ $p =~ $portre ]]; then p="${p%"${BASH_REMATCH[0]}"}"; fi
  case "$p" in
    *.rs::*|*.md::*|*.toml::*|*.lua::*|*.json::*|*.sh::*|*.yml::*|*.yaml::*|*.lock::*|*.txt::*|*.snap::*)
      "$fn" path "${p%%::*}"
      "$fn" symbol "${p#*::}"
      return 0 ;;
  esac
  if is_path "$p"; then
    "$fn" path "$p"
  elif is_symbol "$p"; then
    "$fn" symbol "$p"
  fi
  return 0
}

# expand_token TOKEN FN: skip rules, then one `{a,b}` group, then _plan_plain.
# A Files-section token holding `*` is recorded as a cover pattern before the
# skip. FN is called as `FN glob T`, `FN path P` or `FN symbol S`, in the
# current shell. A symbol is passed as written (a trailing `()` kept).
expand_token() {
  local t="$1" fn="$2" tmp n pre rest inner suf item
  case "$t" in *"*"*)
    case "$t" in *"<"*|*">"*|*" "*) return 0 ;; esac
    case "$CUR_SEC" in files) GLOBS="$GLOBS$t"$'\n' ;; esac
    "$fn" glob "$t"
    return 0 ;;
  esac
  case "$t" in *"<"*|*">"*|*" "*) return 0 ;; esac
  case "$t" in
    /|.|..) return 0 ;;
    .*) case "$t" in */*) ;; *) return 0 ;; esac ;;
  esac
  case "$t" in
    *"{"*)
      case "$t" in *"}"*) ;; *) return 0 ;; esac
      tmp="${t//\{/}"
      n=$(( ${#t} - ${#tmp} ))
      [ "$n" -eq 1 ] || return 0
      pre="${t%%\{*}"
      rest="${t#*\{}"
      inner="${rest%%\}*}"
      suf="${rest#*\}}"
      while IFS= read -r item; do
        _plan_plain "$pre$item$suf" "$fn"
      done <<<"$(awk -v s="$inner" 'BEGIN { n = split(s, a, ","); for (i = 1; i <= n; i++) print a[i] }')"
      return 0 ;;
  esac
  _plan_plain "$t" "$fn"
  return 0
}

# resolve_path P: resolve P at REV by plan-check's check 1 rule. Sets RES to
# the resolved path (or empty) and RES_KIND to found, ambiguous or none.
resolve_path() {
  local p="$1" out cnt m
  RES=""
  RES_KIND="none"
  case "$p" in
    */) if git -C "$dir" cat-file -e "$rev:${p%/}" 2>/dev/null; then RES="$p"; RES_KIND="found"; return 0; fi ;;
    *) if git -C "$dir" cat-file -e "$rev:$p" 2>/dev/null; then RES="$p"; RES_KIND="found"; return 0; fi ;;
  esac
  out="$(awk -v t="$p" '{
    if ($0 == t || (length($0) > length(t) && substr($0, length($0) - length(t)) == "/" t)) { c++; m = $0 }
  } END { printf "%d\t%s\n", c, m }' <<<"$tree")"
  cnt="${out%%$'\t'*}"
  m="${out#*$'\t'}"
  if [ "$cnt" = 1 ]; then
    RES="$m"
    RES_KIND="found"
  elif [ "$cnt" -ge 2 ]; then
    RES_KIND="ambiguous"
  fi
  return 0
}

# covered P: true when P is a Files entry, a directory P whose P/ prefixes a
# Files entry, under a Files entry ending `/`, or matched by a Files glob.
covered() {
  local p="$1" d
  case "$p" in
    */)
      d="${p%/}"
      case "$FILES" in *"|$d/"*) return 0 ;; esac ;;
    *)
      case "$FILES" in *"|$p|"*) return 0 ;; esac ;;
  esac
  in_files "$p"
}

# _plan_files_awk MODE: the `## Files` entry reader. A Files entry is a list item
# or table row whose first backticked token follows its marker directly; prose
# lines and prose before the token contribute nothing. MODE "lines" prints
# "N<TAB>token" (N the plan line), any other MODE prints the token.
_plan_files_awk='
  /^## Files([[:space:]]|$)/ { f = 1; next }
  f && /^## / { exit }
  f && match($0, /^[[:space:]]*([-*]|\|)[[:space:]]+`[^`]*`/) {
    t = substr($0, RSTART, RLENGTH); sub(/^[^`]*`/, "", t); sub(/`$/, "", t)
    if (t == "") next
    if (mode == "lines") print NR "\t" t; else print t
  }'

# plan_files_pathspecs PLAN: one path per line from the `## Files` entries. Blank
# tokens are dropped. Ends with awk, so no pipe can fail under pipefail.
plan_files_pathspecs() { awk -v mode=paths "$_plan_files_awk" "$1"; }

# plan_bare_dirs PLAN WORKTREE: one "Files line N: ..." line per entry whose path
# has no slash and is a directory in WORKTREE: a git pathspec that covers the
# whole tree. Names the plan line, so the planner sees which entry to fix.
plan_bare_dirs() {
  local n t
  while IFS=$'\t' read -r n t; do
    case "$t" in */*) continue ;; esac
    [ -d "$2/$t" ] && printf 'Files line %s: `%s` is a bare directory, so it covers the whole tree\n' "$n" "$t"
  done < <(awk -v mode=lines "$_plan_files_awk" "$1")
  return 0
}

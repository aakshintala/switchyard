#!/usr/bin/env bash
# canary.sh: run one ticket's brief on pi and Fiber side by side, with metrics.
#
# Usage:
#   canary.sh run <ticket> <brief file> --gate '<gate>' [--pi-model M] [--fiber-model M] [--fiber-reviewer-model M] [--thinking L] [--repo owner/name] [--clone <path>] [--out DIR]
#   canary.sh clean <ticket> [--out DIR]
#   canary.sh report <ticket> [--out DIR]
#
# report rebuilds metrics.json and summary.md from a finished run's saved
# outputs and the Fiber event log; it reruns nothing and makes no network calls.
#
# `--thinking L` appends `:L` to both arms' model ids; without the flag the ids
# pass through unchanged. The level itself is not checked here: delegate
# rejects an unknown level, and each arm then fails as a harness error.
#
# Exit codes: 0 both runs finished, whatever their gates did;
# 1 a run errored in the harness; 2 usage or setup error.
#
# The script never pushes, never opens a PR, and apart from the single
# `git fetch origin` in the clone it makes no network calls itself. The brief
# is wrapped with a line telling each agent to commit locally and not push.
set -uo pipefail

PI_MODEL="opencode-go/muse-spark-1.3-contributor"
FIBER_MODEL="fiber/opencode-go/muse-spark-1.3-contributor"
DEFAULT_REPO="aakshintala/fiber"

TAB="$(printf '\t')"

# TOK_QT matches one double-quoted, single-quoted, or bare token.
TOK_QT="\"[^\"]*\"|'[^']*'"

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/metrics.sh"

# Sandbox rules (see #223). Rows read class<TAB>tool<TAB>ERE, matched against
# "<tool> <command|path>" with ~, $HOME, $TMPDIR and $PWD expanded. needs_out
# rows are tried first, then unknown rows; anything else is contained.
# Writes to a path outside the allowed roots (the worktree, $TMPDIR, /tmp,
# /private/tmp, /dev/null) are judged by write_outside, next to the table.
SANDBOX_NEEDS_OUT="$(printf '%s\n' \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])(curl|wget)([^[:alnum:]_]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])gh([^[:alnum:]_]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])git[[:space:]]([^;|&]*[[:space:]])?(fetch|push|clone|pull|ls-remote|submodule[[:space:]]+update)([^[:alnum:]_]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])(npm|pnpm|yarn|bun)[[:space:]]+(install|i|ci|add|update)([^[:alnum:]_-]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])npx([^[:alnum:]_-]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])pip3?[[:space:]]+install([^[:alnum:]_]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])uv[[:space:]]+(pip[[:space:]]+install|sync|add)([^[:alnum:]_]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])brew([^[:alnum:]_-]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])cargo[[:space:]]+(install|fetch|update|add|search)([^[:alnum:]_]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])go[[:space:]]+(get|mod[[:space:]]+download)([^[:alnum:]_]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])(ssh|scp|rsync|nc)([^[:alnum:]_-]|\$)")"

SANDBOX_UNKNOWN="$(printf '%s\n' \
  "unknown${TAB}*${TAB}(^|[^[:alnum:]_])\\.\\.([^[:alnum:]_]|\$)" \
  "unknown${TAB}*${TAB}\\\$[A-Za-z_0-9{?#*@!$]" \
  "unknown${TAB}bash${TAB}(^|[^[:alnum:]_])eval([^[:alnum:]_]|\$)" \
  "unknown${TAB}bash${TAB}(^|[^[:alnum:]_])(bash|sh|zsh)[[:space:]]+-c([^[:alnum:]_]|\$)" \
  "unknown${TAB}bash${TAB}(^|[^[:alnum:]_])xargs([^[:alnum:]_]|\$)" \
  "unknown${TAB}bash${TAB}[|][[:space:]]*(python3|python|sh|bash|node|perl)([^[:alnum:]_]|$)")"

err() {
  printf 'canary: %s\n' "$*" >&2
}

usage() {
  err "usage: canary.sh run <ticket> <brief file> --gate '<gate>' [--pi-model M] [--fiber-model M] [--fiber-reviewer-model M] [--thinking L] [--repo owner/name] [--clone <path>] [--out DIR]"
  err "       canary.sh clean <ticket> [--out DIR]"
  err "       canary.sh report <ticket> [--out DIR]"
}

now_ms() {
  printf '%d' "$(( $(date +%s) * 1000 ))"
}

# absolute_path PATH: PATH made absolute against the current directory, with
# its directory's symlinks resolved. Returns 1 when that directory is missing.
absolute_path() {
  local p="$1" dir base
  dir="$(dirname "$p")"; base="$(basename "$p")"
  dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s' "$dir" "$base"
}

# resolve_fiber_bin: the Fiber binary delegate would run, in delegate's order
# (FIBER_BIN, then PATH, then $HOME/.local/bin/fiber). Prints its absolute path;
# returns 1 when there is none. The worktree runs elsewhere, so a relative
# path must be made absolute here, in the caller's directory. The last
# candidate must be executable, so a missing file is refused here too.
resolve_fiber_bin() {
  local found=""
  if [ -n "${FIBER_BIN:-}" ]; then
    case "$FIBER_BIN" in
      */*) absolute_path "$FIBER_BIN"; return ;;
    esac
    found="$(command -v "$FIBER_BIN" 2>/dev/null)" && [ -n "$found" ] || return 1
    absolute_path "$found"; return
  fi
  found="$(command -v fiber 2>/dev/null)" && [ -n "$found" ] && { absolute_path "$found"; return; }
  if [ -x "$HOME/.local/bin/fiber" ]; then printf '%s' "$HOME/.local/bin/fiber"; return 0; fi
  return 1
}

# match_table TABLE TEXT TOOL: true when a row for TOOL (or *) matches TEXT.
match_table() {
  local table="$1" text="$2" tool="$3" line rest row_tool ere
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    rest="${line#*$TAB}"
    row_tool="${rest%%$TAB*}"; ere="${rest#*$TAB}"
    if [ "$row_tool" = "*" ] || [ "$row_tool" = "$tool" ]; then
      if printf '%s' "$text" | grep -Eq "$ere"; then return 0; fi
    fi
  done <<<"$table"
  return 1
}

# expand_bare TEXT NAME VALUE: replace $NAME only when the next character
# is not [A-Za-z0-9_] (end of string counts as a boundary). A longer
# name such as $TMPDIR_BACKUP is left for the unknown rules.
expand_bare() {
  local text="$1" name="$2" value="$3"
  local needle="\$$name" out="" rest="$text" pre="" tail="" next=""
  while :; do
    case "$rest" in
      *"$needle"*)
        pre="${rest%%"$needle"*}"
        tail="${rest#*"$needle"}"
        next="${tail:0:1}"
        case "$next" in
          ""|[!A-Za-z0-9_]) out="$out$pre$value"; rest="$tail" ;;
          *) out="$out$pre$needle"; rest="$tail" ;;
        esac ;;
      *) out="$out$rest"; break ;;
    esac
  done
  printf '%s' "$out"
}

# normalize_text TEXT WORKTREE TMPDIR: expand ~, $HOME, $TMPDIR, $PWD.
normalize_text() {
  local t="$1" wt="$2" tmp="$3" home="${HOME:-/tmp}" esc
  tmp="${tmp%/}"; [ -n "$tmp" ] || tmp="/tmp"
  t="${t//\$\{HOME\}/$home}"
  t="$(expand_bare "$t" "HOME" "$home")"
  t="${t//\$\{TMPDIR\}/$tmp}"
  t="$(expand_bare "$t" "TMPDIR" "$tmp")"
  t="${t//\$\{PWD\}/$wt}"
  t="$(expand_bare "$t" "PWD" "$wt")"
  t="${t//\~\//$home/}"
  esc="$(printf '%s' "$home" | sed -e 's/[#\\/&]/\\&/g')"
  t="$(printf '%s' "$t" | sed -E "s#(^|[[:space:]\"'=])~([[:space:]\"']|\$)#\1${esc}\2#g")"
  printf '%s' "$t"
}

# path_outside PATH WORKTREE TMPDIR: true for an absolute path outside the
# allowed roots (the worktree, $TMPDIR, /tmp, /private/tmp, /dev/null).
path_outside() {
  local p="$1" wt="$2" tmp="$3" r
  tmp="${tmp%/}"; [ -n "$tmp" ] || tmp="/tmp"
  case "$p" in /*) ;; *) return 1 ;; esac
  for r in "$wt" "$tmp" /tmp /private/tmp /dev/null; do
    [ -n "$r" ] || continue
    if [ "$p" = "$r" ] || [[ "$p" == "$r"/* ]]; then return 1; fi
  done
  return 0
}

# write_targets_bash TEXT: redirect targets and write-verb operands of a bash
# command, one per line. Verb operands over-approximate (sources count too).
# operands_of CHUNK: whitespace-separated tokens, one per line, quotes stripped.
operands_of() {
  local chunk="$1" tok
  while IFS= read -r tok || [ -n "$tok" ]; do
    [ -n "$tok" ] || continue
    tok="${tok#\"}"; tok="${tok%\"}"; tok="${tok#\'}"; tok="${tok%\'}"
    printf '%s\n' "$tok"
  done < <(printf '%s' "$chunk" | grep -Eo "(${TOK_QT}|[^[:space:]]+)")
}

# write_targets_bash TEXT: redirect targets and write-verb operands of a bash
# command, one per line. Verb operands over-approximate (sources count too).
write_targets_bash() {
  local text="$1" m chunk op verbs verb
  verbs="tee cp mv rm mkdir touch ln install"
  while IFS= read -r m || [ -n "$m" ]; do
    [ -n "$m" ] || continue
    chunk="$(printf '%s' "$m" | sed -E 's/^[0-9]*>>?[[:space:]]*//')"
    operands_of "$chunk"
  done < <(printf '%s' "$text" | grep -Eo "[0-9]*>>?[[:space:]]*(${TOK_QT}|[^[:space:];|&()<>]+)")
  if printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_-])sed[[:space:]]+[^;&|]*(-[A-Za-z]*i|--in-place)([^[:alnum:]_]|$)'; then
    verbs="$verbs sed"
  fi
  for verb in $verbs; do
    while IFS= read -r m || [ -n "$m" ]; do
      [ -n "$m" ] || continue
      chunk="${m#*"$verb"}"
      chunk="${chunk#"${chunk%%[![:space:]]*}"}"
      while IFS= read -r op || [ -n "$op" ]; do
        [ -n "$op" ] || continue
        case "$op" in -*) ;; *) printf '%s\n' "$op" ;; esac
      done < <(operands_of "$chunk")
    done < <(printf '%s' "$text" | grep -Eo "(^|[[:space:];|&()])${verb}[[:space:]]+[^;|&]+")
  done
}

# write_outside TOOL NTEXT NARG WORKTREE TMPDIR: true when a write lands
# outside the allowed roots (redirect/verb targets for bash, the path for
# write/edit).
write_outside() {
  local name="$1" ntext="$2" narg="$3" wt="$4" tmp="$5" cand
  if [ "$name" = "write" ] || [ "$name" = "edit" ]; then
    path_outside "$narg" "$wt" "$tmp" && return 0
    return 1
  fi
  while IFS= read -r cand || [ -n "$cand" ]; do
    [ -n "$cand" ] || continue
    if path_outside "$cand" "$wt" "$tmp"; then return 0; fi
  done <<<"$(write_targets_bash "$ntext")"
  return 1
}

# cd_outside TEXT WORKTREE TMPDIR: true when cd/pushd leaves the allowed
# roots (or its target cannot be settled: bare, `-`, or relative).
cd_outside() {
  local text="$1" wt="$2" tmp="$3" m verb chunk tgt
  while IFS= read -r m || [ -n "$m" ]; do
    [ -n "$m" ] || continue
    verb="cd"
    case "$m" in *pushd*) verb="pushd" ;; esac
    chunk="${m#*"$verb"}"
    tgt="$(operands_of "$chunk" | head -n 1)"
    if [ -z "$tgt" ]; then return 0; fi
    case "$tgt" in -*) return 0 ;; esac
    if path_outside "$tgt" "$wt" "$tmp"; then return 0; fi
    case "$tgt" in /*) ;; *) return 0 ;; esac
  done < <(printf '%s' "$text" | grep -Eo "(^|[[:space:];|&()])(cd|pushd)([[:space:];|&]|$)[^;|&]*")
  return 1
}

# abs_outside TEXT WORKTREE TMPDIR: true when any absolute path in TEXT lies
# outside the allowed roots.
abs_outside() {
  local text="$1" wt="$2" tmp="$3" tok sanitized
  sanitized="$(printf '%s' "$text" | sed -E 's/([()<>|;&=])/ \1 /g')"
  while IFS= read -r tok || [ -n "$tok" ]; do
    [ -n "$tok" ] || continue
    case "$tok" in /*)
      if path_outside "$tok" "$wt" "$tmp"; then return 0; fi ;;
    esac
  done < <(operands_of "$sanitized")
  return 1
}
emit_decision() {
  local file="$1" cls="$2" text="$3"
  text="$(printf '%s' "$text" | cut -c1-200)"
  jq -n --arg class "$cls" --arg command "$text" '{class:$class,command:$command}' >>"$file"
}

# classify_side EVENTS WORKTREE TMPDIR DECISIONS: judge every reviewed call
# (permission_resolved with decided_by == reviewer, joined to its
# tool_call_requested) into DECISIONS as JSONL.
classify_side() {
  local ev="$1" wt="$2" tmp="$3" decisions="$4"
  local aid req name argstype arg text ntext narg kind
  : >"$decisions"
  while IFS= read -r aid || [ -n "$aid" ]; do
    [ -n "$aid" ] || continue
    req="$(jq -c --arg a "$aid" 'select(.kind=="tool_call_requested" and .action_id==$a)
      | .payload' "$ev" 2>/dev/null | head -n 1)"
    if [ -z "$req" ]; then
      emit_decision "$decisions" "unknown" "unknown"
      continue
    fi
    name="$(printf '%s' "$req" | jq -r '.name // ""' 2>/dev/null)"
    argstype="$(printf '%s' "$req" | jq -r '.arguments | type' 2>/dev/null)"
    if [ "$argstype" != "object" ]; then
      arg="$(printf '%s' "$req" | jq -c '.arguments' 2>/dev/null)"
      emit_decision "$decisions" "unknown" "$name $arg"
      continue
    fi
    # Fiber's shell tool is "shell" (bash rows); its write and edit tools
    # take the path as .arguments.path, like the classifier's write/edit rows.
    case "$name" in
      bash|shell)
        kind="bash"
        arg="$(printf '%s' "$req" | jq -r '.arguments.command
          | if type=="string" then . else tojson end' 2>/dev/null)"
        text="$name $arg" ;;
      write|edit)
        kind="$name"
        arg="$(printf '%s' "$req" | jq -r '.arguments.path
          | if type=="string" then . else tojson end' 2>/dev/null)"
        text="$name $arg" ;;
      *)
        arg="$(printf '%s' "$req" | jq -c '.arguments' 2>/dev/null)"
        emit_decision "$decisions" "unknown" "$name $arg"
        continue ;;
    esac
    ntext="$(normalize_text "$text" "$wt" "$tmp")"
    narg="$(normalize_text "$arg" "$wt" "$tmp")"
    if match_table "$SANDBOX_NEEDS_OUT" "$ntext" "$kind"; then
      emit_decision "$decisions" "needs_out" "$ntext"
    elif write_outside "$kind" "$ntext" "$narg" "$wt" "$tmp"; then
      emit_decision "$decisions" "needs_out" "$ntext"
    elif match_table "$SANDBOX_UNKNOWN" "$ntext" "$kind"; then
      emit_decision "$decisions" "unknown" "$ntext"
    elif [ "$kind" = "bash" ] \
      && { cd_outside "$ntext" "$wt" "$tmp" || abs_outside "$ntext" "$wt" "$tmp"; }; then
      emit_decision "$decisions" "unknown" "$ntext"
    else
      emit_decision "$decisions" "contained" "$ntext"
    fi
  done <<<"$(jq -r 'select(.kind=="permission_resolved" and .payload.decided_by=="reviewer")
    | .action_id // ""' "$ev" 2>/dev/null)"
}

# write_prompt BRIEF WORKTREE BRANCH: the brief plus the no-push wrapper line.
write_prompt() {
  local brief="$1" wt="$2" branch="$3"
  { cat "$brief"
    printf '\n%s\n' "Canary run: work only in $wt. Commit your work locally on branch $branch. Do not push, and do not open a PR."
  }
}

# canary_worktree CLONE TICKET SIDE: the worktree path for one side, next
# to the clone and named after it.
canary_worktree() {
  local clone="$1" ticket="$2" side="$3"
  printf '%s/%s-canary-%s-%s' "$(dirname "$clone")" "$(basename "$clone")" "$ticket" "$side"
}

# fiber_provider_of MODEL: the provider of a fiber/<provider>/<model> id,
# with an optional :thinking suffix ignored by stopping at the second slash.
# Prints the provider; returns 1 with no output for any other shape or for
# a provider outside [A-Za-z0-9][A-Za-z0-9_-]*, so no crafted id reaches cp.
fiber_provider_of() {
  local rest="${1:-}"
  case "$rest" in
    fiber/*/*) rest="${rest#fiber/}" ;;
    *) return 1 ;;
  esac
  local provider="${rest%%/*}"
  [ -n "$provider" ] || return 1
  [ -n "${rest#*/}" ] || return 1
  case "$provider" in
    [A-Za-z0-9]*)
      case "$provider" in
        *[!A-Za-z0-9_-]*) return 1 ;;
      esac
      printf '%s\n' "$provider" ;;
    *) return 1 ;;
  esac
}

# reviewer_source CONFIG PROVIDER PROVIDER_FILE: the reviewer pick for a
# flag-less run, printed on two lines: the source ("config" or "package")
# then the pick. Only the real config's providers.<provider>.reviewer_model
# is read from the config; the package default is the provider file's
# .reviewer_model, then extension.json's. An unreadable or invalid file, or
# a pick that is not a non-empty string, is no source from that location.
# Returns 1 when no source names a reviewer. Only reads.
reviewer_source() {
  local config="$1" provider="$2" prov_file="$3" pick
  pick="$(jq -r --arg p "$provider" \
    '.providers[$p].reviewer_model | select(type == "string" and length > 0)' \
    "$config" 2>/dev/null)" || pick=""
  if [ -n "$pick" ]; then
    printf 'config\n%s\n' "$pick"
    return 0
  fi
  pick="$(jq -r '.reviewer_model | select(type == "string" and length > 0)' \
    "$prov_file" 2>/dev/null)" || pick=""
  if [ -z "$pick" ]; then
    pick="$(jq -r '.reviewer_model | select(type == "string" and length > 0)' \
      "${prov_file%/providers/*}/extension.json" 2>/dev/null)" || pick=""
  fi
  [ -n "$pick" ] || return 1
  printf 'package\n%s\n' "$pick"
}

# clean_ticket CLONE TICKET OUT [--force]: remove whatever exists of the
# ticket's two worktrees and two branches, then the <side>/worktree files.
# Without --force a dirty worktree refuses (git's message, return 1).
# Idempotent: with nothing left it returns 0.
clean_ticket() {
  local clone="$1" ticket="$2" out="$3" force="${4:-}" side wt branch
  for side in pi fiber; do
    wt="$(canary_worktree "$clone" "$ticket" "$side")"
    [ -e "$wt" ] || continue
    if [ "$force" = "--force" ]; then
      git -C "$clone" worktree remove --force "$wt" || return 1
    else
      git -C "$clone" worktree remove "$wt" || return 1
    fi
  done
  git -C "$clone" worktree prune || return 1
  for side in pi fiber; do
    branch="canary/$ticket-$side"
    if git -C "$clone" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$clone" branch -D "$branch" >/dev/null || return 1
    fi
  done
  rm -f "$out/pi/worktree" "$out/fiber/worktree"
  return 0
}

cmd_run() {
  [ $# -ge 2 ] || { usage; return 2; }
  local ticket="$1" brief="$2"
  shift 2
  local gate="" repo="$DEFAULT_REPO" clone="" out="" pi_model="$PI_MODEL" fiber_model="$FIBER_MODEL" fiber_reviewer_model="" thinking=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --gate) [ $# -ge 2 ] || { err "--gate needs a value"; return 2; }; gate="$2"; shift 2 ;;
      --repo) [ $# -ge 2 ] || { err "--repo needs a value"; return 2; }; repo="$2"; shift 2 ;;
      --clone) [ $# -ge 2 ] || { err "--clone needs a value"; return 2; }; clone="$2"; shift 2 ;;
      --out) [ $# -ge 2 ] || { err "--out needs a value"; return 2; }; out="$2"; shift 2 ;;
      --pi-model) [ $# -ge 2 ] || { err "--pi-model needs a value"; return 2; }; pi_model="$2"; shift 2 ;;
      --fiber-model) [ $# -ge 2 ] || { err "--fiber-model needs a value"; return 2; }; fiber_model="$2"; shift 2 ;;
      --fiber-reviewer-model)
        [ $# -ge 2 ] && [ -n "$2" ] || { err "--fiber-reviewer-model needs a value"; return 2; }
        case "$2" in
          *[[:space:]]*) err "--fiber-reviewer-model needs a value"; return 2 ;;
        esac
        fiber_reviewer_model="$2"; shift 2 ;;
      --thinking) [ $# -ge 2 ] && [ -n "$2" ] || { err "--thinking needs a value"; return 2; }; thinking="$2"; shift 2 ;;
      --*) err "unknown flag $1"; return 2 ;;
      *) err "unexpected argument $1"; return 2 ;;
    esac
  done
  if [ -n "$thinking" ]; then
    pi_model="$pi_model:$thinking"
    fiber_model="$fiber_model:$thinking"
  fi
  [[ "$ticket" =~ ^[0-9A-Za-z._-]+$ ]] || { err "bad ticket '$ticket'"; return 2; }
  [ -n "$gate" ] || { err "--gate is required"; return 2; }
  [ -f "$brief" ] || { err "brief file $brief missing"; return 2; }
  # The provider comes from the final fiber model id, after --thinking is
  # applied above; a malformed id is a usage error before any side effect.
  local fiber_provider
  fiber_provider="$(fiber_provider_of "$fiber_model")" \
    || { usage; return 2; }
  # The owner's real home is read before FIBER_HOME points at the isolated
  # one below. Only the extensions/<name> directory that provides this
  # provider is copied; credentials and config never leave the real home.
  local real_fiber_home="${REAL_FIBER_HOME:-${FIBER_HOME:-$HOME/.fiber}}"
  local ext_dir="" cand
  for cand in "$real_fiber_home"/extensions/*/providers/"$fiber_provider".json; do
    [ -f "$cand" ] || continue
    ext_dir="${cand%/providers/*}"
    break
  done
  if [ -z "$ext_dir" ]; then
    err "The provider $fiber_provider is not installed in $real_fiber_home. Run fiber extension install ${fiber_provider%%-*}."
    return 2
  fi
  # A provider without an env credential needs a credential file the
  # isolated home never gets, so the run stops here, before the pi arm
  # spends anything. Credentials are never copied; the owner rules.
  if [ -z "$(jq -r '.credential.env // empty' "$cand")" ]; then
    err "The provider $fiber_provider needs a credential file under $real_fiber_home/credentials, which the isolated home does not get. Not copied; owner ruling needed."
    return 2
  fi
  # A symlink in the extension tree could point back into the real home,
  # so the copy below refuses the tree unless every file in it is real.
  if [ -n "$(find "$ext_dir" -type l)" ]; then
    err "Refusing to copy $ext_dir: the extension tree holds a symlink."
    return 2
  fi
  # With no --fiber-reviewer-model the reviewer comes from the real
  # config's providers.<provider>.reviewer_model or the provider
  # package's default; with no source the run stops here, before any pi
  # spend. Only reads; nothing is created before this point.
  local reviewer_origin="" reviewer_pick=""
  if [ -n "$fiber_reviewer_model" ]; then
    reviewer_origin="flag"
    reviewer_pick="$fiber_reviewer_model"
  else
    local reviewer_resolved=""
    if reviewer_resolved="$(reviewer_source "$real_fiber_home/config.json" "$fiber_provider" "$cand")"; then
      reviewer_origin="${reviewer_resolved%%$'\n'*}"
      reviewer_pick="${reviewer_resolved#*$'\n'}"
    else
      err "no reviewer model for provider $fiber_provider: pass --fiber-reviewer-model <provider>/<model>"
      return 2
    fi
  fi
  # Resolve Fiber before any worktree, job or output dir exists, and pin the
  # binary so delegate runs the same one the summary records.
  local fiber_bin fiber_version
  fiber_bin="$(resolve_fiber_bin)" \
    || { err "no Fiber binary: set FIBER_BIN or put fiber on PATH"; return 2; }
  fiber_version="$("$fiber_bin" --version 2>/dev/null)" \
    || { err "$fiber_bin --version failed"; return 2; }
  fiber_version="$(printf '%s' "$fiber_version" | head -n 1)"
  export FIBER_BIN="$fiber_bin"
  local repo_name="${repo##*/}"
  [ -n "$repo_name" ] || { err "bad --repo '$repo'"; return 2; }
  [ -z "$clone" ] && clone="$HOME/work/$repo_name"
  [ -z "$out" ] && out="$HOME/.cache/agents/canary/$ticket"
  # The Fiber lane gets an isolated home under the out dir, so it never
  # touches the owner's real home; metrics read it through FIBER_HOME.
  # The export is absolute: the lane runs in its worktree, where a
  # relative --out would resolve to a different directory.
  mkdir -p "$out/fiber-home"
  export FIBER_HOME="$(cd "$out/fiber-home" && pwd)"
  # Seed the isolated home with only the provider's extension directory, as
  # real files: the lane starts with its provider installed and nothing else.
  mkdir -p "$FIBER_HOME/extensions" \
    || { err "cannot create $FIBER_HOME/extensions"; return 2; }
  cp -R "$ext_dir" "$FIBER_HOME/extensions/" \
    || { err "cannot copy $ext_dir to $FIBER_HOME/extensions"; return 2; }
  git -C "$clone" rev-parse --git-common-dir >/dev/null 2>&1 \
    || { err "clone $clone is not a git checkout"; return 2; }
  clone="$(cd "$clone" && pwd)"
  local pi_branch="canary/$ticket-pi" fiber_branch="canary/$ticket-fiber"
  local pi_wt fiber_wt
  pi_wt="$(canary_worktree "$clone" "$ticket" pi)"
  fiber_wt="$(canary_worktree "$clone" "$ticket" fiber)"
  local b
  for b in "$pi_branch" "$fiber_branch"; do
    if git -C "$clone" show-ref --verify --quiet "refs/heads/$b"; then
      err "branch $b exists; run 'canary.sh clean $ticket' first"
      return 2
    fi
  done
  if [ -e "$pi_wt" ] || [ -e "$fiber_wt" ]; then
    err "a worktree path exists; run 'canary.sh clean $ticket' first"
    return 2
  fi
  if [ -f "$out/pi/worktree" ] || [ -f "$out/fiber/worktree" ]; then
    err "a previous run exists in $out; run 'canary.sh clean $ticket' first"
    return 2
  fi
  # Clean leaves the isolated home behind, so a stale config.json from an
  # earlier reviewer must not survive it: remove just that file, after
  # every setup refusal above, then write the new one. A package pick
  # needs no file; Fiber applies its own default.
  rm -f "$FIBER_HOME/config.json" \
    || { err "cannot remove $FIBER_HOME/config.json"; return 2; }
  case "$reviewer_origin" in
    flag)
      jq -n --arg m "$reviewer_pick" '{reviewer:{model:$m}}' \
        >"$FIBER_HOME/config.json" \
        || { rm -f "$FIBER_HOME/config.json"; err "cannot write $FIBER_HOME/config.json"; return 2; } ;;
    config)
      jq -n --arg p "$fiber_provider" --arg m "$reviewer_pick" \
        '{providers:{($p):{reviewer_model:$m}}}' >"$FIBER_HOME/config.json" \
        || { rm -f "$FIBER_HOME/config.json"; err "cannot write $FIBER_HOME/config.json"; return 2; } ;;
  esac
  # Record the clone before any git mutation, so clean can always find it.
  mkdir -p "$out"
  printf '%s\n' "$clone" >"$out/clone"
  git -C "$clone" fetch origin >/dev/null 2>&1 \
    || { err "git fetch origin failed in $clone"; return 2; }
  local base
  base="$(git -C "$clone" rev-parse origin/main 2>/dev/null)" \
    || { err "no origin/main in $clone"; return 2; }
  local side
  for side in pi fiber; do
    if [ -d "$out/$side" ] && [ ! -f "$out/$side/worktree" ]; then
      rm -rf "$out/$side"
    fi
    mkdir -p "$out/$side"
  done
  for side in pi fiber; do
    local wt branch
    wt="$(canary_worktree "$clone" "$ticket" "$side")"
    branch="canary/$ticket-$side"
    if ! git -C "$clone" worktree add -b "$branch" "$wt" "$base" >/dev/null 2>&1; then
      err "worktree add failed for $wt"
      clean_ticket "$clone" "$ticket" "$out" --force \
        || err "cleanup failed; run 'canary.sh clean $ticket' after fixing the cause"
      return 2
    fi
    printf '%s' "$wt" >"$out/$side/worktree"
  done
  write_prompt "$brief" "$pi_wt" "$pi_branch" >"$out/pi/prompt.md"
  write_prompt "$brief" "$fiber_wt" "$fiber_branch" >"$out/fiber/prompt.md"

  local delegate_bin="${DELEGATE_BIN:-delegate}"
  FIBER_EVENTS_ROOT="${FIBER_HOME:-$HOME/.fiber}"
  local jobs_dir="${TMPDIR:-/tmp}/delegate-jobs"
  local tmp_root="${TMPDIR:-/tmp}"
  : >"$out/pi/delegate.log"
  : >"$out/fiber/delegate.log"

  # Sequential (#244): pi's run and watch end before Fiber's run starts, so
  # each side's wall time covers only its own job. Each run returns a job id
  # at once; its watch then blocks until the job ends.
  local pi_start pi_out pi_rc pi_id pi_run_ok=1 pi_note="" pi_wrc=0 pi_end
  local fiber_start fiber_out fiber_rc fiber_id fiber_run_ok=1 fiber_note="" fiber_wrc=0 fiber_end
  pi_start="$(now_ms)"
  pi_out="$("$delegate_bin" run --model "$pi_model" --cwd "$pi_wt" \
    --prompt-file "$out/pi/prompt.md" 2>>"$out/pi/delegate.log")"
  pi_rc=$?
  pi_id="$(printf '%s' "$pi_out" | tail -n 1 | tr -d '[:space:]')"
  if [ "$pi_rc" -ne 0 ]; then pi_run_ok=0; pi_note="delegate run failed (exit $pi_rc)";
  elif [ -z "$pi_id" ]; then pi_run_ok=0; pi_note="delegate run printed no job id"; fi
  if [ "$pi_run_ok" -eq 1 ]; then
    "$delegate_bin" watch "$pi_id" >>"$out/pi/delegate.log" 2>&1
    pi_wrc=$?
  fi
  pi_end="$(now_ms)"

  fiber_start="$(now_ms)"
  fiber_out="$("$delegate_bin" run --model "$fiber_model" --cwd "$fiber_wt" \
    --prompt-file "$out/fiber/prompt.md" 2>>"$out/fiber/delegate.log")"
  fiber_rc=$?
  fiber_id="$(printf '%s' "$fiber_out" | tail -n 1 | tr -d '[:space:]')"
  if [ "$fiber_rc" -ne 0 ]; then fiber_run_ok=0; fiber_note="delegate run failed (exit $fiber_rc)";
  elif [ -z "$fiber_id" ]; then fiber_run_ok=0; fiber_note="delegate run printed no job id"; fi
  if [ "$fiber_run_ok" -eq 1 ]; then
    "$delegate_bin" watch "$fiber_id" >>"$out/fiber/delegate.log" 2>&1
    fiber_wrc=$?
  fi
  fiber_end="$(now_ms)"

  # Gates run in each worktree once both jobs end.
  local pi_gate_exit fiber_gate_exit
  ( cd "$pi_wt" && bash -c "$gate" ) >"$out/pi/gate.log" 2>&1
  pi_gate_exit=$?
  printf '%s' "$pi_gate_exit" >"$out/pi/gate.exit"
  ( cd "$fiber_wt" && bash -c "$gate" ) >"$out/fiber/gate.log" 2>&1
  fiber_gate_exit=$?
  printf '%s' "$fiber_gate_exit" >"$out/fiber/gate.exit"

  run_side_metrics pi "$pi_wt" "$pi_id" "$pi_model" "$pi_run_ok" "$pi_note" \
    "$pi_wrc" "$pi_start" "$pi_end" "$out" "$base" "$jobs_dir" "$tmp_root"
  run_side_metrics fiber "$fiber_wt" "$fiber_id" "$fiber_model" "$fiber_run_ok" "$fiber_note" \
    "$fiber_wrc" "$fiber_start" "$fiber_end" "$out" "$base" "$jobs_dir" "$tmp_root"

  write_summary "$ticket" "$base" "$out" "$fiber_bin" "$fiber_version"

  if [ -f "$out/pi/.harness" ] || [ -f "$out/fiber/.harness" ]; then
    rm -f "$out/pi/.harness" "$out/fiber/.harness"
    return 1
  fi
  return 0
}

# run_side_metrics SIDE WORKTREE ID MODEL RUN_OK RUN_NOTE WATCH_RC START_MS
#   END_MS OUT BASE JOBS_DIR TMPROOT: diff, dirty flag and metrics.json.
run_side_metrics() {
  local side="$1" wt="$2" id="$3" model="$4" run_ok="$5" run_note="$6"
  local wrc="$7" start_ms="$8" end_ms="$9" out="${10}" base="${11}"
  local jobs_dir="${12}" tmp_root="${13}"
  local dir="$out/$side" rec="" outcome="" harness=0
  # A worktree that is gone (after clean, or a report) keeps the saved diff
  # and dirty flag; only a live worktree is read again.
  local dirty="false"
  if [ -d "$wt" ]; then
    git -C "$wt" diff "$base...HEAD" >"$dir/diff.patch" 2>/dev/null || true
    [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] && dirty="true"
  elif [ -f "$dir/metrics.json" ]; then
    dirty="$(jq -r '.dirty // false' "$dir/metrics.json" 2>/dev/null)"
  fi
  local notes="$dir/.notes.txt" den_tsv="$dir/.denials.tsv" decisions="$dir/.decisions.jsonl"
  : >"$notes"; : >"$den_tsv"; : >"$decisions"
  [ -n "$run_note" ] && printf '%s\n' "$run_note" >>"$notes"
  if [ "$run_ok" -eq 1 ] && [ "$wrc" -ne 0 ]; then
    printf 'delegate watch failed (exit %s)\n' "$wrc" >>"$notes"
    harness=1
  fi
  if [ "$run_ok" -eq 0 ]; then harness=1; fi
  # The job record is saved into the side's dir, so report still has it
  # after $TMPDIR is cleaned; a saved copy is preferred.
  if [ -n "$id" ] && [ ! -f "$dir/job.json" ] && [ -f "$jobs_dir/$id.json" ]; then
    cp "$jobs_dir/$id.json" "$dir/job.json"
  fi
  if [ -n "$id" ] && [ -f "$dir/job.json" ]; then
    rec="$dir/job.json"
  elif [ "$run_ok" -eq 1 ] && [ "$wrc" -eq 0 ]; then
    printf 'job record missing: %s/%s.json\n' "$jobs_dir" "$id" >>"$notes"
    harness=1
  fi
  if [ "$harness" -eq 1 ]; then
    outcome="harness_error"
    : >"$dir/.harness"
  elif [ -n "$rec" ]; then
    outcome="$(jq -r '.status // "unknown"' "$rec" 2>/dev/null)"
    [ "$outcome" = "null" ] && outcome="unknown"
  else
    outcome="harness_error"
    : >"$dir/.harness"
  fi
  local wall_ms=$((end_ms - start_ms))
  local m_in="" m_out="" m_cr="" m_total="" m_main="" m_reviewer=""
  local rc="" rt="" per="" split=""
  if [ "$side" = "pi" ]; then
    if [ -n "$rec" ]; then
      m_total="$(pi_metrics "$rec" "" | sed -n 3p)"
      m_in="$(pi_metrics "$rec" "" | sed -n 4p)"
      m_out="$(pi_metrics "$rec" "" | sed -n 5p)"
      m_cr="$(pi_metrics "$rec" "" | sed -n 6p)"
      m_main="$m_total"
    fi
    m_reviewer="0"
    rc="0"
  else
    if [ -n "$rec" ]; then
      # Save the run's event log beside the record: report reads the copy
      # when the Fiber home is gone. A copy already there is kept.
      if [ ! -f "$out/fiber/events.jsonl" ]; then
        saved_sid="$(jq -r '.resume.sessionId // ""' "$rec" 2>/dev/null)"
        if [ -n "$saved_sid" ] && [ "$saved_sid" != "null" ]; then
          saved_ev="$(fiber_events "$saved_sid")"
          if [ -n "$saved_ev" ]; then cp "$saved_ev" "$out/fiber/events.jsonl"; fi
        fi
      fi
      m_total="$(fiber_metrics "$rec" | sed -n 3p)"
      m_in="$(fiber_metrics "$rec" | sed -n 4p)"
      m_out="$(fiber_metrics "$rec" | sed -n 5p)"
      m_cr="$(fiber_metrics "$rec" | sed -n 6p)"
      split="$(fiber_side_split "$rec" "$wt" "$tmp_root" "$notes" "$den_tsv" "$decisions")"
      m_main="$(printf '%s' "$split" | jq -r '.main_cost')"
      m_reviewer="$(printf '%s' "$split" | jq -r '.reviewer_cost')"
      # A null main line (a zero-token call with no cost) nulls the split;
      # total minus reviewer is what the main agent cost (#238).
      if [ "$m_main" = "null" ] && [ -n "$m_total" ] && [ "$m_total" != "null" ] \
        && [ -n "$m_reviewer" ] && [ "$m_reviewer" != "null" ]; then
        m_main="$(jq -n --argjson t "$m_total" --argjson r "$m_reviewer" '$t - $r')"
      fi
      rt="$(printf '%s' "$split" | jq -r '.reviewer_tokens')"
      rc="$(printf '%s' "$split" | jq -r '.reviewed_calls')"
    else
      printf 'fiber events unavailable without a job record\n' >>"$notes"
    fi
  fi
  if [ -n "$rt" ] && [ "$rt" != "null" ] && [ -n "$rc" ] && [ "$rc" != "null" ] && [ "$rc" != "0" ]; then
    per="$(jq -n --argjson a "$rt" --argjson b "$rc" '$a / $b' 2>/dev/null)"
  fi
  local denials_json sandbox_json notes_json
  denials_json="$(jq -R -s 'split("\n") | map(select(length > 0 and . != "EVENTS_MISSING")
    | split("\t") | {action_id: .[0], decided_by: .[1], reason: .[2], command: .[3]})' "$den_tsv")"
  sandbox_json="$(jq -s '{contained: {count: ([.[] | select(.class=="contained")] | length),
      commands: ([.[] | select(.class=="contained") | .command])},
    needs_out: {count: ([.[] | select(.class=="needs_out")] | length),
      commands: ([.[] | select(.class=="needs_out") | .command])},
    unknown: {count: ([.[] | select(.class=="unknown")] | length),
      commands: ([.[] | select(.class=="unknown") | .command])}}' "$decisions")"
  notes_json="$(jq -R -s 'split("\n") | map(select(length > 0))' "$notes")"
  # Main and reviewer tokens (#238): pi is all main; fiber splits its usage
  # by action_id (reviewer_split). $split is null for pi and for a missing record.
  jq -n --arg side "$side" --arg outcome "$outcome" --arg job_id "$id" \
    --arg model "$model" --arg base "$base" --argjson dirty "$dirty" \
    --arg wall "$wall_ms" --arg in "$m_in" --arg o "$m_out" --arg cr "$m_cr" \
    --arg total "$m_total" --arg main "$m_main" --arg reviewer "$m_reviewer" \
    --arg rc "$rc" --arg per "$per" \
    --argjson denials "$denials_json" --argjson sandbox "$sandbox_json" \
    --argjson notes "$notes_json" --argjson split "${split:-null}" \
    'def n: if . == "" or . == "null" then null else tonumber end;
    {side: $side, outcome: $outcome,
     job_id: (if $job_id == "" then null else $job_id end),
     model: $model, base: $base, dirty: $dirty, wall_ms: ($wall | tonumber),
     tokens: {input: ($in | n), output: ($o | n), cache_read: ($cr | n)},
     tokens_main: (if $side == "pi" then {input: ($in | n), output: ($o | n), cache_read: ($cr | n)}
       else $split.main_io end),
     tokens_reviewer: (if $side == "pi" then {input: 0, output: 0, cache_read: 0}
       else $split.reviewer_io end),
     cost: {total: ($total | n), main: ($main | n), reviewer: ($reviewer | n)},
     reviewed_calls: ($rc | n), denials: $denials, sandbox: $sandbox,
     per_review_tokens_est: ($per | n), notes: $notes}' >"$dir/metrics.json"
  rm -f "$notes" "$den_tsv" "$decisions"
}

# fiber_side_split RECORD WORKTREE TMPROOT NOTES DEN_TSV DECISIONS: print the
# reviewer_split JSON for the fiber side; denials and sandbox classes go to
# DEN_TSV and DECISIONS, notes appended to NOTES.
fiber_side_split() {
  local rec="$1" wt="$2" tmp_root="$3" notes="$4" den_tsv="$5" decisions="$6"
  local sid ev split
  sid="$(jq -r '.resume.sessionId // ""' "$rec" 2>/dev/null)"
  ev=""
  if [ -n "$sid" ] && [ "$sid" != "null" ]; then
    ev="$(fiber_events "$sid")"
  fi
  if [ -z "$ev" ] || ! jq empty "$ev" >/dev/null 2>&1; then
    printf 'fiber events missing or unparsable; cost split unknown\n' >>"$notes"
    printf '{"main_cost":null,"reviewer_cost":null,"reviewer_tokens":null,"reviewed_calls":null}'
    return 0
  fi
  split="$(reviewer_split "$ev")"
  printf '%s' "$split"
  denials_for "$rec" >"$den_tsv" 2>/dev/null || true
  if grep -qx 'EVENTS_MISSING' "$den_tsv" 2>/dev/null; then
    : >"$den_tsv"
    printf 'fiber events missing or unparsable; cost split unknown\n' >>"$notes"
  fi
  classify_side "$ev" "$wt" "$tmp_root" "$decisions"
}

# load_side SIDE OUT: set S_* display fields for the summary table.
load_side() {
  local side="$1" out="$2" metrics
  metrics="$out/$side/metrics.json"
  S_model="$(jq -r .model "$metrics")"
  S_outcome="$(jq -r .outcome "$metrics")"
  if [ "$(cat "$out/$side/gate.exit")" = "0" ]; then S_gate="pass"; else S_gate="fail"; fi
  S_wall="$(fmt_wall "$(jq -r .wall_ms "$metrics")")"
  S_tmain="$(jq -r '.tokens_main | "\(.input // "unknown")/\(.output // "unknown")/\(.cache_read // "unknown")"' "$metrics")"
  S_trev="$(jq -r '.tokens_reviewer | "\(.input // "unknown")/\(.output // "unknown")/\(.cache_read // "unknown")"' "$metrics")"
  S_main="$(fmt_money "$(jq -r '.cost.main // "null"' "$metrics")")"
  S_rev="$(fmt_money "$(jq -r '.cost.reviewer // "null"' "$metrics")")"
  S_rc="$(jq -r '.reviewed_calls // "unknown"' "$metrics")"
  S_den="$(jq -r '.denials | length' "$metrics")"
  S_con="$(jq -r '.sandbox.contained.count' "$metrics")"
  S_need="$(jq -r '.sandbox.needs_out.count' "$metrics")"
  S_unk="$(jq -r '.sandbox.unknown.count' "$metrics")"
  S_per="$(jq -r '.per_review_tokens_est // "unknown"' "$metrics")"
}

# write_summary TICKET BASE OUT FIBER_BIN FIBER_VERSION: the two-column
# comparison table, under a line naming the Fiber binary and its version.
write_summary() {
  local ticket="$1" base="$2" out="$3" fiber_bin="$4" fiber_version="$5"
  local pi_outcome fiber_outcome pi_gate fiber_gate pi_wall fiber_wall
  local pi_tmain fiber_tmain pi_trev fiber_trev
  local pi_main fiber_main pi_rev fiber_rev pi_rc fiber_rc
  local pi_den fiber_den pi_con fiber_con pi_need fiber_need pi_unk fiber_unk
  local pi_per fiber_per pi_mod fiber_mod
  load_side pi "$out"
  pi_outcome="$S_outcome"; pi_gate="$S_gate"; pi_wall="$S_wall"
  pi_tmain="$S_tmain"; pi_trev="$S_trev"
  pi_main="$S_main"; pi_rev="$S_rev"; pi_rc="$S_rc"; pi_den="$S_den"
  pi_con="$S_con"; pi_need="$S_need"; pi_unk="$S_unk"; pi_per="$S_per"; pi_mod="$S_model"
  load_side fiber "$out"
  fiber_outcome="$S_outcome"; fiber_gate="$S_gate"; fiber_wall="$S_wall"
  fiber_tmain="$S_tmain"; fiber_trev="$S_trev"
  fiber_main="$S_main"; fiber_rev="$S_rev"; fiber_rc="$S_rc"; fiber_den="$S_den"
  fiber_con="$S_con"; fiber_need="$S_need"; fiber_unk="$S_unk"; fiber_per="$S_per"; fiber_mod="$S_model"
  {
    printf '# Canary %s\n\n' "$ticket"
    printf 'Base `%s`.\n\n' "$base"
    printf 'Fiber `%s`, `fiber --version`: `%s`.\n\n' "$fiber_bin" "$fiber_version"
    printf '| metric | pi | fiber |\n'
    printf '| --- | --- | --- |\n'
    printf '| model | %s | %s |\n' "$pi_mod" "$fiber_mod"
    printf '| outcome | %s | %s |\n' "$pi_outcome" "$fiber_outcome"
    printf '| gate | %s | %s |\n' "$pi_gate" "$fiber_gate"
    printf '| wall | %s | %s |\n' "$pi_wall" "$fiber_wall"
    printf '| tokens main in/out/cache-read | %s | %s |\n' "$pi_tmain" "$fiber_tmain"
    printf '| tokens reviewer in/out/cache-read | %s | %s |\n' "$pi_trev" "$fiber_trev"
    printf '| cost main | %s | %s |\n' "$pi_main" "$fiber_main"
    printf '| cost reviewer | %s | %s |\n' "$pi_rev" "$fiber_rev"
    printf '| reviewed calls | %s | %s |\n' "$pi_rc" "$fiber_rc"
    printf '| denials | %s | %s |\n' "$pi_den" "$fiber_den"
    printf '| contained | %s | %s |\n' "$pi_con" "$fiber_con"
    printf '| needs_out | %s | %s |\n' "$pi_need" "$fiber_need"
    printf '| unknown | %s | %s |\n' "$pi_unk" "$fiber_unk"
    printf '| per-review tokens est | %s | %s |\n' "$pi_per" "$fiber_per"
  } >"$out/summary.md"
}

cmd_clean() {
  [ $# -ge 1 ] || { usage; return 2; }
  local ticket="$1"
  shift
  local out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) [ $# -ge 2 ] || { err "--out needs a value"; return 2; }; out="$2"; shift 2 ;;
      --*) err "unknown flag $1"; return 2 ;;
      *) err "unexpected argument $1"; return 2 ;;
    esac
  done
  [[ "$ticket" =~ ^[0-9A-Za-z._-]+$ ]] || { err "bad ticket '$ticket'"; return 2; }
  [ -z "$out" ] && out="$HOME/.cache/agents/canary/$ticket"
  if [ ! -f "$out/clone" ]; then
    printf 'canary: nothing to clean for %s (no %s/clone)\n' "$ticket" "$out"
    return 0
  fi
  local clone
  clone="$(cat "$out/clone")"
  git -C "$clone" rev-parse --git-common-dir >/dev/null 2>&1 \
    || { err "clone $clone (from $out/clone) is not a git checkout"; return 1; }
  clean_ticket "$clone" "$ticket" "$out" || return 1
  return 0
}

cmd_report() {
  [ $# -ge 1 ] || { usage; return 2; }
  local ticket="$1"
  shift
  local out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) [ $# -ge 2 ] || { err "--out needs a value"; return 2; }; out="$2"; shift 2 ;;
      --*) err "unknown flag $1"; return 2 ;;
      *) err "unexpected argument $1"; return 2 ;;
    esac
  done
  [[ "$ticket" =~ ^[0-9A-Za-z._-]+$ ]] || { err "bad ticket '$ticket'"; return 2; }
  [ -z "$out" ] && out="$HOME/.cache/agents/canary/$ticket"
  [ -f "$out/pi/metrics.json" ] && [ -f "$out/fiber/metrics.json" ] \
    || { err "no finished run for $ticket in $out"; return 2; }
  local base side wt id model wall run_ok note tmp
  local jobs_dir="${TMPDIR:-/tmp}/delegate-jobs" tmp_root="${TMPDIR:-/tmp}"
  export FIBER_EVENTS_ROOT="${FIBER_HOME:-$HOME/.fiber}"
  # Check that every source exists before any write. The saved copies (a
  # run's job records and Fiber event log) come first; $TMPDIR and the Fiber
  # home are the fallback. Contents are checked after the rebuild.
  local missing="" chk_side chk_id
  for chk_side in pi fiber; do
    chk_id="$(jq -r '.job_id // ""' "$out/$chk_side/metrics.json" 2>/dev/null)"
    if [ -z "$chk_id" ] || [ "$chk_id" = "null" ]; then
      missing="$missing $chk_side job id;"
    elif [ ! -f "$out/$chk_side/job.json" ] && [ ! -f "$jobs_dir/$chk_id.json" ]; then
      missing="$missing $chk_side job record;"
    fi
    [ -f "$out/$chk_side/gate.exit" ] || missing="$missing $chk_side gate.exit;"
  done
  local fiber_rec="$out/fiber/job.json" fiber_sid="" fiber_ev=""
  if [ ! -f "$fiber_rec" ]; then
    fiber_rec="$jobs_dir/$(jq -r '.job_id // ""' "$out/fiber/metrics.json" 2>/dev/null).json"
  fi
  if [ -f "$out/fiber/events.jsonl" ]; then
    fiber_ev="$out/fiber/events.jsonl"
  elif [ -f "$fiber_rec" ]; then
    fiber_sid="$(jq -r '.resume.sessionId // ""' "$fiber_rec" 2>/dev/null)"
    if [ -n "$fiber_sid" ] && [ "$fiber_sid" != "null" ]; then
      fiber_ev="$(fiber_events "$fiber_sid")"
    fi
  fi
  if [ -z "$fiber_ev" ] || ! jq empty "$fiber_ev" >/dev/null 2>&1; then
    missing="$missing fiber event log;"
  fi
  if [ -n "$missing" ]; then
    err "cannot report $ticket:$missing nothing was written to $out"
    return 1
  fi
  if [ -f "$out/fiber/events.jsonl" ]; then
    CANARY_FIBER_EVENTS="$out/fiber/events.jsonl"
    export CANARY_FIBER_EVENTS
  fi
  base="$(jq -r .base "$out/pi/metrics.json")"
  # The binary and version the run recorded; a summary from before #235 has
  # no such line, so they read unknown.
  # The line splits on backticks: Fiber, path, version (fields 2 and 6).
  local fiber_bin="unknown" fiber_version="unknown" line bt='`'
  line="$(awk -F "$bt" '/^Fiber / { print $2 "\t" $6; exit }' "$out/summary.md" 2>/dev/null)"
  if [ -n "$line" ]; then fiber_bin="${line%%"$TAB"*}"; fiber_version="${line#*"$TAB"}"; fi

  # Rebuild in a scratch dir inside $out (the same filesystem), so the saved
  # files are replaced only after every rebuilt file checks out.
  tmp="$(mktemp -d "$out/.report.XXXXXX")" || { err "cannot make a scratch dir in $out"; return 1; }
  if ! cp -R "$out/pi" "$out/fiber" "$tmp/"; then
    rm -rf "$tmp"; err "cannot copy the saved outputs of $ticket"; return 1
  fi
  for side in pi fiber; do
    if [ -f "$out/$side/worktree" ]; then
      wt="$(cat "$out/$side/worktree")"
    else
      wt="$(canary_worktree "$(cat "$out/clone" 2>/dev/null)" "$ticket" "$side")"
    fi
    id="$(jq -r '.job_id // ""' "$out/$side/metrics.json")"
    model="$(jq -r '.model // "unknown"' "$out/$side/metrics.json")"
    wall="$(jq -r '.wall_ms // 0' "$out/$side/metrics.json")"
    run_ok=1; note=""
    if [ -z "$id" ] || [ "$id" = "null" ]; then
      id=""; run_ok=0; note="no job id in the saved metrics"
    fi
    run_side_metrics "$side" "$wt" "$id" "$model" "$run_ok" "$note" 0 0 "$wall" \
      "$tmp" "$base" "$jobs_dir" "$tmp_root"
  done
  write_summary "$ticket" "$base" "$tmp" "$fiber_bin" "$fiber_version"

  # Validate the rebuild. Any failure leaves the saved files as they were.
  local problems="" notes_text=""
  for side in pi fiber; do
    if [ -f "$tmp/$side/.harness" ]; then
      problems="$problems $side rebuild failed;"
      notes_text="$notes_text$(cat "$tmp/$side/.notes.txt" 2>/dev/null)"
    fi
    if ! jq -e '(.status | type == "string") and (.status | length > 0)' \
      "$tmp/$side/job.json" >/dev/null 2>&1; then
      problems="$problems $side job record has no status or does not parse;"
    fi
    if ! jq empty "$tmp/$side/metrics.json" >/dev/null 2>&1; then
      problems="$problems $side metrics.json does not parse;"
    elif ! jq -e '(.outcome | type == "string") and (.outcome | length > 0)' \
      "$tmp/$side/metrics.json" >/dev/null 2>&1; then
      problems="$problems $side outcome is empty;"
    fi
    # Every number the saved file had for tokens or cost must still be one.
    if ! jq -e -n --slurpfile o "$out/$side/metrics.json" --slurpfile b "$tmp/$side/metrics.json" '
      [$o[0] | paths(type == "number") | select(.[0] == "tokens_main" or .[0] == "tokens_reviewer" or .[0] == "cost")] as $ps
      | [$ps[] | . as $p | select(($b[0] | getpath($p) | type) != "number")] | length == 0' \
      >/dev/null 2>&1; then
      problems="$problems $side tokens or cost lost a number;"
    fi
  done
  if [ -n "$problems" ]; then
    rm -rf "$tmp"
    err "cannot report $ticket:$problems nothing was replaced in $out"
    [ -n "$notes_text" ] && printf '%s\n' "$notes_text" >&2
    return 1
  fi
  for side in pi fiber; do
    mv "$tmp/$side/metrics.json" "$out/$side/metrics.json" || { rm -rf "$tmp"; err "could not replace $out/$side/metrics.json"; return 1; }
  done
  mv "$tmp/summary.md" "$out/summary.md" || { rm -rf "$tmp"; err "could not replace $out/summary.md"; return 1; }
  rm -rf "$tmp"
  return 0
}

cmd="${1:-}"
if [ $# -gt 0 ]; then shift; fi
case "$cmd" in
  run) cmd_run "$@" ;;
  clean) cmd_clean "$@" ;;
  report) cmd_report "$@" ;;
  *) usage; exit 2 ;;
esac

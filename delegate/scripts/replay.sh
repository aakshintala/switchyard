#!/usr/bin/env bash
# replay.sh: replay finished pi jobs on the Fiber backend and compare.
#
# One script reruns finished pi jobs through `delegate run --model fiber/<model>`
# in sealed scratch clones and writes a Markdown comparison with the pass bar
# applied. Fixture-driven: inputs come from REPLAY_JOBS_DIR (default
# $TMPDIR/delegate-jobs) and REPLAY_PI_SESSIONS (default ~/.pi/agent/sessions).
# Usage:
#   replay.sh select [--out DIR] [--total 30] [--force]
#   replay.sh run [--out DIR] [--share muse|codex|all] [--batch 3 | --job ID...] [--fresh]
#   replay.sh report [--out DIR] [--verdicts FILE]
#   replay.sh all [--out DIR] [--share muse] [--verdicts FILE]
#
# Exit codes: 0 ok; 1 a job errored in the harness (others still run);
# 2 bad usage or missing input.
set -uo pipefail

SOL_MODEL="openai/gpt-6.1-sol"
MUSE_MODEL="opencode-go/muse-spark-1.3-contributor"
LUNA_MODEL="openai/gpt-6-luna:xhigh"
MUSE_FIBER_MODEL="fiber/opencode-go/muse-spark-1.3-contributor"

TAB="$(printf '\t')"

# Shared cost/token/denial extraction (factored out, see #223).
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/metrics.sh"

default_out() {
  printf '%s/.cache/agents/fiber-replay' "${HOME:-/tmp}"
}

err() {
  printf 'replay: %s\n' "$*" >&2
}

# iso_epoch TS: ISO-8601 UTC (millis optional) to epoch seconds.
iso_epoch() {
  local ts="$1" base out
  base="${ts%%.*}"
  base="${base%Z}"
  if [ "$(uname)" = "Darwin" ]; then
    out="$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "$base" +%s 2>/dev/null)" || return 1
  else
    out="$(date -u -d "$ts" +%s 2>/dev/null)" || return 1
  fi
  printf '%s' "$out"
}

# file_epoch PATH: mtime as epoch seconds.
file_epoch() {
  if [ "$(uname)" = "Darwin" ]; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

fiber_model_for() {
  case "$1" in
    "$MUSE_MODEL") printf '%s' "$MUSE_FIBER_MODEL" ;;
    *) printf '' ;;
  esac
}

share_for() {
  case "$1" in
    "$MUSE_MODEL") printf 'muse' ;;
    "$SOL_MODEL"|"$LUNA_MODEL") printf 'codex' ;;
    *) printf '' ;;
  esac
}

# repo_from_url URL: last two path components, without a .git suffix.
repo_from_url() {
  local u="$1" rest tmp owner
  u="${u%/}"
  u="${u%.git}"
  u="${u//:/\/}"
  rest="${u##*/}"
  tmp="${u%/*}"
  owner="${tmp##*/}"
  [ -n "$owner" ] && [ -n "$rest" ] || return 1
  printf '%s/%s' "$owner" "$rest"
}

# resolve_repo CWD: print owner/name via git when CWD exists, else the repo map.
# Map file rows are prefix<TAB>owner/name; the first matching prefix wins.
resolve_repo() {
  local cwd="$1" url line prefix repo
  if [ -d "$cwd" ]; then
    url="$(git -C "$cwd" remote get-url origin 2>/dev/null)" || return 1
    repo_from_url "$url" || return 1
    return 0
  fi
  if [ -n "${REPLAY_REPO_MAP:-}" ]; then
    [ -f "$REPLAY_REPO_MAP" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *"$TAB"*) ;;
        *) continue ;;
      esac
      prefix="${line%%$TAB*}"
      repo="${line#*$TAB}"
      [ -n "$prefix" ] || continue
      if [ "${cwd:0:${#prefix}}" = "$prefix" ]; then
        printf '%s' "$repo"
        return 0
      fi
    done <"$REPLAY_REPO_MAP"
    return 1
  fi
  case "$cwd" in
    /Users/aakshintala/work/fiber-worktrees/*) printf 'aakshintala/fiber' ;;
    /Users/aakshintala/work/switchyard-*) printf 'aakshintala/switchyard' ;;
    *) return 1 ;;
  esac
}

# find_session SID: newest session file ending _SID.jsonl under the sessions tree.
find_session() {
  find "${REPLAY_PI_SESSIONS:-$HOME/.pi/agent/sessions}" -name "*_$1.jsonl" 2>/dev/null | sort | tail -n 1
}

# session_ts FILE: timestamp of the session header line.
session_ts() {
  jq -r 'select(.type=="session") | .timestamp // ""' "$1" 2>/dev/null | head -n 1
}

# session_cwd FILE: cwd of the session header line (type == "session").
session_cwd() {
  jq -r 'select(.type=="session") | .cwd // ""' "$1" 2>/dev/null | head -n 1
}

# brief_text FILE: text of the first user message (string or text parts).
brief_text() {
  jq -rs '[.[] | select(.type=="message" and .message.role=="user")
    | .message.content
    | if type=="string" then .
      elif type=="array" then map(select(.type=="text") | .text // "") | join("")
      else "" end][0] // ""' "$1" 2>/dev/null
}

# strip_status TEXT: drop delegate's trailing status block (the text after the
# last blank-line --- separator, when that tail names a STATUS: line).
# A brief that uses a --- rule of its own keeps it.
strip_status() {
  local text="$1" tail
  case "$text" in
    *$'\n\n---\n\n'*)
      tail="${text##*$'\n\n---\n\n'}"
      case "$tail" in
        *STATUS:*) printf '%s' "${text%$'\n\n---\n\n'*}" ;;
        *) printf '%s' "$text" ;;
      esac
      ;;
    *) printf '%s' "$text" ;;
  esac
}

# brief_refs: sorted unique absolute .md paths named on stdin.
# Quoted paths (single, double or backtick) may contain spaces; anything with
# spaces must be quoted, unquoted spaced text splits into tokens and drops.
brief_refs() {
  local text quoted bare
  text="$(cat)"
  quoted="$(printf '%s' "$text" | tr '`"\047' '\n\n\n' | sed -e 's/^[[:space:]]*//' -e 's/[.,;:]*$//' | grep -E '^/[^()<>]*\.md$')"
  bare="$(printf '%s' "$text" | sed -e 's/`[^`]*`/ /g' -e 's/"[^"]*"/ /g' -e "s/'[^']*'/ /g" | tr -s '[:space:]' '\n' | sed -e 's/^[(<]*//' -e 's/[.,;:)>]*$//' | grep -E '^/[^()<>]*\.md$')"
  printf '%s\n%s\n' "$quoted" "$bare" | sed '/^$/d' | sort -u
}

# mirror_path REPO: print the mirror dir for owner/name.
mirror_path() {
  printf '%s/mirrors/%s.git' "$SEL_OUT" "$(printf '%s' "$1" | tr '/' '_')"
}

# ensure_mirror REPO: clone the bare mirror once; prints its path.
ensure_mirror() {
  local repo="$1" base url mirror
  mirror="$(mirror_path "$repo")"
  if [ ! -d "$mirror" ]; then
    mkdir -p "$SEL_OUT/mirrors"
    if [ -n "${REPLAY_REMOTE_BASE:-}" ]; then
      base="${REPLAY_REMOTE_BASE%/}"
      url="$base/$repo.git"
    else
      url="https://github.com/$repo.git"
    fi
    git clone -q --mirror "$url" "$mirror" 2>/dev/null || return 1
  fi
  printf '%s' "$mirror"
}

# snapshot_job ID PROMPT GATE BRIEFS: write DIR/jobs/<id>/ files. BRIEFS is
# newline-separated absolute paths.
snapshot_job() {
  local id="$1" prompt="$2" gate="$3" briefs="$4"
  local dest="$SEL_OUT/jobs/$id" n=0 ref copy
  mkdir -p "$dest/briefs"
  printf '%s' "$prompt" >"$dest/prompt.md"
  printf '%s' "$gate" >"$dest/gate.txt"
  : >"$dest/briefs/map.tsv"
  if [ -n "$briefs" ]; then
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      n=$((n + 1))
      copy="$n-$(basename "$ref")"
      cp "$ref" "$dest/briefs/$copy"
      printf '%s\t%s\n' "$ref" "$copy" >>"$dest/briefs/map.tsv"
    done <<<"$briefs"
  fi
}

# select_job JOBFILE: print one SKIP or CAND line. CAND fields:
# CAND epoch id share pimodel fibermodel repo sha session cwd started.
# As a side effect an eligible job's snapshot is written to DIR/jobs/<id>/.
select_job() {
  local job="$1" id status resumed backend model gate head sid cwd session sts epoch
  local prompt stripped ref norm_cwd refs outside missing soon share fibermodel repo mirror
  id="$(basename "$job" .json)"
  status="$(jq -r '.status // ""' "$job" 2>/dev/null)"
  if [ "$status" = "RUNNING" ]; then printf 'SKIP\t%s\tstill running\n' "$id"; return 0; fi
  if [ -z "$status" ]; then printf 'SKIP\t%s\tunreadable record\n' "$id"; return 0; fi
  resumed="$(jq -r '.resumedFrom // ""' "$job" 2>/dev/null)"
  if [ -n "$resumed" ]; then printf 'SKIP\t%s\tresumed turn\n' "$id"; return 0; fi
  backend="$(jq -r '.resume.backend // ""' "$job" 2>/dev/null)"
  if [ "$backend" != "pi" ]; then printf 'SKIP\t%s\tbackend %s\n' "$id" "${backend:-none}"; return 0; fi
  model="$(jq -r '.resume.model // ""' "$job" 2>/dev/null)"
  case "$model" in
    "$SOL_MODEL"|"$MUSE_MODEL"|"$LUNA_MODEL") ;;
    *) printf 'SKIP\t%s\tmodel not in replay set\n' "$id"; return 0 ;;
  esac
  gate="$(jq -r '.resume.gate // ""' "$job" 2>/dev/null)"
  if [ -z "$gate" ]; then printf 'SKIP\t%s\tno gate\n' "$id"; return 0; fi
  head="$(jq -r '.result.changeSet.headBefore // ""' "$job" 2>/dev/null)"
  if [ -z "$head" ] || [ "$head" = "null" ]; then printf 'SKIP\t%s\tno base commit\n' "$id"; return 0; fi
  sid="$(jq -r '.resume.sessionId // ""' "$job" 2>/dev/null)"
  session=""
  if [ -n "$sid" ] && [ "$sid" != "null" ]; then
    session="$(find_session "$sid")"
  fi
  if [ -z "$session" ]; then printf 'SKIP\t%s\tno pi session %s\n' "$id" "${sid:-none}"; return 0; fi
  cwd="$(session_cwd "$session")"
  if [ -z "$cwd" ] || [ "$cwd" = "null" ]; then
    cwd="$(jq -r '.resume.cwd // ""' "$job" 2>/dev/null)"
  fi
  case "$cwd" in
    *review-pr.run.*) printf 'SKIP\t%s\treview-pr temp cwd\n' "$id"; return 0 ;;
  esac
  repo="$(resolve_repo "$cwd")" || { printf 'SKIP\t%s\tno repo for cwd\n' "$id"; return 0; }
  mirror="$(ensure_mirror "$repo")" || { printf 'SKIP\t%s\tmirror unavailable\n' "$id"; return 0; }
  git -C "$mirror" cat-file -e "$head^{commit}" 2>/dev/null \
    || { printf 'SKIP\t%s\tbase commit missing from mirror\n' "$id"; return 0; }
  sts="$(session_ts "$session")"
  epoch="$(iso_epoch "$sts" 2>/dev/null)" || epoch=""
  if [ -z "$sts" ] || [ -z "$epoch" ]; then
    printf 'SKIP\t%s\tno pi session %s\n' "$id" "$sid"
    return 0
  fi
  prompt="$(brief_text "$session")"
  if [ -z "$prompt" ]; then printf 'SKIP\t%s\tno brief in pi session\n' "$id"; return 0; fi
  norm_cwd="${cwd%/}"
  refs="$(printf '%s' "$prompt" | brief_refs)"
  outside=""
  if [ -n "$refs" ]; then
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      case "$ref" in
        "$norm_cwd"/*) continue ;;
      esac
      outside="$outside$ref
"
    done <<<"$refs"
  fi
  missing=""; soon=""
  if [ -n "$outside" ]; then
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      if [ ! -f "$ref" ]; then missing="$ref"; break; fi
      if [ "$(file_epoch "$ref")" -gt "$epoch" ]; then soon="$ref"; break; fi
    done <<<"$outside"
  fi
  if [ -n "$missing" ]; then printf 'SKIP\t%s\tbrief %s missing\n' "$id" "$missing"; return 0; fi
  if [ -n "$soon" ]; then printf 'SKIP\t%s\tbrief %s newer than session start\n' "$id" "$soon"; return 0; fi
  share="$(share_for "$model")"
  fibermodel="$(fiber_model_for "$model")"
  stripped="$(strip_status "$prompt")"
  snapshot_job "$id" "$stripped" "$gate" "$outside"
  printf 'CAND\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$epoch" "$id" "$share" "$model" "$fibermodel" "$repo" "$head" "$session" "$cwd" "$sts"
}

cmd_select() {
  local out total force=0
  out="$(default_out)"
  total=30
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) [ $# -ge 2 ] || { err "--out needs a value"; return 2; }; out="$2"; shift 2 ;;
      --total) [ $# -ge 2 ] || { err "--total needs a value"; return 2; }; total="$2"; shift 2 ;;
      --force) force=1; shift ;;
      --*) err "unknown flag $1"; return 2 ;;
      *) err "unexpected argument $1"; return 2 ;;
    esac
  done
  case "$total" in
    ''|*[!0-9]*|0*) err "--total must be a positive number"; return 2 ;;
  esac
  local jobs_dir="${REPLAY_JOBS_DIR:-${TMPDIR:-/tmp}/delegate-jobs}"
  [ -d "$jobs_dir" ] || { err "jobs dir $jobs_dir missing"; return 2; }
  SEL_OUT="$out"
  mkdir -p "$out" || return 1
  if [ -f "$out/manifest.tsv" ] && [ "$force" -ne 1 ]; then
    err "$out/manifest.tsv exists; pass --force to overwrite"
    return 2
  fi
  if [ "$force" -eq 1 ]; then
    rm -rf "$out/jobs"
  fi
  local sol_n muse_n luna_n
  sol_n=$((total * 60 / 100))
  muse_n=$((total * 30 / 100))
  luna_n=$((total - sol_n - muse_n))
  local skipped="$out/skipped.tsv" new_manifest="$out/manifest.tsv.new"
  : >"$skipped"
  : >"$new_manifest"
  local f res kind rest pimodel list want spec
  for f in "$jobs_dir"/*.json; do
    [ -e "$f" ] || continue
    res="$(select_job "$f")"
    kind="${res%%$TAB*}"
    rest="${res#*$TAB}"
    if [ "$kind" = "SKIP" ]; then
      printf '%s\n' "$rest" >>"$skipped"
      continue
    fi
    pimodel="$(printf '%s' "$rest" | cut -f4)"
    case "$pimodel" in
      "$SOL_MODEL") list="$out/.list-sol.tsv" ;;
      "$MUSE_MODEL") list="$out/.list-muse.tsv" ;;
      "$LUNA_MODEL") list="$out/.list-luna.tsv" ;;
      *) err "candidate with unknown model $pimodel"; return 1 ;;
    esac
    printf '%s\n' "$rest" >>"$list"
  done
  local id admitted
  for spec in "sol:$sol_n" "muse:$muse_n" "luna:$luna_n"; do
    want="${spec##*:}"
    case "${spec%%:*}" in
      sol) list="$out/.list-sol.tsv" ;;
      muse) list="$out/.list-muse.tsv" ;;
      luna) list="$out/.list-luna.tsv" ;;
    esac
    [ -f "$list" ] || continue
    if [ "$want" -eq 0 ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        rm -rf "$out/jobs/$(printf '%s' "$line" | cut -f2)"
      done <"$list"
      continue
    fi
    admitted="$out/.admitted.$$.txt"
    # newest first, job id breaks ties; keep the quota
    sort -t"$TAB" -k1,1rn -k2,2 "$list" | head -n "$want" >"$out/.kept.$$.tsv"
    # project CAND rows (epoch id share pimodel fibermodel repo sha session cwd sts)
    # to manifest rows, preserving empty fields (read would collapse them)
    awk -F'\t' 'NF{print $2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7"\t"$8"\t"$9"\t"$10}' \
      "$out/.kept.$$.tsv" >>"$new_manifest"
    cut -f2 "$out/.kept.$$.tsv" >"$admitted"
    # drop snapshots of eligible rows the quota cut
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      id="$(printf '%s' "$line" | cut -f2)"
      grep -qx "$id" "$admitted" 2>/dev/null || rm -rf "$out/jobs/$id"
    done <"$list"
    rm -f "$list" "$out/.kept.$$.tsv" "$admitted"
  done
  # newest-first across models, id breaks ties
  sort -t"$TAB" -k9,9r -k1,1 "$new_manifest" -o "$new_manifest"
  mv "$new_manifest" "$out/manifest.tsv"
  sort -o "$skipped" "$skipped"
  printf 'select: %s jobs, %s skipped -> %s\n' \
    "$(wc -l <"$out/manifest.tsv" | tr -d ' ')" "$(wc -l <"$skipped" | tr -d ' ')" "$out"
}

# ---------- run ----------

# sb_quote S: sandbox-exec profile string literal.
sb_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# literal_replace FILE OLD NEW: literal (non-regex) string replacement via jq.
literal_replace() {
  local file="$1" old="$2" new="$3" tmp
  [ -n "$old" ] || return 0
  tmp="$file.rew$$"
  jq -Rrs --arg o "$old" --arg n "$new" 'split($o)|join($n)' "$file" >"$tmp" \
    && mv "$tmp" "$file"
}

# replace_cwd FILE OLD NEW: rewrite only complete path prefixes of OLD to NEW.
# OLD must already be normalised (no trailing slash). A match counts only when
# followed by "/", end of text, whitespace, a quote or backtick, one of )]}>,;:
# or a "." that ends a sentence. Anything else continues a sibling name
# (/old/job-2, /old/job+2, /old/jobé when OLD is /old/job) and is left alone:
# an unrewritten reference stays sealed, a wrong rewrite corrupts the brief.
replace_cwd() {
  local file="$1" old="$2" new="$3" tmp
  [ -n "$old" ] || return 0
  tmp="$file.rew$$"
  jq -Rjs --arg o "$old" --arg n "$new" '
    def bound: . == "" or startswith("/")
      or test("^[\\s\"'"'"'`)\\]}>,;:]") or test("^\\.(\\s|$)");
    split($o) as $p
    | reduce range(1; $p | length) as $k
        ($p[0]; . + (if ($p[$k] | bound) then $n else $o end) + $p[$k])
  ' "$file" >"$tmp" \
    && mv "$tmp" "$file"
}

# build_fiber OUT: fetch, checkout and build fiber; exports FIBER_BIN.
build_fiber() {
  local out="$1" src bin
  if [ -z "${REPLAY_FIBER_SRC:-}" ]; then
    err "REPLAY_FIBER_SRC is not set (a dedicated fiber clone, never ~/work/fiber)"
    return 2
  fi
  src="${REPLAY_FIBER_SRC%/}"
  if [ "$src" = "$HOME/work/fiber" ]; then
    err "REPLAY_FIBER_SRC must not be ~/work/fiber"
    return 2
  fi
  [ -d "$src/.git" ] || { err "fiber source $src is not a git checkout"; return 2; }
  case "$out" in /*) ;; *) out="$(pwd)/$out" ;; esac
  case "$src" in /*) ;; *) src="$(pwd)/$src" ;; esac
  git -C "$src" fetch -q origin >>"$out/fiber-build.log" 2>&1 \
    || { err "git fetch origin failed in $src"; return 1; }
  git -C "$src" checkout -q --detach origin/main >>"$out/fiber-build.log" 2>&1 \
    || { err "checkout origin/main failed in $src"; return 1; }
  : >"$out/fiber-build.log"
  CARGO_TARGET_DIR="$out/fiber-target" cargo build --manifest-path "$src/Cargo.toml" --release --bin fiber \
    >>"$out/fiber-build.log" 2>&1 || { err "fiber build failed (see $out/fiber-build.log)"; return 1; }
  bin="$out/fiber-target/release/fiber"
  [ -x "$bin" ] || { err "fiber build produced no binary at $bin"; return 1; }
  FIBER_BIN="$bin"
  export FIBER_BIN
}

# setup_fiber_home OUT: copy model/reviewer config once.
setup_fiber_home() {
  local fh="$1/fiber-home" src="$HOME/.fiber"
  [ -d "$fh" ] && return 0
  mkdir -p "$fh"
  chmod 700 "$fh"
  [ -f "$src/config.json" ] && { cp "$src/config.json" "$fh/"; chmod 600 "$fh/config.json"; }
  [ -d "$src/credentials" ] && { cp -r "$src/credentials" "$fh/"; chmod -R go-rwx "$fh/credentials"; }
  [ -d "$src/extensions" ] && { cp -R "$src/extensions" "$fh/"; }
  [ -e "$src/rules" ] && { cp -R "$src/rules" "$fh/"; }
  return 0
}

# sh_quote S: shell single-quoted literal for baking paths into shims.
sh_quote() {
  local s="$1" esc
  esc="$(printf '%s' "$s" | sed "s/'/'\\\\''/g")"
  printf "'%s'" "$esc"
}

# clean_recorded_tmpdir RUNDIR: remove the recorded TMPDIR only when it is
# exactly mktemp's /tmp/frp-XXXXXX form, a non-symlink dir owned by us.
# Anything else is left alone with a warning: the sealed replay can rewrite
# DIR, so a recorded path is untrusted.
clean_recorded_tmpdir() {
  local rundir="$1" oldtmp suffix
  [ -f "$rundir/tmpdir" ] || return 0
  oldtmp="$(cat "$rundir/tmpdir" 2>/dev/null)"
  case "$oldtmp" in
    /tmp/frp-??????) ;;
    *) err "warning: leaving unexpected tmpdir $oldtmp"; return 0 ;;
  esac
  suffix="${oldtmp#/tmp/frp-}"
  case "$suffix" in
    ''|*[!A-Za-z0-9]*) err "warning: leaving unexpected tmpdir $oldtmp"; return 0 ;;
  esac
  if [ ! -d "$oldtmp" ] || [ -L "$oldtmp" ] || [ ! -O "$oldtmp" ]; then
    err "warning: leaving unexpected tmpdir $oldtmp"
    return 0
  fi
  rm -rf "$oldtmp"
}

# run_tmp RUNDIR: the replay's TMPDIR, a unique short dir per prep recorded in
# RUNDIR/tmpdir. Short and outside DIR on purpose: Fiber and its tests put
# unix sockets under TMPDIR, and a socket path must fit in 103 bytes, which
# a TMPDIR under DIR/runs/<uuid>/ does not leave room for.
run_tmp() {
  cat "$1/tmpdir" 2>/dev/null
}

# write_seal RUNDIR: seal.sb profile, outward shims, gitconfig, tmp dir.
# The shims log execution to RUNDIR/outward.log: gh logs and exits 1, curl
# and wget log then exec the real binary, git logs outward subcommands
# (push, remote, send-email, request-pull) then execs the real git.
write_seal() {
  local rundir="$1" home="${HOME:-/tmp}" realtmp="${RUN_REALTMP:-/tmp}" tmpdir
  local seal_path p old_ifs real_git real_curl real_wget q_log q_git q_curl q_wget
  {
    printf '(version 1)\n(allow default)\n'
    printf '(deny file-write* (subpath %s))\n' "$(sb_quote "$home")"
    printf '(allow file-write* (subpath %s) (subpath %s) (subpath %s))\n' \
      "$(sb_quote "$RUN_OUT")" "$(sb_quote "$home/.cargo/registry")" "$(sb_quote "$home/.cargo/git")"
    printf '(deny file-write* (subpath %s))\n' "$(sb_quote "$realtmp/delegate-jobs")"
    printf '(deny file-read* (subpath %s) (subpath %s) (literal %s))\n' \
      "$(sb_quote "$home/.ssh")" "$(sb_quote "$home/.config/gh")" "$(sb_quote "$home/.git-credentials")"
  } >"$rundir/seal.sb"
  mkdir -p "$rundir/shim"
  seal_path=""
  old_ifs="$IFS"
  IFS=:
  set -f
  for p in $PATH; do
    if [ "$p" != "$rundir/shim" ] && [ -n "$p" ]; then
      if [ -z "$seal_path" ]; then seal_path="$p"; else seal_path="$seal_path:$p"; fi
    fi
  done
  set +f
  IFS="$old_ifs"
  real_git="$(PATH="$seal_path" command -v git 2>/dev/null)"
  real_curl="$(PATH="$seal_path" command -v curl 2>/dev/null)"
  real_wget="$(PATH="$seal_path" command -v wget 2>/dev/null)"
  case "$real_git" in /*) ;; *) real_git="" ;; esac
  case "$real_curl" in /*) ;; *) real_curl="" ;; esac
  case "$real_wget" in /*) ;; *) real_wget="" ;; esac
  tmpdir="$(mktemp -d /tmp/frp-XXXXXX)" || return 1
  printf '%s' "$tmpdir" >"$rundir/tmpdir"
  : >"$rundir/outward.log"
  q_log="$(sh_quote "$rundir/outward.log")"
  cat >"$rundir/shim/gh" <<EOF
#!/bin/sh
if [ \$# -gt 0 ]; then printf 'gh %s\n' "\$*" >>$q_log; else printf 'gh\n' >>$q_log; fi
echo "gh disabled in replay" >&2
exit 1
EOF
  chmod +x "$rundir/shim/gh"
  q_curl="$(sh_quote "$real_curl")"
  if [ -n "$real_curl" ]; then
    cat >"$rundir/shim/curl" <<EOF
#!/bin/sh
if [ \$# -gt 0 ]; then printf 'curl %s\n' "\$*" >>$q_log; else printf 'curl\n' >>$q_log; fi
exec $q_curl "\$@"
EOF
  else
    cat >"$rundir/shim/curl" <<EOF
#!/bin/sh
if [ \$# -gt 0 ]; then printf 'curl %s\n' "\$*" >>$q_log; else printf 'curl\n' >>$q_log; fi
echo "curl disabled in replay: real binary not found" >&2
exit 127
EOF
  fi
  chmod +x "$rundir/shim/curl"
  q_wget="$(sh_quote "$real_wget")"
  if [ -n "$real_wget" ]; then
    cat >"$rundir/shim/wget" <<EOF
#!/bin/sh
if [ \$# -gt 0 ]; then printf 'wget %s\n' "\$*" >>$q_log; else printf 'wget\n' >>$q_log; fi
exec $q_wget "\$@"
EOF
  else
    cat >"$rundir/shim/wget" <<EOF
#!/bin/sh
if [ \$# -gt 0 ]; then printf 'wget %s\n' "\$*" >>$q_log; else printf 'wget\n' >>$q_log; fi
echo "wget disabled in replay: real binary not found" >&2
exit 127
EOF
  fi
  chmod +x "$rundir/shim/wget"
  q_git="$(sh_quote "$real_git")"
  if [ -n "$real_git" ]; then
    cat >"$rundir/shim/git" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    push|remote|send-email|request-pull)
      if [ \$# -gt 0 ]; then printf 'git %s\n' "\$*" >>$q_log; else printf 'git\n' >>$q_log; fi
      break
      ;;
  esac
done
exec $q_git "\$@"
EOF
  else
    cat >"$rundir/shim/git" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    push|remote|send-email|request-pull)
      if [ \$# -gt 0 ]; then printf 'git %s\n' "\$*" >>$q_log; else printf 'git\n' >>$q_log; fi
      echo "git disabled in replay: real binary not found" >&2
      exit 127
      ;;
  esac
done
echo "git disabled in replay: real binary not found" >&2
exit 127
EOF
  fi
  chmod +x "$rundir/shim/git"
  printf '[user]\n\tname = replay\n\temail = replay@invalid\n' >"$rundir/gitconfig"
}

# run_in_seal RUNDIR CMD...: sandbox plus the replay environment.
run_in_seal() {
  local rundir="$1" suffix
  shift
  suffix="${RUN_TARGET_SUFFIX:-replay}"
  "${REPLAY_SANDBOX_EXEC:-sandbox-exec}" -f "$rundir/seal.sb" env \
    "PATH=$rundir/shim:$PATH" \
    "GH_TOKEN=replay-invalid" \
    "GITHUB_TOKEN=replay-invalid" \
    GIT_CONFIG_NOSYSTEM=1 \
    "GIT_CONFIG_GLOBAL=$rundir/gitconfig" \
    GIT_TERMINAL_PROMPT=0 \
    GIT_SSH_COMMAND=false \
    "TMPDIR=$(run_tmp "$rundir")" \
    "FIBER_HOME=$RUN_OUT/fiber-home" \
    "FIBER_BIN=$FIBER_BIN" \
    "CARGO_TARGET_DIR=$RUN_OUT/target/$suffix" \
    "$@"
}

# seal_check RUNDIR SCRATCH REPO: every probe must fail; else the seal is open.
seal_check() {
  local rundir="$1" scratch="$2" repo="$3" base probe
  base=".replay-seal-probe.$$.${RANDOM:-0}"
  probe="${HOME:-/tmp}/$base"
  if [ -e "$probe" ] || [ -L "$probe" ]; then
    err "seal probe $probe exists; refusing"
    return 1
  fi
  # set -C: exclusive create, so an open seal never writes through a link.
  if run_in_seal "$rundir" sh -c 'set -C; : >"$1"' _ "$probe" 2>/dev/null; then
    rm -f "$probe"
    err "seal open: home write probe succeeded"
    return 1
  fi
  if run_in_seal "$rundir" gh auth status >/dev/null 2>&1; then
    err "seal open: gh probe succeeded"
    return 1
  fi
  if run_in_seal "$rundir" git -C "$scratch" push --dry-run \
      "https://github.com/$repo.git" "HEAD:refs/heads/replay-seal-probe" >/dev/null 2>&1; then
    err "seal open: git push probe succeeded"
    return 1
  fi
  # probes above run through the shims; clear their log lines so the
  # replay starts with an empty outward log.
  : >"$rundir/outward.log"
  return 0
}

# manifest_row ID: the manifest line for a job id.
manifest_row() {
  awk -F'\t' -v id="$1" '$1==id{print; exit}' "$RUN_OUT/manifest.tsv"
}

row_field() {
  printf '%s' "$1" | cut -f"$2"
}

# prep_job ID FRESH: scratch clone, snapshot rewrite, seal files.
prep_job() {
  local id="$1" fresh="$2" row rundir mirror scratch cwd cwd_norm repo sha
  local mapline ref copy bylen
  row="$(manifest_row "$id")"
  repo="$(row_field "$row" 5)"
  sha="$(row_field "$row" 6)"
  cwd="$(row_field "$row" 8)"
  rundir="$RUN_OUT/runs/$id"
  if [ -e "$rundir" ] && [ "$fresh" -ne 1 ]; then
    err "run dir $rundir exists (pass --fresh to redo $id)"
    return 1
  fi
  if [ "$fresh" -eq 1 ] && [ -e "$rundir" ]; then
    clean_recorded_tmpdir "$rundir"
    rm -rf "$rundir"
  fi
  mkdir -p "$rundir"
  mirror="$(mirror_path "$repo")"
  git clone -q "$mirror" "$rundir/scratch" 2>/dev/null || { err "$id: clone failed"; return 1; }
  git -C "$rundir/scratch" checkout -q --detach "$sha" 2>/dev/null \
    || { err "$id: checkout $sha failed"; return 1; }
  git -C "$rundir/scratch" remote remove origin 2>/dev/null
  scratch="$rundir/scratch"
  case "$scratch" in
    "$HOME/.agents"/*) err "$id: scratch under ~/.agents refused"; return 1 ;;
  esac
  if [ "$scratch" = "$cwd" ]; then
    err "$id: scratch equals the original cwd"
    return 1
  fi
  cp "$RUN_OUT/jobs/$id/prompt.md" "$rundir/prompt.md"
  cp "$RUN_OUT/jobs/$id/gate.txt" "$rundir/gate.txt"
  rm -rf "$rundir/briefs"
  cp -r "$RUN_OUT/jobs/$id/briefs" "$rundir/briefs"
  cwd_norm="$cwd"
  while [ "${cwd_norm%/}" != "$cwd_norm" ] && [ "${#cwd_norm}" -gt 1 ]; do cwd_norm="${cwd_norm%/}"; done
  replace_cwd "$rundir/prompt.md" "$cwd_norm" "$scratch" || return 1
  replace_cwd "$rundir/gate.txt" "$cwd_norm" "$scratch" || return 1
  for f in "$rundir/briefs"/*; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "map.tsv" ] && continue
    replace_cwd "$f" "$cwd_norm" "$scratch" || return 1
  done
  # longest original path first, so a prefix ref cannot shadow a longer one
  bylen="$rundir/briefs/.map-bylen.tsv"
  awk -F'\t' '{print length($1) "\t" $0}' "$RUN_OUT/jobs/$id/briefs/map.tsv" \
    | sort -rn | cut -f2- >"$bylen"
  while IFS= read -r mapline; do
    [ -n "$mapline" ] || continue
    ref="${mapline%%$TAB*}"
    copy="${mapline#*$TAB}"
    literal_replace "$rundir/prompt.md" "$ref" "$rundir/briefs/$copy" || return 1
  done <"$bylen"
  rm -f "$bylen"
  write_seal "$rundir" || { err "$id: seal setup failed"; return 1; }
  RUN_TARGET_SUFFIX="$(printf '%s' "$repo" | tr '/' '_')"
  run_in_seal "$rundir" "$FIBER_BIN" version >"$rundir/version.txt" 2>&1 \
    || { err "$id: fiber version failed"; return 1; }
  return 0
}

# collect_notes ID RUNDIR SCRATCH: outward attempts from the execution log
# plus tool-call arguments that point outside the scratch.
collect_notes() {
  local id="$1" rundir="$2" scratch="$3" sid ev match line
  : >"$rundir/notes.txt"
  if [ -f "$rundir/outward.log" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      printf 'note: outward: %s\n' "$line" >>"$rundir/notes.txt"
    done <"$rundir/outward.log"
  fi
  sid="$(jq -r '.resume.sessionId // ""' "$rundir/record.json" 2>/dev/null)"
  if [ -z "$sid" ] || [ "$sid" = "null" ]; then
    printf 'note: no replay session id in record\n' >>"$rundir/notes.txt"
    return 0
  fi
  ev=""
  for f in "$RUN_OUT"/fiber-home/projects/*/sessions/"$sid"/events.jsonl; do
    [ -e "$f" ] || continue
    if [ -n "$ev" ]; then
      ev="AMBIGUOUS"
      break
    fi
    ev="$f"
  done
  if [ -z "$ev" ]; then
    printf 'note: fiber events missing\n' >>"$rundir/notes.txt"
    return 0
  fi
  if [ "$ev" = "AMBIGUOUS" ]; then
    printf 'note: fiber events ambiguous\n' >>"$rundir/notes.txt"
    return 0
  fi
  match="$(jq -r --arg home "$HOME" --arg scratch "$scratch" '
    select(.kind=="tool_call_requested")
    | .payload.name as $n
    | (.payload.arguments | if type=="string" then . else tojson end) as $a
    | ($n + " " + $a) as $cmd
    | select($cmd | (((contains($home + "/work/") or contains($home + "/.agents"))
            and (contains($scratch) | not))))
    | "note: " + $cmd[0:200]' "$ev" 2>/dev/null)"
  if [ -n "$match" ]; then
    printf '%s\n' "$match" >>"$rundir/notes.txt"
  fi
  return 0
}

# launch_job ID: delegate run + watch + record copy + notes (runs in background).
launch_job() {
  local id="$1" row rundir fibermodel gate newid
  row="$(manifest_row "$id")"
  fibermodel="$(row_field "$row" 4)"
  gate="$(cat "$RUN_OUT/runs/$id/gate.txt")"
  rundir="$RUN_OUT/runs/$id"
  RUN_TARGET_SUFFIX="$(printf '%s' "$(row_field "$row" 5)" | tr '/' '_')"
  newid="$(run_in_seal "$rundir" "$DELEGATE_BIN" run --model "$fibermodel" \
    --cwd "$rundir/scratch" --gate "$gate" --prompt-file "$rundir/prompt.md" 2>"$rundir/delegate.err")"
  newid="$(printf '%s' "$newid" | tail -n 1 | tr -d '[:space:]')"
  if [ -z "$newid" ]; then
    err "$id: delegate run printed no job id"
    return 1
  fi
  run_in_seal "$rundir" "$DELEGATE_BIN" watch "$newid" >>"$rundir/delegate.err" 2>&1 \
    || { err "$id: delegate watch failed"; return 1; }
  [ -f "$(run_tmp "$rundir")/delegate-jobs/$newid.json" ] \
    || { err "$id: replay record missing"; return 1; }
  cp "$(run_tmp "$rundir")/delegate-jobs/$newid.json" "$rundir/record.json"
  collect_notes "$id" "$rundir" "$rundir/scratch"
  return 0
}

cmd_run() {
  local out share batch batch_given=0 fresh=0 jobs_arg=""
  out="$(default_out)"
  share="all"
  batch=3
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) [ $# -ge 2 ] || { err "--out needs a value"; return 2; }; out="$2"; shift 2 ;;
      --share)
        [ $# -ge 2 ] || { err "--share needs a value"; return 2; }
        case "$2" in
          muse|codex|all) share="$2" ;;
          *) err "--share must be muse, codex or all"; return 2 ;;
        esac
        shift 2 ;;
      --batch)
        [ $# -ge 2 ] || { err "--batch needs a value"; return 2; }
        case "$2" in
          ''|*[!0-9]*|0*) err "--batch must be a positive number"; return 2 ;;
        esac
        batch="$2"; batch_given=1; shift 2 ;;
      --job)
        [ $# -ge 2 ] || { err "--job needs a value"; return 2; }
        jobs_arg="$jobs_arg$2
"; shift 2 ;;
      --fresh) fresh=1; shift ;;
      --*) err "unknown flag $1"; return 2 ;;
      *) err "unexpected argument $1"; return 2 ;;
    esac
  done
  if [ -n "$jobs_arg" ] && [ "$batch_given" -eq 1 ]; then
    err "--batch and --job exclude each other"
    return 2
  fi
  [ -f "$out/manifest.tsv" ] || { err "no manifest at $out/manifest.tsv (run select first)"; return 2; }
  RUN_OUT="$out"
  FIBER_EVENTS_ROOT="$RUN_OUT/fiber-home"
  SEL_OUT="$out"
  RUN_REALTMP="${TMPDIR:-/tmp}"
  DELEGATE_BIN="${DELEGATE_BIN:-delegate}"
  export RUN_OUT DELEGATE_BIN
  build_fiber "$out" || return $?
  setup_fiber_home "$out" || return 1
  "$DELEGATE_BIN" models >"$out/.models.txt" 2>"$out/delegate-models.err" \
    || { err "delegate models failed"; return 1; }
  # batch rows: manifest order, share filter, skip run dirs unless --fresh
  local selected="$out/.selected.$$.txt" line id idshare hasdir
  : >"$selected"
  if [ -n "$jobs_arg" ]; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      [ -n "$(manifest_row "$id")" ] || { err "unknown job $id"; return 2; }
      printf '%s\n' "$id" >>"$selected"
    done <<<"$jobs_arg"
  else
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      id="$(printf '%s' "$line" | cut -f1)"
      idshare="$(printf '%s' "$line" | cut -f2)"
      case "$share" in
        all) ;;
        *) [ "$idshare" = "$share" ] || continue ;;
      esac
      hasdir=0
      [ -e "$out/runs/$id" ] && hasdir=1
      if [ "$fresh" -eq 1 ] || [ "$hasdir" -eq 0 ]; then
        printf '%s\n' "$id" >>"$selected"
      fi
      [ "$(wc -l <"$selected" | tr -d ' ')" -ge "$batch" ] && break
    done <"$out/manifest.tsv"
  fi
  # refetch one mirror per repo in this run
  local repos="$out/.repos.$$.txt" repo
  : >"$repos"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    repo="$(row_field "$(manifest_row "$id")" 5)"
    grep -qxF "$repo" "$repos" 2>/dev/null || printf '%s\n' "$repo" >>"$repos"
  done <"$selected"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    git -C "$(mirror_path "$repo")" remote update >/dev/null 2>&1 \
      || err "warning: fetch of $repo mirror failed"
  done <"$repos"
  rm -f "$repos"
  # prep (sequential): pending markers, scratch clones, seal files
  local launch="$out/.launch.$$.txt" fibermodel row errcount=0
  : >"$launch"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    row="$(manifest_row "$id")"
    fibermodel="$(row_field "$row" 4)"
    if [ -z "$fibermodel" ]; then
      [ "$fresh" -eq 1 ] && rm -rf "$out/runs/$id"
      if [ ! -e "$out/runs/$id" ]; then
        mkdir -p "$out/runs/$id"
        printf 'pending: no fiber model until aakshintala/fiber#311\n' >"$out/runs/$id/pending.txt"
      fi
      continue
    fi
    if ! awk '{print $1}' "$out/.models.txt" | grep -qxF "$fibermodel"; then
      [ "$fresh" -eq 1 ] && rm -rf "$out/runs/$id"
      if [ ! -e "$out/runs/$id" ]; then
        mkdir -p "$out/runs/$id"
        printf 'pending: model %s unavailable\n' "$fibermodel" >"$out/runs/$id/pending.txt"
      fi
      continue
    fi
    if prep_job "$id" "$fresh"; then
      printf '%s\n' "$id" >>"$launch"
    else
      printf '%s\n' "$id" >"$out/runs/$id/error.txt" 2>/dev/null || true
      errcount=$((errcount + 1))
    fi
  done <"$selected"
  # seal self-check once, before any replay
  local first
  first="$(head -n 1 "$launch" 2>/dev/null)"
  if [ -n "$first" ]; then
    row="$(manifest_row "$first")"
    seal_check "$out/runs/$first" "$out/runs/$first/scratch" "$(row_field "$row" 5)" \
      || { rm -f "$selected" "$launch"; return 1; }
  fi
  # launch concurrently and wait for all
  local pid pids="" failed=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    launch_job "$id" &
    pids="$pids $!"
  done <"$launch"
  for pid in $pids; do
    wait "$pid" || failed=1
  done
  rm -f "$selected" "$launch"
  if [ "$errcount" -gt 0 ] || [ "$failed" -eq 1 ]; then
    return 1
  fi
  return 0
}

# ---------- report ----------

# pi_level SESSION: last thinking_level_change, else unknown.
pi_level() {
  local lvl
  lvl="$(jq -rs '[.[] | select(.type=="thinking_level_change") | .thinkingLevel] | last // ""' "$1" 2>/dev/null)"
  [ -n "$lvl" ] && [ "$lvl" != "null" ] && printf '%s' "$lvl" || printf 'unknown'
}

# fiber_level EVENTS: a thinkingLevel in the events, else fiber default.
fiber_level() {
  local lvl=""
  if [ -n "$1" ]; then
    lvl="$(jq -rs '[.. | objects | .payload.thinkingLevel?, .thinkingLevel?]
      | map(select(. != null)) | last // ""' "$1" 2>/dev/null)"
  fi
  [ -n "$lvl" ] && [ "$lvl" != "null" ] && printf '%s' "$lvl" || printf 'fiber default'
}

# verdict_fail ID: failure verdict decision + note, or "".
verdict_fail() {
  [ -n "${VERDICTS_FILE:-}" ] || return 0
  awk -F'\t' -v id="$1" '$1==id && $2=="failure"{print $3"\t"$4; exit}' "$VERDICTS_FILE" 2>/dev/null
}

# verdict_deny ID ACTION: denial verdict decision + note, or "".
verdict_deny() {
  [ -n "${VERDICTS_FILE:-}" ] || return 0
  awk -F'\t' -v id="$1" -v a="$2" '$1==id && $2==a{print $3"\t"$4; exit}' "$VERDICTS_FILE" 2>/dev/null
}

median_of_file() {
  local f="$1" n lo hi
  n="$(wc -l <"$f" | tr -d ' ')"
  [ "$n" -gt 0 ] || return 1
  if [ $((n % 2)) -eq 1 ]; then
    sed -n "$(((n + 1) / 2))p" "$f"
  else
    lo="$(sed -n "$((n / 2))p" "$f")"
    hi="$(sed -n "$((n / 2 + 1))p" "$f")"
    awk -v a="$lo" -v b="$hi" 'BEGIN{printf "%.10f", (a + b) / 2}'
  fi
}

cmd_report() {
  local out verdicts=""
  out="$(default_out)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) [ $# -ge 2 ] || { err "--out needs a value"; return 2; }; out="$2"; shift 2 ;;
      --verdicts) [ $# -ge 2 ] || { err "--verdicts needs a value"; return 2; }; verdicts="$2"; shift 2 ;;
      --*) err "unknown flag $1"; return 2 ;;
      *) err "unexpected argument $1"; return 2 ;;
    esac
  done
  [ -f "$out/manifest.tsv" ] || { err "no manifest at $out/manifest.tsv"; return 2; }
  if [ -n "$verdicts" ] && [ ! -f "$verdicts" ]; then
    err "verdicts file $verdicts missing"
    return 2
  fi
  RUN_OUT="$out"
  FIBER_EVENTS_ROOT="$RUN_OUT/fiber-home"
  VERDICTS_FILE="$verdicts"
  local jobs_dir="${REPLAY_JOBS_DIR:-${TMPDIR:-/tmp}/delegate-jobs}"
  local res="$out/results.md"
  local line id share pimodel fibermodel repo sha session cwd sts
  local compared=0 pi_pass=0 fiber_pass=0
  local fail_unread=0 fail_fiber=0 deny_unread=0 deny_wrong=0 deny_total=0
  local table="" levels="" denials="" notes=""
  : >"$out/.cost-pi.txt"
  : >"$out/.cost-fiber.txt"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id="$(printf '%s' "$line" | cut -f1)"
    share="$(printf '%s' "$line" | cut -f2)"
    pimodel="$(printf '%s' "$line" | cut -f3)"
    session="$(printf '%s' "$line" | cut -f7)"
    cwd="$(printf '%s' "$line" | cut -f8)"
    # pi side
    local pi_rec="$jobs_dir/$id.json" pi_ran=0
    [ -f "$pi_rec" ] && pi_ran=1
    local p_outcome="unknown" p_gate="n/a" p_cost="" p_in="" p_out="" p_cr="" p_share="" p_wall="" p_lvl="unknown"
    if [ "$pi_ran" -eq 1 ]; then
      p_outcome="$(pi_metrics "$pi_rec" "$session" | sed -n 1p)"
      p_gate="$(pi_metrics "$pi_rec" "$session" | sed -n 2p)"
      p_cost="$(pi_metrics "$pi_rec" "$session" | sed -n 3p)"
      p_in="$(pi_metrics "$pi_rec" "$session" | sed -n 4p)"
      p_out="$(pi_metrics "$pi_rec" "$session" | sed -n 5p)"
      p_cr="$(pi_metrics "$pi_rec" "$session" | sed -n 6p)"
      p_share="$(pi_metrics "$pi_rec" "$session" | sed -n 7p)"
      p_wall="$(pi_metrics "$pi_rec" "$session" | sed -n 8p)"
      p_lvl="$(pi_level "$session")"
    fi
    # fiber side
    local f_state="not run" f_outcome="" f_gate="" f_cost="" f_in="" f_out="" f_cr="" f_share="" f_wall="" f_lvl=""
    local f_rec="$out/runs/$id/record.json"
    if [ -f "$out/runs/$id/pending.txt" ]; then
      f_state="pending ($(cat "$out/runs/$id/pending.txt"))"
    elif [ -f "$out/runs/$id/error.txt" ]; then
      f_state="error"
    elif [ -f "$f_rec" ]; then
      f_state="run"
    fi
    if [ "$f_state" = "run" ]; then
      f_outcome="$(fiber_metrics "$f_rec" | sed -n 1p)"
      f_gate="$(fiber_metrics "$f_rec" | sed -n 2p)"
      f_cost="$(fiber_metrics "$f_rec" | sed -n 3p)"
      f_in="$(fiber_metrics "$f_rec" | sed -n 4p)"
      f_out="$(fiber_metrics "$f_rec" | sed -n 5p)"
      f_cr="$(fiber_metrics "$f_rec" | sed -n 6p)"
      f_share="$(fiber_metrics "$f_rec" | sed -n 7p)"
      f_wall="$(fiber_metrics "$f_rec" | sed -n 8p)"
      sid="$(jq -r '.resume.sessionId // ""' "$f_rec" 2>/dev/null)"
      ev="$(fiber_events "$sid")"
      f_lvl="$(fiber_level "$ev")"
    fi
    # compared set: both sides ran
    local fail_note="" fail_verdict=""
    if [ "$pi_ran" -eq 1 ] && [ "$f_state" = "run" ]; then
      compared=$((compared + 1))
      [ "$p_gate" = "pass" ] && pi_pass=$((pi_pass + 1))
      [ "$f_gate" = "pass" ] && fiber_pass=$((fiber_pass + 1))
      if [ -n "$p_cost" ] && [ -n "$f_cost" ]; then
        printf '%s\n' "$p_cost" >>"$out/.cost-pi.txt"
        printf '%s\n' "$f_cost" >>"$out/.cost-fiber.txt"
      fi
      # failure detection
      local is_fail=0
      case "$f_outcome" in
        DONE|DONE_WITH_CONCERNS) ;;
        *) is_fail=1 ;;
      esac
      if [ "$f_gate" = "fail" ] && [ "$p_gate" = "pass" ]; then
        is_fail=1
      fi
      if [ "$is_fail" -eq 1 ]; then
        fail_verdict="$(verdict_fail "$id")"
        if [ -z "$fail_verdict" ]; then
          fail_unread=$((fail_unread + 1))
          fail_note="unread"
        elif [ "${fail_verdict%%$TAB*}" = "fiber" ]; then
          fail_fiber=$((fail_fiber + 1))
          fail_note="fiber (${fail_verdict#*$TAB})"
        elif [ "${fail_verdict%%$TAB*}" = "not-fiber" ]; then
          fail_note="not-fiber (${fail_verdict#*$TAB})"
        else
          fail_unread=$((fail_unread + 1))
          fail_note="invalid verdict: ${fail_verdict%%$TAB*}"
        fi
      fi
      # denials
      while IFS= read -r dline; do
        [ -n "$dline" ] || continue
        if [ "$dline" = "EVENTS_MISSING" ]; then
          deny_unread=$((deny_unread + 1))
          denials="$denials- $id: denials unknown (events missing or ambiguous)\\n"
          continue
        fi
        deny_total=$((deny_total + 1))
        aid="$(printf '%s' "$dline" | cut -f1)"
        decided="$(printf '%s' "$dline" | cut -f2)"
        reason="$(printf '%s' "$dline" | cut -f3)"
        cmd="$(printf '%s' "$dline" | cut -f4)"
        dverdict="$(verdict_deny "$id" "$aid")"
        dnote="unread"
        if [ -z "$dverdict" ]; then
          deny_unread=$((deny_unread + 1))
        elif [ "${dverdict%%$TAB*}" = "wrong" ]; then
          deny_wrong=$((deny_wrong + 1))
          dnote="wrong (${dverdict#*$TAB})"
        elif [ "${dverdict%%$TAB*}" = "right" ]; then
          dnote="right (${dverdict#*$TAB})"
        else
          deny_unread=$((deny_unread + 1))
          dnote="invalid verdict: ${dverdict%%$TAB*}"
        fi
        denials="$denials- $id $aid: \`$cmd\` (decided by $decided, reason: $reason) verdict: $dnote\\n"
      done <<<"$(denials_for "$f_rec")"
    fi
    # table row
    local f_cells
    case "$f_state" in
      pending*|error|"not run")
        f_cells="$f_state | $f_state | $f_state | $f_state | $f_state | $f_state" ;;
      *)
        f_cells="$f_outcome | $f_gate | $(fmt_money "$f_cost") | ${f_in:-unknown}/${f_out:-unknown}/${f_cr:-unknown} | $(fmt_share "$f_share") | $(fmt_wall "$f_wall")" ;;
    esac
    table="$table| $id | $share | $p_outcome | $p_gate | $(fmt_money "$p_cost") | ${p_in:-unknown}/${p_out:-unknown}/${p_cr:-unknown} | $(fmt_share "$p_share") | $(fmt_wall "$p_wall") | $f_cells | ${fail_note:-ok} |\\n"
    if [ "$pi_ran" -eq 1 ] || [ "$f_state" = "run" ]; then
      levels="$levels- $id: pi ${p_lvl:-unknown} / fiber ${f_lvl:-unknown}\\n"
    fi
    if [ -f "$out/runs/$id/notes.txt" ] && [ -s "$out/runs/$id/notes.txt" ]; then
      while IFS= read -r nline; do
        [ -n "$nline" ] || continue
        notes="$notes- $id: $nline\\n"
      done <"$out/runs/$id/notes.txt"
    fi
  done <"$out/manifest.tsv"
  # pass bar math
  local gate_need=$((pi_pass - 1)) gate_met="not met"
  [ "$fiber_pass" -ge "$gate_need" ] && gate_met="met"
  sort -n "$out/.cost-pi.txt" -o "$out/.cost-pi.txt"
  sort -n "$out/.cost-fiber.txt" -o "$out/.cost-fiber.txt"
  local pi_med fiber_med cost_met="not met" cost_detail
  pi_med="$(median_of_file "$out/.cost-pi.txt" 2>/dev/null)"
  fiber_med="$(median_of_file "$out/.cost-fiber.txt" 2>/dev/null)"
  if [ -n "$pi_med" ] && [ -n "$fiber_med" ]; then
    if awk -v f="$fiber_med" -v p="$pi_med" 'BEGIN{exit !(f <= 1.2 * p)}'; then
      cost_met="met"
    fi
    cost_detail="median fiber $(fmt_money "$fiber_med") vs median pi $(fmt_money "$pi_med") (need <= 1.2x)"
  else
    cost_detail="no rows with both costs known"
  fi
  local fail_met="not met" fail_detail
  if [ "$fail_unread" -gt 0 ]; then
    fail_detail="$fail_fiber fiber-caused, $fail_unread unread"
  elif [ "$fail_fiber" -gt 0 ]; then
    fail_detail="$fail_fiber fiber-caused failures"
  else
    fail_met="met"
    fail_detail="no fiber-caused failures"
  fi
  local deny_met="not met" deny_detail
  if [ "$deny_unread" -gt 0 ]; then
    deny_detail="$deny_total read, $deny_unread unread"
  elif [ "$deny_wrong" -gt 0 ]; then
    deny_detail="$deny_wrong wrong of $deny_total"
  else
    deny_met="met"
    deny_detail="$deny_total denials, zero wrong"
  fi
  local versions
  versions="$(cat "$out"/runs/*/version.txt 2>/dev/null | sort -u | tr '\n' ' ')"
  [ -n "$versions" ] || versions="none recorded"
  {
    printf '# Fiber replay results\n\n'
    printf 'Manifest %s (%s compared, %s skipped). Fiber versions: %s. Verdicts: %s.\n\n' \
      "$out/manifest.tsv" "$compared" "$(wc -l <"$out/skipped.tsv" | tr -d ' ')" \
      "$versions" "${verdicts:-none}"
    printf '## Pass bar\n\n'
    printf -- '- Gate: fiber %s passes vs pi %s passes (need >= %s): %s\n' "$fiber_pass" "$pi_pass" "$gate_need" "$gate_met"
    printf -- '- Cost: %s: %s\n' "$cost_detail" "$cost_met"
    printf -- '- Failures: %s: %s\n' "$fail_detail" "$fail_met"
    printf -- '- Denials: %s: %s\n\n' "$deny_detail" "$deny_met"
    printf '## Jobs\n\n'
    printf '| job | share | pi outcome | pi gate | pi cost | pi in/out/cr | pi cr share | pi wall | fiber outcome | fiber gate | fiber cost | fiber in/out/cr | fiber cr share | fiber wall | failure |\n'
    printf '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n'
    printf '%b' "$table" | sed 's/\\\\n$/\n/'
    printf '\n## Levels\n\n'
    printf '%b' "$levels" | sed 's/\\\\n$/\n/'
    printf '\n## Denials\n\n'
    if [ -n "$denials" ]; then
      printf '%b' "$denials" | sed 's/\\\\n$/\n/'
    else
      printf 'No denials recorded (no compared rows or no events read).\n'
    fi
    printf '\n## Row notes\n\n'
    if [ -n "$notes" ]; then
      printf '%b' "$notes" | sed 's/\\\\n$/\n/'
    else
      printf 'None.\n'
    fi
    printf '\n## Skipped\n\n'
    if [ -s "$out/skipped.tsv" ]; then
      awk -F'\t' '{print "- " $1 ": " $2}' "$out/skipped.tsv"
    else
      printf 'None.\n'
    fi
  } >"$res"
  cat "$res"
  rm -f "$out/.cost-pi.txt" "$out/.cost-fiber.txt"
}

cmd_all() {
  local out share verdicts="" rc=0
  out="$(default_out)"
  share="muse"
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) [ $# -ge 2 ] || { err "--out needs a value"; return 2; }; out="$2"; shift 2 ;;
      --share)
        [ $# -ge 2 ] || { err "--share needs a value"; return 2; }
        case "$2" in
          muse|codex|all) share="$2" ;;
          *) err "--share must be muse, codex or all"; return 2 ;;
        esac
        shift 2 ;;
      --verdicts) [ $# -ge 2 ] || { err "--verdicts needs a value"; return 2; }; verdicts="$2"; shift 2 ;;
      --*) err "unknown flag $1"; return 2 ;;
      *) err "unexpected argument $1"; return 2 ;;
    esac
  done
  if [ ! -f "$out/manifest.tsv" ]; then
    cmd_select --out "$out" || return $?
  fi
  cmd_run --out "$out" --share "$share" --batch 3 || rc=$?
  if [ -n "$verdicts" ]; then
    cmd_report --out "$out" --verdicts "$verdicts" || return $?
  else
    cmd_report --out "$out" || return $?
  fi
  return "$rc"
}

usage() {
  err "usage: replay.sh select [--out DIR] [--total 30] [--force]"
  err "       replay.sh run [--out DIR] [--share muse|codex|all] [--batch 3 | --job ID...] [--fresh]"
  err "       replay.sh report [--out DIR] [--verdicts FILE]"
  err "       replay.sh all [--out DIR] [--share muse] [--verdicts FILE]"
}

cmd="${1:-}"
if [ $# -gt 0 ]; then shift; fi
case "$cmd" in
  select) cmd_select "$@" ;;
  run) cmd_run "$@" ;;
  report) cmd_report "$@" ;;
  all) cmd_all "$@" ;;
  *) usage; exit 2 ;;
esac

#!/bin/bash
# fw-lib.sh: shared measurements for fw-tick, fw-watch and fence-grant.
# bash 3.2 compatible, `set -u` safe. Source it, do not execute:
#   . "$(dirname "$0")/lib/fw-lib.sh"
# Overridables: FW_RUN, FW_GH, FW_CLAUDE, FW_SSH, FW_QUOTA, FW_BOX_HOST.
# Host-independent testing: FW_MAC_LOADAVG, FW_MAC_MEMPRESS, FW_MAC_DF
# override the raw stdout of sysctl, memory_pressure and `df -g /`.

_fw_source=${BASH_SOURCE[0]}
while [ -L "$_fw_source" ]; do
  _fw_source_dir=$(cd "$(dirname "$_fw_source")" && pwd)
  _fw_source_link=$(readlink "$_fw_source")
  case "$_fw_source_link" in /*) _fw_source=$_fw_source_link;; *) _fw_source=$_fw_source_dir/$_fw_source_link;; esac
done
_FW_LIB_DIR=$(cd "$(dirname "$_fw_source")" && pwd)
unset _fw_source _fw_source_dir _fw_source_link

_fw_run() { printf '%s' "${FW_RUN:-${RUN_DIR:-$HOME/work/fiber-worktrees/flywheel/run}}"; }
_fw_box_host() { printf '%s' "${FW_BOX_HOST:-roundhouse-7010-plus-1.local}"; }

# Use SSH from the Mac, and the local shim when the flywheel itself runs on
# the Linux box. Explicit overrides keep tests and alternate hosts hermetic.
fw_box_ssh() {
  if [ -n "${BOX_SSH:-${FW_SSH:-}}" ]; then
    "${BOX_SSH:-$FW_SSH}" "$@"
  elif [ "$(uname -s)" = Darwin ]; then
    ssh "$@"
  else
    "${FW_BOX_LOCAL:-$_FW_LIB_DIR/box-local.sh}" "$@"
  fi
}

fw_box_is_local() {
  [ -z "${BOX_SSH:-${FW_SSH:-}}" ] && [ "$(uname -s)" != Darwin ]
}

# Read `claude agents --json` on stdin; print live lane names (fiber-*,
# busy/idle). Exits 1 when stdin is not parseable JSON (fail closed).
_fw_lane_names_json() {
  python3 -c 'import json,sys
try:
  data = json.load(sys.stdin)
except Exception:
  sys.exit(1)
if not isinstance(data, list):
  sys.exit(1)
out = []
for a in data:
  try:
    n = a.get("name", "")
    s = a.get("status", "")
  except Exception:
    continue
  if n.startswith("fiber-") and s in ("busy", "idle"):
    out.append(n)
print(" ".join(out))' 2>/dev/null
}

# Prints Mac lane names; exit 1 when the command fails or output is unparseable.
# Stderr of the claude command goes to ${FW_CLAUDE_ERR:-/dev/null}.
fw_lane_names_mac() {
  _fw_out=$("${FW_CLAUDE:-claude}" agents --json 2>"${FW_CLAUDE_ERR:-/dev/null}") || return 1
  printf '%s' "$_fw_out" | _fw_lane_names_json || return 1
  return 0
}

# One ssh round trip gathering every box fact; results cached in FW_BOX_*.
# FW_BOX_RC holds ssh's exit code; FW_BOX_OK is 1 only with intact markers.
_fw_box_probe() {
  if [ -n "${FW_BOX_PROBED:-}" ]; then return 0; fi
  FW_BOX_PROBED=1
  FW_BOX_OK=0
  FW_BOX_RC=0
  FW_BOX_RAW=""
  _fw_raw=$(fw_box_ssh "$(_fw_box_host)" 'echo FWSEC=UPTIME; uptime; echo FWSEC=FREE; free -g; echo FWSEC=DF; df -BG /; echo FWSEC=AGENTS; claude agents --json; echo FWSEC=PILANES; (cd ~/work/fiber-worktrees/flywheel/run && for f in fiber-*-pi.pid; do [ -f "$f" ] || continue; p=$(cat "$f" 2>/dev/null); case "$p" in ""|*[!0-9]*) continue;; esac; kill -0 "$p" 2>/dev/null || continue; n=${f#fiber-}; n=${n%-pi.pid}; echo "fiber-$n"; done; echo PILANESOK); echo FWSEC=SHIP; ps -ax -o command= 2>/dev/null | grep -c "[s]hip-pr"; echo FWSEC=END' 2>"${FW_SSH_ERR:-/dev/null}") || FW_BOX_RC=$?
  case "$_fw_raw" in
    *FWSEC=UPTIME*FWSEC=END*) FW_BOX_OK=1; FW_BOX_RAW="$_fw_raw" ;;
  esac
  return 0
}

_fw_box_section() {
  _fw_box_probe
  if [ "${FW_BOX_OK:-0}" != 1 ]; then return 1; fi
  printf '%s\n' "$FW_BOX_RAW" | awk -v s="FWSEC=$1" '$0 == s {on = 1; next} /^FWSEC=/ {on = 0} on {print}'
  return 0
}

fw_box_load5() {
  _fw_s=$(_fw_box_section UPTIME) || { echo "?"; return 0; }
  _fw_l=$(printf '%s' "$_fw_s" | sed 's/.*load average[s]*: *//; s/,//g')
  # shellcheck disable=SC2086
  set -- $_fw_l
  printf '%s' "${2:-?}"
  return 0
}

fw_box_memavail_gib() {
  _fw_s=$(_fw_box_section FREE) || { echo "?"; return 0; }
  _fw_v=$(printf '%s\n' "$_fw_s" | awk '/^Mem:/ {print $7}')
  case "$_fw_v" in ''|*[!0-9]*) echo "?";; *) echo "$_fw_v";; esac
  return 0
}

fw_box_disk_gib() {
  _fw_s=$(_fw_box_section DF) || { echo "?"; return 0; }
  _fw_v=$(printf '%s\n' "$_fw_s" | awk 'NR == 2 {v = $4; gsub(/G/, "", v); print v}')
  case "$_fw_v" in ''|*[!0-9]*) echo "?";; *) echo "$_fw_v";; esac
  return 0
}

# Prints box lane names; exit 1 when ssh failed or output is unparseable.
fw_box_lane_names() {
  _fw_box_probe
  if [ "${FW_BOX_OK:-0}" != 1 ]; then return 1; fi
  _fw_s=$(_fw_box_section AGENTS) || return 1
  [ -n "$_fw_s" ] || return 1
  printf '%s' "$_fw_s" | _fw_lane_names_json || return 1
  return 0
}

# Prints live Mac pi-lane names, `fiber-<n>` per live `fiber-<n>-pi.pid`.
# A pi lane is invisible to `claude agents`, so a fence probe that reads only
# that command loses every pi lane's hold once its grant files age out of the
# six-hour window (2026-10-31: a sweep printed "live lanes:" empty with 14 pi
# lanes running). Exit 1 when the run directory is missing (fail closed).
fw_pi_lane_names_mac() {
  _fw_rd=$(_fw_run)
  [ -d "$_fw_rd" ] || return 1
  case "$-" in *f*) _fw_hadf=1;; *) _fw_hadf=0;; esac
  set +f
  _fw_names=""
  for _fw_f in "$_fw_rd"/fiber-*-pi.pid; do
    [ -f "$_fw_f" ] || continue
    _fw_p=$(cat "$_fw_f" 2>/dev/null)
    case "$_fw_p" in ''|*[!0-9]*) continue;; esac
    kill -0 "$_fw_p" 2>/dev/null || continue
    _fw_n=${_fw_f##*/fiber-}
    _fw_n=${_fw_n%-pi.pid}
    _fw_names="$_fw_names fiber-$_fw_n"
  done
  [ "$_fw_hadf" -eq 1 ] && set -f
  printf '%s' "${_fw_names# }"
  return 0
}

# Prints live box pi-lane names from the one box probe. Exit 1 when ssh failed
# or the section's end marker is missing (fail closed).
fw_pi_lane_names_box() {
  _fw_box_probe
  if [ "${FW_BOX_OK:-0}" != 1 ]; then return 1; fi
  _fw_s=$(_fw_box_section PILANES) || return 1
  case "$_fw_s" in *PILANESOK*) : ;; *) return 1;; esac
  printf '%s' "$_fw_s" | grep '^fiber-' | tr '\n' ' '
  return 0
}

fw_mac_load5() {
  if [ -n "${FW_MAC_LOADAVG+x}" ]; then
    _fw_src=$FW_MAC_LOADAVG
  else
    _fw_src=$(sysctl -n vm.loadavg 2>/dev/null)
  fi
  _fw_v=$(printf '%s' "$_fw_src" | tr -d '{}' | awk '{print $3}')
  case "$_fw_v" in ''|*[!0-9.]*|*.*.*) echo "?";; *) echo "$_fw_v";; esac
  return 0
}

fw_mac_memfree() {
  if [ -n "${FW_MAC_MEMPRESS+x}" ]; then
    _fw_src=$FW_MAC_MEMPRESS
  else
    _fw_src=$(memory_pressure 2>/dev/null)
  fi
  _fw_v=$(printf '%s' "$_fw_src" | grep 'free percentage' | grep -o '[0-9][0-9]*' | head -n 1)
  case "$_fw_v" in ''|*[!0-9]*) echo "?";; *) echo "$_fw_v";; esac
  return 0
}

fw_mac_disk_gib() {
  if [ -n "${FW_MAC_DF+x}" ]; then
    _fw_src=$FW_MAC_DF
  else
    _fw_src=$(df -g / 2>/dev/null)
  fi
  _fw_v=$(printf '%s' "$_fw_src" | awk 'NR == 2 {print $4}')
  case "$_fw_v" in ''|*[!0-9]*) echo "?";; *) echo "$_fw_v";; esac
  return 0
}

_fw_count() {
  # shellcheck disable=SC2086
  set -- $1
  echo $#
}

fw_lanes_mac() { _fw_count "$(fw_lane_names_mac 2>/dev/null)"; }
fw_lanes_box() {
  _fw_n=$(fw_box_lane_names 2>/dev/null) || { echo "?"; return 0; }
  _fw_count "$_fw_n"
}

# The claude line's Session and Weekly percents, e.g. s90w62; ? when unknown.
fw_quota() {
  _fw_v=$("${FW_QUOTA:-$HOME/.agents/bin/quota}" 2>/dev/null | awk '/^claude / {s = ""; w = ""; if (match($0, /Session [0-9]+%/)) {s = substr($0, RSTART + 8, RLENGTH - 9)} if (match($0, /Weekly [0-9]+%/)) {w = substr($0, RSTART + 7, RLENGTH - 8)} if (s != "" && w != "") {print "s" s "w" w}}' | head -n 1)
  if [ -n "$_fw_v" ]; then printf '%s' "$_fw_v"; else printf '?'; fi
  return 0
}

fw_inbox_count() {
  _fw_run=$(_fw_run)
  _fw_n=0
  for _fw_f in "$_fw_run"/inbox/*.md; do
    [ -f "$_fw_f" ] || continue
    _fw_n=$((_fw_n + 1))
  done
  echo "$_fw_n"
  return 0
}

# Basenames of inbox *.md files, sorted, space separated (empty when none).
fw_inbox_files() {
  _fw_run=$(_fw_run)
  for _fw_f in "$_fw_run"/inbox/*.md; do
    [ -f "$_fw_f" ] || continue
    basename "$_fw_f"
  done | sort | tr '\n' ' ' | sed 's/ $//'
  return 0
}

# Epoch mtime of a file; empty when unknown. Portable (macOS/Linux stat).
fw_mtime() {
  _fw_m=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null) || _fw_m=""
  case "$_fw_m" in *[!0-9]*|'') printf '';; *) printf '%s' "$_fw_m";; esac
  return 0
}

# Count of live `ship-pr` processes across both hosts; ? when the box is
# unreachable and the Mac has none, since "0 here" is not "0 anywhere".
# The bracket in [s]hip-pr keeps the grep from matching its own command text:
# a plain `grep -c ship-pr` over `ps` always counts itself, which read as a
# live shipper once and hid a three-hour stall (2026-11-05).
fw_shippers() {
  if fw_box_is_local; then
    _fw_m=0
  else
    _fw_m=$(ps -ax -o command= 2>/dev/null | grep -c '[s]hip-pr' 2>/dev/null)
    [ -n "$_fw_m" ] || _fw_m=0
  fi
  _fw_b=$(_fw_box_section SHIP | tr -d "[:space:]")
  case "$_fw_b" in
    ''|*[!0-9]*)
      if [ "$_fw_m" -gt 0 ]; then printf '%s' "$_fw_m"; else printf '?'; fi
      return 0 ;;
  esac
  printf '%s' "$((_fw_m + _fw_b))"
  return 0
}

# Open PRs whose newest review-pr comment both names the current head and
# carries a merge verdict, i.e. ready to ship. Prints `0`, or `<n>:<csv>` as
# in `2:4194,4200`. Nothing is shipping a PR on this list unless a `ship-pr`
# is alive, so `fw_ready_unshipped` over `fw_shippers` is the stall signal:
# a dead backgrounded shipper leaves no inbox file and no lane exit, so no
# other watch trigger sees it. Set FW_NO_PR_PROBE=1 to skip the gh calls.
fw_ready_unshipped() {
  [ -n "${FW_NO_PR_PROBE:-}" ] && { printf '0'; return 0; }
  _fw_repo="${FW_REPO:-aakshintala/fiber}"
  _fw_prs=$(gh pr list -R "$_fw_repo" --state open --limit 30 \
    --json number,headRefOid --jq '.[] | "\(.number) \(.headRefOid)"' 2>/dev/null) \
    || { printf '?'; return 0; }
  _fw_n=0
  _fw_list=''
  # A draft counts: #4194 sat ready-and-drafted for three hours.
  while IFS=' ' read -r _fw_num _fw_sha; do
    [ -n "$_fw_num" ] || continue
    _fw_body=$(gh pr view "$_fw_num" -R "$_fw_repo" --json comments \
      --jq '.comments[-1].body' 2>/dev/null) || continue
    case "$_fw_body" in *"$_fw_sha"*) ;; *) continue ;; esac
    case "$_fw_body" in
      *FIX-OK*|*APPROVE*) ;;
      *) continue ;;
    esac
    _fw_n=$((_fw_n + 1))
    if [ -z "$_fw_list" ]; then _fw_list="$_fw_num"; else _fw_list="$_fw_list,$_fw_num"; fi
  done <<EOF
$_fw_prs
EOF
  if [ "$_fw_n" -eq 0 ]; then printf '0'; else printf '%s:%s' "$_fw_n" "$_fw_list"; fi
  return 0
}

# The repo area holding the fewest live claims, as `<area>:<claims>`; ? when
# the checkout or the registry cannot be read. An area is a `crates/<name>`
# directory plus `xtask/src`.
#
# This exists because the frontier is not thin when it looks thin. On
# 2026-11-05 I recorded "no disjoint work" six times while `crates/keeper`
# held zero claims and three unblocked tickets. `gh issue list` returns
# newest first, newest clusters on whatever the owner last filed, and that
# clusters on the most-claimed area in the repo — so the top of the list is
# always colliding and the list reads as the problem. The coldest area is the
# answer to "where is there room", and it costs one `ls` and one registry
# read.
fw_coldest_area() {
  _fw_co_repo="${FW_SHARED_REPO:-$HOME/work/fiber}"
  [ -d "$_fw_co_repo/crates" ] || { printf '?'; return 0; }
  _fw_co_claims=$("${FW_FILE_CLAIM:-$HOME/.agents/bin/file-claim}" list 2>/dev/null) \
    || { printf '?'; return 0; }
  _fw_co_best=''
  _fw_co_bestn=''
  # Every unclaimed area, not just the alphabetically first: a tick that said
  # `crates/config:0` would still have hidden `crates/keeper`, and which of
  # several empty areas has a live ticket is the part I have to judge.
  _fw_co_zero=''
  _fw_co_zn=0
  for _fw_co_d in "$_fw_co_repo"/crates/*/ "$_fw_co_repo"/xtask/; do
    [ -d "$_fw_co_d" ] || continue
    _fw_co_a=${_fw_co_d%/}
    _fw_co_a=${_fw_co_a#"$_fw_co_repo"/}
    case "$_fw_co_a" in xtask) _fw_co_a=xtask/src ;; esac
    _fw_co_n=$(printf '%s\n' "$_fw_co_claims" | grep -c "^$_fw_co_a/")
    if [ "$_fw_co_n" -eq 0 ]; then
      _fw_co_zn=$((_fw_co_zn + 1))
      if [ "$_fw_co_zn" -le 4 ]; then
        if [ -z "$_fw_co_zero" ]; then _fw_co_zero="$_fw_co_a"; else _fw_co_zero="$_fw_co_zero,$_fw_co_a"; fi
      fi
    fi
    if [ -z "$_fw_co_bestn" ] || [ "$_fw_co_n" -lt "$_fw_co_bestn" ]; then
      _fw_co_bestn=$_fw_co_n
      _fw_co_best=$_fw_co_a
    fi
  done
  if [ "$_fw_co_zn" -gt 0 ]; then
    printf '%s/%s_unclaimed' "$_fw_co_zero" "$_fw_co_zn"
  elif [ -z "$_fw_co_best" ]; then
    printf '?'
  else
    printf '%s:%s' "$_fw_co_best" "$_fw_co_bestn"
  fi
  return 0
}

# Minutes since $FW_RUN/peer-last/<name> changed; ? when the file is missing.
fw_peer_age() {
  _fw_f="$(_fw_run)/peer-last/$1"
  [ -f "$_fw_f" ] || { echo "?"; return 0; }
  _fw_m=$(fw_mtime "$_fw_f")
  case "$_fw_m" in
    '') echo "?" ;;
    *)
      _fw_now=$(date +%s)
      _fw_a=$(( (_fw_now - _fw_m) / 60 ))
      [ "$_fw_a" -lt 0 ] && _fw_a=0
      echo "$_fw_a" ;;
  esac
  return 0
}

# Print the parent session address a Mac --bg lane reports to with SendMessage.
# Resolution order: $FW_PARENT, then the first non-empty line of the run dir's
# `parent` file. Prints nothing and returns 1 when neither is set, so a caller
# that needs a real address fails the launch instead of baking in a stale ref.
fw_parent() {
  if [ -n "${FW_PARENT:-}" ]; then printf '%s' "$FW_PARENT"; return 0; fi
  _fw_pf="$(_fw_run)/parent"
  [ -f "$_fw_pf" ] || return 1
  _fw_pv=$(grep -v '^[[:space:]]*$' "$_fw_pf" | head -1)
  [ -n "$_fw_pv" ] || return 1
  printf '%s' "$_fw_pv"
  return 0
}

# fw_is_liveness <file>: true when the file is a supervisor liveness note and
# nothing else -- one line, exactly `[session <uuid> idle|dead]`.
#
# It lives here, not beside a caller, because two paths deliver into the same
# inbox and only one of them used to route. box-inbox-pull.sh carried this
# predicate and applied it to box lanes; a Mac muse lane passes the inbox
# straight to `delegate session start --inbox`, so its notes never met the
# predicate at all. On 2026-11-07 four Mac lanes had their idle notices sitting
# at maxdepth 1 in the inbox, each one a wake-up carrying nothing `lanecheck`
# does not already say, and say standing rather than once.
#
# The fail direction is "treat it as a report": anything that is not exactly one
# liveness line stays in the inbox and still wakes the flywheel. A report must
# never be routed into liveness/ to be found later by someone looking for it.
# Exercised against all 91 files in the live inbox on 2026-11-04: 53 notices, 38
# reports, no file on either side misread.
fw_is_liveness() {
  [ -f "$1" ] &&
    [ "$(wc -l <"$1" | tr -d ' ')" -eq 1 ] &&
    grep -qxE '^\[session [0-9a-f-]{36} (idle|dead)\]$' "$1"
}

# fw_self_grant <launcher> <n> <run>: record the fence from the ticket's posted
# plan, so a settled plan never waits on the flywheel to type it in (owner,
# 2026-11-07: "build the launcher self-grant"). Reads the last comment carrying
# a `## Files` section; a bullet that opens with a backticked path is a write,
# unless it is marked `(read)` or sits under a "Reads" line, which go to
# --reads. Ranges are not parsed, so writes are granted whole. Returns 1 --
# and the launcher refuses as before -- when there is no plan, no write path,
# fence-grant refuses, or no grant file appears in <run>.
# FW_GH and FW_FENCE_GRANT override gh and fence-grant (tests).
fw_self_grant() {
  local who=$1 n=$2 run=$3 body lists w r rg fg
  fg=${FW_FENCE_GRANT:-$_FW_LIB_DIR/fence-grant}
  _fw_grant_ssh=${FW_SSH:-}
  if [ -z "$_fw_grant_ssh" ] && [ "$(uname -s)" != Darwin ]; then
    _fw_grant_ssh=${FW_BOX_LOCAL:-$_FW_LIB_DIR/box-local.sh}
  fi
  body=$("${FW_GH:-gh}" api "repos/aakshintala/fiber/issues/$n/comments?per_page=100" \
    --jq '[.[]|select(.body|test("(?im)^#+ *files"))]|last|.body // ""' 2>/dev/null) || return 1
  [ -n "$body" ] || { echo "$who: #$n has no posted plan with a Files section" >&2; return 1; }
  lists=$(printf '%s\n' "$body" | python3 -c 'import re,sys
w=[];r=[];rg=[];on=False;reads=False
for line in sys.stdin:
  s=line.rstrip("\n")
  if re.match(r"#+\s*files\b",s,re.I): on=True; continue
  if not on: continue
  if re.match(r"#+\s",s): break
  if re.match(r"\s*reads\b",s,re.I): reads=True; continue
  if re.match(r"\s*writes\b",s,re.I): reads=False; continue
  m=re.match(r"\s*[-*]\s+`([^`\s]+)`(\s*\(read\))?",s)
  if not m: continue
  if reads or m.group(2):
    for p in re.findall(r"`([^`\s]+)`\s*\(read\)",s) or [m.group(1)]:
      p=p.split("::")[0]
      p in r or p in w or r.append(p)
  else:
    q=re.match(r"(.+):(\d+)(?:-(\d+))?$",m.group(1))
    if q:
      rg.append("%s:%s-%s" % (q.group(1),q.group(2),q.group(3) or q.group(2)))
    p=q.group(1) if q else m.group(1)
    p in w or w.append(p)
print(",".join(w)); print(",".join(r)); print(",".join(rg))') || return 1
  w=$(printf '%s\n' "$lists" | sed -n 1p); r=$(printf '%s\n' "$lists" | sed -n 2p)
  rg=$(printf '%s\n' "$lists" | sed -n 3p)
  [ -n "$w" ] || { echo "$who: #$n's plan Files section names no write path" >&2; return 1; }
  # A path the plan creates is not on main yet, and fence-grant wants it under
  # --new as well as --paths: ask a --dry probe, which names each one MISSING.
  local nw a
  nw=$(FW_SSH="$_fw_grant_ssh" FW_RUN=$run bash "$fg" "$n" --repo aakshintala/fiber --paths "$w" --dry 2>&1 \
    | sed -n 's/^MISSING //p' | paste -sd, -)
  echo "$who: no fence grant for #$n; granting from the posted plan: $w${nw:+ (new: $nw)}${rg:+ (ranges: $rg)}" >&2
  a=(--paths "$w")
  [ -n "$nw" ] && a+=(--new "$nw")
  [ -n "$rg" ] && a+=(--ranges "$rg")
  [ -n "$r" ] && a+=(--reads "$r")
  FW_SSH="$_fw_grant_ssh" FW_RUN=$run bash "$fg" "$n" --repo aakshintala/fiber "${a[@]}" >&2 || return 1
  set +f; local g=("$run"/fiber-"$n"-fence-grant*.md); set -f
  [ -e "${g[0]}" ] || { echo "$who: fence-grant ran but wrote no grant file in $run" >&2; return 1; }
}

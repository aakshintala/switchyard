# local-gate-body: shared PR-body placement for the Local gate line.
# Source this file from a tkt tool; call tkt_local_gate_body_insert BODY LINE ATTR MODE.
# Implemented by takes precedence, then ATTR (exact or prefix), then the end.
tkt_local_gate_body_insert() {
  local body="$1" gate_line="$2" attr="$3" attr_mode="$4"
  if [ -z "$body" ]; then
    printf '%s\n' "$gate_line"
    return 0
  fi
  TKT_GATE_LINE="$gate_line" TKT_GATE_ATTR="$attr" TKT_GATE_ATTR_MODE="$attr_mode" awk '
    /^Local gate:/ { next }
    { l[++n] = $0 }
    END {
      anchor = 0
      for (i = 1; i <= n; i++) if (l[i] ~ /^Implemented by:/) { anchor = i; break }
      if (!anchor && ENVIRON["TKT_GATE_ATTR"] != "") {
        if (ENVIRON["TKT_GATE_ATTR_MODE"] == "prefix") {
          for (i = 1; i <= n; i++) if (index(l[i], ENVIRON["TKT_GATE_ATTR"]) == 1) { anchor = i; break }
        } else {
          for (i = 1; i <= n; i++) if (l[i] == ENVIRON["TKT_GATE_ATTR"]) { anchor = i; break }
        }
      }
      if (!anchor) anchor = n + 1
      for (i = 1; i <= n; i++) { if (i == anchor) print ENVIRON["TKT_GATE_LINE"]; print l[i] }
      if (anchor == n + 1) print ENVIRON["TKT_GATE_LINE"]
    }' <<<"$body"
}

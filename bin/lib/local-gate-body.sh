# local-gate-body: shared best-effort PR-body update for the Local gate line.
# Source this file from a tkt tool; call tkt_local_gate_body_insert BODY LINE.
tkt_local_gate_body_insert() {
  local body="$1" gate_line="$2"
  if [ -z "$body" ]; then
    printf '%s\n' "$gate_line"
    return 0
  fi
  TKT_GATE_LINE="$gate_line" awk '
    /^Local gate:/ { next }
    { print }
    END { print ENVIRON["TKT_GATE_LINE"] }' <<<"$body"
}

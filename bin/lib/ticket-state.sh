#!/usr/bin/env bash
# Shared GitHub ticket-state lookup for file claims and fence grants.
#
# ticket_states_lookup REPO NUMBERS_FILE OUTPUT_PREFIX
# Reads one ticket number per line. Writes <prefix>.states as NUMBER<TAB>STATE,
# <prefix>.warnings for missing or unknown entries, and <prefix>.err / .json
# for diagnostics and the raw response. Returns 1 for query/API failure and 2
# for an unreadable response. A partial but readable response returns 0 with a
# warning for every number whose state is unavailable; callers decide whether
# their policy permits acting on the known subset.
ticket_states_lookup() {
  local repo="$1" numbers="$2" prefix="$3" owner name
  : >"$prefix.states"
  : >"$prefix.warnings"
  : >"$prefix.err"
  : >"$prefix.json"
  [ -s "$numbers" ] || return 0

  owner="${repo%%/*}"
  name="${repo#*/}"
  if ! query="$(python3 -c 'import sys
numbers = [line.strip() for line in sys.stdin if line.strip()]
fields = " ".join("ticket_%s: issueOrPullRequest(number: %s) { ... on Issue { state } ... on PullRequest { state } }" % (number, number) for number in numbers)
print("query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { " + fields + " } }")' <"$numbers" 2>"$prefix.query.err")"; then
    printf 'ticket state query build failed\n' >"$prefix.err"
    return 1
  fi
  if ! "${FW_GH:-gh}" api graphql -F "owner=$owner" -F "name=$name" -f "query=$query" >"$prefix.json" 2>"$prefix.err"; then
    return 1
  fi
  if ! python3 -c 'import json,sys
try:
  numbers = [line.strip() for line in open(sys.argv[1]) if line.strip()]
  response = json.load(open(sys.argv[2]))
  if response.get("errors"):
    sys.exit(1)
  repository = response["data"]["repository"]
  if not isinstance(repository, dict):
    sys.exit(1)
  rows = []
  warnings = []
  for number in numbers:
    alias = "ticket_" + number
    if alias not in repository or repository[alias] is None:
      warnings.append("ticket #" + number + " missing from response")
      continue
    item = repository[alias]
    if not isinstance(item, dict):
      sys.exit(1)
    state = item.get("state")
    if state in ("OPEN", "CLOSED", "MERGED"):
      rows.append((number, state))
    else:
      if isinstance(state, str):
        reason = state.replace("\n", " ").replace("\r", " ").replace("\t", " ")
      else:
        reason = json.dumps(state, separators=(",", ":"))
      warnings.append("ticket #" + number + " unknown state " + reason)
except Exception:
  sys.exit(1)
for number, state in rows:
  print(number + "\t" + state)
with open(sys.argv[3], "w") as output:
  for warning in warnings:
    output.write(warning + "\n")' "$numbers" "$prefix.json" "$prefix.warnings" >"$prefix.states" 2>/dev/null; then
    : >"$prefix.states"
    return 2
  fi
  return 0
}

# Same default run directory as fence-grant; tests set FW_RUN to an isolated path.
ticket_states_run_dir() {
  printf '%s' "${FW_RUN:-$HOME/work/fiber-worktrees/flywheel/run}"
}

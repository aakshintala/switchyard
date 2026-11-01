#!/usr/bin/env bash
# Run one prompt through a backend's raw headless CLI and save stdout/stderr as a parser fixture.
#
#   scripts/record.sh BACKEND MODEL NAME [CWD] [SESSION] < prompt
#
# BACKEND: cursor | pi | claude. Every backend records with its write flags.
# SESSION resumes that backend session; pi and claude get a fresh id when it is omitted.
# CANCEL_AFTER=N sends the CLI SIGTERM after N seconds.
# Writes tests/fixtures/recorded/BACKEND/NAME.{stdout,stderr,argv} by default; prints the
# session id (if chosen) and exit code. FIXTURE_KIND=contract writes to
# tests/fixtures/contract/BACKEND/ instead, for curated parser-contract streams.
set -uo pipefail

[ $# -ge 3 ] || { sed -n 2,11p "$0"; exit 2; }
backend=$1 model=$2 name=$3 cwd=${4:-$PWD} session=${5:-}
here="$(cd "$(dirname "$0")" && pwd)"
kind=${FIXTURE_KIND:-recorded}
case "$kind" in contract|recorded) ;; *) echo "bad fixture kind: $kind" >&2; exit 2 ;; esac
out="$here/../tests/fixtures/$kind/$backend"
mkdir -p "$out"

prompt="$(cat)"
prompt+=$'\n\n'
prompt+="$(cat "$here/../src/status_instruction.txt")"

case "$backend" in
  cursor)
    argv=(cursor-agent --print --output-format stream-json --trust --approve-mcps --force --model "$model" --workspace "$cwd" --sandbox disabled)
    [ -n "$session" ] && argv+=(--resume "$session") ;;
  pi)
    session=${session:-$(uuidgen | tr A-Z a-z)}
    argv=(pi -p --mode json --model "$model" --session-id "$session") ;;
  claude)
    argv=(claude -p --output-format stream-json --verbose --model "$model" --permission-mode auto)
    if [ -n "$session" ]; then argv+=(--resume "$session")
    else session=$(uuidgen | tr A-Z a-z); argv+=(--session-id "$session"); fi ;;
  *) echo "bad backend: $backend" >&2; exit 2 ;;
esac

printf '%q ' "${argv[@]}" > "$out/$name.argv"; echo >> "$out/$name.argv"
cd "$cwd" || exit 2
"${argv[@]}" < <(printf '%s' "$prompt") > "$out/$name.stdout" 2> "$out/$name.stderr" &
pid=$!
[ -n "${CANCEL_AFTER:-}" ] && sleep "$CANCEL_AFTER" && kill -TERM "$pid" 2>/dev/null
wait "$pid"
code=$?
# Redact the user's setup (see redact.jq) and home-directory name; non-JSON lines pass through.
for f in "$out/$name".{stdout,stderr,argv}; do
  jq -rR -L "$here" 'include "redact"; (fromjson? | redact | tojson) // .' "$f" | sed "s/${USER:?}/user/g" > "$f.tmp" && mv "$f.tmp" "$f"
done
# Leak-scan the files just written, after redaction. On a hit the fixture
# is deleted and recording fails: a fixture quoting a pattern is not
# committed (no allowlist). The scan prints pattern names only, never
# matched text.
leaks="$("$here/leak-scan.sh" "$out/$name.stdout" "$out/$name.stderr" "$out/$name.argv" 2>&1)" || {
  [ -n "$leaks" ] && printf '%s\n' "$leaks" >&2
  rm -f "$out/$name".{stdout,stderr,argv}
  echo "record.sh: leak-scan hit, fixture deleted" >&2
  exit 3
}
echo "session=$session exit=$code fixture=$out/$name.stdout"
exit $code

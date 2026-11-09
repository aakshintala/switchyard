#!/usr/bin/env bash
# Box-local fw-lib behavior must not count the same ship-pr processes twice.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/fw-lib-move.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stubs" "$T/home"

cat > "$T/stubs/uname" <<'STUB'
#!/bin/sh
echo Linux
STUB
cat > "$T/stubs/ps" <<'STUB'
#!/bin/sh
printf 'ship-pr first\nship-pr second\n'
STUB
cat > "$T/box-local" <<'STUB'
#!/bin/sh
cat <<'EOF'
FWSEC=UPTIME
FWSEC=SHIP
2
FWSEC=END
EOF
STUB
chmod +x "$T/stubs/uname" "$T/stubs/ps" "$T/box-local"

out=$(HOME="$T/home" PATH="$T/stubs:$PATH" FW_BOX_LOCAL="$T/box-local" \
  FW_BOX_HOST=fixture bash -c '. "$1/lib/fw-lib.sh"; fw_shippers' _ "$here/../bin")
if [ "$out" != 2 ]; then
  printf 'FAIL fw_shippers counted a local ship-pr twice: expected 2, got %s\n' "$out" >&2
  exit 1
fi
printf 'ok fw-shippers-counts-local-host-once\n'

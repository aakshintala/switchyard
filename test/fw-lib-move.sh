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

# Sibling tools live in bin/, the parent of bin/lib/ (#1701). Resolve the
# defaults with no override set, and through a symlink to fw-lib.sh.
repo_bin=$(cd "$here/../bin" && pwd)
ln -s "$repo_bin/lib/fw-lib.sh" "$T/fw-lib-link.sh"
for src in "$repo_bin/lib/fw-lib.sh" "$T/fw-lib-link.sh"; do
  paths=$(env -u FW_FENCE_GRANT -u FW_BOX_LOCAL bash -c \
    '. "$1"; _fw_fence_grant; echo; _fw_box_local' _ "$src")
  for want in fence-grant box-local.sh; do
    got=$(printf '%s\n' "$paths" | grep -- "/$want\$" || true)
    if [ "$got" != "$repo_bin/$want" ] || [ ! -x "$got" ]; then
      printf 'FAIL default %s from %s: expected executable %s, got %s\n' \
        "$want" "$src" "$repo_bin/$want" "${got:-nothing}" >&2
      exit 1
    fi
  done
done
over=$(FW_FENCE_GRANT=/x/fg FW_BOX_LOCAL=/x/bl bash -c \
  '. "$1"; _fw_fence_grant; echo; _fw_box_local' _ "$repo_bin/lib/fw-lib.sh")
if [ "$over" != "$(printf '/x/fg\n/x/bl')" ]; then
  printf 'FAIL env overrides lost: got %s\n' "$over" >&2
  exit 1
fi
printf 'ok fw-lib-sibling-tool-defaults\n'

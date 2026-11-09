#!/usr/bin/env bash
# Shared fence-grant Markdown readers.
# Source beside bin/fence-grant and bin/tkt-gate.

# fence_grant_paths_block FILE: print only the Paths block. `Reads:` and any
# following heading end the block, so read-only paths cannot become grants.
fence_grant_paths_block() {
  awk '
    /^Reads:[[:space:]]*$/ { stop = 1 }
    /^##([[:space:]]|$)/ { stop = 1 }
    stop { next }
    /^Paths:[[:space:]]*$/ { paths = 1; next }
    paths { print }
  ' "$1" 2>/dev/null
}

# fence_grant_pathspecs FILE: print Markdown bullet path entries from Paths.
# Grant files write paths as `- <path>`; other lines such as Ranges are not
# whole-file grants.
fence_grant_pathspecs() {
  fence_grant_paths_block "$1" | awk '
    /^[[:space:]]*-[[:space:]]+/ {
      sub(/^[[:space:]]*-[[:space:]]+/, "")
      gsub(/`/, "")
      sub(/[[:space:]]+$/, "")
      if ($0 != "") print
    }
  '
}

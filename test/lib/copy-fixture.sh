# Copy an immutable test fixture into a case-local directory. On macOS, use
# APFS clonefile copies when the temporary directory's volume supports them;
# fall back to ordinary recursive copies on other filesystems and platforms.
case "$(uname -s)" in
  Darwin) _COPY_FIXTURE_CLONE=1 ;;
  *) _COPY_FIXTURE_CLONE=0 ;;
esac

copy_fixture_tree() {
  local source="$1" destination="$2"
  mkdir -p "$destination" || return
  if [ "$_COPY_FIXTURE_CLONE" = 1 ]; then
    if cp -cR "$source/." "$destination/" 2>/dev/null; then
      return 0
    fi
  fi
  cp -R "$source/." "$destination/"
}

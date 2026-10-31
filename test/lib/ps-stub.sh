# Shared ps stub for lane liveness tests. The fixture directory holds
# <pid>.comm and <pid>.info files; callers place the returned stub dir first
# on PATH and keep the fixture path in PS_STUB_FIXTURE_DIR.
write_ps_stub() {
  local stub_dir=$1 fixture_dir=$2
  mkdir -p "$stub_dir" || return
  PS_STUB_FIXTURE_DIR=$fixture_dir
  export PS_STUB_FIXTURE_DIR
  cat >"$stub_dir/ps" <<'STUB'
#!/bin/sh
case "$#:$1:$2:$3" in
  4:-o:comm=:-p)
    if [ -f "$PS_STUB_FIXTURE_DIR/$4.comm" ]; then
      IFS= read -r value <"$PS_STUB_FIXTURE_DIR/$4.comm" || [ -n "${value:-}" ]
      printf '%s\n' "$value"
    else
      exit 1
    fi
    ;;
  4:-o:stat=,etime=:-p)
    if [ -f "$PS_STUB_FIXTURE_DIR/$4.info" ]; then
      IFS= read -r value <"$PS_STUB_FIXTURE_DIR/$4.info" || [ -n "${value:-}" ]
      printf '%s\n' "$value"
    else
      exit 1
    fi
    ;;
  *) echo "unexpected ps arguments: $*" >&2; exit 2;;
esac
STUB
  chmod +x "$stub_dir/ps"
}

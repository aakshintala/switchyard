#!/bin/bash
# box-local.sh [ssh options] <host> [command...]: run the command here.
# Port shim, added when the flywheel moved onto the box: the box is now the
# local host, so every `ssh $host '<cmd>'` the scripts make runs <cmd> locally.
# Scripts take it as their default for BOX_SSH / FW_SSH / the literal `ssh`;
# tests still override those with a stub. It mimics what ssh gives a remote
# command: cwd is $HOME, PATH is the box's non-interactive ssh PATH, the args
# are joined with spaces and parsed by bash, and stdin passes through.
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-p|-i|-l|-F|-J|-L|-R) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || exit 0
shift   # the host
[ $# -gt 0 ] || exit 0
cd "$HOME" || exit 1
export PATH="$HOME/.cargo/bin:$HOME/.agents/bin:$HOME/.local/bin:$PATH"
exec bash -c "$*"

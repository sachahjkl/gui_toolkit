#!/usr/bin/env bash
# Shortcut: ./build.sh [example] [-debug] is tk build (tools/tk). Every other command: odin run tools/tk -- <command>.
exec odin run "$(dirname "$0")/tools/tk" -out:"$(dirname "$0")/build/tk" -- build "$@"

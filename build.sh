#!/usr/bin/env bash
# Shortcut: ./build.sh [example] [-debug] is tk build (tools/tk). Every other command: odin run tools/tk -- <command>.
cd "$(dirname "$0")" && mkdir -p build && exec odin run tools/tk -out:build/tk -keep-executable -- build "$@"

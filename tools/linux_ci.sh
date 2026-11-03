#!/usr/bin/env bash
# The Linux part of the CI (and a local check in WSL): the native text backend (cargo, native/text ->
# build/text/libgt_text.a), odin check -vet of every package for Linux, the examples built (native text, Vulkan through
# wgpu-native: tools/tk fetch_wgpu first), and the tests.
#   tools/linux_ci.sh [odin]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ODIN="${1:-odin}"
fail=0
# the text backend: the examples link it themselves (FONT_NATIVE_LINK); wgpu-native is the other Rust library in them,
# whose few unmangled symbols of Rust's standard library are the same code
(cd native/text && cargo build --release --locked --lib --target-dir "$ROOT/build/text/target") || exit 1
mkdir -p build/text build/linux
cp build/text/target/release/libgt_text.a build/text/libgt_text.a
NATIVE=(-define:FONT_BACKEND=native -extra-linker-flags:"-Wl,--allow-multiple-definition")
for p in base config dbus devtools draw flate font fsx i18n instance platform render ui; do
  if out=$("$ODIN" check "$p" -no-entry-point -vet -target:linux_amd64 "${NATIVE[@]:0:1}" 2>&1); then
    echo "check ok   $p"
  else
    echo "check FAIL $p"; echo "$out" | grep -E "Error" | head -15; fail=1
  fi
done
for e in hello smoke todo markdown panes docking whatsnew; do
  if out=$("$ODIN" build "examples/$e" -vet "${NATIVE[@]}" -out:"build/linux/$e" 2>&1); then
    echo "build ok   examples/$e"
  else
    echo "build FAIL examples/$e"; echo "$out" | grep -E "Error|error" | head -15; fail=1
  fi
done
# the tests (tools/run_tests: its list says which run on Linux). The pixels: Vulkan's software rasterizer (mesa-vulkan-drivers)
"$ODIN" run tools/run_tests -vet -out:build/linux/run_tests || fail=1
exit $fail

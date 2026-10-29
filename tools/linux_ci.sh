#!/usr/bin/env bash
# The Linux part of the CI (and a local check in WSL): the native text backend (cargo, native/text ->
# build/text/libgt_text.a), odin check -vet of every package for Linux, the examples built (native text, Vulkan through
# wgpu-native: tools/fetch_wgpu.sh first), and the tests that need no window.
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
for p in base config dbus draw flate font fsx i18n instance platform render ui; do
  if out=$("$ODIN" check "$p" -no-entry-point -vet -target:linux_amd64 "${NATIVE[@]:0:1}" 2>&1); then
    echo "check ok   $p"
  else
    echo "check FAIL $p"; echo "$out" | grep -E "Error" | head -15; fail=1
  fi
done
for e in hello smoke todo markdown panes; do
  if out=$("$ODIN" build "examples/$e" -vet "${NATIVE[@]}" -out:"build/linux/$e" 2>&1); then
    echo "build ok   examples/$e"
  else
    echo "build FAIL examples/$e"; echo "$out" | grep -E "Error|error" | head -15; fail=1
  fi
done
for t in frame_slots pacing autoscroll flate; do
  out=$("$ODIN" test "tests/$t" -vet -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -out:"build/linux/${t}_test" 2>&1)
  if echo "$out" | grep -qE "All tests were successful|The test was successful"; then
    echo "test ok    tests/$t $(echo "$out" | grep -oE 'Finished [0-9]+ tests?')"
  else
    echo "test FAIL  tests/$t"; echo "$out" | grep -E "\[ERROR|Error|FAILED|undefined" | head -20; fail=1
  fi
done
exit $fail

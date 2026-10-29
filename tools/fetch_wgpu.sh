#!/usr/bin/env bash
# The library vendor:wgpu links on Linux (the WebGPU render backend, the toolkit's only one there): wgpu-native 29.0.1.1,
# static, pinned by SHA-256, put where Odin's vendor/wgpu looks for it (lib/wgpu-linux-x86_64-release/lib/). Odin's Linux
# release archives do not ship it (the Windows ones do: tools/fetch_wgpu.ps1 only checks it there).
#   tools/fetch_wgpu.sh [odin]      ODIN: the compiler whose vendor folder gets the library (default: odin on PATH)
set -euo pipefail
ODIN="${1:-odin}"
VERSION=29.0.1.1
URL="https://github.com/gfx-rs/wgpu-native/releases/download/v$VERSION/wgpu-linux-x86_64-release.zip"
SHA256=95a4d90c071005a98d03eab348beaa6b07e16eb00d1dcdb9f8348f75eb97ec5a
DEST="$("$ODIN" root | tr -d '\r')/vendor/wgpu/lib/wgpu-linux-x86_64-release"
if [ -f "$DEST/lib/libwgpu_native.a" ] && [ "$(cat "$DEST/VERSION" 2>/dev/null)" = "$VERSION" ]; then
  echo "wgpu-native $VERSION in $DEST"
  exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/wgpu.zip" "$URL"
echo "$SHA256  $tmp/wgpu.zip" | sha256sum -c - >/dev/null
mkdir -p "$DEST"
(cd "$DEST" && unzip -qo "$tmp/wgpu.zip")
echo "$VERSION" > "$DEST/VERSION"
echo "wgpu-native $VERSION -> $DEST"

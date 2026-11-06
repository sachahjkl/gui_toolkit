#!/usr/bin/env bash
# The Linux backends against real servers, on a virtual desktop nobody sees: tests/linux_desktop under Xvfb with a window
# manager, then under a headless Wayland compositor. Never on a person's desktop: DISPLAY and WAYLAND_DISPLAY are this
# script's. Needs: Xvfb openbox xdotool xclip xprop xwininfo xrandr, Xorg with its dummy driver, sway wl-clipboard wtype, and
# libxcb, its xfixes and randr libraries, libxkbcommon(-x11), libwayland-client where dlopen finds them.
#   XORG: how to start Xorg (default: Xorg); XORG_MODULES: more module directories for it.
#   tools/linux_desktop.sh [odin] [x11|randr|wayland]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ODIN="${1:-odin}"
ONLY="${2:-}"
OUT="${TMPDIR:-/tmp}/gt_desktop_$$"
mkdir -p "$OUT/bin" "$OUT/run"
chmod 700 "$OUT/run"
fail=0
pids=()
cleanup() { for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$OUT"; }
trap cleanup EXIT

# what open_url calls: writes its argument
cat > "$OUT/bin/xdg-open" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" > /tmp/gt_opened.tmp && mv /tmp/gt_opened.tmp /tmp/gt_opened
EOF
chmod +x "$OUT/bin/xdg-open"
export PATH="$OUT/bin:$PATH"
# no session bus of a person: open_url must come to the xdg-open above
unset DBUS_SESSION_BUS_ADDRESS
export XDG_RUNTIME_DIR="$OUT/run"

"$ODIN" build tests/linux_desktop/virtual_pointer -vet -out:"$OUT/virtual_pointer" || exit 1
"$ODIN" build tests/linux_desktop/drag_peer -vet -out:"$OUT/bin/drag_peer" || exit 1
"$ODIN" build tests/linux_desktop -build-mode:test -vet -define:ODIN_TEST_THREADS=1 -debug ${GUI_TEST_NAMES:+-define:ODIN_TEST_NAMES=$GUI_TEST_NAMES} -out:"$OUT/desktop_test" || exit 1

run_tests() {
  local name="$1"
  if GUI_TEST_DESKTOP="$name" timeout 240 "$OUT/desktop_test"; then
    echo "desktop ok   $name"
  else
    echo "desktop FAIL $name"; fail=1
  fi
}

if [ -z "$ONLY" ] || [ "$ONLY" = x11 ]; then
  # X11: a server with RandR and XFIXES, a window manager (frames, minimize, _NET_WM_STATE)
  unset WAYLAND_DISPLAY
  export DISPLAY=:97
  Xvfb :97 -screen 0 1280x1024x24 +extension RANDR +extension XFIXES -nolisten tcp >"$OUT/xvfb.log" 2>&1 &
  pids+=($!)
  for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; xprop -root >/dev/null 2>&1 && break; sleep 0.1; done
  openbox >"$OUT/openbox.log" 2>&1 &
  pids+=($!)
  for _ in $(seq 100); do xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q "window id" && break; sleep 0.1; done
  run_tests x11
  kill "${pids[@]}" 2>/dev/null
  wait 2>/dev/null
  pids=()
fi

if [ -z "$ONLY" ] || [ "$ONLY" = randr ]; then
  # RandR: Xvfb's only mode has no timing. Xorg's dummy driver has outputs and modelines: two monitors, 60 and 144 Hz
  unset WAYLAND_DISPLAY
  export DISPLAY=:96
  cat > "$OUT/xorg.conf" <<'EOF'
Section "ServerFlags"
  Option "AutoAddDevices" "false"
  Option "AutoEnableDevices" "false"
EndSection
Section "Device"
  Identifier "dummy"
  Driver "dummy"
  VideoRam 128000
EndSection
Section "Monitor"
  Identifier "mon"
  HorizSync 5-1000
  VertRefresh 20-400
  Modeline "m60"  74.25 1280 1390 1430 1650 720 725 730 750
  Modeline "m144" 178.2 1280 1390 1430 1650 720 725 730 750
EndSection
Section "Screen"
  Identifier "s"
  Device "dummy"
  Monitor "mon"
  DefaultDepth 24
  SubSection "Display"
    Depth 24
    Virtual 2560 720
    Modes "m60"
  EndSubSection
EndSection
EOF
  ${XORG:-Xorg} :96 -config "$OUT/xorg.conf" ${XORG_MODULES:+-modulepath "$XORG_MODULES"} -ac -noreset -logfile "$OUT/xorg.log" -nolisten tcp >/dev/null 2>&1 &
  pids+=($!)
  for _ in $(seq 100); do xprop -root >/dev/null 2>&1 && break; sleep 0.1; done
  xrandr --addmode DUMMY1 m60 && xrandr --addmode DUMMY1 m144 && xrandr --output DUMMY0 --mode m60 --pos 0x0 --output DUMMY1 --mode m144 --pos 1280x0
  if GUI_TEST_RANDR=1 GUI_TEST_DESKTOP= timeout 60 "$OUT/desktop_test"; then
    echo "desktop ok   randr"
  else
    echo "desktop FAIL randr"; tail -5 "$OUT/xorg.log" 2>/dev/null; fail=1
  fi
  if [ -n "${XORG:-}" ]; then sudo -n pkill -f "Xorg :96" 2>/dev/null; fi
  kill "${pids[@]}" 2>/dev/null
  wait 2>/dev/null
  pids=()
fi

if [ -z "$ONLY" ] || [ "$ONLY" = wayland ]; then
  # Wayland: sway on no hardware. Its virtual output and seat take the test's cursor; wtype is a virtual keyboard
  unset DISPLAY
  export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1
  cat > "$OUT/sway.conf" <<'EOF'
xwayland disable
output HEADLESS-1 resolution 1280x1024@60Hz
default_border none
EOF
  sway --unsupported-gpu -c "$OUT/sway.conf" >"$OUT/sway.log" 2>&1 &
  pids+=($!)
  for _ in $(seq 100); do
    s=$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v lock | head -1)
    [ -n "$s" ] && break
    sleep 0.1
  done
  export WAYLAND_DISPLAY="$(basename "${s:-wayland-1}")"
  export SWAYSOCK="$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* 2>/dev/null | head -1)"
  sleep 0.5
  # the seat's devices: a pointer the tests move with swaymsg, a keyboard (wtype sleeping); a device stays while its client does
  "$OUT/virtual_pointer" &
  pids+=($!)
  wtype -s 3600000 &
  pids+=($!)
  sleep 0.5
  run_tests wayland
  [ "$fail" != 0 ] && tail -20 "$OUT/sway.log"
fi
exit $fail

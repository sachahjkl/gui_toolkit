# Platform backends (`platform` package)

The `platform` package is the toolkit's window, input, clipboard, cursors and desktop services, behind **one neutral
API** (no system types in the public signatures). Each system has a backend chosen at build time by file suffix
(`*_win32.odin` for Windows, `*_linux.odin` for Linux), and the pure, shared logic (clipboard conversions, HTML-format
headers, drag helpers, dialog filters, the chrome hit test, cursor shapes) lives in files with no suffix.

A program written against this API — the toolkit's `ui` and `render`, and an application such as Wren — does not name
Win32 or Wayland. It opens a window, polls events, draws, and asks for services, the same on every system.

| Backend | Window / input | Clipboard | Dialogs | Cursors | DPI | Decorations |
|---|---|---|---|---|---|---|
| Windows (`*_win32.odin`) | Win32 messages | OLE + CF_* | IFileDialog | IDC_* / drawn | per-monitor v2 | DWM + integrated title |
| Linux Wayland (`window_wl_linux.odin`) | xdg-shell + wl_seat (xkbcommon) | wl_data_device | portal / zenity / kdialog | wp_cursor_shape_v1, else libwayland-cursor | wp_fractional_scale_v1 with wp_viewporter, else the wl_output integer scale | zxdg-decoration, or the app's integrated title |
| Linux X11 (`window_x11_linux.odin`) | XCB + xkbcommon | CLIPBOARD selection | portal / zenity / kdialog | libxcb-cursor, else the server's cursor font; custom images through RENDER | Xft.dpi | Motif hints |

## The neutral types (what a backend fills, what the app reads)

- **`Window`** = `Native_Window` (per-backend state, one `rawptr` per backend so the struct carries no system types) +
  the fields every backend fills: `size` (physical pixels), `dpi_scale` (dpi/96), `focused`, `active`, `events`,
  `chrome`, `user`, `on_frame`.
- **`Event`** (`Event_Kind`: `Key_Press`/`Release`, `Text`, `Mouse_*`, `Scroll`, `Close`, `Activate`, `Pointer_*`,
  `Drop_*`, `Accessibility`), with `pos` in client pixels, `delta` in wheel notches (`+y` scrolls content down),
  `mods`, `buttons`, `stamp`, `pointer`, `injected`.
- **`Key`**, **`Mouse_Button`**, **`Modifier`**, **`Cursor`** (named after the CSS keywords), **`Display_Info`**
  (refresh rate for pacing), **`Chrome_Regions`** (the integrated title bar's regions, hit-tested by
  `hit_test_chrome`), **`Placement`** (outer rect + maximized).

## What a backend must provide

A new backend implements this set (the Win32 and Linux backends both do). Procedures that cannot apply to a system are
no-ops with a sane return, never an error.

**Lifecycle** — `open_window`, `open_window_offscreen`, `show_window`, `destroy_window`, `set_title`, `set_size`,
`is_closed`, `cancel_close` (the app answered a Close by staying open), `is_offscreen`.
`can_hide_windows()`: whether a window can exist unseen, made and never shown (Windows); on Wayland and X11 it cannot, and a
program that needs an unseen window opens an offscreen one.

**Identity** — `set_app_id(id)`, once before the first window: on Linux, the windows' Wayland app_id and X11 WM_CLASS.
The desktop finds the program's `<id>.desktop` by it, for the icon and the name in a task bar. Without a call, the id is
the executable's file name. On Windows it does nothing: the program declares its AppUserModelID itself.

**State** — `minimize`, `toggle_maximize`, `set_fullscreen`, `request_close`, `is_maximized`, `is_minimized`,
`is_fullscreen`, `set_integrated_title` / `is_integrated_title`, `set_chrome_regions`, `show_system_menu`,
`needs_top_border`, `resize_border`, `set_backdrop`, `set_square_corners`, `set_border_color`, `set_dark_title`,
`set_offscreen_dpi`, `set_offscreen_active`.

**An offscreen window's machine** (`virtual.odin`) — `virtual_screen_set`, `virtual_screen`: the screen `monitor_size` and `display_info` answer for it; its input comes through `inject_event`, its cursor is `w.cursor`, its clipboard the process's store: nothing of the machine it runs on is read or written.

**Loop** — `poll_events` (re-entrancy safe; drops what the last call returned, keeps what came since), `wait_event`,
`wait_handle` (waits on a render frame-latency handle while taking input), `take_paint_request`, `pump_stats`, `wake`,
`wake_handle` / `wake_signal` (a thread-safe wake handle for offscreen windows), `inject_event`.

**Placement** — `outer_rect`, `client_origin`, `move_window`, `get_placement`, `set_placement`.

**Display** — `display_info`, `display_invalidate`, `display_live_hz`, `monitor_size` (the window's monitor in pixels,
for a screen-sized fixed surface).

**Cursors** — `set_cursor`, `set_cursor_custom`, `cursor_info`, `cursor_source`, `cursor_scheme`, `cursor_size_px`,
`cursor_render`, `shown_cursor`, `cursor_handle_of`, `custom_cursor_create` / `_release` / `_valid` / `_stats` /
`_info`, `cursors_destroy`.

**Text clipboard** — `get_clipboard`, `set_clipboard`. **Rich clipboard** (`clipboard.odin`) —
`clipboard_set` / `_get_image` / `_get_html` / `_get_files` / `_formats` / `_sequence` / `_watch` / `_changed`.

**Dialogs and shell** — `open_file_dialog`, `save_file_dialog`, `pick_folder_dialog`, `known_folder_path`, `open_url`,
`open_path`, `reveal_in_folder`.

**System** — `config_dir`, `system_font_path`, `os_animations_enabled`, `app_icon_rgba`.

**Devices** — `input_devices`, `touch_max_points`.

**Drag and drop** (`dragdrop.odin`), **tray** (`tray.odin`), **accessibility** (`a11y.odin`): optional; a backend that
has none keeps the shared stubs (neither Windows nor Linux), which answer "not supported".

## Differences the app should know

- **Threads.** A window's procedures run on the thread that opened it. Windows' messages are the thread's; on Linux each
  thread that opens windows has its own connection to the display server (its events, its seat's focus and serials) and its
  own session bus, so several apps of a process each run on a thread of their own. The process's resources (the clipboard
  store, the virtual screen of the offscreen windows, the window class) are locked or atomic (getting-started.md, "Where state lives").
- **Window position.** X11 and Windows report and set the outer rectangle. **Wayland does not let a client know or set
  its absolute position** (the compositor places windows): `client_origin` is `{0,0}`, `move_window` is a no-op. Save
  and restore the **size** and the **maximized** state (both work everywhere), not the position, on Wayland.
- **Decorations.** Windows and KDE (zxdg-decoration) draw a server title bar; **GNOME draws none** — set an integrated
  title bar (`set_integrated_title`) and draw it yourself (the toolkit's `ui.window_buttons` already does, the same
  frame as Windows). X11 asks the window manager for no decorations through Motif hints when integrated.
- **DPI.** Windows is per-monitor (physical pixels, `dpi_scale` = dpi/96). Wayland is `wp_fractional_scale_v1` with `wp_viewporter`:
  the buffer has the scaled size, the surface the logical one; without them the `wl_output` integer scale. X11 reads `Xft.dpi`.
- **Translucency.** `set_backdrop` is the Windows acrylic effect; on Linux a window is translucent when it was opened
  with an alpha surface (`render.init` `transparent`), which the compositor blends — there is no extra effect to turn
  on, so `set_backdrop` reports whether the window is translucent at all.
- **The clipboard change signal** is cheap on Windows (a sequence number). On Linux it comes from `wl_data_device` or XFIXES;
  an X server without XFIXES only tells a program when it loses the clipboard.
- **Libraries load at run time** (`dlopen`): a binary built for Linux starts on a machine missing libwayland-client or
  libxcb and prints which library is absent (it does not fail to link). The window backends needed:
  libwayland-client + libxkbcommon (Wayland), libxcb + libxkbcommon (X11; libxkbcommon-x11 refines the keymap).

## Rendering on Linux

`render` chooses **wgpu** (Vulkan) on Linux; there is no Direct3D. The surface comes from the window's native handles
through wgpu's platform surface descriptors:

- Wayland: `wgpu.SurfaceSourceWaylandSurface{ display = wl_display, surface = wl_surface }`.
- X11 (XCB): `wgpu.SurfaceSourceXCBWindow{ connection = xcb_connection, window = xcb_window }`.

The platform package exposes these handles for the renderer through `native_surface_handles(w)`; `render.init` takes a neutral handle instead of a `win.HWND` so the same call opens the renderer on
every system. The present mode (`Vsync`: wgpu's Fifo; `Tearing`: its Immediate, where the surface offers it), resize, DPI and capture (`src/render/capture.odin`) are the
same code as the Windows wgpu path (`wgpu_surface.odin`), which the Linux surface slots into.

## Linux desktop services

Beyond the window, input and plain-text clipboard, the Linux backend now carries the full desktop services, behind the
same neutral API as Windows. Most ride a small D-Bus client (the `dbus` package — see `docs/dbus.md`), whose socket is
folded into the window loop's `poll(2)` so the bus is drained on the UI thread each pump. Every service degrades to a
sane fallback (or a no-op) when its desktop piece is absent, so a bare session still runs.

### Rich clipboard (cross-process)

The clipboard owner is complete on both backends. **Wayland** (`clipboard_wl_linux.odin`): a full `wl_data_source`
offers every flavour the store holds (text, HTML, `text/uri-list`, and PNG when the app sets `png_encode_hook` and `png_decode_hook`: the toolkit has no PNG codec on Linux), its `send` callback writes the bytes to the
fd the compositor hands over, `cancelled` releases it, and `set_selection` uses the last input serial; reading a
flavour another client owns dups a pipe, calls `wl_data_offer.receive`, and reads it. There is no **primary**
(middle-click) selection on Wayland (on X11 a copy owns `PRIMARY` too). **X11** (`clipboard_x11_linux.odin`): `SelectionRequest` serves `TARGETS`,
`TIMESTAMP`, `MULTIPLE` and the MIME targets, with **INCR** for a payload too large for one property (a pasted image);
reading follows an INCR hand-off. `clipboard_set` / `clipboard_get_image` / `_get_html` / `_get_files` read a foreign
owner over the selection transport.

### Drag and drop

`dragdrop_linux.odin` keeps the window's `Dnd_State` and the API; the transports are **Wayland `wl_data_device`**
(`dragdrop_wl_linux.odin`: enter / motion / drop, the offered MIME types, `set_actions`, and a `wl_data_source` for the
source side) and **X11 XDND v5** (`dragdrop_x11_linux.odin`: `XdndAware`, the Enter / Position / Status / Drop / Leave
/ Finished client messages, the data read over `XdndSelection`). The public API is the Win32 one: `drop_target_enable`,
`drop_data`, `drop_set_effect`, `drag_start`, `drop_inject`, `drag_script`.

### Tray icon and notifications

`tray_linux.odin` implements the **StatusNotifierItem** specification over D-Bus: it exports an item object, serves its
properties (icon as an ARGB pixmap, title, tooltip, menu), registers with the `StatusNotifierWatcher`, and turns the
host's Activate / SecondaryActivate / ContextMenu into `Tray_Event`s. The menu is a **`com.canonical.dbusmenu`** tree
(`dbusmenu_linux.odin`: `GetLayout`, `Event`). `tray_notify` calls **`org.freedesktop.Notifications`**; its
`ActionInvoked` / `NotificationClosed` signals become `Notify_*` events. Same public API as `tray_win32.odin`.

### Dialogs, shell and live theme

`portal_linux.odin` adds the **XDG portals**: `org.freedesktop.portal.FileChooser` (OpenFile / SaveFile / a folder,
filters, multiple, suggested name; the result arrives on a `Response` signal), `org.freedesktop.portal.OpenURI`
(`open_url` / `open_path`), and `org.freedesktop.portal.Settings` for **live light / dark** — `dark_mode_preferred`
reads `org.freedesktop.appearance color-scheme` and `watch_color_scheme(cb)` fires `cb` on the `SettingChanged` signal.
`dialogs_linux.odin` tries the portal first, then zenity / kdialog; `theme_linux.odin` falls back to the GTK settings.

### Accessibility, IME, and the smaller services

- **Accessibility** (`a11y_linux.odin`): a minimal **AT-SPI 2** bridge over D-Bus (the a11y bus address from
  `org.a11y.Bus.GetAddress`), exposing the window's tree (roles, names, states, bounds) and the `Action` interface's
  Invoke / Focus from the toolkit's neutral `A11y_Update`. Nothing is built while no assistive technology connects.
- **IME** (`ime.odin` + `ime_wl_linux.odin`): **Wayland `zwp_text_input_v3`** commits text as `.Text` events (the same
  path as a typed key) and exposes the preedit through `ime_preedit`; `ime_set_cursor_rect` places the candidate
  window. What the protocol sends is pending until its `done`: `Ime_Compose` (`ime.odin`, pure: `tests/ime`) keeps it and makes
  the events (Backspace presses for the text replaced, `.Text` for the text committed) and the preedit;
  `ime_cursor_rect_logical` turns the caret's rectangle into the compositor's units. On **X11**, text comes from the key and the modifiers through libxkbcommon as `.Text`:
  no input method, and no dead keys or Compose sequences (Known gaps).
- **Smaller services** (`services_linux.odin`): `idle_inhibit` / `idle_uninhibit` keep the screen awake through
  `org.freedesktop.ScreenSaver`; `add_recent_file` appends to the freedesktop `recently-used.xbel`.
- **Cursors** (`cursors_wl_linux.odin`): Wayland names a shape to the compositor through `wp_cursor_shape_v1`, so the
  pointer matches the user's theme with no pixel upload.

### Known gaps

- **AT-SPI** is a minimal bridge (root tree, names, DoAction) that answers calls but does not register with the
  desktop: a screen reader such as Orca does not find the window yet. The full surface (registration, Text ranges,
  Collection, per-node objects at their own paths) is what AccessKit's `accesskit_unix` adapter would give.
- **Input**: no dead keys or Compose sequences on X11, no touch on Wayland.


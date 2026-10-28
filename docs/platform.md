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
| Linux Wayland (`window_wl_linux.odin`) | xdg-shell + wl_seat (xkbcommon) | wl_data_device | portal / zenity / kdialog | wp_cursor_shape / theme | wl_output scale, fractional-scale | zxdg-decoration or client-side |
| Linux X11 (`window_x11_linux.odin`) | XCB + xkbcommon | CLIPBOARD selection | portal / zenity / kdialog | Xcursor theme | Xft.dpi | Motif hints |

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
`is_closed`, `is_offscreen`.

**State** — `minimize`, `toggle_maximize`, `set_fullscreen`, `request_close`, `is_maximized`, `is_minimized`,
`is_fullscreen`, `set_integrated_title` / `is_integrated_title`, `set_chrome_regions`, `show_system_menu`,
`needs_top_border`, `resize_border`, `set_backdrop`, `set_square_corners`, `set_border_color`, `set_dark_title`,
`set_offscreen_dpi`.

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
has none keeps the shared `!windows` stubs, which answer "not supported".

## Differences the app should know

- **Window position.** X11 and Windows report and set the outer rectangle. **Wayland does not let a client know or set
  its absolute position** (the compositor places windows): `client_origin` is `{0,0}`, `move_window` is a no-op. Save
  and restore the **size** and the **maximized** state (both work everywhere), not the position, on Wayland.
- **Decorations.** Windows and KDE (zxdg-decoration) draw a server title bar; **GNOME draws none** — set an integrated
  title bar (`set_integrated_title`) and draw it yourself (the toolkit's `ui.window_buttons` already does, the same
  frame as Windows). X11 asks the window manager for no decorations through Motif hints when integrated.
- **DPI.** Windows is per-monitor (physical pixels, `dpi_scale` = dpi/96). Wayland is the `wl_output` integer scale
  (fractional-scale refines it where the compositor offers `wp_fractional_scale_v1`). X11 reads `Xft.dpi`.
- **Translucency.** `set_backdrop` is the Windows acrylic effect; on Linux a window is translucent when it was opened
  with an alpha surface (`render.init` `transparent`), which the compositor blends — there is no extra effect to turn
  on, so `set_backdrop` reports whether the window is translucent at all.
- **The clipboard change signal** is cheap on Windows (a sequence number). On Linux it is best effort: a window reports
  a change whenever it does not own the selection.
- **Libraries load at run time** (`dlopen`): a binary built for Linux starts on a machine missing libwayland-client or
  libxcb and prints which library is absent (it does not fail to link). The window backends needed:
  libwayland-client + libxkbcommon (Wayland), libxcb + libxkbcommon (X11; libxkbcommon-x11 refines the keymap),
  optionally libdecor for client-side decorations.

## Rendering on Linux

`render` chooses **wgpu** (Vulkan) on Linux; there is no Direct3D. The surface comes from the window's native handles
through wgpu's platform surface descriptors:

- Wayland: `wgpu.SurfaceSourceWaylandSurface{ display = wl_display, surface = wl_surface }`.
- X11 (XCB): `wgpu.SurfaceSourceXCBWindow{ connection = xcb_connection, window = xcb_window }`, or
  `SurfaceSourceXlibWindow` with an Xlib display.

The platform package exposes these handles for the renderer through `native_surface_handles(w)` (see the report's
integration notes); `render.init` takes a neutral handle instead of a `win.HWND` so the same call opens the renderer on
every system. The present mode (`FIFO` / `Mailbox`), resize, fractional DPI and capture (`render/capture.odin`) are the
same code as the Windows wgpu path (`wgpu_surface.odin`), which the Linux surface slots into.

## Linux desktop services

Beyond the window, input and plain-text clipboard, the Linux backend now carries the full desktop services, behind the
same neutral API as Windows. Most ride a small D-Bus client (the `dbus` package — see `docs/dbus.md`), whose socket is
folded into the window loop's `poll(2)` so the bus is drained on the UI thread each pump. Every service degrades to a
sane fallback (or a no-op) when its desktop piece is absent, so a bare session still runs.

### Rich clipboard (cross-process)

The clipboard owner is complete on both backends. **Wayland** (`clipboard_wl_linux.odin`): a full `wl_data_source`
offers every flavour the store holds (text, HTML, PNG, `text/uri-list`), its `send` callback writes the bytes to the
fd the compositor hands over, `cancelled` releases it, and `set_selection` uses the last input serial; reading a
flavour another client owns dups a pipe, calls `wl_data_offer.receive`, and reads it. The **primary** (middle-click)
selection rides `zwp_primary_selection_v1`. **X11** (`clipboard_x11_linux.odin`): `SelectionRequest` serves `TARGETS`,
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
  window. On **X11**, libxkbcommon already composes dead keys and Compose sequences inline, so committed text arrives
  as `.Text` with no extra work.
- **Smaller services** (`services_linux.odin`): `idle_inhibit` / `idle_uninhibit` keep the screen awake through
  `org.freedesktop.ScreenSaver`; `add_recent_file` appends to the freedesktop `recently-used.xbel`.
- **Cursors** (`cursors_wl_linux.odin`): Wayland names a shape to the compositor through `wp_cursor_shape_v1`, so the
  pointer matches the user's theme with no pixel upload.

### Known gaps (the lead's first checks)

- The **X11 drag source** (`x11_drag_start`) sends XDND to the toplevel under the pointer, but `x11_window_at` does not
  yet walk the window tree to find an XDND-aware toplevel (it returns 0), so cross-application X11 drags *out* of the
  window are the piece to try under a real WM; drops *into* the window, and all Wayland drags, are complete.
- The **X11 cursor** still uses the compositor default (no Xcursor upload yet); Wayland cursor shapes are live.
- **AT-SPI** is a minimal bridge (root tree, names, DoAction); the full surface (Text ranges, Collection, per-node
  objects at their own paths) is the AccessKit `accesskit_unix` alternative discussed in the night's report.


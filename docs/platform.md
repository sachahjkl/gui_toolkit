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
  `Drop_*`, `Accessibility`, `Hotkey`, `Notification_*`, `Clipboard_Data`), with `pos` in client pixels, `delta` in wheel notches (`+y` scrolls content down),
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
`hide_window(w)` takes a shown window off the screen and `show_window(w)` brings it back, its size, title and interface
kept: a program that lives in the notification area hides its window instead of closing it, and shows it again in a few
milliseconds (no new device, fonts or state). A window with a renderer goes through the host (`host.host_hide`,
`host.host_show`), which releases the renderer's surface first. Draw no frame of a hidden window (on Linux a frame would
wait for a screen the window is not on); its wait still ends on a wake, a post and the tray. Wayland: the toplevel role
and the surface go, and `show_window` makes new ones and waits for their first configure, so the compositor places and
focuses it as a new window. (The role alone is not enough: the last frames' content updates may wait in the surface's
queue behind a FIFO barrier of `wp_fifo_v1` that an unmapped surface never clears, and every later commit with them.)
X11: unmapped (withdrawn). Windows: `SW_HIDE`.
A window opened and not yet shown is hidden too, and gets no frame either. Wayland: it is a surface with no role (the
renderer makes its surface on it); its toplevel is made at the first `show_window`, so a window never shown is in no
task bar (ShojiWM lists every toplevel, even one with no picture yet). `set_maximized` and `set_fullscreen` asked before
that show are asked by the new toplevel; `minimize` is asked once its first configure came. `Window.shown_again` counts the shows after a hide: the host makes the
renderer's surface again at the next frame (`render.surface_remake`).
`raise_window(w)` brings a shown window to the front with the keyboard focus. X11: `_NET_ACTIVE_WINDOW`. Wayland:
`xdg_activation_v1`, a token with the seat's last input serial the connection saw (0 when it saw none), spent on the
window's surface; the compositor decides. A compositor that does not focus a new window by itself (ShojiWM's Windows 7
configuration) gives the focus this way: call it after `show_window` when the user asked for the window. A second start of the
program brings the first one's window up with the token its launcher gave it: `activation_token_from_env()` in the second
(Wayland's `XDG_ACTIVATION_TOKEN`, X11's `DESKTOP_STARTUP_ID`, taken out of the environment), handed to the first, which
calls `raise_window_token(w, token)` (Windows: `raise_window`).

**Identity** — `set_app_id(id)`, once before the first window: on Linux, the windows' Wayland app_id and X11 WM_CLASS.
The desktop finds the program's `<id>.desktop` by it, for the icon and the name in a task bar. Without a call, the id is
the executable's file name. On Windows it does nothing: the program declares its AppUserModelID itself.

**State** — `minimize`, `toggle_maximize`, `set_fullscreen`, `request_close`, `is_maximized`, `is_minimized`,
`is_fullscreen`, `set_integrated_title` / `is_integrated_title`, `system_title_available`, `set_chrome_regions`, `show_system_menu`,
`set_caption_menu_app`, `system_menu_available`,
`needs_top_border`, `needs_frame_outline`, `resize_border`, `set_backdrop`, `set_square_corners`, `set_border_color`, `set_dark_title`,
`set_offscreen_dpi`, `set_offscreen_active`.

**An offscreen window's machine** (`virtual.odin`) — `virtual_screen_set`, `virtual_screen`: the screen `monitor_size` and `display_info` answer for it; its input comes through `inject_event`, its cursor is `w.cursor`, its clipboard the process's store: nothing of the machine it runs on is read or written.

**Loop** — `poll_events` (re-entrancy safe; drops what the last call returned, keeps what came since), `wait_event`,
`wait_handle` (waits on a render frame-latency handle while taking input), `take_paint_request`, `pump_stats`, `wake`,
`wake_handle` / `wake_signal` (a thread-safe wake handle for offscreen windows), `inject_event`.

**Placement** — `outer_rect`, `client_origin`, `move_window`, `get_placement`, `set_placement`.
`move_to_active_monitor(w, follow)` puts a window on the monitor the user works on, at the same place of its work area
(`rect_on_work`): with `.Pointer` (the default) the monitor under the pointer, with `.Focus` the one of the window in front
(the pointer's when there is none; `active_monitor_parse` reads "pointer" or "focus"): a program called up by a shortcut or a
notification area icon calls it before it shows its window. Windows; elsewhere the system places what it shows.

**Display** — `display_info`, `display_invalidate`, `display_live_hz`, `monitor_size` (the window's monitor in pixels,
for a screen-sized fixed surface).

**Cursors** — `set_cursor`, `set_cursor_custom`, `cursor_info`, `cursor_source`, `cursor_scheme`, `cursor_size_px`,
`cursor_render`, `shown_cursor`, `cursor_handle_of`, `custom_cursor_create` / `_release` / `_valid` / `_stats` /
`_info`, `cursors_destroy`.

**Text clipboard** — `get_clipboard`, `set_clipboard`. **Rich clipboard** (`clipboard.odin`) —
`clipboard_request` (a read that does not wait: a `Clipboard_Data` event answers it), `clipboard_set` / `_get_image` /
`_get_html` / `_get_files` / `_formats` / `_sequence` / `_watch` / `_changed`.

**Dialogs and shell** — `open_file_dialog`, `save_file_dialog`, `pick_folder_dialog`, `known_folder_path`, `open_url`,
`open_path`, `reveal_in_folder`. `launch_detached(args)` (Linux) starts a program and does not wait for it, its output
nowhere: xdg-open, an application of "Open with" (`desktop.open_with`).

**System** — `config_dir`, `system_font_path`, `os_animations_enabled`, `app_icon_rgba`.

**Network interfaces** (`net_interfaces.odin`) — `interface_addresses()` lists every IPv4 and IPv6 address of every
interface, IPv4 first (`Interface_Address`: the interface's name, the family, the address and the netmask in network
order, `up`, `loopback`); `interface_addresses_destroy` frees the list. core:net's `IP4_Address` is `addr[:4]`, its
`IP6_Address` is `transmute([8]u16be)addr`. Linux: the C library's `getifaddrs`. Elsewhere: an empty list for now.

**Devices** — `input_devices`, `touch_max_points`.

**Hotkeys** (`hotkey.odin`) — `hotkey_register(w, id, hk)`, `hotkey_unregister`: a combination the system gives the
window wherever the keyboard is, as a `Hotkey` event whose `hotkey` is the id. `hotkey_parse("Ctrl+Shift+V")` and
`hotkey_text` read and write their text (Ctrl, Shift, Alt, Win, then a letter, a digit, F1 to F12, a named key, or a
single character for a key Key does not name: `Hotkey.char`, the key that types it on the user's layout, "Ctrl+Shift+ù").
`ui.hotkey_field` records one from the keys pressed (a click, then the keys): a key Key does not name comes as a
`Key_Press` with its character (`Event.char`).
Windows: `RegisterHotKey` (false when another program holds the combination). Linux: none (false): the compositor binds
shortcuts to commands. `send_hotkey(w, hk)` is the other way: it presses `hk` for whatever window has the keyboard (another
program's: a clipboard history pastes with Ctrl+V into the program it was called from). Windows: `SendInput`. Wayland: a
virtual keyboard of the seat (`zwp_virtual_keyboard_v1`, with a keymap that has the key alone; false when the compositor
has none); the window's thread calls it. X11: false.

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
- **The session's windows.** `toplevels(w)` lists the windows of the session, other programs' too (their app id,
  title, focus, minimized), and `toplevel_activate(w, id)` brings one to the front: where the compositor offers
  wlr-foreign-toplevel-management (sway, Hyprland, niri, labwc, river, ShojiWM). Elsewhere (GNOME, KDE, X11, Windows)
  the list is empty: a program hides what needs it.
- **A window not shown.** Wayland's compositor tells when it shows a window's picture (`wl_surface.frame`), and a present
  in Fifo waits for that word about the last one: a window it does not show (covered whole, minimized, on another
  workspace) never gets it. `frame_shown_ask(w)`, just before a picture is presented, asks for it; `frame_shown_pending(w)`
  says it has not come; `frame_shown_forget(w)` drops it when no picture was presented after all. `host` presents no picture while it is pending (the input is still read and built), and the word
  asks for a repaint. False and nothing elsewhere.
- **Decorations.** Windows and KDE (zxdg-decoration) draw a server title bar; **GNOME draws none** — set an integrated
  title bar (`set_integrated_title`) and draw it yourself (the toolkit's `ui.window_buttons` already does, the same
  frame as Windows). X11 asks the window manager for no decorations through Motif hints when integrated.
  `system_title_available(w)` says whether the system can draw the title bar (Windows, X11, a Wayland compositor with
  zxdg-decoration): where it can, a program offers the choice (a preference "the system's title bar") and switches at
  any time with `set_integrated_title`; `ui.window_buttons` draws nothing while the title bar is the system's.
- **An integrated title bar's frame on Linux** (`frame_linux.odin`). Windows moves, resizes and maximizes a window from
  its hit test; Wayland and X11 leave that to the client. A left press on the caption becomes the compositor's move
  (`xdg_toplevel.move`, X11 `_NET_WM_MOVERESIZE`), on a band along any of the four sides its resize, a double click on
  the caption maximizes or restores, a right click there opens the compositor's window menu (Wayland), and the pointer
  over a band shows the resize cursor. The app gets an `Event.Frame_Press` instead of the press. Where the window has
  no frame of the system's, `needs_frame_outline` is true and `ui` draws a 1-pixel outline in the theme's border colour:
  not when the compositor chose server-side decorations, when it tiles the window (the `tiled_*` states: sway,
  Hyprland and niri draw their own border), when the X11 window manager reports `_NET_FRAME_EXTENTS`, nor when the
  window is maximized or full screen. Windows always has the system's.
- **The app's menu of the title bar.** A right click on the caption of an integrated title bar opens the system's window
  menu: Windows' (Restore, Move, Size...), the Wayland compositor's (`xdg_toplevel.show_window_menu`). X11 has none: the
  click is the app's there. `set_caption_menu_app(w, true)` gives that click to the app on every system: a `Mouse_Press`
  and a `Mouse_Release` of `.Right` at that point (Windows: `WM_NCRBUTTONDOWN` over `HTCAPTION` is taken and captured,
  and the `WM_CONTEXTMENU` of its release is not given to `DefWindowProc`). `ui.caption_right_clicked()` says that such
  a click came on an empty part of the title bar this frame, and where; the app opens its own menu there.
  `show_system_menu(w, pos)` still opens the system's, from an item of that menu; `system_menu_available(w)` says
  whether there is one to open (Windows, Wayland; not X11 nor an offscreen window). Call
  `set_caption_menu_app` once per window; the left button, the double click and the resize bands stay the system's.

  ```odin
  platform.set_caption_menu_app(w, true)
  // in the build, after the title bar:
  if at, ok := ui.caption_right_clicked(); ok { ui.ctx_menu_open(menu_key, at) }
  ```
- **DPI.** Windows is per-monitor (physical pixels, `dpi_scale` = dpi/96). Wayland is `wp_fractional_scale_v1` with `wp_viewporter`:
  the buffer has the scaled size, the surface the logical one; without them the `wl_output` integer scale. A window that
  the compositor has given no fractional scale yet follows the integer scale. A window never shown has a surface with no
  role, on no output: most compositors send its scale with the first configure, and the first show waits for it. X11 reads `Xft.dpi`.
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
offers every flavour the store holds (text, HTML, `text/uri-list`, `image/png` through the toolkit's codec: [png.md](png.md)), its `send` callback writes the bytes to the
fd the compositor hands over, `cancelled` releases it, and `set_selection` uses the last input serial; reading a
flavour another client owns dups a pipe, calls `wl_data_offer.receive`, and reads it. There is no **primary**
(middle-click) selection on Wayland (on X11 a copy owns `PRIMARY` too). **X11** (`clipboard_x11_linux.odin`): `SelectionRequest` serves `TARGETS`,
`TIMESTAMP`, `MULTIPLE` and the MIME targets, with **INCR** for a payload too large for one property (a pasted image);
reading follows an INCR hand-off. `clipboard_set` / `clipboard_get_image` / `_get_html` / `_get_files` read a foreign
owner over the selection transport, in the best type it offers (an image as PNG, JPEG or BMP; files as `text/uri-list` or
GNOME's list: [clipboard.md](clipboard.md)).

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
(`dbusmenu_linux.odin`: `GetLayout`, `Event`). `tray_notify` shows its notification through `notify_linux.odin`;
the results become `Notify_*` events of the icon. Same public API as `tray_win32.odin`.

`notify_linux.odin` shows system notifications through **`org.freedesktop.Notifications`**: `Notify` with the
`desktop-entry`, `urgency` and `image-data` hints; `ActionInvoked`, `NotificationClosed` and `ActivationToken` become
`Notification_*` events of the window ([notifications.md](notifications.md)).

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


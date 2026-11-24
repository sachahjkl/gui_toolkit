# gt-file-picker

Asks the person for files or a folder, and gives your program what they chose. Any program can call it: a shell
script, a program in any language, a program built on gui_toolkit. On Linux it can also be the desktop's file chooser
for every program that asks the XDG desktop portal (GTK, Qt, Electron, Flatpak).

It is the gui_toolkit file picker in a window of its own: places, a path bar with completion, a filter and a search in
subfolders, a preview, thumbnails, the keys of a file manager.

## Download

Each release of gui_toolkit has it, on [its releases page](https://github.com/sachahjkl/gui_toolkit/releases):

- `gt-file-picker-windows-x64.zip`: `gt-file-picker.exe`. It needs nothing beside it.
- `gt-file-picker-linux-x64.tar.gz`: `bin/gt-file-picker` and the portal's files in `share/`.

On Linux the program opens these system libraries when it starts. Every desktop distribution has them.

- The display: `libwayland-client.so.0` and `libxkbcommon.so.0` (Wayland), or `libX11.so.6`, `libX11-xcb.so.1`
  and `libxcb.so.1` (X11).
- The drawing: `libvulkan.so.1` and a Vulkan driver; without one, `libEGL.so.1` and an OpenGL driver.
- The fonts: `libfontconfig.so.1` (linked: the program does not start without it) and `libfreetype.so.6`.
- `libgcc_s.so.1` and glibc (linked).

It speaks D-Bus itself: it needs no `libdbus`. It needs a glibc as recent as the one it was built with (the
toolkit's pinned Nixpkgs).

## Commands

```
gt-file-picker open [--multiple] [options]     files to open
gt-file-picker save [--name NAME] [options]    a file to save
gt-file-picker folder [options]                a folder
gt-file-picker --json < request.json           the request as JSON, the answer as JSON
gt-file-picker --portal                        the XDG portal's FileChooser backend (Linux)
```

| Option | |
|---|---|
| `--title TEXT` | the window's title |
| `--folder PATH` | the folder shown first |
| `--filter NAME:PATTERNS` | a line of the type list: `"Images:*.png;*.jpg"`; one per `--filter` |
| `--all-files` | a last line, "All files" |
| `--name NAME` | `save`: the name suggested |
| `--accept WORD` | the act button's word |
| `--remember ID` | the picker starts in the folder that this ID was left in |
| `--theme NAME[:MODE]` | the look: one of the toolkit's themes (`Ember` by default) and `light`, `dark` or `system` (by default: the desktop's light or dark setting, followed while the picker is open) |
| `--json` | the answer as JSON |

The chosen paths go to stdout, one per line. A path with a line break in it is only safe with `--json`.

```sh
files=$(gt-file-picker open --multiple --filter "Images:*.png;*.jpg") || exit
```

## Exit codes

| Code | |
|---|---|
| 0 | the person chose |
| 1 | the person cancelled (Cancel, Escape, the window closed) |
| 2 | an error: the arguments or the request do not read, or no window can open |

## JSON

The request, on stdin with `--json` and no kind: every field but `kind` may be absent.

```json
{"kind": "open", "title": "Open a picture", "folder": "/home/me/Pictures", "multiple": true,
 "filters": [{"name": "Images", "patterns": ["*.png", "*.jpg"]}], "filter": 0, "all_files": true,
 "name": "", "accept": "Open", "remember": "pictures",
 "choices": [{"id": "ro", "label": "Read only", "options": [], "initial": "false"}]}
```

`kind` is `open`, `save` or `folder`. A choice with options is a drop-down (`initial`: an option's id); one
without is a check box (`initial`: `"true"` or `"false"`). `save` asks before it replaces a file, unless
`"overwrite_prompt": false`.

The answer:

```json
{"status": "chosen", "paths": ["/home/me/Pictures/a.png"], "filter": 0, "choices": [{"id": "ro", "value": "false"}]}
```

`status` is `chosen`, `cancelled` or `failed` (with `error`, what went wrong).

## The desktop's file chooser (Linux)

With `--portal` the program serves `org.freedesktop.impl.portal.FileChooser` (OpenFile, SaveFile, SaveFiles) under
the name `org.freedesktop.impl.portal.desktop.gtfilepicker`. Each request opens its own picker, in a process of its
own. To make it the desktop's file chooser:

1. Put `share/xdg-desktop-portal/portals/gtfilepicker.portal` in `/usr/share/xdg-desktop-portal/portals/` (or the
   `share` of your system's prefix).
2. Put `share/dbus-1/services/org.freedesktop.impl.portal.desktop.gtfilepicker.service` in
   `~/.local/share/dbus-1/services/`, and set its `Exec=` to where `gt-file-picker` is.
3. In `~/.config/xdg-desktop-portal/portals.conf` (or `<desktop>-portals.conf`), route the file chooser to it and
   keep your desktop's backend for the rest:

   ```ini
   [preferred]
   default=<your desktop's backend>
   org.freedesktop.impl.portal.FileChooser=gtfilepicker
   ```

4. Restart the portal: `systemctl --user restart xdg-desktop-portal`.

The picker's window is not yet made a child of the asking program's window.

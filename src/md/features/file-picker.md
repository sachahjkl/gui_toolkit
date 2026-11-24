# The file picker: intent

The picker's own behaviour (sources, readings, rows, rename, trash) is in [file-browser.md](file-browser.md). This file
keeps the layers: how one picker serves a program's layout, the toolkit's dialog and any other program on the desktop.
What a programmer calls is in [docs/file-browser.md](../../../docs/file-browser.md) and
[apps/file-picker/README.md](../../../apps/file-picker/README.md).

## Purpose

A program asks for a file in three ways. It shows a dialog and waits for one answer. It shows a picker in its own
layout: a side panel, an "Open" page, a docked view. Or it is another program, maybe not built on the toolkit, that
asks the person to choose a file. One picker serves the three, with the same look, keys and sources.

## The layers

1. **The source** (`ui.File_Source`): where the files are. The computer's (`local_files`), a server's, an archive's.
   Calls with replies, never a return value (file-browser.md).
2. **The picker** (`ui.File_Picker`): the component. Its state is its holder's: a field of the program's struct, made by
   `file_picker_init` and freed by `file_picker_destroy`. A call per build, `file_picker(id, &p)`, builds it at the
   size `next` gives and returns what happened (`File_Picker_Events`): the answer (chosen or cancelled), another
   folder, another selection.
3. **The dialog** (`ui.file_dialog`): one call and a `done` callback. A picker the State keeps, shown as the view
   `"file_dialog"`. It adds what a dialog has and a component does not: the view, its modality, its size, `done`
   called once, a second dialog that cancels the first.
4. **The request and the answer as values** (`platform.File_Request`, `platform.Dialog_Result`). What is asked (open,
   save or folder; title, start folder, filters, several files, a suggested name, choices) and what comes back (the
   paths or cancelled, the type line, the choices' values). No procedure, no pointer to a State: a value can cross a
   process boundary.
5. **The hosts outside the toolkit's programs** (`apps/file-picker`, `gt-file-picker`): a program that serves one
   request with the picker in a window of its own. Its command line is the first interface (as zenity's and kdialog's);
   the XDG desktop portal's FileChooser backend is the second (Linux). Both are clients of layer 4, served by layer 2.
   The codecs between the values and their texts are pure procedures of `gt:file_request`.

## Which state lives where

| State | Where | Why |
|---|---|---|
| A picker's folder, history, rows, filter, find, preview, rename, trash undo, thumbnails | `File_Picker`, its holder's | several pickers at once; each has its own |
| The computer's places, read once on the chores | `File_Pickers.local` (`State.files`) | one reading per State for all its pickers |
| The memory per `remember_id` (folder, size, split, sort, hidden files, view, recent folders) | `File_Pickers.memory` | a dialog and a panel with one `remember_id` share it |
| The pickers alive, by id | `File_Pickers.live` | a reply finds its picker, or none when it is destroyed |
| The dialog's picker, `done`, `user`, its view | `File_Pickers.dialog` | one dialog per State |

## Decisions

- **A reply names its picker by id and serial, not by pointer.** `File_Reply.picker` is an id of the State's
  `live` map; `serial` counts the picker's requests (`file_picker_start`). A source may answer after the program
  destroyed its picker: the id is then absent and the answer changes nothing. A pointer in the reply would be freed
  memory. Refused: a counter of references per picker (the program frees its struct when it wants).
- **The events are returned by the build, not called back.** A program that builds the picker reads what happened
  where it builds it, as with every widget of the toolkit. An answer that comes from a reply (a path typed, then its
  folder read) waits in the picker for its next build. The dialog is the exception: it calls `done` at once, as before.
- **A program's picker reads the keyboard only with the focus in it.** A picker in a side panel beside the program's
  editor must not take its Escape, its Backspace or its typed letters. The focus at the end of a build decides for
  the next build (`focus_inside`). When the focused box is gone with the rows (an empty folder, a reading that failed),
  the keys stay the picker's while the window's focus is still that box (`focus_held`): F5 and Backspace must work in
  an empty folder. The dialog holds every key of its window, as before (`overlay_capture_keys`).
- **The dialog is a picker and a view, nothing more.** Its view's build calls `file_picker`. The dialog's answer is
  the picker's (`file_picker_answer`), which tells the dialog (`file_dialog_answered`): the view closes, then
  `done` is called. The picker is kept between dialogs: its thumbnails serve the next one.
- **The request is `platform.File_Dialog` with a kind.** `File_Request` adds no field of its own: the options struct
  stays the one API for the options (file-browser.md, "Refused"). `File_Dialog_Kind` moved to `platform`: a value
  that a host outside the interface reads must not need `ui`. Choices joined `File_Dialog` (`File_Choice`) and
  their values joined `Dialog_Result`: the portal asks them, and a program of the toolkit may ask them too.
- **The menus' ids and the question's instance are the picker's.** Two pickers of one window build their own view
  menu, row menu and overwrite question.

## The standalone program

`gt-file-picker` serves one request and exits.

- **Its window is the picker.** A window of its own (`host`), the picker filling it, the request's title as the
  window's. No dialog over an empty window.
- **The command line.** `gt-file-picker open|save|folder [options]`, or `--json` with the request on stdin. The
  answer goes to stdout: one path per line, or a JSON object with `--json`. The exit code says what happened: 0
  chosen, 1 cancelled, 2 an error (a request that does not read, no window). Refused: a code per kind of error (a
  caller acts on three outcomes).
- **The XDG portal's FileChooser backend** (`--portal`, Linux). The program owns
  `org.freedesktop.impl.portal.desktop.gtfilepicker` and serves `OpenFile`, `SaveFile` and `SaveFiles` at
  `/org/freedesktop/portal/desktop`. The person's `portals.conf` routes `org.freedesktop.impl.portal.FileChooser` to
  `gtfilepicker`; their desktop's own backend keeps the other interfaces.
- **Each portal request is a process of its own.** The server is a D-Bus adapter: it turns the call into a
  `File_Request`, runs `gt-file-picker --json` with it on stdin, reads the answer on its stdout, and replies.
  Reasons: the server's thread drives the bus and never a window (a connection has one thread, dbus.md); a crash of
  one picker ends one request, not the service; the server is the same code path as the command line. `Close` on the
  request's object ends its process and answers "cancelled". Refused: windows in the server's process (a second loop
  beside the bus's, and a crash takes every request with it).
- **Its look: Ember, light or dark as the desktop is.** A picker that other programs call has no settings of its own:
  it shows the toolkit's Ember theme, in the version the desktop asks (the appearance portal on Linux, the system's
  setting on Windows), and follows a change while it is open. `--theme NAME[:light|dark|system]` lets a caller keep
  its own look. Refused: a settings file of the picker (a person would set it in one more place), the caller's theme
  through the portal (the portal does not carry it).
- **The parent window is not followed yet.** The portal gives the caller's window (`x11:<id>`, `wayland:<handle>`).
  Making the picker's window a child of it needs `xdg-foreign` on Wayland and `WM_TRANSIENT_FOR` on X11 in the
  platform layer: a later work (ROADMAP.md).
- **MIME filters are matched by extension.** The portal gives a filter as glob or MIME patterns. The picker matches
  names, so a MIME pattern becomes the extensions of a small table (`image/png`: `*.png`); an unknown MIME type takes
  every file of that filter. Refused: reading each file's content to know its type (a read per entry).

## Refused

- One browser per State (the old design): a program could not put a picker in its own layout, and two could not live.
- A callback per event of the embedded picker: the build already returns.
- A ui-level request struct: `platform.File_Dialog` is the request.
- The portal served in the program's own process by each program of the toolkit: the person chooses one picker for
  the desktop, in `portals.conf`, not one per program.

## Subtle points

- A program's picker must be destroyed before `ui.destroy` of its State. If not, `ui.destroy` stops it and forgets
  its id; `file_picker_destroy` then frees only its memory.
- The picker's address must not change between `file_picker_init` and `file_picker_destroy`: the State keeps it.
- The answer of a program's picker is said once, by the next build. A build that is skipped keeps it.
- After an answer, a program's picker stays open: the program decides to hide it, to stop it, or to ask again.

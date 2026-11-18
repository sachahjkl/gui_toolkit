---
name: gui-toolkit
description: Build or change a program in Odin on gui_toolkit, the immediate-mode GUI toolkit (papier, classeur, inspecteur, cliche, atelier, opencode native, Wren, or a new program with gui_toolkit as its ext/gui_toolkit submodule). Use this skill whenever Odin code imports `gt:` packages (`import "gt:ui"`, `gt:host`, `gt:platform`, `gt:testkit/session`), builds with `-collection:gt=...`, or touches `ui.` immediate-mode widgets, `host.Host`, `ui.task` or `ui.post`, `prefs_page`, the standard settings, `ui.vlist` and tables, views, dialogs and panels, the command palette, commands and keys, themes, a program's tool (`toolbox.Project`), its changelog fragments, or a headless test of its interface.
---

# A program on gui_toolkit

gui_toolkit is an immediate-mode interface in Odin, over its own platform layer, renderer and text. A program
builds its widgets in a procedure that runs at each frame. The toolkit keeps the state of the widgets between frames
(hover, focus, scroll, animation) by their ids.

This file gives the rules that a program must follow, and where each subject is documented. It copies no
documentation: read the reference before you write code in its subject.

## Read first

- `references/getting-started.md`: a new program, the `-define:` choices, where state lives, the pitfalls.
- `references/tasks.md` and `references/post.md`: work off the interface's thread.
- `references/testing.md`: the tests of an interface.

## The method

1. Find the subject in the table "Where each subject is", and read its reference.
2. Find how another part of the toolkit or another program does it. Reuse a part before you write one.
3. Write the code. Keep the state in the program's structs (see "Where state lives").
4. Write its test with `gt:testkit/session`.
5. Write a changelog fragment for a change the user can see.

## The collection

A program has the toolkit as its submodule `ext/gui_toolkit`. It imports the packages through the collection `gt`:

```odin
import "gt:ui"
import host "gt:host"
import "gt:platform"
```

```
odin build app -collection:gt=ext/gui_toolkit/src -vet -out:build/myapp
```

- Never import the toolkit by a relative path (`"../ext/gui_toolkit/src/ui"`). The collection is the one form.
- Some packages have another name than their folder (`gt:host` is `tk_host`, `gt:base` is `gt_base`). Import them
  with a name: `import host "gt:host"`.
- The output folder must exist before `odin build`: the compiler does not make it.
- A program builds with its own tool (`odin run tools/<tool> -- build`), made of `toolbox` commands. See
  `references/toolbox.md`, "A project's tool".

## Where state lives

- What belongs to one window or one program lives in its struct: `platform.Window`, `render.Renderer`, `ui.State`,
  and the program's `App`. Never in a global.
- A global of the toolkit is one of four classes: `const`, `process`, `thread`, `test`. The toolkit lists each one
  with its class, and a test fails on a global that is not listed. A program follows the same rule.
- Each window has its own `ui.State`. The renderer and the fonts are shared between the windows of a program.
- A widget is found again by its id. `"Label"` alone uses the text as the id. Write `"Text###stable_id"` for a text
  that changes, or two widgets with one text collide.

Why: several programs run in one process in the tests, each on a thread of its own. A global breaks that.

## Never block the interface's thread

The interface's thread makes no system call: no file read or written, not even a `stat`, no process, no network, no
D-Bus call that waits. Any of them can take a second, and the window freezes for it.

- Do such work with `ui.task(s, work, done, data, lost)`: `work` runs on the chores, `done` runs on the interface's
  thread at its next build. `lost` frees the data when the State is gone first.
- A thread of the program that has a result calls `ui.post(s, fn, data, word)`. The call runs at the start of the
  next build.
- Do no work in proportion to the data in a frame: no sort, no full filter, no pass over every row. Compute it when
  the data changes, off the interface's thread, and keep it.
- A program's tests count the calls that block in a frame (`TOOLKIT_BLOCKING_CHECK`), and a test fails for any.

## The heap for data that crosses threads

The data of a task or a post is the caller's until `done` or `lost` runs. Allocate it on the heap
(`new_clone`, `strings.clone` with the heap, `runtime.heap_allocator()`).

Never use `context.temp_allocator` for it: the frame frees it at its end (`free_all`), while the chore still reads
it. The same holds for a string you give to a widget that keeps it after the frame.

Free a block with the allocator that gave it. A procedure that allocates for another thread sets
`context.allocator = runtime.heap_allocator()` first, because its caller's allocator is not always the heap: in a test
it is the test runner's, and a free on the heap of a block from there crashes, on Windows first.

## Where each subject is

Each row names the reference to read. The list follows the toolkit's documentation menu.

| Need | Read |
|---|---|
| A new program, the build choices, the pitfalls | `references/getting-started.md` |
| What each part costs in the executable | `references/builds.md` |
| Buttons, numbers, fields, sliders | `references/widgets.md` |
| Themes and finishes | `references/themes.md` |
| Text, fonts, a text's backend | `references/text.md` |
| Drawing your own boxes | `references/draw.md` |
| Menus | `references/menus.md` |
| Dialogs, panels, floating windows (views) | `references/views.md` |
| Commands and their keys | `references/commands.md` |
| The command palette | `references/palette.md` |
| Lists, `ui.vlist`, tables, graphs, meters | `references/data-views.md` |
| Find in a view | `references/find.md` |
| Splitters and panes, docking | `references/panes.md`, `references/docking.md` |
| Strips of tabs or choices | `references/strip.md` |
| The scroll bar and its marks | `references/scroll-bar.md`, `references/scroll-marks.md` |
| Undo and redo | `references/undo.md` |
| Markdown in a window | `references/markdown.md` |
| Drag and drop | `references/dragdrop.md` |
| Accessibility and screen readers | `references/accessibility.md` |
| The texts in the user's language | `references/i18n.md` |
| The platform's windows, folders, events | `references/platform.md` |
| The clipboard | `references/clipboard.md` |
| The system's file dialogs, the file browser | `references/dialogs.md`, `references/file-browser.md` |
| System notifications, the tray | `references/notifications.md`, `references/tray.md` |
| Files without waits, zip and tar | `references/fsx.md`, `references/archive.md` |
| HTTP requests | `references/http.md` |
| Preferences, small files of keys | `references/config.md`, `references/store.md` |
| The settings page | `references/prefs_page.md` |
| The common settings of every program | `references/settings.md` |
| The log, crash reports, the crash bar | `references/log.md`, `references/crash.md`, `references/crash_bar.md` |
| The command line | `references/cli.md` |
| One running copy | `references/instance.md` |
| Install, updates, licences | `references/setup.md`, `references/update.md`, `references/licence.md` |
| The program on the desktop | `references/desktop.md` |
| Plugins in JavaScript | `references/plugins.md` |
| Frames, pacing, the frame gate | `references/pacing.md`, `references/frame_gate.md` |
| Calls from other threads | `references/post.md` |
| Work off the interface's thread | `references/tasks.md` |
| Locks, arenas | `references/locks.md`, `references/arena.md` |
| Tests | `references/testing.md`, `references/testkit.md` |
| The devtools endpoint, driving a window | `references/devtools.md`, `references/cdp.md` |
| A program's tool, its site, its release | `references/toolbox.md`, `references/site.md`, `references/release.md` |
| Changelog fragments | `references/changelog.md` |

A package that this table does not name has its page in the toolkit's `docs/` folder, or on
<https://gt.sacha.house/docs/>.

## Tests

A test of an interface is an `@(test)` procedure that drives the program with `gt:testkit/session`:

- **Headless.** The window is offscreen and input goes through the event path. No window opens on the desktop, and
  the clipboard is the process's own.
- **Waits with a bound.** `session.wait_until`, `wait_box`, `wait_text`, `wait_gone` and `wait_idle` make frames until
  what they wait for holds. Their bound only ends a failing run. Never sleep for a fixed time.
- **The clock is the session's.** `session.advance(s, ms)` moves it: a tooltip's delay or a caret's blink needs no
  wait.
- **`wait_idle` before you click in a dialog that opens.** A dialog fades and moves in for a few frames. A click during
  the animation lands where the button is not yet. `wait_idle` waits for three builds with no animation and no post.
- **A whole program**: `session.attach` drives a program that makes its own window and frames.
- A failure leaves `failure.png` and `failure_tree.txt` in `build/session/<test>/`. Read them first.
- Tests that measure time, or drive real windows, are opt-in.

## Records of a program

- **Changelog.** A change the user can see is one fragment in `changelog.d/`, in the same commit. Never edit
  `CHANGELOG.md`: the release assembles the fragments. The format is in `changelog.d/README.md` of the program, and
  in `references/changelog.md`.
- **Roadmap.** A program keeps its planned work in `ROADMAP.md`, beside `CHANGELOG.md`: `# Roadmap`, then `## Now`,
  `## Next`, `## Later`, each a list, and an optional `## Maybe`. The program's changelog check also checks this file,
  so a program without it fails its check. When a work is done, remove its entry in the commit of its fragment.
- **A need of two programs** goes in the toolkit, generic, with its documentation, its test and its fragment there.
  A program keeps only its own words and layout.

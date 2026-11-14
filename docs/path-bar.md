# The path bar (`src/ui/path_bar.odin`)

A folder's path in one bar: at rest a breadcrumb whose parts a click walks; clicked on its empty part, an address field
with a dropdown of what can come next, searched by fuzzy matching. The file browser has one; any screen that shows a
place in a tree of folders can use it (a server's folders, a project's tree). It knows nothing of files: a path is a
text with a separator, read by the helpers of `file_source.odin` (`file_path_root`, `file_path_parts`, ...).

```
 ┌──────────────────────────────────────────────────────┐
 │ … / Projects / gui_toolkit / docs                    │   at rest: a part's click goes there
 └──────────────────────────────────────────────────────┘
 ┌──────────────────────────────────────────────────────┐
 │ /home/me/Projects/gui_toolkit/do▏                    │   typed: the folder's children, then the program's
 ├──────────────────────────────────────────────────────┤
 │ 📁 docs                                              │
 │ 📁 dotfiles                                          │
 │   Places                                             │
 │ ⌂ /home/me/Documents                       Documents │
 └──────────────────────────────────────────────────────┘
```

## Use

The bar reads nothing itself. Each build the program calls `path_bar` and does what its events ask; it answers what the
bar `wants` when it can, later or at once.

```odin
app.bar: ui.Path_Bar   // the program's; ui.path_bar_destroy(&app.bar) at its end

ui.next({width = ui.fill()})
ev := ui.path_bar("###where", &app.bar, app.folder, {separator = '/', edit_shortcut = "Ctrl+L"})
if p, ok := ev.go.?; ok { go_to(app, p, ev.branch) }
if w, ok := ev.wants.?; ok { ask_children(app, w) }   // later: ui.path_bar_children(&app.bar, w, entries)
if ui.key_press(.L, {.Ctrl}) { ui.path_bar_edit(&app.bar) }
```

- `path_bar(id, &st, path, o) -> Path_Bar_Events`: `path` is the folder shown. Its size is `next`'s (else its parent's
  width and a button's line). `o`: `separator` ('/' or '\\'; 0: '/'), `name` (a screen reader's, "Path" by default),
  `placeholder` (the field's), `edit_shortcut` (the program's key for `path_bar_edit`, told to a screen reader).
- `Path_Bar_Events`: `go` (a path to go to), `branch` (`go` is a folder: a part, or a row given as a branch; false: the
  text typed, or a leaf's row), `open_elsewhere` (a part middle-clicked or clicked with Ctrl), `wants` (the folder whose
  children the dropdown needs). The strings are the frame's.
- `wants` is said once, in the build where the folder typed changes; never again for it. Answer with
  `path_bar_children(&st, folder, entries)` or `path_bar_failed(&st, folder, message)`, in the same build or a later one.
  An answer for another folder than the one wanted now is dropped. The entries are copied.
- `path_bar_suggestions(&st, groups)`: the program's own rows (places, recent folders, a search's answer), under each
  group's title, after the children. Set them when they change, not each frame; they are copied.
- `path_bar_edit(&st)`: the address mode at the next build. `path_bar_editing(&st)`: whether the bar is in it (its field
  has the keyboard, Escape is its own).
- `Path_Bar_Entry`: `name`, `icon` (a Lucide glyph; "": a folder), `detail` (weak, at the row's right), `branch` (it can
  be entered), `path` (a suggestion's whole path; a child's "": the folder joined to its name).

## At rest: the breadcrumb

In an input well, the parts from the root, each a ghost button (a face only under the pointer, pressed while held),
separated by a faint "/" whatever the separator. The root shows as itself ("/", "C:"). The folder shown is in the text's
colour, the parts above it weak. When the parts do not fit (by the last layout's width), the leading ones go into a
"…" button, its menu (`menu`) listing them, the deepest first. A part's tooltip is its whole path.

## Typed: the address and its dropdown

A click on the bar's empty part (after the last part, or its padding), or `path_bar_edit`, turns the well into a field
holding the whole path, selected: the same well, nothing moves. Under it a popover as wide as the bar lists:

- the children of the folder typed (the text up to its last separator; a relative text from `path`), ranked by
  `fuzzy_score` against what follows that separator, the matched letters lit; nothing after it: all, in their order;
- then each group of suggestions, under its title, ranked against the whole text;
- at first, while the path is as it came (selected: what is typed replaces it), nothing filters: the children of the
  folder shown and every suggestion;
- at most `PATH_BAR_SHOWN_MAX` rows a section, then a line that says how many more;
- "Reading…" while the children have not come, after `PATH_BAR_SLOW_MS` (by the State's clock: a fast answer does not
  flash); the program's words when they failed; "Nothing matches" when nothing does.

The rows are `choice_row`s (an icon, the name or a suggestion's path, the detail at its right). They are ranked only
when the text, the children or the suggestions change: a quiet build ranks nothing (`Path_Bar.ranked` counts them).

| Key | |
|---|---|
| ↓ ↑ | the row highlighted (none at first); the dropdown again when it was closed |
| Tab | the text becomes the row highlighted (or the best one: the first); a branch gets its separator, so its children are asked |
| a separator typed | after a child's name: that folder's children |
| Enter | goes to the row highlighted, else to the text typed (a relative one joined to `path`); the breadcrumb again |
| Escape | closes the dropdown; again: the breadcrumb, going nowhere |

A click on a row goes there. A click outside the field, or the keyboard leaving it, gives the breadcrumb back.

For a screen reader: the breadcrumb is a navigation landmark, its parts buttons (the last one the current location),
its empty part a button "Type a path"; the field an editable combo box that controls the dropdown's list box, the
highlighted row its active descendant.

## Tests

`tests/path_bar`: the parts of "/home/a/b" and "C:\x", a part's click, the address mode and its selection, `wants` said
once per folder, a late answer shown and another folder's dropped, the fuzzy ranking and its lit letters, Tab, Enter on
a row, Escape twice, the suggestions under their titles, the "…" of a narrow bar.

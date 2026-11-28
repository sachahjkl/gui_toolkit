# The tree view and the file tree

`ui.tree` shows a hierarchy as rows of one line, as a code editor's explorer does: an indent per level, indent
guides, a chevron that turns, an icon, the label cut at its end, a slot at the end of the row. Only the rows in view are
built: a tree of 100 000 open nodes builds as fast as one of ten. `ui.file_tree` is a tree of a folder on disk made on
it. Their design: [src/md/features/tree-view.md](../src/md/features/tree-view.md).

## A tree of the program's

The program gives the rows shown, in order (a closed branch's children are not in them), and counts its changes. The
open set is the tree's: when `open_version` moves, the program makes its rows again.

```odin
App :: struct {
	tree:    ui.Tree,
	rows:    [dynamic]ui.Tree_Row,
	version: u64,   // the rows' changes
	seen:    u64,   // the open_version the rows were made for
}

if app.version == 0 || app.seen != app.tree.open_version {
	rows_make(app)   // a pass over the nodes shown: ui.tree_is_open(&app.tree, id) says which branches go down
	app.version += 1
	app.seen = app.tree.open_version
}
ui.next({width = ui.px(280), height = ui.fill()})
if shown, ok := ui.tree("###outline", &app.tree, app.rows[:], app.version); ok {
	for i in shown.first ..< shown.last {
		row := ui.tree_row(&app.tree, i, {trailing = "3", trailing_tag = "weak"})
		if ui.parent(row.box) { ... }   // more at the row's end
	}
}
if app.tree.chosen >= 0 { open(app.rows[app.tree.chosen]) }
if app.tree.menu >= 0 { menu_open(app.tree.menu_at) }
```

- `Tree_Row`: `id` (stable: the selection, the open set and the cursor follow it), `depth` (0 at the top), `label`, `icon`
  (a glyph of Lucide's font; "": no icon cell), `branch` (a chevron).
- `Tree_Row_Options`: the label's `tag` (`"bright"`, `"weak"`), `icon_tint`, a short `trailing` text and its
  `trailing_tag` (a git letter in `"warn"`). The trailing text takes its own width; the label takes the rest of the row.
- `version` 0 makes the derived arrays at every build (a pass over the rows): give a count.
- `tree.multi = true`: several rows with Ctrl and Shift (`ui.list_selected_ids(&tree.list)`).
- `tree.highlight`: what the labels light where it matches (a filter's words).

## What the tree tells

Read after the rows are built; the next call clears them.

| Field | When |
| --- | --- |
| `chosen`, `chosen_double` | a leaf clicked, or Enter or Space on it |
| `menu`, `menu_at`, `menu_keyboard` | a right click, Shift+F10 or the Menu key |
| `rename_asked` | F2: call `ui.tree_rename_begin(&tree, id, name)` to put a field in its label; `renamed` holds the text at Enter |
| `drag_rows` | a press on a row moved past the drag threshold: the rows selected, or the row pressed |
| `drop_row`, `drop_over` | while a drag of rows is held: the branch under the pointer (-1: the top level) |
| `dropped` | the drag was let go over the tree (`drop_row` says where) |

While a drag of rows is active, a non-clickable floating preview pill follows the pointer (showing the dragged item's
icon, label, and a `+N` count badge for multi-item drags) while hovered drop-target folders highlight with an accent
fill and border. Escape cancels the drag; a drag that rests on a closed branch for `TREE_HOVER_OPEN_MS` opens it. A
drop from another program: `ui.tree_drop_target(&tree, pos)` gives the branch under a position.

## Keys

Up, Down, Page Up, Page Down, Home, End and type-ahead are the list's (`ui.vlist`). Right opens a branch, then goes
to its first child; Left closes it, then goes to the parent. Enter and Space open or close a branch and choose a leaf.

## Other calls

- `ui.tree_set_open(&tree, id, open)`, `ui.tree_is_open(&tree, id)`.
- `ui.tree_reveal(&tree, id)`: selects the row and brings it into view once it is in the rows (open its ancestors
  first).
- `ui.tree_row_height()`: one line, the person's density (a dense scope: a dense row).
- `ui.tree_destroy(&tree)`.

## The file tree

```odin
ui.file_tree_set_root(&app.files, "/home/a/project")
ui.file_tree_set_open_file(&app.files, current_path)
if shown, ok := ui.file_tree("###files", &app.files); ok {
	for i in shown.first ..< shown.last { ui.file_tree_row(&app.files, i) }
}
if app.files.chosen >= 0 { open(ui.file_tree_path(&app.files, app.files.chosen)) }
```

- Each folder is read when it is first shown open, on the chores, folders first then in natural order
  (`ascii.compare_natural`). The open folders are watched and read again when they change.
- `file_tree_set_hidden` shows the hidden entries. `file_tree_reveal(&t, path)` opens the folders to a path, reads
  them, then selects its row. `file_tree_entry(&t, i)` is a row's entry; `file_tree_path(&t, i)` its path.
- `ui.file_icon(name, folder, open, link)`: the Lucide icon of a file by its type.
- `ui.file_tree_destroy(&t)`: a reading or a change that comes after it changes nothing.

### The filter

Ctrl+F on the tree opens a field over it (`File_Tree.type_filters`: typing opens it with what is typed; else typing
jumps to a name). Its words find names in the whole folder, read or not, on the chores: the matches and the folders on
their way are the rows, those folders open, the letters lit, a count inside the field's end ("Searching…" while it
walks).
Hidden entries are left out unless `hidden`; in a git repository, what its `.gitignore` files ignore is left out
unless `gitignored`. Escape empties it and gives the open folders of before back. `ui.file_tree_filter_open(&t, text)`
and `ui.file_tree_filter_close(&t)` do the same from the program.

### The menu, the keys, the palette

A right click on rows (or under them), the Menu key or Shift+F10 opens the menu of the rows selected: New file, New
folder, Show in the file manager, Open with, Open in a terminal, Duplicate, Cut, Copy, Paste, Copy path, Copy relative
path, Rename (F2, in its row), Move to the trash (Delete, undone from its toast or `ui.file_tree_undo(&t)`), Expand all
here, Collapse all, Refresh (F5). Every operation on the disk runs on the chores; a failure is a toast with each
entry's reason.

- A rename never replaces another entry; a change of case only is the entry itself on a disk that ignores case, and
  another file on one that does not (`fsx.same_entry`). A name the system refuses is said before anything is tried:
  `ui.file_name_problem(name, windows)` gives the rule it breaks (an empty name, `.` and `..`, a separator, a control
  character; on Windows `< > : " | ? *`, a dot or a space at its end, a device's name such as `CON` or `nul.txt`).
- A move to another volume is a copy, then the original removed; a move refused for another reason (a folder that
  cannot be written) copies nothing. A copy that fails removes what it made; a link is copied as a link.
- A duplicate is "<name> copy.<ext>", then "… copy 2"; a folder's name has no extension ("v1.2 copy").

```odin
// the program's acts, after the toolkit's
app.files.actions = app.file_actions[:]   // []ui.File_Tree_Action{{label = "Open in a tab", icon = lucide.PANEL_TOP, act = open_tabs, user = app}}
app.files.acts_off = {.Terminal}          // the toolkit's acts left out

// the palette: the same commands, their keys the person's
ui.palette_commands(&palette, ui.file_tree_commands(), nil)
if id, ok := chosen_command(); ok { ui.file_tree_command_run(&app.files, id) }
```

### Drags

A row dragged onto a folder moves its file there (Ctrl: copies). Out of the window, it is the system's drag of the
files. Another program's files dropped on the tree go into the folder under the pointer (copied; Shift moves);
`File_Tree.no_system_drops` leaves the window's drops to the program.

## fsx.Ignore

`fsx.ignore_add(&rules, base, text)` adds a `.gitignore`'s rules (its folder `base` relative to the repository's top);
`fsx.ignore_match(&rules, rel, folder)` says whether a path is ignored; `fsx.glob_match` is its glob (`*`, `?`, `[...]`,
`**`).

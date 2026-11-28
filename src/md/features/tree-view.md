# Tree view and file tree

`ui.tree` shows a hierarchy as rows of one line: a folder tree, an outline, a scene graph, an inspector's nodes.
`ui.file_tree` is a tree of a folder on disk, built on it. The bar is a code editor's explorer: dense, aligned, no
room spent on nothing, 100 000 nodes as fast as 10.

## Why a widget of its own

plume built its side tree by hand on `ui.vlist` and called `ui.space(em * 0.8 * depth + em * 0.4)`. `ui.space` takes
steps of the spacing scale in em, not pixels: each level moved its row by about six em, and the names went off to the
right, cut. Every program that shows a hierarchy (plume, classeur, galerie, Wren, Tower) wrote or will write the same
row: an indent, a chevron, an icon, a name, a mark at the end. One widget makes the geometry right once.

## The model is the program's: a flat list of the visible rows

The program gives the rows shown, in order: each row its identity, its depth, its label, its icon and whether it is a
branch (`Tree_Row`). A collapsed branch's children are not in the list. This is the only shape that is virtual for
free: `ui.vlist` builds the rows in view of a list of any length, and a tree of 100 000 open nodes is a list of
100 000 rows.

- The rows change only when the data or the open set changes. The program counts those changes (`version`); the
  tree compares nothing per build. On a new version the tree makes its derived arrays in one pass (each row's parent,
  the end of its subtree, its place among its siblings and their count): the same cost as `vlist`'s placement of new
  ids, on the interface's thread, on a change, never per frame.
- The open set is the tree's (`Tree.open`, by identity): the keys, a click and a reveal change it, and its
  `open_version` tells the program to make its rows again. The chevron reads that set.
- Refused: a tree of nodes the widget walks (a callback per child, a node struct). It walks the whole tree to know
  where row 50 000 is, or keeps the flat list anyway. Refused: the flat list made on a chore. It needs a snapshot of the
  program's model (a copy as large as the rows) and shows the old rows for a frame after each click; the pass is cheap
  enough to make where the change happens.

## Geometry

A row at depth `d`: `TREE_EDGE_EM`, then `d * TREE_INDENT_EM`, then the chevron's cell (`TREE_CHEVRON_EM`), the icon's
cell (`TREE_ICON_EM`), the label filling what is left, then what the program adds at the end. Every size is a pixel
size made from the font's em, never a step of the spacing scale (`ui.space` takes steps). A leaf keeps an empty
chevron cell: the icons of a folder and of a file of one level line up.

- The indent is 0.62 em, a code editor's explorer's (8 pixels at 13): a child's chevron sits under its parent's
  icon, the guide under its parent's chevron; depth 10 still leaves two thirds of a 20 em panel to the name. 0.85 em
  was tried first: the names drifted right a third faster than in the explorer people compare it with.
- The row is one line: `TREE_ROW_EM` (1.65 em; the explorer's is 22 pixels at 13, 1.69 em) in the person's density,
  or a dense row in a dense scope.
- A trailing text (a git letter) takes its own width, no padding: the label's end padding is the gap, and the label
  takes the rest of the row. A padded slot cut names that had room.
- The label is cut at its end with an ellipsis, never moved; the whole name shows in a tooltip while the pointer
  rests on a cut row (`table_cell_tip`), and a click on the ellipsis opens it (text-reveal.md).

## Indent guides and the chevron

The guides and the chevron are drawn by the row's custom draw, not built as boxes: a row at depth 6 would build six
boxes for six lines. Each row draws a vertical hairline for each level above it, under the centre of that level's
chevron; the rows one under the other make continuous lines. The guide of the active branch (the cursor's open branch,
else the cursor's parent) is drawn in a stronger ink over the rows of that branch: the eye finds the siblings of the
row it is on.

The chevron is two strokes that turn from right to down (`anim`, a quarter turn). A glyph cannot turn: a box draws its
text upright.

## Keys and pointer

The list is `ui.vlist`'s: Up, Down, Page Up, Page Down, Home, End, type-ahead on the labels, Ctrl and Shift to select
several rows (`Item_Selection`). The tree adds the keys of every tree view (the WAI-ARIA tree pattern):

- Right: a closed branch opens; an open branch goes to its first child.
- Left: an open branch closes; another row goes to its parent.
- Enter and Space: a branch opens or closes; a leaf is chosen (`Tree.chosen`). Space while type-ahead is in progress
  is a letter of it.
- F2 asks for a rename (`rename_asked`); Shift+F10 and the Menu key ask for the context menu (`menu`).

A click on a row selects it (`list_row`, at the press) and, at the release with no modifier, opens or closes a branch
or chooses a leaf. The second click of a double click does not toggle the branch back. A right click selects the row
(or keeps the selection it is in) and asks for the menu at the pointer.

The cursor follows its row by identity: when the rows change above it, `sel` moves with its row. vlist's cursor is an
index, and a tree's rows move under it at each open.

## Reveal

`tree_reveal(t, id)` selects a row and scrolls it into view once it is in the rows. The tree does not know a row's
ancestors: the program opens them (`tree_set_open`) and its next rows hold the row. A reveal waits across versions
until the row comes or another reveal replaces it.

## Accessibility

The list is a `Tree` node, each row a `Tree_Item` with its level, its place among its siblings and their count, its
expanded state (a branch) and its selection. vlist builds only the rows in view; the counts come from the derived
arrays, so a screen reader reads "3 of 7, level 2" for a row whatever is built.

## Hooks the program answers

The tree says what was asked; the program does it with its own data and words:

- `chosen`: a leaf chosen (open the file).
- `menu`, `menu_at`: a context menu for the selection.
- `rename_asked`: F2 on a row. `tree_rename_begin(t, id, text)` puts a field in that row's label; `renamed` holds the
  text at Enter; Escape or a click elsewhere ends it with nothing.
- Drag and drop: `drag_rows` once a press moved past the drag threshold (the rows selected, or the row pressed);
  while it is held, `drop_row` is the branch under the pointer (a leaf's parent), opened after `TREE_HOVER_OPEN_MS`,
  a floating drag preview pill (`###tree_drag_preview`) follows the pointer on the root overlay layer (non-clickable,
  raised above panels and views so it never steals hits; icon + label + `+N` count badge for multi-item drags), and
  the hovered drop target folder gets an accent tint and border (root drops outline the tree). Escape cancels an active
  drag cleanly; releasing sets `dropped` when over the tree. The program starts the system's drag when the pointer
  leaves the window (`platform.drag_start`), and gives the system's drops to `tree_drop_hover`.

## The file tree

`ui.file_tree` is a `Tree` whose rows it makes from a folder on disk.

- Each folder is listed when it is first shown open, on the chores (`ui.task`, `fsx.read_folder`), and sorted there:
  folders first, then by `ascii.compare_natural`. The interface's thread makes no system call.
- A row's identity is a hash of its folder's identity and its name: no path is joined per row. A path is joined only
  for a row the person acts on and for the open folders.
- Hidden entries (the system's mark, a name that starts with ".") are left out unless `hidden` is on.
- The icon is the file's type (`file_icon`: about fifty extensions on Lucide's file icons); a folder's is open or
  closed with its row.
- The open folders are watched (`fsx.Watch`, one waiting thread per file tree, started with the first reading). A
  change reads the folder again; its rows are made again when the listing comes, the cursor kept by identity.
- `file_tree_reveal(t, path)` opens each folder from the root to the path, reads those not read yet, then reveals the
  row.
- `open_file` is marked: its label in the bright ink and a dot at the end of its row.
- Its rows select several (`multi`): the acts and the drags take them all.

The answers of the chores and of the watching thread come back through a link the tree and each piece of work hold
(counted): a tree destroyed before an answer leaves the answer nothing to change. A folder read for an earlier root
(`file_tree_set_root` since) is dropped by its generation.

Refused: the file picker's source (`File_Source`). Its replies go to pickers by id, through the picker's tickets and
dialogs; a tree has neither, and the computer's files are the only ones a tree needs today. When a tree needs a
server's files, the source's replies become a procedure per asker.

## The file tree's filter

A field over the tree (Ctrl+F; typing when `type_filters` is on, else typing is the list's type-ahead) finds names in
the whole folder, read or not: a filter over the rows already read would miss what is in a closed folder, which is what
a person looks for.

- The search walks the folder on the chores, folders by folders, and stops at `FILE_TREE_FIND_MAX_VISITS` entries or
  `FILE_TREE_FIND_MAX_MATCHES` matches (then the count says more are not shown). Each new text starts a search with a
  new serial; the walk reads the serial between folders and stops when it is not its own.
- What it found comes in batches (every `FILE_TREE_FIND_BATCH_MS` while it walks): the count and the rows grow; the
  field says "Searching…" until the end. The count is inside the field's end (`Line_Edit_Options.suffix`), so the field
  takes the row: a count beside it left the text a third of a narrow panel.
- `fsx.glob_match` is a pass per part of the pattern over the name's prefixes, never a backtrack per star: a
  repository's `.gitignore` is not the program's, and "*a*a*a*a*a*a*b" against a long name would stop the walk, which
  reads its stop only between folders.
- It leaves out hidden entries unless the tree shows them, links to folders (no cycle), `.git`, and in a repository
  what its `.gitignore` files ignore (`fsx.Ignore`: the files from the repository's top down to each folder walked),
  unless `gitignored`. A folder ignored is not entered.
- The match is the palette's (`fuzzy_words`) on the name, or on the relative path when the text has a separator. The
  letters matched are lit in the rows (`Tree.fuzzy`).
- The rows are then made from the matches: each match in its folder, the folders on its way, with the same row
  identities as the folders' own rows (a hash of the names from the root), so the cursor and the selection keep their
  meaning. The folders on the way open once; a folder the person closes stays closed for the next batches.
- The open set before the filter is put aside and given back when the field is emptied or closed (Escape): the filter
  changes nothing of the tree the person left.

Refused: a filter of the rows read only (it finds nothing in a closed folder); an index of the folder kept by the tree
(a watch of every subfolder; `gt:filesearch` is that index, for a program that wants it).

## The file tree's acts

The menu (a right click on rows or under them, the Menu key, Shift+F10) and the keys (`file_tree_commands`, the same
table a program gives its palette) act on the rows selected, else the cursor's row, else the tree's folder:

| Act | Key | What it does |
| --- | --- | --- |
| New file, New folder | | made in the folder acted on under a free name, then its name edited in its row |
| Rename | F2 | the name edited in place; refused over another entry: `fsx.same_entry` tells a case change on a disk that ignores case (the entry itself) from another file on one that does not; a name the system refuses or changes (`file_name_problem`: Windows' rules are checked from any system) is said before anything is tried |
| Duplicate | | "<name> copy.<ext>", "… copy 2" |
| Move to the trash | Delete | the system's trash (`platform.move_to_trash`); its toast puts them back (`put_back`) |
| Cut, Copy, Paste | Ctrl+X, C, V | the system's clipboard of files (a file manager's); a paste copies, or moves what was cut |
| Copy path, Copy relative path | Shift+Alt+C, Ctrl+Shift+Alt+C | the paths, one per line |
| Show in the file manager | Shift+Alt+R | `open(path, .Reveal)` |
| Open with | | the programs of the file (`Open_With`, read when the menu opens) |
| Open in a terminal | | `desktop.open_terminal` |
| Expand all here, Collapse all, Refresh | F5 for Refresh | Expand opens the folders under it as they are read, at most `FILE_TREE_EXPAND_MAX` |

- Every operation runs on the chores. A failure is a toast that names each entry and its reason (the system's words,
  or the tree's, worded on the interface's thread in the person's language); nothing fails in silence.
- A move falls back to a copy and a removal only when the two folders are on two volumes (`fsx.same_volume`): a rename
  refused for another reason (the folder cannot be written) would else leave a copy and an original. A copy is the
  tree's own walk: a link is copied as a link (one to a folder above would copy without end), and what a failed copy
  made is removed.
- A move of a folder onto its own row (a drag that came back) does nothing and says nothing; a copy into itself is
  refused.
- Refused for now: progress and a stop for a long copy or move (`ROADMAP.md`): the operation runs whole on a chore.
- The folders an operation touched are read again at once; the watch would tell them a little later.
- What an operation made is revealed; New's entry gets its name edited.
- A trash's toast holds the trash's serial, not a pointer: its click finds its tree among the State's file trees, and
  an older toast, or one of a tree gone, finds nothing.
- The program's acts (`File_Tree.actions`) come after the toolkit's, with the paths acted on; `acts_off` leaves some of
  the toolkit's out.

## The file tree's drags

- A drag of rows onto a folder row moves them there, Ctrl copies. The folder a drag rests on opens.
- A drag that leaves the window becomes the system's drag of the files (`platform.drag_start`): a file manager takes
  them; a move there reads their folders again.
- Another program's files dragged over the tree go into the folder under the pointer (`build_events`: Drop_Enter,
  Drop_Over, Drop), copied, or moved with Shift (`drop_effect_for`). `no_system_drops` leaves the window's drops to
  the program.


## Subtleties

- A folder marked to be read again (a change told, an operation, F5) sets `dirty_any`; the pass over the folders runs
  after a mark, not at every build. A folder told changed while it is being read keeps its mark and is read again after.
- A folder that could not be read (removed while open) is read again when its parent's listing comes: a build folder
  removed and made again shows its entries and is followed again (the watch of a removed folder is forgotten,
  `IN_IGNORED`).
- One waiting thread and one system watch per file tree: a program with many trees spends an inotify instance each
  (128 per user by default) and, on Windows, 63 folders each at most. A tree the system refuses a watch is read again
  only when the person asks (F5).
- The labels are slices of the program's strings: valid while its rows are. The file tree makes its rows again in
  the build where a listing replaces another, before any row is built.
- A selected row's guides and chevron take the row's ink: they stay visible on the accent.
- A click toggles a branch at its release; the selection is made at the press: a drag from a folder does not open it.

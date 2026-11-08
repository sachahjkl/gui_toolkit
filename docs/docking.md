# Docking (`src/ui/dock_model.odin`, `src/ui/docking.odin`)

Panels the user rearranges, as in an IDE: stacks of tabs side by side or one above the other, split, joined, floated over
the window and docked back by dragging their tabs. The app owns the layout as flat data (a `ui.Dock`), builds its panels'
content as usual, and saves the layout as one line of text.

```odin
Panel :: enum u32 { Files = 1, Editor, Console }

app.dock: ui.Dock
ui.dock_init(&app.dock)
if !ui.dock_parse(&app.dock, saved_text, panel_of, app) { ui.dock_parse(&app.dock, DEFAULT_LAYOUT, panel_of, app) }
for p in Panel { ui.dock_add(&app.dock, u32(p), ui.dock_with(&app.dock, u32(Panel.Editor))) }   // the panels the text did not name

// each frame
ui.next({width = ui.fill(), height = ui.fill()})
ui.dock_begin(&app.dock, "###dock", {title = panel_title, on_save = save_layout, user = app, close_buttons = true})
if ui.dock_panel(&app.dock, u32(Panel.Files)) { files_view(app) }
if ui.dock_panel(&app.dock, u32(Panel.Editor)) { editor_view(app) }
if ui.dock_panel(&app.dock, u32(Panel.Console)) { console_view(app) }
ui.dock_end(&app.dock)
```

`dock_panel` is true while the panel is shown (the tab on top of its stack, the stack not folded away): the block builds
its content in the stack's room, the box of that panel wherever it is docked (its content keeps its state, scroll and
focus when it moves). `dock_panel_size` is that room in this frame's layout, before the layout runs. Like `parent`, it
lets the box go at the end of the statement it is in: `if ui.dock_panel(d, p) { ... }`, not `if !ui.dock_panel(d, p) { continue }`
(that one lets it go before the content is built, which then lands in the dock space's parent).

## The model

A `Dock` is a tree of nodes in one array (`nodes`, `#soa`), addressed by index:

| Node | Fields |
|---|---|
| leaf | a stack of panels; `active`: the one shown (`DOCK_NO_PANEL`: an empty stack) |
| split | `a` and `b` side by side (`axis` .X) or `a` above `b` (.Y); `ratio`: `a`'s share of the room, the handle aside; `fold`: `b` folded to a strip |

`main` is the root that fills the dock space; `floats` the roots of the floating panels (the topmost last), each at its
`float` place (logical pixels from the space's top left). `panels` (`#soa`) holds each panel's id and leaf, in tab order
within each leaf, and `home`: for a floated panel, a panel it was docked with. Panels are the app's ids (`u32`). A
node's `rect` is this frame's layout (`dock_layout` writes it before anything reads it). `serial` counts the changes.

The changes keep the tree well formed: a stack emptied goes and its sibling takes the split's place; the main stack stays,
empty (the dock space is then one drop target).

| Procedure | |
|---|---|
| `dock_init`, `dock_destroy`, `dock_clear` | one empty stack; the arrays freed |
| `dock_add(d, panel, target)` | into the dock when it is not in it (a panel the text did not name, one opened again) |
| `dock_move(d, panel, target)` | to a stack (a tab, `index` along its strip, `-1` its end), a side of one, an edge of the space, floating |
| `dock_float(d, panel, rect)`, `dock_close(d, panel)` | |
| `dock_move_node(d, root, target)` | a floating panel with all its stacks (moved, into a stack, at a side, at an edge) |
| `dock_redock(d, root)`, `dock_home_target` | back where its shown panel came from, else into the main tree's largest stack |
| `dock_activate(d, panel)` | shown in its stack; the folds that hid it open; a floating one comes to the front |
| `dock_set_split(d, split, ratio, fold)` | |
| `dock_with(d, other)`, `dock_beside(d, other, side)` | targets for the app's defaults: with `other`, beside it |
| `dock_has`, `dock_leaf_of`, `dock_tabs`, `dock_shown`, `dock_leaves`, `dock_all_leaves`, `dock_root_of`, `dock_is_floating` | questions |
| `dock_layout(d, size, metrics)` | every `rect` |
| `dock_target_at(d, pos, panel, node, grab)`, `dock_markers`, `dock_edge_markers`, `dock_preview_rect` | the drop targets under a point, their squares, where it would land |
| `dock_format(d, name, user)`, `dock_parse(d, text, id_of, user)` | the text |

A `Dock_Target` is a `place` (`.Tab`, `.Left`, `.Right`, `.Top`, `.Bottom` of the stack `node`; `.Edge_Left` ...
`.Edge_Bottom` of the space; `.Float` at `rect`), with `index` for a tab. A panel dropped at a side of a stack takes half
of it (`DOCK_DROP_SHARE`), at an edge a quarter of the space (`DOCK_EDGE_SHARE`). A panel alone in its stack cannot go
beside itself; a floating panel moved whole cannot go into its own stacks.

### The text

```
dock1 x0.700([*elements,console] y0.500f([styles] [computed])) @40,30,320,200 [network]
```

`dock1` (the version), then the main tree, then each floating root after its place (`@x,y,w,h`, logical pixels). A leaf
is `[names]`, `*` before the shown one; a split is `x` or `y`, the first side's ratio, `f` when the second is folded, its
two nodes in parentheses. Names are the app's (`name` / `id_of`): a name with one of `[]()*,@` or a blank is left out.

`dock_parse` reads it into a new tree and keeps the dock as it was when the text is not one (another version, a bracket
missing, a ratio outside 0..1, a place of no size, more than `DOCK_DEPTH_MAX` splits inside splits, anything after the
end). A name `id_of` does not know (a panel removed since) is dropped, a stack left empty with it goes, and a name given
twice counts once. The panels the text does not name are the app's to place: `dock_add` with a target of its choice.

## The dock space

`dock_begin(d, id, opts)` lays the dock out in the space's room (`opts.size`, else the box's last layout, the window's at
first; `next` sizes the box, `fill` by default), takes the input (a drop, the drag's targets, Escape, Ctrl+Tab, the
corners of floating panels) and builds the strips, the handles and the floating panels' frames. `dock_end` draws the drop
targets while something is dragged, builds the menu, and calls `opts.on_save` when the user is done changing the layout
(not in the middle of a drag); it returns `changed`, `finished`, `dragging` and the panel the user `closed`.
`dock_held(d)` says whether the left button holds one of the dock's own controls (a tab or a floating panel's title,
pressed or dragged, a handle, a floating panel's corner; not what a panel's content holds). It holds no state: it asks the
press, so it ends with it (the release, the box held going, the user leaving the window), and may be asked at any time.

| `Dock_Options` | |
|---|---|
| `title(user, panel)` | a panel's name: its tab, its menus, screen readers |
| `tab(user, Dock_Tab)` | the content of a tab inside `t.box` (width: what it builds); nil: the title |
| `closable(user, panel)` | nil: every panel can be closed |
| `strip_begin`, `strip_end(user, d, leaf)` | boxes at the start of a strip and at its end, before its fold and menu buttons (a toolbar) |
| `strip_last(user, d, leaf)` | boxes after the fold and menu buttons: the strip's last control (a window's close button stays at the far right) |
| `strip_space(user, d, leaf, box)` | the empty part of a docked stack's strip, once built: the app may make it `Clickable` (a handle that moves its own window) |
| `on_save(user, d)` | save the layout (`dock_format`) |
| `labels` | the menus' words (`DOCK_LABELS`) |
| `size`, `tab_height`, `handle` | frame pixels (0: the defaults: `DOCK_TAB_EM`, the splitter's handle) |
| `close_buttons` | a close button on the tabs of the panels that can be closed (on the shown tab and the one under the pointer) |

### What the user does

- **Drag a tab** past `DOCK_DRAG_EM`: the drop targets show over the dock space with a translucent preview of where it
  lands (`dock_preview` in the theme). Five squares over the stack under the pointer (into it, at its left, right, top,
  bottom), four at the edges of the space (an edge of the whole main tree), and the strips: between two tabs, a line
  shows where it goes (also how a tab moves along its own strip). Let go anywhere else, it floats there, as large as its
  stack was (at most `DOCK_FLOAT_DEFAULT_EM`). **Escape** cancels the drag: nothing moves when the button goes up.
- **A floating panel** is an overlay of the dock space with a frame and a shadow (inside the application's window: a
  panel in a window of its own would need a `ui.State` of its own, and the panel's content is built in the app's one).
  The empty part of its strip moves it (the drop targets show: let go over one, it docks there with all its stacks), its
  corner resizes it (at least `DOCK_FLOAT_MIN_EM`), a double click on its strip docks it back. A press on it brings it
  to the front. It stays inside the space.
- **Handles** are `pane_split`'s ([panes.md](panes.md)): each side keeps `DOCK_MIN_EM`; a double click, Enter or a drag
  under half the minimum folds the second side to a strip, a click brings it back; the arrows resize it from the keyboard.
  The stacks of a side that folds have a chevron button at the end of their strip, before the menu's (`pane_toggle`, a
  Tab stop: Enter folds). The strip is in the theme's `pane_strip background` (by default the bars' surface), its hover
  the theme's `hover_fill` over it; its tooltip names the stacks. Showing a panel of a folded side (`dock_activate`) opens it.
- **Close**: the tab's close button, a middle click, the menu.
- **The menu** (the button at the end of a strip, a right click on a tab, the menu key or Shift+F10 on a focused tab):
  the stack's tabs; "Dock <panel> to" every target a drag reaches (each stack: into it, at each side; each edge of the
  space; floating); Float or Dock back; move the tab left or right; Close.
- **The keyboard**: tabs are Tab stops; Left / Right / Home / End show another tab of the strip (and take the focus to it),
  Ctrl+Shift+Left / Right move the tab along the strip, Ctrl+Tab / Ctrl+Shift+Tab (the focus in a stack: a tab or its
  panel) show the stack's next or previous panel. An app whose own shortcuts take Ctrl+Tab (a browser's next tab) calls
  `dock_take_ctrl_tab(d)` before them: the dock has it where it has the focus (`dock_focus_leaf`, `dock_cycle`).

### Accessibility

A strip is a tab list (`.Tab_List`, horizontal) named after its panels, each tab a `.Tab` (selected, position in the set)
that `controls` its panel's body, a `.Tab_Panel` labelled by its tab. Handles are separators (`.Splitter`) named after the
stacks on each side, with their size as a value. A floating panel is a group ("floating panel"). The squares and the
preview are not in the tree: the menu is how a screen reader reaches the targets.

Example: `examples/docking` (`tk build docking`): six panels of an editor, the layout saved next to the program. Tests:
`tests/docking` (the model: split, join, float and back, close, the strip, folds, the layout and the targets under a
point, the text, its round trip, the texts refused; through the test session: a tab dragged onto each target and each
edge, along strips, out and back by a double click, Escape, the keyboard and the menu, a handle, a close button, the
preview's pixels; the folded strip's colours in a dark theme, the fold button by the pointer and the keyboard, the
strip's tooltip sized to its text and inside a tall window).

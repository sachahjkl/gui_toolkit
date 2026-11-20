# Tool bars

One bar API (`ui.toolbar`, `src/ui/toolbar.odin`) for every bar of tools that a window can be too narrow for. The
program declares each tool once. The toolkit shows it in the bar, or elsewhere when the bar has no room for it.

## Purpose

- A bar of tools has more in it than a narrow window holds. Running past the window's edge cuts a tool, and a tool cut
  is a tool lost. The bar must keep every tool reachable at every width.
- Two programs answered this in two ways: cliche wraps its bars onto more lines (a tool hidden is a tool the person
  does not have), and a bar of an application window folds its rare tools into a "…" menu (the bar keeps one line).
  Both are good answers for their place. The program chooses one: `Toolbar_Options.overflow`.
- Each program drew its own separators and its own end buttons. The toolkit gives them: the group's `separator`,
  `ui.toolbar_separator` for a bar a program builds itself, the `pinned` group at the bar's end.

## The model

- **A bar is groups; a group is items.** A group is a block of related items (the tools, the properties, the actions);
  it has a `title` (the menu's section heading), a `priority`, a `separator` before it and `pinned` (the end buttons:
  Cancel, Done). An item is one part a person uses.
- **Two kinds of item.** A **tool** (`toolbar_tool(id, {label, icon, shortcut, command, on, ...})`) is an act: the
  toolkit builds it, a glyph button in the bar (its words with `words = true`), a menu row in the menu (icon, label,
  shortcut, a check when `on`). It returns `true` when clicked, in either place. A **control**
  (`if toolbar_control(id, {label}) { ... }`) is a property with a widget of the program (a slider, colour swatches, a
  toggle): the block builds the widget, in the bar or in the right column of a menu row whose left column is its label.
- **The program never knows where an item is.** The same call runs whichever way the item is shown; a click is the same
  answer. `toolbar_in_menu()` exists only for a widget that sizes itself differently in a row.

## The two modes

- **`.Wrap`.** The bar is as tall as its lines. Each group is one piece of the flow: it goes to the next line whole.
  A group wider than a line wraps its own items, and each item moves whole (a label with its slider, the colours with
  their "another colour" disc). The pinned groups are outside the flow, at the end of the bar's last line: the other
  groups wrap before them, Cancel never leaves Done. This is cliche's hand-built bar (`ui.flow` in a row with the end
  buttons after it), made generic.
- **`.Fold`.** The bar keeps one line. What does not fit folds into the dropdown of a "…" button, the lowest
  priority first, a group's last item first, the group whole once its items are all folded (the measuring and the
  priorities of the bar before this design, unchanged). The "…" button stands before the pinned groups.

## Alignment

- **The groups start at the bar's start by default** (`Toolbar_Align.Start`), as a menu bar's: a program's tools stay
  where the hand learned them whatever the window's width.
- **`.Center` is the program's choice per bar**: an editor's bars over and under a picture (cliche) read as balanced
  around it. In `.Wrap` each line is centred, the last one too (the flow's cross alignment, `layout_wrap_positions`). In
  `.Fold` the groups left in the bar are centred in the room before the "…" button and the pinned groups: an empty
  `fill()` spacer at each end shares that room, and a spacer measures nothing, so the fold reads the same widths.
- **The pinned groups stay at the bar's end**, in both alignments. In `.Wrap` they are at the end of the last line,
  outside the flow, and the lines are centred in the flow's room: the bar less the pinned groups. Refused: a line of
  their own at the right, which would centre the lines in the whole bar but cost a line in every bar, even one that
  fits on one line, and take Cancel and Done away from the last tools.
- **Every item sits on its line's middle**, in every mode and alignment. In `.Wrap` an item is a line tall at least,
  taller with a taller control, and the flow centres each item in its line's height; a box in a bar is never a share of
  its parent's height (a share of a box sized by its children goes to a distant ancestor: the bar became as tall as
  the page once).

## The dropdown is a menu

- It is a toolkit menu (`menu_open`, `menu`), not a panel. A folded group is a section: its title as a heading, a
  separator between two sections. A tool is a `menu_item` row. A control is a `menu_control` row: its label in a left
  column, its widget in a right column, the columns aligned over every control row of the menu. The keyboard works as
  in every menu: arrows move between the tools, Enter runs one, Escape closes, what is typed filters the tools and the controls.
- **Refused: the panel that rebuilt the bar's controls in rows.** Each folded group became a row of the bar's own
  glyph buttons: unlabelled icons, ragged rows, no shortcut, no keyboard. The user called it a "soupe moche". A tool
  has a name and often a key; a menu row says both, a glyph alone says neither.
- **A group of one item has no title in the menu.** Its one row already says what it is: "Colours" over a row
  "Colour", or "Insert" over a row "Insert", said the same thing twice. The separators keep it apart from the other
  sections. A group of more items keeps its title: there it names what its rows share.
- **`toolbar_menu_show(id)` opens the menu as a click does**, under the "…" button as the last build laid it out: a
  picture or a tour shows it open. It is false while no "…" button is laid out (the program calls it until it is true).
- **A control's widget has its own width.** In a box as wide as what is in it (the bar's item, the menu's right column)
  a widget sized by a share of its parent has nothing to share: the widget gives its natural width (a slider: 12 em,
  never less than its track and its value), not the bar.
- **Refused: a program that builds the menu itself.** The program would declare each tool twice, once for the bar and
  once for the menu, and the two lists would drift. The item declares its words once; the toolkit draws both looks.
- **Refused: two APIs, one per mode.** The groups, the items, the separators and the pinned end are the same in both;
  only what happens at the edge differs. A program moves from one to the other by one option.

## A tool that opens a menu

- Insert, Picture, a zoom: a tool whose act is to show a menu. `Toolbar_Tool.menu` is the id of a menu that the program
  builds as any menu (`if ui.menu(id) { ... }`, outside the bar). In the bar the tool opens it under its own box (its
  anchor: a second click closes it) and is lit while it is open. Folded, the tool is a submenu row of the "…" menu, and
  the same `ui.menu(id)` block builds that submenu (`menu_submenu_of`: `menu` finds its id open as a level over another
  menu's row). Such a tool never returns true: what is chosen is in its menu's block.
- Its menu filters what is typed, as every menu ([menus.md](menus.md)), a zoom's few steps too. Folded, it is a
  submenu of the "…" menu: a letter typed there goes to the "…" menu's field, where the tool's items do not come up
  (they are not that menu's to filter).
- **Refused: `menu_search = false`, a tool's menu without the filter**, where a typed letter selected the next item
  starting with it. The person expects the filter in every menu, and its first match gives what the letter gave.
- A tool's `tip` is its tooltip whatever it shows: words like "100 %" do not say what the tool is.
- **Refused: a control that holds a button and opens the menu itself** (what cliche did first). Folded, the button sat
  in a menu row with no anchor that the program could use, and the menu opened over the "…" menu, not beside its row.
- **Refused: the tool's block builds the items.** The menu would then be built inside the bar's code, at the tool's
  place in the build, in the bar or in the "…" menu; a program's menu is built once, where it always is, and a menu that
  closes no longer depends on whether its tool is folded.

## Spacing

- The gaps are measured between what a person sees, and are the same for every program. A tool is a ghost button a
  line wide around a glyph half as tall: its face shows only under the pointer, so its glyph already stands a quarter of
  the line from its edge. Between two tools the gap is small (0.2 em): it only keeps two lit faces apart.
- A control's widget (a track, a swatch, a field's frame) is seen to its edge. It carries 0.15 em of its own on each
  side, so two controls stand 0.5 em apart (cliche's spacing between properties), and a control stands a little further
  from a tool than two tools do from each other. One rule, item gap plus what each item carries, reads well for a bar of
  tools and for a bar of properties.
- Two groups on one line stand a separator's room apart (0.9 em), more than any two items; the line is drawn in it when
  the later group asks for one. A group reads as a group without a line.
- **A separator never starts a line, nor ends one.** It belongs between two groups the person sees side by side. In
  `.Wrap` the room is the flow's gap, which the layout puts only between two items of one line, and the flow draws the
  lines in those gaps after the layout (`toolbar_flow_draw`): a group that wraps starts its line flush. Refused: hiding
  the separator from the last frame's layout; the group's width would change with it, and a group at the edge of a line
  would go back and forth between two lines. In `.Fold`, the line is not drawn when every group before it is folded.
- Every horizontal gap follows the density (`dense`): a dense window tightens its bars as it tightens its lists.

## Subtle points

- **One build, two places.** The bar and its menu are built in one pass over the program's code, in the bar's order.
  The menu's level is entered at the first folded item, then left and entered again around each folded item
  (`toolbar_menu_enter`, `toolbar_menu_leave`), and ended at the bar's end. A widget of the bar that opens its own
  menu meanwhile closes this one: the bar checks that the open level is still its own before it enters it again.
- **The fold reads last build's widths.** A folded item keeps the width it had when it was last in the bar: it is not
  built there while folded. A new item, never measured, is built in the bar invisible for one frame, then placed. The
  bar's first frame is invisible: it has not been measured yet. Nothing shows in a place it leaves at the next frame.
- **Gaps belong to items.** In `.Fold`, an item's gap before it is in its box (not before the first item of a group),
  a control's own room is in its box, and a group's gap and separator count with its rest: the widths that fold are
  the widths that leave. A gap of the layout would stay behind and make the fold oscillate. In `.Wrap` the groups carry
  their gap too (the flow has none), so a group's gap and its separator are one room, never both.
- **Controls are for the pointer.** The menu owns the keyboard while it is open (`menu_capture_keys`), so the arrows
  skip the control rows. A control that a person needs by keyboard is a tool (`on`) or a command of the palette.
- **What a group builds outside its items** shows in the bar only. When the whole group folds, it is built in an
  invisible box. Build a `.Fold` bar of items.
- **No spacer.** The bar puts its pinned groups at its end itself, in both modes; a `fill()` spacer in a `.Wrap` flow
  would take a whole line.

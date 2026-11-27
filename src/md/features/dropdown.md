# The dropdown and its list

`ui.dropdown`: a button that shows the current item, and a list that opens under it. Its rules are about room: the
button and the list show their words whole and spend no width on nothing.

## Decisions

- **A light inset, nothing more.** The button's words have their text's inset only, a little off its edge; the arrow
  sits in a cell of `DROPDOWN_ARROW_EM` (1.25) at the right edge, a small gap around it. A lead of 0.8 em before the
  words and an arrow's cell of 1.8 em were stuffing: a third of a narrow dropdown's room. In a dense scope the cell is
  `DROPDOWN_DENSE_ARROW_EM` (1.0) and the inset the dense one (a dense number's): `dropdown_width` gives the width that
  shows the longest item whole, the place a row gives it.
- **The list's rows, tight.** A row: a hair, the check (or the item's icon) in a column at its left, the label, its
  shortcut, a submenu's arrow, a hair (`MENU_ROW_LEAD_EM` 0.3, `MENU_ICON_EM` 1.2, `MENU_ROW_TRAIL_EM` 0.35; the dense
  ones a quarter em and a column of 1 em). The check stays at the left in every density: at the right end it sat on
  the row's edge and spilled past the list.
- **The list is a dense list under a dense button** (`Menu_Level.dense`): the scope's text and inset, rows a dense row
  high, no least width. Elsewhere a menu is a menu: the window's style (popups.odin).
- **Never narrower than what it holds.** The list is as wide as its widest row and its field's hint
  (`search_band_width`), and at least as wide as its button; wider than the button when they need it. A list cut to
  its button's width cut its hint to "Type t…".
- **In its button's room.** A list wider than its button, opened near the right edge of the room its button is shown
  in (the nearest box that clips the button: a floating view's body), moves left to stay in it (`Menu_Level.inside`),
  and inside the window. A list that ran past a floating view's edge read as cut by it. A list wider than that room
  keeps its place by its button: pinned to the room's left edge, a list aligned to its button's end ran the other way.

## Not here

- The list's filter, keys and placement above or below: popups.odin's menus, shared by every menu.

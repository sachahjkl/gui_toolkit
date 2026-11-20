# Every menu filters what is typed

A program's author reads [docs/menus.md](../../../docs/menus.md). This file keeps why the menus type as they do
(`src/ui/popups.odin`).

## The decision

- Every menu filters what is typed: a context menu, a menu bar's, a tool bar's, a drop-down's list, a field's menu.
  `menu_open` has no option for it. The person expects the filter in every menu; a menu where a letter did something
  else was a menu that seemed broken.
- The filter is fuzzy (`fuzzy_score`, the palette's). A field at the menu's top (`search_band`) shows the letters.
  The first match is selected, so Enter chooses it.
- The field is a level's own only for level 0 and a nested menu (`menu_query_owner`). A submenu has none: its items
  come up into its menu's filter. A letter typed while submenus are open closes them and goes to the menu's field.
  The menu's level does it at its own build, before its rows (`menu_letter_waits`); a submenu built before its menu
  (a tool's menu folded into a bar's "…") leaves the letter in the queue for it.
- A level filters from its first build, then only if it built an item (`Menu_Level.filters`, `had_items`). Measured with
  its field from the first, invisible frame, it keeps its place: a field that came a frame later made it taller after its
  place was held, and it ran past the anchor it opened above. A panel opened as a menu with no item (a slider's) loses
  the field before it is shown: there is nothing to filter.
- Until something is typed, Space chooses and Left, Right, Home and End move in the menu. A filter does not start with
  a space, and Space chooses in a drop-down as in a system's. Once a letter is typed, these keys edit the field.
- A drop-down opens on its current value (`menu_select`): Enter keeps it while nothing is typed. A letter selects the
  first match instead.

## Refused

- **A mode where a typed letter selects the next item that starts with it** (`menu_open`'s `search = false`, the tool
  bar's `menu_search = false`). It was there for "a menu of a few fixed choices". The filter's first match gives the
  same, and one way to type in every menu is one thing to learn. Before 1.0 nothing is kept for compatibility: an
  option that no menu must use goes.
- **A field in each submenu.** Each level would show a band, and a letter would filter only the level the pointer left
  open. The menu's filter already reaches its submenus' items.
- **The field only once a letter is typed.** The menu would grow under the pointer at the first letter, and its hint
  ("Type to search") would no longer say what typing does.

## Subtle points

- A panel opened as a menu with its own field (a vault's search) still has the menu's field when it builds an item.
  Once its own field has the focus, the keys are that field's (`overlay_capture_keys`).
- The menu's field takes its keys through the menu (`Search_Band_Options.owner_keys`): it never has the focus, so a
  field of the program keeps its own.

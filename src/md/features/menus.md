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

## The menu bar's keys

`menu_bar_button` (`src/ui/menu_bar.odin`) takes the keyboard as Windows' and GTK's bars do: galerie's bar had only the
pointer, and a person who works with the keys could not reach its menus.

- **Access letters** come from the words: `&` marks one (Windows' and GTK's own mark: "&File", "Ed&it"); without it,
  the first letter. One way to write it, no option of the call. The letter is underlined while Alt is held, while the bar
  is lit, and while a menu of the bar opened by the keys is open: the system's rule (underlines only for who uses the
  keys). Refused: underlined always (noise for the pointer's user), a separate `mnemonic` argument (two places to
  keep in step).
- **F10 and Alt alone light the bar** (its first entry): Windows has both, GTK has F10. Alt alone counts only when
  nothing was pressed while it was down (`alt_alone`, set by the press, cleared by any other key or a press of the
  pointer, read at its release): Alt+Left is no tap.
- **The bar has no begin nor end**: the first entry of a build reads the keys against the last build's entries (an
  entry's box, its menu, its letter). A key that opens a menu sets `bar.open`; that entry opens it when it is built:
  an entry built before the menu that took the key opens a build later (a frame), with no state of its own across
  windows.
- **Left and Right in an open menu of the bar go to the next menu**, not to nothing: before, Left at the top level was
  swallowed. Right on an item with a submenu still opens it. **Escape** closes the menu and leaves its entry lit, the
  keys the bar's; a second Escape gives them back (Windows').
- The implicit state machine: Idle, Lit (`bar.focus`), Open (a menu of the bar); the transitions are in the head of
  `menu_bar.odin`.

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

# The path bar: intent

What the person sees and the API are in [docs/path-bar.md](../../../docs/path-bar.md). This file keeps the reasons.

## Purpose

A folder's path, shown as a breadcrumb a click walks, and typed as an address with a list of what can come next. The
file browser has one; a program's own screens (ocn's server folders, a project's tree) want the same bar. So it is a
widget of its own, `ui.path_bar`, that knows nothing of files: a path is a text with a separator.

## Decisions

- **No reading inside the widget.** It says which folder's children it needs (`wants`), once per folder; the program
  answers later with `path_bar_children` or `path_bar_failed`. The widget cannot wait on the interface's thread, and
  only the program knows where its folders come from (a source, a server, a model). The answer for a folder that is
  no longer the one wanted is dropped: the folder is the ticket, a path compared with its trailing separators trimmed.
- **`wants` is an edge, not a level.** Said in the build where the folder typed changes, never again for it. A level
  (said each frame) made the browser ask its source each frame. Leaving the address mode forgets the folder: a new
  edit asks again, the folder may have changed.
- **The suggestions are set, not given each frame** (`path_bar_suggestions`). Copying or comparing them per frame is work
  in proportion to them; the program knows when they change (places, recent folders, a search's answer).
- **Ranking happens when the text or the data change.** A version counts the changes of the children and of the
  suggestions; the rows are kept with the (text, version) they were made for. A quiet frame ranks nothing. The rows
  shown are bounded (`PATH_BAR_SHOWN_MAX` per section): a folder of 100 000 entries builds as many boxes as a small one.
- **Children are ranked against what follows the last separator; suggestions against the whole text.** A child is a
  name in the folder typed; a suggestion is a whole path from anywhere. `rank` with `rank_fuzzy`, the toolkit's one
  ranking, with a fold cache per section: a letter typed folds only the new needle.
- **One well for both modes.** The breadcrumb and the field are in the same `input_frame`, of the same height: a click
  that turns one into the other moves nothing.
- **The dropdown is a `popover`, its rows `choice_row`s.** A `menu` takes every key of the frame (it is an overlay
  that owns the keyboard), and the field must keep typing. The popover is the toolkit's floating panel that takes
  no keys; `choice_row` is its list row, the palette's look. `choice_row` grew `ranges` (the matched letters) and
  `beside` (the detail on the line): one row for every list to choose from.
- **A press on the dropdown keeps the field's keyboard.** A press moves the focus to the box under it, which is not
  focusable there: the address mode would end before the row's click (on the release). The bar gives the focus back
  to the field in the frame of that press.
- **The path as it came filters nothing** (`fresh`, until the text is edited). It is selected: what is typed replaces
  it. Ranked against it, the dropdown showed the siblings of the folder that match its own name and hid every
  suggestion. Fresh, it lists the folder shown's children and all the suggestions: what a person who pressed Ctrl+L
  looks for.
- **Nothing highlighted at first.** Enter on nothing goes to the text typed: a person who typed a whole path is not
  sent to the first suggestion. The pointer moving over a row highlights it, as in a menu.
- **The text typed goes out absolute, as typed.** A relative one is joined to the bar's path; nothing is cleaned: a
  trailing separator says "this folder" to a program that tells a folder from a file (the browser).
- **The "/" glyph is the separator shown, whatever the source's.** One look for every path; the root shows as itself
  ("/", "C:"), and the part after a root that ends with a separator has no glyph before it.
- **The leading parts collapse into "…"**, by the bar's width at the last layout, the last part always shown. Its
  menu is the toolkit's `menu`, the hidden parts deepest first.

## Refused

- A completion that fills the field as far as the names agree (the shell's Tab). Tab takes the row highlighted, or the
  best one: the list already shows what the names have in common, and a fuzzy needle has no common prefix.
- A source (`File_Source`) inside the widget: the bar would be the browser's.
- A suggestion list given by a callback the widget calls each frame: the program's work in each frame.

## Subtle points

- Escape is the bar's while its field has the keyboard: the browser's own Escape order skips the path field then.
- A folder typed with "/" on a source of "\" is the same folder: `file_path_clean` reads both.
- The children's "Reading…" line comes after `PATH_BAR_SLOW_MS` by the State's clock: a fast answer does not flash.
- `go` from a row is that row's path: a child's is the folder typed joined to its name.

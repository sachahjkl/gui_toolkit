# Find in a view (`ui.find_bar`)

A person looks for a word in a view: a conversation, a log, a document, a settings page. The toolkit has one find per
window, over one view, with its bar at the view's top right, inside it, left of its scroll bar. The reasons are in
[src/md/features/find-in-view.md](../src/md/features/find-in-view.md); the code is `src/ui/find.odin` and
`src/ui/find_bar.odin`; the scenario tests are `tests/scenarios/find_test.odin`.

The bar has:

- the field, with the keyboard when the bar opens (its text selected; the text stays while the bar is closed);
- the count: "3/17" (the current match and how many), "No results", "12…" while rows are still being counted;
- the scopes, as a segmented choice, when the program gives two or more and the view has rows;
- match case (Alt+C) and whole word (Alt+W), toggled glyph buttons;
- previous and next: Shift+Enter and Enter in the field, Shift+F3 and F3 anywhere in the window while the bar is open;
- close: Escape, which gives the keyboard back to what had it.

A pointer press on an option, a scope or an arrow leaves the keyboard in the field: the person goes on typing. Tab and
Space still reach and press each button.

Every match is painted behind its letters: a light fill of the theme's `find_match background` inside a 1 px edge of
its `find_match border`, the current one in `find_current background` with a 2 px edge of `find_current border`. The
letters keep their own colours (a code's colours stay). The edge reaches 3:1 against what is under the view's text
(`ui.FIND_EDGE_RATIO`) in every theme. Every match is also a tick on the view's vertical scroll bar, in the edge's colour, the
current one twice as tall, over the program's own marks ([scroll-marks.md](scroll-marks.md)).

## Use

```odin
// the program's Ctrl+F (a command of its own): open over the view, or give the field the keyboard
if ui.command_pressed(app.find_cmd) { ui.find_open(app.state, app.doc_key) }

ui.next({width = ui.fill(), height = ui.fill()})
if ui.scroll_y("###doc") {
	... the content ...
}
res := ui.find_bar(ui.prev_box("###doc"), {placeholder = "Find in the document"})
if res.scrolled { app.follow_bottom = false }   // the find moved the view to a match
```

- `ui.find_open(s, view, text = "")` opens the find of window `s` over the scroll box `view` (its key). Open there
  already, it gives the field the keyboard and selects its text. Open over another view, it moves: there is one find per
  window, so there is at most one bar per view. `text` replaces the field's text.
- `ui.find_close(s)` closes it: nothing lit, nothing counted, its cache freed.
- `ui.find_set_current(s, index)` makes the `index`-th match current (0-based, over every row), clamped to the matches,
  and brings it in as the arrows do. It waits until every row is counted; with no needle or no match it does nothing.
- `ui.find_is_open(s, view = 0)`: the find of window `s` is open over `view` (0: over any). It reads what the last call
  of the others wrote, so a program that closes a panel asks it and calls `find_close` with no flag of its own.
- These four take the window's State: call them in a build, or between two builds on the interface thread (a command
  line option, a menu, a key the program routes itself), for any window. The next build of `s` applies the three that
  change it, and `ui.needs_frame(s)` is true until it runs.
- `ui.find_bar(view, options) -> Find_Result` at each build of the view, before or after its content, with the view's box
  of this build or of the last one (`prev_box`). It builds the bar only while the find is open over that view. A build that
  does not call it lights nothing: a page that is not shown has no find.
- `Find_Options`: `placeholder` (the field's hint; "" is "Find"), `scopes` (below).
- `Find_Result`: `moved` (a step or a new needle chose another current match in the build before), `scrolled` (the build
  before moved the view to bring the current match in: a program that follows the bottom of a log stops following),
  `row`, `start`, `end` (its row and its bytes in the row's whole text; row -1 with no rows). A view that paints its own
  rows (a terminal) brings that row in itself.
- `ui.find_count()`, `ui.find_index()` (the current match, -1 none), `ui.find_pending()` (rows not counted yet),
  `ui.find_needle()` (the field's text), `ui.find_matches()` (what the last layout lit: box, window rect, ordinal),
  `ui.find_row_matches(row)` (a row's byte ranges), `ui.find_ticks(view)` (the ticks' places on the bar, for tests).

## A view that builds all of its content

A view with no rows is searched in its boxes after each layout: every label, wrapped paragraph and rich paragraph of its
subtree (a match may span the runs of a rich paragraph, never two boxes). This is enough for a settings page, a dialog, a
short list. A step brings the match's rect into the view.

## A view with rows: a lazy column, a terminal, a diff

A view that builds only a part of its content declares its rows. A lazy column does it with the rows it already gives the
text selection:

```odin
rows := ui.Text_Rows{
	count   = len(doc.items),
	text    = item_text,      // proc(user, row, allocator, whole) -> (string, bool)
	id      = item_id,        // a row's identity: rows put before it do not change it
	stamp   = item_stamp,     // changes when that row's text changes (a counter, a length)
	version = doc.version,    // changes when any row changes
	reveal  = item_reveal,    // proc(user, row, offset): open the folded part that holds byte `offset`
	user    = doc,
}
lz := ui.lazy_begin(rows = rows)
```

- `text(user, row, allocator, whole)`: the row's text as its `.Selectable` boxes give it, in their order (two boxes: a line
  break between them). `whole` false is what they show now (a copy); `whole` true is what they would show with every part
  the program can open opened: a folded tool output, a long reasoning past its preview, a diagram's source. The find reads
  the whole text: what is folded is counted.
- The find counts the rows in slices, at most `ui.FIND_ROWS_PER_FRAME` rows and `ui.FIND_BYTES_PER_FRAME` bytes a frame,
  plus the rows built in that frame. It keeps each row's text by its `id` while it is open, and reads it again only when its
  `stamp` moves: a new needle, an option, a scope count again from what it kept. Without `stamp`, `version` stands for every
  row's: give `stamp` for a long list.
- A step to a match in a row that is not built builds that row in the next build, wherever it is, and brings it in.
  The rows on the way stand as the column's estimate until they are built and measured, which moves the match; the view
  follows it at each build until it rests with the match inside, for at most `ui.FIND_SETTLE_BUILDS` builds. A wheel
  turn or a drag of the scroll bar's thumb ends this: the person took the view.
- A match in a part that is not shown: the boxes of its row hold fewer matches than its whole text. The find calls `reveal`
  once with the match's byte offset; the program opens that part; once the row's boxes hold as many matches as its text, the
  match is lit and brought in. A program that cannot open it leaves it: after a few builds the view goes to the row.
- A row's built matches are numbered as the whole only when it holds as many as its whole text; otherwise they are lit
  without a number (none of them is the current one).

A view that draws its rows itself (no lazy column) declares them with `ui.find_rows(view, rows)` in its build, gives where
each row starts with `ui.find_place_row(row, top)` for the ticks, paints `ui.find_row_matches(row)` and brings in
`Find_Result.row` when `moved`.

## Scopes

```odin
scopes := []ui.Find_Scope{
	{name = "All"},
	{name = "Prompts", keep = proc(user: rawptr, row: int) -> bool { return is_prompt(user, row) }},
}
ui.find_bar(view, {scopes = scopes})
```

The first scope is the default. A scope's `keep(rows.user, row)` says whether a row is searched (nil: every row). A change of
scope counts again from the texts kept. Scopes apply to rows: a view with no rows shows none.

## The marks' magnifier

A bar with marks (`ui.scroll_marks`) has a magnifier above it: a press opens the find over its view, a second press closes
it; a character typed while the marks have the keyboard opens it with that character. The program wires nothing: the
magnifier calls `ui.find_open`. To search only the marked items, give a scope that keeps them.

## What it costs

A frame visits at most `FIND_ROWS_PER_FRAME` rows (an `id` and a `stamp` each), reads or matches at most
`FIND_BYTES_PER_FRAME` bytes, and looks at the boxes of the rows it built. The count before a row and the row of the k-th
match come from a Fenwick tree: logarithmic. The ticks are merged again only when the counts, the places, the track or the
content's height change. While it counts, the find asks for the next frame (`needs_frame`); once counted, nothing.

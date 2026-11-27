# Find in a view: intent

How a program uses it is in [docs/find.md](../../../docs/find.md). This file keeps the reasons. The code is
`src/ui/find.odin` (the model, the matches, the painting) and `src/ui/find_bar.odin` (the bar); the ticks on the scroll bar are
drawn by `src/ui/scrollbar.odin`; a lazy column feeds the model from `src/ui/lazy.odin`.

## Purpose

A person who reads a long view (a conversation, a log, a document, a settings page) looks for a word in it: Ctrl+F, a field,
"3/17", Enter to the next one. Before this design a program had three ways that overlapped (opencode native, 0.72):

- its own find bar over the toolkit's find in page: it read the text that a build made, and a lazy column was read by a
  *sweep* that built a slice of its items at each frame. A part folded away, a reasoning past its preview, a diagram's
  source were never searched: the build had not made them.
- the marks rail's filter field (the magnifier above the bar): it kept the prompt marks whose text held the words. It had no
  count, no highlight, the view did not move, it was drawn at the same corner as the find bar, and both could be open.
- Jump to message: a palette of the prompts.

Three answers to one question, "where in this view does it say X". The design gives one: **one find per view**, in the
toolkit.

## The irreducible model

A view's searchable content is **a sequence of rows**, each with an identity and a text. Everything else is derived:

- a match is *(row, byte range in that row's text)*;
- the count is the sum of the rows' counts: it never needs a layout;
- the current match is *(row identity, which occurrence in that row)*;
- what is lit is the part of the rows that is built, found again in the built boxes.

A view that builds all of its content (a settings page, a dialog, a short list) needs no rows: its built boxes are its text
(the *box mode*, below). A view that builds only part of it (a lazy column, a terminal's scrollback, a diff) gives rows.

### The single source of a row's text

`Text_Rows` is the one description of a view's rows, the same value the text selection already reads
([text-selection.md](text-selection.md)). Its `text(user, row, allocator, whole)` gives a row's text:

- `whole = false`: what its boxes show now, for a copy (a folded part is not copied: it is not on the screen);
- `whole = true`: what its boxes would show **with every part the program can open opened** (a folded tool output, a long
  reasoning past its preview, a diagram's source), for the find.

One procedure, two readings: the program writes one function and a flag, so the text a copy takes and the text a find reads
cannot drift apart. The contract is strict: the `whole` text is the `.Selectable` boxes' texts of the row, all parts open, in
tree order, with any separator that holds a newline between boxes. That contract is what lets a match be found again in the
boxes (below).

Refused:

- **A second struct for the find (`Find_Rows`)**: two descriptions of the same rows, kept in sync by hand in each program.
- **The copy text for the find**: what is folded is not found, which is the failure this design corrects.
- **The program's raw source (Markdown)**: a match on `**` that no box shows cannot be lit, and its count would differ from the
  boxes' at every emphasis.

### Change: `stamp`, `version`, identity

`Text_Rows.id` (already there for the selection) is a row's identity: rows inserted before it (a page of older messages) do
not change it. `Text_Rows.stamp(user, row)` changes when that row's text changes (a message that streams, a part that came);
`Text_Rows.version` changes when any row changes. A stamp is cheap (a counter, a length), so the model can ask it of many rows
at each frame; the text is read only when the stamp moved. With no `stamp`, `version` is every row's stamp: correct, and a
change of anything reads every row again (fine for a short list, not for a long one).

## Counting without building

The model keeps, while a find is open:

- a **cache by row identity**: the row's whole text (owned), its stamp, its count for the current query;
- an **order**: for each row index, its identity and whether it is known for the current query;
- a **Fenwick tree** over the rows' counts: the number of matches before a row (the "3" of "3/17") and the row that holds the
  k-th match, both in O(log n), updated in O(log n) when one row's count changes.

A **pass** walks the rows from a cursor, wrapping, with a budget per frame (`FIND_ROWS_PER_FRAME` rows visited,
`FIND_BYTES_PER_FRAME` bytes read or matched, at least one row). A visit asks the row's id and stamp; if they are the ones it
knows for this query, it is done; else it reads the text (only when the stamp moved: a new needle matches the cached text) and
counts. A pass starts again when the query changes (needle, case, whole word, scope), when the count of rows changes, when
`version` changes. **The rows built in this frame are visited at every frame**, outside the budget (they are a screen's worth):
the message that streams is counted as it grows.

`find_pending` is true while some row is not known for the current query: the count then shows "12…". A pass that only checks
stamps (a version moved, nothing else) is quiet: the count stands.

Refused: **the sweep** that was (`lazy_begin(sweep = find_sweep())`): it built a slice of items at each frame to read their
boxes' text. Building is far dearer than reading a text (layout, Markdown, shaping); what a build folds was still missed; the
count waited for the needle to rest and for a whole pass of builds; and the sweep had to guess when what is built no longer
answered what it had read. The rows' text answers all four.

**No frame does work in proportion to the rows.** The pass is bounded; the Fenwick queries are logarithmic; the ticks on the bar
are merged only when their inputs change. The test `a_long_list_is_counted_in_bounded_slices` counts the text reads of each
frame over 20 000 rows.

### Why on the interface's thread, in slices, and not a task

The rows' `text` reads the program's live data (a message that streams), which a chore cannot read without a lock the program
does not have. A task would need a snapshot of every row's text, and making it is the work in proportion to the data that the
rule forbids. The reading is the cost (Markdown made plain); the matching of cached text is a few hundred kilobytes a frame. So:
the reads and the matches in bounded slices, the cache kept for the next needle. Refused: a snapshot per query handed to a
task; a lock in each program around its rows.

### Rows inserted

A change of the count rebuilds the order (O(rows), once for that change) and restarts the pass; the cache, by identity, keeps
every text, so the rows are recounted from it, not re-read. The current match is held by its row's **identity**: the pass finds
its new index when it visits it. Until the pass ends the "3" can be off; it says so ("…").

## Finding a match in the boxes

A lazy column (`lazy_begin(rows = ...)`) inside the open find's view gives its rows to the find (`find_rows`), tells it which
row each built item is, and where each row starts in the content (for the ticks). After the layout, for each built row, the
find reads its `.Selectable` boxes in tree order and finds the needle in them: the built count `nb`. The row's count from the
cache is `n`.

- `nb == n`: the row is fully open; the j-th match in the boxes is the j-th in the row's text (the contract above), so each
  rect gets its ordinal (the Fenwick prefix plus j) and the current one is lit stronger.
- `nb < n`: a part is folded. The built matches are lit as matches, none as current (which one it is cannot be told).
- `nb > n`: the program's `whole` text misses what its boxes show. The same: lit, none current.

Refused: mapping by byte offsets per box (every box would have to say where its text starts in the row's text: a change in
every widget); aligning the built text against the row's text (costly, and wrong when a fold removes a repeated phrase).

### The current match's way to the screen

The current match is a small state machine (`Find_Goal`):

- **None**: nothing to bring in.
- **Seek**: a step chose it. If its row is not built, the lazy column builds that row in the next build wherever it is (as it
  builds the selection's ends), and the view goes to it. Once built: `nb == n` → the view brings the match's rect in (a glide
  to put it at a third of the view's height, only when it is not already well inside) → **Settle**. `nb != n` with a
  `reveal` → **Reveal**.
- **Reveal**: `Text_Rows.reveal(user, row, offset)` was called once, `offset` the match's byte in the row's whole text. The
  program unfolds the part that holds it. At each build the row is looked at again; when `nb == n` the match is lit and
  brought in → **Settle**. After `FIND_REVEAL_BUILDS` builds without it (the program could not reveal it) the view goes to
  the row's top → None, the count unchanged.
- **Settle**: the target was set from a layout whose rows between the view and the match were estimates. At each build the
  row stays built and the match is brought in again from its rects of that layout. When the bring-in has nothing to change,
  the view rests on its target and the lazy column built all it shows (`lazy_more` false) → None. A wheel turn or a held
  thumb → None: the person took the view. After `FIND_SETTLE_BUILDS` builds → None: a layout that never rests (a row that
  grows at each frame) does not hold the view for ever.

**Why Settle.** A lazy column replaces the estimate of a row with its height when it builds it; the glide toward a far
match builds the rows it passes. Those above the column's anchor move the view and its target together (`view_shift`,
clamped at 0); those between the anchor and the match move the match under a fixed target. A jump set once lands where
the match was in the first layout (opencode native: from match 59 to match 10, the view stopped at 0, the match below
it). F3 seldom showed it: its step lands on a row next to built ones, whose heights are measured. The fix is the same
bring-in, done again until the layout rests, so a step, `find_set_current` and a revealed part share it. Refused: a
height for the rows on the way before the jump (building them is the cost the lazy column avoids); a jump with no glide
(the anchor still moves the match); following `Vlist_Rows.guessed` (it says a vlist's first build, not a lazy column's
estimates).

A view with rows and no lazy column (a terminal that draws its own grid) has no boxes: `find_bar` returns the current
match's row and range when it changed (`Find_Result.moved`), the program scrolls to it and paints the ranges it reads with
`find_row_matches`.

**The find says when it moved the view** (`Find_Result.scrolled`): the build before set the view's scroll target to bring
the current match in. A program that follows the bottom of a log stops following then, or the next line pulls the view
away from the match. `moved` does not say it: a match already well inside the view is made current without a scroll, and a
step to a row not built scrolls over several builds. The flag is set where the target is written (`find_bring_in`), so
every way to the screen (box mode, a built row, a row not built, a revealed part) reports it. Refused: the program
comparing its scroll offset before and after (a wheel, a glide, its own follow would read as the find's).

### A current match the program chooses

`find_set_current(s, index)` makes the `index`-th match current (clamped to the matches), then brings it in as a step
does: the same `find_make_current`, the same goal **Seek**. The index is an ordinal over every row, so it is applied once
the count is known (no row left to count): before that, the k-th known match is not the k-th match. Until then it waits
in the State (`asked`), with no frame of its own: the pass already asks for the next frame while it counts. No needle, or a
needle with no match, drops it; a close or a move to another view drops it. Called in the same build as a step, it wins. Refused: a
step of `index - current` (wrong while the count grows, and a wrap at the ends).

## Box mode

A view that gives no rows is searched in its built boxes after each layout, every `.Draw_Text` box and rich paragraph of its
subtree (a settings page's labels are its content). Each occurrence has its rects and its ordinal; the current is an ordinal;
a step brings its rect in. This is the find in page that was, kept for views that build everything.

## The bar

`find_bar(view, options)` is called at each build of the view; while the find is open over that view it builds the bar:

- at the view's top right, inside it, left of its scroll bar's room (never over the bar: its ticks are the map of the
  matches), at the window's root so that it is over the content and takes its clicks;
- the field; the count ("3/17", "No results", "12…" while counting); the scopes as a segmented choice when the options give
  two or more and the view has rows; the options case-sensitive (Alt+C) and whole word (Alt+W) as toggled glyph buttons;
  previous and next; close;
- Enter and Shift+Enter in the field, F3 and Shift+F3 anywhere in the window while it is open, step; Escape closes and gives
  the keyboard back to what had it.

**A pointer press in the bar leaves the keyboard in the field**, as a browser's find bar does: the options, the scopes, the
arrows act on what the field holds, and the person goes on typing. The press gives the keyboard to what it hits (an
unchosen scope is not even focusable: the keyboard went nowhere); the bar takes it back for the field in the build of the
press, before anything is drawn. A press is a pointer's (`pressed_any`): Tab to a button and Space keep the keyboard on the
button, and a screen reader's activation does not move it. The scopes' dropdown (a narrow view) is left alone: its menu
takes the keyboard and gives it back to its button. Refused: a flag on each button that keeps the focus where it is (a
change in the button, the segmented control and the dropdown for one caller).

**The program drives it outside a build.** `find_open(s, view)`, `find_close(s)` and `find_set_current(s, index)` take the
window's State: a program calls them from its command line (`--find`), its menu or a key it routes itself, on the
interface thread, between two builds, for a window that is not the thread's current one. They write the State only (the
field, the flags, the focus key); the next build of that State applies them, and `needs_frame(s)` is true until it runs.
`find_is_open(s, view)` reads the same flag they write, so it answers at once after them: a program that closes a panel
closes the find over it without a flag of its own (opencode native kept one, because the query read the current State
only). One form, with the State: the bar's own calls pass theirs. Refused: a second form on the current State beside it
(two names for one act); a queue of requests (the State already holds what the next build reads); `Find_State` made
public (the program would read the find's working state).

**One find per window.** The State holds one find: its view, its field, its options. `find_open(s, view)` opens it over that view,
or focuses its field when it is open there already (its text selected); open over another view, it moves. So there is at most
one bar per view by construction, and two bars in one corner cannot happen. Refused: a find state per view kept by the
program (each program would wire the magnifier, the keys and the corner by hand, and two finds could light the same boxes).

**Nothing else in its corner.** The marks rail's filter field is gone; the magnifier above a bar with marks opens this find
(`find_open(s, view)`), and a character typed while the marks have the keyboard opens it with that character.

**The text stays** while the bar is closed: Ctrl+F again shows it, selected. A change of what the view shows (another
session) is the program's to say: `find_close`, or nothing (the rows' identities change and the pass counts again).

### Scopes

`Find_Options.scopes` names subsets of the rows ("All", "Prompts"). A scope's `keep(user, row)` says whether a row is searched
(nil: all). The scope is part of the query: a change counts again from the cache, no text read. This replaces the rail's
filter (which kept prompt marks by their text) and opencode native's Jump to message (a palette of the prompts): "Prompts" and
Enter go to a prompt that says the word, lit, counted. A scope applies to rows only; a view in box mode shows none.

## The look of a match

The code is `find_draw` (`src/ui/find.odin`) and the `Find_Edge` and `Find_Fill` slots (`theme_default.odin`).

- **A light fill and an edge, the letters in their own colours.** Every match is a fill of the theme's `find_match
  background` inside a 1 px edge of its `find_match border`; the current match has a 2 px edge (`find_current`), and its
  rect grows by that pixel so the edge does not touch the letters. The box draws its text over them as everywhere else:
  a code's comment stays grey, a keyword purple.
- **Why.** Up to 0.363 a match was an opaque amber (0.62, the current one 0.85) and its letters were drawn again in
  `find_text`, black or white. On a code view the colours of the code went away under each match, and in plume's
  captures a grey comment on amber did not read. The person looks for where the word is, then reads it in its context:
  the edge says where, the letters keep what they say.
- **The edge reaches 3:1** (WCAG 1.4.11, a part of the interface that is no text). `Find_Edge` is the theme's warn hue
  made readable at `FIND_EDGE_RATIO` on the page (`readable`: a light theme's amber is darkened); at the draw, it is
  checked again against what is under the box (`box_under`: a selected row, a bar).
- **The fill looks like 15 % of the edge's colour in every theme** (`FIND_FILL`). An alpha mixes in linear light, where
  0.15 of amber on a black page looks like 40 % (measured `#69562A` on `#151515`): `Find_Fill` is the edge's colour at
  the alpha whose mix has the luminance of an sRGB step of 0.15 from the page.
- **The fill gives way before the text.** Where the theme's text would drop under 4.5:1 on it (or the weak text under
  3:1), the share shrinks by steps of 0.8 until both read (Tokyo Night's light text read 4.07 on the full share).
  `tests/theme_look` checks it, and the edge's 3:1, in every theme.
- **On a selected row, the edge alone.** A selected row's inks are made to read at 4.5:1 on its own ground
  (selection-contrast.md); a fill over it took a nav row's title to 4.06:1 (Naysayer). There the match is its edge only.
- The scroll bar's ticks are in the edge's colour (`find_match border`, `find_current border`): a tick is a thin line,
  and needs the edge's contrast, not the fill's.

Refused:

- **An opaque fill with letters drawn again in a colour that reads on it** (the look up to 0.363): it removes the
  text's own colours, and it needs a second pass of the text clipped round each match.
- **A fill alone, without the edge**: at 15 % the fill alone is below 1.5:1 on the page and does not show where a match
  is; strong enough to show it, it covers the colours again.
- **The selection's colour for the matches**: a match is not a selection, and a selection inside a match must show.

## Ticks on the scroll bar

Every match is a tick on the view's vertical bar, in the theme's `find_match border`, the current one in
`find_current border` and twice as tall, drawn over the thumb and over the program's marks: those (prompts, headings) are navigation and
keep their accent; the ticks are the find's and go when it closes. With rows, a tick is a row's top (from the lazy column's
`y` before its item, `find_place_row` for a custom view); in box mode, each occurrence's top. Ticks closer than a pitch are one.
The merge is made again only when the counts, the places, the track or the content height change.

## Subtle points

- **Whole word** is a match whose neighbours are not letters, digits or `_`. **Case** is simple folding, rune by rune, as before;
  case-sensitive compares the runes.
- **The query's generation** (`gen`) counts the changes of needle, options and scope: a cached count is valid for one `gen`.
- **A row whose stamp moved** is read again even when the query did not change: its count changes in the tree at once.
- **The bar's needle is the find's** only in a build that called `find_bar` for the open view: a page without it shows no
  highlight, and the cache is freed when the find closes.
- **The cache costs the text of the rows** (one copy) while the find is open, and nothing once it closes.
- **The first match of a new needle** is chosen once its count is known (no row left to count): the first at or below the
  view's first row in view (box mode: the first rect at or below the view's top), else the last above it, and brought in. Not
  before: a count still growing would move the view at each slice.
- **A step reads the built rows after it**: the step is made first, then the built rows are matched, so the row it lands on is
  the one looked for in the boxes of that layout (the other order brought the old current match in again).
- **The bar is never wider than its view**: a narrow view shrinks the field first; the scopes keep their own width.

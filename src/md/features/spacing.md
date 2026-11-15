# One spacing scale: intent

Every gap and every inset of a program's page is a step of one scale, given by the toolkit. A program names the role
of a gap (a card's inset, the gap between two groups) and the role gives its step. Atelier had this alone, in its
`view.odin`; the toolkit takes it, with the blocks that use it: the card, the list card and its rows, the well.

## The problem

- **Scattered values.** `ui.card` puts 0.9 em above and below its content, 1.1 em at its sides and 1 em after itself;
  programs add 0.3, 0.45, 0.6 em of their own around it. Two places next to each other look a little off, and nobody
  can say which value is right.
- **A card that adds a gap after itself.** The gap between two cards belongs to the page, not to the first card: a
  card at the end of a column left a gap under it, and a page that wanted cards closer could not have them.
- **Each program keeps a scale.** Atelier's `SPACE_*` and its roles, its card, list and list rows are written again by
  the next program that wants the same look.

## Decisions

### The steps

`ui.SPACE_1 .. ui.SPACE_6` are font sizes: 0.25, 0.5, 0.75, 1 and 1.5 em (`SPACE_5` does not exist: 1.25 em was never
used and would invite the in-between values the scale removes). `ui.space(step)` is a spacer of that many font sizes
along the parent's axis, on whole pixels.

Refused: pixels. A scale in em follows the zoom and the density, as every size of the toolkit does.

### The roles

The toolkit names the roles a page has, each with one step:

| Role | Step | Where |
|---|---|---|
| `PAGE_MARGIN` | `SPACE_6` | the page's left, right and bottom edges |
| `CARD_PAD` | `SPACE_4` | a card's inset, the same on its four sides |
| `ROW_PAD` | `SPACE_3` | a list row's inset above and below (its sides: `CARD_PAD`) |
| `GROUP_GAP` | `SPACE_6` | between two groups of a page |
| `ITEM_GAP` | `SPACE_4` | between two items of one group |
| `LINE_GAP` | `SPACE_2` | between two lines of a group, between a group's head and its card |
| `ICON_GAP` | `SPACE_2` | between an icon and its words |
| `CONTROL_GAP` | `SPACE_2` | between two buttons, between words and their button |
| `TOOL_GAP` | `SPACE_1` | between two icon buttons of a bar |
| `INNER_PAD` | `SPACE_3` | inside a well: its content's inset from its edge |

A program uses the roles; a step alone is for a place no role names. A program that needs a role the toolkit lacks
asks for it here rather than keep its own.

### The card

`ui.card(title, icon)` keeps its signature. Its content sits `CARD_PAD` from each of its four edges, its title
included. It adds nothing after itself: the page puts `GROUP_GAP` or `ITEM_GAP` between two cards.

### The list card

`if ui.list_card(id) { for ... { if ui.card_row(id) { ... } } }`: one card whose rows are split by hairlines. Each row
has `ROW_PAD` above and below; the card's own inset above and below is `CARD_PAD - ROW_PAD`, so its first and last
rows sit `CARD_PAD` from its edges, as the content of any card. A row draws its hairline above itself when it is not
the first: the program does not count its rows.

### The well

`ui.well(id, axis, flags, pad = 0, edge = true)`: `pad` is an inset of that many font sizes on its four sides
(`INNER_PAD` for a text in it); `edge = false` leaves its border out (a tinted area inside a card, where a second edge
would be one line too many).

### The wireframe

`ui.set_wireframe(s, on)` draws every box of the window as its outline, over the page, each gap filled with the colour
of its step (`SPACE_1` blue, `SPACE_2` green, `SPACE_3` yellow, `SPACE_4` orange, `SPACE_6` violet), a gap off the
scale in red, and the innermost box under the pointer named with its size. A gap knows its step because `space` writes
it on the spacer it makes (`Box.gap_step`); a spacer made by hand (`spacer(px(...))`) has none, and shows red: the
places that still leave the scale are seen at a glance.

It is the author's, not the users': Ctrl+Alt+Shift+W toggles it only in a build with the devtools
(`TOOLKIT_DEVTOOLS`), and Chrome DevTools' Rendering panel turns it on with "Layer borders"
(`Overlay.setShowDebugBorders`). A gap is drawn across its whole parent: it has no size across the parent's axis, and
the room it makes is the parent's width (or height).

## Subtle points

- The steps are rounded to whole pixels where they are used (`space`), never in the constants: a scale multiplied
  before rounding stays a scale at every zoom.
- A list row's hairline is the theme's (`hline`), as wide as the card's content: it does not touch the card's edges.
- The settings' pages (`prefs_page`) and the setup use the roles too. Their framed boxes of facts (the setup's panels,
  the Diagnostics rows) are wells: `INNER_PAD` inside. The changelog's version card has `ui.card`'s inset. A few gaps are
  no role and stay a bare step: the page's top (`SPACE_4`, under the window's bar), the sidebar's insets, the gap
  between two theme cards and between a key and its value. The sidebar's heading lead aligns with its rows' words; it
  is not a gap.

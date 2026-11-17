# A text cut to a width

One cutter (`ui.elide`, `src/ui/elide.odin`) cuts a text to a width with an ellipsis: the boxes' text (`draw_box_text`
through `truncate`), the last line of a mark's card, and what a program draws itself (a crumb, a tile's name, a node of
a tree). Before it, the toolkit had three cutters and the programs wrote four more, each with its own cost and its own
bugs.

- **Where it cuts is the caller's choice: `.End` or `.Middle`.** The end is for a title or a line of a list. The middle
  is for a name whose end says what it is: an extension, a version, a number. Only these two: a cut at the start ("…tail")
  had no caller.
- **It cuts between clusters, never inside one.** An accent or an emoji stays whole (as `ui.wrap_lines` and the text
  fields do). The spaces beside the cut go: "word …" reads as a gap.
- **It measures shaped text, by halves.** The width of a kept part is `font.text_width` of the part with its ellipsis, so
  kerning and ligatures count, and a few measures find the cut whatever the length. The old box cutter added glyph
  advances one rune at a time: linear, and a pixel off where a pair kerns.
- **The cut is cached** by the text's hash, font, size, width, place and ellipsis, and an entry not used for
  `WRAP_CACHE_KEEP` builds goes, as the wrapped lines. A list that asks every frame measures each text once. The key
  hashes the text at each call: one pass over the bytes, cheaper than one measure.
- **A text that fits is returned as it is**: the same string, no allocation.
- **Two ellipses.** `elide` writes "…" (`ELLIPSIS`). A box's cut text keeps `TRUNC_ELLIPSIS`, its own target that opens
  the whole text (text-reveal.md); the cache key holds the ellipsis, so both share one cache.
- **A line that must end in the ellipsis** (more text follows, as on a mark's card) is cut with the ellipsis already at
  its end: `elide(f, size, line + ELLIPSIS, width)`. With `.End`, the last cluster is never kept when the text is cut,
  so the result ends in one ellipsis, never two, and no second procedure is needed. (`.Middle` keeps the last
  cluster: it is the end of the name it shows.)
- **The window being built.** `elide` measures with the fonts and the cache of the State in use (`gs()`), as every
  widget does: it is called in a build, or in a draw callback of that State. A program that draws for another
  window's State makes that State current first.
- **What changed for a box's cut** (it goes through `elide` too): a text that fits once shaped is drawn whole, with no
  reveal target, where a measure that over-counted cut it; and a width of exactly the ellipsis gives the ellipsis, not
  nothing.

## Not here

- **The rich text's ellipsis** (`rich_text.odin`, a cut last line) stays its own: its line is fragments of several faces
  and sizes, already laid out, and it cuts the last fragments back. `elide` takes one font and one size.
- **A text cut to a number of wrapped lines** (classeur's tile names) is not a width: it wraps, then counts lines.

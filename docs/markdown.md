# markdown: Markdown in a window

`import "gt:markdown"`. Shows Markdown as people and models write it in a chat, a note or a reply: headings,
paragraphs, bullet and numbered lists (nested by indent), quotes, rules, tables, fenced code, and inline `**bold**`,
`*italic*`, `` `code` ``, `~~strike~~`, `[links](https://example.org)` and bare web addresses. Each block is a `ui.rich_paragraph`
(selectable, its links answer the pointer and the keyboard). For Markdown to HTML (a site), see `site.render_markdown`.

```odin
doc: markdown.Doc                                   // the program keeps it: one per text shown
cfg := markdown.Config{prose = my_font, link = proc(user: rawptr, url: string) { platform.open_url(url) }}
markdown.view(&doc, "note", text, cfg)              // at each build
markdown.doc_destroy(&doc)                          // when the text is no longer shown (none needed in an arena)
```

## The cache: a text is read when it changes

`Doc` keeps the blocks of the text it was given with where that text lies and how long it is. `view` (or `read`)
reads nothing when it is the same text; when it grew in its place (an answer that streams into its buffer) only its
last block is read again, from where it starts; any other text is read whole. Each block's joined text, its inline
runs, a code block's highlighted runs, a table's cells and its columns' widths are made once, and again only when what
they are made with changes (the colours, the faces, the sizes). So a long document costs nothing at each frame but its
boxes: no parse, no highlight, no measure.

The text is the program's: it must live, at the same place, as long as the doc shows it. A text that changes in its
place without growing (an edit) must be given at a new place or with another length, or the doc says it is the same.
`Doc.alloc` (zero: `context.allocator` at the first read) holds what the doc makes; `Doc.parses` counts the reads. A doc
once read does not move: the program keeps it where it made it (a `new` one in a map, a field).

| Procedure | What |
|---|---|
| `view(doc, id, src, cfg, size = 0)` | shows `src` in the current column; `id` keys its boxes; `size` the text's (0: the current one) |
| `read(doc, src)` | the blocks of `src`, read only when it changed |
| `block_lines(doc, n)`, `block_text(doc, n)` | a block's lines as written, its text as shown |
| `block_runs(doc, n, base, inline)` | its inline runs (`inline_runs` of its text), kept |
| `code_runs(doc, n, base)` | a code block's runs, its language (`syntax.language` of its fence's word) in the theme's colours (`ui.code_runs`), kept |
| `table_of(doc, n, header, body, inline)` | a table block's `Table`: its rows of runs, its columns' alignment, kept |
| `table_measure(t, rich_context, em, pad)` | the widths of its columns, measured only when the faces or sizes changed |
| `table_cell(t, row, col)`, `table_html(t)` | a cell's runs; the table as HTML for the clipboard (a plain grid that takes the style of where it is pasted) |
| `marker_widths(doc, measure, face, size, least, gap)`, `list_marker_widths(blocks, ...)` | the width of each list item's marker column: a list's numbers all as wide as its widest ("10.") |
| `inline_runs(text, base, &runs, inline)` | the inline Markdown of one text as `ui.Rich_Run`s (no copy of the text) |
| `doc_destroy(doc)` | frees what the doc holds |

## What the program decides: Config

Every field may stay zero.

| Field | What |
|---|---|
| `prose`, `face`, `mono` | the text's face, the tables', the code's (0: the current face, `prose`, `ui.mono_font`) |
| `prose_scale`, `line_ratio`, `cell_scale` | the text's size and the height of its lines, the tables' size, of the size `view` is given |
| `colors` | `Colors`: text, headings, quotes, list markers, a quote's rail, inline code, code, a table's header, frame, stripes, rule and scroll bar; alpha 0 takes the theme's (`text`, `weak text`, `accent`, `code_bg`, `well`) |
| `user` | what the procedures are given |
| `link(user, url)` | a link clicked or chosen with Enter (nil: links open nothing). The target is as written: a program checks it before it hands it to the system |
| `code(user, id, c: Code)` | a fenced block, built in its place: its language, text, highlighted runs, whether its fence closed, a version for `rich_paragraph`, its number among the fenced blocks (`fence`: a diagram laid out ahead is found by it) (a diagram, a header with a copy button). nil: `code_block` |
| `frame(user, box, kind)` | paints the box a table or a code block sits in (nil: its colour, rounded) |
| `rule(user, id)` | a rule (nil: `ui.hline`) |
| `table_corner(user, table, source, size)` | built in a table's top right corner while the pointer is on it, over its rows: a copy button (`table_html`, `source` its lines) |

## Tables

A table is the lines that start with `|`; a second row of `-` and `:` is its separator, and says each column's
alignment (`:--`, `:-:`, `--:`). Its first row is the header, under a rule; every other row is shaded. Each column is as
wide as its widest cell on one line, no wider than `TABLE_COL_MAX_EM` (its words wrap past it) and never narrower than
its longest word; a table wider than its place scrolls sideways (the wheel sideways or Shift+wheel, a bar under it, a
fade on the side that hides more).

## Lists and code

A list item's marker sits in a column as wide as the widest of its list and level, so the items' text stays in one
column. A code block that is still being written (no closing fence yet) is shown as it grows; `Code.closed` says when it
is done (a program draws a diagram only then).

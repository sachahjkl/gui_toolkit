# pdf: open, render and write PDF files

`gt:pdf` opens PDF files, renders their pages, and writes new files from pages a program arranges: turned, removed,
added, moved, imported from other files, with text stamped on top. The engine is hayro (pure Rust) in `native/pdf`,
built into the program: nothing ships beside it. The design and its refused alternatives:
[src/md/features/pdf.md](../src/md/features/pdf.md).

## Building it in

Give the program's `toolbox.Project` the feature `Pdf`. Its odin commands get `-define:GT_PDF=true`, `build_native`
builds the native library with the part `pdf`, and the notices name hayro and its crates (with the Foxit fonts it
embeds for the standard fonts). Without the define, `pdf.available()` is false and `pdf.open` says `.Unavailable`.

## The model

A document is the program's own list of `pdf.Page` values; the engine holds only the files (sources), which never
change.

```odin
src, err := pdf.open(bytes, password)          // .Password: ask for one and open again
pages := make([dynamic]pdf.Page)
for i in 0 ..< pdf.page_count(src) { append(&pages, pdf.Page{source = src, index = i}) }

pages[0].turns += 1                             // a quarter turn clockwise
ordered_remove(&pages, 2)                       // the undo keeps the value
inject_at(&pages, 1, pdf.Page{size = {595, 842}})   // a blank A4 page

bytes, ok := pdf.write(pages[:], base = src)   // the file: outlines, form and metadata of `src` kept
```

- `Page{source, index}`: page `index` of an open file. `Page{size}` with source 0: a blank page of `size` points.
- `turns`: quarter turns clockwise added to the page's own rotation. `shown_size(page)` gives the size it is shown at.
- `stamps`: text on the page (below).
- `write(pages, base)`: with `base`, the catalog of that source is kept (outlines, named destinations, the form, the
  structure tree, the page labels, the metadata); a reference to a page the list does not hold names nothing, so a
  removed page and its resources leave the file. Without `base` (an extract), a new file of the pages and their
  annotations. A written file is never encrypted.
- Pages of several sources mix in one list: `open` the other file and add its pages.
- `close(src)` when no list holds a page of it any more.

## Rendering

`render(page, width, height, layer)` gives `width × height` RGBA pixels on white: the page's shown size scaled to
them. Without `layer`, the page's own content only: no annotation, form widget or signature appearance (a reader that
opens a document without its interactive layer). With it, the annotations' appearances are drawn too; nothing is ever
interactive.

A page with stamps (or a blank one) is written alone and that file is rendered: the picture is what `write` makes.

## Stamps

```odin
stamp := pdf.Stamp{
	at = {72, 72},                       // top-left corner, points, the page as its source shows it, y down
	font = {family = .Serif, bold = true},
	size = 14,
	color = {20, 20, 20},
	background = {255, 240, 150, 255},   // alpha 0: none
	text = "Approved\n17 November",
}
box := pdf.stamp_size(stamp)            // its size before its turns, margins included
```

- The fonts are PDF's standard fonts (Helvetica, Times and Courier, each with bold and italic): every reader has
  them and nothing is embedded. Characters outside WinAnsi (Western European) are written as `?`.
- `turns`: the text's own quarter turns about its corner. A stamp placed while the page is shown turned by `k` takes
  `(4 - k) % 4`, so that it reads upright where it was put; it then turns with its page.

A signature in a font the program gives:

```odin
script, ok := pdf.font_add(#load("fonts/GreatVibes-Regular.ttf"))   // once, at the start; any thread
sig := pdf.Stamp{
	at = {360, 700}, face = script, size = 28, color = {20, 40, 140},
	text = "Camille Dupré",
	tilt = 4,                          // degrees, rising to the right
	weight = 25,                       // the outline stroked too, thousandths of the size: a heavier pen
	flourish = true,                   // a pen's stroke under it
	caption = "Paris, 19/11/2026",     // a smaller Helvetica line under it
}
```

- The file embeds the glyphs the stamps use (a subset) and their text stays copyable.
- `font_add` keeps the font for the process's life: give each file once.

## Shapes

```odin
frame := pdf.Shape{kind = .Rect, points = {{70, 60}, {300, 110}}, stroke = {220, 30, 30, 255}, width = 2}
mark  := pdf.Shape{kind = .Rect, points = {{72, 200}, {400, 214}}, fill = {255, 230, 0, 110}}   // a highlight
arrow := pdf.Shape{kind = .Arrow, points = {{50, 300}, {120, 260}}, stroke = {0, 0, 0, 255}, width = 2}
pen   := pdf.Shape{kind = .Ink, points = drawn[:], stroke = {29, 78, 216, 255}, width = 1.5}
page.shapes = {frame, mark, arrow, pen}
```

- `Rect` and `Ellipse` fill and outline the box of their two corners; `Line` and `Arrow` go from their first point to
  their second (the arrow's head there); `Ink` follows its points.
- `Outline` fills closed contours with its `fill`: a pen's ink from `gt:ink` (`ink.polygon`), its width changing along
  the stroke. A point `{NaN, NaN}` starts the next contour.
- Points are in points, in the page as its source shows it (before `turns`), y down, as a stamp's `at`.
- `stroke` and `fill`: alpha 0 for none. A colour less than opaque multiplies with the page, as a highlighter.
- The shapes are drawn under the stamps.

## Threads

Every procedure may run on any thread; none belongs on the interface's thread (a large file takes time to open,
render and write). A program renders and writes on its workers and posts the results.

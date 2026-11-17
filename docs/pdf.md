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

## Threads

Every procedure may run on any thread; none belongs on the interface's thread (a large file takes time to open,
render and write). A program renders and writes on its workers and posts the results.

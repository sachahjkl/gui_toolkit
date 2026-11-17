# PDF: show, arrange, stamp, write

`gt:pdf` opens PDF files, renders their pages, and writes a new PDF from pages arranged by a program: turned, removed,
added, imported, moved, with text stamped on top. feuille is its first program; classeur's preview is the next.

## The model

A document is not a mutable PDF. It is a list of pages, each a value:

- `source` and `index`: a page of an open file (a source), or a blank page of a given size (source 0).
- `turns`: quarter turns clockwise, added to the page's own `/Rotate`.
- `stamps`: text placed on the page (see Stamps).

A source is immutable: the bytes of a file, parsed once. Every edit is a change of the list, done by the program in
its own data. Undo keeps the old value; a removed page is a value kept by the undo, not a page parked in a scratch
document. Two engines' edits cannot disagree, as there is no engine state to edit.

`write(pages, base)` makes the file. It is the only place where a PDF is built, and rendering a page with stamps goes
through it (below): the picture is what the save writes.

Refused:

- Editing the parsed objects in place (PDFium's model): the engine then holds the document's truth, every edit needs
  an inverse in the engine, and a removed page needs a place to wait.
- An incremental update (new objects appended after the old file): a removed page stays in the file, readable by
  anyone. A person who removes a page means it gone.

## The engine

hayro (pure Rust: hayro-syntax reads, hayro-interpret and vello_cpu render), in `native/pdf`, a part of the toolkit's
one native library (feature `pdf`). Measured against PDFium on 37 hard files (feuille's bench, commit c98bd26):
pictures equal to the eye, 36 files of 37 opened, no page failed, 2.8 times faster. Refused:

- PDFium: a 6 MB shared library beside every program, global state fenced on one thread, C memory safety.
- MuPDF (AGPL), Poppler (GPL).
- lopdf beside hayro for the writing: two parsers of one file can disagree on what a page holds.

A source is shared between threads (`Arc`); its render cache is locked. A program can render from its task pool.
Every entry point catches panics: a page that fails is a page not shown, never a dead program.

## Writing

The writer walks the object graph from the roots and gives each object reached a new number. What is not reached is
not written: removed pages and their resources leave the file. Streams are copied as they are (their filters kept),
decrypted: a written file has no encryption and no restrictions.

- With a base (the source the person opened), its catalog is kept: outlines, named destinations, the form, the
  structure tree, the metadata, the page labels. Its `/Pages` is a new flat tree of the list.
- A reference to a page resolves to that page's new object when the list has it, and to `null` when it does not
  (an outline entry to a removed page goes nowhere; it does not bring the page back).
- Each page dictionary is written anew: its own keys, then the inherited ones made explicit (`/Resources`,
  `/MediaBox`, `/CropBox`), `/Rotate` with the turns, `/Parent` the new tree. Its annotations keep their `/P`, which
  now names the new page.
- Without a base (an extract, a new file), the catalog is new: the pages and their annotations, nothing of the
  documents they came from.
- The trailer's `/Info` is written from the base's metadata; the `/ID` is new.

## Stamps

A stamp is text on a page: its top-left corner in points, in the page as its source shows it (before the turns), its
lines, a font, a size, a colour, a background (transparent or a colour), and its own turns so that it reads upright
where it was placed. It turns with its page.

The fonts are the standard fonts of PDF: Helvetica, Times and Courier, each regular, bold, italic and bold italic.
Every reader has them, nothing is embedded, the file grows by a few hundred bytes. Their encoding is WinAnsi: the
characters of Western European languages; another character is written as `?`. The widths are Adobe's metrics
(`native/pdf/src/metrics.rs`, from hayro-font, MIT): `measure` and the writer use the same ones.

Refused for now: embedding a font of the system (any script). It needs subsetting and a Type 0 font with its
`ToUnicode`; it is the next step if a person asks for a script outside WinAnsi.

The page's content is wrapped: `q`, its streams, `Q`, then the stamps, so a page that leaves its graphics state
changed does not move them. Their font resources take names no page uses (`GtStamp…`).

A page with stamps is rendered by writing it alone as a PDF and rendering that: the same writer, the same picture.

## The layer

The render draws the page's own content. `layer` adds its annotations (form widgets, signatures' appearances, notes):
`RenderContent::ANNOTATIONS`. No form is ever interactive.

## The test that breaks it

A document whose outline points at page 2: remove page 2, write. The outline entry must be `null`, page 2's content
must not be in the file, and page 1's annotation's `/P` must name the new page 1. `native/pdf` tests it.

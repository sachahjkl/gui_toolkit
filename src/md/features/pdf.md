# PDF: show, arrange, stamp, write

`gt:pdf` opens PDF files, renders their pages, and writes a new PDF from pages arranged by a program: turned, removed,
added, imported, moved, with text stamped on top. feuille is its first program; classeur's preview is the next.

## The model

A document is not a mutable PDF. It is a list of pages, each a value:

- `source` and `index`: a page of an open file (a source), or a blank page of a given size (source 0).
- `quarters`: quarter turns clockwise, added to the page's own `/Rotate`.
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
  `/MediaBox`, `/CropBox`), `/Rotate` with the quarters, `/Parent` the new tree. Its annotations keep their `/P`, which
  now names the new page.
- Without a base (an extract, a new file), the catalog is new: the pages and their annotations, nothing of the
  documents they came from.
- The trailer's `/Info` is written from the base's metadata; the `/ID` is new.

## Stamps

A stamp is text on a page: its top-left corner in points, in the page as its source shows it (before the page's quarter turns), its
lines, a font, a size, a colour, a background (transparent or a colour), and its own quarters (quarter turns) so that it reads upright
where it was placed. It turns with its page.

The fonts are the standard fonts of PDF: Helvetica, Times and Courier, each regular, bold, italic and bold italic.
Every reader has them, nothing is embedded, the file grows by a few hundred bytes. Their encoding is WinAnsi: the
characters of Western European languages; another character is written as `?`. The widths are Adobe's metrics
(`native/pdf/src/metrics.rs`, from hayro-font, MIT): `measure` and the writer use the same ones.

A program can also give its own fonts (`font_add`: a signature's script fonts). The engine keeps each for the
process's life, by id: a program gives a few files once, and a page value names one by a number, cheap to copy. The
writer gathers the glyphs of every stamp of every page first, then embeds each font once as a subset of them
(`subsetter`, typst's), a Type 0 font with Identity-H codes (each code is its glyph's new id) and its `ToUnicode`, so
the text stays copyable. The subset's name has its tag of six capitals, from the glyphs it holds.

Refused: embedding the whole font (a script font is 50 to 450 kB, a signature uses twenty glyphs), and shaping
(ligatures, contextual forms): the stamp maps each character to its glyph. The script fonts a signature takes join
their letters by design without it.

The effects of a signature are a stamp's too: a tilt about its box's centre, a weight (the glyphs' outline stroked
over their fill, round joins: a heavier pen), a flourish (one cubic stroke under the text) and a caption (a smaller
Helvetica line: the place and the date). They are part of the stamp, not separate marks, so the signature moves,
turns and measures as one thing; `measure` gives the box with the tilt inside it.

The page's content is wrapped: `q`, its streams, `Q`, then the stamps, so a page that leaves its graphics state
changed does not move them. Their font resources take names no page uses (`GtStamp…`).

A page with stamps is rendered by writing it alone as a PDF and rendering that: the same writer, the same picture.

## Shapes

A shape is a mark on a page: a rectangle or an ellipse (a box, filled or outlined: to frame, to circle), a line, an
arrow, a free line (a pen). Like a stamp, it is part of its page's value, in the page as its source shows it, and it
turns with its page. The writer draws the shapes in the same added stream as the stamps, under them: a text written
in a box stays readable.

A colour less than opaque is laid over the page by multiplication (`/BM /Multiply`, the alpha in `/ca` and `/CA`):
a highlighter. Over black it stays black, over white it is its colour, so the words under it stay readable; an
ordinary blend would grey them. One graphics state per alpha used, named `GtAlpha<alpha>`.

A pen's ink (an Outline) is the exception: it is laid normally (`/BM /Normal`, `GtInk<alpha>`). gt:ink draws a
stroke as stacked levels whose alphas are computed for source over; multiplied, the levels came out a fifth darker,
and the PDF differed from the program's own drawing of the same ink. A translucent ink over printed words covers
them a little, as real ink does.

An outline is a pen's ink drawn as its shape, not as a stroke: closed contours filled with the non-zero rule, as
gt:ink computes them from the pointer's samples (its width changes with speed or pressure, its ends taper). A stroke
of PDF has one width, so it cannot draw a nib. A NaN point starts the next contour, so a signature's strokes are one
shape that moves as one.

Refused: annotations (`/Square`, `/Ink`, `/Highlight`). Readers draw them differently, some not at all when printing,
and a program that hides the annotation layer (feuille) would hide its own marks; and a person's mark is meant to be
part of the page.

## The layer

The render draws the page's own content. `layer` adds its annotations (form widgets, signatures' appearances, notes):
`RenderContent::ANNOTATIONS`. No form is ever interactive.

## The test that breaks it

A document whose outline points at page 2: remove page 2, write. The outline entry must be `null`, page 2's content
must not be in the file, and page 1's annotation's `/P` must name the new page 1. `native/pdf` tests it.

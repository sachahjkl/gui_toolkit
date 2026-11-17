# Printing (`src/platform/print.odin`)

Two calls, each through the system's print dialog: `print_image` prints one picture on one page; `print_document`
prints a document of several pages, with the page range and the copies chosen in the dialog. Both block until the
person is done and the system has the pages: call them on a worker or a chore (`ui.task`), never on the interface's
thread, and post the status back.

## A picture

One page, one picture: the person chooses the printer, the paper and the copies; the picture is laid on the page at its
natural size, made smaller to fit, never larger, and centred.

```odin
// on a worker or the chores: the call waits for the person, then for the system to take the page
status := platform.print_image(owner_window, "Screenshot", rgba, {width, height})
switch status {
case .Printed:     // the system has the page
case .Cancelled:   // the person closed the dialog
case .Unsupported: // no print dialog here (Linux: no print portal, or a bus that cannot pass a file)
case .Failed:      // the dialog or the printer refused
}
```

| procedure | what |
|---|---|
| `print_image(owner, title, rgba, size) -> Print_Status` | the dialog, then the page. Blocks: never on the interface's thread |
| `print_fit(picture, page, margin, units_per_inch) -> (x, y, w, h)` | where the picture goes: `PRINT_PICTURE_DPI` (96) of its pixels an inch, smaller to fit inside the margins, centred; from the top left. Pure |
| `print_pdf(rgba, size, page, margin) -> []u8` | a one-page PDF of `page` points showing the picture as `print_fit` places it, its pixels deflated (lossless). Pure |

The picture is straight RGBA; its alpha is laid over white, since paper has no transparency.

## A document

The program describes its pages; the toolkit asks for each one when the printer needs it.

```odin
doc := platform.Print_Document{
	title      = "Report.pdf",
	page_count = n,
	user       = engine,
	page_size  = proc(user: rawptr, page: int) -> [2]f64 { /* the page's width and height in points */ },
	render     = proc(user: rawptr, page: int, size: [2]int, rows: [2]int, out: []u8) -> bool {
		// draw the page at size pixels; write only its rows rows[0] ..< rows[1] into out (RGBA, from the top)
	},
	pdf        = file_bytes,   // optional: the document as a PDF file
}
// on a worker: the dialog, then the job
status := platform.print_document(owner_window, doc)
```

| procedure | what |
|---|---|
| `print_document(owner, doc) -> Print_Status` | the dialog (page range, copies), then every page chosen. Blocks: never on the interface's thread |
| `print_page_fit(page, paper, offset, area, dpi) -> (x, y, w, h)` | where a page of `page` points goes on a printer's sheet, in dots from the top left of its printable area: its natural size, smaller to fit, never larger, centred on the sheet when it fits. Pure |
| `print_document_pdf(doc, out, dpi = PRINT_DOCUMENT_DPI) -> bool` | the document as a PDF of pictures written to an `io.Writer` as the pages are rendered: each page at its size in points, its pixels deflated. Pure but for the callbacks |
| `print_band_rows(width) -> int` | the rows of a page `width` pixels wide that `render` is asked for at once (`PRINT_BAND_BYTES`, 64 MiB of RGBA) |

- `page_size` and `render` run on the thread that called `print_document`, never on the interface's thread. They must
  be safe there for the program's engine, and the document must stay open until the call returns.
- `render` gets the size of the whole page and the band of rows to draw: `out` holds exactly
  `(rows[1] - rows[0]) * size.x * 4` bytes, set to white. A band keeps the memory bounded at a printer's resolution
  (A4 at 600 dots an inch is three bands). False stops the job: `Failed`.
- `pdf` is used on Linux only: the portal then prints the program's own file and the printer gets vectors. Windows
  always renders. Without `pdf`, `page_size` and `render` are needed everywhere.
- Pages count from 0. The dialog shows them from 1.

## Each system

- **Linux**: the XDG print portal (`org.freedesktop.portal.Print`), on a connection of its own on the calling thread.
  `PreparePrint` shows the dialog and answers on its request's `Response` with a token and the page setup (the paper's
  width and height in millimetres, its margins, its orientation); `Print` then gets the file in a memory file
  (`memfd_create`) passed as a descriptor (gt:dbus `call_with_fds`), with that token: no second dialog.
  - A picture: the page as a PDF (`print_pdf`); A4 with 12 mm margins when the portal says nothing of the page.
  - A document: `pdf` as it is, else `print_document_pdf` at 300 dots an inch, written into the memory file as the
    pages are rendered. The pages keep their own sizes; the print system fits them to its paper and applies the range
    and the copies chosen in its dialog.
- **Windows**: GDI on the printer's device context.
  - A picture: the common Print dialog (`PrintDlgW`, modal to `owner`), the picture drawn with `StretchDIBits`
    (halftone) in the printable area, at the printer's `LOGPIXELSX`.
  - A document: the common Print dialog with its page range and copies (`PrintDlgExW`). Each page chosen is rendered
    at the printer's resolution (`LOGPIXELSX`, `LOGPIXELSY`), placed by `print_page_fit` from the sheet's size, the
    printable area and its offset, and drawn a band at a time, one pixel a dot. The copies are the driver's when it
    can make them, else the toolkit prints them, collated or not as the dialog says. Each page turns the sheet to its
    own orientation (`ResetDCW`) when the driver allows it.
- **Other systems**: `Unsupported`.

## Limits

No preview; no scaling, no pages per sheet, no position chosen in the dialog (the page setup's paper and orientation
are used for a picture on Linux, the printer's on Windows); no colour management. On Windows a document's pages are
pictures at the printer's resolution, never vectors; the dialog's "Current page" and "Selection" are not offered. On
Linux, the page range and the copies are the print system's work: the portal's dialog offers them and the file holds
every page.

## Tests

`tests/print`: a small picture keeps its natural size, centred; a large one shrinks to the margins with its ratio; no
pixel or no room gives nothing; the PDF has one page of the size asked, a cross-reference table whose offsets are its
objects', and its pixels inflate back to RGB with the alpha over white. A document's page keeps its size centred on the
sheet, a large one shrinks into the printable area with its ratio, each axis takes its own resolution; a document of two
pages becomes a PDF with two `/Page` objects of their sizes, every row rendered once, correct offsets, and its pixels
inflate back. The dialog needs a person: it is never shown, and nothing goes to a printer. gt:dbus's own test passes a
descriptor over a socket pair (`a_descriptor_goes_with_its_call`). `odin run tools/run_tests -- print`.

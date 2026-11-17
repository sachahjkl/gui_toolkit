# Printing a document

`platform.print_document` prints a document of several pages through the system's print dialog, with its page range
and copies. The first user is feuille, a PDF reader; any program that shows pages (a report, an invoice) can use it.
How to call it: [docs/printing.md](../../../docs/printing.md).

## Decisions

- **The program draws, the toolkit prints.** The toolkit knows no document format. A document is a page count, a size
  in points per page and a render callback. A PDF engine, a layout engine or a canvas all fit that shape.
- **A blocking call, as `print_image`.** The call waits for the person, then for the job. The program runs it on a
  worker or a chore and posts the status back. A callback for the result and a thread of the toolkit's own were
  refused: they add a second way to run work off the interface's thread, and the package's other dialogs block too.
- **The callbacks run on the printing thread.** That thread is the caller's, not the interface's: rendering a page
  at 600 dots an inch takes seconds. So the program's engine must accept calls from that thread while the interface
  goes on (feuille's engine owns a worker and is thread-safe).
- **Render a band of rows, not a page.** A Letter page at 1200 dots an inch is 538 MB of RGBA. The callback gets the
  whole page's size and the rows to draw, so memory stays at `PRINT_BAND_BYTES` (64 MiB) whatever the resolution.
  PDFium draws a band directly (a bitmap of the band, the page offset upward). A whole page per call, a tiling in
  two dimensions, and a pixel-format choice were refused: rows are enough for both systems, and RGBA is the toolkit's
  format everywhere.
- **The program's PDF, when it has one.** The Linux portal prints a PDF file. Sending the original gives the printer
  vectors and fonts: sharper, smaller, faster. Pictures of the pages are the fallback for a program with no PDF.
- **No PDF on Windows.** GDI does not take a PDF, and the "Microsoft Print to PDF" path is a printer, not an input.
  Each page is rendered at the printer's own resolution and drawn one pixel a dot, so nothing is resampled.
- **The page keeps its size.** A page is laid at its natural size, made smaller only to fit the printable area,
  never larger, and centred on the sheet (not on the printable area, whose margins are often uneven). This is what
  the person expects from "Actual size"; the "Fit" and "Pages per sheet" choices of other readers are not offered.
- **Each page turns the sheet.** A landscape page on a portrait sheet would shrink to less than half its area. On
  Windows each page sets the orientation of its sheet (`ResetDCW` between pages), when the driver says it can.
  Rotating the pixels was refused: it doubles the memory of a band and does not work a band at a time.
- **The copies: the driver's first.** With `PD_USEDEVMODECOPIESANDCOLLATE`, a driver that makes copies returns one
  copy to print; else the toolkit prints the copies itself in the order `PD_COLLATE` says.

## Subtle points

- On Linux, the PDF is made after the dialog, not before: a person who cancels costs nothing. It is written to the
  memory file as it is made: memory holds one band, never the whole document.
- On Linux the page range and copies chosen in the portal's dialog are applied by the print system (CUPS), not by
  the toolkit: the file always holds every page.
- The PDF of pictures lays the bands of a page edge to edge, one image each. One image per page was refused: it needs
  the whole page in memory to deflate it as one stream.
- `PrintDlgExW` refuses no owner: with no window the desktop is the owner. It shows a property sheet, which needs COM
  on the thread; a thread already in another apartment keeps it.
- Every band starts white: a renderer that draws nothing (an empty page) leaves paper, not the last band's pixels.

## Refused

- A preview in the toolkit: a reader already shows its pages.
- PostScript for the portal: PDF is what both GTK's and KDE's portals take first.
- An asynchronous job API (progress, cancel from the program): the system's queue already shows and cancels a job.

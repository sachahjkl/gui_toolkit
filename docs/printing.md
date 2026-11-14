# Printing a picture (`src/platform/print.odin`)

One page, one picture, through the system's print dialog: the person chooses the printer, the paper and the copies;
the picture is laid on the page at its natural size, made smaller to fit, never larger, and centred.

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

## Each system

- **Linux**: the XDG print portal (`org.freedesktop.portal.Print`), on a connection of its own on the calling thread.
  `PreparePrint` shows the dialog and answers on its request's `Response` with a token and the page setup (the paper's
  width and height in millimetres, its margins, its orientation); `Print` then gets the page as a PDF (`print_pdf`), in
  a memory file (`memfd_create`) passed as a descriptor (gt:dbus `call_with_fds`), with that token: no second dialog.
  The page is A4 with 12 mm margins when the portal says nothing of it.
- **Windows**: the common Print dialog (`PrintDlgW`, modal to `owner`), then GDI on the printer's device context: the
  picture drawn with `StretchDIBits` (halftone) in the printable area, at the printer's `LOGPIXELSX`.
- **Other systems**: `Unsupported`.

## Limits

One page; no preview, no scaling or position chosen in the dialog (the page setup's paper and orientation are used on
Linux, the printer's on Windows); no colour management.

## Tests

`tests/print`: a small picture keeps its natural size, centred; a large one shrinks to the margins with its ratio; no
pixel or no room gives nothing; the PDF has one page of the size asked, a cross-reference table whose offsets are its
objects', and its pixels inflate back to RGB with the alpha over white. The dialog needs a person: it is never shown.
gt:dbus's own test passes a descriptor over a socket pair (`a_descriptor_goes_with_its_call`).
`odin run tools/run_tests -- print`.

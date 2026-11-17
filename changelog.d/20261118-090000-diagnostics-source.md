type: Changed

**`Page_Options.diagnostics` is a `prefs_page.Diagnostics_Source`, so a program with a loop of its own shows the Diagnostics page.** The source is plain data: the renderer, the window, a `host.Frame_Ring` and whether partial redraw is on. A program on the host writes `diagnostics = prefs_page.diagnostics_of(&app.main)` in place of `&app.main`. `host.frame_add` records one picture in a ring, and `prefs_page.diagnostics_rows` gives the page's lines.

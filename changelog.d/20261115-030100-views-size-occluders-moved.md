type: Added

**Views: a size per opening, what floats over a view, `moved` at a direct opening**: `ui.view_size(v, width_em, height_em)` sizes this opening's dialog (a viewer hugs its picture, past the 46 em cap of a dialog sized by its words). `ui.view_occluders(v)` and `ui.views_floating_rects(vs, s)` give the rects of the floating windows and dialogs over a view, for a page with a native child window to step aside. A view that opens straight into a window of its own now gets `moved` too.

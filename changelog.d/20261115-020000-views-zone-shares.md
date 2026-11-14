type: Added

**Dock zones sized by a share of their space**: `View_Options.extent_frac` and `View_Dock_Options.extent_frac` / `extent_em` (per edge, also for `views_frame(vs, o)`) give a zone's size at first as a share of its space's width or height, so it follows the window's size. A zone the user resizes keeps its unit: a share stays a share in the memory (`left.frac=0.300`).

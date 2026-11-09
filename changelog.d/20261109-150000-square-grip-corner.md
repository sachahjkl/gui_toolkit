type: Changed

**A resize grip sits in a square corner**: a resizable dialog (`modal_sized`) and a floating dock panel keep their bottom right corner square, and their grip is a bevel cut across it in the theme's `resize_grip shade` (the border colour: darker on a light theme, lighter on a dark one), with its dots on it, clear of its edge. Boxes have `square_corners` (`ui.Corners`) for this; `ui.paint_rect_corners`, `ui.box_radii` and `ui.radii_grown` are new.

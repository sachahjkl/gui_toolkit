type: Added

**`ui.modal_header`, `ui.modal_corner`, `ui.corner_place`, `ui.concentric_radius`**: a control in a dialog's top right corner (a close button) is placed by the toolkit: the same margin from the dialog's top and right edges, its corners concentric with the dialog's (radius `max(R - m, 0)`), and the row across the dialog's top centered with it and kept clear of it. The grips of a resized dialog leave it its corner. `corner_place` places a control in any rounded corner by the same rule. The Setup dialog's close control is placed this way.

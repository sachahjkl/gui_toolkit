type: Fixed

**The mark editor's text field opens where you click**: in `ui.mark_editor_dialog`, or wherever the editor is not at
the window's top left, a click of the Text tool opened the field away from the click. The field now opens on the
clicked point at every zoom, its letters on the letters of the kept text, and it stays on its point while you zoom
or pan. Near the canvas's edge, the field stops at the edge and scrolls, so the caret stays seen.
`marks.to_canvas` gives a picture point from the canvas's top left.

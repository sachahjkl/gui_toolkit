type: Added

**A selection rectangle starts from the empty part of a row**: in a `ui.Table` of several with `rubber_band`, in Details and List, a drag from after the text or between the cells draws the rectangle; a click there selects when the button is let go, and the list keeps half a row of room at its end. Ctrl and a drag from a row's text start it too. A program with rows of its own takes `ui.List_State.pressed_empty` (or `ui.row_content_at`), `ui.item_band_row_press`, the `row_press` of `ui.item_band_update` and `ui.Virtual_List.end_space`.

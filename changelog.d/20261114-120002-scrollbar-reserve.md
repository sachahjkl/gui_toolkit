type: Added

**`.Scrollbar_Reserve`**: a box that scrolls keeps the room of its scroll bar even while its content fits, so a list that grows past its view does not narrow under the reader (`ui.next({flags = {.Scrollbar_Reserve}})` before `scroll_y`, `list`, `vlist`, `text_edit`). By default the room is kept only while the content overflows.

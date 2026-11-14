type: Added

**A program asks which view has the keyboard, and opens its panes at the first start**: `ui.view_has_focus(vs, id, instance)` and `ui.views_focus(vs)` say whether the focus is in a view, whatever its presentation. `ui.view_restore(vs, id, data, first_start_open)` opens a view at start-up when it was open at the last quit, or at the very first start when asked; a view the user closed stays closed. F6 and Shift+F6 between the areas of a window are now read last in a frame: a program that binds F6 itself keeps it, wherever it reads its keys.

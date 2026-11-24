type: Added

**`ui.File_Picker`**: the file picker as a component a program builds in its own layout (a side panel, an "Open" page, a docked view): `file_picker_init`, `file_picker(id, &p)` at each build, `file_picker_destroy`. A build returns `File_Picker_Events` (the answer, another folder, another selection); `file_picker_folder`, `file_picker_selected`, `file_picker_focus`, `file_picker_start` and `file_picker_stop` complete it. Several live at once; each reads the keyboard only with the focus in it.

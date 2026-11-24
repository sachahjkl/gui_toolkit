type: Changed

**`ui.file_dialog` is a picker in a view**: the same call and the same `done`, rebuilt over `ui.File_Picker`. `File_Dialog_Kind` moved to `platform`; `file_browser_counts(s)` is `file_picker_counts(file_dialog_picker(s))`; the `FILE_BROWSER_*` constants are `FILE_PICKER_*`, and the dialog's sizes `FILE_DIALOG_*_EM`; a source's `File_Reply` names its picker and its request (`picker`, `serial`) in place of `dialog`.

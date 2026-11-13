type: Changed

**`ui.shortcuts_sheet` keeps its list in a `Shortcuts_Sheet`**: `ui.shortcuts_sheet(id, commands, &open, title)` → `ui.shortcuts_sheet(&app.sheet, id, commands, title, version)` with `app.sheet.open`, and `ui.shortcuts_sheet_destroy(&app.sheet)` at the end. It lists the commands that have a key only when they change, and builds only the lines near its view.

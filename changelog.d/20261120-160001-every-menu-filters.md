type: Changed

**Every menu filters what is typed**: a menu bar's, a tool bar's, a drop-down's list, a view's menu, the file browser's row menu and a number field's menu now show the field at their top, as the context menus did: the items that do not match go, the first match is selected and Enter chooses it. A letter typed in an open submenu closes it and filters its menu. A drop-down still opens on its current value. Until something is typed, Space chooses the selected item. A panel opened as a menu with no item (a slider) has no field. No menu selects the next item starting with a typed letter any more: the filter's first match does it. For a program's author:
  - `menu_open` has no `search` parameter: remove `search = false` and `search = true`.
  - `Toolbar_Tool` has no `menu_search` field: remove `menu_search = false`.

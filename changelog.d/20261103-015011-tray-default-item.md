type: Fixed

**Tray menus** (Windows): the default item of a menu is shown in bold (`AppendMenuW` ignored `MF_DEFAULT`: it is set with `SetMenuDefaultItem`). `platform.tray_menu_build` makes the native menu of a model without showing it; `tests/tray` reads it back with `GetMenuItemInfoW` (separators, check and radio marks, the default item, a disabled one, a submenu, each command's id).

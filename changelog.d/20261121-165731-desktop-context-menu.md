type: Added

**Asynchronous system shell context menu (`gt:desktop`)**: `Context_Menu` (`context_menu_query`, `context_menu_invoke`, `context_menu_clear`, `context_menu_destroy`) queries and invokes third-party shell actions off the interface thread (Windows `IContextMenu` / `IContextMenu2` / `IContextMenu3` on a dedicated COM STA worker; Linux KIO service menus, Nemo actions, and Thunar `uca.xml`), with caller-supplied `exclude_verbs`, mnemonic stripping, and submenu/separator pruning.

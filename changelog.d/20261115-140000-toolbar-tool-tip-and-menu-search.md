type: Added

**A tool bar's tool takes its tooltip and its menu's search**: `ui.toolbar_tool(id, {..., tip = "Zoom"})` shows that tooltip whatever the tool shows, its words too (a zoom showing "100 %"). Without a `tip`, a tool with a command shows the command's tooltip. `menu_search = false` opens the tool's menu without a search field, where a typed letter selects an item (a menu of a few fixed choices); by default its menu searches, as every menu.

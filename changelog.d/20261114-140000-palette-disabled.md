type: Changed

**`ui.palette` and `ui.flow_palette` say which commands are `disabled`** (the same polarity as a button's and a menu item's): pass `disabled[i] = !can(i)`. `tile` and `title_strip` lose their unused `clickable` and `closable`; `Line_Graph_Opts` is `Line_Graph_Options`.

type: Added

**Lazy lists in a plugin's view (plugin API level 5)**: a `list` node shows up to a million rows and asks the plugin
only for those in view and a margin, as the person scrolls, with `row(i)`. A row not answered yet shows a placeholder,
a slow plugin leaves the window scrolling, and a new `version` asks the rows again. `plugins.list_info` and
`plugins.list_scroll_to` read and scroll such a list. A plugin's own key can no longer hold `~`.

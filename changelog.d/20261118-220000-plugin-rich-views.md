type: Added

**Rich views in plugins (plugin API level 6)**: a plugin's button, text, heading, field and switch take an `icon` by
its Lucide name; a text takes a `tone` (`info`, `good`, `warn`, `bad`, `weak`), `mono` for the monospace face and
`highlight` to mark what a search found in the find bar's colours; a new `badge` node shows a level, a state or a count
in its tone's colour. An unknown icon draws nothing and the plugin's log says it once. A program older than level 6
ignores these fields. The log explorer demo uses all of them.

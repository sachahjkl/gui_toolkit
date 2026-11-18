type: Added

**Plugins in the palette, the menus and the tool bar, in the person's language (plugin API level 7)**: a manifest's
`palette` declares a source under a prefix of the palette (`@`, `#`, `/`, or the plain search), which the plugin
answers with `palette.source(id, search, { onChoose })` as the person types, one query at a time, the newest waiting
and an older answer dropped; a source that does not answer leaves the palette working and says "not responding". Its
`menus` and `toolbar` put its commands in the places the program names (`Host_Options.menu_places`,
`plugins.menu_entries`, `plugins.toolbar_entries`, `plugins.toolbar_tool`), without running it. Its `l10n` translates
its manifest's words for the toolkit's language, and its code reads `context.language`. The log explorer demo searches
its lines under `@`.

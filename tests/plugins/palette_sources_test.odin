// Slice 7 (plugins.md, "As built: palette sources, menus, the tool bar, a plugin's languages"): a plugin's palette
// source answers the query typed after its prefix, a late answer for an older query is dropped, a source that never
// answers leaves the palette building, a choice reaches the plugin; its menu and tool bar entries come from its
// manifest, none while it is off, and run its command; its manifest's words in French when the toolkit's language is.
package plugins_test

import "core:testing"
import i18n "gt:i18n"
import lucide "gt:lucide"
import plugins "gt:plugins"
import "gt:testkit"
import "gt:testkit/session"

FINDER_MANIFEST :: `{
	"id": "finder", "name": "Finder", "api": 7, "main": "main.js",
	"commands": [{"id": "hello", "label": "Say hello"}, {"id": "bye", "label": "Say bye"}],
	"palette": [{"id": "lines", "label": "Lines", "prefix": "@"}],
	"menus": [{"command": "hello", "where": "file"}, {"command": "bye", "where": "edit"}, {"command": "hello", "where": "nowhere"}],
	"toolbar": [{"command": "hello", "icon": "search"}],
	"l10n": {"fr": {"Say hello": "Dire bonjour", "Lines": "Lignes"}}
}`

// A query that starts with "a" takes SLOW_MS (the next letter waits for it); "loop" never answers.
FINDER_MAIN :: `import { commands, palette, toast } from "gt";
const SLOW_MS = 150;
export function activate(context) {
	commands.on("hello", () => toast.show("hello " + context.language));
	commands.on("bye", () => toast.show("bye"));
	palette.source("lines", async (query) => {
		if (query === "loop") { for (;;) {} }
		if (query.startsWith("a")) { const t = Date.now(); while (Date.now() - t < SLOW_MS) {} }
		return [{ id: "row-" + query, label: "[" + query + "]", detail: "a line", icon: "file-text" }];
	}, { onChoose: (row) => toast.show("chose " + row.id + " " + row.detail) });
}
`

@(private = "file")
open_finder :: proc(t: ^testing.T) -> (s: ^session.Session, fx: ^Fx) {
	root := testkit.temp_folder(t, "plugin-palette")
	write_plugin(root, "finder", FINDER_MANIFEST, FINDER_MAIN)
	enable(root, "finder")
	fx = new(Fx)   // (freed by open's cleanup)
	s = open(t, fx, root, menu_places = {"file", "edit"})
	wait_started(s, fx, "finder")
	return
}

@(private = "file")
info_of :: proc(fx: ^Fx) -> plugins.Source_Info {
	info, _ := plugins.source_info(&fx.host, "finder", "lines")
	return info
}

@(test)
a_source_answers_the_query :: proc(t: ^testing.T) {
	s, fx := open_finder(t)
	fx.open_with = "@x"
	session.wait_text(s, "[x]", WAIT)
	testing.expect(t, session.find_text(s, "a line") != nil, "the row's detail")
}

@(test)
a_late_answer_for_an_older_query_is_dropped :: proc(t: ^testing.T) {
	s, fx := open_finder(t)
	fx.open_with = "@a"
	session.frame(s)
	// ("a" is in flight for SLOW_MS: "ab" waits for it, and goes when its answer comes)
	session.type_text(s, "b")
	session.wait_text(s, "[ab]", WAIT)
	testing.expect(t, session.find_text(s, "[a]") == nil, "the row of the older query is shown")
	info := info_of(fx)
	testing.expectf(t, info.asks == 2 && info.answered == 2, "asks %d, answered %d: the plugin was asked more than the two queries", info.asks, info.answered)
}

@(test)
a_slow_source_leaves_the_palette_building :: proc(t: ^testing.T) {
	s, fx := open_finder(t)
	fx.open_with = "@loop"
	session.wait_text(s, "Lines: reading…", WAIT)
	from := fx.builds
	session.wait_until(s, Count{fx, from + MORE_BUILDS}, proc(s: ^session.Session, c: Count) -> bool { return c.fx.builds >= c.at }, "30 more builds", WAIT)
	session.wait_text(s, "could not read (not responding)", WAIT)
	plugins.stop(&fx.host, "finder")
	wait_state(s, fx, "finder", .Ready)
}

@(test)
choosing_a_row_reaches_the_plugin :: proc(t: ^testing.T) {
	s, fx := open_finder(t)
	fx.open_with = "@x"
	session.wait_text(s, "[x]", WAIT)
	toasts := fx.host.toasts
	session.key(s, .Return)
	session.wait_until(s, Count{fx, toasts + 1}, answered, "the choice's toast", WAIT)
	testing.expect_value(t, fx.host.last_toast, "chose row-x a line")
}

@(test)
menu_and_tool_bar_entries_come_from_the_manifest :: proc(t: ^testing.T) {
	s, fx := open_finder(t)
	file := plugins.menu_entries(&fx.host, "file")
	if testing.expect_value(t, len(file), 1) {
		testing.expect_value(t, file[0].command, "plugin.finder.hello")
		testing.expect_value(t, file[0].label, "Say hello")
	}
	testing.expect_value(t, len(plugins.menu_entries(&fx.host, "edit")), 1)
	testing.expect_value(t, len(plugins.menu_entries(&fx.host, "nowhere")), 0)   // (a place the program does not name)
	tools := plugins.toolbar_entries(&fx.host)
	if testing.expect_value(t, len(tools), 1) {
		testing.expect_value(t, tools[0].icon, lucide.SEARCH)
		testing.expect_value(t, plugins.toolbar_tool(tools[0]).label, "Say hello")
		// (choosing it runs its command, which starts the plugin)
		toasts := fx.host.toasts
		testing.expect(t, plugins.run_command(&fx.host, tools[0].command), "the entry's command did not run")
		session.wait_until(s, Count{fx, toasts + 1}, answered, "the command's toast", WAIT)
		testing.expect_value(t, fx.host.last_toast, "hello en")
	}
	plugins.set_enabled(&fx.host, "finder", false)
	wait_state(s, fx, "finder", .Off)
	testing.expect_value(t, len(plugins.menu_entries(&fx.host, "file")), 0)
	testing.expect_value(t, len(plugins.toolbar_entries(&fx.host)), 0)
}

@(test)
the_manifests_words_in_the_persons_language :: proc(t: ^testing.T) {
	s, fx := open_finder(t)
	l, _ := i18n.load("fr", {})
	defer { i18n.use(nil); i18n.destroy(l) }
	if !testing.expect(t, l != nil, "the toolkit has no French") { return }
	i18n.use(l)
	session.frame(s)
	file := plugins.menu_entries(&fx.host, "file")
	if testing.expect_value(t, len(file), 1) { testing.expect_value(t, file[0].label, "Dire bonjour") }
	// (a text the manifest does not translate: its English)
	edit := plugins.menu_entries(&fx.host, "edit")
	if testing.expect_value(t, len(edit), 1) { testing.expect_value(t, edit[0].label, "Say bye") }
	// the plugin's code reads the language in its context
	toasts := fx.host.toasts
	testing.expect(t, plugins.run_command(&fx.host, "plugin.finder.hello"), "the command did not run")
	session.wait_until(s, Count{fx, toasts + 1}, answered, "the command's toast", WAIT)
	testing.expect_value(t, fx.host.last_toast, "hello fr")
	// the palette's source under its French label (its "reading…" row is the toolkit's, in French)
	fx.open_with = "@loop"
	session.wait_text(s, "Lignes", WAIT)
	plugins.stop(&fx.host, "finder")
}

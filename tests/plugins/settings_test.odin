// A plugin's settings (plugins.md, slice 2): the manifest's settings registered as the program's preferences, read by
// settings.get without waiting, and a change in the program's settings heard by settings.onChange and shown by the
// plugin's view at once.
package plugins_test

import "core:testing"
import config "gt:config"
import i18n "gt:i18n"
import plugins "gt:plugins"
import "gt:testkit"
import "gt:testkit/session"

GREETER_MANIFEST :: `{
	"id": "greeter", "name": "Greeter", "api": 3, "main": "main.js",
	"views": [{"id": "main", "title": "Greeter"}],
	"settings": [
		{"id": "greeting", "title": "Greeting", "kind": "string", "default": "Hello"},
		{"id": "times", "title": "Times", "kind": "int", "default": 2, "min": 1, "max": 5}
	]
}`

GREETER_MAIN :: `import { settings, views } from "gt";
let last = "nothing changed";
export function activate() {
	views.register("main", () => ({ kind: "column", children: [
		{ kind: "text", key: "greeting", text: settings.get("greeting") + " x" + settings.get("times") },
		{ kind: "text", key: "last", text: last },
	] }));
	settings.onChange((id, value) => { last = id + "=" + value; });
}
`

@(test)
a_plugin_reads_its_settings_and_hears_their_changes :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "plugin-settings")
	write_plugin(root, "greeter", GREETER_MANIFEST, GREETER_MAIN)
	enable(root, "greeter")
	fx := new(Fx)   // (freed by open's cleanup)
	s := open(t, fx, root)
	testing.expect(t, config.ref_of(&fx.prefs, "plugins.greeter.greeting") != config.NO_REF, "the setting is not one of the program's preferences")
	pages := plugins.settings_pages(&fx.host)
	if testing.expect_value(t, len(pages), 1) {
		testing.expect_value(t, pages[0].title, "Greeter")
		testing.expect_value(t, len(pages[0].names), 2)
	}
	wait_started(s, fx, "greeter")
	fx.open_view = {"greeter", "main"}
	session.wait_text(s, "Hello x2", WAIT)
	testing.expect_value(t, config.set_string(&fx.prefs, "plugins.greeter.greeting", "Hi"), config.Set_Error.None)
	session.wait_text(s, "Hi x2", WAIT)
	session.wait_text(s, "greeting=Hi", WAIT)
	testing.expect_value(t, config.set_int(&fx.prefs, "plugins.greeter.times", 9), config.Set_Error.Out_Of_Range)
}

GREETER_L10N_MANIFEST :: `{
	"id": "greeter", "name": "Greeter", "api": 7, "main": "main.js",
	"views": [{"id": "main", "title": "Greeter"}],
	"settings": [
		{"id": "greeting", "title": "Greeting", "description": "What it says first.", "kind": "string", "default": "Hello"},
		{"id": "times", "title": "Times", "kind": "int", "default": 2, "min": 1, "max": 5}
	],
	"l10n": {"fr": {"Greeting": "Salutation", "What it says first.": "Ce qu'il dit d'abord."}}
}`

@(private = "file")
def_of :: proc(fx: ^Fx, name: string) -> config.Def {
	r := config.ref_of(&fx.prefs, name)
	if r == config.NO_REF { return {} }
	return config.entry(&fx.prefs, r).def
}

// The settings' titles follow a change of language at the next build: no reload, no restart of the plugin's process,
// and back again.
@(test)
the_settings_titles_follow_the_language :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "plugin-settings-l10n")
	write_plugin(root, "greeter", GREETER_L10N_MANIFEST, GREETER_MAIN)
	enable(root, "greeter")
	fx := new(Fx)   // (freed by open's cleanup)
	s := open(t, fx, root)
	testing.expect_value(t, def_of(fx, "plugins.greeter.greeting").title, "Greeting")
	wait_started(s, fx, "greeter")
	p := plugins.find(&fx.host, "greeter")
	testing.expectf(t, p.state == .Running, "started: %v (%s)", p.state, p.failure)
	process := p.serial
	l, _ := i18n.load("fr", {})
	defer { i18n.use(nil); i18n.destroy(l) }
	if !testing.expect(t, l != nil, "the toolkit has no French") { return }
	i18n.use(l)
	session.frame(s)
	d := def_of(fx, "plugins.greeter.greeting")
	testing.expect_value(t, d.title, "Salutation")
	testing.expect_value(t, d.description, "Ce qu'il dit d'abord.")
	testing.expect_value(t, def_of(fx, "plugins.greeter.times").title, "Times")   // (not translated: its English)
	testing.expect_value(t, p.serial, process)   // (the same process: no reload, no restart)
	testing.expectf(t, p.state == .Running, "after the change: %v (%s)", p.state, p.failure)
	i18n.use(nil)
	session.frame(s)
	testing.expect_value(t, def_of(fx, "plugins.greeter.greeting").title, "Greeting")
	testing.expect_value(t, def_of(fx, "plugins.greeter.greeting").description, "What it says first.")
}

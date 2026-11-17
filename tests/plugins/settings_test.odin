// A plugin's settings (plugins.md, slice 2): the manifest's settings registered as the program's preferences, read by
// settings.get without waiting, and a change in the program's settings heard by settings.onChange and shown by the
// plugin's view at once.
package plugins_test

import "core:testing"
import config "gt:config"
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
	fx.open_view = {"greeter", "main"}
	session.wait_text(s, "Hello x2", WAIT)
	testing.expect_value(t, config.set_string(&fx.prefs, "plugins.greeter.greeting", "Hi"), config.Set_Error.None)
	session.wait_text(s, "Hi x2", WAIT)
	session.wait_text(s, "greeting=Hi", WAIT)
	testing.expect_value(t, config.set_int(&fx.prefs, "plugins.greeter.times", 9), config.Set_Error.Out_Of_Range)
}

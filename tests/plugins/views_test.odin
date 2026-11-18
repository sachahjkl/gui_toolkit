// A plugin's view (plugins.md, decision 2, slice 4): its render's tree replayed in the window as the toolkit's widgets,
// a click sent back and the view rendered again, a field typed while the plugin is slow that keeps what was typed, a
// key given twice dropped and said in the plugin's log, and a handler that never returns while the window builds on.
package plugins_test

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import plugins "gt:plugins"
import "gt:testkit"
import "gt:testkit/session"

COUNTER_MANIFEST :: `{
	"id": "counter", "name": "Counter", "api": 2, "main": "main.js",
	"views": [{"id": "main", "title": "Counter", "place": "internal"}]
}`

// The field's handler takes SLOW_MS: the person types faster than the plugin hears.
COUNTER_MAIN :: `import { views } from "gt";
let count = 0, name = "";
const SLOW_MS = 120;
export function activate() {
	views.register("main", () => ({ kind: "column", children: [
		{ kind: "heading", text: "Counter" },
		{ kind: "text", key: "count", text: "Count: " + count },
		{ kind: "row", children: [
			{ kind: "button", key: "add", label: "Add", intent: "primary", onClick: () => { count += 1; } },
			{ kind: "button", key: "hang", label: "Hang", onClick: () => { for (;;) {} } },
			{ kind: "check", key: "agree", label: "Checked in a row", checked: false, onChange: () => {} },
			{ kind: "button", key: "quiet", label: "Open", look: "ghost", size: "small", onClick: () => { count += 10; } },
		] },
		{ kind: "field", key: "name", value: name, placeholder: "Your name", onChange: (v) => {
			const t = Date.now(); while (Date.now() - t < SLOW_MS) {}
			name = v;
		} },
		{ kind: "text", key: "twice", text: "the first" },
		{ kind: "text", key: "twice", text: "the second" },
		count > 0 && { kind: "text", key: "more", text: "More than none" },
	] }));
}
`

open_counter :: proc(t: ^testing.T) -> (s: ^session.Session, fx: ^Fx, root: string) {
	root = testkit.temp_folder(t, "plugin-views")
	write_plugin(root, "counter", COUNTER_MANIFEST, COUNTER_MAIN)
	enable(root, "counter")
	fx = new(Fx)   // (freed by open's cleanup)
	s = open(t, fx, root)
	wait_started(s, fx, "counter")
	fx.open_view = {"counter", "main"}
	session.wait_text(s, "Count: 0", WAIT)
	return
}

@(test)
a_view_is_built_and_a_click_renders_it_again :: proc(t: ^testing.T) {
	s, fx, root := open_counter(t)
	keys := plugins.view_keys(&fx.host, "counter", "main")
	testing.expectf(t, slice.contains(keys, "add") && slice.contains(keys, "count"), "the list's keys: %v", keys)
	testing.expect(t, session.find_text(s, "More than none") == nil, "a false child was built")
	// a check box in a row shows its label (given the size of its own text, which it has none of, its label had no room)
	if label := session.find_text(s, "Checked in a row"); testing.expect(t, label != nil, "the check box's label is not built") {
		testing.expectf(t, label.rect.max.x - label.rect.min.x > 40, "the check box's label is %v wide", label.rect.max.x - label.rect.min.x)
	}
	// a ghost, small button: lower than a medium one, and clicked as any
	quiet, add := session.get(s, "pv:quiet"), session.get(s, "pv:add")
	testing.expectf(t, quiet.rect.max.y - quiet.rect.min.y < add.rect.max.y - add.rect.min.y, "the small button is %v high, the medium %v", quiet.rect.max.y - quiet.rect.min.y, add.rect.max.y - add.rect.min.y)
	session.click(s, "pv:quiet")
	session.wait_text(s, "Count: 10", WAIT)
	session.click(s, "pv:add")
	session.wait_text(s, "Count: 11", WAIT)
	session.wait_text(s, "More than none", WAIT)

	// a key given twice: the second node is dropped, and the plugin's log says so
	testing.expect(t, session.find_text(s, "the first") != nil, "the first node of the key is not shown")
	testing.expect(t, session.find_text(s, "the second") == nil, "the second node of a key given twice is shown")
	session.wait_until(s, root, proc(s: ^session.Session, root: string) -> bool {
		data, err := os.read_entire_file(fmt.tprintf("%s/state/counter.log", root), context.temp_allocator)
		return err == nil && strings.contains(string(data), "the key \"twice\" is twice in the view")
	}, "the log of the key given twice", WAIT)
}

@(test)
a_field_keeps_what_is_typed_while_the_plugin_is_slow :: proc(t: ^testing.T) {
	s, fx, _ := open_counter(t)
	session.click(s, "pv:name")
	session.type_text(s, "abc")
	// each change takes the plugin SLOW_MS: its renders of "a" and "ab" come after "abc" was typed, and must not
	// put them back in the field
	session.wait_until(s, fx, proc(s: ^session.Session, fx: ^Fx) -> bool {
		shown, rendered, ok := plugins.view_field(&fx.host, "counter", "main", "name")
		if ok && shown != "abc" { session.failed(s, fmt.tprintf("the field shows \"%s\" while the plugin catches up", shown)) }
		return ok && rendered == "abc"
	}, "the plugin's render of the whole text", WAIT)
	shown, _, _ := plugins.view_field(&fx.host, "counter", "main", "name")
	testing.expect_value(t, shown, "abc")
}

// gt-runtime's way: one lone file, its manifest implied (its name, one view "main"), on from the start, its view built
// in the window's own layout.
@(test)
a_lone_file_runs_with_an_implied_manifest :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "plugin-single")
	file := fmt.tprintf("%s/My Counter.js", root)
	_ = os.write_entire_file(file, transmute([]u8)string(COUNTER_MAIN))
	fx := new(Fx)   // (freed by open's cleanup)
	s := open(t, fx, root, single = file)
	list := plugins.host_plugins(&fx.host)
	if !testing.expect_value(t, len(list), 1) { return }
	p := list[0]
	testing.expect_value(t, p.manifest.id, "my-counter")
	testing.expect_value(t, p.manifest.name, "My Counter")
	testing.expect_value(t, p.state, plugins.Plugin_State.Ready)
	fx.body = {"my-counter", "main"}
	session.wait_text(s, "Count: 0", WAIT)
	session.click(s, "pv:add")
	session.wait_text(s, "Count: 1", WAIT)
}

@(test)
a_handler_that_never_returns_leaves_the_window_building :: proc(t: ^testing.T) {
	s, fx, _ := open_counter(t)
	session.click(s, "pv:add")
	session.wait_text(s, "Count: 1", WAIT)
	session.click(s, "pv:hang")
	from := fx.builds
	session.wait_until(s, Count{fx, from + MORE_BUILDS}, proc(s: ^session.Session, c: Count) -> bool { return c.fx.builds >= c.at }, "30 more builds", WAIT)
	wait_state(s, fx, "counter", .Not_Responding)
	session.wait_text(s, "Not responding.", WAIT)
	session.click(s, "pv_status_act")   // (the view's Stop)
	wait_state(s, fx, "counter", .Ready)
	// the last list stays ("Count: 1"), and the view offers to start the plugin again: a new runtime renders it from
	// the start
	session.wait_text(s, "Stopped.", WAIT)
	testing.expect(t, session.find_text(s, "Count: 1") != nil, "the last list is gone after the stop")
	session.click(s, "pv_status_act")
	session.wait_text(s, "Count: 0", WAIT)
	wait_state(s, fx, "counter", .Running)
}

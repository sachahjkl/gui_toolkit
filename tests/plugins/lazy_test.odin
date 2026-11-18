// Lazy lists (plugins.md, "As built: lazy lists"): a list of 100 000 rows asks the plugin's process only for the rows
// in view and a margin; a scroll asks the new range and lets go of the old one; an answer for an older version is
// dropped; a plugin whose rows never come leaves the window building and scrolling, with placeholders.
package plugins_test

import "core:testing"
import plugins "gt:plugins"
import "gt:testkit"
import "gt:testkit/session"

LAZY_MANIFEST :: `{
	"id": "lazy", "name": "Lazy", "api": 5, "main": "main.js",
	"views": [{"id": "main", "title": "Rows", "place": "internal"}],
	"commands": [{"id": "bump"}, {"id": "hang"}]
}`

// `bump` takes BUMP_MS before it changes the version: an ask the window sends meanwhile waits behind it, and is
// answered for the version that is gone by then.
LAZY_MAIN :: `import { commands, views } from "gt";
let version = 1, hang = false;
const BUMP_MS = 4000;
export function activate() {
	commands.on("bump", () => {
		const t = Date.now(); while (Date.now() - t < BUMP_MS) {}
		version += 1;
		views.update("main");
	});
	commands.on("hang", () => { hang = true; version += 1; views.update("main"); });
	views.register("main", () => ({ kind: "column", children: [
		{ kind: "text", key: "title", text: "Rows v" + version },
		{ kind: "list", key: "rows", count: 100000, version, visibleRows: 10, rowHeight: 2, row: (i) => {
			if (hang) { for (;;) {} }
			return { kind: "row", children: [{ kind: "text", text: "row " + i + " v" + version }] };
		} },
	] }));
}
`

LAZY_COUNT :: 100_000

@(private = "file")
open_lazy :: proc(t: ^testing.T) -> (s: ^session.Session, fx: ^Fx) {
	root := testkit.temp_folder(t, "plugin-lazy")
	write_plugin(root, "lazy", LAZY_MANIFEST, LAZY_MAIN)
	enable(root, "lazy")
	fx = new(Fx)   // (freed by open's cleanup)
	s = open(t, fx, root)
	wait_started(s, fx, "lazy")
	fx.open_view = {"lazy", "main"}
	session.wait_text(s, "row 0 v1", WAIT)
	// (the view's window takes its content's height as it comes: a scroll before it settles can miss its list)
	session.wait_idle(s, WAIT)
	return
}

@(private = "file")
info_of :: proc(fx: ^Fx) -> plugins.List_Info {
	info, _ := plugins.list_info(&fx.host, "lazy", "main", "rows")
	return info
}

// No ask waits, and every row built is answered.
@(private = "file")
settled :: proc(s: ^session.Session, fx: ^Fx) -> bool {
	info, ok := plugins.list_info(&fx.host, "lazy", "main", "rows")
	return ok && !info.waiting && info.answered >= info.shown_to - info.shown_from
}

@(test)
only_the_rows_in_view_are_asked :: proc(t: ^testing.T) {
	s, fx := open_lazy(t)
	session.wait_until(s, fx, settled, "the rows in view answered", WAIT)
	info := info_of(fx)
	testing.expect_value(t, info.count, LAZY_COUNT)
	shown := info.shown_to - info.shown_from
	testing.expectf(t, shown > 0 && shown < 100, "the rows built: %d ..< %d", info.shown_from, info.shown_to)
	// (the rows built and as many again on each side: never the count)
	testing.expectf(t, info.asked_most <= info.shown_to + shown, "rows asked up to %d, %d built", info.asked_most, info.shown_to)
	testing.expect(t, session.find_text(s, "row 500 v1") == nil, "a row far out of view was built")
}

@(test)
a_scroll_asks_the_new_range :: proc(t: ^testing.T) {
	s, fx := open_lazy(t)
	session.wait_until(s, fx, settled, "the first rows answered", WAIT)
	testing.expect(t, plugins.list_scroll_to(&fx.host, "lazy", "main", "rows", 50_000), "no such list")
	session.wait_text(s, "row 50000 v1", WAIT)
	session.wait_until(s, fx, settled, "the new rows answered", WAIT)
	info := info_of(fx)
	testing.expectf(t, info.shown_from >= 49_000 && info.shown_from <= 50_000, "the rows built: %d ..< %d", info.shown_from, info.shown_to)
	// (the first rows are let go of: what is kept follows the view, not the scroll's history)
	testing.expectf(t, info.answered < 1000, "%d rows kept", info.answered)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find_text(s, "row 0 v1") == nil }, "the first row gone", WAIT)
}

@(test)
a_version_change_drops_stale_answers :: proc(t: ^testing.T) {
	s, fx := open_lazy(t)
	session.wait_until(s, fx, settled, "the first rows answered", WAIT)
	// the plugin is busy with bump; the scroll's ask waits behind it, and its answer is for version 1 when it comes
	testing.expect(t, plugins.run_command(&fx.host, "plugin.lazy.bump"), "the command did not run")
	testing.expect(t, plugins.list_scroll_to(&fx.host, "lazy", "main", "rows", 300), "no such list")
	session.frames(s, 2)
	session.wait_until(s, fx, proc(s: ^session.Session, fx: ^Fx) -> bool {
		info := info_of(fx)
		return info.version == 2 && info.dropped >= 1 && session.find_text(s, "row 300 v2") != nil
	}, "version 2's rows, the stale answer dropped", WAIT)
	testing.expect(t, session.find_text(s, " v1") == nil, "a row of version 1 is still shown")
}

PICKER_MANIFEST :: `{
	"id": "picker", "name": "Picker", "api": 8, "main": "main.js",
	"views": [{"id": "main", "title": "Pick", "place": "internal"}]
}`

// A row is a text and the room after it: a press on that room is the row's, not the text's.
PICKER_MAIN :: `import { toast, views } from "gt";
export function activate() {
	views.register("main", () => ({ kind: "list", key: "rows", count: 1000, visibleRows: 10, rowHeight: 2,
		row: (i) => ({ kind: "row", children: [{ kind: "text", text: "item " + i }, { kind: "space", size: "fill" }] }),
		onActivate: (i) => toast.show("activated " + i),
	}));
}
`

@(private = "file")
Active :: struct { fx: ^Fx, row: int }

@(private = "file")
picker_active :: proc(fx: ^Fx) -> (active: int, focused: bool) {
	info, ok := plugins.list_info(&fx.host, "picker", "main", "rows")
	if !ok { return -1, false }
	return info.active, info.focused
}

// A press on a row (on its room past its text, where no widget of the plugin's is) makes it active and gives the list
// the keyboard.
@(private = "file")
press_row :: proc(s: ^session.Session, row: string, count := 1) {
	b := session.get(s, row)
	session.click_at(s, {b.rect.min.x + (b.rect.max.x - b.rect.min.x) * 0.75, (b.rect.min.y + b.rect.max.y) * 0.5}, count = count)
}

// Level 8: the list's active row is the host's (a press sets it, Down moves it); Enter on it and a double click reach
// the plugin's onActivate with the row's index.
@(test)
the_active_row_and_enter_reach_the_plugin :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t, "plugin-picker")
	write_plugin(root, "picker", PICKER_MANIFEST, PICKER_MAIN)
	enable(root, "picker")
	fx := new(Fx)   // (freed by open's cleanup)
	s := open(t, fx, root)
	wait_started(s, fx, "picker")
	fx.open_view = {"picker", "main"}
	session.wait_text(s, "item 2", WAIT)
	// (the view's window takes its content's height as it comes: a press before it settles can miss its row)
	session.wait_idle(s, WAIT)
	press_row(s, "lrow_2")
	session.wait_until(s, Active{fx, 2}, proc(s: ^session.Session, w: Active) -> bool {
		active, focused := picker_active(w.fx)
		return active == w.row && focused
	}, "row 2 active, the list focused", WAIT)
	session.key(s, .Down)
	session.wait_until(s, Active{fx, 3}, proc(s: ^session.Session, w: Active) -> bool {
		active, _ := picker_active(w.fx)
		return active == w.row
	}, "row 3 active", WAIT)
	toasts := fx.host.toasts
	session.key(s, .Return)
	session.wait_until(s, Count{fx, toasts + 1}, proc(s: ^session.Session, c: Count) -> bool { return c.fx.host.toasts >= c.at }, "onActivate's toast", WAIT)
	testing.expect_value(t, fx.host.last_toast, "activated 3")
	// a double click activates the row it is on
	toasts = fx.host.toasts
	press_row(s, "lrow_5", count = 2)
	session.wait_until(s, Count{fx, toasts + 1}, proc(s: ^session.Session, c: Count) -> bool { return c.fx.host.toasts >= c.at }, "the double click's toast", WAIT)
	testing.expect_value(t, fx.host.last_toast, "activated 5")
}

// A list of an older level has no onActivate: its Enter reaches the process, which drops it with no render and no
// error; the list goes on answering.
@(test)
enter_on_a_list_without_on_activate :: proc(t: ^testing.T) {
	s, fx := open_lazy(t)
	session.wait_until(s, fx, settled, "the first rows answered", WAIT)
	b := session.get(s, "lrow_1")
	session.click_at(s, {b.rect.min.x + (b.rect.max.x - b.rect.min.x) * 0.75, (b.rect.min.y + b.rect.max.y) * 0.5})
	toasts := fx.host.toasts
	session.key(s, .Return)
	session.frames(s, 10)
	testing.expect_value(t, fx.host.toasts, toasts)
	testing.expect_value(t, plugins.state_of(&fx.host, "lazy"), plugins.Plugin_State.Running)
	testing.expect_value(t, info_of(fx).active, 1)
}

@(test)
a_slow_plugin_keeps_the_window_scrolling :: proc(t: ^testing.T) {
	s, fx := open_lazy(t)
	session.wait_until(s, fx, settled, "the first rows answered", WAIT)
	// (a new version whose rows never come: its row function loops)
	testing.expect(t, plugins.run_command(&fx.host, "plugin.lazy.hang"), "the command did not run")
	session.wait_text(s, "…", WAIT)   // (the placeholders of version 2)
	from := fx.builds
	session.wait_until(s, Count{fx, from + MORE_BUILDS}, proc(s: ^session.Session, c: Count) -> bool { return c.fx.builds >= c.at }, "30 more builds", WAIT)
	wait_state(s, fx, "lazy", .Not_Responding)
	testing.expect(t, plugins.list_scroll_to(&fx.host, "lazy", "main", "rows", 1000), "no such list")
	session.wait_until(s, fx, proc(s: ^session.Session, fx: ^Fx) -> bool { return info_of(fx).shown_from >= 900 }, "the list scrolled", WAIT)
	testing.expect(t, session.find_text(s, "row 1000") == nil, "a row came from a plugin that loops")
	info := info_of(fx)
	testing.expectf(t, info.answered == 0, "%d rows of version 2 kept", info.answered)
	plugins.stop(&fx.host, "lazy")
	wait_state(s, fx, "lazy", .Ready)
}

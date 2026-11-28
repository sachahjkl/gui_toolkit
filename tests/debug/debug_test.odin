// The debug panel (src/md/features/debug-panel.md): a program's panel built in the window, a drag that changes the
// program's variable, an act that calls its code, the tools' list, set and press (in the process and over the
// devtools protocol), nothing run while the window is closed, the key, the filter, a pin, reflection and Odin source;
// the dense drag field of ui.
//   odin run tools/run_tests -- debug
package debug_test

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "gt:debug"
import "gt:devtools"
import "gt:platform"
import "gt:testkit/session"
import "gt:ui"

WINDOW :: [2]int{1000, 700}
// A drag of this many pixels; a float with no step moves ui.DRAG_FLOAT_SPEED a pixel.
DRAG_PX :: 50
EPS :: 0.02

Look :: struct {
	scale:  f32 `debug:"0..4"`,
	name:   string,
	secret: int `debug:"-"`,
	seen:   int `debug:"ro"`,
	tint:   ui.Color,
}

Kind :: enum { Soldier, Archer, Knight }

Soldier :: struct {
	model:    int,
	kind:     Kind,
	speed:    f32,
	alive:    bool,
	position: [3]f32,
	look:     Look,
	prints:   int,
	builds:   int,   // the panel's procedure's runs
	speeds:   ui.Value_History(16),
	route:    debug.Curve,
}

soldier_debug :: proc(s: ^Soldier) {
	s.builds += 1
	debug.number("model", &s.model, lo = 0, hi = 7)
	debug.choice("kind", &s.kind)
	debug.number("speed", &s.speed)
	debug.toggle("alive", &s.alive)
	if debug.section("Transform") {
		debug.vector("position", &s.position, step = 0.5)
	}
	debug.value("look", &s.look)
	debug.watch("prints", s.prints)
	if debug.act("Print") { s.prints += 1 }
	debug.plot("speeds", &s.speeds)
	debug.curve("route", &s.route)
}

@(private = "file")
page :: proc(s: ^session.Session) {
	ui.label("The page###page")
}

@(private = "file")
open_with_soldier :: proc(t: ^testing.T, soldier: ^Soldier) -> ^session.Session {
	s := session.start(t, {size = WINDOW, build = page})
	debug.panel(s.state, "Soldier", soldier_debug, soldier)
	debug.open(s.state)
	testing.expect(t, debug.show_panel(s.state, "Soldier"))
	session.wait_box(s, debug.box_name("Soldier/speed"))
	return s
}

@(test)
a_drag_changes_the_programs_variable :: proc(t: ^testing.T) {
	soldier: Soldier
	s := open_with_soldier(t, &soldier)
	b := session.get(s, debug.box_name("Soldier/speed"))
	at := session.center(b)
	session.drag(s, at, at + {DRAG_PX, 0})
	testing.expectf(t, abs(soldier.speed - DRAG_PX * ui.DRAG_FLOAT_SPEED) < EPS, "a drag of %d px: %v", DRAG_PX, soldier.speed)
	// (a vector's component, rounded to its step)
	c := session.center(session.get(s, debug.box_name("Soldier/Transform/position", "c1")))
	session.drag(s, c, c + {DRAG_PX, 0})
	testing.expect_value(t, soldier.position, [3]f32{0, 0.5 * DRAG_PX, 0})
}

@(test)
an_act_pressed_calls_the_program :: proc(t: ^testing.T) {
	soldier: Soldier
	s := open_with_soldier(t, &soldier)
	session.click(s, debug.box_name("Soldier/Print", "act"))
	testing.expect_value(t, soldier.prints, 1)
}

@(test)
a_closed_window_runs_nothing :: proc(t: ^testing.T) {
	soldier: Soldier
	s := session.start(t, {size = WINDOW, build = page})
	debug.panel(s.state, "Soldier", soldier_debug, &soldier)
	session.frames(s, 30)
	testing.expect_value(t, soldier.builds, 0)
	testing.expect(t, !debug.shown(s.state))
	// the key opens it, the panel's procedure runs while its tab shows, the key closes it
	session.key(s, .D, {.Ctrl, .Alt, .Shift})
	testing.expect(t, debug.shown(s.state))
	testing.expect(t, debug.show_panel(s.state, "Soldier"))
	session.frames(s, 3)
	testing.expect(t, soldier.builds > 0)
	session.key(s, .D, {.Ctrl, .Alt, .Shift})
	testing.expect(t, !debug.shown(s.state))
	session.frames(s, 3)
	runs := soldier.builds
	session.frames(s, 30)
	testing.expect_value(t, soldier.builds, runs)
}

// A person who opens the debug window by chance closes it with Escape, as with the key: the key puts the focus in it.
@(test)
escape_closes_the_debug_window_the_key_opened :: proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = page})
	_ = debug.attach(s.state)   // (as gt:host does for every window)
	session.frames(s, 2)
	session.key(s, .D, {.Ctrl, .Alt, .Shift})
	testing.expect(t, debug.shown(s.state), "the key opens it")
	session.frames(s, 3)
	testing.expect(t, debug.shown(s.state), "it stays open")
	session.key(s, .Escape)
	session.frames(s, 3)
	testing.expect(t, !debug.shown(s.state), "Escape closes it")
}

// A program whose own shortcut is the debug window's chord keeps it (four programs' "Compact rows" was
// Ctrl+Alt+Shift+D): the key opens the debug window only when no reader of the build took the press.
@(test)
a_program_s_own_shortcut_on_the_debug_key_wins :: proc(t: ^testing.T) {
	Mine :: struct { presses: int }
	mine: Mine
	s := session.start(t, {size = WINDOW, user = &mine, build = proc(s: ^session.Session) {
		if ui.key_press(.D, {.Ctrl, .Alt, .Shift}) { (^Mine)(s.user).presses += 1 }
		ui.label("The page###page")
	}})
	_ = debug.attach(s.state)
	session.frames(s, 2)
	session.key(s, .D, {.Ctrl, .Alt, .Shift})
	session.frames(s, 2)
	testing.expect_value(t, mine.presses, 1)
	testing.expect(t, !debug.shown(s.state), "the program took the press: no debug window")
}

// A panel's test needs no window: a bare ui.State (no fonts, no theme, no session) runs the List and Apply passes,
// as a release runner with no display nor offscreen renderer does (docs/debug.md, "A panel's test").
@(test)
a_panel_is_tested_on_a_bare_state :: proc(t: ^testing.T) {
	soldier := Soldier{speed = 1}
	s: ui.State
	ui.init(&s, nil, nil)
	defer ui.destroy(&s)
	debug.panel(&s, "Soldier", soldier_debug, &soldier)
	sb := strings.builder_make(context.temp_allocator)
	debug.list(&s, &sb)
	testing.expect(t, strings.contains(strings.to_string(sb), `"path":"Soldier/speed","kind":"number","value":1`))
	testing.expect_value(t, debug.set(&s, "Soldier/speed", "2.5"), "")
	testing.expect_value(t, soldier.speed, 2.5)
	testing.expect_value(t, debug.press(&s, "Soldier/Print"), "")
	testing.expect_value(t, soldier.prints, 1)
}

@(test)
the_tools_list_set_and_press :: proc(t: ^testing.T) {
	soldier := Soldier{speed = 1}
	s := session.start(t, {size = WINDOW, build = page})
	debug.panel(s.state, "Soldier", soldier_debug, &soldier)
	sb := strings.builder_make(context.temp_allocator)
	debug.list(s.state, &sb)
	listed := strings.to_string(sb)
	for want in ([]string{`"path":"Soldier/speed","kind":"number","value":1`, `"path":"Soldier/Transform/position","kind":"vector"`,
		`"path":"Soldier/kind","kind":"choice","value":"Soldier","choices":["Soldier","Archer","Knight"]`, `"path":"Soldier/Print","kind":"act"`,
		`"path":"Soldier/look/scale","kind":"number","value":0,"min":0,"max":4`, `"path":"Soldier/look/seen","kind":"number","value":0,"integer":true,"readOnly":true`,
		`"path":"View/wireframe","kind":"bool"`}) {
		testing.expectf(t, strings.contains(listed, want), "the list holds %s", want)
	}
	testing.expect(t, !strings.contains(listed, "secret"), "a field tagged - is hidden")
	testing.expect_value(t, soldier.builds, 1)
	// (closed sections are open to a tool: the window was never opened)
	testing.expect_value(t, debug.set(s.state, "Soldier/speed", "2.5"), "")
	testing.expect_value(t, soldier.speed, 2.5)
	testing.expect_value(t, debug.set(s.state, "Soldier/model", "12"), "")
	testing.expect_value(t, soldier.model, 7)   // (held to its bounds)
	testing.expect_value(t, debug.set(s.state, "Soldier/Transform/position", "[1.2, 2, 3]"), "")
	testing.expect_value(t, soldier.position, [3]f32{1, 2, 3})   // (to its step)
	testing.expect_value(t, debug.set(s.state, "Soldier/kind", "knight"), "")
	testing.expect_value(t, soldier.kind, Kind.Knight)
	testing.expect_value(t, debug.set(s.state, "Soldier/alive", "true"), "")
	testing.expect(t, soldier.alive)
	testing.expect_value(t, debug.set(s.state, "Soldier/look/name", "Ann"), "")
	testing.expect_value(t, soldier.look.name, "Ann")
	testing.expect_value(t, debug.set(s.state, "Soldier/look/tint", "#ff000080"), "")
	testing.expect(t, soldier.look.tint.r == 1 && abs(soldier.look.tint.a - 128.0 / 255) < 1e-4)
	testing.expect_value(t, debug.press(s.state, "Soldier/Print"), "")
	testing.expect_value(t, soldier.prints, 1)
	testing.expect_value(t, debug.set(s.state, "View/wireframe", "true"), "")
	testing.expect(t, s.state.wireframe)
	// what is refused says why
	testing.expect(t, strings.contains(debug.set(s.state, "Soldier/look/seen", "3"), "read only"))
	testing.expect(t, strings.contains(debug.set(s.state, "Soldier/nothing", "3"), "no \"nothing\""))
	testing.expect(t, strings.contains(debug.press(s.state, "Archer/Print"), "known: View, Soldier"))
	testing.expect(t, strings.contains(debug.press(s.state, "Soldier/speed"), "a value"))
	testing.expect(t, strings.contains(debug.set(s.state, "Soldier/speed", "fast"), "not a number"))
}

@(test)
the_devtools_protocol_reaches_the_panels :: proc(t: ^testing.T) {
	soldier: Soldier
	s := session.start(t, {size = WINDOW, build = page})
	debug.panel(s.state, "Soldier", soldier_debug, &soldier)
	srv := devtools.start_local(s.win, "debug")
	defer devtools.stop(srv)
	c := devtools.local_connect(srv)
	defer devtools.local_close(c)
	ask :: proc(s: ^session.Session, srv: ^devtools.Server, c: devtools.Local_Client, id: int, method, params: string) -> string {
		devtools.local_send(c, fmt.tprintf(`{{"id":%d,"method":%q,"params":%s}}`, id, method, params))
		for _ in 0 ..< 10 {
			devtools.service(srv, s.state, nil)
			for m in devtools.local_take(c, context.temp_allocator) {
				if strings.contains(m, fmt.tprintf(`"id":%d,`, id)) || strings.contains(m, fmt.tprintf(`"id":%d}}`, id)) { return m }
			}
			session.frame(s)
		}
		return ""
	}
	listed := ask(s, srv, c, 1, "Toolkit.debugPanels", "{}")
	testing.expect(t, strings.contains(listed, `"path":"Soldier/Transform/position"`), listed)
	testing.expect(t, strings.contains(ask(s, srv, c, 2, "Toolkit.debugSet", `{"path":"Soldier/Transform/position","value":[1,2,3]}`), `"result":{}`))
	testing.expect_value(t, soldier.position, [3]f32{1, 2, 3})
	testing.expect(t, strings.contains(ask(s, srv, c, 3, "Toolkit.debugSet", `{"path":"Soldier/speed","value":0.75}`), `"result":{}`))
	testing.expect_value(t, soldier.speed, 0.75)
	testing.expect(t, strings.contains(ask(s, srv, c, 4, "Toolkit.debugPress", `{"path":"Soldier/Print"}`), `"result":{}`))
	testing.expect_value(t, soldier.prints, 1)
	refused := ask(s, srv, c, 5, "Toolkit.debugSet", `{"path":"Soldier/nothing","value":1}`)
	testing.expect(t, strings.contains(refused, `"error"`), refused)
	// (the reply parses as JSON)
	_, err := json.parse_string(listed, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
}

@(test)
the_filter_shows_the_rows_that_match :: proc(t: ^testing.T) {
	soldier: Soldier
	s := open_with_soldier(t, &soldier)
	testing.expect(t, session.find(s, debug.box_name("Soldier/model", "row")) != nil)
	session.click(s, "debug_filter")
	session.type_text(s, "pos")
	session.wait_gone(s, debug.box_name("Soldier/model", "row"))
	session.wait_box(s, debug.box_name("Soldier/Transform/position", "row"))
	testing.expect(t, session.find_text(s, "Transform › position") != nil, "the row says its section")
}

@(test)
a_section_closes_and_keeps_its_state :: proc(t: ^testing.T) {
	soldier: Soldier
	s := open_with_soldier(t, &soldier)
	session.click(s, debug.box_name("Soldier/Transform", "section"))
	session.wait_gone(s, debug.box_name("Soldier/Transform/position", "row"))
	session.key(s, .D, {.Ctrl, .Alt, .Shift})
	session.key(s, .D, {.Ctrl, .Alt, .Shift})
	session.wait_box(s, debug.box_name("Soldier/speed"))
	testing.expect(t, session.find(s, debug.box_name("Soldier/Transform/position", "row")) == nil, "still closed")
}

@(test)
a_pinned_panel_is_a_view_of_its_own :: proc(t: ^testing.T) {
	soldier: Soldier
	s := open_with_soldier(t, &soldier)
	session.click(s, "debug_pin")
	session.frames(s, 3)
	testing.expect(t, ui.view_is_open(ui.state_views(s.state), debug.DEBUG_PANEL_VIEW, fmt.tprintf("%x/Soldier", uintptr(s.state))))
	// (its rows are built once, in its own view)
	testing.expect(t, session.find(s, debug.box_name("Soldier/speed")) != nil)
	testing.expect(t, session.find(s, debug.box_name("Soldier/speed"), 1) == nil)
}

@(test)
a_value_is_written_as_odin :: proc(t: ^testing.T) {
	soldier := Soldier{model = 2, kind = .Archer, position = {0, 1.5, 0}, look = {name = "Ann"}}
	text := debug.odin_text(soldier.look)
	testing.expect_value(t, text, `Look{scale = 0, name = "Ann", secret = 0, seen = 0, tint = {0, 0, 0, 0}}`)
	testing.expect(t, strings.has_prefix(debug.odin_text(soldier), `Soldier{model = 2, kind = .Archer, speed = 0, alive = false, position = {0, 1.5, 0}, look = {scale = 0`))
}

// A drag with modifiers held, as the system gives it: each event of the pointer says them.
@(private = "file")
drag_with :: proc(s: ^session.Session, from, to: [2]f32, mods: platform.Modifiers) {
	session.move(s, from)
	s.buttons += {.Left}
	session.event(s, {kind = .Mouse_Press, button = .Left, pos = from, mods = mods})
	session.frame(s)
	for i in 1 ..= session.DRAG_STEPS {
		at := from + (to - from) * f32(i) / f32(session.DRAG_STEPS)
		s.pointer = at
		session.event(s, {kind = .Mouse_Move, pos = at, mods = mods})
		session.frame(s)
	}
	s.buttons -= {.Left}
	session.event(s, {kind = .Mouse_Release, button = .Left, pos = to, mods = mods})
	session.frames(s, 2)
}

// ui.drag_number alone: Shift slower, Ctrl faster, a double click types it, the wheel and the keys step it, bounds hold.
@(test)
a_dragged_number_moves_as_asked :: proc(t: ^testing.T) {
	App :: struct { v: f32, n: int, p: [3]f32 }
	app: App
	s := session.start(t, {size = {400, 200}, user = &app, build = proc(s: ^session.Session) {
		app := (^App)(s.user)
		if ui.dense_scope() {
			ui.next({width = ui.px(200)})
			ui.drag_number("###v", &app.v)
			ui.next({width = ui.px(200)})
			ui.drag_number("###n", &app.n, lo = 0, hi = 10)
			ui.next({width = ui.px(300)})
			ui.drag_vector("###p", &app.p, step = 0.5)
		}
	}})
	at := session.center(session.get(s, "v"))
	drag_with(s, at, at + {DRAG_PX, 0}, {.Shift})
	testing.expectf(t, abs(app.v - DRAG_PX * ui.DRAG_FLOAT_SPEED * ui.DRAG_SLOW) < EPS * ui.DRAG_SLOW, "Shift: %v", app.v)
	app.v = 0
	session.advance(s, session.SEPARATE_CLICK_MS)
	drag_with(s, at, at + {DRAG_PX, 0}, {.Ctrl})
	testing.expectf(t, abs(app.v - DRAG_PX * ui.DRAG_FLOAT_SPEED * ui.DRAG_FAST) < EPS * ui.DRAG_FAST, "Ctrl: %v", app.v)
	// typed
	session.advance(s, session.SEPARATE_CLICK_MS)
	session.click(s, "v", count = 2)
	session.type_text(s, "7.25")
	session.key(s, .Return)
	testing.expect_value(t, app.v, 7.25)
	// the wheel over it, the keys while it has the keyboard; held at its bounds
	n := session.center(session.get(s, "n"))
	session.wheel(s, n, {0, -3})
	testing.expect_value(t, app.n, 3)
	session.click(s, "n")
	session.key(s, .Up)
	testing.expect_value(t, app.n, 4)
	session.advance(s, session.SEPARATE_CLICK_MS)
	session.drag(s, n, n + {300, 0})
	testing.expect_value(t, app.n, 10)
	// a vector: each component its own field, rounded to the step
	y := session.center(session.get(s, "1", within = session.get(s, "p")))
	session.drag(s, y, y + {4, 0})
	testing.expect_value(t, app.p, [3]f32{0, 2, 0})
}

// Floating, the window's header is the row of its tabs, as tall as a dense body's tabs: no title bar over them.
@(test)
the_floating_window_s_header_is_its_tabs :: proc(t: ^testing.T) {
	soldier: Soldier
	s := open_with_soldier(t, &soldier)
	head := session.get(s, "view_header")
	tabs := session.get(s, "debug_tabs")
	testing.expectf(t, tabs.rect.min.y >= head.rect.min.y && tabs.rect.max.y <= head.rect.max.y, "the tabs %v in the header %v", tabs.rect, head.rect)
	row := session.get(s, debug.box_name("Soldier/speed", "row"))
	h, rh := head.rect.max.y - head.rect.min.y, row.rect.max.y - row.rect.min.y
	testing.expectf(t, h <= rh * 1.4, "the header %v px, a row %v px", h, rh)
	testing.expect(t, session.find(s, "view_header_title") == nil, "no title in a dense header")
	testing.expect(t, session.find(s, "view_close") != nil, "its close is there")
}

// A plot takes the field's width, a little taller than a row, with its highest and lowest values.
@(test)
a_plot_spans_its_field :: proc(t: ^testing.T) {
	soldier: Soldier
	for v in ([]f32{1, 4, 2, 8, 3}) { ui.value_history_push(&soldier.speeds, v) }
	s := open_with_soldier(t, &soldier)
	row := session.get(s, debug.box_name("Soldier/speeds", "row"))
	graph := session.get(s, debug.box_name("Soldier/speeds", "graph"))
	field := session.get(s, debug.box_name("Soldier/speed"))
	rh := session.get(s, debug.box_name("Soldier/speed", "row")).rect
	testing.expectf(t, row.rect.max.y - row.rect.min.y > (rh.max.y - rh.min.y) * 1.5, "a plot's row %v, a row %v", row.rect, rh)
	testing.expectf(t, graph.rect.min.x <= field.rect.min.x + 1 && graph.rect.max.x > field.rect.min.x + (field.rect.max.x - field.rect.min.x) * 0.6, "the graph %v in the field's place %v", graph.rect, field.rect)
	testing.expect(t, session.find_text(s, "8.00") != nil, "its highest")
	testing.expect(t, session.find_text(s, "1.00") != nil, "its lowest")
}

// A section closed by the person is still open to a tool: its values are set and its acts pressed by their paths.
@(test)
a_closed_section_is_open_to_the_tools :: proc(t: ^testing.T) {
	soldier: Soldier
	s := open_with_soldier(t, &soldier)
	session.click(s, debug.box_name("Soldier/Transform", "section"))
	session.wait_gone(s, debug.box_name("Soldier/Transform/position", "row"))
	testing.expect_value(t, debug.set(s.state, "Soldier/Transform/position", "1, 2, 3"), "")
	testing.expect_value(t, soldier.position, [3]f32{1, 2, 3})
	session.frames(s, 2)
	testing.expect(t, session.find(s, debug.box_name("Soldier/Transform/position", "row")) == nil, "still closed")
}

// What a tool sets that is no finite number never reaches the program.
@(test)
a_tool_s_infinity_is_refused :: proc(t: ^testing.T) {
	soldier := Soldier{speed = 1}
	s := session.start(t, {size = WINDOW, build = page})
	debug.panel(s.state, "Soldier", soldier_debug, &soldier)
	for bad in ([]string{"inf", "nan", "-Inf", "1e999"}) {
		testing.expectf(t, debug.set(s.state, "Soldier/speed", bad) != "", "%q refused", bad)
	}
	testing.expect(t, debug.set(s.state, "Soldier/Transform/position", "1, nan, 2") != "")
	testing.expect_value(t, soldier.speed, 1)
	testing.expect_value(t, soldier.position, [3]f32{})
}

Nest :: struct { state: ^ui.State, runs: int }

nest_debug :: proc(n: ^Nest) {
	n.runs += 1
	// (a panel's procedure that registers and removes panels: the passes walk the panels while it runs)
	debug.panel(n.state, "Inner", nest_debug, n)
	debug.panel_remove(n.state, "Nest")
	debug.number("runs", &n.runs)
}

// A panel's procedure that registers or removes a panel changes nothing: the list it runs in stays whole.
@(test)
a_panel_s_procedure_cannot_change_the_panels :: proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = page})
	nest := Nest{state = s.state}
	debug.panel(s.state, "Nest", nest_debug, &nest)
	for _ in 0 ..< 2 {
		sb := strings.builder_make(context.temp_allocator)
		debug.list(s.state, &sb)
		listed := strings.to_string(sb)
		testing.expect(t, strings.contains(listed, `"path":"Nest/runs"`), listed)
		testing.expect(t, !strings.contains(listed, "Inner"), listed)
	}
	testing.expect_value(t, nest.runs, 2)
}

// The window closed, a panel costs nothing per frame: no byte allocated, its procedure never run.
@(test)
a_closed_window_allocates_nothing :: proc(t: ^testing.T) {
	soldier: Soldier
	s := session.start(t, {size = WINDOW, build = page})
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, s.ctx.allocator)
	defer mem.tracking_allocator_destroy(&track)
	was := s.ctx.allocator
	s.ctx.allocator = mem.tracking_allocator(&track)
	defer s.ctx.allocator = was
	measure :: proc(s: ^session.Session, track: ^mem.Tracking_Allocator) -> (count: i64, bytes: i64) {
		session.frames(s, 10)
		c, b := track.total_allocation_count, track.total_memory_allocated
		session.frames(s, 30)
		return track.total_allocation_count - c, track.total_memory_allocated - b
	}
	count, bytes := measure(s, &track)
	debug.panel(s.state, "Soldier", soldier_debug, &soldier)
	debug.attach(s.state)
	with_count, with_bytes := measure(s, &track)
	testing.expectf(t, with_count == count && with_bytes == bytes, "30 frames: %d allocations, %d bytes; with a panel, %d, %d", count, bytes, with_count, with_bytes)
	testing.expect_value(t, soldier.builds, 0)
}

// A scroll in progress keeps scrolling: a dense field that slides under a still pointer does not take the wheel. A wheel
// that starts after a rest, over a field, steps it.
@(test)
a_scroll_in_progress_keeps_scrolling :: proc(t: ^testing.T) {
	ROWS :: 40
	App :: struct { v: [ROWS]int }
	app: App
	s := session.start(t, {size = {300, 200}, user = &app, build = proc(s: ^session.Session) {
		app := (^App)(s.user)
		if ui.dense_scope() {
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.scroll_y("###list") {
				ui.next({width = ui.fill(), height = ui.px(80)})
				ui.build_box({}, "###top")
				for i in 0 ..< ROWS {
					if ui.dense_row(fmt.tprintf("v%d", i), fmt.tprintf("###row%d", i)) { ui.drag_number(fmt.tprintf("###f%d", i), &app.v[i]) }
				}
			}
		}
	}})
	// (over the field's column, in the top box: the wheel scrolls the list)
	at := [2]f32{250, 40}
	slid := false
	for _ in 0 ..< 8 {
		for i in 0 ..< ROWS {
			if b := session.find(s, fmt.tprintf("f%d", i)); b != nil && at.x >= b.rect.min.x && at.x < b.rect.max.x && at.y >= b.rect.min.y && at.y < b.rect.max.y { slid = true }
		}
		session.wheel(s, at, {0, 1})
	}
	testing.expect(t, slid, "a field slid under the pointer during the scroll")
	testing.expect_value(t, app.v, [ROWS]int{})
	// a rest, then a wheel over a field: it steps
	session.advance(s, 2 * ui.WHEEL_LATCH_MS)
	session.wheel(s, at, {0, 1})
	stepped := 0
	for v in app.v { stepped += abs(v) }
	testing.expect_value(t, stepped, 1)
}

// The labels read on the window's ground (WCAG AA, 4.5) in a dark and a light theme.
@(test)
the_labels_read_in_both_themes :: proc(t: ^testing.T) {
	Case :: struct { theme: string, light: bool }
	for c in ([]Case{{"Graphite", false}, {"Glacier", true}, {"Midnight", false}, {"Midnight", true}}) {
		soldier: Soldier
		s := session.start(t, {size = WINDOW, build = page, palette = ui.palette_of(c.theme, light = c.light)})
		debug.panel(s.state, "Soldier", soldier_debug, &soldier)
		debug.open(s.state)
		testing.expect(t, debug.show_panel(s.state, "Soldier"))
		row := session.wait_box(s, debug.box_name("Soldier/model", "row"))
		label := session.get(s, "label", within = row)
		ground := row.parent
		for ground != nil && !(.Draw_Background in ground.flags) { ground = ground.parent }
		if !testing.expect(t, ground != nil, "the row lies on a ground") { continue }
		ratio := ui.contrast(label.target_text, ground.target_bg)
		testing.expectf(t, ratio >= 4.5, "%s light=%v: a label at %.2f:1", c.theme, c.light, ratio)
	}
}

Labels :: struct { a, b, c: f32 }

short_labels :: proc(l: ^Labels) {
	debug.number("a", &l.a)
	if debug.section("S") { debug.number("bb", &l.b) }
}

Grown :: struct { a, b: f32, long: bool }

grown_labels :: proc(g: ^Grown) {
	debug.toggle("long", &g.long)
	if g.long { debug.number("the drone's speed", &g.b) }
}

// A window that goes idle keeps no column of a build before: a longer label that comes (the program's data changed,
// nothing animates) asks for the next build, and shows whole.
@(test)
the_label_column_is_right_once_idle :: proc(t: ^testing.T) {
	g: Grown
	s := session.start(t, {size = WINDOW, build = page})
	debug.panel(s.state, "Mid", grown_labels, &g)
	debug.open(s.state)
	testing.expect(t, debug.show_panel(s.state, "Mid"))
	session.wait_box(s, debug.box_name("Mid/long", "row"))
	session.wait_idle(s)
	g.long = true
	session.frame(s)
	// (wait_idle builds anyway: what is looked at is whether a cut label asks for the next build)
	first := session.get(s, "label", within = session.get(s, debug.box_name("Mid/the drone's speed", "row")))
	testing.expect(t, first.ellipsis == {} || ui.needs_frame(s.state), "a label cut by the last build's column asks for the next build")
	session.wait_idle(s)
	lb := session.get(s, "label", within = session.get(s, debug.box_name("Mid/the drone's speed", "row")))
	testing.expectf(t, lb.ellipsis == {}, "the label whole: %v px", lb.rect.max.x - lb.rect.min.x)
}

long_labels :: proc(l: ^Labels) {
	debug.number("a", &l.a)
	debug.number("a label much longer than any column should be", &l.c)
}

// The labels' column is the panel's longest label's (ui.Dense_Labels): short labels, a narrow column; a long label caps
// it at DENSE_LABEL_MAX_EM and is cut; the fields of every depth start on one edge.
@(test)
the_label_column_is_the_longest_label_s :: proc(t: ^testing.T) {
	l: Labels
	s := session.start(t, {size = WINDOW, build = page})
	debug.panel(s.state, "Short", short_labels, &l)
	debug.panel(s.state, "Long", long_labels, &l)
	debug.open(s.state)
	testing.expect(t, debug.show_panel(s.state, "Short"))
	session.wait_box(s, debug.box_name("Short/a"))
	session.frames(s, 3)
	a := session.get(s, debug.box_name("Short/a"))
	bb := session.get(s, debug.box_name("Short/S/bb"))
	row := session.get(s, debug.box_name("Short/a", "row"))
	em := a.font_size
	testing.expectf(t, abs(a.rect.min.x - bb.rect.min.x) <= 1, "one edge across sections: %v, %v", a.rect.min.x, bb.rect.min.x)
	// ("bb" under its section's indent is the widest: a few ems, where the fixed column took seven)
	testing.expectf(t, a.rect.min.x - row.rect.min.x <= 4 * em, "short labels, a narrow column: %v px", a.rect.min.x - row.rect.min.x)
	testing.expect(t, debug.show_panel(s.state, "Long"))
	session.wait_box(s, debug.box_name("Long/a"))
	session.frames(s, 3)
	la := session.get(s, debug.box_name("Long/a"))
	lrow := session.get(s, debug.box_name("Long/a", "row"))
	col := la.rect.min.x - lrow.rect.min.x
	testing.expectf(t, col <= ui.DENSE_LABEL_MAX_EM * em + 4 && col > ui.DENSE_LABEL_MIN_EM * em, "a long label caps the column: %v px", col)
	long := session.get(s, debug.box_name("Long/a label much longer than any column should be"))
	testing.expect(t, abs(long.rect.min.x - la.rect.min.x) <= 1)
}

Acts :: struct { pressed: [8]int }

acts_debug :: proc(a: ^Acts) {
	if debug.act("Print") { a.pressed[0] += 1 }
	if debug.act("Reset") { a.pressed[1] += 1 }
	debug.number("n", &a.pressed[7])
	for i in 2 ..< 7 { if debug.act(fmt.tprintf("A much longer act of the panel %d", i)) { a.pressed[i] += 1 } }
}

// Acts one after another share a row, as many as it holds, then the next; what is not an act ends their row.
@(test)
acts_flow_on_one_row :: proc(t: ^testing.T) {
	a: Acts
	s := session.start(t, {size = WINDOW, build = page})
	debug.panel(s.state, "Acts", acts_debug, &a)
	debug.open(s.state)
	testing.expect(t, debug.show_panel(s.state, "Acts"))
	session.wait_box(s, debug.box_name("Acts/Reset", "act"))
	session.frames(s, 3)
	print := session.get(s, debug.box_name("Acts/Print", "act"))
	reset := session.get(s, debug.box_name("Acts/Reset", "act"))
	testing.expectf(t, abs(print.rect.min.y - reset.rect.min.y) < 1 && reset.rect.min.x > print.rect.max.x, "Print %v and Reset %v side by side", print.rect, reset.rect)
	n := session.get(s, debug.box_name("Acts/n", "row"))
	testing.expect(t, n.rect.min.y >= print.rect.max.y, "a number ends the acts' row")
	first := session.get(s, debug.box_name("Acts/A much longer act of the panel 2", "act"))
	last := session.get(s, debug.box_name("Acts/A much longer act of the panel 6", "act"))
	testing.expect(t, last.rect.min.y > first.rect.min.y, "a full row goes on to the next")
	body := session.get(s, debug.box_name("Acts/n", "row"))
	for i in 2 ..< 7 {
		b := session.get(s, debug.box_name(fmt.tprintf("Acts/A much longer act of the panel %d", i), "act"))
		testing.expectf(t, b.rect.max.x <= body.rect.max.x + 1, "act %d within the panel: %v", i, b.rect)
	}
	session.click(s, debug.box_name("Acts/Reset", "act"))
	testing.expect_value(t, a.pressed[1], 1)
}

// Clicking a tab in the debug window switches the shown panel.
@(test)
clicking_a_debug_tab_switches_panels :: proc(t: ^testing.T) {
	soldier: Soldier
	s := session.start(t, {size = WINDOW, build = page})
	debug.panel(s.state, "Soldier", soldier_debug, &soldier)
	debug.open(s.state)
	session.wait_box(s, debug.box_name("View/wireframe", "row"))
	testing.expect(t, session.find(s, debug.box_name("Soldier/speed")) == nil, "View panel shows first")
	session.click(s, "debug_tabs_1")
	session.wait_box(s, debug.box_name("Soldier/speed"))
	testing.expect(t, session.find(s, debug.box_name("View/wireframe", "row")) == nil, "Soldier panel replaces View")
	session.click(s, "debug_tabs_0")
	session.wait_box(s, debug.box_name("View/wireframe", "row"))
	testing.expect(t, session.find(s, debug.box_name("Soldier/speed")) == nil, "View panel returns on click")
}

// Many debug tabs (9+) in a narrow floating debug window keep a dedicated draggable grip on the left and pin/reattach/
// window/close controls strictly inside the header with zero overlap; dragging the grip moves the floating window.
@(test)
many_debug_tabs_keep_header_controls_inside :: proc(t: ^testing.T) {
	soldier: Soldier
	s := session.start(t, {size = {460, 500}, build = page})
	for name in ([]string{"Folder", "Draft", "Apply", "Indexes", "Installer", "Network", "Layout", "Plugins", "Audio"}) {
		debug.panel(s.state, name, soldier_debug, &soldier)
	}
	debug.open(s.state)
	session.wait_box(s, "debug_pin")
	session.frames(s, 3)
	head := session.get(s, "view_header")
	grip := session.get(s, "view_drag_grip")
	slot := session.get(s, "debug_tabs_slot")
	pin := session.get(s, "debug_pin")
	reattach := session.get(s, "view_reattach")
	window := session.get(s, "view_window")
	close_btn := session.get(s, "view_close")
	testing.expectf(t, grip.rect.max.x - grip.rect.min.x >= 12, "dedicated drag grip present: %v", grip.rect)
	ordered := [?]^ui.Box{grip, slot, pin, reattach, window, close_btn}
	for b, i in ordered {
		testing.expectf(t, b.rect.min.x >= head.rect.min.x - 1 && b.rect.max.x <= head.rect.max.x + 1, "control %d (%v) inside header %v", i, b.rect, head.rect)
		if i > 0 {
			prev := ordered[i - 1]
			testing.expectf(t, prev.rect.max.x <= b.rect.min.x + 1, "control %d (%v) does not overlap control %d (%v)", i - 1, prev.rect, i, b.rect)
		}
	}
	// Dragging the dedicated grip moves the floating debug window.
	x0 := head.rect.min.x
	g0 := session.center(grip)
	session.drag(s, g0, g0 - {50, 0})
	session.frames(s, 2)
	head = session.get(s, "view_header")
	testing.expectf(t, head.rect.min.x < x0 - 20, "dragging grip moved debug window: %v -> %v", x0, head.rect.min.x)
}

Spacing_Data :: struct { count: int, flag: bool }

spacing_debug :: proc(d: ^Spacing_Data) {
	debug.number("configuration_directory_limit", &d.count)
	debug.watch("url", "https://api.example.com/v1/sessions/ses_1234567890abcdef")
	if debug.act("Print") {}
	if debug.act("Reset") {}
	if debug.section("Render") {
		debug.toggle("wire", &d.flag)
	}
}

// Acts followed by a section header keep clear vertical breathing room (>= dense_gap * 2), and a short-labelled watch
// with a long value gets the full remaining row width instead of wasting blank space on the left.
@(test)
section_spacing_and_watch_horizontal_distribution :: proc(t: ^testing.T) {
	d := Spacing_Data{count = 7, flag = true}
	s := session.start(t, {size = {900, 620}, build = page})
	debug.panel(s.state, "Space", spacing_debug, &d)
	debug.open(s.state)
	testing.expect(t, debug.show_panel(s.state, "Space"))
	session.wait_box(s, debug.box_name("Space/Render", "section"))
	session.frames(s, 3)
	act_btn := session.get(s, debug.box_name("Space/Print", "act"))
	sec := session.get(s, debug.box_name("Space/Render", "section"))
	gap := sec.rect.min.y - act_btn.rect.max.y
	min_gap := max(f32(1), ui.dense_gap()) * 2
	testing.expectf(t, gap >= min_gap, "acts-to-section vertical gap %.1f px >= %.1f px", gap, min_gap)
	url_row := session.get(s, debug.box_name("Space/url", "row"))
	url_lbl := session.get(s, "label", within = url_row)
	url_val := session.get(s, debug.box_name("Space/url", "watch"))
	num_row := session.get(s, debug.box_name("Space/configuration_directory_limit", "row"))
	num_lbl := session.get(s, "label", within = num_row)
	// Short label "url" takes far less width than the long label column, so the long watch value gets full remaining width.
	url_lbl_w := url_lbl.rect.max.x - url_lbl.rect.min.x
	num_lbl_w := num_lbl.rect.max.x - num_lbl.rect.min.x
	testing.expectf(t, url_lbl_w < num_lbl_w * 0.6, "watch label %.1f px stays compact vs long label %.1f px", url_lbl_w, num_lbl_w)
	testing.expectf(t, url_val.rect.min.x <= url_lbl.rect.max.x + 8, "watch value starts right after its short label: %v after %v", url_val.rect, url_lbl.rect)
	testing.expectf(t, (url_val.rect.max.x - url_val.rect.min.x) > (url_row.rect.max.x - url_row.rect.min.x) * 0.75, "watch value gets >75%% of row width: %v in %v", url_val.rect, url_row.rect)
}

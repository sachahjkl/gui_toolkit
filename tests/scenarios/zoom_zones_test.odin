package scenarios_test

// Zoom zones (src/md/features/zoom-zones.md): the standard zoom keys act on the zone that holds the keyboard focus,
// Ctrl+wheel on the zone under the pointer, the window's zoom elsewhere; a zone's zoom remembered by the key it shows.

import "core:strconv"
import "core:testing"
import "gt:platform"
import store "gt:store"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file") WINDOW :: [2]int{400, 300}
@(private = "file") STEP :: f32(1.1)   // the Feel's zoom_step by default

@(private = "file")
Zones :: struct {
	outer, inner: ui.Zoom_Zone,
	outer_key, inner_key: string,   // what each zone shows ("": its own zoom)
}

// A side column outside any zone; the zone "outer" beside it, with the zone "inner" inside it under its own button.
@(private = "file")
build :: proc(s: ^session.Session) {
	z := (^Zones)(s.user)
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.row(id = "###row") {
		ui.next({width = ui.px(100), height = ui.fill()})
		if ui.column(id = "###side") { ui.button("Out###out_btn") }
		ui.zoom_zone(&z.outer, z.outer_key)
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.column(id = "###outer") {
			ui.button("Outer###outer_btn")
			ui.zoom_zone(&z.inner, z.inner_key)
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.column(id = "###inner") { ui.button("Inner###inner_btn") }
		}
	}
}

@(private = "file")
start :: proc(t: ^testing.T, z: ^Zones) -> ^session.Session {
	return session.start(t, {size = WINDOW, no_renderer = true, user = z, build = build})
}

@(private = "file")
zones_destroy :: proc(z: ^Zones) {
	ui.zoom_zone_destroy(&z.outer)
	ui.zoom_zone_destroy(&z.inner)
}

@(private = "file")
near_zoom :: proc(a, b: f32) -> bool { return abs(a - b) < 1e-4 }

@(private = "file")
outer_zoom :: proc(z: ^Zones) -> f32 { return ui.zoom_zone_value(&z.outer) }
@(private = "file")
inner_zoom :: proc(z: ^Zones) -> f32 { return ui.zoom_zone_value(&z.inner) }

@(test)
a_zoom_key_zooms_the_zone_that_has_the_focus :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	z: Zones
	defer zones_destroy(&z)
	s := start(t, &z)
	session.click(s, "outer_btn")
	testing.expect_value(t, session.focused_name(s), "outer_btn")
	session.key(s, .Equal, {.Ctrl})
	testing.expect(t, near_zoom(outer_zoom(&z), STEP), "the zone zooms in")
	testing.expect_value(t, z.outer.serial, 1)
	testing.expect_value(t, ui.zoom(s.state), 1)   // (not the window)
	testing.expect_value(t, inner_zoom(&z), 1)
	session.key(s, .Minus, {.Ctrl}, repeat = 2)
	testing.expect(t, near_zoom(outer_zoom(&z), 1 / STEP), "and out")
	testing.expect_value(t, ui.zoom(s.state), 1)
}) }

@(test)
with_the_focus_outside_any_zone_the_window_zooms :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	z: Zones
	defer zones_destroy(&z)
	s := start(t, &z)
	// the focus nowhere
	session.key(s, .Equal, {.Ctrl})
	testing.expect(t, near_zoom(ui.zoom(s.state), STEP), "the window zooms")
	session.key(s, .N0, {.Ctrl})
	// the focus outside the zones: every chord of the standard tables is the window's
	session.click(s, "out_btn")
	for c in ui.ZOOM_IN_KEYS {
		ui.set_zoom(s.state, 1)
		session.key(s, c.key, c.mods)
		testing.expectf(t, near_zoom(ui.zoom(s.state), STEP), "%v zooms the window in", c)
	}
	for c in ui.ZOOM_OUT_KEYS {
		ui.set_zoom(s.state, 1)
		session.key(s, c.key, c.mods)
		testing.expectf(t, near_zoom(ui.zoom(s.state), 1 / STEP), "%v zooms the window out", c)
	}
	for c in ui.ZOOM_RESET_KEYS {
		ui.set_zoom(s.state, 2)
		session.key(s, c.key, c.mods)
		testing.expectf(t, ui.zoom(s.state) == 1, "%v resets the window", c)
	}
	testing.expect(t, outer_zoom(&z) == 1 && inner_zoom(&z) == 1 && z.outer.serial == 0, "no zone moved")
}) }

// Ctrl++ on an AZERTY keyboard is Ctrl+Shift+=: the same zoom as Ctrl+=, in a zone too.
@(test)
ctrl_shift_equal_zooms_the_zone_too :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	z: Zones
	defer zones_destroy(&z)
	s := start(t, &z)
	session.click(s, "outer_btn")
	session.key(s, .Equal, {.Ctrl, .Shift})
	testing.expect(t, near_zoom(outer_zoom(&z), STEP), "Ctrl+Shift+= zooms the zone in")
	for c in ui.ZOOM_IN_KEYS {
		ui.zoom_zone_reset(&z.outer)
		session.key(s, c.key, c.mods)
		testing.expectf(t, near_zoom(outer_zoom(&z), STEP), "%v zooms the zone in", c)
	}
	testing.expect_value(t, ui.zoom(s.state), 1)
}) }

@(test)
ctrl_wheel_zooms_the_zone_under_the_pointer :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	z: Zones
	defer zones_destroy(&z)
	s := start(t, &z)
	// over a button of the zone (the box in front), with the focus elsewhere: the pointer decides
	session.click(s, "out_btn")
	session.wheel(s, session.center(session.get(s, "outer_btn")), {0, -1}, {.Ctrl})
	testing.expect(t, near_zoom(outer_zoom(&z), STEP), "the zone under the pointer zooms in")
	testing.expect_value(t, ui.zoom(s.state), 1)
	// over an empty part of the inner zone (nothing drawn there): the innermost
	inner := session.get(s, "inner")
	session.wheel(s, inner.rect.max - {10, 10}, {0, 1}, {.Ctrl})
	testing.expect(t, near_zoom(inner_zoom(&z), 1 / STEP), "the inner zone zooms out")
	testing.expect(t, near_zoom(outer_zoom(&z), STEP), "the outer zone stays")
	// outside the zones: the window
	side := session.get(s, "side")
	session.wheel(s, {side.rect.min.x + 10, side.rect.max.y - 10}, {0, -1}, {.Ctrl})
	testing.expect(t, near_zoom(ui.zoom(s.state), STEP), "the window zooms")
	testing.expect(t, near_zoom(outer_zoom(&z), STEP) && near_zoom(inner_zoom(&z), 1 / STEP), "no zone moved")
}) }

@(test)
ctrl_0_resets_the_zone_only :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	z: Zones
	defer zones_destroy(&z)
	s := start(t, &z)
	ui.set_zoom(s.state, 1.5)
	ui.zoom_zone_set(&z.inner, 2)
	ui.zoom_zone_set(&z.outer, 3)
	session.click(s, "inner_btn")
	session.key(s, .N0, {.Ctrl})
	testing.expect_value(t, inner_zoom(&z), 1)
	testing.expect_value(t, outer_zoom(&z), 3)
	testing.expect_value(t, ui.zoom(s.state), 1.5)
}) }

@(test)
nested_zones_the_innermost_takes_the_keys :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	z: Zones
	defer zones_destroy(&z)
	s := start(t, &z)
	session.click(s, "inner_btn")
	session.key(s, .Equal, {.Ctrl})
	testing.expect(t, near_zoom(inner_zoom(&z), STEP), "the inner zone zooms")
	testing.expect_value(t, outer_zoom(&z), 1)
	testing.expect_value(t, ui.zoom(s.state), 1)
	// a zone's own bounds hold
	z.inner.max = 1.2
	session.key(s, .Equal, {.Ctrl}, repeat = 3)
	testing.expect_value(t, inner_zoom(&z), 1.2)
}) }

// A zone remembers the zoom of each key it shows: another key has its own, the first one comes back with its zoom.
@(test)
a_key_s_zoom_comes_back_with_the_key :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	m: ui.Zoom_Memory
	defer ui.zoom_memory_destroy(&m)
	z: Zones
	defer zones_destroy(&z)
	z.outer.memory = &m
	z.outer_key = "ses_a"
	s := start(t, &z)
	session.click(s, "outer_btn")
	session.key(s, .Equal, {.Ctrl})
	testing.expect(t, near_zoom(outer_zoom(&z), STEP), "ses_a zooms in")
	z.outer_key = "ses_b"
	session.frame(s)
	testing.expect_value(t, outer_zoom(&z), 1)   // (another thing: its own zoom, the default)
	session.key(s, .Minus, {.Ctrl})
	testing.expect(t, near_zoom(outer_zoom(&z), 1 / STEP), "ses_b zooms out")
	z.outer_key = "ses_a"
	session.frame(s)
	testing.expect(t, near_zoom(outer_zoom(&z), STEP), "ses_a's zoom comes back")
	testing.expect(t, m.serial == 2, "two changes in the memory")
}) }

// Two zones on one memory: two keys, two zooms; the same key in both, one zoom.
@(test)
two_zones_on_one_memory :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	m: ui.Zoom_Memory
	defer ui.zoom_memory_destroy(&m)
	z: Zones
	defer zones_destroy(&z)
	z.outer.memory, z.inner.memory = &m, &m
	z.outer_key, z.inner_key = "ses_a", "ses_b"
	s := start(t, &z)
	session.click(s, "inner_btn")
	session.key(s, .Equal, {.Ctrl}, repeat = 2)
	testing.expect(t, near_zoom(inner_zoom(&z), STEP * STEP), "ses_b zooms")
	testing.expect_value(t, outer_zoom(&z), 1)   // (ses_a keeps its own)
	z.outer_key = "ses_b"
	session.frame(s)
	testing.expect(t, near_zoom(outer_zoom(&z), STEP * STEP), "ses_b in the other zone: the same zoom")
}) }

// Ctrl+0 forgets the key's zoom: it follows the default, and a change of the default reaches it.
@(test)
ctrl_0_forgets_the_key :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	m := ui.Zoom_Memory{default = 1.25}
	defer ui.zoom_memory_destroy(&m)
	z: Zones
	defer zones_destroy(&z)
	z.inner.memory = &m
	z.inner_key = "ses_a"
	s := start(t, &z)
	testing.expect_value(t, inner_zoom(&z), 1.25)   // (never zoomed: the default)
	session.click(s, "inner_btn")
	session.key(s, .Equal, {.Ctrl})
	testing.expect(t, near_zoom(inner_zoom(&z), 1.25 * STEP), "zoomed from the default")
	m.default = 1.5
	testing.expect(t, near_zoom(inner_zoom(&z), 1.25 * STEP), "a zoomed key keeps its zoom")
	session.key(s, .N0, {.Ctrl})
	testing.expect_value(t, inner_zoom(&z), 1.5)
	testing.expect_value(t, len(m.kept.values), 0)   // (forgotten, not kept at the default)
	m.default = 2
	testing.expect_value(t, inner_zoom(&z), 2)   // (it follows the default)
	// a step back to the default forgets the key too
	session.key(s, .Equal, {.Ctrl})
	session.key(s, .Minus, {.Ctrl})
	testing.expect_value(t, inner_zoom(&z), 2)
	testing.expect_value(t, len(m.kept.values), 0)
}) }

// A memory given a Store: each change is written to it (and a reset removes its line); another memory loaded from it
// has the same zooms.
@(test)
a_memory_writes_its_store :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	file: store.Store   // (in memory: no path, no worker)
	defer store.close(&file)
	store.set(&file, "ses_old", "9")   // (past the bounds: clamped when read)
	m := ui.Zoom_Memory{min = 0.5, max = 3}
	defer ui.zoom_memory_destroy(&m)
	ui.zoom_memory_load(&m, &file)
	z: Zones
	defer zones_destroy(&z)
	z.outer.memory = &m
	z.outer_key = "ses_old"
	s := start(t, &z)
	testing.expect_value(t, outer_zoom(&z), 3)
	z.outer_key = "ses_a"
	session.click(s, "outer_btn")
	session.key(s, .Equal, {.Ctrl})
	v, ok := store.get(&file, "ses_a")
	written, number := strconv.parse_f64(v)
	testing.expect(t, ok && number && near_zoom(f32(written), STEP), "the zoom written")
	again: ui.Zoom_Memory
	defer ui.zoom_memory_destroy(&again)
	ui.zoom_memory_load(&again, &file)
	testing.expect(t, near_zoom(f32(store.kept_of(&again.kept, "ses_a", 1)), STEP), "and read back")
	session.key(s, .N0, {.Ctrl})
	_, ok = store.get(&file, "ses_a")
	testing.expect(t, !ok, "a reset removes its line")
	ui.zoom_memory_forget(&m, "ses_old")
	_, ok = store.get(&file, "ses_old")
	testing.expect(t, !ok, "a thing gone: its line goes")
}) }

// A key press read for a zoom: every chord of the standard tables, nothing with Alt or without Ctrl.
@(test)
zoom_key_action_reads_the_standard_tables :: proc(t: ^testing.T) {
	for c in ui.ZOOM_IN_KEYS { testing.expect_value(t, ui.zoom_key_action(c.key, c.mods), ui.Zoom_Action.In) }
	for c in ui.ZOOM_OUT_KEYS { testing.expect_value(t, ui.zoom_key_action(c.key, c.mods), ui.Zoom_Action.Out) }
	for c in ui.ZOOM_RESET_KEYS { testing.expect_value(t, ui.zoom_key_action(c.key, c.mods), ui.Zoom_Action.Reset) }
	testing.expect_value(t, ui.zoom_key_action(.Equal, {}), ui.Zoom_Action.None)
	testing.expect_value(t, ui.zoom_key_action(.Equal, platform.Modifiers{.Ctrl, .Alt}), ui.Zoom_Action.None)
}

package taskbar_test

// The pure parts of the taskbar button (gt:platform taskbar.odin), the same on every system: the count's picture that
// Windows shows and the launcher entry that Linux sends. No window, no bus.

import "core:math"
import "core:testing"
import "gt:dbus"
import "gt:platform"
import "gt:render"
import "gt:ui"

@(private = "file") SIZE :: 16
@(private = "file") DARK :: u32(0x1E3A8A)    // white ink on it
@(private = "file") LIGHT :: u32(0xFDE68A)   // black ink on it

@(private = "file")
pixel :: proc(px: []u8, x, y: int, size := SIZE) -> [4]u8 {
	at := (y * size + x) * 4
	return {px[at], px[at + 1], px[at + 2], px[at + 3]}
}

// The disc fills the picture and leaves its corners clear; inside, a pixel is the accent or the ink, never another colour
// where no edge is.
@(test)
the_badge_is_a_disc_in_the_accent :: proc(t: ^testing.T) {
	testing.expect(t, platform.taskbar_badge_pixels(0, SIZE, DARK) == nil, "no count, no picture")
	px := platform.taskbar_badge_pixels(1, SIZE, DARK)
	defer delete(px)
	testing.expect_value(t, len(px), SIZE * SIZE * 4)
	testing.expect_value(t, pixel(px, 0, 0).a, 0)
	testing.expect_value(t, pixel(px, SIZE - 1, SIZE - 1).a, 0)
	testing.expect_value(t, pixel(px, 2, SIZE / 2), [4]u8{0x1E, 0x3A, 0x8A, 255})   // (left of the digit, inside the disc)
}

// The ink is the one with the higher contrast on the accent; the digit's stroke is in it.
@(test)
the_digits_are_in_the_contrasting_ink :: proc(t: ^testing.T) {
	testing.expect_value(t, platform.taskbar_badge_ink(DARK), 0xFFFFFF)
	testing.expect_value(t, platform.taskbar_badge_ink(LIGHT), 0x000000)
	testing.expect_value(t, platform.taskbar_badge_ink(platform.TASKBAR_BADGE_RED), 0xFFFFFF)
	// "1": its stem crosses the middle row a little right of the centre
	one := platform.taskbar_badge_pixels(1, SIZE, DARK)
	defer delete(one)
	stem := false
	for x in SIZE / 2 - 1 ..= SIZE / 2 + 1 { if pixel(one, x, SIZE / 2) == {255, 255, 255, 255} { stem = true } }
	testing.expect(t, stem, "the stem of the 1 is white on the dark disc")
	// "0": a hole in its middle, strokes left and right of it
	zero := platform.taskbar_badge_pixels(10, 32, LIGHT)   // (two digits: "1" then "0")
	defer delete(zero)
	ink := 0
	for i := 0; i < len(zero); i += 4 { if zero[i] == 0 && zero[i + 1] == 0 && zero[i + 2] == 0 && zero[i + 3] == 255 { ink += 1 } }
	testing.expect(t, ink > 20, "black strokes on the light disc")
}

// Each count has its own picture; 100 and more are one picture (the plus sign); the size follows the screen's.
@(test)
each_count_draws_its_own_number :: proc(t: ^testing.T) {
	same :: proc(a, b: []u8) -> bool {
		if len(a) != len(b) { return false }
		for v, i in a { if v != b[i] { return false } }
		return true
	}
	pictures: [dynamic][]u8
	defer { for p in pictures { delete(p) }; delete(pictures) }
	for n in ([]int{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 42, 99, 100}) { append(&pictures, platform.taskbar_badge_pixels(n, SIZE, DARK)) }
	for a, i in pictures {
		for b, j in pictures[i + 1:] { testing.expectf(t, !same(a, b), "pictures %d and %d differ", i, i + 1 + j) }
	}
	more := platform.taskbar_badge_pixels(1000, SIZE, DARK)
	defer delete(more)
	testing.expect(t, same(more, pictures[len(pictures) - 1]), "100 and 1000: the plus sign")
	big := platform.taskbar_badge_pixels(7, 32, DARK)
	defer delete(big)
	testing.expect_value(t, len(big), 32 * 32 * 4)
}

// What a dock reads of one entry.
Entry :: struct {
	uri:              string,
	count:            i64,
	count_visible:    bool,
	progress:         f64,
	progress_visible: bool,
	urgent:           bool,
	keys:             int,
	ok:               bool,
}

// Reads an Update body (sa{sv}) as a dock does: the URI, then each property by its type.
read_entry :: proc(body: []u8) -> (e: Entry) {
	r := dbus.reader_make(body, false)
	e.uri = dbus.r_string(&r)
	end := dbus.r_array_begin(&r, "{sv}")
	for r.pos < end && !r.err {
		dbus.r_align_entry(&r)
		key := dbus.r_string(&r)
		sig := dbus.r_variant_sig(&r)
		e.keys += 1
		switch {
		case key == "count" && sig == "x":            e.count = dbus.r_i64(&r)
		case key == "count-visible" && sig == "b":    e.count_visible = dbus.r_bool(&r)
		case key == "progress" && sig == "d":         e.progress = dbus.r_f64(&r)
		case key == "progress-visible" && sig == "b": e.progress_visible = dbus.r_bool(&r)
		case key == "urgent" && sig == "b":           e.urgent = dbus.r_bool(&r)
		case:                                         return {}   // (a key or a type a dock does not know)
		}
	}
	e.ok = !r.err && r.pos == len(body)
	return
}

// The entry names the program's desktop file and gives every property with the types of libunity.
@(test)
the_launcher_entry_says_every_property :: proc(t: ^testing.T) {
	uri := platform.launcher_entry_uri("opencode-native")
	testing.expect_value(t, uri, "application://opencode-native.desktop")
	path := platform.launcher_entry_path(uri)
	testing.expect(t, len(path) > len("/com/canonical/unity/launcherentry/"), "libunity's path and a hash")
	testing.expect_value(t, platform.launcher_entry_path(uri), path)

	e := read_entry(platform.launcher_entry_body(uri, {count = 3, progress = .Normal, done = 250, attention = true}))
	testing.expect(t, e.ok, "a well-formed sa{sv}")
	testing.expect_value(t, e.uri, uri)
	testing.expect_value(t, e.keys, 5)
	testing.expect_value(t, e.count, 3)
	testing.expect(t, e.count_visible && e.progress_visible && e.urgent)
	testing.expect_value(t, e.progress, 0.25)

	// paused and failed show as a bar (the entry has no state for them); indeterminate and none show no bar
	testing.expect(t, read_entry(platform.launcher_entry_body(uri, {progress = .Paused, done = 500})).progress_visible)
	testing.expect(t, read_entry(platform.launcher_entry_body(uri, {progress = .Error, done = 500})).progress_visible)
	busy := read_entry(platform.launcher_entry_body(uri, {progress = .Indeterminate}))
	testing.expect(t, busy.ok && !busy.progress_visible)
	none := read_entry(platform.launcher_entry_body(uri, {}))
	testing.expect(t, none.ok && !none.count_visible && !none.progress_visible && !none.urgent, "the cleared entry")
}

// ui.taskbar_badge gives the accent of the theme in use, as the sRGB the system's pictures take. The window's tests call it
// (a ui State, no renderer: the theme is data).
badge_in_the_theme_s_accent :: proc(t: ^testing.T, w: ^platform.Window, count: int) {
	theme: ui.Theme
	defer ui.theme_destroy(&theme)
	ui.apply_palette(&theme, ui.palette_of("Graphite"))
	s: ui.State
	ui.init(&s, nil, &theme)
	defer ui.destroy(&s)
	c := ui.color("accent")
	channel :: proc(l: f32) -> u32 { return u32(math.round(render.linear_to_srgb(l) * 255)) }
	want := channel(c.r) << 16 | channel(c.g) << 8 | channel(c.b)
	testing.expect(t, ui.taskbar_badge(w, count))
	testing.expect_value(t, platform.taskbar_state(w).accent, want)
	testing.expect(t, want != platform.TASKBAR_BADGE_RED, "the theme's, not the default")
	testing.expect(t, !ui.taskbar_badge(w, count), "the same theme: no change")
}

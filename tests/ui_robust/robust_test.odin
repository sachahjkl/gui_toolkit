// Widgets and theme calls with the arguments an application can hand them by mistake or by timing (an empty list, a
// selection past the end, icons fewer than labels, a theme edited before the palette), a toast cut inside a character, the
// highlight of a search match after a character whose lower case is longer, wake-up requests. No window.
//   odin test tests/ui_robust -vet -define:ODIN_TEST_THREADS=1
package ui_robust_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "../../font"
import "../../platform"
import "../../ui"

Fx :: struct {
	fonts: font.State,
	theme: ui.Theme,
	s:     ui.State,
	base_font: font.Font_Id,
}

open :: proc(f: ^Fx) -> bool {
	font.init(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !ok { return false }
	icons, iok := font.load_embedded(&f.fonts, ui.ICON_FONT_DATA)
	if !iok { return false }
	ui.apply_palette(&f.theme, ui.PALETTE_MIDNIGHT)
	ui.init(&f.s, &f.fonts, &f.theme)
	f.s.icon_font = icons
	f.base_font = id
	return true
}

close :: proc(f: ^Fx) {
	ui.destroy(&f.s)
	ui.theme_destroy(&f.theme)
	font.destroy(&f.fonts)
}

frame :: proc(f: ^Fx, events: []platform.Event, body: proc(f: ^Fx, user: rawptr), user: rawptr = nil) {
	ui.begin_build(&f.s, {
		window_size = {800, 600}, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
	})
	body(f, user)
	ui.end_build()
	free_all(context.temp_allocator)
}

Run :: struct { sel: int, items: []string, labels: []string, icons: []string }

build_widgets :: proc(f: ^Fx, user: rawptr) {
	r := (^Run)(user)
	ui.next({width = ui.px(200), height = ui.px(30)})
	ui.dropdown("###dd", r.items, &r.sel)
	ui.next({width = ui.px(400), height = ui.px(30)})
	if ui.row() { ui.tabs("###tabs", r.labels, r.icons, &r.sel) }
	ui.next({width = ui.px(400), height = ui.px(30)})
	ui.segmented("###seg", r.labels, &r.sel)
}

@(test)
widgets_survive_odd_arguments :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r: Run
	// a dropdown with nothing to choose from, with none chosen, with a choice past the end; tabs with fewer icons than
	// labels; a segmented control without a segment
	cases := [?]Run{
		{sel = 0, items = nil, labels = nil, icons = nil},
		{sel = -1, items = {"a", "b"}, labels = {"x", "y", "z"}, icons = {"\ue000"}},
		{sel = 7, items = {"a", "b"}, labels = {"x"}, icons = nil},
		{sel = 2, items = {}, labels = {"x", "y", "z"}, icons = {"\ue000", "\ue001"}},
	}
	for c in cases {
		r = c
		frame(&f, nil, build_widgets, &r)
		frame(&f, nil, build_widgets, &r)
	}
}

@(test)
theme_edited_before_the_palette :: proc(t: ^testing.T) {
	th: ui.Theme
	defer ui.theme_destroy(&th)
	mine := ui.Color{0.1, 0.9, 0.3, 1}
	ui.theme_add(&th, fmt.tprintf("%s background", "chart"), mine)   // the tags of a temporary string
	free_all(context.temp_allocator)
	ui.apply_palette(&th, ui.PALETTE_MIDNIGHT)
	ui.apply_palette(&th, ui.PALETTE_MIDNIGHT)   // twice: the entries are made once
	testing.expect_value(t, ui.theme_lookup(&th, {"chart"}, "background"), mine)
	testing.expect(t, ui.theme_lookup(&th, {}, "text") != ui.Color{1, 0, 1, 1}, "the palette's entries exist")
	n := len(th.patterns)
	ui.apply_palette(&th, ui.PALETTE_MIDNIGHT)
	testing.expect_value(t, len(th.patterns), n)
}

build_toast :: proc(f: ^Fx, user: rawptr) {
	ui.toast(.Info, "%s", (^string)(user)^)
}

@(test)
toast_is_cut_between_characters :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	text := strings.concatenate({strings.repeat("a", 111, context.temp_allocator), "\u00e9\u00e9"}, context.temp_allocator)
	frame(&f, nil, build_toast, &text)
	found := false
	for &toast in f.s.toasts {
		if !toast.alive { continue }
		found = true
		s := string(toast.text[:toast.len])
		for r in s { testing.expect(t, r != '\uFFFD', "a broken character") }
		testing.expect_value(t, toast.len, 111)   // the 112th byte would be half of an e acute
	}
	testing.expect(t, found)
}

@(test)
fuzzy_ranges_are_in_the_original_text :: proc(t: ^testing.T) {
	hay := "\u0130stanbul Stan"   // a dotted capital I: its lower case is longer in UTF-8
	ranges, ok := ui.fuzzy_find("stan", hay)
	testing.expect(t, ok && len(ranges) == 1)
	if len(ranges) == 1 {
		testing.expect_value(t, hay[ranges[0][0]:ranges[0][1]], "stan")
	}
	summer := "un \u00e9t\u00e9 chaud"
	ranges, ok = ui.fuzzy_find("\u00c9T\u00c9", summer)
	testing.expect(t, ok && len(ranges) == 1)
	if len(ranges) == 1 { testing.expect_value(t, summer[ranges[0][0]:ranges[0][1]], "\u00e9t\u00e9") }
}

build_timers :: proc(f: ^Fx, user: rawptr) {
	first := (^bool)(user)^
	if first {
		ui.timer_set(ui.Key(1), 5)
		ui.timer_set(ui.Key(2), 5)
	}
	_ = ui.timer_due(ui.Key(2))   // this one is asked about every build
}

// Timers nobody asks about and scrollbars whose scroll box is gone do not stay for ever.
@(test)
stale_tables_are_emptied :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	first := true
	frame(&f, nil, build_timers, &first)
	first = false
	f.s.sb_owner[ui.Key(7)] = ui.Key(8)   // a scrollbar of a box that does not exist
	testing.expect_value(t, len(f.s.timers), 2)
	for _ in 0 ..< ui.TIMER_KEEP_BUILDS + 50 { frame(&f, nil, build_timers, &first) }
	testing.expect_value(t, len(f.s.timers), 1)
	testing.expect(t, ui.Key(2) in f.s.timers)
	testing.expect(t, ui.Key(7) not_in f.s.sb_owner)
}

Wrap_Run :: struct { text: string, width: f32, lines: [][2]int }

build_wrap :: proc(f: ^Fx, user: rawptr) {
	r := (^Wrap_Run)(user)
	r.lines = ui.wrap_lines(f.base_font, 15, r.text, r.width, context.allocator)
}

// A line is never cut inside an emoji sequence or between a letter and its combining mark, and a long run of them is
// broken between clusters.
@(test)
wrapping_cuts_between_clusters :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	family := "\U0001F468\u200D\U0001F469\u200D\U0001F467"
	fours := strings.repeat(family, 4)
	defer delete(fours)
	text := strings.concatenate({"ab ", family, family, family, "e\u0301e\u0301e\u0301e\u0301 ", fours})   // (not temp: frame() frees that)
	defer delete(text)
	for width in ([?]f32{10, 25, 40, 70, 120}) {
		r := Wrap_Run{text = text, width = width}
		frame(&f, nil, build_wrap, &r)
		testing.expect(t, len(r.lines) > 1)
		for l in r.lines {
			testing.expectf(t, font.is_grapheme_boundary(text, l[0]) && font.is_grapheme_boundary(text, l[1]), "width %.0f: a line [%d, %d) cuts a cluster", width, l[0], l[1])
		}
		delete(r.lines)
	}
}

@(test)
wake_requests_keep_the_soonest :: proc(t: ^testing.T) {
	s: ui.State
	ui.wake_within(&s, 265)
	ui.wake_within(&s, 1000)
	testing.expect_value(t, ui.wake_ms(&s), 265)
	ui.wake_within(&s, 100)
	testing.expect_value(t, ui.wake_ms(&s), 100)
}

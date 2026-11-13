// Widgets and theme calls with the arguments an application can hand them by mistake or by timing (an empty list, a
// selection past the end, icons fewer than labels, a theme edited before the palette), a toast cut inside a character, the
// highlight of a search match after a character whose lower case is longer, wake-up requests. No window.
//   odin test tests/ui_robust -vet -define:ODIN_TEST_THREADS=1
package ui_robust_test

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"
import "../../src/font"
import "../../src/platform"
import "../../src/ui"

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
	ui.apply_palette(&f.theme, ui.palette_of("Midnight"))
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

// A theme destroyed is a theme with nothing: a palette applied again makes its entries anew, and a second destroy has nothing to free.
@(test)
a_destroyed_theme_starts_over :: proc(t: ^testing.T) {
	theme: ui.Theme
	ui.apply_palette(&theme, ui.palette_of("Midnight"))
	ui.theme_destroy(&theme)
	testing.expect_value(t, len(theme.patterns), 0)
	ui.apply_palette(&theme, ui.palette_of("Midnight"))
	testing.expect(t, len(theme.patterns) > 0, "made again")
	ui.theme_destroy(&theme)
	ui.theme_destroy(&theme)
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
	ui.apply_palette(&th, ui.palette_of("Midnight"))
	ui.apply_palette(&th, ui.palette_of("Midnight"))   // twice: the entries are made once
	testing.expect_value(t, ui.theme_lookup(&th, {"chart"}, "background"), mine)
	testing.expect(t, ui.theme_lookup(&th, {}, "text") != ui.Color{1, 0, 1, 1}, "the palette's entries exist")
	n := len(th.patterns)
	ui.apply_palette(&th, ui.palette_of("Midnight"))
	testing.expect_value(t, len(th.patterns), n)
}

build_toast :: proc(f: ^Fx, user: rawptr) {
	ui.announce(&ui.Announcer{mode = .Window}, .Info, (^string)(user)^)
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

@(test)
fuzzy_score_subsequences :: proc(t: ^testing.T) {
	// in order, not side by side; the runs come back merged
	_, ranges, ok := ui.fuzzy_score("cs5", "claude-sonnet-5")
	testing.expect(t, ok)
	testing.expect_value(t, len(ranges), 3)
	_, ranges, ok = ui.fuzzy_score("son", "claude-sonnet-5")
	testing.expect(t, ok && len(ranges) == 1)
	cs := "claude-sonnet-5"
	if len(ranges) == 1 { testing.expect_value(t, cs[ranges[0][0]:ranges[0][1]], "son") }
	_, _, ok = ui.fuzzy_score("5c", "claude-sonnet-5")
	testing.expect(t, !ok, "out of order")
	// a run and word starts rank above scattered letters; the tightest window is taken
	a, _, _ := ui.fuzzy_score("gpt", "gpt-5")
	b, _, _ := ui.fuzzy_score("gpt", "gemini-pro-turbo")
	testing.expect(t, a > b, "a run first")
	_, ranges, _ = ui.fuzzy_score("ab", "a-x-ab")
	testing.expect(t, len(ranges) == 1 && ranges[0] == {4, 6}, "the tightest window")
	// case folding keeps the original's offsets
	hay := "İstanbul Stan"
	_, ranges, ok = ui.fuzzy_score("stan", hay)
	testing.expect(t, ok && len(ranges) == 1 && hay[ranges[0][0]:ranges[0][1]] == "stan")
	s, r, ok2 := ui.fuzzy_score("  ", "anything")
	testing.expect(t, ok2 && s == 0 && r == nil, "an empty needle matches everything")
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

Scroll_Run :: struct { left: bool, box: ui.Key }

build_scroll :: proc(f: ^Fx, user: rawptr) {
	r := (^Scroll_Run)(user)
	ui.next({fixed_x = 100, fixed_y = 50, width = ui.px(200), height = ui.px(300), axis = .Y})
	flags := ui.Box_Flags{.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y}
	if r.left { flags += {.Scrollbar_Left} }
	b := ui.build_box(flags, "###list")
	r.box = b.key
	if ui.parent(b) { ui.spacer(ui.px(1200), exact = true) }
}

// The scrollbar of a scroll box is at its right edge, or at its left one with .Scrollbar_Left: the pointer there is on
// the scrollbar (the hot key is a scrollbar of that box), and on the other edge it is not.
@(test)
scrollbar_on_the_left :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	on_bar :: proc(f: ^Fx, r: ^Scroll_Run, x: f32) -> bool {
		ev := [1]platform.Event{{kind = .Mouse_Move, pos = {x, 200}}}
		frame(f, ev[:], build_scroll, r)
		frame(f, ev[:], build_scroll, r)
		owner, ok := f.s.sb_owner[f.s.hot_key]
		return ok && owner == r.box
	}
	r := Scroll_Run{left = false}
	frame(&f, nil, build_scroll, &r)
	testing.expect(t, on_bar(&f, &r, 296), "right edge: the scrollbar")
	testing.expect(t, !on_bar(&f, &r, 104), "left edge: the content")
	r.left = true
	testing.expect(t, on_bar(&f, &r, 104), "left edge: the scrollbar")
	testing.expect(t, !on_bar(&f, &r, 296), "right edge: the content")
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

// A byte that is no UTF-8 (a file name, say) matches as one byte wide, not as the three of U+FFFD.
@(test)
fuzzy_score_on_invalid_utf8 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_, ranges, ok := ui.fuzzy_score("\xff", "a\xff")
	testing.expect(t, ok, "found")
	if testing.expect_value(t, len(ranges), 1) { testing.expect_value(t, ranges[0], ui.Fuzzy_Range{1, 2}) }
	_, ranges, ok = ui.fuzzy_score("\xffb", "\xff\xffb")
	testing.expect(t, ok, "found")
	if testing.expect_value(t, len(ranges), 1) { testing.expect_value(t, ranges[0], ui.Fuzzy_Range{1, 3}) }
}

@(private = "file")
Wrap_Cache_Run :: struct { text: string, lines: [][2]int, arena: mem.Arena }

// The wrapped lines kept between builds do not live in whatever allocator the context had at the first wrap.
@(test)
wrap_cache_outlives_the_callers_allocator :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Wrap_Cache_Run{text = "several words that wrap onto several lines"}
	memory := make([]u8, 1 << 16)
	defer delete(memory)
	mem.arena_init(&r.arena, memory)
	frame(&f, nil, proc(f: ^Fx, user: rawptr) {
		r := (^Wrap_Cache_Run)(user)
		context.allocator = mem.arena_allocator(&r.arena)
		r.lines = ui.wrap_lines_cached(f.base_font, 15, r.text, 80)
	}, &r)
	for &b in memory { b = 0xee }
	frame(&f, nil, proc(f: ^Fx, user: rawptr) {
		r := (^Wrap_Cache_Run)(user)
		r.lines = ui.wrap_lines_cached(f.base_font, 15, r.text, 80)
	}, &r)
	testing.expect(t, len(r.lines) > 1 && r.lines[0][0] == 0, "the lines are still there")
}

@(private = "file")
Tip_Run :: struct { beside: bool }

@(private = "file")
build_tip :: proc(f: ^Fx, user: rawptr) {
	if (^Tip_Run)(user).beside {
		if ui.tooltip_beside() { ui.label("A tooltip") }
	} else {
		if ui.tooltip() { ui.label("A tooltip") }
	}
}

// Where tooltips go: below and right of the pointer, or beside it, centered on it; flipped or clamped into the window.
@(test)
tooltip_places :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	at :: proc(f: ^Fx, r: ^Tip_Run, p: ui.Vec2) -> ui.Rect {
		ev := [1]platform.Event{{kind = .Mouse_Move, pos = p}}
		for _ in 0 ..< 3 { frame(f, ev[:], build_tip, r) }
		return ui.box_at("###tooltip").rect
	}
	r := Tip_Run{}
	b := at(&f, &r, {100, 100})
	size := b.max - b.min
	testing.expect(t, size.x > 30 && size.y >= 30, "as large as its content")
	testing.expect_value(t, b.min, ui.Vec2{100 + 15 * 0.8, 100 + 15 * 1.4})
	b = at(&f, &r, {795, 595})
	testing.expect_value(t, b.max.x, 800)   // (shifted in)
	testing.expect_value(t, b.max.y, math.round(f32(595 - 15 * ui.TOOLTIP_ABOVE_EM)))   // (above the pointer: no room below)
	r.beside = true
	b = at(&f, &r, {100, 100})
	testing.expect_value(t, b.min.x, 100 + 15 * 1.2)
	testing.expect(t, abs((b.min.y + b.max.y) * 0.5 - 100) <= 1, "centered on the pointer")
	b = at(&f, &r, {790, 100})
	testing.expect_value(t, b.max.x, 790 - 15 * 1.2)
	b = at(&f, &r, {100, 2})
	testing.expect_value(t, b.min.y, 0)
}

// The bar of a scroll box: its size from the font, its margin, its thumb's length and place.
@(test)
scrollbar_geometry :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Scroll_Run{}
	for _ in 0 ..< 2 { frame(&f, nil, build_scroll, &r) }
	b := ui.box_at("###list")
	track, thumb, ok := ui.scrollbar_rects(b)
	testing.expect(t, ok, "a bar")
	testing.expect_value(t, track, ui.Rect{{289, 53}, {297, 347}})
	testing.expect_value(t, thumb, ui.Rect{{289, 53}, {297, 53 + 73.5}})   // 294 * 300 / 1200 long
	b.view_off.y = 450
	_, thumb, _ = ui.scrollbar_rects(b)
	testing.expect_value(t, thumb.min.y, 53 + 0.5 * (294 - 73.5))
	b.view_off.y = 900
	_, thumb, _ = ui.scrollbar_rects(b)
	testing.expect_value(t, thumb.max.y, 347)
	b.view_off.y = 0
	r.left = true
	for _ in 0 ..< 2 { frame(&f, nil, build_scroll, &r) }
	track, _, _ = ui.scrollbar_rects(ui.box_at("###list"))
	testing.expect_value(t, track.min.x, 103)
	testing.expect_value(t, track.max.x, 111)
}

// At 200 % the bar is twice as wide, and so is what takes the press beyond it.
@(test)
scrollbar_follows_the_scale :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r: Scroll_Run
	one :: proc(f: ^Fx, r: ^Scroll_Run, events: []platform.Event) {
		ui.begin_build(&f.s, {
			window_size = {800, 600}, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 2,
			base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
		})
		build_scroll(f, r)
		ui.end_build()
		free_all(context.temp_allocator)
	}
	for _ in 0 ..< 2 { one(&f, &r, nil) }
	track, _, _ := ui.scrollbar_rects(ui.box_at("###list"))
	testing.expect_value(t, track.max.x - track.min.x, 15)
	on_bar :: proc(f: ^Fx, r: ^Scroll_Run, x: f32) -> bool {
		ev := [1]platform.Event{{kind = .Mouse_Move, pos = {x, 200}}}
		for _ in 0 ..< 2 { one(f, r, ev[:]) }
		owner, ok := f.s.sb_owner[f.s.hot_key]
		return ok && owner == r.box
	}
	testing.expect(t, on_bar(&f, &r, track.min.x - 7), "8 pixels toward the content")
	testing.expect(t, !on_bar(&f, &r, track.min.x - 9), "and no more")
}

@(private = "file")
Frame_Run :: struct { frame, field: ^ui.Box, text: ui.Text_Field, focus: bool }

@(private = "file")
build_field_frame :: proc(f: ^Fx, user: rawptr) {
	r := (^Frame_Run)(user)
	ui.next({width = ui.px(300), height = ui.px(30)})
	if ui.field_frame("###frame") {
		r.frame = ui.parent_box()
		ui.next({width = ui.fill(), height = ui.pct(1)})
		if ui.tags("bare") { r.field = ui.line_edit("###field", &r.text).box }
	}
	if r.focus { ui.set_focus(r.field.key) } else if ui.focus_key() == r.field.key { ui.set_focus(0) }
}

// A field_frame is focused while its field is, and the bare field inside draws no surface, border or ring of its own.
@(test)
a_field_frame_is_focused_with_its_field :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Frame_Run{focus = true}
	defer ui.field_destroy(&r.text)
	for _ in 0 ..< 3 { frame(&f, nil, build_field_frame, &r) }
	testing.expect_value(t, r.frame.focus_t, 1)
	r.focus = false
	for _ in 0 ..< 3 { frame(&f, nil, build_field_frame, &r) }
	testing.expect_value(t, r.frame.focus_t, 0)
	for name in ([]string{"background", "border", "focus border"}) {
		testing.expectf(t, ui.theme_lookup(&f.theme, {"bare", "input"}, name).a == 0, "a bare field's %s is clear", name)
		testing.expectf(t, ui.theme_lookup(&f.theme, {"input"}, name).a > 0, "an input's %s is not", name)
	}
}

@(private = "file")
Deep_Run :: struct { outer: ^ui.Box, depth: int }

@(private = "file")
build_deep :: proc(f: ^Fx, user: rawptr) {
	r := (^Deep_Run)(user)
	ui.next({width = ui.px(300), height = ui.px(300)})
	r.outer = ui.build_box({.Clickable, .Hot_Within}, "###outer")
	ui.push_parent(r.outer)
	for _ in 0 ..< r.depth {
		ui.next({width = ui.fill(), height = ui.fill()})
		ui.push_parent(ui.build_box({}))
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	ui.build_box({.Clickable}, "###deep")
	for _ in 0 ..< r.depth { ui.pop_parent() }
	ui.pop_parent()
}

// .Hot_Within and hot_within see as far up the tree: the outer box of a row counts while the pointer is deep inside it.
@(test)
hot_within_looks_as_far_as_its_flag :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r := Deep_Run{depth = 55}
	ev := [1]platform.Event{{kind = .Mouse_Move, pos = {100, 100}}}
	for _ in 0 ..< 3 { frame(&f, ev[:], build_deep, &r) }
	testing.expect(t, ui.hot_within(r.outer.key), "hot_within")
	testing.expect_value(t, r.outer.hot_t, 1)
}

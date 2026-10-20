// The window's integrated title bar (hit test, regions from the ui tree), the virtualized list, the wrapped text cache
// and the scroll curve, without a window: synthetic input, builds, assertions. The ui state is global: one test thread.
//   odin test tests/chrome -vet -define:ODIN_TEST_THREADS=1
package chrome_test

import "core:fmt"
import "core:sync"
import "core:testing"
import "../../font"
import "../../platform"
import "../../ui"

WINDOW :: ui.Vec2{800, 600}

Fx :: struct {
	fonts: font.State,
	theme: ui.Theme,
	s:     ui.State,
	base_font: font.Font_Id,
}

@(private = "file")
open :: proc(f: ^Fx) -> bool {
	font.init(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !ok { return false }
	icons, iok := font.load_embedded(&f.fonts, ui.ICON_FONT_DATA)
	if !iok { return false }
	ui.apply_palette(&f.theme, ui.PALETTE_GRAPHITE)
	ui.init(&f.s, &f.fonts, &f.theme)
	f.s.icon_font = icons
	f.base_font = id
	return true
}

@(private = "file")
close :: proc(f: ^Fx) {
	ui.destroy(&f.s)
	ui.theme_destroy(&f.theme)
	font.destroy(&f.fonts)
}

@(private = "file")
frame :: proc(f: ^Fx, events: []platform.Event, body: proc(f: ^Fx, user: rawptr), user: rawptr, size := WINDOW) {
	ui.begin_build(&f.s, {
		window_size = size, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
	})
	body(f, user)
	ui.end_build()
	free_all(context.temp_allocator)
}

@(private = "file")
key :: proc(k: platform.Key, mods: platform.Modifiers = {}) -> platform.Event { return {kind = .Key_Press, key = k, mods = mods} }

////////////////////////////////
// Hit test of an integrated title bar (platform.hit_test_chrome)

@(private = "file")
sample_regions :: proc() -> (c: platform.Chrome_Regions) {
	// a 1000 x 40 title bar: a tab at 40..200, the caption buttons at the right end (46 px each)
	append(&c.caption, platform.Region{{0, 0}, {1000, 40}})
	append(&c.holes, platform.Region{{40, 4}, {200, 40}})
	c.buttons[.Minimize] = {{862, 0}, {908, 40}}
	c.buttons[.Maximize] = {{908, 0}, {954, 40}}
	c.buttons[.Close]    = {{954, 0}, {1000, 40}}
	return
}

// The tests drive the toolkit's global UI state: the test runner's threads take turns (no -define:ODIN_TEST_THREADS=1
// needed).
@(private = "file")
ui_state_lock: sync.Mutex

@(test)
hit_test_zones :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	c := sample_regions()
	defer platform.chrome_regions_destroy(&c)
	size := [2]f32{1000, 700}
	hit :: proc(c: ^platform.Chrome_Regions, x, y: f32, size: [2]f32, sides: platform.Sides = {.Top}) -> platform.Hit {
		return platform.hit_test_chrome(c, {x, y}, size, 8, 16, sides)
	}
	testing.expect_value(t, hit(&c, 500, 20, size), platform.Hit.Caption)        // empty title bar: drags
	testing.expect_value(t, hit(&c, 20, 20, size), platform.Hit.Caption)
	testing.expect_value(t, hit(&c, 100, 20, size), platform.Hit.Client)         // the tab is the app's
	testing.expect_value(t, hit(&c, 880, 20, size), platform.Hit.Minimize)
	testing.expect_value(t, hit(&c, 930, 20, size), platform.Hit.Maximize)       // HTMAXBUTTON: Snap Layouts
	testing.expect_value(t, hit(&c, 990, 20, size), platform.Hit.Close)
	testing.expect_value(t, hit(&c, 500, 300, size), platform.Hit.Client)        // below the title bar
}

@(test)
hit_test_edges :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	c := sample_regions()
	defer platform.chrome_regions_destroy(&c)
	size := [2]f32{1000, 700}
	h :: proc(c: ^platform.Chrome_Regions, x, y: f32, sides: platform.Sides) -> platform.Hit {
		return platform.hit_test_chrome(c, {x, y}, {1000, 700}, 8, 16, sides)
	}
	_ = size
	// the top band resizes, over the caption, a tab and the caption buttons alike; its ends are corners
	testing.expect_value(t, h(&c, 500, 3, {.Top}), platform.Hit.Top)
	testing.expect_value(t, h(&c, 100, 3, {.Top}), platform.Hit.Top)
	testing.expect_value(t, h(&c, 990, 3, {.Top}), platform.Hit.Top_Right)
	testing.expect_value(t, h(&c, 5, 3, {.Top}), platform.Hit.Top_Left)
	testing.expect_value(t, h(&c, 930, 8, {.Top}), platform.Hit.Maximize)       // just below the band
	// the other sides only when the client area reaches them
	testing.expect_value(t, h(&c, 2, 300, {.Top}), platform.Hit.Client)
	all := platform.Sides{.Left, .Top, .Right, .Bottom}
	testing.expect_value(t, h(&c, 2, 300, all), platform.Hit.Left)
	testing.expect_value(t, h(&c, 998, 300, all), platform.Hit.Right)
	testing.expect_value(t, h(&c, 500, 697, all), platform.Hit.Bottom)
	testing.expect_value(t, h(&c, 2, 697, all), platform.Hit.Bottom_Left)
	testing.expect_value(t, h(&c, 998, 697, all), platform.Hit.Bottom_Right)
	testing.expect_value(t, h(&c, 2, 10, all), platform.Hit.Top_Left)          // along the left edge, near the top
}

@(test)
hit_test_maximized :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	c := sample_regions()
	defer platform.chrome_regions_destroy(&c)
	// maximized: no resize band; the very top row of pixels is the buttons' and the caption's (Fitts)
	h :: proc(c: ^platform.Chrome_Regions, x, y: f32) -> platform.Hit { return platform.hit_test_chrome(c, {x, y}, {1000, 700}, 8, 16, {}) }
	testing.expect_value(t, h(&c, 999, 0), platform.Hit.Close)
	testing.expect_value(t, h(&c, 930, 0), platform.Hit.Maximize)
	testing.expect_value(t, h(&c, 500, 0), platform.Hit.Caption)
	testing.expect_value(t, h(&c, 0, 0), platform.Hit.Caption)
}

////////////////////////////////
// Title bar regions from the ui tree (ui.title_bar, ui.window_buttons)

@(test)
title_bar_regions :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	body :: proc(f: ^Fx, user: rawptr) {
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.title_bar("###tb") {
			ui.spacer(ui.px(20))
			ui.label("Title")                                  // text, not clickable: drags
			ui.next({width = ui.px(100), height = ui.pct(1)})
			ui.button("Tab###tab")                             // the app's
			ui.spacer(ui.fill())
			_, _ = ui.window_buttons()
		}
		ui.next({width = ui.fill(), height = ui.fill()})
		ui.button("Content###content")                         // not over the title bar: no hole
	}
	for _ in 0 ..< 3 { frame(f, nil, body, nil) }
	c := ui.chrome_regions(&f.s)
	testing.expect_value(t, len(c.caption), 1)
	if len(c.caption) == 1 { testing.expect_value(t, c.caption[0].max.y, f32(40)) }
	testing.expect_value(t, len(c.holes), 1)
	for b in platform.Caption_Button { testing.expect(t, !platform.region_empty(c.buttons[b])) }
	testing.expect_value(t, c.buttons[.Close].max.x, WINDOW.x)
	testing.expect_value(t, c.buttons[.Close].max.x - c.buttons[.Close].min.x, f32(ui.CAPTION_BUTTON_WIDTH))
	testing.expect(t, c.buttons[.Minimize].max.x <= c.buttons[.Maximize].min.x)
	// what the window would answer
	size := [2]f32{WINDOW.x, WINDOW.y}
	tab := c.holes[0]
	testing.expect_value(t, platform.hit_test_chrome(c, {(tab.min.x + tab.max.x) / 2, 20}, size, 8, 16, {}), platform.Hit.Client)
	testing.expect_value(t, platform.hit_test_chrome(c, {30, 20}, size, 8, 16, {}), platform.Hit.Caption)
	testing.expect_value(t, platform.hit_test_chrome(c, {400, 20}, size, 8, 16, {}), platform.Hit.Caption)
	mx := c.buttons[.Maximize]
	testing.expect_value(t, platform.hit_test_chrome(c, {(mx.min.x + mx.max.x) / 2, 20}, size, 8, 16, {}), platform.Hit.Maximize)
}

@(test)
caption_button_click :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	Run :: struct { clicked: platform.Caption_Button, ok: bool }
	run: Run
	body :: proc(f: ^Fx, user: rawptr) {
		r := (^Run)(user)
		ui.next({width = ui.fill(), height = ui.px(32)})
		if ui.title_bar("###tb") {
			ui.spacer(ui.fill())
			if b, ok := ui.window_buttons(); ok { r.clicked, r.ok = b, true }
		}
	}
	frame(f, nil, body, &run)
	frame(f, nil, body, &run)
	// a press and a release over the close button (as the platform turns WM_NCLBUTTONDOWN + the captured release)
	p := [2]f32{WINDOW.x - 10, 16}
	frame(f, {{kind = .Mouse_Move, pos = p}, {kind = .Mouse_Press, button = .Left, pos = p}}, body, &run)
	frame(f, {{kind = .Mouse_Release, button = .Left, pos = p}}, body, &run)
	testing.expect(t, run.ok)
	testing.expect_value(t, run.clicked, platform.Caption_Button.Close)
}

////////////////////////////////
// Virtualized list

ROWS :: 1000

Vl_Run :: struct {
	vl:     ui.Virtual_List,
	ids:    [ROWS]u64,
	labels: [ROWS]string,
	built:  int,
	first, last: int,
}

@(private = "file")
row_height :: proc(i: int) -> f32 { return 24 + f32(i % 5) * 12 }

@(private = "file")
vl_body :: proc(f: ^Fx, user: rawptr) {
	r := (^Vl_Run)(user)
	r.built = 0
	ui.next({width = ui.fill(), height = ui.fill()})
	if rows, ok := ui.vlist("###vl", &r.vl, r.ids[:], r.labels[:]); ok {
		r.first, r.last = rows.first, rows.last
		for i in rows.first ..< rows.last {
			ui.next({height = ui.px(row_height(i))})
			row := ui.list_row(&r.vl.list, i, r.labels[i])
			if ui.parent(row.box) {
				ui.next({width = ui.fill(), height = ui.pct(1)})
				ui.label(r.labels[i])
			}
			r.built += 1
		}
	}
}

@(private = "file")
vl_setup :: proc(r: ^Vl_Run) {
	for i in 0 ..< ROWS {
		r.ids[i] = u64(i) * 0x9e3779b97f4a7c15 + 1
		r.labels[i] = fmt.aprintf("row %d###r%d", i, i)
	}
}

@(private = "file")
vl_teardown :: proc(r: ^Vl_Run) {
	for l in r.labels { delete(l) }
	ui.vlist_destroy(&r.vl)
}

@(test)
vlist_builds_only_what_is_seen :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	r := new(Vl_Run)
	defer free(r)
	vl_setup(r)
	defer vl_teardown(r)
	for _ in 0 ..< 3 { frame(f, nil, vl_body, r) }
	// 600 px of view, rows of 24..72 px: a few dozen at most (view and margin), not a thousand
	testing.expect(t, r.built > 5 && r.built < 80, fmt.tprintf("built %d rows", r.built))
	testing.expect(t, ui.boxes_built(&f.s) < 250)
	// the rows laid out are measured: their extents are their real heights
	for i in r.first ..< r.last {
		_, h := ui.vlist_row_extent(&r.vl, i)
		if h != row_height(i) { testing.expectf(t, false, "row %d: %v, want %v", i, h, row_height(i)); break }
	}
}

@(test)
vlist_keyboard_reaches_every_row :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	r := new(Vl_Run)
	defer free(r)
	vl_setup(r)
	defer vl_teardown(r)
	frame(f, nil, vl_body, r)
	ui.set_focus(r.vl.key)   // (between builds: the focus of the next one)
	f.s.focus_key = r.vl.key
	frame(f, {key(.End)}, vl_body, r)
	testing.expect_value(t, r.vl.sel, ROWS - 1)
	for _ in 0 ..< 3 { frame(f, nil, vl_body, r) }
	testing.expect(t, r.first <= ROWS - 1 && r.last == ROWS, fmt.tprintf("rows %d..%d", r.first, r.last))
	// the last row is built and inside the list's box
	lb := ui.box_from_key(r.vl.key)
	rb := ui.box_from_key(ui.key_from_string(r.vl.key, fmt.tprintf("###lrow_%d", ROWS - 1)))
	if testing.expect(t, lb != nil && rb != nil) {
		testing.expect(t, rb.rect.max.y <= lb.rect.max.y + 0.5 && rb.rect.min.y >= lb.rect.min.y - 0.5, fmt.tprintf("row %v list %v", rb.rect, lb.rect))
	}
	frame(f, {key(.Home)}, vl_body, r)
	testing.expect_value(t, r.vl.sel, 0)
	frame(f, {key(.Page_Down)}, vl_body, r)
	testing.expect(t, r.vl.sel > 5, fmt.tprintf("page down to %d", r.vl.sel))
	// type-ahead over rows never built: "row 77" (labels match by their display text)
	sel := r.vl.sel
	frame(f, {{kind = .Text, text = 'r'}, {kind = .Text, text = 'o'}, {kind = .Text, text = 'w'}, {kind = .Text, text = ' '}, {kind = .Text, text = '7'}, {kind = .Text, text = '7'}, {kind = .Text, text = '7'}}, vl_body, r)
	testing.expect_value(t, r.vl.sel, 777)
	testing.expect(t, sel != r.vl.sel)
	for _ in 0 ..< 2 { frame(f, nil, vl_body, r) }
	testing.expect(t, r.first <= 777 && 777 < r.last)
}

@(test)
vlist_view_stays_on_its_row :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	r := new(Vl_Run)
	defer free(r)
	vl_setup(r)
	defer vl_teardown(r)
	frame(f, nil, vl_body, r)
	f.s.focus_key = r.vl.key
	ui.list_select(&r.vl.list, 500)
	for _ in 0 ..< 4 { frame(f, nil, vl_body, r) }
	// row 500's place on screen, then a narrower window (the heights are measured again at the new width: here they
	// do not change, so the view must not move)
	rb := ui.box_from_key(ui.key_from_string(r.vl.key, "###lrow_500"))
	if !testing.expect(t, rb != nil) { return }
	y0 := rb.rect.min.y
	for _ in 0 ..< 3 { frame(f, nil, vl_body, r, {700, 600}) }
	rb = ui.box_from_key(ui.key_from_string(r.vl.key, "###lrow_500"))
	if testing.expect(t, rb != nil) { testing.expect_value(t, rb.rect.min.y, y0) }
}

////////////////////////////////
// Wrapped text cache

@(test)
wrapped_text_is_cached :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f := new(Fx)
	defer free(f)
	if !testing.expect(t, open(f)) { return }
	defer close(f)
	W :: struct { width: f32 }
	w := W{300}
	body :: proc(f: ^Fx, user: rawptr) {
		ui.next({width = ui.px((^W)(user).width)})
		ui.paragraph("The quick brown fox jumps over the lazy dog, again and again, until the line has to wrap.###p")
	}
	for _ in 0 ..< 5 { frame(f, nil, body, &w) }
	testing.expect_value(t, ui.wrap_cache_len(&f.s), 1)   // layout and drawing share it, every frame
	w.width = 200
	frame(f, nil, body, &w)
	testing.expect_value(t, ui.wrap_cache_len(&f.s), 2)
	lines := ui.wrap_lines_cached(f.base_font, 15, "a b c", 1000)
	testing.expect_value(t, len(lines), 1)
}

////////////////////////////////
// Scroll curve

@(test)
scroll_curve :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	for c in ui.Scroll_Curve {
		if c == .Exponential { continue }
		p0, _ := ui.scroll_curve_eval(c, 5, 0)
		p1, d1 := ui.scroll_curve_eval(c, 5, 1)
		testing.expect(t, abs(p0) < 1e-9 && abs(p1 - 1) < 1e-9 && abs(d1) < 1e-9, fmt.tprintf("%v ends", c))
		prev: f64 = -1
		for k in 0 ..= 20 {   // never goes back, never past the end
			p, _ := ui.scroll_curve_eval(c, 5, f64(k) / 20)
			testing.expect(t, p >= prev - 1e-12 && p <= 1 + 1e-12)
			prev = p
		}
	}
	// a new target while moving fast keeps the speed: the move takes less than its duration
	cfg := ui.DEFAULT_SCROLL
	a: ui.Scroll_Anim
	ui.scroll_anim_retarget(&a, cfg, 0, 0, 100, 0)
	testing.expect_value(t, a.dur, f64(cfg.duration_ms))
	_, vel, _ := ui.scroll_anim_sample(&a, cfg, 10)
	pos, _, _ := ui.scroll_anim_sample(&a, cfg, 10)
	ui.scroll_anim_retarget(&a, cfg, pos, vel * 20, pos + 10, 10)
	testing.expect(t, a.dur < f64(cfg.duration_ms))
	end, _, done := ui.scroll_anim_sample(&a, cfg, 10 + a.dur)
	testing.expect(t, done && end == pos + 10)
}

// An app may read the UI state before its first build (Wren routed the mouse of its first frame through ui.scale and
// crashed when the pointer was over the window at start-up): init makes the state current.
@(test)
state_readable_before_the_first_build :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	fs: font.State
	font.init(&fs)
	defer font.destroy(&fs)
	theme: ui.Theme
	s: ui.State
	ui.init(&s, &fs, &theme)
	defer ui.destroy(&s)
	// the getters read this state, not whatever state built last (or none)
	s.scale = 2.5
	testing.expect_value(t, ui.scale(), f32(2.5))
	testing.expect_value(t, ui.focus_key(), ui.Key(0))
}
// Visual and geometric checks of the selection rectangle (ui.Item_Band): box rect, ancestor clip, draw order, and
// software-rendered pixels in every Table view (Details, List, Columns, Grid), at scroll 0 and scrolled, inside a
// parent that scrolls, clips, pads or sits away from the origin, in dark and light palettes, and on Ctrl+drag.
package data_views_test

import "core:fmt"
import "core:math"
import "core:testing"
import "gt:platform"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file") BV_WIN :: [2]int{640, 440}
@(private = "file") BV_OFF_X :: f32(110)
@(private = "file") BV_OFF_Y :: f32(60)
@(private = "file") BV_PAD :: f32(14)
@(private = "file") BV_TABLE_W :: f32(460)
@(private = "file") BV_TABLE_H :: f32(310)

@(private = "file")
BV_COLUMNS := [?]ui.Table_Column{
	{title = "Name", width = 0},
	{title = "Size", width = 6, number = true},
}

@(private = "file")
BV_WIDE_COLUMNS := [?]ui.Table_Column{
	{title = "Name", width = 18},
	{title = "Kind", width = 14},
	{title = "Date", width = 14},
	{title = "Size", width = 10, number = true},
}

@(private = "file")
BV_App :: struct {
	t:           ui.Table,
	d:           ui.Table_Data,
	offset:      bool,    // sidebar + header + padded clipped container around the table
	wide:        bool,    // wide columns to test horizontal scroll in Details
	table_w:     f32,
	table_h:     f32,
}

@(private = "file")
bv_init :: proc(app: ^BV_App, n: int, zoom: int, wide := false) {
	app.wide = wide
	app.table_w = BV_TABLE_W
	app.table_h = BV_TABLE_H
	cols := wide ? BV_WIDE_COLUMNS[:] : BV_COLUMNS[:]
	ui.table_init(&app.t, cols)
	app.t.zoom = zoom
	app.t.vl.multi = true
	app.t.rubber_band = true
	app.t.card_line = 1
	ui.table_data_reset(&app.d, len(cols))
	for i in 0 ..< n {
		name := fmt.tprintf("item_%02d.txt", i)
		ui.table_data_row(&app.d, u64(1000 + i), name)
		ui.table_data_cell(&app.d, name)
		if wide {
			ui.table_data_cell(&app.d, "Text")
			ui.table_data_cell(&app.d, "2026-01-01")
		}
		ui.table_data_cell(&app.d, fmt.tprintf("%d B", i * 10), f64(i * 10))
	}
	app.t.sort = ui.TABLE_UNSORTED
	ui.table_apply(&app.t, &app.d, "")
}

@(private = "file")
bv_destroy :: proc(app: ^BV_App) {
	ui.table_destroy(&app.t)
	ui.table_data_destroy(&app.d)
}

@(private = "file")
bv_build :: proc(s: ^session.Session) {
	app := (^BV_App)(s.user)
	if !app.offset {
		ui.next({width = ui.px(app.table_w), height = ui.px(app.table_h)})
		_ = ui.table_build("###table", &app.t, &app.d, "Empty")
		return
	}
	// Sidebar, header, and a clipped padded container so the table sits away from the window origin.
	ui.next({width = ui.fill(), height = ui.px(BV_OFF_Y)})
	_ = ui.build_box({.Draw_Background}, "###top_bar")
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.row() {
		ui.next({width = ui.px(BV_OFF_X), height = ui.fill()})
		_ = ui.build_box({.Draw_Background}, "###side_bar")
		ui.next({width = ui.px(app.table_w + 2 * BV_PAD), height = ui.px(app.table_h + 2 * BV_PAD)})
		if ui.column(flags = {.Clip, .Draw_Border}, id = "###frame") {
			ui.spacer(ui.px(BV_PAD), exact = true)
			ui.next({width = ui.fill(), height = ui.px(app.table_h)})
			if ui.row() {
				ui.spacer(ui.px(BV_PAD), exact = true)
				ui.next({width = ui.px(app.table_w), height = ui.px(app.table_h)})
				_ = ui.table_build("###table", &app.t, &app.d, "Empty")
				ui.spacer(ui.px(BV_PAD), exact = true)
			}
			ui.spacer(ui.px(BV_PAD), exact = true)
		}
	}
}

// Effective screen clip applied to box `b` by all clipping ancestors (root down to b.parent).
@(private = "file")
effective_clip :: proc(s: ^session.Session, b: ^ui.Box) -> ui.Rect {
	clip := s.state.root.rect
	for a := b.parent; a != nil; a = a.parent {
		if .Clip in a.flags {
			clip = {{max(clip.min.x, a.rect.min.x), max(clip.min.y, a.rect.min.y)}, {min(clip.max.x, a.rect.max.x), min(clip.max.y, a.rect.max.y)}}
		}
	}
	return clip
}

// Pre-order index of `target` in the UI draw tree (-1 if not found). Later index draws on top.
@(private = "file")
draw_order_index :: proc(root, target: ^ui.Box) -> int {
	walk :: proc(b, target: ^ui.Box, idx: ^int) -> int {
		cur := idx^
		idx^ += 1
		if b == target { return cur }
		for c := b.first; c != nil; c = c.next {
			if found := walk(c, target, idx); found >= 0 { return found }
		}
		return -1
	}
	idx := 0
	return walk(root, target, &idx)
}

// Maximum pre-order index of any box inside `container` except `skip`.
@(private = "file")
max_item_draw_index :: proc(root, container, skip: ^ui.Box) -> int {
	best := -1
	walk :: proc(b, container, skip: ^ui.Box, in_c: bool, idx: ^int, best: ^int) {
		cur := idx^
		idx^ += 1
		inside := in_c || b == container
		if inside && b != container && b != skip && (.Draw_Background in b.flags || .Draw_Text in b.flags || .Row in b.flags || b.custom != nil) {
			best^ = max(best^, cur)
		}
		for c := b.first; c != nil; c = c.next { walk(c, container, skip, inside, idx, best) }
	}
	idx := 0
	walk(root, container, skip, false, &idx, &best)
	return best
}

// Max channel difference between two pixels.
@(private = "file")
px_diff :: proc(a, b: session.Color) -> int {
	return max(abs(int(a.r) - int(b.r)), abs(int(a.g) - int(b.g)), abs(int(a.b) - int(b.b)))
}

// Linear ui.Color to sRGB u8 triple (for comparing border pixels against theme accent).
@(private = "file")
srgb_u8 :: proc(c: ui.Color) -> session.Color {
	enc :: proc(v: f32) -> u8 {
		cl := clamp(v, 0, 1)
		s := cl <= 0.0031308 ? cl * 12.92 : 1.055 * math.pow(cl, 1.0 / 2.4) - 0.055
		return u8(clamp(math.round(s * 255), 0, 255))
	}
	return {enc(c.r), enc(c.g), enc(c.b), 255}
}

// Verifies the band box exists, sits at `want` (within 2 px), lies inside its clip, draws after every item in `view`,
// and produces visible border and interior pixel changes on the software renderer.
@(private)
check_band_drawn :: proc(t: ^testing.T, s: ^session.Session, view: ^ui.Box, want: ui.Rect, before: session.Image, label: string, loc := #caller_location) {
	rb := session.find(s, "item_band")
	if !testing.expectf(t, rb != nil, "%s: item_band box exists", label, loc = loc) { return }

	// 1. Box rect matches expected on-screen rectangle.
	r := rb.rect
	testing.expectf(t, abs(r.min.x - want.min.x) <= 2 && abs(r.min.y - want.min.y) <= 2 && abs(r.max.x - want.max.x) <= 2 && abs(r.max.y - want.max.y) <= 2,
		"%s: band rect %v matches expected %v", label, r, want, loc = loc)

	// 2. Band box is clipped inside the view and visible inside its effective ancestor clip.
	clip := effective_clip(s, rb)
	testing.expectf(t, rb.parent == view, "%s: band parent is view box %q, got %q", label, view.name, rb.parent != nil ? rb.parent.name : "", loc = loc)
	vis := ui.Rect{{max(r.min.x, clip.min.x), max(r.min.y, clip.min.y)}, {min(r.max.x, clip.max.x), min(r.max.y, clip.max.y)}}
	testing.expectf(t, vis.max.x - vis.min.x >= (r.max.x - r.min.x) - 2 && vis.max.y - vis.min.y >= (r.max.y - r.min.y) - 2,
		"%s: band rect %v unclipped inside %v (visible %v)", label, r, clip, vis, loc = loc)

	// 3. Draw order: band draws AFTER every visible item inside `view`.
	band_idx := draw_order_index(s.state.root, rb)
	item_idx := max_item_draw_index(s.state.root, view, rb)
	testing.expectf(t, band_idx > item_idx, "%s: band draw order (%d) is after items (%d)", label, band_idx, item_idx, loc = loc)

	// 4. Pixels on the software renderer: border matches accent and differs from pre-drag frame; interior differs.
	after := session.capture(s)
	ui.use(s.state)
	accent := srgb_u8(ui.color("accent"))
	x0, y0 := int(math.round(r.min.x)), int(math.round(r.min.y))
	x1, y1 := int(math.round(r.max.x)) - 1, int(math.round(r.max.y)) - 1
	mid_x, mid_y := (x0 + x1) / 2, (y0 + y1) / 2

	border_hits := 0
	for p in ([4][2]int{{mid_x, y0}, {mid_x, y1}, {x0, mid_y}, {x1, mid_y}}) {
		// Check the pixel and its 1px inner neighbour in case of rounding.
		best_dist := 999
		for dy in -1 ..= 1 {
			for dx in -1 ..= 1 {
				got := session.pixel(after, p.x + dx, p.y + dy)
				best_dist = min(best_dist, px_diff(got, accent))
			}
		}
		if best_dist <= 20 { border_hits += 1 }
	}
	testing.expectf(t, border_hits == 4, "%s: all 4 band border edges show accent %v (got %d/4, rect=%v)", label, accent, border_hits, r, loc = loc)

	interior_changed := 0
	for py := y0 + 4; py < y1 - 3; py += 4 {
		for px := x0 + 4; px < x1 - 3; px += 4 {
			if px_diff(session.pixel(after, px, py), session.pixel(before, px, py)) >= 6 { interior_changed += 1 }
		}
	}
	testing.expectf(t, interior_changed > 0, "%s: band interior pixels differ from pre-drag frame (rect=%v)", label, r, loc = loc)
}

@(private = "file")
ctrl_event :: proc(s: ^session.Session, kind: platform.Event_Kind, at: [2]f32) {
	s.pointer = at
	if kind == .Mouse_Press { s.buttons += {.Left} }
	if kind == .Mouse_Release { s.buttons -= {.Left} }
	session.event(s, {kind = kind, button = .Left, pos = at, mods = {.Ctrl}})
	session.frames(s, 2)
}

// Band visibility in all four views (Details, List, Columns, Grid) at scroll 0 AND scrolled, in dark and light palettes,
// inside an offset padded clipped parent.
@(test)
band_is_drawn_in_every_view_at_scroll_zero_and_scrolled :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Case :: struct {
		name:     string,
		zoom:     int,
		view_box: string,
		light:    bool,
		scrolled: bool,
		wide:     bool,
	}
	cases := [?]Case{
		{"Details dark scroll0",  0, "rows", false, false, false},
		{"Details light scroll0", 0, "rows", true,  false, false},
		{"Details dark scrolled", 0, "rows", false, true,  false},
		{"Details wide scrolledX",0, "rows", false, true,  true},
		{"List dark scroll0",     1, "rows", false, false, false},
		{"List light scrolled",   1, "rows", true,  true,  false},
		{"Columns dark scroll0",  2, "cols", false, false, false},
		{"Columns light scrolled",2, "cols", true,  true,  false},
		{"Grid dark scroll0",     3, "grid", false, false, false},
		{"Grid light scrolled",   3, "grid", true,  true,  false},
	}

	for tc in cases {
		app: BV_App
		n := tc.scrolled ? 80 : 3
		bv_init(&app, n, tc.zoom, tc.wide)
		app.offset = true
		s := session.start(t, {
			size = BV_WIN,
			palette = ui.palette_of("Midnight", light = tc.light),
			build = bv_build,
			user = &app,
		})
		session.frames(s, 3)

		view := session.get(s, tc.view_box)
		if tc.scrolled {
			if tc.zoom == 2 {
				// Columns scrolls horizontally.
				view.view_off.x, view.view_target.x = 180, 180
			} else if tc.wide {
				view.view_off.x, view.view_target.x = 120, 120
				view.view_off.y, view.view_target.y = 220, 220
			} else {
				view.view_off.y, view.view_target.y = 220, 220
			}
			session.frames(s, 3)
			view = session.get(s, tc.view_box)
		}

		before := session.capture(s)

		from, to: [2]f32
		if !tc.scrolled {
			// Start in empty space below/right of the 3 items, drag up-left across items.
			from = {view.rect.max.x - 40, view.rect.max.y - 30}
			to = {view.rect.min.x + 40, view.rect.min.y + 30}
			session.press(s, from)
			session.move(s, to)
			session.frames(s, 1)
		} else {
			// Full scrolled view: start via Ctrl+press on a visible item (in Grid: also works on empty gap).
			from = {view.rect.min.x + 220, view.rect.min.y + 60}
			to = {view.rect.min.x + 60, view.rect.min.y + 180}
			session.move(s, from)
			ctrl_event(s, .Mouse_Press, from)
			ctrl_event(s, .Mouse_Move, to)
		}

		want := ui.Rect{{min(from.x, to.x), min(from.y, to.y)}, {max(from.x, to.x), max(from.y, to.y)}}
		check_band_drawn(t, s, view, want, before, tc.name)

		if tc.scrolled {
			ctrl_event(s, .Mouse_Release, to)
		} else {
			session.release(s, to)
		}
		bv_destroy(&app)
	}
}) }

// A custom view calling item_band_update OUTSIDE parent(box), inside a scrolling, clipped, padded parent away from origin.
@(test)
band_in_scrolling_parent_outside_box_scope :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Outer_App :: struct {
		band: ui.Item_Band,
		sel:  ui.Item_Selection,
	}
	app := Outer_App{sel = {sel = -1, multi = true}}
	defer { ui.item_band_destroy(&app.band); ui.item_selection_destroy(&app.sel) }

	s := session.start(t, {size = {500, 380}, user = &app, build = proc(s: ^session.Session) {
		app := (^Outer_App)(s.user)
		ui.next({width = ui.fill(), height = ui.px(40)})
		_ = ui.build_box({.Draw_Background}, "###hdr")
		ui.next({width = ui.px(420), height = ui.px(280), axis = .Y})
		if ui.scroll_y("###outer_scroll") {
			ui.spacer(ui.px(260), exact = true)
			ui.next({width = ui.px(360), height = ui.px(260), axis = .Y})
			box := ui.build_box({.Clickable, .Clip, .Draw_Background}, "###inner_view")
			rows := ui.Item_Rows{count = 10}
			if ui.parent(box) {
				for i in 0 ..< 10 {
					lit := ui.item_selection_has(&app.sel, rows, i)
					if lit { ui.push_tags("selected") }
					ui.next({width = ui.fill(), height = ui.px(22)})
					_ = ui.build_box(lit ? ui.Box_Flags{.Draw_Background} : {}, fmt.tprintf("row %d###r%d", i, i))
					if lit { ui.pop_tags() }
				}
			}
			// Called OUTSIDE parent(box), where parent_box() is ###outer_scroll!
			layout := ui.Item_Band_Layout{kind = .Columns, count = 10, item_w = 360, step = 360, row_h = 22}
			_ = ui.item_band_update(&app.band, &app.sel, rows, box, layout, false)
		}
	}})
	session.frames(s, 3)

	// Scroll outer_scroll so inner_view moves into view at a non-zero outer view_off.
	outer := session.get(s, "outer_scroll")
	outer.view_off.y, outer.view_target.y = 220, 220
	session.frames(s, 3)

	view := session.get(s, "inner_view")
	before := session.capture(s)
	from := [2]f32{view.rect.min.x + 30, view.rect.min.y + 30}
	to := [2]f32{view.rect.min.x + 210, view.rect.min.y + 150}
	session.press(s, from)
	session.move(s, to)
	session.frames(s, 1)

	check_band_drawn(t, s, view, {from, to}, before, "scrolling parent outside box scope")
	session.release(s, to)
}) }

// A single pointer move that changes selection inside item_band_update must ask for another frame so rows built before
// item_band_update repaint immediately.
@(test)
band_move_requests_frame_when_selection_changes :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	app: BV_App
	bv_init(&app, 4, 0)
	defer bv_destroy(&app)
	s := session.start(t, {size = BV_WIN, build = bv_build, user = &app, no_renderer = true})
	session.frames(s, 3)
	view := session.get(s, "rows")
	from := [2]f32{view.rect.max.x - 40, view.rect.max.y - 30}
	to := [2]f32{view.rect.min.x + 40, view.rect.min.y + 10}
	session.press(s, from)
	session.wait_idle(s)
	// Inject a single move and run exactly one frame.
	s.pointer = to
	session.event(s, {kind = .Mouse_Move, pos = to})
	session.frame(s)
	testing.expect(t, len(ui.list_selected_ids(&app.t.vl)) > 0, "selection changed on the move frame")
	testing.expect(t, ui.needs_frame(s.state), "needs_frame is true so rows built earlier repaint")
	session.release(s, to)
}) }

// Starting a Ctrl+band on a virtualized row or card and autoscrolling past it must not end the band when the pressed
// box leaves the built range (boxes_gone).
@(test)
ctrl_band_survives_pressed_row_leaving_virtual_range :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	// Details view
	{
		app: BV_App
		bv_init(&app, 120, 0)
		defer bv_destroy(&app)
		s := session.start(t, {size = BV_WIN, build = bv_build, user = &app, no_renderer = true})
		session.frames(s, 3)
		view := session.get(s, "rows")
		row0 := session.get(s, "lrow_0")
		c0 := session.get(s, "c0", within = row0)
		// Press on row 0's name text (content) with Ctrl so item_band_begin starts on the row itself.
		from := [2]f32{c0.rect.min.x + 12, (row0.rect.min.y + row0.rect.max.y) * 0.5}
		session.move(s, from)
		ctrl_event(s, .Mouse_Press, from)
		testing.expect(t, app.t.band.active, "Details: Ctrl+press on a row's content starts the band")
		edge := [2]f32{from.x + 80, view.rect.max.y - 4}
		ctrl_event(s, .Mouse_Move, edge)
		for _ in 0 ..< 120 {
			session.frame(s)
			if app.t.vl.first > 5 { break }
		}
		testing.expectf(t, app.t.vl.first > 5, "Details: autoscroll moved row 0 out of built range (first=%d)", app.t.vl.first)
		testing.expect(t, app.t.band.active, "Details: band stays active after pressed row leaves virtual range")
		testing.expect(t, session.find(s, "item_band") != nil, "Details: band rect box stays built")
		ctrl_event(s, .Mouse_Release, edge)
	}
	// Grid view
	{
		app: BV_App
		bv_init(&app, 120, 3)
		defer bv_destroy(&app)
		s := session.start(t, {size = BV_WIN, build = bv_build, user = &app, no_renderer = true})
		session.frames(s, 3)
		view := session.get(s, "grid")
		card0 := session.get(s, "item0")
		from := session.center(card0)
		session.move(s, from)
		ctrl_event(s, .Mouse_Press, from)
		testing.expect(t, app.t.band.active, "Grid: Ctrl+press on a card starts the band")
		edge := [2]f32{from.x + 80, view.rect.max.y - 4}
		ctrl_event(s, .Mouse_Move, edge)
		for _ in 0 ..< 120 {
			session.frame(s)
			if app.t.grid.first > 4 { break }
		}
		testing.expectf(t, app.t.grid.first > 4, "Grid: autoscroll moved card 0 out of built range (first=%d)", app.t.grid.first)
		testing.expect(t, app.t.band.active, "Grid: band stays active after pressed card leaves virtual range")
		testing.expect(t, session.find(s, "item_band") != nil, "Grid: band rect box stays built")
		ctrl_event(s, .Mouse_Release, edge)
	}
}) }

// Band drawn over already-selected rows in dark and light themed palettes (Midnight and Ember), with partial redraw,
// both at scroll 0 and scrolled.
@(test)
band_visible_over_selected_rows_dark_and_light :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Case :: struct {
		label:   string,
		theme:   string,
		light:   bool,
		partial: bool,
	}
	cases := [?]Case{
		{"Midnight dark over selected",  "Midnight", false, false},
		{"Midnight light over selected", "Midnight", true,  false},
		{"Ember dark partial redraw",    "Ember",    false, true},
		{"Ember light partial redraw",   "Ember",    true,  true},
	}
	for tc in cases {
		app: BV_App
		bv_init(&app, 40, 0)
		app.offset = true
		s := session.start(t, {
			size = BV_WIN,
			palette = ui.palette_of(tc.theme, light = tc.light),
			build = bv_build,
			user = &app,
		})
		if tc.partial { ui.set_partial_redraw(s.state, true) }
		session.frames(s, 3)

		// Scroll down and select all rows so the entire band sits over already-selected rows.
		view := session.get(s, "rows")
		view.view_off.y, view.view_target.y = 180, 180
		ui.list_select_all(&app.t.vl)
		session.frames(s, 3)
		view = session.get(s, "rows")

		before := session.capture(s)
		from := [2]f32{view.rect.min.x + 220, view.rect.min.y + 40}
		to := [2]f32{view.rect.min.x + 60, view.rect.min.y + 170}
		session.move(s, from)
		ctrl_event(s, .Mouse_Press, from)
		ctrl_event(s, .Mouse_Move, to)

		want := ui.Rect{{min(from.x, to.x), min(from.y, to.y)}, {max(from.x, to.x), max(from.y, to.y)}}
		check_band_drawn(t, s, view, want, before, tc.label)

		ctrl_event(s, .Mouse_Release, to)
		bv_destroy(&app)
	}
}) }

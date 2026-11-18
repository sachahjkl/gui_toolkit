// A virtual list's rows in a Fenwick tree (ui.vlist): a row measured anew is a point update, not a pass over the
// rows; the tops, the total and the row at a place agree with the heights added up one by one.
//   odin test tests/data_views -collection:gt=src -vet -define:ODIN_TEST_THREADS=1 (Linux: -define:FONT_BACKEND=native)
package data_views_test

import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") MILLION_ROWS :: 1_000_000
@(private = "file") MILLION_SCROLLS :: 100
@(private = "file") MILLION_SCROLL_PX :: 5000   // far enough that each scroll lays out rows never measured
@(private = "file") VLIST_W :: 300
@(private = "file") VLIST_H :: 150
// More rows than the first build (laid out at the window's height) and one scroll lay out: some stay estimated.
@(private = "file") SMALL_ROWS :: 200
@(private = "file") SMALL_SCROLL_PX :: 2000
@(private = "file") TOP_TOLERANCE :: 0.01

// Mixed heights, none the first estimate's, so that each row laid out is a new height.
@(private = "file")
row_height :: proc(i: int) -> f32 { return 17 + f32((i * 7) % 23) }

@(private = "file")
Vlist_App :: struct {
	vl:      ui.Virtual_List,
	ids:     []u64,
	version: u64,
	built:   int,   // the rows the last build built
}

@(private = "file")
build_vlist :: proc(s: ^session.Session) {
	app := (^Vlist_App)(s.user)
	ui.next({width = ui.px(VLIST_W), height = ui.px(VLIST_H)})
	if rows, ok := ui.vlist("###tree", &app.vl, app.ids, ids_version = app.version); ok {
		app.built = rows.last - rows.first
		for i in rows.first ..< rows.last {
			ui.next({height = ui.px(row_height(i))})
			ui.list_row(&app.vl, i, "")
		}
	}
}

// A list of a million rows scrolled a hundred times, each scroll laying out rows at heights never measured: the
// rows are not placed again for any of them (offsets_made stays), only when the ids change.
@(test)
a_million_rows_measured_are_not_placed_again :: proc(t: ^testing.T) {
	app := new(Vlist_App)
	app.ids = make([]u64, MILLION_ROWS)
	app.version = 1
	defer { ui.vlist_destroy(&app.vl); delete(app.ids); free(app) }
	for &id, i in app.ids { id = u64(i) + 1 }
	s := session.start(t, {build = build_vlist, user = app, no_renderer = true})
	// (the first builds: the ids placed once, the width known, the first rows measured)
	session.frames(s, 4)
	made := app.vl.offsets_made
	measured := len(app.vl.measured)
	for k in 1 ..= MILLION_SCROLLS {
		ui.vlist_scroll_to(&app.vl, f32(k * MILLION_SCROLL_PX))
		session.frames(s, 2)
	}
	testing.expectf(t, len(app.vl.measured) >= measured + MILLION_SCROLLS, "new rows measured (%d, from %d)", len(app.vl.measured), measured)
	testing.expect_value(t, app.vl.offsets_made, made)
	// a measured row's height is in the tree at once (the first row built: built the build before too, so measured)
	first := app.vl.first
	_, h := ui.vlist_row_extent(&app.vl, first)
	want, found := app.vl.measured[app.ids[first]]
	testing.expect(t, found, "the first row built is measured")
	testing.expect_value(t, h, want)
	testing.expect_value(t, h, row_height(first))
	// new ids: every row placed again, once
	app.version += 1
	session.frames(s, 3)
	testing.expect_value(t, app.vl.offsets_made, made + 1)
}

// A small list, some rows measured and the others estimated: each row's top is the heights above it added up, the
// total is all of them, and the row at a place is the row whose extent holds it.
@(test)
the_row_tops_agree_with_the_heights_added_up :: proc(t: ^testing.T) {
	app := new(Vlist_App)
	app.ids = make([]u64, SMALL_ROWS)
	defer { ui.vlist_destroy(&app.vl); delete(app.ids); free(app) }
	for &id, i in app.ids { id = u64(i) + 1 }
	s := session.start(t, {build = build_vlist, user = app, no_renderer = true})
	session.frames(s, 4)
	ui.vlist_scroll_to(&app.vl, SMALL_SCROLL_PX)   // (rows measured in the middle, estimated below)
	session.frames(s, 4)
	n_measured := 0
	top: f64   // (added up in f64: the f32 sum of a few hundred rows drifts past the tolerance)
	for id, i in app.ids {
		h, found := app.vl.measured[id]
		if !found { h = app.vl.est } else { n_measured += 1 }
		got_top, got_h := ui.vlist_row_extent(&app.vl, i)
		testing.expectf(t, abs(f64(got_top) - top) < TOP_TOLERANCE, "row %d's top: %v, added up %v", i, got_top, top)
		testing.expectf(t, abs(f64(ui.vlist_row_top(&app.vl, i)) - top) < TOP_TOLERANCE, "row %d's top alone", i)
		testing.expectf(t, abs(got_h - h) < TOP_TOLERANCE, "row %d's height: %v, not %v", i, got_h, h)
		if found { testing.expect_value(t, h, row_height(i)) }
		testing.expect_value(t, ui.vlist_row_at(&app.vl, f32(top) + h * 0.5), i)
		top += f64(h)
	}
	testing.expect(t, n_measured > 0 && n_measured < SMALL_ROWS, "some rows measured, some estimated")
	total := ui.vlist_total(&app.vl)
	testing.expectf(t, abs(f64(total) - top) < TOP_TOLERANCE, "the total: %v, added up %v", total, top)
	testing.expect_value(t, ui.vlist_row_at(&app.vl, -1), 0)
	testing.expect_value(t, ui.vlist_row_at(&app.vl, total + 100), SMALL_ROWS - 1)
}

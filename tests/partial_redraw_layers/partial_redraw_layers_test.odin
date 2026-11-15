// Partial redraw under what covers a change (ui.set_partial_redraw, draw.damage_auto): a dialog, an internal window, a
// table's masked layer, framed panels. Each partial frame is the whole frame to the byte, and no pixel is left less than
// opaque, in both frame formats (8 bits and half floats). A process of its own: with tests/partial_redraw's scenes, one
// package passed 420 s on WebGPU's WARP, where the verify draws each frame twice.
//   odin test tests/partial_redraw_layers -collection:gt=src -vet -define:ODIN_TEST_THREADS=1
package partial_redraw_layers_test

import "core:fmt"
import "core:testing"
import "gt:markdown"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") ROW_HEIGHT :: 24
// Each scene runs in both frame formats (src/md/infrastructure/frame-formats.md).
@(private = "file") FORMATS :: [2]bool{false, true}

////////////////////////////////
// What covers a change is drawn again over it, and no pixel is left less than opaque (expect_opaque: a pixel with an
// alpha under 1, or a value past [0, 1], is a hole where a translucent window shows what is behind it)

@(private = "file") UNDER_W :: 640
@(private = "file") UNDER_H :: 480
@(private = "file") UNDER_WINDOW :: [2]int{UNDER_W, UNDER_H}
@(private = "file") UNDER_ROWS :: 30
@(private = "file") UNDER_LIST_H :: 160
@(private = "file") UNDER_FADE :: 20
@(private = "file") UNDER_STEPS :: 8
@(private = "file") UNDER_STEP_PX :: 70
@(private = "file") UNDER_BAND_PX :: 40
// The most a step may redraw: the band where it was and where it is (2 x 40 x 480), its reach around, room to spare;
// a quarter of the window.
@(private = "file") UNDER_PARTIAL_PX_MAX :: UNDER_W * UNDER_H / 4

@(private = "file")
Under_Body :: struct {
	rows: int,
}

@(private = "file")
Under :: struct {
	views:  ui.Views,
	body:   Under_Body,
	want:   bool,
	band_x: f32,   // where the page's band is: it moves under the dialog
}

// The page: a ground that never changes, and a band that moves, each a box of its own. (One box that drew both was one
// part whose bounds were the whole window: each move of the band redrew the whole frame.)
@(private = "file")
under_build :: proc(s: ^session.Session) {
	u := (^Under)(s.user)
	if u.want {
		ui.view_open(&u.views, "files", &u.body)
		u.want = false
	}
	ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(f32(UNDER_WINDOW.x)), height = ui.px(f32(UNDER_WINDOW.y)), radius = 0, bg = {0.85, 0.85, 0.8, 1}})
	ui.build_box({.Draw_Background}, "###page")
	ui.next({fixed_x = u.band_x, fixed_y = 0, width = ui.px(UNDER_BAND_PX), height = ui.px(f32(UNDER_WINDOW.y)), radius = 0, bg = {0.9, 0.2, 0.1, 1}})
	ui.build_box({.Draw_Background}, "###band")
}

@(private = "file")
under_view :: proc(v: ^ui.View, b: ^Under_Body) {
	b.rows = UNDER_ROWS
	if ui.dialog_body("under_body") {
		ui.next({width = ui.fill(), height = ui.px(UNDER_LIST_H), edge_fade = [4]f32{0, UNDER_FADE, 0, UNDER_FADE}})
		if ui.scroll_y("###under_list") {
			for i in 0 ..< b.rows {
				ui.next({width = ui.fill(), height = ui.px(ROW_HEIGHT)})
				ui.label(fmt.tprintf("File %d###file%d", i, i))
			}
		}
	}
}

// A page box changes under a dialog: wherever the region is, everything over it is drawn again in it, in its order: the
// scrim, the dialog, its list that fades at both edges (a masked layer). Each partial frame is the whole frame to the bit,
// and no pixel of the window is left less than opaque, in both frame formats.
@(test)
a_change_under_a_dialog_redraws_the_dialog_over_it :: proc(t: ^testing.T) { for half in FORMATS { under_scene(t, half) } }

@(private = "file")
under_scene :: proc(t: ^testing.T, half: bool) {
	u: Under
	defer ui.views_destroy(&u.views)
	ui.view_register(&u.views, "files", under_view, ui.View_Options{title = "Files"})
	s := session.start(t, {size = UNDER_WINDOW, build = under_build, user = &u, palette = ui.palette_of("Midnight", light = true), half_float = half})
	session.damage_verify(s)
	session.frames(s, 3)
	u.want = true
	session.wait_until(s, "modal_view_files", proc(s: ^session.Session, panel: string) -> bool {
		b := session.find(s, panel)
		return b != nil && b.transparency <= 0
	}, "the dialog to show")
	session.damage_settle(s)
	list := session.get(s, "under_list")
	session.wheel(s, session.center(list), {0, 2})
	session.damage_settle(s)
	testing.expect(t, session.get(s, "under_list").view_off.y > 0, "the list scrolled: both its edges fade")
	panel := session.get(s, "modal_view_files").rect
	under := 0   // the steps whose band, before or after it moved, lies under the dialog
	for k in 1 ..= UNDER_STEPS {
		was := u.band_x
		u.band_x = f32(k * UNDER_STEP_PX)
		session.frame(s)
		px, active := session.damage_px(s)
		// (where the band was and where it is, each a little wider than the band: far from the whole window)
		testing.expectf(t, active && px > 0 && px < UNDER_PARTIAL_PX_MAX, "step %d: a partial frame (%d px, active %v, why whole: %v)", k, px, active, ui.damage_stats(s.state).whole)
		for x in ([]f32{was, u.band_x}) {
			if x < panel.max.x && x + UNDER_BAND_PX > panel.min.x { under += 1; break }
		}
		session.expect_opaque(t, s, fmt.tprintf("step %d (the dialog at %v)", k, panel))
	}
	testing.expectf(t, under > 0, "the band moved under the dialog (at %v)", panel)
	session.damage_expect_exact(t, s, "a change under a dialog")
}

// An internal window (a view floated in the window: its frame, its shadow, its plate) over lines of text that change
// each step (a shell's output under it, opencode native's Statistics over a conversation): the text never shows through
// the window. Each partial frame is the whole frame to the bit, in both frame formats, in opencode native's finish
// (machined, its glow) and a flat one (every finish made the package pass 420 s on WebGPU's WARP).
@(private = "file") FLOAT_STEPS :: 3

@(private = "file")
Float_Run :: struct {
	views: ui.Views,
	body:  Under_Body,
	want:  bool,
	step:  int,
}

@(private = "file")
float_build :: proc(s: ^session.Session) {
	u := (^Float_Run)(s.user)
	if u.want {
		ui.view_open(&u.views, "files", &u.body)
		ui.view_present(&u.views, "files", .Internal)
		u.want = false
	}
	ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(f32(UNDER_WINDOW.x)), height = ui.px(f32(UNDER_WINDOW.y)), axis = .Y})
	if ui.column(id = "###lines") {
		for i in 0 ..< 24 {
			ui.next({width = ui.fill(), height = ui.px(ROW_HEIGHT), font = ui.mono_font()})
			ui.label(fmt.tprintf("line %d of step %d: /run/systemd/app.slice/opencode.service %d###line%d", i, u.step, u.step * 31 + i, i))
		}
	}
}

@(test)
text_that_changes_under_an_internal_window_stays_under_it :: proc(t: ^testing.T) { for half in FORMATS { float_scene(t, half) } }

@(private = "file")
float_scene :: proc(t: ^testing.T, half: bool) { for f in ([2]ui.Finish{.Machined, .Flat}) { float_scene_in(t, half, f) } }

@(private = "file")
float_scene_in :: proc(t: ^testing.T, half: bool, finish: ui.Finish) {
	u: Float_Run
	defer ui.views_destroy(&u.views)
	ui.view_register(&u.views, "files", under_view, ui.View_Options{title = "Files"})
	pal := ui.palette_of("Midnight")
	pal.finish = finish
	s := session.start(t, {size = UNDER_WINDOW, build = float_build, user = &u, palette = pal, half_float = half})
	s.state.theme.glow = 1
	session.damage_verify(s)
	session.frames(s, 3)
	u.want = true
	session.wait_until(s, "internal_view_files", proc(s: ^session.Session, frame: string) -> bool {
		b := session.find(s, frame)
		return b != nil && b.transparency <= 0
	}, "the internal window to show")
	session.damage_settle(s)
	for k in 1 ..= FLOAT_STEPS {
		u.step = k
		session.frame(s)
		session.damage_settle(s)
		session.expect_opaque(t, s, fmt.tprintf("step %d", k))
	}
	session.damage_expect_exact(t, s, fmt.tprintf("text that changes under an internal window, %v", finish))
}

// A Markdown table wider than its place (it scrolls sideways in a masked layer), inline code in its striped rows, in the
// machined finish on a light palette: the pointer over it (its corner's tool comes and goes) and a scroll sideways. Each
// partial frame is the whole frame to the byte; no pixel is left less than opaque around the code's chips.
@(private = "file") TABLE_WINDOW :: [2]int{640, 400}
@(private = "file") TABLE_COLUMN_PX :: 600
@(private = "file") TABLE_TEXT :: "| Name | What it does | Where it is |\n|---|---|---|\n" +
	"| `first` | reads the lines of a block and keeps the cases it meets | in the reader of blocks, under the parser |\n" +
	"| `case_lines` | splits a case into its lines, one run of code each | in the table code, beside the measure |\n" +
	"| `x` | a name that says little and stays short in its cell | nowhere in particular, a cell of the test |\n" +
	"| `case_lines` | the same name again, in a striped row of its own | in the second striped row of the table |\n"
@(private = "file") TABLE_MOVES :: 6

@(private = "file")
Table_Run :: struct {
	doc: markdown.Doc,
}

@(private = "file")
table_build :: proc(s: ^session.Session) {
	tr := (^Table_Run)(s.user)
	cfg := markdown.View_Options{user = tr, table_corner = proc(user: rawptr, t: ^markdown.Table, source: []string, size: f32) {
		_ = ui.button("table_copy", "Copy")
	}}
	ui.next({width = ui.px(TABLE_COLUMN_PX), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###doc") { markdown.view(&tr.doc, "md", TABLE_TEXT, cfg) }
}

@(test)
a_table_with_code_in_striped_rows_is_exact_and_opaque :: proc(t: ^testing.T) { for half in FORMATS { table_scene(t, half) } }

@(private = "file")
table_scene :: proc(t: ^testing.T, half: bool) {
	tr := Table_Run{doc = {alloc = context.allocator}}
	defer markdown.doc_destroy(&tr.doc)
	p := ui.palette_of("Midnight", light = true)
	p.finish = .Machined
	s := session.start(t, {size = TABLE_WINDOW, build = table_build, user = &tr, palette = p, half_float = half})
	session.damage_verify(s)
	session.damage_settle(s)
	session.expect_opaque(t, s, "shown")
	table := session.get(s, "hs").rect
	for k in 0 ..< TABLE_MOVES {
		// (across the table, row by row: its corner's tool comes, the rows under the pointer change nothing else)
		f := (f32(k) + 0.5) / TABLE_MOVES
		session.move(s, {table.min.x + 20 + f * (table.max.x - table.min.x - 40), table.min.y + f * (table.max.y - table.min.y)})
		session.damage_settle(s, 10)
		session.expect_opaque(t, s, fmt.tprintf("pointer move %d", k))
	}
	session.wheel(s, session.center(session.get(s, "hs")), {0, 2}, {.Shift})
	session.damage_settle(s)
	testing.expect(t, session.get(s, "hs").view_off.x > 0, "the table scrolled sideways: it is wider than its place")
	session.expect_opaque(t, s, "scrolled sideways")
	session.leave(s)
	session.damage_settle(s)
	session.expect_opaque(t, s, "the pointer gone")
	session.damage_expect_exact(t, s, "a table with code in its cells")
}

// A program's window as atelier builds it: everything in ui.views_frame, a page box, a list of framed panels (boxes
// tagged "input", each a check box and words), in the machined finish with its glow; then a dialog over them, and the
// dialog closed. No pixel is left less than opaque at any step, in both frame formats.
@(private = "file") PANELS_WINDOW :: [2]int{640, 480}
@(private = "file") PANEL_ROWS :: 8

@(private = "file")
Panels_Run :: struct {
	views:  ui.Views,
	body:   Under_Body,
	want:   bool,
	ticked: [PANEL_ROWS]bool,
}

@(private = "file")
panels_build :: proc(s: ^session.Session) {
	u := (^Panels_Run)(s.user)
	if u.want {
		ui.view_open(&u.views, "files", &u.body)
		u.want = false
	}
	if ui.views_frame(&u.views) {
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		page := ui.build_box({.Draw_Background}, "###page")
		if ui.parent(page) {
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.scroll_y("###panels") {
				for i in 0 ..< PANEL_ROWS {
					ui.spacer(ui.px(6))
					ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center, radius = 6})
					box: ^ui.Box
					if ui.tags("input") { box = ui.build_box({.Draw_Background, .Draw_Border}, fmt.tprintf("###panel%d", i)) }
					if ui.parent(box) {
						ui.next({width = ui.px(28), height = ui.px(28)})
						ui.checkbox("###box", "", &u.ticked[i])
						ui.next({width = ui.fill(), height = ui.px(44)})
						ui.label(fmt.tprintf("Program %d###name", i))
					}
				}
			}
		}
	}
}

@(test)
framed_panels_and_a_dialog_over_them_stay_opaque :: proc(t: ^testing.T) { for half in FORMATS { panels_scene(t, half) } }

@(private = "file")
panels_scene :: proc(t: ^testing.T, half: bool) {
	u: Panels_Run
	defer ui.views_destroy(&u.views)
	ui.view_register(&u.views, "files", under_view, ui.View_Options{title = "Files"})
	pal := ui.palette_of("Midnight")
	pal.finish = .Machined
	s := session.start(t, {size = PANELS_WINDOW, build = panels_build, user = &u, palette = pal, half_float = half})
	s.state.theme.glow = 1
	session.damage_verify(s)
	session.damage_settle(s)
	session.expect_opaque(t, s, "the panels")
	for i in 0 ..< 3 {
		session.move(s, session.center(session.get(s, fmt.tprintf("panel%d", i))))
		session.damage_settle(s, 20)
		session.expect_opaque(t, s, fmt.tprintf("the pointer over panel %d", i))
	}
	u.want = true
	session.wait_until(s, "modal_view_files", proc(s: ^session.Session, panel: string) -> bool {
		b := session.find(s, panel)
		return b != nil && b.transparency <= 0
	}, "the dialog to show")
	session.damage_settle(s)
	session.expect_opaque(t, s, "the dialog over the panels")
	session.key(s, .Escape)
	session.damage_settle(s)
	session.expect_opaque(t, s, "the dialog closed")
	session.damage_expect_exact(t, s, "framed panels and a dialog over them")
}

// atelier's Programs step: a head row of quiet buttons (one of them busy at times) above framed panels, on a page box.
// The pointer goes over each button, presses it and leaves; the busy one turns. Holes were seen on Windows in the strip
// between the buttons and the first panel. Each partial frame is the whole frame to the byte, and every frame is opaque,
// in every finish and both frame formats.
@(private = "file") QUIET_WINDOW :: [2]int{640, 360}
@(private = "file") QUIET_PANELS :: 3
@(private = "file") QUIET_BUTTONS :: [3]string{"check", "all", "none"}

@(private = "file")
Quiet_Run :: struct {
	busy:   bool,
	ticked: [QUIET_PANELS]bool,
}

@(private = "file")
quiet_build :: proc(s: ^session.Session) {
	u := (^Quiet_Run)(s.user)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	page := ui.build_box({.Draw_Background}, "###page")
	if !ui.parent(page) { return }
	ui.spacer(ui.px(12))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###select") {
		ui.spacer(ui.px(16))
		ui.next({width = ui.fill(), height = ui.px(28), text_pad = 0})
		ui.label("Choose the programs to install.###choose")
		_ = ui.button("###check", "Check for updates", o = {quiet = true, busy = u.busy})
		ui.spacer(ui.px(6))
		_ = ui.button("###all", "Select all", o = {quiet = true})
		ui.spacer(ui.px(6))
		_ = ui.button("###none", "Select none", o = {quiet = true})
		ui.spacer(ui.px(16))
	}
	for i in 0 ..< QUIET_PANELS {
		ui.spacer(ui.px(7))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.parent(ui.build_box({}, fmt.tprintf("###panel%d_line", i))) {
			ui.spacer(ui.px(16))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center, radius = 6})
			box: ^ui.Box
			if ui.tags("input") { box = ui.build_box({.Draw_Background, .Draw_Border}, fmt.tprintf("###panel%d", i)) }
			if ui.parent(box) {
				ui.next({width = ui.px(28), height = ui.px(28)})
				ui.checkbox("###box", "", &u.ticked[i])
				ui.next({width = ui.fill(), height = ui.px(56)})
				ui.label(fmt.tprintf("Program %d###name", i))
			}
			ui.spacer(ui.px(16))
		}
	}
}

@(test)
quiet_buttons_above_framed_panels_are_exact_and_opaque :: proc(t: ^testing.T) {
	for half in FORMATS { for f in ui.Finish { quiet_scene(t, half, f) } }
}

// A scale of Windows' displays: the buttons' edges and their shadows fall between pixels. (1, 1.25 and 1.5 all passed
// on WebGPU; one scale keeps the package within WARP's time.)
@(private = "file") QUIET_SCALE :: 1.25

@(private = "file")
quiet_scene :: proc(t: ^testing.T, half: bool, finish: ui.Finish) {
	u: Quiet_Run
	pal := ui.palette_of("Midnight")
	pal.finish = finish
	s := session.start(t, {size = QUIET_WINDOW, build = quiet_build, user = &u, palette = pal, half_float = half, dpi_scale = QUIET_SCALE, animations = true})
	s.state.theme.glow = 1
	session.damage_verify(s)
	session.damage_settle(s)
	session.expect_opaque(t, s, fmt.tprintf("%v: shown", finish))
	for name in QUIET_BUTTONS {
		at := session.center(session.get(s, name))
		session.move(s, at)
		session.damage_settle(s, 20)
		session.expect_opaque(t, s, fmt.tprintf("%v: over %s", finish, name))
		session.press(s, at)
		session.damage_settle(s, 20)
		session.expect_opaque(t, s, fmt.tprintf("%v: %s pressed", finish, name))
		session.release(s, at)
		session.damage_settle(s, 20)
		// (under the panels' strip: the pointer leaves downward, over the gap and the first panel)
		session.move(s, {at.x, session.get(s, "panel0").rect.min.y - 2})
		session.damage_settle(s, 20)
		session.move(s, session.center(session.get(s, "panel0")))
		session.damage_settle(s, 20)
		session.expect_opaque(t, s, fmt.tprintf("%v: left %s", finish, name))
	}
	for busy in ([2]bool{true, false}) {
		u.busy = busy
		session.damage_settle(s, 30)
		session.expect_opaque(t, s, fmt.tprintf("%v: busy %v", finish, busy))
	}
	session.leave(s)
	session.damage_settle(s)
	session.damage_expect_exact(t, s, fmt.tprintf("quiet buttons above framed panels, %v", finish))
}

// Docking's chrome (ui/docking.odin, ui/panes.odin, ui/popups.odin): a folded side's strip in the theme's colours, the
// fold button of a stack's strip by the pointer and the keyboard, the strip's tooltip sized to its text and inside the
// window, under an app's style that fills (as a browser's chrome is built).
//   odin test tests/docking -vet -define:ODIN_TEST_THREADS=1
package docking_test

import "core:fmt"
import "core:testing"
import "../../testkit/session"
import "../../ui"

@(private = "file") CHROME_SIZE :: [2]int{500, 1000}   // a tall window: the folded strip is as tall
@(private = "file") REST_MS :: 1000                     // past the strip's tooltip delay
@(private = "file") DARK_MAX :: 0x50                    // no channel of a dark theme's surface (hovered or not) above this
@(private = "file") CHROME_TITLES := [?]string{"", "Alpha", "Beta"}
@(private = "file") LONG_TITLE :: "Beta, a panel whose name is long enough to take more than one line of a tooltip"

@(private = "file")
Chrome_App :: struct {
	dock:  ui.Dock,
	long:  bool,   // panel b has LONG_TITLE
}

@(private = "file")
chrome_build :: proc(s: ^session.Session) {
	app := (^Chrome_App)(s.user)
	// (an app's style that fills, as a browser builds its chrome under: a tooltip's content is its own size anyway)
	if ui.style({width = ui.fill(), height = ui.fill()}) {
		ui.dock_begin(&app.dock, "###dock", {title = proc(user: rawptr, id: u32) -> string {
			return id == 2 && (^Chrome_App)(user).long ? LONG_TITLE : CHROME_TITLES[id]
		}, user = app})
		for p in u32(1) ..= 2 { if ui.dock_panel(&app.dock, p) { ui.label(fmt.tprintf("%s content###content", CHROME_TITLES[p])) } }
		ui.dock_end(&app.dock)
	}
}

@(private = "file")
chrome_setup :: proc(t: ^testing.T, app: ^Chrome_App, layout: string) -> ^session.Session {
	ui.dock_init(&app.dock)
	testing.expect(t, ui.dock_parse(&app.dock, layout, id_of, nil))
	s := session.start(t, {build = chrome_build, user = app, size = CHROME_SIZE})
	session.frames(s, 2)
	return s
}

@(private = "file")
strip_box :: proc(s: ^session.Session, app: ^Chrome_App) -> ^ui.Box { return session.get(s, fmt.tprintf("dock_split_%d", app.dock.main)) }

@(private = "file")
rgba :: proc(c: u32) -> session.Color { return {u8(c >> 24), u8(c >> 16), u8(c >> 8), u8(c)} }

@(private = "file")
dark :: proc(c: session.Color) -> bool { return c.r <= DARK_MAX && c.g <= DARK_MAX && c.b <= DARK_MAX }

@(test)
a_folded_strip_takes_the_theme_colours :: proc(t: ^testing.T) {
	app: Chrome_App
	defer ui.dock_destroy(&app.dock)
	s := chrome_setup(t, &app, "dock1 x0.700f([*a] [*b])")
	h := strip_box(s, &app)
	testing.expect_value(t, h.rect.max.x, f32(CHROME_SIZE.x))
	// a quarter down the strip: no chevron, no edge
	x, y := int(session.center(h).x), int(h.rect.min.y + (h.rect.max.y - h.rect.min.y) * 0.25)
	rest := session.pixel(session.capture(s), x, y)
	testing.expectf(t, session.near(rest, rgba(ui.PALETTE_MIDNIGHT.panel)), "the strip is the bars' surface: %v", rest)
	session.move(s, session.center(h))
	hot := session.pixel(session.capture(s), x, y)
	testing.expectf(t, dark(hot) && hot != rest, "hovered: a step of the dark theme, %v", hot)
}

@(test)
the_fold_button_folds_and_the_strip_brings_it_back :: proc(t: ^testing.T) {
	app: Chrome_App
	defer ui.dock_destroy(&app.dock)
	s := chrome_setup(t, &app, "dock1 x0.700([*a] [*b])")
	split := app.dock.main
	testing.expect(t, session.find(s, "dock_fold", 1) == nil, "one button: the stack on the side that folds")
	fold := session.get(s, "dock_fold")
	menu := session.find(s, "dock_menu_btn", 1)
	if !testing.expect(t, menu != nil) { return }
	testing.expect_value(t, fold.rect.max - fold.rect.min, menu.rect.max - menu.rect.min)
	testing.expect(t, fold.a11y != nil && fold.a11y.role == .Button && fold.a11y.expanded.? == true)
	// the pointer
	session.click(s, "dock_fold")
	testing.expect(t, app.dock.nodes[split].fold, "folded by its button")
	session.click_at(s, session.center(strip_box(s, &app)))
	testing.expect(t, !app.dock.nodes[split].fold, "back by a click on the strip")
	// the keyboard: from the stack's tab, Tab goes to the button, Enter folds; Enter on the strip brings it back
	session.click(s, "dock_tab_2")
	session.key(s, .Tab)
	testing.expect_value(t, session.focused_name(s), "dock_fold")
	session.key(s, .Return)
	testing.expect(t, app.dock.nodes[split].fold, "folded by Enter on its button")
	ui.set_focus(strip_box(s, &app).key)
	session.frame(s)
	session.key(s, .Return)
	testing.expect(t, !app.dock.nodes[split].fold, "back by Enter on the strip")
}

@(test)
a_tooltip_over_a_tall_strip_fits_its_text :: proc(t: ^testing.T) {
	app: Chrome_App
	defer ui.dock_destroy(&app.dock)
	s := chrome_setup(t, &app, "dock1 x0.700f([*a] [*b])")
	em := ui.font_size()
	window := ui.Rect{{0, 0}, {f32(CHROME_SIZE.x), f32(CHROME_SIZE.y)}}
	inside :: proc(r, w: ui.Rect) -> bool { return r.min.x >= w.min.x && r.min.y >= w.min.y && r.max.x <= w.max.x && r.max.y <= w.max.y }
	sizes: [2]ui.Vec2   // short, long
	for long, k in ([]bool{false, true}) {
		app.long = long
		session.leave(s)
		session.move(s, session.center(strip_box(s, &app)))
		session.advance(s, REST_MS)
		tip := session.get(s, "tooltip")
		sizes[k] = tip.rect.max - tip.rect.min
		testing.expectf(t, inside(tip.rect, window), "inside the window: %v", tip.rect)
	}
	// (one line of its own width; the long one at the most width, on more lines)
	max_w := ui.TOOLTIP_MAX_WIDTH_EM * em
	testing.expectf(t, sizes[0].x < max_w && sizes[0].y < 3 * em, "the short one: %v", sizes[0])
	testing.expectf(t, sizes[1].x <= max_w + em && sizes[1].x > sizes[0].x && sizes[1].y > sizes[0].y + em, "the long one wraps: %v", sizes[1])
	// at the bottom of the window: above the pointer
	at := [2]f32{session.center(strip_box(s, &app)).x, f32(CHROME_SIZE.y) - em}
	session.leave(s)
	session.move(s, at)
	session.advance(s, REST_MS)
	session.frame(s)   // (placed by its size of the frame before)
	tip := session.get(s, "tooltip")
	testing.expectf(t, tip.rect.max.y <= at.y && inside(tip.rect, window), "above the pointer: %v", tip.rect)
}

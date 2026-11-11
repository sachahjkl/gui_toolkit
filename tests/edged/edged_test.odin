package edged_test

// The edged finish: the machined reliefs drawn crisp. A raised face has a lit line along its top and a dark one along its
// bottom, a well a dark line under its opening's top; nothing is blurred out of them (no soft shadow around a face).

import "core:fmt"
import "core:testing"
import "../../src/draw"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") EDGED_WINDOW :: [2]int{200, 120}
@(private = "file") FACE :: ui.Rect{{40, 30}, {160, 60}}
@(private = "file") HOLE :: ui.Rect{{40, 80}, {160, 110}}

@(private = "file")
reliefs_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	ui.machined_bevel(dc, FACE, 0, {0.2, 0.25, 0.35, 1}, 0, 0)
	ui.machined_well(dc, HOLE, 0, {0.03, 0.04, 0.06, 1})
}

@(private = "file")
reliefs :: proc(t: ^testing.T, finish: ui.Finish) -> ^session.Session {
	p := ui.palette_of("Midnight")
	p.finish = finish
	return session.start(t, {size = EDGED_WINDOW, palette = p, build = proc(s: ^session.Session) {
		ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(200), height = ui.px(120)})
		b := ui.build_box({}, "###reliefs")
		b.custom = reliefs_draw
	}})
}

@(private = "file")
sum :: proc(c: session.Color) -> int { return int(c.r) + int(c.g) + int(c.b) }

@(test)
an_edged_face_has_hairlines_and_no_shadow :: proc(t: ^testing.T) {
	img := session.capture(reliefs(t, .Edged))
	x := int(FACE.min.x + FACE.max.x) / 2
	top, under := session.pixel(img, x, int(FACE.min.y) + 1), session.pixel(img, x, int(FACE.min.y) + 3)
	testing.expectf(t, sum(top) > sum(under) + 12, "a lit line along its top: %v over %v", top, under)
	bottom, over := session.pixel(img, x, int(FACE.max.y) - 2), session.pixel(img, x, int(FACE.max.y) - 4)
	testing.expectf(t, sum(bottom) + 12 < sum(over), "a dark line along its bottom: %v under %v", bottom, over)
	edge := session.pixel(img, x, int(FACE.max.y) - 1)
	testing.expectf(t, sum(edge) < sum(bottom), "a dark hairline around it: %v", edge)
	page := session.pixel(img, 5, 5)
	for d in 1 ..= 3 {   // (the machined finish's shadow falls here)
		below := session.pixel(img, x, int(FACE.max.y) + d)
		testing.expectf(t, session.near(below, page, 1), "nothing blurred under it, %d px down: %v (the page %v)", d, below, page)
	}
	hole_top, hole := session.pixel(img, x, int(HOLE.min.y) + 1), session.pixel(img, x, int(HOLE.min.y) + 6)
	testing.expectf(t, sum(hole_top) < sum(hole), "a well: a dark line under its top, %v over %v", hole_top, hole)
	session.save_png(reliefs(t, .Edged), "edged.png")
}

// The same reliefs in the machined finish do cast a shadow: the test above sees the difference.
@(test)
a_machined_face_casts_a_shadow :: proc(t: ^testing.T) {
	img := session.capture(reliefs(t, .Machined))
	x := int(FACE.min.x + FACE.max.x) / 2
	below, page := session.pixel(img, x, int(FACE.max.y) + 2), session.pixel(img, 5, 5)
	testing.expectf(t, !session.near(below, page, 1), "a soft shadow under it: %v (the page %v)", below, page)
}

@(test)
kernel_is_dark_and_edged :: proc(t: ^testing.T) {
	p := ui.palette_of("Kernel")
	testing.expect_value(t, p.finish, ui.Finish.Edged)
	testing.expect(t, p.dark)
	testing.expect_value(t, ui.finish_of("edged"), ui.Finish.Edged)
	th: ui.Theme
	defer ui.theme_destroy(&th)
	ui.apply_palette(&th, p)
	testing.expect_value(t, th.finish, ui.Finish.Edged)
	light := p
	light.dark = false   // (the reliefs are made for the dark)
	ui.apply_palette(&th, light)
	testing.expect_value(t, th.finish, ui.Finish.Flat)
}

// The built-in widgets in Kernel, for the eye: build/session/console_widgets/console.png.
@(test)
console_widgets :: proc(t: ^testing.T) {
	Widgets :: struct { on, off: bool, level: f32, pick: int, field: ui.Text_Field }
	w: Widgets
	w.on, w.level, w.pick = true, 0.4, 1
	s := session.start(t, {size = {720, 560}, palette = ui.palette_of("Kernel"), user = &w, build = proc(s: ^session.Session) {
		w := (^Widgets)(s.user)
		ui.next({fixed_x = 16, fixed_y = 16, width = ui.px(688), height = ui.px(528)})
		if ui.column(id = "###page") {
			ui.title_strip("###strip", "boot")
			ui.spacer(ui.px(12))
			if ui.card("") {
				ui.section_header("###time", "The line of time", "a frame, from input to present", "11.4 ms", ui.hue(.Blue))
				ui.spacer(ui.px(10))
				ui.stacked_bar("###bar", {{1.0, ui.hue(.Purple), "1.0"}, {2.7, ui.hue(.Yellow), "2.7 ms"}, {3.5, ui.hue(.Blue), "3.5 ms"}, {2.1, ui.hue(.Cyan), "2.1 ms"}})
				ui.spacer(ui.px(14))
				ui.section_header("###files", "Files", "touched by this session", "", ui.hue(.Yellow))
				ui.spacer(ui.px(8))
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.flow({4, 4}) {
					names := [?]string{"overlays.odin", "types.odin", "rect.wgsl", "draw.odin", "machined.odin", "themes.odin", "settings.odin", "model.odin"}
					hues := [?]ui.Hue{.Rose, .Blue, .Green, .Purple, .Yellow, .Cyan, .Accent, .Red}
					for n, i in names { ui.tile(fmt.tprintf("###f%d", i), n, ui.hue(hues[i])) }
				}
			}
			if ui.card("Controls") {
				if ui.row(id = "###buttons") {
					ui.button("Archive###a"); ui.spacer(ui.px(8))
					ui.push_tags("accent_button"); ui.button("Send###s"); ui.pop_tags(); ui.spacer(ui.px(8))
					ui.push_tags("ghost_button"); ui.button("Cancel###c"); ui.pop_tags(); ui.spacer(ui.px(8))
					ui.next({width = ui.px(240)})
					ui.line_edit("###search", &w.field, "Search the sessions")
				}
				ui.spacer(ui.px(12))
				if ui.row(id = "###marks") {
					ui.checkbox("###on", "Watch", &w.on); ui.spacer(ui.px(16))
					ui.toggle("###off", "Glow", &w.off); ui.spacer(ui.px(16))
					ui.next({width = ui.px(200)})
					ui.slider("###level", &w.level, 0, 1)
					ui.spacer(ui.px(16))
					ui.segmented("###pick", {"All", "Active", "Done"}, &w.pick)
				}
				ui.spacer(ui.px(12))
				ui.next({width = ui.fill()})
				ui.progress("###p", 0.62)
			}
		}
	}})
	session.frames(s, 3)
	session.save_png(s, "console.png")
}

// A stacked bar's parts are as long as their shares: the colour of each is where its share puts it.
@(test)
a_stacked_bar_cuts_by_shares :: proc(t: ^testing.T) {
	s := session.start(t, {size = {400, 60}, palette = ui.palette_of("Kernel"), build = proc(s: ^session.Session) {
		ui.next({fixed_x = 0, fixed_y = 10, width = ui.px(400), height = ui.px(30)})
		ui.stacked_bar("###bar", {{1, {1, 0, 0, 1}, ""}, {3, {0, 1, 0, 1}, ""}})
	}})
	img := session.capture(s)
	left, right := session.pixel(img, 50, 25), session.pixel(img, 250, 25)
	testing.expectf(t, left.r > 200 && left.g < 40, "a quarter red: %v", left)
	testing.expectf(t, right.g > 200 && right.r < 40, "three quarters green: %v", right)
	edge := session.pixel(img, 102, 25)
	testing.expectf(t, edge.g > 200, "the cut at 100: %v", edge)
}

// The edged finish has square corners whatever the rounding asked: its hairlines run straight to the corners. A card's
// corner pixel is its edge, not the page.
@(test)
edged_corners_are_square :: proc(t: ^testing.T) {
	for finish in ([]ui.Finish{.Edged, .Machined}) {
		p := ui.palette_of("Kernel")
		p.finish = finish
		s := session.start(t, {size = {200, 120}, palette = p, build = proc(s: ^session.Session) {
			ui.next({fixed_x = 20, fixed_y = 20, width = ui.px(160), height = ui.px(80), radius = 12, bg = {0.3, 0.3, 0.3, 1}})
			ui.build_box({.Draw_Background}, "###face")
		}})
		testing.expect_value(t, ui.rounding(s.state), finish == .Edged ? 0 : 1)
		ui.use(s.state)   // (a switch's pill and a radio's disc are shapes: they keep their radius)
		testing.expect_value(t, ui.shape_rad(8), 8)
		testing.expect_value(t, ui.rad(8), finish == .Edged ? 0 : 8)
		corner, page := session.pixel(session.capture(s), 20, 20), session.pixel(session.capture(s), 5, 5)
		testing.expectf(t, session.near(corner, page, 2) == (finish != .Edged), "%v: the corner %v, the page %v", finish, corner, page)
	}
}

// An edged panel is outlined all around, its sides too: its edge is its border's colour, lit, not a dark line lost on a
// dark page (a dialog over its dimmed window).
@(test)
an_edged_panel_is_outlined_on_its_sides :: proc(t: ^testing.T) {
	s := session.start(t, {size = {200, 120}, palette = ui.palette_of("Kernel"), build = proc(s: ^session.Session) {
		ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(200), height = ui.px(120), bg = {0, 0, 0, 1}})
		if ui.column(flags = {.Draw_Background}, id = "###page") {
			ui.next({fixed_x = 40, fixed_y = 30, width = ui.px(120), height = ui.px(60), bg = ui.color("background"), border = ui.color("border")})
			ui.build_box({.Draw_Background, .Draw_Border, .Plate, .Draw_Shadow}, "###panel")
		}
	}})
	img := session.capture(s)
	left, inside, page := session.pixel(img, 40, 60), session.pixel(img, 45, 60), session.pixel(img, 20, 60)
	testing.expectf(t, sum(left) > sum(page) + 40 && sum(left) > sum(inside), "its left side: %v (inside %v, the page %v)", left, inside, page)
	right := session.pixel(img, 159, 60)
	testing.expectf(t, sum(right) > sum(page) + 40, "its right side: %v", right)
}

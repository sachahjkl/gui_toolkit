package scenarios_test

// The layout: sizes against what a box asks for, the room shared along a row, what is too much, wrapping, floating, DPI and zoom.

import "core:math"
import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{400, 300}

@(private = "file")
width_of :: proc(s: ^session.Session, name: string, loc := #caller_location) -> f32 { b := session.get(s, name, loc = loc); return b.rect.max.x - b.rect.min.x }
@(private = "file")
height_of :: proc(s: ^session.Session, name: string, loc := #caller_location) -> f32 { b := session.get(s, name, loc = loc); return b.rect.max.y - b.rect.min.y }

// A row of a fixed box, a firm share, and what fills the rest.
@(test)
a_row_shares_its_room :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.row(id = "###row") {
			ui.next({width = ui.px(100), height = ui.fill()})
			ui.build_box({}, "###fixed")
			ui.next({width = ui.pct(0.25, 1), height = ui.fill()})
			ui.build_box({}, "###share")
			ui.next({width = ui.fill(), height = ui.fill()})
			ui.build_box({}, "###rest")
		}
	}})
	testing.expect_value(t, width_of(s, "fixed"), 100)
	testing.expect_value(t, width_of(s, "share"), f32(WINDOW.x) * 0.25)
	testing.expect_value(t, width_of(s, "rest"), f32(WINDOW.x) - 100 - f32(WINDOW.x) * 0.25)
	testing.expect_value(t, session.get(s, "share").rect.min.x, session.get(s, "fixed").rect.max.x)
	testing.expect_value(t, session.get(s, "rest").rect.max.x, f32(WINDOW.x))
	testing.expect_value(t, height_of(s, "rest"), 40)
	session.resize(s, {WINDOW.x * 2, WINDOW.y})
	testing.expect_value(t, width_of(s, "fixed"), 100)
	testing.expect_value(t, width_of(s, "share"), f32(WINDOW.x) * 0.5)
}) }

// A column whose height is the sum of its children, its width the widest.
@(test)
a_box_can_take_its_size_from_its_children :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.children_sum(), height = ui.children_sum()})
		if ui.column(id = "###col") {
			ui.next({width = ui.px(50), height = ui.px(20)})
			ui.build_box({}, "###a")
			ui.next({width = ui.px(70), height = ui.px(30)})
			ui.build_box({}, "###b")
		}
	}})
	testing.expect_value(t, height_of(s, "col"), 50)
	testing.expect_value(t, width_of(s, "col"), 70)
	testing.expect_value(t, session.get(s, "b").rect.min.y, session.get(s, "a").rect.max.y)
}) }

// What is too wide gives way by its strictness: a box that may shrink does, one that may not keeps its size; what shrinks shares the loss by its size.
@(test)
what_may_shrink_shares_the_loss :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.row(id = "###row") {
			ui.next({width = ui.px(100), height = ui.fill()})
			ui.build_box({}, "###fixed")
			ui.next({width = ui.pct(0.25), height = ui.fill()})
			ui.build_box({}, "###soft_share")
			ui.next({width = ui.fill(), height = ui.fill()})
			ui.build_box({}, "###soft_rest")
		}
	}})
	testing.expect_value(t, width_of(s, "fixed"), 100)
	share, rest := width_of(s, "soft_share"), width_of(s, "soft_rest")
	testing.expect_value(t, 100 + share + rest, f32(WINDOW.x))
	testing.expect_value(t, rest, share * 4)
}) }

@(test)
what_is_too_much_gives_way_by_its_strictness :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.row(id = "###row") {
			ui.next({width = ui.px(300, 1), height = ui.fill()})
			ui.build_box({}, "###firm")
			ui.next({width = ui.px(300, 0), height = ui.fill()})
			ui.build_box({}, "###soft")
		}
	}})
	testing.expect_value(t, width_of(s, "firm"), 300)
	testing.expect_value(t, width_of(s, "soft"), f32(WINDOW.x) - 300)
}) }

@(private = "file")
Spacer_Row :: struct { width: f32 }

// An empty fill() spacer gives its width before a label is cut: a row of fixed parts, a name that may shrink and a
// spacer asking for the whole row keeps the name whole while the row holds it, and cuts it only by what is missing.
@(test)
a_spacer_gives_way_before_a_label :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Spacer_Row{1000}
	s := session.start(t, {size = {1200, 300}, no_renderer = true, user = &r, build = proc(s: ^session.Session) {
		r := (^Spacer_Row)(s.user)
		ui.next({width = ui.px(r.width), height = ui.px(24), axis = .X})
		if ui.row(id = "###row") {
			ui.next({width = ui.px(20), height = ui.fill()}); ui.build_box({}, "###indent")
			ui.next({width = ui.px(16), height = ui.fill()}); ui.build_box({}, "###chevron")
			ui.next({width = ui.px(16), height = ui.fill()}); ui.build_box({}, "###icon")
			ui.next({width = ui.text_size(0, 0), height = ui.fill()}); ui.label("A rather long node name###name")
			ui.next({width = ui.px(30), height = ui.fill()}); ui.build_box({}, "###count")
			ui.next({width = ui.px(60), height = ui.fill()}); ui.build_box({}, "###button")
			ui.spacer(ui.fill())
		}
	}})
	name := session.get(s, "name")
	natural := math.ceil(name.text_dim.x + 2 * name.text_pad)
	fixed := f32(20 + 16 + 16 + 30 + 60)
	testing.expect_value(t, width_of(s, "name"), natural)
	// room for all and 10 px more: the name whole, the spacer takes the 10 px
	r.width = fixed + natural + 10
	session.frame(s)
	testing.expect_value(t, width_of(s, "name"), natural)
	testing.expect_value(t, session.get(s, "button").rect.max.x, session.get(s, "row").rect.min.x + fixed + natural)
	// 20 px short: the name gives exactly those
	r.width = fixed + natural - 20
	session.frame(s)
	testing.expect_value(t, width_of(s, "name"), natural - 20)
	testing.expect_value(t, width_of(s, "button"), 60)
}) }

// label, spacer(fill()), what is at the right: with room the spacer pushes it to the right edge and the label is whole;
// short of room the label gives only what is missing.
@(test)
a_spacer_pushes_to_the_right_edge :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Spacer_Row{400}
	s := session.start(t, {size = {600, 300}, no_renderer = true, user = &r, build = proc(s: ^session.Session) {
		r := (^Spacer_Row)(s.user)
		ui.next({width = ui.px(r.width), height = ui.px(24), axis = .X})
		if ui.row(id = "###row") {
			ui.next({width = ui.text_size(0, 0), height = ui.fill()}); ui.label("Title of the panel###name")
			ui.spacer(ui.fill())
			ui.next({width = ui.px(60), height = ui.fill()}); ui.build_box({}, "###button")
		}
	}})
	name := session.get(s, "name")
	natural := math.ceil(name.text_dim.x + 2 * name.text_pad)
	row := session.get(s, "row")
	testing.expect_value(t, width_of(s, "name"), natural)
	testing.expect_value(t, session.get(s, "button").rect.max.x, row.rect.max.x)
	testing.expect_value(t, width_of(s, "button"), 60)
	r.width = natural + 60 - 10
	session.frame(s)
	testing.expect_value(t, width_of(s, "name"), natural - 10)
	testing.expect_value(t, session.get(s, "button").rect.max.x, session.get(s, "row").rect.max.x)
}) }

// The cross alignment of a row: centred children keep their own height, in the middle.
@(test)
a_row_centres_across :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.fill(), height = ui.px(100)})
		if ui.row(.Center, id = "###row") {
			ui.next({width = ui.px(50), height = ui.px(20)})
			ui.build_box({}, "###small")
		}
	}})
	b := session.get(s, "small")
	testing.expect_value(t, b.rect.min.y, 40)
	testing.expect_value(t, b.rect.max.y, 60)
}) }

// A flow wraps at the width of its box, and its height is its lines'.
@(test)
a_flow_wraps_into_lines :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {200, 300}, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.flow({10, 5}, "###flow") {
			names := [5]string{"###f0", "###f1", "###f2", "###f3", "###f4"}
			for n in names {
				ui.next({width = ui.px(60), height = ui.px(20)})
				ui.build_box({}, n)
			}
		}
	}})
	testing.expect_value(t, session.get(s, "f0").rect.min.y, session.get(s, "f1").rect.min.y)
	testing.expect_value(t, session.get(s, "f1").rect.min.x, 70)
	testing.expect(t, session.get(s, "f3").rect.min.y >= session.get(s, "f0").rect.max.y + 5, "the fourth does not fit: next line")
	testing.expect_value(t, session.get(s, "f3").rect.min.x, 0)
	testing.expect_value(t, height_of(s, "flow"), 2 * 20 + 5)
}) }

// Floating boxes do not take part in the layout, and what is clipped takes no click.
@(test)
what_is_clipped_takes_no_click :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Clicks :: struct { inside, outside: int }
	c: Clicks
	s := session.start(t, {size = WINDOW, no_renderer = true, user = &c, build = proc(s: ^session.Session) {
		c := (^Clicks)(s.user)
		ui.next({width = ui.px(100), height = ui.px(100), flags = {.Clip}})
		if ui.column(flags = {.Clip}, id = "###clip") {
			ui.next({fixed_x = 10, fixed_y = 10, width = ui.px(40), height = ui.px(40)})
			if ui.button("inside").clicked { c.inside += 1 }
			ui.next({fixed_x = 150, fixed_y = 10, width = ui.px(40), height = ui.px(40)})
			if ui.button("outside").clicked { c.outside += 1 }
		}
	}})
	session.click(s, "inside")
	testing.expect_value(t, c.inside, 1)
	session.click(s, "outside")
	testing.expect_value(t, c.outside, 0)
}) }

// The layout says what it sees as a mistake: a box with no room for its percent of a parent sized by its children.
@(test)
a_layout_mistake_is_said :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true, build = proc(s: ^session.Session) {
		ui.set_layout_warnings(s.state, true)
		ui.next({width = ui.children_sum(), height = ui.px(20)})
		if ui.row(id = "###row") {
			ui.next({width = ui.pct(1), height = ui.fill()})
			ui.build_box({}, "###asks_of_its_parent")
		}
	}})
	session.frame(s)
	testing.expect(t, len(ui.layout_warnings()) > 0, "a percent of a parent sized by its children")
}) }

// DPI: pixels are physical, sizes in the root style and px() in logical ones; the window keeps its logical size.
@(test)
a_scale_multiplies_what_is_logical :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.text_size()})
		ui.label("Some words###text")
		ui.next({width = ui.fill(), height = ui.px(ui.scale() * 40)})
		ui.build_box({}, "###band")
	}})
	h1 := height_of(s, "text")
	w1 := width_of(s, "text")
	band1 := height_of(s, "band")
	session.set_dpi(s, 2)
	testing.expect_value(t, s.win.dpi_scale, 2)
	testing.expect_value(t, s.win.size, [2]int{WINDOW.x * 2, WINDOW.y * 2})
	testing.expect_value(t, height_of(s, "text"), h1 * 2)
	testing.expectf(t, math.abs(width_of(s, "text") - w1 * 2) <= 2, "the text is twice as wide, near enough: %v and %v", w1, width_of(s, "text"))
	testing.expect_value(t, height_of(s, "band"), band1 * 2)
	testing.expect_value(t, width_of(s, "band"), f32(WINDOW.x * 2))
	session.set_dpi(s, 1)
	testing.expect_value(t, s.win.size, WINDOW)
	testing.expect_value(t, height_of(s, "text"), h1)
}) }

// A click lands by physical pixels at any scale, and the frame is the size of the window.
@(test)
at_a_scale_clicks_and_pixels_are_where_they_should_be :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Clicks :: struct { n: int }
	c: Clicks
	s := session.start(t, {size = WINDOW, user = &c, dpi_scale = 1.5, build = proc(s: ^session.Session) {
		c := (^Clicks)(s.user)
		ui.next({fixed_x = 30, fixed_y = 30, width = ui.px(60), height = ui.px(60), bg = {0, 1, 0, 1}})
		b := ui.build_box({.Clickable, .Draw_Background}, "###target")
		if ui.signal(b).clicked { c.n += 1 }
	}})
	session.click(s, "target")
	testing.expect_value(t, c.n, 1)
	img := session.capture(s)
	testing.expect_value(t, img.width, WINDOW.x)
	b := session.get(s, "target")
	testing.expect(t, session.near(session.pixel(img, int(session.center(b).x), int(session.center(b).y)), {0, 255, 0, 255}), "the box is where it says")
	testing.expect(t, !session.near(session.pixel(img, int(b.rect.max.x) + 2, int(session.center(b).y)), {0, 255, 0, 255}), "and ends where it says")
}) }

// Ctrl and the wheel, Ctrl + and Ctrl 0 zoom what the build says in logical pixels, and the fonts.
@(test)
the_zoom_is_a_scale_of_the_user_s :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, no_renderer = true, build = proc(s: ^session.Session) {
		ui.next({width = ui.text_size()})
		ui.label("Words###text")
	}})
	h := height_of(s, "text")
	session.key(s, .Equal, {.Ctrl})
	testing.expect_value(t, ui.zoom(s.state), 1.1)
	testing.expect(t, height_of(s, "text") > h, "bigger")
	session.key(s, .N0, {.Ctrl})
	testing.expect_value(t, ui.zoom(s.state), 1)
	testing.expect_value(t, height_of(s, "text"), h)
	session.wheel(s, {10, 10}, {0, 1}, {.Ctrl})
	testing.expect(t, ui.zoom(s.state) != 1, "Ctrl and the wheel")
}) }

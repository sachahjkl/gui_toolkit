package theme_look_test

// A theme's look beside its colours (src/md/features/theme-design.md): each value a theme gives reaches what is drawn,
// and a theme that gives none looks as before.

import "core:fmt"
import "core:math"
import "core:testing"
import "gt:draw"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") EM :: f32(session.BASE_FONT_SIZE)

////////////////////////////////
// Layer 1: shape per role

// The default radii are the constants every widget had: a theme that says none keeps its corners.
@(test)
the_default_shape_is_the_old_radii :: proc(t: ^testing.T) {
	d := ui.SHAPE_DEFAULT
	testing.expect_value(t, d[.Control], 0.45)
	testing.expect_value(t, d[.Row], 0.45)
	testing.expect_value(t, d[.Card], 0.6)
	testing.expect_value(t, d[.Dialog], 0.8)
	testing.expect_value(t, d[.Menu], 0.5)
	testing.expect_value(t, d[.Tooltip], 0.4)
	testing.expect_value(t, d[.Scroll_Thumb], 3)
	testing.expect_value(t, d[.Scroll_Arrow], 2)
	// (Old Head is made of its look: theme-design.md, layer 7)
	for th in ui.THEMES { if th.name != "Old Head" { testing.expectf(t, th.look == {}, "%s says no look of its own", th.name) } }
}

@(private = "file")
Shapes :: struct { list: ui.List_State, menu_open: bool }

@(private = "file")
shapes_build :: proc(s: ^session.Session) {
	r := (^Shapes)(s.user)
	ui.next({fixed_x = 20, fixed_y = 20, width = ui.px(300), height = ui.children_sum()})
	if ui.column(id = "###page") {
		if ui.card("T") { ui.button("ok", "OK") }
		ui.next({width = ui.px(300), height = ui.px(100)})
		if ui.list("###l", &r.list) {
			for i in 0 ..< 2 {
				ui.next({height = ui.px(28)})
				ui.list_row(&r.list, i, "row")
			}
		}
	}
	key := "m"
	if !r.menu_open { r.menu_open = true; ui.menu_open(key, ui.Vec2{200, 200}) }
	if ui.menu(key) { ui.menu_item("An item") }
}

// A theme's radius of a role is the radius its widgets get, times the font size.
@(test)
a_roles_radius_is_the_themes :: proc(t: ^testing.T) {
	shape := ui.SHAPE_DEFAULT
	shape[.Card], shape[.Control], shape[.Row], shape[.Menu] = 1, 0.3, 0.2, 0.25
	p := ui.palette_of("Midnight")
	p.look.shape = shape
	r: Shapes
	defer ui.list_state_destroy(&r.list)
	s := session.start(t, {size = {600, 400}, palette = p, user = &r, no_renderer = true, build = shapes_build})
	session.frames(s, 3)
	ui.use(s.state)
	testing.expect_value(t, ui.shape_of(.Card), 1)
	near :: proc(a, b: f32) -> bool { return math.abs(a - b) < 1e-3 }
	card := session.get(s, "card_T")
	testing.expectf(t, near(card.radius, EM * 1), "a card's radius: %v", card.radius)
	ok := session.get(s, "ok")
	testing.expectf(t, near(ok.radius, EM * 0.3), "a button's radius: %v", ok.radius)
	row := session.get(s, "lrow_0")
	testing.expectf(t, near(row.radius, EM * 0.2), "a row's radius: %v", row.radius)
	item: ^ui.Box
	for _, b in s.state.boxes { if b.a11y != nil && b.a11y.role == .Menu_Item && b.last_build == s.state.build_index { item = b } }
	if testing.expect(t, item != nil, "a menu's item") {
		testing.expectf(t, near(item.radius, EM * 0.2), "a menu's row: %v", item.radius)
		panel := item.parent
		for panel != nil && (.Plate not_in panel.flags) { panel = panel.parent }
		if testing.expect(t, panel != nil, "its menu") { testing.expectf(t, near(panel.radius, EM * 0.25), "a menu's panel: %v", panel.radius) }
	}
}

@(private = "file")
card_alone :: proc(s: ^session.Session) {
	ui.next({fixed_x = 20, fixed_y = 20, width = ui.px(160), height = ui.children_sum()})
	if ui.column(id = "###page") { if ui.card("C") { ui.spacer(ui.px(40)) } }
}

// A square card of the theme's is drawn square: its corner pixel is its edge, where a rounded one leaves the page.
@(test)
a_themes_square_card_is_drawn_square :: proc(t: ^testing.T) {
	for square in ([]bool{false, true}) {
		p := ui.palette_of("Midnight")
		p.finish = .Flat
		if square {
			shape := ui.SHAPE_DEFAULT
			shape[.Card] = 0
			p.look.shape = shape
		}
		s := session.start(t, {size = {200, 160}, palette = p, build = card_alone})
		session.frames(s, 2)
		card := session.get(s, "card_C")
		x, y := int(math.round(card.rect.min.x)), int(math.round(card.rect.min.y))
		img := session.capture(s)
		corner, page := session.pixel(img, x, y), session.pixel(img, 5, 5)
		testing.expectf(t, session.near(corner, page, 2) == !square, "square %v: the corner %v, the page %v", square, corner, page)
	}
}

////////////////////////////////
// Layer 2: selection per role, with its text colour

@(private = "file") NAVY :: 0x000080ff
@(private = "file") WHITE :: 0xffffffff

@(private = "file")
Rows :: struct { list: ui.List_State }

@(private = "file")
rows_build :: proc(s: ^session.Session) {
	r := (^Rows)(s.user)
	ui.next({fixed_x = 20, fixed_y = 20, width = ui.px(300), height = ui.px(200)})
	if ui.list("###l", &r.list) {
		for i in 0 ..< 3 {
			ui.next({height = ui.px(28)})
			if ui.parent(ui.list_row(&r.list, i, "row").box) {
				ui.next({width = ui.px(100)})
				ui.build_box({.Draw_Text}, fmt.tprintf("row %d###lbl_%d", i, i))
				ui.next({width = ui.px(60), bg = ui.Color{0.5, 0.5, 0.5, 1}})
				ui.build_box({.Draw_Text, .Draw_Background}, fmt.tprintf("key###key_%d", i))
			}
		}
	}
}

@(private = "file")
rows_selected :: proc(t: ^testing.T, p: ui.Palette, r: ^Rows) -> ^session.Session {
	s := session.start(t, {size = {400, 300}, palette = p, user = r, no_renderer = true, build = rows_build})
	ui.use(s.state)
	ui.list_set_selected(&r.list, 1)
	session.frames(s, 2)
	ui.use(s.state)
	return s
}

// A theme's selection of a list's row: its fill is the row's face, its ink the text of what the row holds, down to a
// box with a face of its own.
@(test)
a_selected_rows_text_is_the_themes_ink :: proc(t: ^testing.T) {
	p := ui.palette_of("Midnight")
	for role in ([]ui.Selection_Role{.List, .Weak}) { p.look.selections[role] = {fill = NAVY, ink = WHITE} }
	r: Rows
	defer ui.list_state_destroy(&r.list)
	s := rows_selected(t, p, &r)
	row := session.get(s, "lrow_1")
	testing.expect(t, .Chosen in row.flags, "row 1 is selected")
	testing.expectf(t, row.bg == draw.hex(NAVY), "its face is the theme's fill: %v", row.bg)
	testing.expectf(t, session.get(s, "lbl_1").text_color == draw.hex(WHITE), "its label is the theme's ink: %v", session.get(s, "lbl_1").text_color)
	text := ui.theme_lookup(s.state.theme, nil, "text")
	testing.expectf(t, session.get(s, "lbl_0").text_color == text, "a row not selected keeps the text: %v", session.get(s, "lbl_0").text_color)
	testing.expectf(t, session.get(s, "key_1").text_color == text, "a box with its own face keeps its text: %v", session.get(s, "key_1").text_color)
}

// A theme that gives no selection: a selected row's label has the text of every other label (the old look).
@(test)
no_ink_keeps_the_text :: proc(t: ^testing.T) {
	r: Rows
	defer ui.list_state_destroy(&r.list)
	s := rows_selected(t, ui.palette_of("Midnight"), &r)
	testing.expect_value(t, session.get(s, "lbl_1").text_color, session.get(s, "lbl_0").text_color)
	testing.expect_value(t, session.get(s, "lrow_1").ink.a, 0)
}

// The text's selection role sets the entries the selected text is drawn with.
@(test)
a_text_selection_is_the_themes :: proc(t: ^testing.T) {
	p := ui.palette_of("Midnight")
	p.look.selections[.Text] = {fill = NAVY, ink = WHITE}
	th: ui.Theme
	defer ui.theme_destroy(&th)
	ui.apply_palette(&th, p)
	testing.expect_value(t, ui.theme_lookup(&th, nil, "selection"), draw.hex(NAVY))
	testing.expect_value(t, ui.theme_lookup(&th, nil, "selection text"), draw.hex(WHITE))
	ui.apply_palette(&th, ui.palette_of("Midnight"))
	testing.expect(t, ui.theme_lookup(&th, nil, "selection").a < 0.5, "without it: the accent's tint")
}

////////////////////////////////
// Layer 3: focus style

@(private = "file") RED :: 0xff0000ff
@(private = "file") KEY :: ui.Rect{{40, 40}, {160, 70}}

@(private = "file")
key_build :: proc(s: ^session.Session) {
	ui.next({fixed_x = KEY.min.x, fixed_y = KEY.min.y, width = ui.px(KEY.max.x - KEY.min.x), height = ui.px(KEY.max.y - KEY.min.y)})
	ui.button("ok", "OK")
}

@(private = "file")
red :: proc(c: session.Color) -> bool { return c.r > 200 && c.g < 60 && c.b < 60 }

// A dotted focus: one dot every two pixels along the box's top, in the theme's colour; a ring is solid there.
@(test)
a_dotted_focus_is_dots :: proc(t: ^testing.T) {
	for style in ([]ui.Focus_Style{.Dotted, .Ring}) {
		p := ui.palette_of("Midnight")
		p.finish = .Flat
		p.look.focus = {style = style, width = 1, color = RED}
		s := session.start(t, {size = {200, 120}, palette = p, build = key_build})
		session.key(s, .Tab)
		session.frames(s, 2)
		img := session.capture(s)
		x, y := int(KEY.min.x) + 40, int(KEY.min.y)
		a, b := session.pixel(img, x, y), session.pixel(img, x + 1, y)
		if style == .Dotted {
			testing.expectf(t, red(a) && !red(b), "a dot, then none: %v %v", a, b)
		} else {
			testing.expectf(t, red(a) && red(b), "a solid ring: %v %v", a, b)
		}
	}
}

////////////////////////////////
// Layer 4: motion

// A still theme removes motion under the system's word; the person's On keeps it.
@(test)
a_still_theme_has_no_motion :: proc(t: ^testing.T) {
	p := ui.palette_of("Midnight")
	p.look.still = true
	s := session.start(t, {palette = p, animations = true, no_renderer = true, build = proc(s: ^session.Session) {}})
	ui.use(s.state)
	testing.expect(t, !ui.animations_on(), "a still theme: no motion")
	ui.set_animations(s.state, .On)
	session.frames(s, 1)
	ui.use(s.state)
	testing.expect(t, ui.animations_on(), "the person's On wins")
	moving := session.start(t, {animations = true, no_renderer = true, build = proc(s: ^session.Session) {}})
	ui.use(moving.state)
	testing.expect(t, ui.animations_on(), "a theme that says nothing keeps the motion")
}

////////////////////////////////
// Layer 5: font

@(private = "file")
label_build :: proc(s: ^session.Session) {
	ui.next({fixed_x = 10, fixed_y = 10})
	ui.build_box({.Draw_Text}, "Words###words")
}

// The theme's size factor scales the program's font size; a theme without one keeps it.
@(test)
a_themes_size_scales_the_font :: proc(t: ^testing.T) {
	p := ui.palette_of("Midnight")
	p.look.font.size = 2
	big := session.start(t, {palette = p, no_renderer = true, build = label_build})
	testing.expect_value(t, session.get(big, "words").font_size, 2 * EM)
	plain := session.start(t, {no_renderer = true, build = label_build})
	testing.expect_value(t, session.get(plain, "words").font_size, EM)
}

// The theme's family is the interface's while the person asked none; the person's family wins, even while it loads.
@(test)
the_persons_family_wins_over_the_themes :: proc(t: ^testing.T) {
	s := session.start(t, {no_renderer = true, build = label_build})
	themed := s.own.mono_font   // (a face that stands for the theme's family, loaded)
	s.state.text_themed.face = themed
	defer s.state.text_themed.face = 0
	testing.expect_value(t, ui.state_text_face(s.state, .Interface), themed)
	ui.use(s.state)
	ui.use_text_family(s.state, .Interface, "A family of the person's")
	testing.expect(t, ui.state_text_face(s.state, .Interface) != themed, "the person's word wins")
	ui.use_text_family(s.state, .Interface, "")
	testing.expect_value(t, ui.state_text_face(s.state, .Interface), themed)
}

////////////////////////////////
// Layer 6: relief as data

// Each finish is a preset whose flags say what each test of the finish said before: the same drawing, by its data.
@(test)
the_finishes_are_presets :: proc(t: ^testing.T) {
	for f in ui.Finish {
		rl := ui.relief_of(f)
		testing.expectf(t, rl.carved == (f == .Machined || f == .Edged), "%v: carved", f)
		testing.expectf(t, rl.square == (f == .Edged), "%v: square", f)
		testing.expectf(t, rl.sheen == (f != .Flat), "%v: sheen", f)
		testing.expectf(t, rl.engrave == (f == .Machined), "%v: engraved", f)
		testing.expectf(t, rl.extra != .None || f == .Flat, "%v: its look is its extra", f)
		testing.expectf(t, !rl.no_glow && !rl.no_hover && !rl.no_shadow && !rl.surface_tones, "%v: halos, hover, shadows kept", f)
		testing.expectf(t, rl.raised == {} && rl.sunken == {}, "%v: no rings: its edges are its extra's", f)
	}
	testing.expect_value(t, ui.relief_of(.Flat), ui.Relief{})
	testing.expect_value(t, ui.relief_of(.Gradient).face, ui.Face_Paint.Lit)
	testing.expect_value(t, ui.relief_of(.Glass).face, ui.Face_Paint.Gloss)
	testing.expect_value(t, ui.relief_of(.Machined).face, ui.Face_Paint.Strong)
	testing.expect_value(t, ui.relief_of(.Edged).face, ui.Face_Paint.Strong)
	testing.expect_value(t, ui.relief_of(.Glass).row, ui.Row_Paint.Glass)
	testing.expect_value(t, ui.relief_of(.Edged).row, ui.Row_Paint.Edged)
	// the finish picks the preset; a theme's own relief wins over it
	th: ui.Theme
	defer ui.theme_destroy(&th)
	p := ui.palette_of("Midnight")
	p.finish = .Machined
	ui.apply_palette(&th, p)
	testing.expect_value(t, th.relief, ui.RELIEF_MACHINED)
	p.look.relief = ui.RELIEF_BEVEL
	ui.apply_palette(&th, p)
	testing.expect_value(t, th.relief, ui.RELIEF_BEVEL)
}

////////////////////////////////
// Layer 7: Old Head, a theme of data

@(private = "file")
old_head :: proc(finish := ui.Finish.Machined) -> ui.Palette {
	p := ui.palette_of("Old Head")
	p.finish = finish   // (the program's finish: the theme's relief wins over it)
	return p
}

@(private = "file")
near_hex :: proc(c: session.Color, v: u32) -> bool {
	want := session.Color{u8(v >> 24), u8(v >> 16), u8(v >> 8), 255}
	return session.near(c, want, 3)
}

// Old Head's button: square, two rings of two tones (white and light along its top and left, black and shadow along
// its bottom and right), on the theme's grey.
@(test)
old_heads_button_is_a_two_tone_bevel :: proc(t: ^testing.T) {
	s := session.start(t, {size = {200, 120}, palette = old_head(), build = key_build})
	session.frames(s, 2)
	ok := session.get(s, "ok")
	testing.expect_value(t, ok.radius, 0)
	testing.expect_value(t, s.state.theme.relief, ui.RELIEF_BEVEL)
	img := session.capture(s)
	x, y := int(KEY.min.x + KEY.max.x) / 2, int(KEY.min.y + KEY.max.y) / 2
	x0, y0, x1, y1 := int(KEY.min.x), int(KEY.min.y), int(KEY.max.x) - 1, int(KEY.max.y) - 1
	check :: proc(t: ^testing.T, img: session.Image, x, y: int, v: u32, what: string) {
		c := session.pixel(img, x, y)
		testing.expectf(t, near_hex(c, v), "%s at %d,%d: %v, not %08x", what, x, y, c, v)
	}
	check(t, img, x, y0, 0xffffffff, "its top, white")
	check(t, img, x, y0 + 1, 0xdfdfdfff, "under it, the light")
	check(t, img, x0, y, 0xffffffff, "its left, white")
	check(t, img, x, y1, 0x000000ff, "its bottom, black")
	check(t, img, x, y1 - 1, 0x808080ff, "over it, the shadow")
	check(t, img, x1, y, 0x000000ff, "its right, black")
	check(t, img, x0 + 4, y1 - 4, 0xc0c0c0ff, "its face, the grey")
	testing.expect_value(t, ui.theme_lookup(s.state.theme, nil, "drop_shadow").a, 0)
}

////////////////////////////////
// Layer 8: the scroll bar's form

// The pixel at x, y (window pixels, cut to whole ones) is the colour `v` (0xRRGGBBAA).
@(private = "file")
check_at :: proc(t: ^testing.T, img: session.Image, x, y: f32, v: u32, what: string) {
	c := session.pixel(img, int(x), int(y))
	testing.expectf(t, near_hex(c, v), "%s at %v,%v: %v, not %08x", what, x, y, c, v)
}

@(private = "file")
bar_build :: proc(s: ^session.Session) {
	ui.next({fixed_x = 20, fixed_y = 20, width = ui.px(200), height = ui.px(200)})
	if ui.scroll_y("###view") {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") {
			for i in 0 ..< 60 {
				ui.next({width = ui.fill(), height = ui.px(20)})
				ui.label(fmt.tprintf("Line %d###line%d", i, i))
			}
		}
	}
}

// Old Head's bar: a flat light grey trough, arrow buttons and a thumb that are keys of its rings (white along their top
// and left, black along their bottom and right, the grey face inside). The standard form, on the same theme, keeps the
// standard's thumb: its corner is its border's colour, not a key's white.
@(test)
old_heads_scroll_bar_is_keys :: proc(t: ^testing.T) {
	for form in ([]ui.Scroll_Bar_Form{.Keys, .Standard}) {
		p := old_head()
		p.look.scroll_bar.form = form
		s := session.start(t, {size = {260, 260}, palette = p, build = bar_build})
		session.frames(s, 2)
		view := session.get(s, "view")
		start, end, arrows := ui.scrollbar_arrow_rects(view)
		track, thumb, has := ui.scrollbar_rects(view)
		if !testing.expect(t, has && arrows, "a bar with its arrows") { return }
		img := session.capture(s)
		check :: check_at
		if form == .Standard {
			c := session.pixel(img, int(thumb.min.x), int(thumb.min.y))
			testing.expectf(t, !near_hex(c, 0xffffffff), "the standard's thumb corner is its border: %v", c)
			continue
		}
		check(t, img, start.min.x, start.min.y, 0xffffffff, "the start arrow's top left, white")
		check(t, img, start.max.x - 1, start.max.y - 1, 0x000000ff, "its bottom right, black")
		check(t, img, start.min.x + 1, start.min.y + 1, 0xdfdfdfff, "inside it, the light")
		check(t, img, end.max.x - 1, end.max.y - 1, 0x000000ff, "the end arrow's bottom right, black")
		check(t, img, thumb.min.x, thumb.min.y, 0xffffffff, "the thumb's top left, white")
		check(t, img, thumb.max.x - 1, thumb.max.y - 1, 0x000000ff, "its bottom right, black")
		check(t, img, math.floor((thumb.min.x + thumb.max.x) * 0.5), math.floor((thumb.min.y + thumb.max.y) * 0.5), 0xc0c0c0ff, "its face, the grey: no grip")
		check(t, img, math.floor((track.min.x + track.max.x) * 0.5), track.max.y - 2, 0xdfdfdfff, "the trough, flat light grey")
		check(t, img, track.min.x, track.max.y - 2, 0xdfdfdfff, "its side, no border")
	}
}

////////////////////////////////
// Layer 9: the title bar

@(private = "file") BAR_H :: 30
@(private = "file") BAR_W :: 400
@(private = "file") WINDOW_H :: 120

@(private = "file")
caption_build :: proc(s: ^session.Session) {
	ui.next({width = ui.fill(), height = ui.px(BAR_H)})
	if ui.title_bar("###tb") {
		ui.next({width = ui.px(120), height = ui.pct(1)})
		ui.label("Title###title")
		ui.spacer(ui.fill())
		_, _ = ui.window_buttons()
	}
	ui.next({fixed_x = 10, fixed_y = 60, width = ui.px(120)})
	ui.label("Words###out")
}

// Old Head's caption: a band from navy to blue (grey to light grey while the window is behind), its text white and bold,
// its buttons square keys of its rings in the system's boxes.
@(test)
old_heads_title_bar_is_a_band :: proc(t: ^testing.T) {
	s := session.start(t, {size = {BAR_W, WINDOW_H}, palette = old_head(), integrated_title = true, build = caption_build})
	session.frames(s, 2)
	img := session.capture(s)
	check :: check_at
	right := f32(BAR_W - 1)
	check(t, img, 0, 1, 0x000080ff, "the band's left, navy")
	check(t, img, right, 1, 0x1084d0ff, "its right, blue")
	title, out := session.get(s, "title"), session.get(s, "out")
	testing.expect_value(t, title.text_color, draw.hex(WHITE))
	testing.expect(t, title.font != out.font, "the caption's text is bold")
	close := ui.box_from_key(s.state.caption_keys[.Close])
	if testing.expect(t, close != nil, "a close button") {
		testing.expect_value(t, close.rect.max.x - close.rect.min.x, f32(ui.CAPTION_BUTTON_WIDTH))
		// (the key's place as caption_key_draw makes it: 0.62 of the bar's height, 8 / 7 as wide)
		h := math.round(f32(BAR_H) * 0.62)
		w := math.round(h * 8.0 / 7.0)
		c := (close.rect.min + close.rect.max) * 0.5
		at := [2]f32{math.round(c.x - w * 0.5), math.round(c.y - h * 0.5)}
		check(t, img, at.x, at.y, 0xffffffff, "the close key's top left, white")
		check(t, img, at.x + w - 1, at.y + h - 1, 0x000000ff, "its bottom right, black")
		check(t, img, at.x + 3, at.y + 3, 0xc0c0c0ff, "its face, the grey")
		check(t, img, close.rect.max.x - 2, at.y - 2, 0x1084d0ff, "the band around it")
	}
	s.win.active = false
	session.frames(s, 2)
	img = session.capture(s)
	check(t, img, 0, 1, 0x808080ff, "behind, the band's left, grey")
	check(t, img, right, 1, 0xb5b5b5ff, "its right, light grey")
}

// A theme without a caption keeps the program's title bar: no band (the page shows through it), the text as it is, and
// the system's buttons, which draw nothing at rest.
@(test)
no_caption_keeps_the_title_bar :: proc(t: ^testing.T) {
	p := ui.palette_of("Midnight")
	p.finish = .Flat
	s := session.start(t, {size = {BAR_W, WINDOW_H}, palette = p, integrated_title = true, build = caption_build})
	session.frames(s, 2)
	img := session.capture(s)
	page := session.pixel(img, 1, WINDOW_H - 2)
	testing.expectf(t, session.near(session.pixel(img, 1, 1), page, 2), "no band: %v", session.pixel(img, 1, 1))
	title, out := session.get(s, "title"), session.get(s, "out")
	testing.expect_value(t, title.text_color, out.text_color)
	testing.expect_value(t, title.font, out.font)
	if close := ui.box_from_key(s.state.caption_keys[.Close]); testing.expect(t, close != nil, "a close button") {
		c := session.pixel(img, int(close.rect.min.x) + 3, int(close.rect.min.y) + 3)
		testing.expectf(t, session.near(c, page, 2), "a system button at rest draws nothing: %v", c)
	}
}

////////////////////////////////
// Layer 10: a relief of rings in every widget

@(private = "file")
lamp_build :: proc(s: ^session.Session) {
	ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(200), height = ui.px(120), bg = ui.Color{0.75, 0.75, 0.75, 1}})
	ground := ui.build_box({.Draw_Background}, "###ground")
	ground.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		ui.machined_lamp(dc, {60, 60}, 20, draw.hex(0x008000ff))
		ui.relief_face(dc, {{120, 40}, {180, 80}}, draw.hex(0xc0c0c0ff), 0)
	}
}

// Under Old Head's rings a lamp is a flat disc of its colour (no highlight, no rim), and a raised tile has the raised
// rings; the machined finish keeps its bead's highlight.
@(test)
a_lamp_and_a_tile_take_the_rings :: proc(t: ^testing.T) {
	s := session.start(t, {size = {200, 120}, palette = old_head(), build = lamp_build})
	session.frames(s, 2)
	img := session.capture(s)
	// (the bead's highlight was up and left of its centre; a flat disc is its colour there too)
	hl, mid := session.pixel(img, 57, 54), session.pixel(img, 60, 60)
	testing.expectf(t, session.near(hl, mid, 3), "a flat disc: %v at the highlight, %v at the centre", hl, mid)
	testing.expectf(t, near_hex(mid, 0x008000ff), "its colour: %v", mid)
	testing.expectf(t, near_hex(session.pixel(img, 120, 40), 0xffffffff), "the tile's top left, white: %v", session.pixel(img, 120, 40))
	testing.expectf(t, near_hex(session.pixel(img, 179, 79), 0x000000ff), "its bottom right, black: %v", session.pixel(img, 179, 79))
	p := ui.palette_of("Midnight")
	p.finish = .Machined
	lit := session.start(t, {size = {200, 120}, palette = p, build = lamp_build})
	session.frames(lit, 2)
	img = session.capture(lit)
	hl, mid = session.pixel(img, 57, 54), session.pixel(img, 60, 60)
	testing.expectf(t, !session.near(hl, mid, 3), "the machined bead keeps its highlight: %v, %v", hl, mid)
}

// Old Head's selected row: navy, its text white.
@(test)
old_heads_selected_row_is_white_on_navy :: proc(t: ^testing.T) {
	r: Rows
	defer ui.list_state_destroy(&r.list)
	s := rows_selected(t, old_head(), &r)
	testing.expect_value(t, session.get(s, "lrow_1").bg, draw.hex(NAVY))
	testing.expect_value(t, session.get(s, "lbl_1").text_color, draw.hex(WHITE))
	testing.expect_value(t, session.get(s, "lbl_0").text_color, draw.hex(0x000000ff))
}

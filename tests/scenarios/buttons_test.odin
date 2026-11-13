package scenarios_test

// Buttons and small widgets: how a button is laid out by what it is asked, its text alignment from its style or `next`
// (centred when nothing says), a glyph alone's tooltip and the name a screen reader reads, a toggled button held down, a
// lit one, a label that shows its whole text when cut, and a spinner that asks for frames only while it is shown.

import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{500, 300}
@(private = "file") BUTTON_WIDTH :: 200
@(private = "file") BUTTON_HEIGHT :: 30
@(private = "file") CUT_WIDTH :: 60

// The words of a row wider than them go where the style or `next` aligns text, centred when nothing says.
@(test)
a_button_keeps_the_text_align_it_is_given :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) {
		ui.next({width = ui.px(BUTTON_WIDTH), height = ui.px(BUTTON_HEIGHT), text_align = .Left})
		ui.button("left", "Left")
		ui.next({width = ui.px(BUTTON_WIDTH), height = ui.px(BUTTON_HEIGHT)})
		ui.button("centre", "Centre")
		if ui.style({text_align = .Right}) {
			ui.next({width = ui.px(BUTTON_WIDTH), height = ui.px(BUTTON_HEIGHT)})
			ui.button("right", "Right")
		}
		ui.next({width = ui.px(BUTTON_WIDTH), height = ui.px(BUTTON_HEIGHT), text_align = .Left})
		ui.button("glyph", icon = ui.ICON_UP)
	}})
	// (the room left of the words, and right of them)
	room :: proc(s: ^session.Session, id: string) -> (before, after: f32) {
		b := session.get(s, id)
		words := session.get(s, "t", within = b)
		return words.rect.min.x - b.rect.min.x, b.rect.max.x - words.rect.max.x
	}
	lb, la := room(s, "left")
	testing.expect(t, lb < la, "left: the room is after the words")
	cb, ca := room(s, "centre")
	testing.expect(t, abs(cb - ca) <= 1, "centred when nothing says")
	rb, ra := room(s, "right")
	testing.expect(t, rb > ra, "right: the room is before the words")
	testing.expect_value(t, session.get(s, "glyph").text_align, ui.Text_Align.Left)
}) }

@(private = "file")
Words :: struct { text: string }

// Words (a glyph before them or not) are one row, its words a box in it, sized by `next`: a text_size(pad) width is
// the words' and `pad` on each side. A glyph alone is one box that shows it; a Link has no face, its words weak until
// the pointer is over it. The id alone keys it: new words keep the box.
@(test)
a_button_is_laid_out_by_what_it_is_asked :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Words{text = "Save"}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Words)(s.user)
		ui.button("row", r.text, ui.ICON_UP)
		ui.button("###glyph", icon = ui.ICON_UP)
		ui.next({width = ui.text_size(10), height = ui.px(BUTTON_HEIGHT)})
		ui.button("sized", r.text)
		ui.button("link", r.text, o = {face = .Link})
	}})
	row := session.get(s, "row")
	testing.expect(t, .Draw_Text not_in row.flags, "a row: its glyph and words are boxes in it")
	testing.expect_value(t, ui.box_text(session.get(s, "t", within = row)), "Save")
	testing.expect_value(t, ui.box_text(session.get(s, "glyph")), ui.ICON_UP)
	sized := session.get(s, "sized")
	words := session.get(s, "t", within = sized)
	testing.expect_value(t, sized.size.y, f32(BUTTON_HEIGHT))
	testing.expectf(t, abs(sized.size.x - (words.size.x + 20)) <= 1, "its words' width and the padding: %v, words %v", sized.size, words.size)
	link := session.get(s, "link")
	testing.expect(t, .Draw_Background not_in link.flags, "a link has no face")
	rest := session.get(s, "t", within = link).text_color
	session.hover(s, "link")
	session.frames(s, 2)
	testing.expect(t, session.get(s, "t", within = session.get(s, "link")).text_color != rest, "lit under the pointer")
	r.text = "Saved"
	session.frames(s, 2)
	testing.expect(t, session.get(s, "sized") == sized, "new words, the same box")
	testing.expect_value(t, ui.box_text(session.get(s, "t", within = sized)), "Saved")
}) }

@(private = "file")
Tips :: struct { clicks: int, on: bool }

// The tooltip shows once the pointer has rested on the button; its words name the glyph for a screen reader. Disabled, it
// takes no click.
@(test)
a_glyph_alone_shows_its_tip_and_is_named_by_it :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Tips{}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Tips)(s.user)
		ui.next({width = ui.px(BUTTON_HEIGHT), height = ui.px(BUTTON_HEIGHT)})
		if ui.button("bell", icon = ui.ICON_UP, o = {tip = "Notifications", intent = .Primary, disabled = r.on}).clicked { r.clicks += 1 }
	}})
	ui.a11y_capture(s.state, true)
	session.hover(s, "bell")
	testing.expect(t, session.find_text(s, "Notifications") == nil, "no tooltip at once")
	session.wait_text(s, "Notifications")
	bell := session.get(s, "bell")
	testing.expect(t, bell.a11y != nil && bell.a11y.name == "Notifications", "its tip names it")
	session.click(s, "bell")
	testing.expect_value(t, r.clicks, 1)
	r.on = true
	session.frames(s, 2)
	session.click(s, "bell")
	testing.expect_value(t, r.clicks, 1)
}) }

// A Toggled face is held down, a lit button drawn as under the pointer.
@(test)
a_toggled_button_is_held_and_a_lit_one_hot :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) {
		ui.button("bold", "Bold", o = {face = .Toggled})
		ui.button("menu", "Menu", o = {lit = true})
		ui.button("plain", "Plain", o = {quiet = true})
	}})
	bold := session.get(s, "bold")
	testing.expect(t, .Held in bold.flags, "held down")
	testing.expect_value(t, ui.box_held(bold), 1)
	testing.expect_value(t, ui.box_hot(session.get(s, "menu")), 1)
	testing.expect_value(t, ui.box_hot(session.get(s, "plain")), 0)
}) }

@(private = "file")
Spin :: struct { shown: bool }

// A spinner asks for the next frames while it is shown, and for none once it is gone.
@(test)
a_spinner_asks_for_frames_only_while_shown :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Spin{shown = true}
	s := session.start(t, {size = WINDOW, user = &r, animations = true, build = proc(s: ^session.Session) {
		r := (^Spin)(s.user)
		if r.shown { ui.spinner("###busy") }
	}})
	session.frames(s, 3)
	testing.expect(t, ui.needs_frame(s.state), "it turns")
	r.shown = false
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.needs_frame(s.state) }, "no frame asked")
	session.frames(s, 3)
	testing.expect(t, !ui.needs_frame(s.state), "still none")
}) }

// A label cut by its box shows its whole text in a tooltip once the pointer rests on it; one that fits shows none.
@(test)
a_cut_label_shows_its_whole_text :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) {
		ui.next({width = ui.px(CUT_WIDTH), height = ui.px(BUTTON_HEIGHT)})
		ui.label_tip("A name far too long for its box###long")
		ui.next({width = ui.px(BUTTON_WIDTH), height = ui.px(BUTTON_HEIGHT)})
		ui.label_tip("Short###short")
	}})
	session.hover(s, "short")
	session.advance(s, f64(ui.feel(s.state).tooltip_delay_ms) * 2)
	testing.expect(t, session.find(s, "tooltip_text") == nil, "a label that fits has no tooltip")
	session.hover(s, "long")
	box := session.wait_box(s, "tooltip_text")
	testing.expect_value(t, ui.box_text(box), "A name far too long for its box")
}) }

// A dot with no intent takes the colour of the text where it stands (a button's words: a sibling label's); with one,
// the intent's hue.
@(test)
a_dot_takes_the_text_s_colour_or_its_intent_s :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := session.start(t, {size = {300, 200}, build = proc(s: ^session.Session) {
		if ui.tags("button", "danger_button") {
			if ui.row(.Center, {}, "###dots") {
				ui.dot("###ink")
				ui.dot("###danger", intent = .Primary)
				ui.label("Record###words")
			}
		}
	}})
	ink_box := session.get(s, "ink")
	ink := (^ui.Dot_Draw)(ink_box.custom_user)
	testing.expect(t, !ink.own, "no colour of its own")
	words := session.get(s, "words").text_color
	testing.expect_value(t, ink_box.text_color, words)
	danger := (^ui.Dot_Draw)(session.get(s, "danger").custom_user)
	testing.expect(t, danger.own && danger.color != words, "the intent's hue")
}) }

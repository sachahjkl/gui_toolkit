package data_views_test

// A stack of cards, one at a time: the arrows and the buttons go from one to the next, A and the middle button ask the act,
// the count says where the card is, and a card shown anew is shown from its top.

import "core:fmt"
import "core:testing"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file")
Cards :: struct { st: ui.Card_Stack, count: int, built: int, acts: [dynamic]ui.Card_Act }

@(private = "file")
cards_build :: proc(s: ^session.Session) {
	c := (^Cards)(s.user)
	ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(400), height = ui.px(300), axis = .Y})
	if ui.column(id = "###page") {
		c.built = -1
		if ui.card_stack("###cards", &c.st, c.count) {
			c.built = c.st.at
			ui.next({width = ui.fill(), height = ui.px(40)})
			ui.label(fmt.tprintf("card %d###title", c.st.at))
			ui.next({width = ui.fill(), height = ui.px(900)})   // (taller than its room: the card scrolls)
			ui.build_box({}, "###tall")
		}
		if c.st.act != .None { append(&c.acts, c.st.act) }
	}
}

@(test)
a_card_stack_goes_card_by_card :: proc(t: ^testing.T) {
	c := Cards{count = 3}
	defer delete(c.acts)
	s := session.start(t, {size = {400, 300}, user = &c, no_renderer = true, build = cards_build})
	session.frames(s, 3)
	testing.expect_value(t, c.built, 0)
	testing.expect(t, session.find_text(s, "1 / 3") != nil, "where the card is")
	session.key(s, .Left)
	session.frames(s, 2)
	testing.expect_value(t, c.st.at, 0)   // (the first: no card before it)
	testing.expect_value(t, len(c.acts), 0)
	session.key(s, .Right)
	session.frame(s)
	testing.expect_value(t, c.built, 1)   // (in the very frame of the key)
	testing.expect(t, len(c.acts) == 1 && c.acts[0] == .Next, "Next")
	session.key(s, .A)
	session.frame(s)
	testing.expect(t, len(c.acts) == 2 && c.acts[1] == .Settle, "A: the act")
	testing.expect_value(t, c.st.at, 1)   // (the act is the program's: the stack does not move)
	session.click(s, "card_next")
	session.frames(s, 2)
	testing.expect_value(t, c.st.at, 2)
	testing.expect(t, session.find_text(s, "3 / 3") != nil, "the last")
	session.click(s, "card_settle")
	session.frames(s, 2)
	testing.expect(t, c.acts[len(c.acts) - 1] == .Settle, "the middle button: the act")
	session.click(s, "card_prev")
	session.frames(s, 2)
	testing.expect_value(t, c.st.at, 1)
}

@(test)
a_card_shown_anew_is_shown_from_its_top :: proc(t: ^testing.T) {
	c := Cards{count = 3}
	defer delete(c.acts)
	s := session.start(t, {size = {400, 300}, user = &c, no_renderer = true, build = cards_build})
	session.frames(s, 3)
	view := session.get(s, "card")
	ui.view_jump(view, ui.view_limit(view))
	session.frames(s, 2)
	testing.expect(t, session.get(s, "card").view_off.y > 100, "read down the card")
	session.key(s, .Right)
	session.frames(s, 2)
	testing.expectf(t, session.get(s, "card").view_off.y < 0.5, "the next card from its top: %v", session.get(s, "card").view_off.y)
}

@(test)
an_empty_stack_builds_no_card :: proc(t: ^testing.T) {
	c := Cards{count = 0}
	defer delete(c.acts)
	s := session.start(t, {size = {400, 300}, user = &c, no_renderer = true, build = cards_build})
	session.frames(s, 3)
	testing.expect_value(t, c.built, -1)
	testing.expect(t, session.find_text(s, "0 / 0") != nil, "nothing")
	session.key(s, .A)
	session.frames(s, 2)
	testing.expect_value(t, len(c.acts), 0)
}

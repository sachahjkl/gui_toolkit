package ui

// A stack of cards shown one at a time: a queue the person goes through (what they missed, what waits for a review), each
// card read whole before the next. What is in a card is the program's; the stack gives the card its room, which scrolls,
// and a foot under it: Previous, the act in the middle (Acknowledge by default) and Next, with where the card is
// ("3 / 14"). The Left and Right arrows and A do the same as the three buttons.
//
//   if ui.card_stack("###cards", &st, len(items)) { build items[st.at] }
//   switch st.act {
//   case .Settle: acknowledge items[st.at]; if it stays in the list, st.at += 1 (else the next one took its place)
//   case .Previous, .Next, .None:   // (the stack moved st.at itself)
//   }
//
// `st.at` is the card shown; a key moves it before the card is built, so the frame shows the new one; a button under the
// card moves it for the next frame. A card shown anew is shown from its top.

import "core:fmt"
import lucide "../lucide"
import i18n "../i18n"

Card_Stack :: struct {
	at:    int,        // the card shown (the program may set it: a card chosen elsewhere)
	act:   Card_Act,   // what this frame asked, read after the stack is built
	shown: int,        // the card shown at the last build: another one is scrolled to its top
	built: bool,
}

// What the person asked of the stack in a frame. Previous and Next are done by the stack (st.at moved); Settle is the
// program's: the act of the middle button on the card at st.at.
Card_Act :: enum u8 { None, Previous, Next, Settle }

Card_Stack_Options :: struct {
	settle:        string,   // the middle button's words ("": Acknowledge)
	settle_icon:   string,   // its glyph ("": a check)
	settle_intent: Maybe(Intent),   // its colour (nil: Success)
	no_keys:       bool,     // the arrows and A are not the stack's (a field in the card takes them)
}

// The stack, `count` cards; true when there is one to build (st.at is in 0 ..< count). Its end builds the foot.
@(deferred_in = card_stack_end)
card_stack :: proc(id: string, st: ^Card_Stack, count: int, o := Card_Stack_Options{}) -> bool {
	st.act = .None
	st.at = clamp(st.at, 0, max(count - 1, 0))
	if count > 0 && !o.no_keys {
		// (read before the card is built: the frame shows where the key went)
		switch {
		case key_press(.Left) && st.at > 0:          st.at -= 1; st.act = .Previous
		case key_press(.Right) && st.at < count - 1: st.at += 1; st.act = .Next
		case key_press(.A):                          st.act = .Settle
		}
	}
	next({width = fill(), height = fill(), axis = .Y})
	push_parent(build_box({}, fmt.tprintf("###%s", hash_part(id))))
	// (scroll_y's box, kept open past this procedure: the card is built in it, the end closes it)
	next({width = fill(), height = fill()})
	set_next_axis(.Y)
	view := build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y}, "###card")
	_ = signal(view)
	push_parent(view)
	if st.built && st.at != st.shown { view_jump(view, 0) }
	st.shown, st.built = st.at, true
	next({width = fill(), height = children_sum(), axis = .Y})
	push_parent(build_box({}, "###content"))
	return count > 0
}

@(private)
card_stack_end :: proc(id: string, st: ^Card_Stack, count: int, o: Card_Stack_Options) {
	pop_parent()   // the content
	pop_parent()   // the card's view
	em := font_size()
	// (Previous and where the card is at the left, Next at the right, each side as wide as the other: the act is in the middle)
	next({width = fill(), height = children_sum(), axis = .X, cross = .Center})
	if row(.Center, id = "###card_foot") {
		h := dense(em * 2.2)
		next({width = fill(), height = children_sum(), axis = .X, cross = .Center})
		if row(.Center, id = "###card_before") {
			if button("card_prev", "", lucide.ARROW_LEFT, {height = h, disabled = count == 0 || st.at == 0, tip = i18n.tr("Previous")}).clicked {
				st.at -= 1
				st.act = .Previous
			}
			spacer(px(em * 0.6))
			if tags("weak") {
				next({width = text_size(), height = px(h), text_pad = 0, font_size = em * 0.9})
				label(fmt.tprintf("%d / %d###card_count", count > 0 ? st.at + 1 : 0, count))
			}
			spacer(fill())
		}
		words := o.settle != "" ? o.settle : i18n.tr("Acknowledge")
		icon := o.settle_icon != "" ? o.settle_icon : lucide.CHECK
		if button("card_settle", words, icon, {intent = o.settle_intent.? or_else .Success, height = h, disabled = count == 0}).clicked {
			st.act = .Settle
		}
		next({width = fill(), height = children_sum(), axis = .X, cross = .Center})
		if row(.Center, id = "###card_after") {
			spacer(fill())
			if button("card_next", "", lucide.ARROW_RIGHT, {height = h, disabled = count == 0 || st.at >= count - 1, tip = i18n.tr("Next")}).clicked {
				st.at += 1
				st.act = .Next
			}
		}
	}
	pop_parent()   // the stack
}

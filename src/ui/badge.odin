package ui

import "core:fmt"

// The badge's text past this: "99+" (wider says nothing more at a glance).
BADGE_MOST :: 99

// A count on the top right corner of `b` (an icon_button's box, a button_icon's): a pill of the intent's hue, its digits
// in ink_on of it, "99+" past 99; nothing at 0 or less. Call it right after building the box, in the same frame:
//
//   sig := ui.icon_button("inbox", ICON_BELL)
//   ui.badge(sig.box, open_count)
//
// The pill is a child of `b` that floats over it and takes no click: the press goes to the button. A screen reader hears
// the count as the button's description, unless the program gave one.
badge :: proc(b: ^Box, count: int, intent := Intent.Primary) {
	if b == nil || count <= 0 { return }
	text := count > BADGE_MOST ? fmt.tprintf("%d+", BADGE_MOST) : fmt.tprintf("%d", count)
	a11y_default(b, {description = text})
	em := font_size()
	h := em * 0.95   // (a pill of one digit is a disc this tall)
	ground := hue_color(intent_hue(intent))
	ground.a = 1
	if parent(b) {
		// (over the whole box, laid out as a row: the pill goes to its right end, at its top, whatever size the box gets)
		next({fixed_x = 0, fixed_y = 0, width = pct(1), height = pct(1), axis = .X, cross = .Start})
		if parent(build_box({}, "###badge")) {
			spacer(fill())
			width := text_size()
			width.least = h
			next({width = width, height = px(h), font_size = em * 0.68, text_pad = em * 0.25, text_align = .Center, radius = h * 0.5, bg = ground, fg = ink_on(ground)})
			pill := build_box({.Draw_Background, .Draw_Text, .No_Text_Trunc, .Fixed_Radius}, fmt.tprintf("%s###badge_count", text))
			a11y_set(pill, {ignore = true})
		}
	}
}

package ui

import "core:fmt"
import "core:math"
import turn "../turn"

// The badge's text past this: "99+" (wider says nothing more at a glance).
BADGE_MOST :: 99

// A count on the top right corner of `b` (a button's box): a pill of the intent's hue, its digits
// in ink_on of it, "99+" past 99; nothing at 0 or less. Call it right after building the box, in the same frame:
//
//   sig := ui.button("inbox", icon = ICON_BELL)
//   ui.badge(sig.box, open_count)
//
// The pill is a child of `b` that floats over it and takes no click: the press goes to the button. A screen reader hears
// the count as the button's description, unless the program gave one.
badge :: proc(b: ^Box, count: int, intent := Intent.Primary) {
	if b == nil || count <= 0 { return }
	text := badge_text(count)
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

// What a badge of `count` says: its digits, "99+" past BADGE_MOST.
@(private)
badge_text :: proc(count: int) -> string {
	return count > BADGE_MOST ? fmt.tprintf("%d+", BADGE_MOST) : fmt.tprintf("%d", count)
}

// A dot on a button's corner (badge_dot): none; still (something new, a state); pulsing (work under way).
Badge_Dot :: enum u8 { None, Still, Pulse }

// A pulsing dot's breath, in ms, and the wake between two of its steps: the dot asks for no frame of the display's rate,
// a step every BADGE_PULSE_STEP_MS is smooth for an opacity this slow.
BADGE_PULSE_MS :: 1600
BADGE_PULSE_STEP_MS :: 50

// A dot on the top right corner of `b` (a button's box), inside its face: a disc of the intent's hue, a state with no
// count. .Pulse: it breathes while it is built (a wake every BADGE_PULSE_STEP_MS, none once it is gone), still when the
// animations are off. Call it right after building the box, in the same frame:
//
//   sig := ui.button("agents", icon = ICON_BOT)
//   ui.badge_dot(sig.box, .Primary, .Pulse)
//
// The dot floats over the box and takes no click. Its colour says nothing to a screen reader: the program says the
// state in the button's description.
badge_dot :: proc(b: ^Box, intent := Intent.Primary, dot := Badge_Dot.Still) {
	if b == nil || dot == .None { return }
	s := gs()
	em := font_size()
	side := math.round(em * 0.45)
	inset := math.round(em * 0.2)
	ground := hue_color(intent_hue(intent))
	ground.a = 1
	if dot == .Pulse && s.anim_rate != 0 {
		phase := math.mod(s.time_ms, BADGE_PULSE_MS) / BADGE_PULSE_MS
		ground.a = f32(0.65 + 0.35 * turn.cos(phase))
		wake_within(s, BADGE_PULSE_STEP_MS)
	}
	if parent(b) {
		next({fixed_x = 0, fixed_y = 0, width = pct(1), height = pct(1), axis = .X, cross = .Start})
		if parent(build_box({}, "###badge_dot")) {
			spacer(fill())
			next({width = px(side), height = children_sum(), axis = .Y})
			if parent(build_box({}, "###badge_dot_column")) {
				spacer(px(inset))
				next({width = px(side), height = px(side), radius = side * 0.5, bg = ground})
				disc := build_box({.Draw_Background, .Fixed_Radius}, "###badge_dot_disc")
				a11y_set(disc, {ignore = true})
			}
			spacer(px(inset))
		}
	}
}

package ui

import "core:math"
import "core:strconv"
import "../platform"

// Numbers in a text stepped from the keyboard and the wheel, as the style editors of browsers' developer tools step them: Up /
// Down add or take 1 to the number at the caret (Page Up / Page Down Feel.step_page), Ctrl multiplies it by Feel.step_ctrl (100),
// Shift by Feel.step_shift (10), Alt by Feel.step_alt (0.1); its unit and the
// text around it stay ("margin: 10px 5px", "rgba(10, 20, 30, 0.5)", "calc(100% - 12px)"). A number is digits with a point and
// a sign; one that is part of a word or a hex colour (h1, translate3d, #10f) is not one.
//
//   num_step_text(text, caret, delta)   the text with the number at the caret moved (else the next one after it, else the
//                                       last one before), and where that number is in it now
//   num_step_delta(key, mods)           what a key press steps by (ok false: a key that does not step)
//   line_edit_num_step(f, box)              the steps of this build in field `f` (its line_edit `box`) while it has the keyboard:
//                                       its keys, and the wheel over it (with the keys' modifiers); the number stays selected

// A result is rounded to this many decimals: steps of 0.1 add no noise (10.1, not 10.100000000000001).
NUM_STEP_DECIMALS :: 6

// What a press of `key` with `mods` steps a number by (the current state's Feel; FEEL_DEFAULT outside any).
num_step_delta :: proc(key: platform.Key, mods: platform.Modifiers) -> (delta: f64, ok: bool) {
	#partial switch key {
	case .Up:        delta = 1
	case .Down:      delta = -1
	case .Page_Up:   delta = feel_now().step_page
	case .Page_Down: delta = -feel_now().step_page
	case: return
	}
	return delta * num_step_scale(mods), true
}

@(private = "file")
num_step_scale :: proc(mods: platform.Modifiers) -> f64 {
	f := feel_now()
	switch {
	case .Ctrl in mods:  return f.step_ctrl
	case .Shift in mods: return f.step_shift
	case .Alt in mods:   return f.step_alt
	}
	return 1
}

// The number nearest the caret, as [start, end) of its digits (the sign included), and its value.
@(private = "file")
number_at :: proc(text: string, caret: int) -> (lo, hi: int, value: f64, ok: bool) {
	is_digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }
	is_word :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || is_digit(c) || c == '_' || c == '#' || c == '-' || c == '.' }
	parse :: proc(s: string) -> f64 { v, _ := strconv.parse_f64(s); return v }
	before, after := [2]int{-1, -1}, [2]int{-1, -1}   // the last number before the caret, the first after it
	i := 0
	for i < len(text) {
		start := i
		if (text[i] == '-' || text[i] == '+') && i + 1 < len(text) && (is_digit(text[i + 1]) || text[i + 1] == '.') { i += 1 }
		digits := i
		for i < len(text) && is_digit(text[i]) { i += 1 }
		if i < len(text) && text[i] == '.' && i + 1 < len(text) && is_digit(text[i + 1]) { i += 1; for i < len(text) && is_digit(text[i]) { i += 1 } }
		if i == digits || (start > 0 && is_word(text[start - 1])) {
			// not a number (or one inside a word): past the word
			word := is_word(text[start]) && text[start] != '-' && text[start] != '.'
			i = max(i, start + 1)
			for word && i < len(text) && is_word(text[i]) && text[i] != '-' { i += 1 }
			continue
		}
		end := i
		for i < len(text) && (is_word(text[i]) || text[i] == '%') && text[i] != '-' && text[i] != '.' { i += 1 }   // its unit
		switch {
		case caret >= start && caret <= i: return start, end, parse(text[start:end]), true
		case i < caret:                    before = {start, end}
		case after[0] < 0:                 after = {start, end}
		}
	}
	at := after[0] >= 0 ? after : before
	if at[0] < 0 { return }
	return at[0], at[1], parse(text[at[0]:at[1]]), true
}
// `text` with the number at the caret moved by `delta` (temporary allocator), and the span of the number in it.
num_step_text :: proc(text: string, caret: int, delta: f64) -> (out: string, lo, hi: int, ok: bool) {
	start, end, v := number_at(text, caret) or_return
	k := math.pow(10, f64(NUM_STEP_DECIMALS))
	n := num_text(math.round((v + delta) * k) / k, NUM_STEP_DECIMALS)
	out = concat3(text[:start], n, text[end:])
	return out, start, start + len(n), true
}

@(private = "file")
concat3 :: proc(a, b, c: string) -> string {
	buf := make([]u8, len(a) + len(b) + len(c), context.temp_allocator)
	copy(buf, a)
	copy(buf[len(a):], b)
	copy(buf[len(a) + len(b):], c)
	return string(buf)
}

// The keys and the wheel of this build that step the number of `f`, the field of `box` (a line_edit's), while it has the
// keyboard. True when the text changed (an edit of the field's history; the number it moved is selected).
line_edit_num_step :: proc(f: ^Line_Edit, box: ^Box) -> (changed: bool) {
	s := gs()
	if box == nil || s.focus_key != box.key { return }
	box.flags += {.Scroll_Self}   // (the wheel over it is its own while it has the keyboard)
	step :: proc(f: ^Line_Edit, delta: f64) -> bool {
		out, lo, hi, ok := num_step_text(line_edit_string(f), f.cursor, delta)
		if !ok { return false }
		line_edit_checkpoint(f, .Other)
		clear(&f.buf)
		append(&f.buf, out)
		f.mark, f.cursor = lo, hi
		f.edited_ms = build_now_ms()
		return true
	}
	for e, i in s.events.list {
		if s.events.consumed[i] || e.mods - {.Ctrl, .Shift, .Alt} != {} { continue }
		delta := num_step_delta(e.key, e.mods) or_continue
		s.events.consumed[i] = true
		if step(f, delta) { changed = true }
	}
	if s.scroll_key == box.key && s.scroll_delta.y != 0 {
		notches := math.round(-s.scroll_delta.y)
		if notches == 0 { notches = s.scroll_delta.y < 0 ? 1 : -1 }   // (wheel up: delta.y < 0, a larger number)
		if step(f, f64(notches) * num_step_scale(s.mods)) { changed = true }
	}
	return
}

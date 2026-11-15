package ui

// A label whose text changes without a blink (a count, a state, an address that another source replaces: opencode native's
// server switch): the characters that stay the same stay still; the others flip through a few glyphs of their kind (a digit
// through digits, a letter through letters) and settle on the new text from left to right, in MORPH_MS. Its width is the
// new text's at once: the layout around it never jumps. With the animations off, the new text shows at once.
//
//	ui.morph_label(fmt.tprintf("%d running · %d sessions###status", running, total))

import "core:strings"
import "core:unicode/utf8"

// How long a change takes, from the first character to the last (ms), and how often a flipping character shows another
// glyph (ms).
MORPH_MS :: 300
@(private = "file") MORPH_FLIP_MS :: 45
@(private = "file") MORPH_DIGITS :: "0123456789"
@(private = "file") MORPH_LETTERS :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

// What a morph label keeps between builds: the text it changes from and to (owned), when the change began.
@(private)
Morph_Memory :: struct {
	from, to: string,
	began:    f64,
	seen:     u64,
}

morph_label :: proc(text: string) -> Signal {
	s := gs()
	shown := display_part(text)
	st := top_style()
	if !s.has_next || s.next_mod.width == nil {
		next_default({width = px(text_width(st.font, st.font_size, shown) + 2 * st.text_pad)})
	}
	b := build_box({.Draw_Text, .No_Text_Trunc}, text)
	m, kept := &s.morphs[b.key]
	if !kept {
		s.morphs[b.key] = {to = strings.clone(shown, s.morphs.allocator)}
		m = &s.morphs[b.key]
	} else if m.to != shown {
		// (a change during a change starts from what was meant, not from the glyphs shown)
		delete(m.from, s.morphs.allocator)
		m.from, m.to, m.began = m.to, strings.clone(shown, s.morphs.allocator), s.time_ms
	}
	m.seen = s.build_index
	elapsed := s.time_ms - m.began
	if m.from != "" && s.anim_rate > 0 && elapsed < MORPH_MS {
		b.text = morph_text(m.from, m.to, elapsed, frame_allocator())
		s.anim_busy = true
	} else if m.from != "" {
		delete(m.from, s.morphs.allocator)
		m.from = ""
	}
	return signal(b)
}

// What a change from `from` to `to` shows `elapsed` ms after it began: each character that differs settles on its new
// glyph at its time along the text (left first), and until then flips through glyphs of its kind.
@(private)
morph_text :: proc(from, to: string, elapsed: f64, allocator := context.allocator) -> string {
	a := utf8.string_to_runes(from, context.temp_allocator)
	z := utf8.string_to_runes(to, context.temp_allocator)
	b := strings.builder_make(allocator)
	n := len(z)
	for r, i in z {
		old := i < len(a) ? a[i] : ' '
		settle := MORPH_MS * f64(i + 1) / f64(max(n, 1))
		if r == old || elapsed >= settle || r == ' ' {
			strings.write_rune(&b, r)
			continue
		}
		set := MORPH_LETTERS
		if r >= '0' && r <= '9' { set = MORPH_DIGITS } else if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z') { strings.write_rune(&b, r); continue }
		flip := int(elapsed / MORPH_FLIP_MS)
		strings.write_byte(&b, set[(i * 7 + flip * 13 + int(r)) % len(set)])
	}
	return strings.to_string(b)
}

// The labels this build did not build.
@(private)
morph_trim :: proc(s: ^State) {
	dead := make([dynamic]Key, context.temp_allocator)
	for k, m in s.morphs { if m.seen != s.build_index { append(&dead, k) } }
	for k in dead {
		m := s.morphs[k]
		delete(m.from, s.morphs.allocator)
		delete(m.to, s.morphs.allocator)
		delete_key(&s.morphs, k)
	}
}

@(private)
morph_destroy :: proc(s: ^State) {
	for _, m in s.morphs {
		delete(m.from, s.morphs.allocator)
		delete(m.to, s.morphs.allocator)
	}
	delete(s.morphs)
}


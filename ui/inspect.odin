package ui

import "../font"
import "../platform"

// What a tool reads of a box from outside a build (devtools, tests): its text as shown, plain or rich. Between end_build
// and the next begin_build (the frame memory it points into is freed then). Temp memory for a rich paragraph's text.
box_text :: proc(b: ^Box) -> string {
	if b == nil { return "" }
	if b.custom == rich_draw && b.custom_user != nil {
		return rich_text((^Rich_Draw)(b.custom_user).runs)
	}
	return b.text
}

// Whether the box was built by the last build (a box kept from an older one is about to go: its memory is not to be read).
// What a tool (Chrome's DevTools) imposes on a box, whatever the program builds: applied after each build, before the layout.
Box_Edit_Field :: enum { Background, Border, Text_Color, Opacity, Radius, Font_Size, Padding, Width, Height, Text, Removed }
Box_Edit :: struct {
	set:                   bit_set[Box_Edit_Field],
	bg, border, text_color: Color,
	opacity, radius, font_size, padding, width, height: f32,   // (frame pixels)
	text:                  string,   // owned
}

box_edit :: proc(s: ^State, key: Key) -> ^Box_Edit {
	if key not_in s.edits { s.edits[key] = {} }
	return &s.edits[key]
}

box_edits_clear :: proc(s: ^State) {
	for _, e in s.edits { delete(e.text) }
	clear(&s.edits)
}

@(private)
box_edits_apply :: proc(s: ^State) {
	for key, e in s.edits {
		b := s.boxes[key]
		if !box_current(s, b) || e.set == {} { continue }
		if .Background in e.set { b.target_bg, b.bg = e.bg, e.bg; b.flags += {.Draw_Background} }
		if .Border in e.set { b.target_border, b.border = e.border, e.border; b.flags += {.Draw_Border} }
		if .Text_Color in e.set { b.target_text, b.text_color = e.text_color, e.text_color }
		if .Opacity in e.set { b.transparency = 1 - e.opacity }
		if .Radius in e.set { b.radius = e.radius }
		if .Font_Size in e.set { b.font_size = e.font_size }
		if .Padding in e.set { b.text_pad = e.padding }
		if .Text in e.set {
			if b.custom == rich_draw && b.custom_user != nil {
				d := (^Rich_Draw)(b.custom_user)
				if len(d.runs) > 0 {
					d.runs = d.runs[:1]
					d.runs[0].text = e.text
					d.version = 0   // (its hash: the text changed)
				}
			} else {
				b.text = e.text
			}
		}
		if e.set & {.Text, .Font_Size} != {} && b.text != "" {
			m := font.metrics(s.fonts, b.font, b.font_size)
			b.text_dim = {font.text_width(s.fonts, b.font, b.font_size, b.text), m.line_height}
		}
		if .Width in e.set { b.pref[.X] = px(e.width) }
		if .Height in e.set { b.pref[.Y] = px(e.height) }
		if .Removed in e.set && b.parent != nil {
			p := b.parent
			if b.prev != nil { b.prev.next = b.next } else { p.first = b.next }
			if b.next != nil { b.next.prev = b.prev } else { p.last = b.prev }
			b.prev, b.next = nil, nil
			p.child_count -= 1
		}
	}
}

// A box lit over everything (Chrome's DevTools, hovering a node); 0: none. The next frame shows it.
set_inspected :: proc(s: ^State, key: Key) { s.inspected = key }

box_current :: proc(s: ^State, b: ^Box) -> bool { return b != nil && b.last_build == s.build_index }

// The box with the focus, the one under the pointer (last build).
focus_key_of :: proc(s: ^State) -> Key { return s.focus_key }
hot_key_of :: proc(s: ^State) -> Key { return s.hot_key }

// What the last build cost (milliseconds), and the items of its lazy columns that were built. total_ms runs from
// begin_build to the end of end_build, the app's own code and the accessibility tree included.
Build_Metrics :: struct {
	build_ms, layout_ms, total_ms: f64,
	lazy_built:                    int,
}

build_metrics :: proc(s: ^State) -> Build_Metrics { return s.metrics }

// The input the last build took (until the next poll_events).
build_events :: proc(s: ^State) -> []platform.Event { return s.last_events }

// The box of a key, if the last build made it.
box_of :: proc(s: ^State, key: Key) -> ^Box {
	b := s.boxes[key] if key != 0 else nil
	return box_current(s, b) ? b : nil
}

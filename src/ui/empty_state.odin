package ui

import "core:fmt"

// What a view shows when it has nothing to show (an empty folder, a filter that hides every row, no result): in the middle
// of the box it fills, an icon in the weak colour, a title, a note, and a button for each thing that can be done about it.
// One line of grey text at the top said what but offered nothing; the person had to know the key.
//
//   if a := ui.empty_state("empty", {icon = lucide.FILTER, title = "No row matches", note = "...", actions = {"Clear the filter"}}); a == 0 {
//       clear_filter()
//   }

Empty_State :: struct {
	icon:    string,     // a glyph of the icon font (Lucide's): "" none
	title:   string,
	note:    string,     // "" none
	actions: []string,   // the buttons' words, in their order
}

// Fills its parent (or what `next` says); returns the action clicked (-1: none).
empty_state :: proc(id: string, e: Empty_State) -> (clicked: int) {
	clicked = -1
	em := font_size()
	s := gs()
	m := s.has_next ? s.next_mod : Style_Mod{}
	if m.width == nil { m.width = fill() }
	if m.height == nil { m.height = fill() }
	m.axis, m.cross = .Y, .Center
	s.next_mod, s.has_next = m, true
	if parent(build_box({}, fmt.tprintf("###%s", id))) {
		spacer(fill())
		if e.icon != "" {
			// (the icon at the size of a heading's picture: `icon` keeps the text's size)
			next({width = px(em * 3.2), height = px(em * 3.2), font = gs().icon_font, font_size = em * 2.4, text_align = .Center, fg = color("weak text")})
			build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###empty_icon", e.icon))
			spacer(px(em * 0.6))
		}
		next({width = fill(), height = px(em * 1.8), font_size = em * 1.1, text_align = .Center})
		label(fmt.tprintf("%s###empty_title", text_shown(e.title)))
		if e.note != "" {
			if tags("weak") {
				next({width = px(em * EMPTY_STATE_NOTE_EM), text_align = .Center})
				paragraph(fmt.tprintf("%s###empty_note", text_shown(e.note)))
			}
		}
		if len(e.actions) > 0 {
			spacer(px(em * 1.0))
			next({width = children_sum(), height = px(dense(em * 2.2))})
			if row(.Center, {}, "###empty_actions") {
				for a, i in e.actions {
					if i > 0 { spacer(px(em * 0.6)) }
					next({width = text_size(em * 1.2), height = pct(1)})
					if button(fmt.tprintf("%s###empty_action%d", text_shown(a), i)).clicked { clicked = i }
				}
			}
		}
		// (a little above the middle: the eye reads the top half first)
		spacer(fill())
		spacer(fill())
	}
	return
}

// The note's width, in ems: the lines of a long note stay short enough to read in the middle of a wide view.
EMPTY_STATE_NOTE_EM :: 24

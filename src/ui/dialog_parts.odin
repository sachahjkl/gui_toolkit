package ui

import "core:fmt"
import "core:math"
import "core:strings"
import "../font"
import lucide "../lucide"

// A dialog's header is the views' (view_header_begin, view_header_end in views_builders.odin): a strip across its top, a
// shade darker than the dialog (top_strip_draw: the dialog's top corners, a groove under it), its icon and its title,
// the program's tools, then the close button in the corner (modal_end builds it).

// Above and below a header's title that wraps onto more lines, in ems.
@(private) DIALOG_TITLE_MARGIN_EM :: 0.45

// The end of a dialog's header: its right end, clear of the corner's control when it has one (the control's margin on
// each side of it: a control of the header never touches it). It pops the strip.
@(private)
dialog_header_end :: proc() {
	s := gs()
	em := font_size()
	end := em * 1.0
	if len(s.modal_stack) > 0 {
		m := s.modal_stack[len(s.modal_stack) - 1]
		if m.corner_side > 0 {
			panel := box_from_key(m.panel)
			border := panel != nil ? border_inset(panel) : 0
			end = max(m.corner_inset + m.corner_side + m.corner_inset - border, 0)
		}
	}
	spacer(px(end), exact = true)
	pop_parent()
}

// The close button of a dialog whose header asked for one, and no control of the program's own took the corner
// (modal_end: built last, it is the last stop of Tab).
@(private)
dialog_close_button :: proc(m: ^Modal_Scope) {
	em := font_size()
	if tags("ghost_button", "button") {
		next({font = lucide_icons(), font_size = em * 1.0, text_pad = 0, text_align = .Center})
		b := modal_corner({.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Text, .Draw_Hot_Effects, .No_Text_Trunc}, fmt.tprintf("%s###dialog_close", lucide.X))
		b.squish = press_squish(b)
		a11y_default(b, {role = .Button, name = m.close_label})
		if signal(b).clicked && m.open != nil { m.open^ = false }
	}
}

// The header's height, in ems, how much darker than the dialog it is (toward black, in sRGB steps), and the side of its
// close button.
DIALOG_HEADER_EM :: f32(2.8)
DIALOG_HEADER_DARKEN :: f32(0.28)
DIALOG_CLOSE_EM :: f32(1.8)

// A row of a list to choose from in a dialog (accounts, passkeys): an icon, a title, a detail under it, as the
// palette's lines. The keyboard's row (`index == sel^`) has the selected row's face, inset and rounded, with a bar of
// the accent at its leading edge, its words in the theme's own colours (row_face.odin). The pointer moving over a row selects it, so the highlight
// follows the pointer; Up and Down are the caller's. True: clicked. `ranges`: what a search found in the title, lit
// (fuzzy_score's). `beside`: the detail on the title's line, at its right, weak (a list under a field: one line a row).
choice_row :: proc(id: string, index: int, sel: ^int, title, detail: string, icon := "", icon_font: font.Font_Id = 0, ranges: []Fuzzy_Range = nil, beside := false) -> bool {
	s := gs()
	em := font_size()
	selected := sel^ == index
	push_tags("menu_item", "nav")
	defer pop_tags()
	if selected { push_tags("selected") }
	defer if selected { pop_tags() }
	h := dense(em * (detail != "" && !beside ? CHOICE_ROW_TWO_EM : CHOICE_ROW_ONE_EM))
	next({width = fill(), height = px(h), axis = .X, cross = .Center, radius = em * shape_of(.Row)})
	flags := Box_Flags{.Clickable, .Draw_Hot_Effects, .Row}
	if selected { flags += {.Draw_Background, .Chosen} }
	rb := build_box(flags, strings.concatenate({"###", id}, frame_allocator()))
	a11y_default(rb, {role = .Menu_Item, name = title, selected = selected})
	sig := signal(rb)
	if sig.hovering && s.mouse_moved { sel^ = index }
	if parent(rb) {
		spacer(px(em * 0.9))
		if icon != "" {
			f := icon_font != 0 ? icon_font : s.icon_font
			if !selected { push_tags("weak") }
			next({width = px(em * 1.6), height = pct(1), font = f, font_size = em * 1.1, text_align = .Center, text_pad = 0})
			build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###i", icon))
			if !selected { pop_tags() }
			spacer(px(em * 0.6))
		}
		if beside {
			next({width = fill(), text_pad = 0})
			matched_label("###t", title, ranges)
			if detail != "" {
				spacer(px(em * 0.6))
				next({width = text_size(), height = pct(1), text_pad = 0, font_size = em * 0.9})
				if tags("weak") { build_box({.Draw_Text}, fmt.tprintf("%s###d", text_shown(detail))) }
			}
		} else {
			next({width = fill(), height = children_sum(), axis = .Y})
			if parent(build_box({}, "###words")) {
				next({width = fill(), height = text_size(), text_pad = 0})
				matched_label("###t", title, ranges)
				if detail != "" {
					next({width = fill(), height = text_size(), text_pad = 0, font_size = em * 0.9})
					if tags("weak") { build_box({.Draw_Text}, fmt.tprintf("%s###d", detail)) }
				}
			}
		}
		spacer(px(em * 0.9))
	}
	return sig.clicked
}

// A choice row's height, in ems: with a detail line, and without.
CHOICE_ROW_TWO_EM :: f32(2.9)
CHOICE_ROW_ONE_EM :: f32(2.2)

// `if dialog_body("id") { ... }`: a dialog's body, between its header and its buttons: a column with the dialog's
// margins on each side (DIALOG_MARGIN_EM) and above and below. What is in it fills its width. `stretch`: it also takes
// the dialog's height that its buttons leave, so a part of it built with fill_least (a preview, a list) grows when the
// person makes a resizable dialog taller; the dialog opens as tall as its parts' least heights.
@(require_results, deferred_none = dialog_body_end)
dialog_body :: proc(id: string, stretch := false) -> bool {
	em := font_size()
	tall := stretch ? fill() : children_sum()
	next({width = fill(), height = tall, axis = .X})
	push_parent(build_box({}, strings.concatenate({"###", id}, frame_allocator())))
	spacer(px(em * DIALOG_MARGIN_EM))
	next({width = fill(), height = tall, axis = .Y})
	push_parent(build_box({}, "###col"))
	spacer(px(em * DIALOG_GAP_EM))
	return true
}

dialog_body_end :: proc() {
	em := font_size()
	spacer(px(em * DIALOG_GAP_EM))
	pop_parent()
	spacer(px(em * DIALOG_MARGIN_EM))
	pop_parent()
}

// `if dialog_buttons("id") { ... }`: a dialog's row of buttons at its bottom, at its right end (the main act last), with
// the dialog's margins and DIALOG_BUTTON_GAP_EM between buttons (put no spacer between them). Buttons that do not fit
// on one line go on more, each line at the right end; a button wider than the dialog on its own is as wide as the dialog,
// its words wrapped. The dialog grows to hold the row on one line, up to its most (modal_end).
@(require_results, deferred_none = dialog_buttons_end)
dialog_buttons :: proc(id: string) -> bool {
	em := font_size()
	next({width = fill(), height = children_sum(), axis = .X, cross = .Center})
	push_parent(build_box({}, strings.concatenate({"###", id}, frame_allocator())))
	spacer(px(em * DIALOG_MARGIN_EM))
	gap := math.round(em * DIALOG_BUTTON_GAP_EM)
	next({width = fill(), height = children_sum(), axis = .X, cross = .End, gap = Vec2{gap, gap}})
	push_parent(build_box({.Wrap}, "###flow"))
	return true
}

dialog_buttons_end :: proc() {
	em := font_size()
	pop_parent()
	spacer(px(em * DIALOG_MARGIN_EM))
	pop_parent()
	spacer(px(em * DIALOG_MARGIN_EM))
}

// Between two buttons of a dialog's row, and between its lines, in ems.
DIALOG_BUTTON_GAP_EM :: f32(0.6)

// A dialog's margin on each side of its body and under its buttons, and the gap above and below its body, in ems.
DIALOG_MARGIN_EM :: f32(1.0)
DIALOG_GAP_EM :: f32(0.8)

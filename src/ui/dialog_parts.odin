package ui

import "core:fmt"
import "core:strings"
import "../font"

// The header of a dialog: a strip across its top, a shade darker than the dialog (dialog_top_draw: the dialog's top
// corners, a groove under it), its title and an icon at its start. Build it first in the dialog, before its body, so
// that it stays on top while the body scrolls. `icon_font` 0: the state's icon font.
dialog_header :: proc(id: string, title: string, icon := "", icon_font: font.Font_Id = 0) {
	em := font_size()
	panel := parent_box()
	shade := frame_new(Color)
	shade^ = srgb_step(panel.bg, {0, 0, 0, panel.bg.a}, DIALOG_HEADER_DARKEN)
	next({width = fill(), height = px(dense(em * DIALOG_HEADER_EM)), radius = DIALOG_RADIUS_EM * em, axis = .X, cross = .Center})
	b := build_box({}, strings.concatenate({"###", id}, frame_allocator()))
	b.custom, b.custom_user = dialog_top_draw, shade
	a11y_default(b, {role = .Heading, name = title})
	if parent(b) {
		spacer(px(em * 1.0))
		if icon != "" {
			f := icon_font != 0 ? icon_font : gs().icon_font
			next({width = px(em * 1.4), height = pct(1), font = f, font_size = em * 1.1, text_align = .Center, text_pad = 0, fg = color("accent")})
			build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###%s_icon", icon, id))
			spacer(px(em * 0.55))
		}
		next({width = fill(), height = pct(1), font_size = em * 1.05, text_pad = 0})
		build_box({.Draw_Text}, fmt.tprintf("%s###%s_title", title, id))
		spacer(px(em * 1.0))
	}
}

// The header's height, in ems, and how much darker than the dialog it is (toward black, in sRGB steps).
DIALOG_HEADER_EM :: f32(2.8)
DIALOG_HEADER_DARKEN :: f32(0.28)

// A row of a list to choose from in a dialog (accounts, passkeys): an icon, a title, a detail under it, as the
// palette's lines. The keyboard's row (`index == sel^`) is sunk in a well with a bar of the accent, its words in the
// theme's own colours (readable: no text on the accent). The pointer moving over a row selects it, so the highlight
// follows the pointer; Up and Down are the caller's. True: clicked.
choice_row :: proc(id: string, index: int, sel: ^int, title, detail: string, icon := "", icon_font: font.Font_Id = 0) -> bool {
	s := gs()
	em := font_size()
	selected := sel^ == index
	push_tags("menu_item")
	defer pop_tags()
	if selected { push_tags("selected") }
	defer if selected { pop_tags() }
	h := dense(em * (detail != "" ? CHOICE_ROW_TWO_EM : CHOICE_ROW_ONE_EM))
	next({width = fill(), height = px(h), axis = .X, cross = .Center})
	rb := build_box({.Clickable, .Draw_Hot_Effects}, strings.concatenate({"###", id}, frame_allocator()))
	if selected { rb.custom = palette_selected_draw }
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
		next({width = fill(), height = children_sum(), axis = .Y})
		if parent(build_box({}, "###words")) {
			next({width = fill(), height = text_size(), text_pad = 0})
			build_box({.Draw_Text}, fmt.tprintf("%s###t", title))
			if detail != "" {
				next({width = fill(), height = text_size(), text_pad = 0, font_size = em * 0.9})
				if tags("weak") { build_box({.Draw_Text}, fmt.tprintf("%s###d", detail)) }
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
// margins on each side (DIALOG_MARGIN_EM) and above and below. What is in it fills its width.
@(deferred_none = dialog_body_end)
dialog_body :: proc(id: string) -> bool {
	em := font_size()
	next({width = fill(), height = children_sum(), axis = .X})
	push_parent(build_box({}, strings.concatenate({"###", id}, frame_allocator())))
	spacer(px(em * DIALOG_MARGIN_EM))
	next({width = fill(), height = children_sum(), axis = .Y})
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
// the dialog's margins.
@(deferred_none = dialog_buttons_end)
dialog_buttons :: proc(id: string) -> bool {
	next({width = fill(), height = children_sum(), axis = .X, cross = .Center})
	push_parent(build_box({}, strings.concatenate({"###", id}, frame_allocator())))
	spacer(fill())
	return true
}

dialog_buttons_end :: proc() {
	em := font_size()
	spacer(px(em * DIALOG_MARGIN_EM))
	pop_parent()
	spacer(px(em * DIALOG_MARGIN_EM))
}

// A dialog's margin on each side of its body and under its buttons, and the gap above and below its body, in ems.
DIALOG_MARGIN_EM :: f32(1.0)
DIALOG_GAP_EM :: f32(0.8)

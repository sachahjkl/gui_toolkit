package ui

import "core:fmt"
import "core:math"
import "core:strings"
import "../draw"
import i18n "../i18n"
import lucide "../lucide"

// A search band's height, in font sizes (before `dense`).
SEARCH_BAND_EM :: 2.5

// What a search band shows besides its field.
Search_Band_Options :: struct {
	placeholder: string,       // what to type, weak, while the field is empty ("": "Type to search")
	count:       Maybe(int),   // the number of results, weak, at the band's end (nil: none)
	clearable:   bool,         // a cross at the field's end empties it while it holds text (line_edit's `clearable`)
	// The keys reach the field through its owner (a menu keeps the keys that move in its items and gives the others to
	// line_edit_key): the field is drawn as one that has the keyboard, its caret blinking, and takes neither the keyboard
	// nor a click. The owner sets `field.edited_ms` when a key changes the field.
	owner_keys:  bool,
}

// The search over a list that it filters (a palette, a picker, a menu that searches, a sidebar's filter): a band from
// edge to edge in a field's background (top_strip_draw), a line under it, a magnifier, the field (`id`), the count.
// One look wherever a list is searched. Build it first in its box: its top corners are that box's. Its size comes from
// `next` (default: the whole width, SEARCH_BAND_EM high). The field is a line_edit with no frame of its own; the
// result is its (focus it with `set_focus(res.box.key)`). Its hint stays while the field is empty, the keyboard in it.
search_band :: proc(id: string, field: ^Line_Edit, o := Search_Band_Options{}) -> (res: Edit_Result) {
	s := gs()
	em := font_size()
	// (no radius of its own: its corners are those it fills, box_drawn_radii)
	next_default({width = fill(), height = px(math.round(dense(em * SEARCH_BAND_EM))), radius = 0})
	set_next_axis(.X, .Center)
	band := build_box({}, strings.concatenate({"###", id}, frame_allocator()))
	band.custom, band.custom_user = top_strip_draw, nil
	push_parent(band)
	defer pop_parent()
	spacer(px(em * 0.8))
	if tags("weak") {
		next({width = px(em * 1.2), height = pct(1), font = lucide_icons(), font_size = em * 1.05, text_align = .Center, text_pad = 0})
		build_box({.Draw_Text, .No_Text_Trunc}, lucide.SEARCH + "###icon")
	}
	hint := o.placeholder != "" ? o.placeholder : i18n.tr("Type to search")
	pad := math.round(em * 0.4)
	next({width = fill(), height = pct(1), font_size = em * 1.05, text_pad = pad})
	if o.owner_keys {
		// (drawn as a field draws itself: the caret, the selection; its text the box's, for what reads it)
		text := line_edit_string(field)
		fb := build_box({.Clip}, fmt.tprintf("%s###field", text_shown(text)))
		since := now_ms() - field.edited_ms
		caret_wake(s, since)
		d := frame_new(Line_Edit_Draw)
		d^ = {text = strings.clone(text, frame_allocator()), placeholder = hint, placeholder_focused = true,
			cursor = field.cursor, mark = field.mark, focused = true,
			caret_on = !s.inactive && (since < CARET_SOLID_MS || (int(since) / CARET_BLINK_MS) % 2 == 0),
			selection = color("selection"), caret = color("cursor"), pad = pad}
		if tags("weak") { d.weak = color("text") }
		fb.custom, fb.custom_user = line_edit_draw, d
		res.box = fb
	} else {
		push_tags("bare")
		res = line_edit("###field", field, {placeholder = hint, placeholder_focused = true, clearable = o.clearable})
		pop_tags()
	}
	if n, ok := o.count.?; ok {
		if tags("weak") {
			next({width = text_size(), height = pct(1), font_size = em * 0.85, text_pad = em * 0.4})
			label(fmt.tprintf("%d###count", n))
		}
	}
	spacer(px(em * 0.8))
	return
}

// A strip across the top of a box (a dialog's title, a search band), as a box's custom draw: its background
// (`custom_user`, a ^Color; nil: a field's, the theme's "input background": search_band), its corners those it fills
// (box_drawn_radii: a dialog's, a menu's, none in a sidebar), a line under it. At the top of a raised box (machined: a
// dialog, a menu, a popover), whose lit rim is just inside its border, the strip begins inside the rim; that box's frame is
// drawn over it (machined_plate_over). Give the strip's box no radius of its own. (Not the box's `bg`: inside a dialog every
// box has the dialog's.)
top_strip_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	s := gs()
	r := b.rect
	radii := box_drawn_radii(s, b)
	if machined() && strip_under_plate(s, b) {
		p := px1()
		r = {{r.min.x + p, r.min.y + p}, {r.max.x - p, r.max.y}}
		for &c in radii { c = concentric_radius(c, p) }
	}
	well := user != nil ? (^Color)(user)^ : color_from_tags(s, b.tags_key, "input background")
	draw.rect_corners(dc, r, {well, well, well, well}, radii)
	// the line that parts the strip from what is under it: carved (machined, edged), the border's colour (flat)
	y := b.rect.max.y - (machined() ? 2 : 1) * px1()
	machined_groove(dc, {r.min.x, y}, {r.max.x, y})
}

// Whether a strip lies against the top of a raised box (.Plate), through the boxes around it whose top is its own.
@(private = "file")
strip_under_plate :: proc(s: ^State, b: ^Box) -> bool {
	for a := b.parent; a != nil; a = a.parent {
		edge: f32 = .Draw_Border in a.flags ? max(1, math.round(s.scale)) : 0
		if abs(b.rect.min.y - a.rect.min.y) > edge + 0.5 { return false }
		if .Plate in a.flags { return true }
	}
	return false
}

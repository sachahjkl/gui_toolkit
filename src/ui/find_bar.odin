package ui

import "core:fmt"
import "core:math"
import i18n "../i18n"
import lucide "../lucide"

// The find bar (src/md/features/find-in-view.md, "The bar"): one find per window, over one view, at its top right inside
// it, left of its scroll bar. The field, the count ("3/17", "No results", "12…" while counting), the scopes when the view
// has rows and the options give two or more, match case (Alt+C) and whole word (Alt+W), previous and next (Shift+Enter
// and Enter in the field, Shift+F3 and F3 anywhere while it is open), close (Escape).
//
//   if ui.command_pressed(find_cmd) { ui.find_open(view_key) }   // the program's Ctrl+F
//   view := ui.prev_box("###doc")
//   res := ui.find_bar(view, {scopes = scopes})                   // at each build of the view, before or after its content
//
// Tags used: "find_bar"; its field "input" under "bare".

Find_Options :: struct {
	placeholder: string,         // the field's hint ("": "Find")
	scopes:      []Find_Scope,   // named subsets of the view's rows, the first the default (fewer than two: none shown)
}

@(private = "file") FIND_BAR_EM :: 24          // the bar's width with no scopes
@(private = "file") FIND_BAR_HEIGHT_EM :: 2.2
@(private = "file") FIND_BAR_SHADOW_PX :: 8
@(private = "file") FIND_BAR_BUTTON_EM :: 1.7

// Opens the find over the scroll box `view` (its key), or gives its field the keyboard when it is open there, its text
// selected. Open over another view, it moves there. `text`: the field's text instead (a character typed on the marks).
find_open :: proc(view: Key, text := "") {
	s := gs()
	f := &s.find
	if !f.open || !f.in_bar { f.back_focus = s.focus_key }
	if f.view != view {
		f.view = view
		find_rows_free(f)
		find_query_changed(f)
	}
	f.open, f.focus_field = true, true
	if text != "" { line_edit_set(&f.field, text) } else { line_edit_select_all(&f.field) }
}

// Closes the find: no needle, no light, the cache freed; the field's text stays for the next opening. The keyboard goes
// back to what had it when it opened, if the bar had it.
find_close :: proc() {
	s := gs()
	f := &s.find
	if !f.open { return }
	f.open = false
	if f.in_bar {
		b := s.boxes[f.back_focus] or_else nil
		s.focus_key = b != nil ? f.back_focus : 0
	}
	f.in_bar = false
}

// What the bar's field holds (kept while it is closed).
find_needle :: proc() -> string { return line_edit_string(&gs().find.field) }

// The find is open over `view` (0: over any).
find_is_open :: proc(view: Key = 0) -> bool {
	f := &gs().find
	return f.open && (view == 0 || f.view == view)
}

// The bar over the scroll box `view` (the last build's, prev_box, or the one being built) while the find is open over it;
// nothing else. The result says where the current match is (a view that paints its own rows brings it in).
find_bar :: proc(view: ^Box, o := Find_Options{}) -> (res: Find_Result) {
	s := gs()
	f := &s.find
	res.row = -1
	if view == nil || !f.open || view.key != f.view { return }
	f.bar_build = s.build_index
	if f.has_cur { res.row = f.cur_row }
	res.moved, res.start, res.end = f.moved, f.cur_range[0], f.cur_range[1]
	f.moved = false

	// the scope: a part of the query
	scoped := f.by_rows && len(o.scopes) >= 2
	f.scope = len(o.scopes) > 0 ? clamp(f.scope, 0, len(o.scopes) - 1) : 0
	set_keep :: proc(f: ^Find_State, o: Find_Options) {
		keep := len(o.scopes) > 0 ? o.scopes[f.scope].keep : nil
		if keep != f.keep { f.keep = keep; find_query_changed(f) }
	}
	set_keep(f, o)
	toggle :: proc(f: ^Find_State, v: ^bool) { v^ = !v^; find_query_changed(f) }

	// the keys of the bar, before its field takes what is typed (Alt+C would type a "c")
	if f.in_bar {
		alt_c, alt_w := key_press(.C, {.Alt}), key_press(.W, {.Alt})
		if alt_c { toggle(f, &f.match_case) }
		if alt_w { toggle(f, &f.whole_word) }
		if (alt_c || alt_w) && .Alt in s.typed_mods { clear(&s.typed) }
	}
	if key_press(.F3) { f.step = 1 }
	if key_press(.F3, {.Shift}) { f.step = -1 }

	em := font_size()
	gap := math.round(em * SPACE_2)
	labels := make([]string, len(o.scopes), context.temp_allocator)
	for sc, i in o.scopes { labels[i] = sc.name }
	seg_w := scoped ? segmented_width(labels) + gap : 0
	edge := border_inset(view)
	right := view.rect.max.x - edge - (.Scrollbar_Left in view.flags ? 0 : view.bar_room.x)
	left := view.rect.min.x + edge + (.Scrollbar_Left in view.flags ? view.bar_room.x : 0)
	// (never wider than the view: a narrow one shrinks the field, then shows the scopes as a dropdown)
	w := max(min(math.round(em * FIND_BAR_EM) + seg_w, right - left - 2 * gap), 0)
	x := right - gap - w
	y := view.rect.min.y + edge + gap
	radius := math.round(em * shape_of(.Control))
	bh := math.round(em * FIND_BAR_BUTTON_EM)
	focusables := make([dynamic]Key, context.temp_allocator)

	push_parent(s.root)
	defer pop_parent()
	push_tags("find_bar")
	defer pop_tags()
	next({fixed_x = x, fixed_y = y, width = px(w), height = children_sum(), axis = .X, cross = .Center, radius = radius})
	// (a plate for its shadow, the well over all of it; .Clickable: a press on its edge is not the content's under it)
	bar := build_box({.Plate, .Clickable}, fmt.tprintf("###find_bar_%x", u64(view.key)))
	bar.plate = frame_new(Plate_Look)
	face := color("card background")
	bar.plate^ = {top = face, bottom = face, border = Color{}, rim = 0, shadow = FIND_BAR_SHADOW_PX}
	f.bar_key = bar.key
	if parent(bar) {
		next({width = fill(), height = px(math.round(em * FIND_BAR_HEIGHT_EM)), cross = .Center, radius = radius})
		if well("###well", .X, flags = {.Focus_Within, .Draw_Focus_Ring}) {
			space(SPACE_2)
			if tags("weak") {
				next({width = px(em * 1.2), height = pct(1), font = lucide_icons(), font_size = em, text_align = .Center, text_pad = 0})
				build_box({.Draw_Text, .No_Text_Trunc}, lucide.SEARCH + "###icon")
			}
			push_tags("bare")
			next({width = fill(), height = pct(1), text_pad = em * 0.3})
			field := line_edit("###field", &f.field, {placeholder = o.placeholder != "" ? o.placeholder : i18n.tr("Find")})
			pop_tags()
			append(&focusables, field.box.key)
			if f.focus_field { s.focus_key = field.box.key; f.focus_field = false }
			if key_press(.Return, {.Shift}) && s.focus_key == field.box.key { f.step = -1 } else if field.committed { f.step = 1 }
			if field.cancelled { find_close() }

			// the count: of the last build's needle
			n := find_count()
			count := ""
			if line_edit_string(&f.field) != "" {
				switch {
				case find_pending():  count = fmt.tprintf("%d…", n)
				case n == 0:          count = i18n.tr("No results")
				case f.current >= 0:  count = fmt.tprintf("%d/%d", f.current + 1, n)
				case:                 count = fmt.tprintf(i18n.tr(n, "%d result", "%d results"), n)
				}
			}
			if tags("weak") {
				next({width = text_size(), height = pct(1), font_size = math.round(em * 0.85), text_pad = em * 0.3})
				label(fmt.tprintf("%s###count", count))
			}
			if scoped {
				space(SPACE_1)
				// (its own width: the field gives way first)
				next({width = px(seg_w - gap), height = px(bh)})
				if segmented("###scope", labels, &f.scope) { set_keep(f, o) }
			}
			space(SPACE_1)
			glyph :: proc(id, icon, tip: string, on: bool, size: f32, focusables: ^[dynamic]Key) -> bool {
				next({width = px(size), height = px(size)})
				sig := button(id, icon = icon, o = {face = on ? Button_Face.Toggled : Button_Face.Ghost, icon_font = lucide_icons(), tip = tip})
				append(focusables, sig.box.key)
				return sig.clicked
			}
			if glyph("###case", lucide.CASE_SENSITIVE, i18n.tr("Match case (Alt+C)"), f.match_case, bh, &focusables) { toggle(f, &f.match_case) }
			if glyph("###word", lucide.WHOLE_WORD, i18n.tr("Whole word (Alt+W)"), f.whole_word, bh, &focusables) { toggle(f, &f.whole_word) }
			if glyph("###prev", lucide.CHEVRON_UP, i18n.tr("Previous match (Shift+Enter)"), false, bh, &focusables) { f.step = -1 }
			if glyph("###next", lucide.CHEVRON_DOWN, i18n.tr("Next match (Enter)"), false, bh, &focusables) { f.step = 1 }
			if glyph("###close", lucide.X, i18n.tr("Close (Escape)"), false, bh, &focusables) { find_close() }
			space(SPACE_1)
		}
	}
	in_bar := false
	for k in focusables { if s.focus_key == k { in_bar = true } }
	if in_bar && f.open && s.focus_key != focusables[0] && key_press(.Escape) { find_close(); in_bar = false }
	if f.open { f.in_bar = in_bar }
	return
}

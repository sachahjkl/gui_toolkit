package ui

// A side panel that folds to a rail (src/md/features/side-panels.md): the views' side zones, the settings' sidebar and a
// program's own split use it.
//
//   * Side_Fold: two bits, `narrow` (the side of the threshold seen last) and `folded` (what shows). side_fold_follow
//     reads the room: a crossing of the threshold, either way, makes folded = narrow. side_fold_set is a manual act: it
//     holds until the next crossing. A manual choice is folded != narrow. side_fold_format / side_fold_parse save both.
//   * side_handle: the splitter between the panel and the content. Open, it resizes the panel; folded, it is the rail's
//     edge line. A drag maps the pointer to a raw width: under the threshold the panel is folded, past it open there.
//   * side_fold_button: the fold button (a panel icon), which the program places in a row it has.
//   * Side_Panel, side_panel_begin, side_panel_handle: the three for a program's own split, with its width.

import "core:math"
import "core:strings"
import lucide "../lucide"

// The hysteresis of the rule (em): a panel folds when the content gets less than its least, and opens again only when
// the content gets this much more. A sweep of the width around the threshold changes the state once each way.
SIDE_FOLD_GAP_EM :: f32(1)
// How far past its rail's width a panel's handle is pulled before the panel opens (em). The panel opens no narrower than
// its least: the threshold is the larger of the two, so the panel opens at the pointer, with no jump.
SIDE_PULL_EM :: f32(1)

// A side panel's fold: what the program keeps and saves. The zero value is wide and open (the automatic state of a wide
// room): no memory and a memory of a wide, open panel are the same.
Side_Fold :: struct {
	folded: bool,   // it shows as its rail
	narrow: bool,   // the last measure was under the threshold
}

// Whether the panel shows a choice of the person's (a fold while wide, an opening while narrow), which the next crossing
// of the threshold ends.
side_fold_manual :: proc(f: Side_Fold) -> bool { return f.folded != f.narrow }

// The rule, once per build: `room` is the whole split's width (the panel, its handle, the content: the fold does not
// change it), `open` the panel's width open, `content_min` the content's least, `gap` the hysteresis
// (SIDE_FOLD_GAP_EM in the same unit); all in one unit. A room of 0 (unknown) changes nothing. crossed: the room
// crossed the threshold; `folded` is the automatic state again (the program saves it).
side_fold_follow :: proc(f: ^Side_Fold, room, open, content_min, gap: f32) -> (crossed: bool) {
	if room <= 0 { return false }
	left := room - open
	narrow := f.narrow ? left < content_min + gap : left < content_min
	if narrow == f.narrow { return false }
	f.narrow, f.folded = narrow, narrow
	return true
}

// A manual fold (true) or opening (false): it holds until the next crossing. changed: it shows otherwise.
side_fold_set :: proc(f: ^Side_Fold, folded: bool) -> (changed: bool) {
	changed = f.folded != folded
	f.folded = folded
	return
}

// The fold as words for a settings file: "folded narrow", "folded", "narrow" or "".
side_fold_format :: proc(f: Side_Fold, allocator := context.temp_allocator) -> string {
	switch {
	case f.folded && f.narrow: return strings.clone("folded narrow", allocator)
	case f.folded:             return strings.clone("folded", allocator)
	case f.narrow:             return strings.clone("narrow", allocator)
	}
	return strings.clone("", allocator)
}

// The fold that side_fold_format wrote. ok false: a word it does not know (the fold is then the zero value).
side_fold_parse :: proc(text: string) -> (f: Side_Fold, ok: bool) {
	rest := text
	for word in strings.fields_iterator(&rest) {
		switch word {
		case "folded": f.folded = true
		case "narrow": f.narrow = true
		case:          return {}, false
		}
	}
	return f, true
}

// What side_handle is given beside its sizes: as splitter's (Splitter_Options), the handle along X.
Side_Handle_Options :: struct {
	after:        bool,    // the panel is after the handle (at the right): a drag towards it shrinks it
	unit:         f32,     // frame pixels per unit of the sizes (0: the scale: logical pixels)
	total:        f32,     // the room of the panel and the content (units; 0: unknown): the content keeps min_other
	min_other:    f32,
	default_size: f32,     // a double click on the open panel's handle puts it back (0: none)
	thickness:    f32,
	line_at:      Splitter_Line,
	flush:        bool,
}

Side_Handle_Result :: struct {
	using res:    Splitter_Result,   // (changed: the open size or the fold changed this frame)
	fold:         bool,              // the state the handle asks: folded (a drag into the rail) or open
	fold_changed: bool,              // the drag crossed the pull's threshold this frame: a manual act (side_fold_set)
}

// What a handle's press keeps: the width shown then, and the open size then (a fold during the drag puts it back).
@(private = "file")
Side_Pull :: struct { from, size: f32, taken: bool }

// The handle of a panel `folded` or open at `size` (units, written while it is dragged open), `rail` wide folded, from
// `lo` to `hi` open. The keys resize an open panel and never fold it. A drag folds it under max(rail + SIDE_PULL_EM,
// lo) and opens it past that, at the pointer; folding, `size` goes back to its value at the press.
side_handle :: proc(id: string, folded: bool, size: ^f32, rail, lo, hi: f32, o := Side_Handle_Options{}) -> (h: Side_Handle_Result) {
	s := gs()
	unit := o.unit > 0 ? o.unit : s.scale
	shown := folded ? rail : size^
	moved := shown
	so := Splitter_Options{default_size = folded ? 0 : o.default_size, after = o.after, total = o.total, min_other = o.min_other,
		thickness = o.thickness, unit = o.unit, line_at = o.line_at, flush = o.flush}
	h.res = splitter(id, .X, &moved, folded ? rail : lo, hi, so)
	h.fold = folded
	keyed := h.res.changed   // (the splitter's own change: a key, a double click, a value; the drag is read below)
	h.changed = false
	if h.res.box == nil { return }
	pull := press_data(Side_Pull, h.res.box.key)
	if pull != nil && !pull.taken { pull^ = {from = shown, size = size^, taken = true} }
	before := size^
	if h.res.dragging && pull != nil {
		d := h.res.drag_delta.x / unit
		if o.after { d = -d }
		raw := pull.from + d
		h.fold = raw < max(rail + SIDE_PULL_EM * font_size() / unit, lo)
		h.fold_changed = h.fold != folded
		if h.fold {
			size^ = pull.size
		} else {
			a, b := splitter_limits(lo, hi, so)
			size^ = clamp(raw, a, b)
		}
	} else if keyed && !folded {
		size^ = moved   // (a key, a double click, a screen reader's value: open only)
	}
	h.changed = size^ != before || h.fold_changed
	return
}

// The fold button of a panel `folded` or open, at the left or (`after`) at the right: the panel icon that says what a
// click does (PANEL_LEFT_CLOSE open, PANEL_LEFT_OPEN folded), its tooltip and its accessible name `fold_label` or
// `open_label`. The program places it in a row it already has, at the same pixel in both states, and on a click calls
// side_fold_set(!folded). `id`: its key ("###fold").
side_fold_button :: proc(id: string, folded, after: bool, fold_label, open_label: string) -> Signal {
	glyph: string
	switch {
	case folded && !after: glyph = lucide.PANEL_LEFT_OPEN
	case folded:           glyph = lucide.PANEL_RIGHT_OPEN
	case !after:           glyph = lucide.PANEL_LEFT_CLOSE
	case:                  glyph = lucide.PANEL_RIGHT_CLOSE
	}
	return side_icon_button(id, glyph, folded ? open_label : fold_label)
}

// The side of the fold button and of a stack's small buttons (em): three of them and a stack's largest tab fit a side
// zone of 12 ems.
SIDE_ICON_EM :: f32(1.3)

// A small icon button, as close to the next as a bar's tools ("###id": its key): the fold button and a narrow stack's
// own buttons.
@(private)
side_icon_button :: proc(id, glyph, label: string) -> Signal {
	em := font_size()
	side := math.round(em * SIDE_ICON_EM)
	push_tags("ghost_button", "button", "weak")
	defer pop_tags()
	next({width = px(side), height = px(side), font = lucide_icons(), font_size = em * 0.85, text_pad = 0, text_align = .Center, radius = em * 0.3})
	b := build_box({.Draw_Text, .No_Text_Trunc, .Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects}, strings.concatenate({glyph, id}, context.temp_allocator))
	a11y_default(b, {role = .Button, name = label})
	sig := signal(b)
	if hovered_for(sig) { if tooltip() { tooltip_text(label) } }
	return sig
}

// A program's own foldable panel: what it keeps and saves (side_fold_format of `fold`, and `width`).
Side_Panel :: struct {
	fold:  Side_Fold,
	width: f32,   // its width open, in the options' unit (0: default_width)
}

// A program's foldable panel: its widths and the content's least, in one unit (`unit` frame pixels each; 0: logical
// pixels).
Side_Panel_Options :: struct {
	after:         bool,   // the panel is at the right of the content (built after it)
	unit:          f32,
	default_width: f32,    // open, at first and on a double click of its handle
	min_width:     f32,
	max_width:     f32,    // (0: no bound but the content's least)
	rail:          f32,    // its width folded
	content_min:   f32,    // the content's least: open, the panel leaves it this much, else it folds
	line_at:       Splitter_Line,
	flush:         bool,
}

// Before the panel's box: the rule read on `room` (the split's width at the last layout, frame pixels), and the width
// to lay the panel out at (frame pixels: its rail's, folded). crossed: the room crossed the threshold (save the fold).
side_panel_begin :: proc(p: ^Side_Panel, room: f32, o: Side_Panel_Options) -> (width: f32, folded, crossed: bool) {
	unit := o.unit > 0 ? o.unit : gs().scale
	if p.width <= 0 { p.width = o.default_width }
	open := side_panel_open(p, o)
	crossed = side_fold_follow(&p.fold, room / unit, open, o.content_min, SIDE_FOLD_GAP_EM * font_size() / unit)
	folded = p.fold.folded
	return math.round((folded ? o.rail : open) * unit), folded, crossed
}

// The handle between the panel and the content, after side_panel_begin: it resizes the open panel, a pull opens the
// folded one, a push into the rail folds it (both manual acts). Save the panel when finished or fold_changed.
side_panel_handle :: proc(id: string, p: ^Side_Panel, room: f32, o: Side_Panel_Options) -> Side_Handle_Result {
	unit := o.unit > 0 ? o.unit : gs().scale
	hi := o.max_width > 0 ? o.max_width : room / unit
	h := side_handle(id, p.fold.folded, &p.width, o.rail, o.min_width, hi, {after = o.after, unit = o.unit, total = room / unit,
		min_other = o.content_min, default_size = o.default_width, line_at = o.line_at, flush = o.flush})
	if h.fold_changed { side_fold_set(&p.fold, h.fold) }
	return h
}

@(private = "file")
side_panel_open :: proc(p: ^Side_Panel, o: Side_Panel_Options) -> f32 {
	w := max(p.width, o.min_width)
	if o.max_width > 0 { w = min(w, max(o.max_width, o.min_width)) }
	return w
}

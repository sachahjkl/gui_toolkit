package ui

import "core:math"
import "../draw"

// A row of tabs and the panel it shows as one surface (src/md/features/tab-styles.md): the panel's ground and edge, given
// once, paint the chosen tab, the strip and the frame; the frame is drawn once, by the panel, and its content draws none.

// What a tab_panel frames, and what its tabs do beyond choosing.
Tab_Panel_Options :: struct {
	surface: Tab_Surface,    // the panel's ground and edge (zero: the page's, the border)
	radius:  f32,            // its corners, logical px (0: the theme's control radius, a fifth more)
	pad:     f32,            // its content's padding, frame px (0: CARD_PAD ems; < 0: none, a terminal's text to the edge)
	tabs:    Tabs_Options,   // its tabs (style nil: .Folder)
}

@(private)
Tab_Panel_Draw :: struct {
	style:  Tab_Style,
	sf:     Tab_Surface,
	radius: f32,
	strip:  ^Box,    // the row the strip stands in (its bottom: the folder's line)
	pad:    f32,
	band:   Color,   // the Header's band (read in the build)
}

// `if r, ok := tab_panel(id, labels, icons, &chosen); ok { ...the chosen page... }`: a row of tabs over the panel it shows,
// one surface in the tabs' style (o.tabs.style; nil: .Folder). Without a size from `next`, it fills its parent.
@(require_results, deferred_out = tab_panel_end)
tab_panel :: proc(id: string, labels: []string, icons: []string, selected: ^int, o := Tab_Panel_Options{}) -> (r: Tabs_Result, ok: bool) {
	s := gs()
	em := font_size()
	st := o.tabs.style.? or_else .Folder
	_ = tabs_over(st, o.surface)   // (closed by tab_panel_end)
	sf := tab_surface_now()
	pad := o.pad == 0 ? math.round(CARD_PAD * em) : max(o.pad, 0)
	rad := o.radius > 0 ? math.round(o.radius * s.scale) : math.round(em * shape_of(.Control) * 1.2)
	if !s.has_next { next({width = fill(), height = fill()}) }
	set_next_axis(.Y)
	frame := build_box({}, id)
	pd := frame_new(Tab_Panel_Draw)
	pd^ = {style = st, sf = sf, radius = rad, pad = pad, band = tab_header_tone(sf.ground)}
	frame.custom, frame.custom_user = tab_panel_open_draw, pd
	push_parent(frame)
	// the strip: above the panel (Folder), its header (Underline, Header), a switcher inside it (Segmented)
	if st == .Segmented { spacer(px(math.round(pad * 0.6))) }
	next({width = fill(), height = px(math.round(em * (st == .Segmented ? 2.0 : 2.4))), axis = .X, cross = .Center})
	row := build_box({}, "###tab_panel_strip")
	pd.strip = row
	push_parent(row)
	switch st {
	case .Folder:    spacer(px(rad))                // (the first foot clear of the frame's corner)
	case .Underline: spacer(px(max(pad - em, 0)))   // (the first words over the page's first column: a tab pads its words by an em)
	case .Segmented: spacer(px(pad))
	case .Header:
	}
	to := o.tabs
	to.style = st
	to.framed = true
	r = tabs_ex(id, labels, icons, selected, to)
	pop_parent()
	// the page, `pad` in from its sides, on the surface's ground (the frame paints it)
	next({width = fill(), height = fill(), axis = .Y})
	push_parent(build_box({}, "###tab_panel_page"))
	spacer(px(pad))
	next({width = fill(), height = fill(), axis = .X})
	push_parent(build_box({}, "###tab_panel_row"))
	spacer(px(pad))
	next({width = fill(), height = fill(), axis = .Y})
	push_parent(build_box({}, "###tab_panel_body"))
	return r, true
}

@(private)
tab_panel_end :: proc(r: Tabs_Result, ok: bool) {
	frame := parent_box().parent.parent.parent
	pd := (^Tab_Panel_Draw)(frame.custom_user)
	pop_parent()   // the body
	spacer(px(pd.pad))
	pop_parent()   // the row
	spacer(px(pd.pad))
	pop_parent()   // the page
	next({fixed_x = 0, fixed_y = 0, width = pct(1), height = pct(1)})
	end := build_box({}, "###tab_panel_close")
	end.custom, end.custom_user = tab_panel_close_draw, pd
	pop_parent()   // the frame
	tabs_over_end()
}

// The panel's rect as its frame draws it: from the strip's line down (Folder), else the whole box.
@(private)
tab_panel_area :: proc(b: ^Box, pd: ^Tab_Panel_Draw) -> Rect {
	r := Rect{{math.round(b.rect.min.x), math.round(b.rect.min.y)}, {math.round(b.rect.max.x), math.round(b.rect.max.y)}}
	if pd.style == .Folder { r.min.y = math.round(pd.strip.rect.max.y) - px1() }
	return r
}

@(private)
tab_panel_open_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	pd := (^Tab_Panel_Draw)(user)
	p := px1()
	area := tab_panel_area(b, pd)
	rad := pd.radius
	draw.rect(dc, area, pd.sf.ground, rad)
	if pd.style == .Header {
		draw.rect_corners(dc, {area.min, {area.max.x, math.round(pd.strip.rect.max.y)}}, colors4(pd.band), {rad, 0, rad, 0})
	}
	// a Folder: the frame's edge before the tabs (the chosen tab covers the line under it and strokes its own outline onto
	// it), nothing clipped (the strip stands above the frame). The others: the edge after the tabs (tab_panel_close_draw),
	// over what reaches a corner, what they draw kept inside the corners
	if pd.style == .Folder {
		draw.rect(dc, area, pd.sf.edge, rad, p)
		draw.push_clip(dc, b.rect)
		return
	}
	draw.push_clip_rounded(dc, draw.rect_pad(area, -p), {rad - p, rad - p, rad - p, rad - p})
}

@(private)
tab_panel_close_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	pd := (^Tab_Panel_Draw)(user)
	draw.pop_clip(dc)
	if pd.style == .Folder { return }
	draw.rect(dc, tab_panel_area(b.parent, pd), pd.sf.edge, pd.radius, px1())
}

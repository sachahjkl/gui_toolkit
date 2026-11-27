package ui

import "core:math"
import "../draw"

// The design proposals for a row of tabs (src/md/features/tab-styles.md): one switch, four ways for a tab to belong
// to the surface it frames. Every one takes its colours from that surface (Tab_Surface), not from the page: the fault the
// owner saw ("the tabs do not integrate with what they frame") was a chosen tab filled with the page's colour over a
// terminal of another, and a strip line drawn under a content that drew its own frame.

// How the toolkit's rows of tabs look (set_tab_style).
Tab_Style :: enum u8 {
	Silhouette,   // 0.366: every tab outlined on the line, the chosen one rising out of it in the page's colour
	Folder,       // A: the chosen tab is the surface, one outline round tab and content; the others flat words
	Underline,    // B: the strip on the surface itself, no line; the chosen tab's words strong over an accent bar
	Segmented,    // C: a segmented switcher on the surface, inside the content's one frame
	Header,       // D: the strip is the surface's header band; the chosen tab is a hole in it onto the surface
}

// What a row of tabs frames: the ground of the content under it and its edge. A zero ground: the page's; a zero edge:
// the theme's border.
Tab_Surface :: struct {
	ground: Color,
	edge:   Color,
}

TAB_SURFACE_DEPTH :: 8

set_tab_style :: proc(style: Tab_Style) { gs().tab_style = style }
tab_style :: proc() -> Tab_Style { return gs().tab_style }

// `if tab_surface(sf) { ... }`: the rows of tabs built inside frame `sf` (their chosen tab, their strip, their line).
@(require_results, deferred_none = tab_surface_end)
tab_surface :: proc(sf: Tab_Surface) -> bool {
	s := gs()
	if s.tab_surface_depth < TAB_SURFACE_DEPTH { s.tab_surfaces[s.tab_surface_depth] = sf }
	s.tab_surface_depth += 1
	return true
}

@(private)
tab_surface_end :: proc() { s := gs(); s.tab_surface_depth = max(s.tab_surface_depth - 1, 0) }

// The surface in force, its zero colours resolved: the page (a chosen tab's "tab_on background") and the border.
tab_surface_now :: proc() -> Tab_Surface {
	s := gs()
	sf: Tab_Surface
	if d := min(s.tab_surface_depth, TAB_SURFACE_DEPTH); d > 0 { sf = s.tab_surfaces[d - 1] }
	if sf.ground.a <= 0 {
		push_tags("tab_on")
		sf.ground = color("background")
		pop_tags()
		sf.ground.a = 1
	}
	if sf.edge.a <= 0 { sf.edge = color("border") }
	return sf
}

// The palette shown is dark (machined.odin's relief_dark is its file's).
@(private)
tab_dark :: proc() -> bool { s := gs(); return s.theme == nil || s.theme.dark }

// The header band of a surface (Header) and the track of a switcher (Segmented): the surface a step toward the window's
// chrome, the page around it. A card lighter than the page gets a darker band, a terminal darker than it a lighter one:
// a fixed step darker vanished on a terminal's near black. A surface that is the page: a step darker (dark palettes) or a
// shade darker (light ones).
@(private) TAB_TOWARD_PAGE :: 0.65
@(private) TAB_SAME_AS_PAGE :: 0.01   // a lightness difference under which the surface is the page
@(private) TAB_HEADER_DARK_STEP :: 0.3
@(private) TAB_HEADER_LIGHT_STEP :: 0.045
@(private) TAB_HEADER_LEAST :: 0.035   // the least lightness step of a band off its surface: under it, the fixed step adds
tab_header_tone :: proc(ground: Color) -> Color {
	page := color("background")
	page.a = 1
	step: f32 = tab_dark() ? TAB_HEADER_DARK_STEP : TAB_HEADER_LIGHT_STEP
	if abs(tab_lightness(page) - tab_lightness(ground)) <= TAB_SAME_AS_PAGE { return darken(ground, step) }
	tone := srgb_mix(ground, page, TAB_TOWARD_PAGE)
	tone.a = 1
	if abs(tab_lightness(tone) - tab_lightness(ground)) < TAB_HEADER_LEAST {
		toward_dark := tab_lightness(page) < tab_lightness(ground)
		tone = toward_dark || !tab_dark() ? darken(tone, step) : lighten(tone, step * 0.3)
	}
	return tone
}

// A colour's lightness as a person sees it, about its sRGB value (the colours are linear): a step of it reads alike on
// a dark and a light palette.
@(private)
tab_lightness :: proc(c: Color) -> f32 { return math.pow(max(luminance(c), 0), 1 / 2.2) }

// A switcher's track on `ground`, and its raised key. Its own steps, not the band's: a track is a well the key sits in, a
// step lighter than the surface on a dark palette (darker vanished on a terminal's near black), darker on a light one;
// the key lighter again, white on a light palette.
@(private) TAB_TRACK_DARK_STEP :: 0.07
@(private) TAB_TRACK_LIGHT_STEP :: 0.07
@(private) TAB_KEY_DARK_STEP :: 0.17
@(private)
tab_track_tone :: proc(ground: Color) -> Color {
	return tab_dark() ? lighten(ground, TAB_TRACK_DARK_STEP) : darken(ground, TAB_TRACK_LIGHT_STEP)
}
@(private)
tab_key_tone :: proc(ground: Color) -> Color {
	return tab_dark() ? lighten(ground, TAB_KEY_DARK_STEP) : lighten(ground, 1)
}

// What a strip of `style` is painted with under its tabs (on `bar`, the strip's own colour, for the outlined styles).
@(private)
tab_strip_ground :: proc(style: Tab_Style, sf: Tab_Surface, bar: Color) -> Color {
	switch style {
	case .Silhouette, .Folder: return bar
	case .Underline, .Segmented: return sf.ground
	case .Header: return tab_header_tone(sf.ground)
	}
	return bar
}

// A strip's look, as the custom_user of tab_strip_draw and tab_line_draw: its style, the surface it frames and its own
// ground (nil user: the bar's colour and the line in the box's border, the 0.366 strip).
Tab_Strip_Look :: struct {
	style:  Tab_Style,
	ground: Color,   // painted under the tabs (tab_strip_ground)
	edge:   Color,   // the line, for the styles that have one
	line:   bool,
}

// The look of a strip of the style and surface in force, `bar` its own colour (transparent: nothing painted, the line
// only), for tab_strip_draw or tab_line_draw.
tab_strip_look :: proc(bar: Color) -> ^Tab_Strip_Look {
	st := tab_style()
	sf := tab_surface_now()
	l := frame_new(Tab_Strip_Look)
	l^ = {style = st, ground = tab_strip_ground(st, sf, bar), edge = sf.edge, line = st == .Silhouette || st == .Folder}
	return l
}

// The room a strip of style `st` leaves before its first tab.
@(private)
tab_style_inset :: proc(st: Tab_Style) -> f32 {
	switch st {
	case .Silhouette, .Folder: return tab_foot() + math.round(TAB_LINE_LEAD * scale())
	case .Underline, .Header: return 0
	case .Segmented: return math.round(TAB_TRACK_PAD_PX * scale())
	}
	return 0
}
@(private) TAB_LINE_LEAD :: 3
@(private) TAB_TRACK_PAD_PX :: 3

// The chosen tab's accent bar (Underline, Header), logical px.
@(private) TAB_BAR_PX :: 2
// A Segmented key's and an Underline hover's vertical inset, a share of the strip's height.
@(private) TAB_KEY_INSET_SHARE :: 0.16
// An Underline bar's inset from the tab's sides, ems.
@(private) TAB_BAR_INSET_EM :: 0.35

@(private)
tab_hover :: proc(b: ^Box, under: Color, hot: f32) -> Color {
	return draw.mix(under, state_fill(b, box_held(b) > 0.5 ? "press_fill" : "hover_fill", under), hot)
}

// Draws a tab of the styles other than the silhouette (tab_draw calls it; the Folder's chosen tab is the silhouette's).
@(private)
tab_draw_style :: proc(b: ^Box, td: ^Tab_Draw, dc: ^draw.Context) {
	s := gs()
	p := px1()
	r := b.rect
	h := r.max.y - r.min.y
	hot := max(box_hot(b), box_held(b))
	switch td.style {
	case .Silhouette:
	case .Folder:
		// an unchosen tab: words on the strip; under the pointer a fill in the shape a chosen tab has, no outline
		if hot > 0.01 {
			rad := min(td.radius, h / 3)
			top := math.round(r.min.y + h * TAB_TOP_SHARE) + math.round(TAB_SOFT_DROP_PX * s.scale)
			x0, x1 := math.round(r.min.x + td.foot * 0.5), math.round(r.max.x - td.foot * 0.5)
			bottom := math.round(r.max.y) - p
			draw.rect_corners(dc, {{x0, top}, {x1, bottom}}, colors4(tab_hover(b, td.under, hot)), {rad, 0, rad, 0})
		}
	case .Underline:
		if !td.on && hot > 0.01 {
			inset := math.round(h * TAB_KEY_INSET_SHARE)
			rad := min(td.radius, (h - 2 * inset) / 2)
			draw.rect(dc, {{r.min.x + 2 * p, r.min.y + inset}, {r.max.x - 2 * p, r.max.y - inset}}, tab_hover(b, td.under, hot), rad)
		}
		if td.on {
			band := max(p, math.round(TAB_BAR_PX * s.scale))
			in_by := math.round(TAB_BAR_INSET_EM * font_size())
			bottom := math.round(r.max.y)
			draw.rect(dc, {{math.round(r.min.x) + in_by, bottom - band}, {math.round(r.max.x) - in_by, bottom}}, td.accent, band * 0.5)
		}
	case .Segmented:
		// the track: one rounded bar under every tab, each tab painting its part (its ends round at the first and last)
		pad := math.round(TAB_TRACK_PAD_PX * s.scale)
		inset := math.round(h * TAB_KEY_INSET_SHARE)
		first := b.prev == nil || b.prev.custom != tab_draw
		last := b.next == nil || b.next.custom != tab_draw
		track := Rect{{math.round(r.min.x) - (first ? pad : 0), r.min.y + inset - pad}, {math.round(r.max.x) + (last ? pad : 0), r.max.y - inset + pad}}
		tr := min(td.radius + pad, (track.max.y - track.min.y) / 2)
		draw.rect_corners(dc, track, colors4(tab_track_tone(td.ground)), {first ? tr : 0, first ? tr : 0, last ? tr : 0, last ? tr : 0})
		key := Rect{{math.round(r.min.x), r.min.y + inset}, {math.round(r.max.x), r.max.y - inset}}
		kr := min(td.radius, (key.max.y - key.min.y) / 2)
		if td.on {
			face := tab_key_tone(td.ground)
			draw.rect(dc, key, face, kr)
			draw.rect(dc, key, face_over(with_alpha(td.edge, 0.7), face, s.space), kr, p)
		} else if hot > 0.01 {
			draw.rect(dc, key, tab_hover(b, tab_track_tone(td.ground), hot), kr)
		}
	case .Header:
		if td.on {
			// a hole in the header onto the surface: its ground, from the strip's top to its bottom, over the separator
			// before it; the accent along its top
			x0, x1 := math.round(r.min.x) - p, math.round(r.max.x)
			draw.rect(dc, {{x0, r.min.y}, {x1, r.max.y + p}}, td.ground)
			band := max(p, math.round(TAB_BAR_PX * s.scale))
			draw.rect(dc, {{x0, r.min.y}, {x1, r.min.y + band}}, td.accent)
		} else {
			if hot > 0.01 { draw.rect(dc, r, tab_hover(b, td.under, hot)) }
			// (a separator between two unchosen tabs only: the chosen one's sides are its own, the last ends the row)
			if b.next == nil || b.next.custom != tab_draw { return }
			x := math.round(r.max.x) - p
			q := math.round(h * 0.3)
			draw.rect(dc, {{x, r.min.y + q}, {x + p, r.max.y - q}}, face_over(with_alpha(td.edge, 0.8), td.under, s.space))
		}
	}
}

// A strip's ground and line (tab_strip_draw, tab_line_draw with a Tab_Strip_Look).
@(private)
tab_strip_paint :: proc(b: ^Box, l: ^Tab_Strip_Look, dc: ^draw.Context, ground: bool) {
	if ground && l.ground.a > 0 { draw.rect(dc, b.rect, l.ground) }
	if l.line {
		p := px1()
		bottom := math.round(b.rect.max.y)
		draw.rect(dc, {{b.rect.min.x, bottom - p}, {b.rect.max.x, bottom}}, l.edge)
	}
}

////////////////////////////////
// A row of tabs and the panel it shows, one surface (tab_panel)

// What a tab_panel frames, and what its tabs do beyond choosing.
Tab_Panel_Options :: struct {
	surface: Tab_Surface,    // the panel's ground and edge (zero: the page's, the border)
	radius:  f32,            // its corners, logical px (0: the theme's control radius, a fifth more)
	pad:     f32,            // its content's padding, frame px (0: CARD_PAD ems; < 0: none, a terminal's text to the edge)
	tabs:    Tabs_Options,
}

@(private)
Tab_Panel_Draw :: struct {
	style:  Tab_Style,
	sf:     Tab_Surface,
	radius: f32,
	strip:  ^Box,   // the row the strip stands in (its bottom: the folder's line)
	pad:    f32,
	band:   Color,  // the Header's band (tab_header_tone, read in the build: a draw has no tags to read the page with)
}

// `if r, ok := tab_panel(id, labels, icons, &chosen); ok { ...the chosen page... }`: a row of tabs and the panel under it
// as one surface, in the style in force: the panel's ground and edge given once (o.surface) paint the chosen tab, the
// strip and the frame, so nothing draws a second border or a cut between them.
@(require_results, deferred_out = tab_panel_end)
tab_panel :: proc(id: string, labels: []string, icons: []string, selected: ^int, o := Tab_Panel_Options{}) -> (r: Tabs_Result, ok: bool) {
	s := gs()
	em := font_size()
	st := tab_style()
	_ = tab_surface(o.surface)   // (closed by tab_panel_end)
	sf := tab_surface_now()
	pad := o.pad == 0 ? CARD_PAD * em : max(o.pad, 0)
	rad := o.radius > 0 ? math.round(o.radius * s.scale) : math.round(em * shape_of(.Control) * 1.2)
	if !s.has_next { next({width = fill(), height = fill()}) }
	set_next_axis(.Y)
	frame := build_box({}, id)
	pd := frame_new(Tab_Panel_Draw)
	pd^ = {style = st, sf = sf, radius = rad, band = tab_header_tone(sf.ground)}
	frame.custom, frame.custom_user = tab_panel_open_draw, pd
	push_parent(frame)
	// the strip: above the panel (Folder), its header (Underline, Header), or a switcher inside it (Segmented)
	if st == .Segmented { spacer(px(math.round(pad * 0.6))) }
	next({width = fill(), height = px(math.round(em * (st == .Segmented ? 2.0 : 2.4))), axis = .X, cross = .Center})
	row := build_box({}, "###tab_panel_strip")
	pd.strip = row
	push_parent(row)
	switch st {
	case .Silhouette, .Folder: spacer(px(rad))   // (the first tab's foot clear of the frame's corner)
	case .Underline: spacer(px(max(pad - em, 0)))   // (the first tab's words over the page's first column: a tab pads its words by an em)
	case .Segmented: spacer(px(pad))
	case .Header:
	}
	to := o.tabs
	to.framed = true
	r = tabs_ex(id, labels, icons, selected, to)
	pop_parent()
	// the page, on the surface's ground (the frame paints it), `pad` in from its sides
	pd.pad = pad
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
	end.custom, end.custom_user = tab_panel_close_draw, frame.custom_user
	pop_parent()   // the frame
	tab_surface_end()
}

// The panel's rect as its frame draws it: from the strip's line down (the outlined styles), else the whole box.
@(private)
tab_panel_area :: proc(b: ^Box, pd: ^Tab_Panel_Draw) -> Rect {
	r := Rect{{math.round(b.rect.min.x), math.round(b.rect.min.y)}, {math.round(b.rect.max.x), math.round(b.rect.max.y)}}
	if pd.style == .Folder || pd.style == .Silhouette { r.min.y = math.round(pd.strip.rect.max.y) - px1() }
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
	// the outlined styles: the frame's edge before the tabs (the chosen tab covers the line under it and strokes its own
	// outline onto it), nothing clipped (the strip stands above the frame). The others: the edge after them
	// (tab_panel_close_draw), what they draw kept inside its corners
	if pd.style == .Folder || pd.style == .Silhouette {
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
	if pd.style == .Folder || pd.style == .Silhouette { return }
	draw.rect(dc, tab_panel_area(b.parent, pd), pd.sf.edge, pd.radius, px1())
}

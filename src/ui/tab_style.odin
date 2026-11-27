package ui

import "core:math"
import "../draw"

// How a row of tabs belongs to the surface it frames (src/md/features/tab-styles.md). Each strip has its style: the
// toolkit's own strips give theirs (a dock's and a stack of views' .Underline, ui.tabs' .Folder), a program's own strip
// takes the one of the tabs_over around it (none: .Folder). Every style takes its colours from that surface
// (Tab_Surface), not from the page: a chosen tab in the page's colour over a terminal of another, and a strip line under
// a content that drew its own frame, were "the tabs do not integrate with what they frame".

Tab_Style :: enum u8 {
	Folder,      // the chosen tab is the surface, one outline round tab and content; the others words (documents)
	Underline,   // the strip on the surface itself, no line; the chosen tab's words strong over an accent bar (docks, editors, terminals)
	Segmented,   // a switcher of keys on a track, inside the content's one frame (a small panel's modes)
	Header,      // the strip is the surface's header band; the chosen tab a hole in it onto the surface
}

// What a row of tabs frames: the ground of the content under it and its edge. A zero ground: the page's; a zero edge:
// the theme's border.
Tab_Surface :: struct {
	ground: Color,
	edge:   Color,
}

@(private)
Tab_Scope :: struct { style: Tab_Style, surface: Tab_Surface }

TAB_SCOPE_DEPTH :: 8

// `if tabs_over(style, sf) { ... }`: the rows of tabs built inside have `style` and frame `sf` (their chosen tab, their
// strip's ground, their line, the inset of a panel's content: dock_content_inset).
@(require_results, deferred_none = tabs_over_end)
tabs_over :: proc(style: Tab_Style, sf: Tab_Surface = {}) -> bool {
	s := gs()
	if s.tab_scope_depth < TAB_SCOPE_DEPTH { s.tab_scopes[s.tab_scope_depth] = {style, sf} }
	s.tab_scope_depth += 1
	return true
}

@(private)
tabs_over_end :: proc() { s := gs(); s.tab_scope_depth = max(s.tab_scope_depth - 1, 0) }

@(private)
tab_scope_now :: proc() -> Tab_Scope {
	s := gs()
	if d := min(s.tab_scope_depth, TAB_SCOPE_DEPTH); d > 0 { return s.tab_scopes[d - 1] }
	return {style = .Folder}
}

// The style of the rows of tabs built here (tabs_over; none: .Folder).
tab_style_now :: proc() -> Tab_Style { return tab_scope_now().style }

// The surface the rows of tabs built here frame, its zero colours resolved: the page (a chosen tab's "tab_on
// background") and the border.
tab_surface_now :: proc() -> Tab_Surface {
	sf := tab_scope_now().surface
	if sf.ground.a <= 0 {
		push_tags("tab_on")
		sf.ground = color("background")
		pop_tags()
		sf.ground.a = 1
	}
	if sf.edge.a <= 0 { sf.edge = color("border") }
	return sf
}

// The palette shown is dark.
@(private)
tab_dark :: proc() -> bool { s := gs(); return s.theme == nil || s.theme.dark }

// A colour's lightness as a person sees it, about its sRGB value (the colours are linear): a step of it reads alike on
// a dark and a light palette. A step in linear luminance vanished on a light card and was huge on a dark one.
@(private)
tab_lightness :: proc(c: Color) -> f32 { return math.pow(max(luminance(c), 0), 1 / 2.2) }

// The header band of a surface (Header): the surface a step toward the page, the chrome around it. A card lighter than
// the page gets a darker band, a terminal darker than it a lighter one (a fixed step darker vanished on a terminal's
// near black). A surface that is the page: a step darker. Read in the build: a draw has no tags to read the page with.
@(private) TAB_TOWARD_PAGE :: 0.65
@(private) TAB_SAME_AS_PAGE :: 0.01   // a lightness difference under which the surface is the page
@(private) TAB_HEADER_DARK_STEP :: 0.3
@(private) TAB_HEADER_LIGHT_STEP :: 0.045
@(private) TAB_HEADER_LEAST :: 0.035   // the least lightness step of a band off its surface: under it, the fixed step adds
@(private)
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

// A switcher's track on `ground` (a well the keys sit in: lighter on a dark palette, where darker vanished on a near
// black, darker on a light one), and its chosen key (lighter again; white on a light palette).
@(private) TAB_TRACK_STEP :: 0.07
@(private) TAB_KEY_DARK_STEP :: 0.17
@(private)
tab_track_tone :: proc(ground: Color) -> Color { return tab_dark() ? lighten(ground, TAB_TRACK_STEP) : darken(ground, TAB_TRACK_STEP) }
@(private)
tab_key_tone :: proc(ground: Color) -> Color { return tab_dark() ? lighten(ground, TAB_KEY_DARK_STEP) : lighten(ground, 1) }

// What a strip of `style` paints under its tabs: `bar` (Folder: its own colour; transparent: nothing), the surface
// (Underline, Segmented), the band (Header).
@(private)
tab_strip_ground :: proc(style: Tab_Style, sf: Tab_Surface, bar: Color) -> Color {
	switch style {
	case .Folder:                return bar
	case .Underline, .Segmented: return sf.ground
	case .Header:                return tab_header_tone(sf.ground)
	}
	return bar
}

// A strip's look, the custom_user of tab_strip_draw or tab_line_draw: its ground and, for a Folder, its line.
Tab_Strip_Look :: struct {
	ground: Color,
	edge:   Color,
	line:   bool,
}

// The look of a strip of the style and surface in force (tabs_over), `bar` its own colour for a Folder (transparent:
// nothing painted, the line only), for tab_strip_draw or tab_line_draw.
tab_strip_look :: proc(bar: Color) -> ^Tab_Strip_Look {
	sc := tab_scope_now()
	sf := tab_surface_now()
	l := frame_new(Tab_Strip_Look)
	l^ = {ground = tab_strip_ground(sc.style, sf, bar), edge = sf.edge, line = sc.style == .Folder}
	return l
}

@(private)
tab_strip_paint :: proc(b: ^Box, l: ^Tab_Strip_Look, dc: ^draw.Context, ground: bool) {
	if ground && l.ground.a > 0 { draw.rect(dc, b.rect, l.ground) }
	if l.line {
		p := px1()
		bottom := math.round(b.rect.max.y)
		draw.rect(dc, {{b.rect.min.x, bottom - p}, {b.rect.max.x, bottom}}, l.edge)
	}
}

// The room a strip of style `st` leaves before its first tab: a Folder's left foot and a short run of the line, a
// Segmented track's pad, none for the others (their first words over the content's first column).
@(private)
tab_style_inset :: proc(st: Tab_Style) -> f32 {
	switch st {
	case .Folder:              return tab_foot() + math.round(TAB_LINE_LEAD_PX * scale())
	case .Underline, .Header:  return 0
	case .Segmented:           return math.round(TAB_TRACK_PAD_PX * scale())
	}
	return 0
}
@(private) TAB_LINE_LEAD_PX :: 3   // the line's straight run between a pane's edge and a Folder's first foot
@(private) TAB_TRACK_PAD_PX :: 3   // a switcher's track round its keys

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

// Draws a tab of every style but the Folder's chosen one (tab_draw's silhouette).
@(private)
tab_draw_style :: proc(b: ^Box, td: ^Tab_Draw, dc: ^draw.Context) {
	s := gs()
	p := px1()
	r := b.rect
	h := r.max.y - r.min.y
	hot := max(box_hot(b), box_held(b))
	accent := td.mark.a > 0 ? td.mark : td.accent
	switch td.style {
	case .Folder:
		// an unchosen tab: words on the strip; under the pointer a fill in a chosen tab's shape, no outline
		if hot > 0.01 {
			rad := min(td.radius, h / 3)
			top := math.round(r.min.y + h * TAB_TOP_SHARE) + math.round(TAB_HOVER_DROP_PX * s.scale)
			x0, x1 := math.round(r.min.x + td.foot * 0.5), math.round(r.max.x - td.foot * 0.5)
			draw.rect_corners(dc, {{x0, top}, {x1, math.round(r.max.y) - p}}, colors4(tab_hover(b, td.under, hot)), {rad, 0, rad, 0})
		}
	case .Underline:
		if !td.on && hot > 0.01 {
			inset := math.round(h * TAB_KEY_INSET_SHARE)
			rad := min(td.radius, (h - 2 * inset) / 2)
			draw.rect(dc, {{r.min.x + 2 * p, r.min.y + inset}, {r.max.x - 2 * p, r.max.y - inset}}, tab_hover(b, td.under, hot), rad)
		}
		if td.on {
			band := max(p, math.round(TAB_BAR_PX * s.scale))
			in_by := math.round(TAB_BAR_INSET_EM * td.em)
			bottom := math.round(r.max.y)
			draw.rect(dc, {{math.round(r.min.x) + in_by, bottom - band}, {math.round(r.max.x) - in_by, bottom}}, accent, band * 0.5)
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
			// a hole in the band onto the surface: its ground, the strip's height, over the separator before it; the
			// accent along its top
			x0, x1 := math.round(r.min.x) - p, math.round(r.max.x)
			draw.rect(dc, {{x0, r.min.y}, {x1, r.max.y}}, td.ground)
			band := max(p, math.round(TAB_BAR_PX * s.scale))
			draw.rect(dc, {{x0, r.min.y}, {x1, r.min.y + band}}, accent)
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

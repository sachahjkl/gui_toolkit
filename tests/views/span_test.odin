package views_test

// How far the top and the bottom zones go across (src/md/features/views.md, section 6.1b): the rects of the four zones
// in each span at several sizes, the pinwheel's yield, the defaults of a frame and of a space of the program's, a drop
// at the bottom in .Content, the person's choice remembered and forgotten, the memory's line, the content's state kept
// across a change of span.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import store "gt:store"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") WINDOW :: [2]int{1000, 700}
@(private = "file") SIDE_EM :: 10
@(private = "file") TOP_EM :: 5
@(private = "file") LOW_EM :: 8
@(private = "file") NEAR :: f32(1.5)   // (px: a rect's edge against another's, the handle aside)

@(private = "file")
Spans :: struct {
	views:   ui.Views,
	want:    [dynamic]string,
	frame_o: ui.View_Dock_Options,
	field:   ui.Line_Edit,
	em:      f32,
}

@(private = "file")
spans_build :: proc(s: ^session.Session) {
	r := (^Spans)(s.user)
	for id in r.want { ui.view_open(&r.views, id, r) }
	clear(&r.want)
	r.em = ui.font_size()
	if ui.views_frame(&r.views, r.frame_o) {
		ui.next({width = ui.px(200), height = ui.px(30)})
		ui.line_edit("###content_field", &r.field)
	}
}

@(private = "file")
words_view :: proc(v: ^ui.View, r: ^Spans) {
	ui.label(fmt.tprintf("%s###words_%s", v.id, v.id))
}

@(private = "file")
spans_register :: proc(r: ^Spans) {
	ui.view_register(&r.views, "left", words_view, ui.View_Options{title = "Left", home = .Panel, home_place = {edge = .Left}, extent_em = SIDE_EM})
	ui.view_register(&r.views, "right", words_view, ui.View_Options{title = "Right", home = .Panel, home_place = {edge = .Right}, extent_em = SIDE_EM})
	ui.view_register(&r.views, "top", words_view, ui.View_Options{title = "Top", home = .Panel, home_place = {edge = .Top}, extent_em = TOP_EM})
	ui.view_register(&r.views, "bottom", words_view, ui.View_Options{title = "Bottom", home = .Panel, home_place = {edge = .Bottom}, extent_em = LOW_EM})
	ui.view_register(&r.views, "ask", words_view, ui.View_Options{title = "Question"})
}

@(private = "file")
spans_start :: proc(t: ^testing.T, r: ^Spans, want: ..string) -> ^session.Session {
	spans_register(r)
	for w in want { append(&r.want, w) }
	return session.start(t, {size = WINDOW, user = r, build = spans_build})
}

@(private = "file")
spans_end :: proc(r: ^Spans) {
	ui.views_destroy(&r.views)
	ui.line_edit_destroy(&r.field)
	delete(r.want)
}

@(private = "file")
built :: proc(s: ^session.Session, name: string) -> ^ui.Box {
	b := session.find(s, name)
	if b == nil || b.last_build != s.state.build_index || b.transparency >= 1 { return nil }
	return b
}

@(private = "file")
rect_of :: proc(s: ^session.Session, name: string) -> (r: ui.Rect, ok: bool) {
	b := built(s, name)
	if b == nil { return }
	return b.rect, true
}

// The rects of the space, its content and its four zones, after the layout settled.
@(private = "file")
Laid :: struct { space, content, left, right, top, bottom: ui.Rect }

@(private = "file")
laid :: proc(s: ^session.Session) -> (l: Laid, ok: bool) {
	session.frames(s, 3)
	oks: [6]bool
	l.space, oks[0] = rect_of(s, "views_space_")
	l.content, oks[1] = rect_of(s, "views_content")
	l.left, oks[2] = rect_of(s, "view_zone_Left")
	l.right, oks[3] = rect_of(s, "view_zone_Right")
	l.top, oks[4] = rect_of(s, "view_zone_Top")
	l.bottom, oks[5] = rect_of(s, "view_zone_Bottom")
	return l, oks == {true, true, true, true, true, true}
}

@(private = "file")
overlap :: proc(a, b: ui.Rect) -> bool {
	return min(a.max.x, b.max.x) - max(a.min.x, b.min.x) > 0.5 && min(a.max.y, b.max.y) - max(a.min.y, b.min.y) > 0.5
}

@(private = "file")
near :: proc(a, b: f32) -> bool { return abs(a - b) <= NEAR }

// Each corner to the zone the spans give it, the sizes kept, nothing over anything.
@(private = "file")
expect_corners :: proc(t: ^testing.T, l: Laid, top, bottom: ui.View_Span, em: f32, what: string, loc := #caller_location) {
	S := l.space
	// (top left: the top zone's when the top spans the left, else the left zone's; and so on)
	if top == .Left || top == .Full {
		testing.expectf(t, near(l.top.min.x, S.min.x) && l.left.min.y >= l.top.max.y - 0.5, "%s: the top takes the top left: %v, left %v", what, l.top, l.left, loc = loc)
	} else {
		testing.expectf(t, near(l.left.min.y, S.min.y) && l.top.min.x >= l.left.max.x - 0.5, "%s: the left takes the top left: %v, left %v", what, l.top, l.left, loc = loc)
	}
	if top == .Right || top == .Full {
		testing.expectf(t, near(l.top.max.x, S.max.x) && l.right.min.y >= l.top.max.y - 0.5, "%s: the top takes the top right: %v, right %v", what, l.top, l.right, loc = loc)
	} else {
		testing.expectf(t, near(l.right.min.y, S.min.y) && l.top.max.x <= l.right.min.x + 0.5, "%s: the right takes the top right: %v, right %v", what, l.top, l.right, loc = loc)
	}
	if bottom == .Left || bottom == .Full {
		testing.expectf(t, near(l.bottom.min.x, S.min.x) && l.left.max.y <= l.bottom.min.y + 0.5, "%s: the bottom takes the bottom left: %v, left %v", what, l.bottom, l.left, loc = loc)
	} else {
		testing.expectf(t, near(l.left.max.y, S.max.y) && l.bottom.min.x >= l.left.max.x - 0.5, "%s: the left takes the bottom left: %v, left %v", what, l.bottom, l.left, loc = loc)
	}
	if bottom == .Right || bottom == .Full {
		testing.expectf(t, near(l.bottom.max.x, S.max.x) && l.right.max.y <= l.bottom.min.y + 0.5, "%s: the bottom takes the bottom right: %v, right %v", what, l.bottom, l.right, loc = loc)
	} else {
		testing.expectf(t, near(l.right.max.y, S.max.y) && l.bottom.max.x <= l.right.min.x + 0.5, "%s: the right takes the bottom right: %v, right %v", what, l.bottom, l.right, loc = loc)
	}
	// (the extents are the zones' whatever the span)
	testing.expectf(t, near(l.left.max.x - l.left.min.x, SIDE_EM * em) && near(l.right.max.x - l.right.min.x, SIDE_EM * em), "%s: the sides' widths: %v, %v", what, l.left, l.right, loc = loc)
	testing.expectf(t, near(l.top.max.y - l.top.min.y, TOP_EM * em) && near(l.bottom.max.y - l.bottom.min.y, LOW_EM * em), "%s: the heights: %v, %v", what, l.top, l.bottom, loc = loc)
	// (the content between the four)
	C := l.content
	testing.expectf(t, C.min.x >= l.left.max.x && C.max.x <= l.right.min.x && C.min.y >= l.top.max.y && C.max.y <= l.bottom.min.y, "%s: the content between them: %v", what, C, loc = loc)
	rects := [5]ui.Rect{l.content, l.left, l.right, l.top, l.bottom}
	for i in 0 ..< 5 {
		for j in i + 1 ..< 5 { testing.expectf(t, !overlap(rects[i], rects[j]), "%s: %v over %v", what, rects[i], rects[j], loc = loc) }
	}
}

// Every span of the top and of the bottom, at three sizes: each corner goes to its zone, the extents stay, the content
// lies between them, nothing lies over anything. The pinwheels are the next test's.
@(test)
the_zones_follow_their_spans :: proc(t: ^testing.T) {
	r: Spans
	defer spans_end(&r)
	s := spans_start(t, &r, "left", "right", "top", "bottom")
	for size in ([][2]int{WINDOW, {760, 520}, {1400, 900}}) {
		session.resize(s, size)
		for top in ui.View_Span {
			for bottom in ui.View_Span {
				if (top == .Left && bottom == .Right) || (top == .Right && bottom == .Left) { continue }
				r.frame_o.top_span, r.frame_o.bottom_span = top, bottom
				l, ok := laid(s)
				what := fmt.tprintf("%v, top %v, bottom %v", size, top, bottom)
				if !testing.expectf(t, ok, "%s: the space, its content and its four zones", what) { return }
				expect_corners(t, l, top, bottom, r.em, what)
			}
		}
	}
}

// The top .Left with the bottom .Right (and the mirror), the four zones there: no zone can go first, so the top gives
// way and is laid out as .Content. With no right zone, nothing is in the way: the top spans as asked.
@(test)
a_pinwheel_lays_the_top_over_the_content :: proc(t: ^testing.T) {
	r: Spans
	defer spans_end(&r)
	s := spans_start(t, &r, "left", "right", "top", "bottom")
	for pair in ([][2]ui.View_Span{{.Left, .Right}, {.Right, .Left}}) {
		r.frame_o.top_span, r.frame_o.bottom_span = pair[0], pair[1]
		l, ok := laid(s)
		if !testing.expect(t, ok, "the four zones") { return }
		expect_corners(t, l, .Content, pair[1], r.em, fmt.tprintf("pinwheel %v", pair))
	}
	ui.view_close(&r.views, "right")
	r.frame_o.top_span, r.frame_o.bottom_span = .Left, .Right
	session.frames(s, 3)
	top, left, space := built(s, "view_zone_Top"), built(s, "view_zone_Left"), built(s, "views_space_")
	if top == nil || left == nil || space == nil { testing.expect(t, false, "the top, the left, the space"); return }
	testing.expectf(t, near(top.rect.min.x, space.rect.min.x) && left.rect.min.y >= top.rect.max.y - 0.5, "no right zone: the top over the left too: %v, %v", top.rect, left.rect)
}

// A window smaller than its zones' extents, in every span (the pinwheels too): no rect turns inside out. (The zones keep
// their extents and overflow the space then, as before the spans: the toolkit does not shrink a top or bottom zone.)
@(test)
a_tiny_window_turns_no_rect_inside_out :: proc(t: ^testing.T) {
	r: Spans
	defer spans_end(&r)
	s := spans_start(t, &r, "left", "right", "top", "bottom")
	for size in ([][2]int{{150, 110}, {60, 40}}) {
		session.resize(s, size)
		for top in ui.View_Span {
			for bottom in ui.View_Span {
				r.frame_o.top_span, r.frame_o.bottom_span = top, bottom
				session.frames(s, 2)
				space := session.find(s, "views_space_")
				if !testing.expectf(t, space != nil, "%v: the space", size) { return }
				for name in ([]string{"views_content", "view_zone_Left", "view_zone_Right", "view_zone_Top", "view_zone_Bottom"}) {
					b := session.find(s, name)
					if b == nil || b.last_build != s.state.build_index { continue }
					R := b.rect
					testing.expectf(t, R.max.x >= R.min.x && R.max.y >= R.min.y, "%v, top %v, bottom %v: %s inside out: %v", size, top, bottom, name, R)
				}
			}
		}
	}
}

// With no span given: the window's frame lays its bottom zone under the content alone, its side zones the window's
// height; a space of the program's spans its whole width (Mission Control's look).
@(test)
the_defaults_are_content_for_the_frame_and_full_for_a_space :: proc(t: ^testing.T) {
	r: Spans
	defer spans_end(&r)
	s := spans_start(t, &r, "left", "right", "top", "bottom")
	l, ok := laid(s)
	if !testing.expect(t, ok, "the four zones") { return }
	expect_corners(t, l, .Content, .Content, r.em, "the frame's default")
	for e in ([]ui.View_Edge{.Top, .Bottom}) {
		frame, frame_chosen := ui.views_space_span(&r.views, "", e)
		space, space_chosen := ui.views_space_span(&r.views, "mission", e)
		testing.expectf(t, frame == .Content && space == .Full && !frame_chosen && !space_chosen, "%v: the frame %v, a space %v", e, frame, space)
	}
	zones := ui.views_space_zones(&r.views, "")
	testing.expectf(t, zones == {.Left, .Right, .Top, .Bottom}, "the zones laid out: %v", zones)
}

// A dialog dragged in .Content with a zone at each side: the bottom's square is under the content's middle, its preview
// spans the content only, and the view let go there lands under the content, the side zones down to the window's
// bottom.
@(test)
a_drop_at_the_bottom_lands_under_the_content :: proc(t: ^testing.T) {
	r: Spans
	defer spans_end(&r)
	s := spans_start(t, &r, "left", "right", "ask")
	if session.wait_box(s, "modal_view_ask") == nil { return }
	session.frames(s, 3)
	content, ok := rect_of(s, "views_content")
	space, _ := rect_of(s, "views_space_")
	header := built(s, "view_header")
	if !ok || header == nil { testing.expect(t, false, "the content and the dialog's header"); return }
	from := [2]f32{header.rect.min.x + 10, (header.rect.min.y + header.rect.max.y) * 0.5}
	session.press(s, from)
	session.move(s, from + {30, 0})
	session.move(s, from + {60, 0})
	session.frames(s, 2)
	target := built(s, "view_target__Bottom")
	if target == nil { testing.expect(t, false, "the bottom's square"); session.release(s, from + {60, 0}); return }
	at := session.center(target)
	testing.expectf(t, abs(at.x - (content.min.x + content.max.x) * 0.5) <= NEAR + 1, "the square under the content's middle: %v, the content %v", at, content)
	session.move(s, at)
	session.frames(s, 2)
	preview, seen := rect_of(s, "view_preview_view_target__Bottom")
	testing.expectf(t, seen && near(preview.min.x, content.min.x) && near(preview.max.x, content.max.x) && near(preview.max.y, space.max.y),
		"the preview under the content: %v, the content %v", preview, content)
	session.release(s, at)
	if session.wait_box(s, "view_panel_view_ask") == nil { return }
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Panel)
	session.frames(s, 3)
	bottom, b_ok := rect_of(s, "view_zone_Bottom")
	left, _ := rect_of(s, "view_zone_Left")
	right, _ := rect_of(s, "view_zone_Right")
	testing.expectf(t, b_ok && bottom.min.x >= left.max.x && bottom.max.x <= right.min.x, "the bottom zone between the sides: %v, %v, %v", left, bottom, right)
	testing.expectf(t, near(left.max.y, space.max.y) && near(right.max.y, space.max.y), "the sides down to the bottom: %v, %v", left, right)
}

// The person's span wins over the program's, is written in the space's line, comes back after a restart, and goes with
// nil (the program's again) and with views_space_reset.
@(test)
the_person_s_span_is_remembered :: proc(t: ^testing.T) {
	r: Spans
	defer spans_end(&r)
	s := spans_start(t, &r)
	path, _ := filepath.join({s.out, "views_spans.txt"}, context.temp_allocator)
	_ = os.remove(path)   // (the session's folder stays between runs)
	restart :: proc(s: ^session.Session, r: ^Spans, path: string) {
		ui.views_destroy(&r.views)
		ui.views_init(&r.views, {path = path})
		spans_register(r)
		for id in ([]string{"left", "right", "top", "bottom"}) { ui.view_open(&r.views, id, r, owner = s.state) }
	}
	restart(s, &r, path)
	r.frame_o.bottom_span = .Content
	ui.views_space_set_span(&r.views, "", .Bottom, .Full)
	l, ok := laid(s)
	if !testing.expect(t, ok, "the four zones") { return }
	expect_corners(t, l, .Content, .Full, r.em, "the person's .Full over the program's .Content")
	text, _ := store.get(&r.views.memory, "#")
	testing.expectf(t, strings.contains(text, "bottom.span=full"), "in the space's line: %q", text)

	restart(s, &r, path)
	span, chosen := ui.views_space_span(&r.views, "", .Bottom)
	testing.expectf(t, span == .Full && chosen, "read back: %v, %v", span, chosen)
	l, ok = laid(s)
	if !testing.expect(t, ok, "the four zones, restarted") { return }
	expect_corners(t, l, .Content, .Full, r.em, "restarted")

	ui.views_space_set_span(&r.views, "", .Bottom, nil)
	span, chosen = ui.views_space_span(&r.views, "", .Bottom)
	text, _ = store.get(&r.views.memory, "#")
	testing.expectf(t, span == .Content && !chosen && !strings.contains(text, "span"), "forgotten: %v, %v, %q", span, chosen, text)

	ui.views_space_set_span(&r.views, "", .Top, .Right)
	ui.views_space_reset(&r.views, "")
	span, chosen = ui.views_space_span(&r.views, "", .Top)
	testing.expectf(t, span == .Content && !chosen, "the layout as at first forgets it: %v, %v", span, chosen)
	// (a side zone has no span)
	ui.views_space_set_span(&r.views, "", .Left, .Full)
	text, _ = store.get(&r.views.memory, "#")
	testing.expectf(t, !strings.contains(text, "left.span"), "no span at the left: %q", text)
}

// The memory's line: a span read and written back; a word it does not know refuses the line.
@(test)
a_space_line_keeps_its_spans :: proc(t: ^testing.T) {
	m, ok := ui.views_space_parse("v1 top.span=left bottom.span=content bottom=8.0")
	testing.expect(t, ok, "parsed")
	top, top_ok := m.span[.Top].?
	bottom, bottom_ok := m.span[.Bottom].?
	testing.expectf(t, top_ok && top == .Left && bottom_ok && bottom == .Content, "the spans: %v", m.span)
	line := ui.views_space_format(m)
	testing.expectf(t, strings.contains(line, "top.span=left") && strings.contains(line, "bottom.span=content"), "written back: %q", line)
	_, bad := ui.views_space_parse("v1 bottom.span=wide")
	testing.expect(t, !bad, "a span it does not know: refused")
	// (a line of the version before the spans: no span, no maximise, the program's defaults; written back the same)
	old := "v1 left=18.0 left.axis=y left.shares=0.400,0.350 bottom.frac=0.250"
	m, ok = ui.views_space_parse(old)
	_, maxed := m.max.?
	testing.expectf(t, ok && m.span == {} && !maxed, "an older line: %v, %v", m.span, m.max)
	testing.expectf(t, ui.views_space_format(m) == old, "written back the same: %q", ui.views_space_format(m))
}

// A change of span changes the nest of boxes around the content; the content's key and what is in it stay: the field
// typed in keeps the focus and its text.
@(test)
a_change_of_span_keeps_the_content_s_state :: proc(t: ^testing.T) {
	r: Spans
	defer spans_end(&r)
	s := spans_start(t, &r, "left", "bottom")
	session.frames(s, 3)
	field := built(s, "content_field")
	content := built(s, "views_content")
	if field == nil || content == nil { testing.expect(t, false, "the content's field"); return }
	key := content.key
	session.click_at(s, session.center(field))
	session.type_text(s, "kept")
	session.frames(s, 2)
	focus := s.state.focus_key
	for span in ([]ui.View_Span{.Full, .Left, .Content}) {
		ui.views_space_set_span(&r.views, "", .Bottom, span)
		session.frames(s, 3)
		content = built(s, "views_content")
		testing.expectf(t, content != nil && content.key == key, "%v: the content's key kept", span)
		testing.expectf(t, s.state.focus_key == focus, "%v: the focus kept", span)
		testing.expectf(t, ui.line_edit_string(&r.field) == "kept", "%v: the text kept: %q", span, ui.line_edit_string(&r.field))
	}
}

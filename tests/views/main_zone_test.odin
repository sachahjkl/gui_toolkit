package views_test

// The main zone and a maximise that keeps zones (src/md/features/views.md, sections 6.1c and 6.1d): a view in the main
// zone has the content's rect, the content back when it closes, the focus moved off the hidden content, the place
// remembered; a maximise keeping the left zone leaves its rect as it was and gives the rest to the stack, the person
// turns it off by a double click on the strip, its menu or Escape; a drop into a zone it hides ends it; it is
// remembered with the layout and waits at a start for its stack.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import store "gt:store"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") WINDOW :: [2]int{1100, 720}
@(private = "file") SIDE_EM :: 11
@(private = "file") LOW_EM :: 9
@(private = "file") NEAR :: f32(1.5)

@(private = "file")
Main :: struct {
	views:   ui.Views,
	want:    [dynamic]string,
	frame_o: ui.View_Dock_Options,
	content: ui.Line_Edit,
	swarm:   ui.Line_Edit,
	main:    string,   // view_show_main of this id in the next build ("": none)
}

@(private = "file")
main_build :: proc(s: ^session.Session) {
	r := (^Main)(s.user)
	for id in r.want { ui.view_open(&r.views, id, r) }
	clear(&r.want)
	if r.main != "" {
		ui.view_show_main(&r.views, r.main, r)
		r.main = ""
	}
	if ui.views_frame(&r.views, r.frame_o) {
		ui.next({width = ui.px(220), height = ui.px(30)})
		ui.line_edit("###content_field", &r.content)
	}
}

@(private = "file")
plain_words :: proc(v: ^ui.View, r: ^Main) { ui.label(fmt.tprintf("%s###words_%s", v.id, v.id)) }

@(private = "file")
swarm_view :: proc(v: ^ui.View, r: ^Main) {
	ui.next({width = ui.px(220), height = ui.px(30)})
	ui.line_edit("###swarm_field", &r.swarm)
}

@(private = "file")
term_view :: proc(v: ^ui.View, r: ^Main) {
	// (a button, not a field: a field takes Escape itself)
	ui.next({width = ui.px(120)})
	ui.button("term_button", "Run")
}

@(private = "file")
main_register :: proc(r: ^Main) {
	ui.view_register(&r.views, "left", plain_words, ui.View_Options{title = "Sessions", home = .Panel, home_place = {edge = .Left}, extent_em = SIDE_EM})
	ui.view_register(&r.views, "right", plain_words, ui.View_Options{title = "Preview", home = .Panel, home_place = {edge = .Right}, extent_em = SIDE_EM})
	ui.view_register(&r.views, "term", term_view, ui.View_Options{title = "Terminal", home = .Panel, home_place = {edge = .Bottom}, extent_em = LOW_EM, tabs_always = true})
	ui.view_register(&r.views, "swarm", swarm_view, ui.View_Options{title = "Swarm", home = .Dialog})
	ui.view_register(&r.views, "ask", plain_words, ui.View_Options{title = "Question"})
}

@(private = "file")
main_start :: proc(t: ^testing.T, r: ^Main, want: ..string) -> ^session.Session {
	main_register(r)
	for w in want { append(&r.want, w) }
	return session.start(t, {size = WINDOW, user = r, build = main_build})
}

@(private = "file")
main_end :: proc(r: ^Main) {
	ui.views_destroy(&r.views)
	ui.line_edit_destroy(&r.content)
	ui.line_edit_destroy(&r.swarm)
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

@(private = "file")
same :: proc(a, b: ui.Rect) -> bool {
	return abs(a.min.x - b.min.x) <= NEAR && abs(a.min.y - b.min.y) <= NEAR && abs(a.max.x - b.max.x) <= NEAR && abs(a.max.y - b.max.y) <= NEAR
}

@(private = "file")
wide :: proc(r: ui.Rect) -> f32 { return r.max.x - r.min.x }

// A view shown in the main zone has the rect the content had, the content laid out at no size with its field kept; the
// focus left in the content goes to the view; closed, the content is back where it was.
@(test)
a_view_in_the_main_zone_takes_the_content_s_rect :: proc(t: ^testing.T) {
	r: Main
	defer main_end(&r)
	s := main_start(t, &r, "left", "term")
	session.frames(s, 4)
	before, ok := rect_of(s, "views_content")
	field := built(s, "content_field")
	if !ok || field == nil { testing.expect(t, false, "the content and its field"); return }
	session.click_at(s, session.center(field))
	session.type_text(s, "draft")
	_, _, shown := ui.views_main(&r.views)
	testing.expect(t, !shown, "no main view yet")

	r.main = "swarm"
	if session.wait_box(s, "view_panel_view_swarm") == nil { return }
	session.frames(s, 3)
	zone, zok := rect_of(s, "view_zone_Center")
	testing.expectf(t, zok && same(zone, before), "the main zone has the content's rect: %v, the content was %v", zone, before)
	// (a box of no size is found by no name: the content is laid out at none)
	testing.expect(t, session.find(s, "views_content") == nil, "the content at no size")
	id, _, main_ok := ui.views_main(&r.views)
	testing.expectf(t, main_ok && id == "swarm", "views_main: %q", id)
	swarm_field := built(s, "swarm_field")
	testing.expectf(t, swarm_field != nil && s.state.focus_key == swarm_field.key, "the focus off the hidden content, into the view")
	testing.expect_value(t, ui.view_presentation(&r.views, "swarm"), ui.View_Presentation.Panel)

	ui.view_close(&r.views, "swarm")
	session.frames(s, 3)
	after, back := rect_of(s, "views_content")
	testing.expectf(t, back && same(after, before), "the content back where it was: %v, %v", after, before)
	testing.expect(t, built(s, "view_zone_Center") == nil, "no main zone")
	testing.expectf(t, ui.line_edit_string(&r.content) == "draft", "its field's text kept: %q", ui.line_edit_string(&r.content))
	_, _, shown = ui.views_main(&r.views)
	testing.expect(t, !shown, "views_main: none")
}

// The main view's place is its memory line's: opened again after a restart, it is in the main zone again.
@(test)
the_main_view_is_remembered :: proc(t: ^testing.T) {
	r: Main
	defer main_end(&r)
	s := main_start(t, &r)
	path, _ := filepath.join({s.out, "views_main.txt"}, context.temp_allocator)
	_ = os.remove(path)
	ui.views_destroy(&r.views)
	ui.views_init(&r.views, {path = path})
	main_register(&r)
	r.main = "swarm"
	if session.wait_box(s, "view_panel_view_swarm") == nil { return }
	ui.views_destroy(&r.views)
	ui.views_init(&r.views, {path = path})
	main_register(&r)
	append(&r.want, "swarm")
	if session.wait_box(s, "view_panel_view_swarm") == nil { return }
	session.frames(s, 2)
	testing.expect(t, built(s, "view_zone_Center") != nil, "in the main zone again")
	ui.view_reattach(&r.views, "swarm")
	// (the main zone shows it until the dialog is measured: then the content is back)
	for _ in 0 ..< 60 {
		if built(s, "view_zone_Center") == nil { break }
		session.frame(s)
	}
	testing.expect(t, built(s, "view_zone_Center") == nil && built(s, "views_content") != nil, "re-attached: a dialog, the content back")
	testing.expect_value(t, ui.view_presentation(&r.views, "swarm"), ui.View_Presentation.Dialog)
}

// The program maximises the terminal's stack keeping the left zone: the left zone's rect is as it was, the stack takes
// the rest of the window, the right zone and the content are not seen. The line keeps it.
@(test)
a_maximise_keeps_its_zones :: proc(t: ^testing.T) {
	r: Main
	defer main_end(&r)
	s := main_start(t, &r, "left", "right", "term")
	session.frames(s, 4)
	left, lok := rect_of(s, "view_zone_Left")
	space, _ := rect_of(s, "views_space_")
	if !lok { testing.expect(t, false, "the left zone"); return }
	ui.views_space_maximise(&r.views, "", .Bottom, 0, {.Left})
	session.frames(s, 3)
	kept, kok := rect_of(s, "view_zone_Left")
	low, bok := rect_of(s, "view_zone_Bottom")
	testing.expectf(t, kok && same(kept, left), "the left zone as it was: %v, %v", kept, left)
	testing.expectf(t, bok && low.min.x >= left.max.x && abs(low.max.x - space.max.x) <= NEAR && abs(low.min.y - space.min.y) <= NEAR && abs(low.max.y - space.max.y) <= NEAR,
		"the stack the rest of the window: %v, the left %v, the space %v", low, left, space)
	testing.expect(t, built(s, "view_zone_Right") == nil, "the right zone hidden")
	testing.expect(t, session.find(s, "views_content") == nil, "the content at no size")
	testing.expect_value(t, ui.views_space_maximise_keeps(&r.views, ""), bit_set[ui.View_Edge]{.Left})
	text, _ := store.get(&r.views.memory, "#")
	testing.expectf(t, strings.contains(text, "max=bottom.0") && strings.contains(text, "max.keep=left"), "in the space's line: %q", text)
	m, parsed := ui.views_space_parse(text)
	x, has_max := m.max.?
	testing.expectf(t, parsed && has_max && x == {edge = .Bottom, stack = 0, keep = {.Left}}, "read back: %v", m.max)

	// off by Escape in the stack, then by a double click on its strip, then by its menu
	ui.view_open(&r.views, "term", &r)   // (the focus into it)
	session.frames(s, 2)
	button := built(s, "term_button")
	testing.expect(t, button != nil && s.state.focus_key == button.key, "the focus in the stack")
	session.key(s, .Escape)
	session.frames(s, 2)
	_, _, maxed := ui.views_space_maximised(&r.views, "")
	testing.expect(t, !maxed, "Escape in the stack restores")
	testing.expect(t, built(s, "view_zone_Right") != nil, "the right zone back")

	ui.views_space_maximise(&r.views, "", .Bottom, 0, {.Left})
	session.frames(s, 3)
	bar := built(s, "view_tabs")
	if bar == nil { testing.expect(t, false, "the terminal's strip"); return }
	session.click_at(s, {bar.rect.min.x + (bar.rect.max.x - bar.rect.min.x) * 0.55, (bar.rect.min.y + bar.rect.max.y) * 0.5}, count = 2)
	session.frames(s, 2)
	_, _, maxed = ui.views_space_maximised(&r.views, "")
	testing.expect(t, !maxed, "a double click on the strip restores")
	session.click_at(s, {bar.rect.min.x + (bar.rect.max.x - bar.rect.min.x) * 0.55, (bar.rect.min.y + bar.rect.max.y) * 0.5}, count = 2)
	session.frames(s, 2)
	_, _, maxed = ui.views_space_maximised(&r.views, "")
	testing.expect(t, maxed, "and maximises again")

	bar = built(s, "view_tabs")
	if bar == nil { return }
	session.click_at(s, {bar.rect.min.x + (bar.rect.max.x - bar.rect.min.x) * 0.55, (bar.rect.min.y + bar.rect.max.y) * 0.5}, .Right)
	session.frames(s, 2)
	testing.expect(t, ui.menu_is_open("###view_menu_view_term"), "the strip's free part opens the view's menu")
	session.click_text(s, "Restore")
	session.frames(s, 2)
	_, _, maxed = ui.views_space_maximised(&r.views, "")
	testing.expect(t, !maxed, "the menu's Restore restores")
	after, _ := rect_of(s, "view_zone_Left")
	testing.expectf(t, same(after, left), "the left zone as at first: %v", after)
}

// The person's Maximise keeps View_Dock_Options.maximise_keeps; a drop into a zone it hides ends it.
@(test)
the_person_s_maximise_keeps_the_program_s_zones :: proc(t: ^testing.T) {
	r: Main
	defer main_end(&r)
	r.frame_o.maximise_keeps = {.Left}
	s := main_start(t, &r, "left", "right", "term")
	session.frames(s, 4)
	max_button := built(s, "view_stack_max")
	if max_button == nil { testing.expect(t, false, "the strip's Maximise"); return }
	session.click_at(s, session.center(max_button))
	session.frames(s, 3)
	e, _, maxed := ui.views_space_maximised(&r.views, "")
	testing.expectf(t, maxed && e == .Bottom && ui.views_space_maximise_keeps(&r.views, "") == {.Left}, "maximised keeping the left: %v %v", e, ui.views_space_maximise_keeps(&r.views, ""))
	testing.expect(t, built(s, "view_zone_Left") != nil && built(s, "view_zone_Right") == nil, "the left kept, the right hidden")
	append(&r.want, "ask")
	if session.wait_box(s, "modal_view_ask") == nil { return }
	session.frames(s, 3)

	header := built(s, "view_header")
	if header == nil { testing.expect(t, false, "the dialog's header"); return }
	from := [2]f32{header.rect.min.x + 10, (header.rect.min.y + header.rect.max.y) * 0.5}
	session.press(s, from)
	session.move(s, from + {30, 0})
	session.move(s, from + {60, 0})
	session.frames(s, 2)
	target := built(s, "view_target__Right")
	if target == nil { testing.expect(t, false, "the right's square"); session.release(s, from + {60, 0}); return }
	at := session.center(target)
	session.move(s, at)
	session.release(s, at)
	if session.wait_box(s, "view_panel_view_ask") == nil { return }
	session.frames(s, 2)
	_, _, maxed = ui.views_space_maximised(&r.views, "")
	testing.expect(t, !maxed, "a drop into a hidden zone ends the maximise")
	testing.expect(t, built(s, "view_zone_Right") != nil, "the right zone shows, with the view dropped")
}

// Remembered: a restart shows the maximise again once its stack's view reopens; before that the space is laid out as
// if none, and the memory keeps it.
@(test)
a_maximise_is_remembered_and_waits_for_its_stack :: proc(t: ^testing.T) {
	r: Main
	defer main_end(&r)
	s := main_start(t, &r)
	path, _ := filepath.join({s.out, "views_max.txt"}, context.temp_allocator)
	_ = os.remove(path)
	restart :: proc(r: ^Main, path: string) {
		ui.views_destroy(&r.views)
		ui.views_init(&r.views, {path = path})
		main_register(r)
	}
	restart(&r, path)
	append(&r.want, "left", "term")
	if session.wait_box(s, "view_panel_view_term") == nil { return }
	ui.views_space_maximise(&r.views, "", .Bottom, 0, {.Left})
	session.frames(s, 3)
	restart(&r, path)
	append(&r.want, "left")
	session.frames(s, 4)
	_, _, maxed := ui.views_space_maximised(&r.views, "")
	testing.expect(t, maxed, "kept while its stack's view is not open yet")
	testing.expect(t, built(s, "views_content") != nil && wide(built(s, "views_content").rect) > 10, "the content shows meanwhile")
	append(&r.want, "term")
	if session.wait_box(s, "view_panel_view_term") == nil { return }
	session.frames(s, 3)
	testing.expect(t, session.find(s, "views_content") == nil, "maximised again: the content at no size")
	testing.expect(t, built(s, "view_zone_Left") != nil, "the left kept")
	// (its stack empties after it showed: the maximise ends)
	ui.view_close(&r.views, "term")
	session.frames(s, 3)
	_, _, maxed = ui.views_space_maximised(&r.views, "")
	testing.expect(t, !maxed, "its stack gone: ended")
}

// A maximise remembered whose views never reopen (the program removed the view) shows nothing of itself; the person who
// then drops another view into its stack lays out the window: the maximise ends, the content stays.
@(test)
a_maximise_waiting_ends_at_a_drop :: proc(t: ^testing.T) {
	r: Main
	defer main_end(&r)
	s := main_start(t, &r)
	path, _ := filepath.join({s.out, "views_max_drop.txt"}, context.temp_allocator)
	_ = os.remove(path)
	restart :: proc(r: ^Main, path: string) {
		ui.views_destroy(&r.views)
		ui.views_init(&r.views, {path = path})
		main_register(r)
	}
	restart(&r, path)
	append(&r.want, "left", "term")
	if session.wait_box(s, "view_panel_view_term") == nil { return }
	ui.views_space_maximise(&r.views, "", .Bottom, 0, {.Left})
	session.frames(s, 3)
	restart(&r, path)
	append(&r.want, "left", "ask")
	if session.wait_box(s, "modal_view_ask") == nil { return }
	session.frames(s, 3)
	content := built(s, "views_content")
	testing.expect(t, content != nil && wide(content.rect) > 10, "the content shows while the maximise waits")

	header := built(s, "view_header")
	if header == nil { testing.expect(t, false, "the dialog's header"); return }
	from := [2]f32{header.rect.min.x + 10, (header.rect.min.y + header.rect.max.y) * 0.5}
	session.press(s, from)
	session.move(s, from + {30, 0})
	session.move(s, from + {60, 0})
	session.frames(s, 2)
	target := built(s, "view_target__Bottom")
	if target == nil { testing.expect(t, false, "the bottom's square"); session.release(s, from + {60, 0}); return }
	at := session.center(target)
	session.move(s, at)
	session.release(s, at)
	if session.wait_box(s, "view_panel_view_ask") == nil { return }
	session.frames(s, 3)
	_, _, maxed := ui.views_space_maximised(&r.views, "")
	testing.expect(t, !maxed, "the drop ended the waiting maximise")
	content = built(s, "views_content")
	testing.expect(t, content != nil && wide(content.rect) > 10, "the content still shows")
}

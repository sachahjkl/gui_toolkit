package views_test

// What a program of several windows and views asks of the toolkit: the moves of the views one window owns (its palette's
// list), a field focused on a view's first build whatever keys its widget gives its boxes (focus_next_field), an icon
// per opening (view_icon).

import "core:testing"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") FRAMES_MAX :: 40

@(private = "file")
Owners :: struct {
	views:   ui.Views,
	want:    string,
	width:   int,
	first:   bool,   // the view's first build is over
	icon:    string, // view_icon's, in the view's first build ("": none)
}

@(private = "file")
owners_build :: proc(s: ^session.Session) {
	r := (^Owners)(s.user)
	if r.want != "" { ui.view_open(&r.views, r.want, r); r.want = "" }
}

@(private = "file")
sized_view :: proc(v: ^ui.View, r: ^Owners) {
	if r.icon != "" { ui.view_icon(v, r.icon) }
	if ui.dialog_body("sized_body") {
		// (the number's field takes the keyboard on the first build: no key of the number's own boxes rebuilt here)
		if !r.first { r.first = true; ui.focus_next_field() }
		ui.number("width", &r.width)
	}
}

@(private = "file")
owners_end :: proc(r: ^Owners) { ui.views_destroy(&r.views) }

@(private = "file")
built :: proc(s: ^session.Session, name: string) -> ^ui.Box {
	b := session.find(s, name)
	if b == nil || b.last_build != s.state.build_index || b.transparency >= 1 { return nil }
	return b
}

@(private = "file")
wait_built :: proc(s: ^session.Session, name: string, loc := #caller_location) -> ^ui.Box {
	for _ in 0 ..< FRAMES_MAX {
		if b := built(s, name); b != nil { return b }
		session.frame(s)
	}
	testing.expectf(s.t, false, "%s not built in %d frames", name, FRAMES_MAX, loc = loc)
	return nil
}

// focus_next_field before a ui.number: its value field has the keyboard, and what is typed goes into it.
@(test)
the_next_field_takes_the_keyboard :: proc(t: ^testing.T) {
	r: Owners
	defer owners_end(&r)
	ui.view_register(&r.views, "sized", sized_view, ui.View_Options{title = "Size"})
	r.want = "sized"
	s := session.start(t, {user = &r, build = owners_build})
	if wait_built(s, "modal_view_sized") == nil { return }
	testing.expect_value(t, session.focused_name(s), "value")
}

// view_icon: the header shows this opening's icon, not the kind's.
@(test)
an_icon_per_opening :: proc(t: ^testing.T) {
	r: Owners
	defer owners_end(&r)
	ui.view_register(&r.views, "sized", sized_view, ui.View_Options{title = "Size", icon = "K"})
	r.want, r.icon = "sized", "M"
	s := session.start(t, {user = &r, build = owners_build})
	if wait_built(s, "modal_view_sized") == nil { return }
	session.frames(s, 2)
	icon := built(s, "view_header_icon")
	testing.expect(t, icon != nil && ui.box_text(icon) == "M", "the opening's icon")
}

// Two windows on one Views: each window's commands list only the moves of the views it owns.
@(test)
each_window_lists_its_own_views :: proc(t: ^testing.T) {
	r: Owners
	defer owners_end(&r)
	ui.view_register(&r.views, "sized", sized_view, ui.View_Options{title = "Size"})
	ui.view_register(&r.views, "other", sized_view, ui.View_Options{title = "Other"})
	a := session.start(t, {user = &r, build = owners_build})
	b := session.start(t, {user = &r, build = owners_build})
	ui.view_open(&r.views, "sized", &r, owner = a.state)
	ui.view_open(&r.views, "other", &r, owner = b.state)
	mine := proc(vs: ^ui.Views, owner: ^ui.State, id: string) -> (own, others: int) {
		_, acts := ui.views_commands(vs, owner = owner)
		for x in acts { if x.id == id { own += 1 } else { others += 1 } }
		return
	}
	own, others := mine(&r.views, a.state, "sized")
	testing.expect(t, own > 0 && others == 0, "the first window: its own view only")
	own, others = mine(&r.views, b.state, "other")
	testing.expect(t, own > 0 && others == 0, "the second window: its own view only")
	vc: ui.View_Commands
	defer ui.views_commands_destroy(&vc)
	testing.expect(t, ui.views_commands_update(&vc, &r.views, a.state), "made for the first window")
	testing.expect(t, !ui.views_commands_update(&vc, &r.views, a.state), "kept")
	testing.expect(t, ui.views_commands_update(&vc, &r.views, b.state), "another window: made again")
	for x in vc.acts { testing.expect_value(t, x.id, "other") }
}

package views_test

// What is typed right after a view opens reaches its field, in every presentation (src/md/features/views.md, section
// 3.5): the view focuses its field in its first build; letters come in the very next frame, while it may still be
// measured unseen, built a frame later (a floating window or a panel opened after views_frame), or in a window not shown
// yet (the keys reach its owner); once it shows, its field has them all, and the page none.

import "core:testing"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{900, 640}
@(private = "file") FRAMES_MAX :: 40
@(private = "file") WORD :: "abc"

@(private = "file")
Typing :: struct {
	views:   ui.Views,
	want:    bool,          // open "typer" in the content, after views_frame
	field:   ui.Line_Edit,  // the view's
	page:    ui.Line_Edit,  // the page's, focused before the view opens
	focused: bool,
	page_focused: bool,
}

@(private = "file")
typing_build :: proc(s: ^session.Session) {
	r := (^Typing)(s.user)
	if ui.views_frame(&r.views) {
		ui.next({width = ui.px(200)})
		res := ui.line_edit("###page_field", &r.page)
		if !r.page_focused { r.page_focused = true; ui.set_focus(res.box.key) }
		if r.want { r.want = false; ui.view_open(&r.views, "typer", r) }
	}
}

@(private = "file")
typer_view :: proc(v: ^ui.View, r: ^Typing) {
	ui.next({width = ui.px(200)})
	res := ui.line_edit("###typer_field", &r.field)
	// (the field takes the keyboard in the view's first build, after it is built: as a program does it)
	if !r.focused { r.focused = true; ui.set_focus(res.box.key) }
}

// Opens "typer" as `o` says, types at once in the next frame, then waits for it to show: its field has the word.
@(private = "file")
typed_reaches_the_view :: proc(t: ^testing.T, o: ui.View_Options, loc := #caller_location) {
	r: Typing
	defer {
		ui.views_destroy(&r.views)
		ui.line_edit_destroy(&r.field)
		ui.line_edit_destroy(&r.page)
	}
	ui.view_register(&r.views, "typer", typer_view, o)
	s := session.start(t, {size = WINDOW, user = &r, build = typing_build})
	ui.views_set_windows(&r.views, session.view_windows(s))
	session.frames(s, 2)
	r.want = true
	session.frame(s)              // (it opens in this frame's build)
	session.type_text(s, WORD)    // (the very next frame: the keys of the window that has the user, its owner)
	for _ in 0 ..< FRAMES_MAX {
		if ui.line_edit_string(&r.field) == WORD { break }
		session.frame(s)
	}
	testing.expectf(t, ui.line_edit_string(&r.field) == WORD, "the view's field has %q (it is %v)", ui.line_edit_string(&r.field), ui.view_presentation(&r.views, "typer"), loc = loc)
	testing.expectf(t, ui.line_edit_string(&r.page) == "", "the page's field has none: %q", ui.line_edit_string(&r.page), loc = loc)
}

@(test)
typing_reaches_a_dialog :: proc(t: ^testing.T) {
	typed_reaches_the_view(t, {title = "Typer"})
}

@(test)
typing_reaches_a_floating_window :: proc(t: ^testing.T) {
	typed_reaches_the_view(t, {title = "Typer", first = .Internal})
}

@(test)
typing_reaches_a_panel :: proc(t: ^testing.T) {
	typed_reaches_the_view(t, {title = "Typer", home = .Panel, home_place = {edge = .Left}})
}

@(test)
typing_reaches_a_window_of_its_own :: proc(t: ^testing.T) {
	typed_reaches_the_view(t, {title = "Typer", first = .External})
}

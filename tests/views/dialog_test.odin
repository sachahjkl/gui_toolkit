package views_test

// Views shown as dialogs, built at the end of each build: the answer of view_end, of Escape, of the close cross and of
// Ctrl+W, taken once; view_close gives none; nothing is drawn before its layout settles; the presentation the user chose
// survives a quit; the header adds the title, an inactive Detach icon and the close cross, and nothing else.

import "core:os"
import "core:path/filepath"
import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") WINDOW :: [2]int{900, 640}
@(private = "file") ANSWER :: 3
@(private = "file") MOVES :: 3          // the builds the moving view's body grows in
@(private = "file") GROW_PX :: 20       // what it grows by at each
@(private = "file") SETTLE_FRAMES :: 20 // more than the six layouts a dialog is measured at most
@(private = "file") AFTER :: 3          // frames made after an answer: it is not given again

@(private = "file")
Body :: struct {
	grows: int,
	least: f32,   // the least width "least" and "least_sized" ask for this opening (em)
	em:    f32,   // the font size of their last build (frame px)
}

@(private = "file")
Run :: struct {
	views:    ui.Views,
	want:     string,                       // a view to open in the next build ("": none)
	body:     Body,
	answers:  [dynamic]int,                 // what view_ended gave for "ask"
	confirms: [dynamic]ui.Confirm_Answer,   // what confirm_answer gave for "delete"
	confirm:  bool,                         // open the confirmation in the next build
}

@(private = "file")
run_build :: proc(s: ^session.Session) {
	r := (^Run)(s.user)
	if r.want != "" {
		ui.view_open(&r.views, r.want, &r.body)
		r.want = ""
	}
	if r.confirm {
		r.confirm = false
		ui.confirm_open("delete", {title = "Delete it?", act = "Delete"})   // (the State's own Views)
	}
	if code, ok := ui.view_ended(&r.views, "ask"); ok { append(&r.answers, code) }
	if a := ui.confirm_answer("delete"); a != .None { append(&r.confirms, a) }
	ui.label("The page###page")
}

@(private = "file")
ask_view :: proc(v: ^ui.View, b: ^Body) {
	if ui.dialog_body("ask_body") { ui.label("What now?###ask_words") }
	if ui.dialog_buttons("ask_buttons") {
		if ui.button("ask_three", "Three").clicked { ui.view_end(v, ANSWER) }
	}
}

// (its body grows for MOVES builds, then stays)
@(private = "file")
moving_view :: proc(v: ^ui.View, b: ^Body) {
	b.grows = min(b.grows + 1, MOVES)
	ui.next({width = ui.fill(), height = ui.px(f32(b.grows * GROW_PX))})
	ui.build_box({}, "###moving_body")
}

@(private = "file")
// (a Views of the test's own, as a program that shares one between its windows has: a zero one works)
run_start :: proc(t: ^testing.T, r: ^Run) -> ^session.Session {
	run_register(r)
	return session.start(t, {size = WINDOW, user = r, build = run_build})
}

@(private = "file")
run_register :: proc(r: ^Run) {
	ui.view_register(&r.views, "ask", ask_view, ui.View_Options{title = "Question"})
	ui.view_register(&r.views, "moving", moving_view, ui.View_Options{title = "Moving"})
}

@(private = "file")
run_end :: proc(r: ^Run) {
	ui.views_destroy(&r.views)
	delete(r.answers)
	delete(r.confirms)
}

// The dialog `name` (its panel, "modal_view_<id>") is drawn: its layout settled and it faded in.
@(private = "file")
wait_shown :: proc(s: ^session.Session, panel: string) {
	session.wait_until(s, panel, proc(s: ^session.Session, panel: string) -> bool {
		b := session.find(s, panel)
		return b != nil && b.transparency < 1
	}, "the dialog to show")
}

@(private = "file")
answers_reach :: proc(s: ^session.Session, n: int) {
	session.wait_until(s, n, proc(s: ^session.Session, n: int) -> bool { return len((^Run)(s.user).answers) >= n }, "the answer")
}

@(test)
a_dialog_view_answers_once :: proc(t: ^testing.T) {
	r: Run
	defer run_end(&r)
	r.want = "ask"
	s := run_start(t, &r)
	wait_shown(s, "modal_view_ask")
	testing.expect(t, ui.view_is_open(&r.views, "ask"))
	session.click(s, "ask_three")
	answers_reach(s, 1)
	testing.expect_value(t, r.answers[0], ANSWER)
	session.frames(s, AFTER)
	testing.expect_value(t, len(r.answers), 1)
	testing.expect(t, !ui.view_is_open(&r.views, "ask"), "view_end closes it")
	session.wait_gone(s, "modal_view_ask")

	// Escape, the close cross and Ctrl+W cancel
	r.want = "ask"
	wait_shown(s, "modal_view_ask")
	session.key(s, .Escape)
	answers_reach(s, 2)
	testing.expect_value(t, r.answers[1], ui.VIEW_CANCELLED)

	r.want = "ask"
	wait_shown(s, "modal_view_ask")
	session.click(s, "dialog_close")
	answers_reach(s, 3)
	testing.expect_value(t, r.answers[2], ui.VIEW_CANCELLED)

	r.want = "ask"
	wait_shown(s, "modal_view_ask")
	session.key(s, .W, {.Ctrl})
	answers_reach(s, 4)
	testing.expect_value(t, r.answers[3], ui.VIEW_CANCELLED)

	// the program's close gives no answer
	r.want = "ask"
	wait_shown(s, "modal_view_ask")
	ui.view_close(&r.views, "ask")
	session.wait_gone(s, "modal_view_ask")
	session.frames(s, AFTER)
	testing.expect_value(t, len(r.answers), 4)
	testing.expect(t, !ui.view_is_open(&r.views, "ask"))
}

@(test)
a_confirmation_answers_once :: proc(t: ^testing.T) {
	r: Run
	defer run_end(&r)
	r.confirm = true
	s := run_start(t, &r)
	wait_shown(s, "modal_view_delete")
	session.click(s, "confirm_act")
	session.wait_until(s, proc(s: ^session.Session) -> bool { return len((^Run)(s.user).confirms) > 0 }, "the answer")
	testing.expect_value(t, r.confirms[0], ui.Confirm_Answer.Confirmed)
	session.frames(s, AFTER)
	testing.expect_value(t, len(r.confirms), 1)

	r.confirm = true
	wait_shown(s, "modal_view_delete")
	session.click(s, "confirm_cancel")
	session.wait_until(s, proc(s: ^session.Session) -> bool { return len((^Run)(s.user).confirms) > 1 }, "the answer")
	testing.expect_value(t, r.confirms[1], ui.Confirm_Answer.Cancelled)
}

// No frame draws a view before its layout settles: the first frame drawn has the final rects (the no-flash rule).
@(test)
nothing_shows_before_the_layout_settles :: proc(t: ^testing.T) {
	r: Run
	defer run_end(&r)
	r.want = "moving"
	s := run_start(t, &r)
	unseen := 0
	shown_at: ui.Rect
	shown := false
	for _ in 0 ..< SETTLE_FRAMES {
		b := session.find(s, "modal_view_moving")
		if b != nil && b.transparency < 1 {
			shown, shown_at = true, b.rect
			testing.expect_value(t, r.body.grows, MOVES)   // (it grew all it does before it showed)
			break
		}
		if b != nil { unseen += 1 }
		session.frame(s)
	}
	testing.expect(t, shown, "it shows once settled")
	testing.expectf(t, unseen >= MOVES, "built unseen while it moved: %d frames", unseen)
	session.frames(s, AFTER)
	b := session.find(s, "modal_view_moving")
	testing.expect(t, b != nil && b.rect == shown_at, "the first frame drawn is where it stays")
}

// The presentation the user chose and whether it was open survive a quit.
@(test)
the_presentation_is_remembered :: proc(t: ^testing.T) {
	r: Run
	defer run_end(&r)
	s := run_start(t, &r)
	path, _ := filepath.join({s.out, "views.txt"}, context.temp_allocator)
	// (the session's folder stays between runs: a memory left by the last run would be read as this one's)
	_ = os.remove(path)
	ui.views_destroy(&r.views)
	ui.views_init(&r.views, {path = path})
	run_register(&r)
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Dialog)

	r.want = "ask"
	wait_shown(s, "modal_view_ask")
	ui.view_present(&r.views, "ask", .Internal)
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Internal)
	session.wait_box(s, "internal_view_ask")   // (built as an internal window now)
	testing.expect(t, ui.view_is_open(&r.views, "ask"))

	// a quit with it open, a start
	ui.views_destroy(&r.views)
	ui.views_init(&r.views, {path = path})
	run_register(&r)
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Internal)
	testing.expect(t, ui.view_was_open(&r.views, "ask"), "it was open at the quit")

	// a quit with it closed
	ui.views_destroy(&r.views)
	ui.views_init(&r.views, {path = path})
	run_register(&r)
	testing.expect(t, !ui.view_was_open(&r.views, "ask"))
}

// Each State has a Views of its own with nothing to call; two windows given one Views share it: what is registered once
// opens in either, each view built in the window that opened it.
@(test)
two_windows_share_one_views :: proc(t: ^testing.T) {
	own := session.start(t, {size = WINDOW, build = proc(s: ^session.Session) {}})
	testing.expect(t, ui.state_views(own.state) == &own.state.own_views, "a State's own Views, made on first use")

	r: Run
	defer run_end(&r)
	run_register(&r)
	build :: proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if r.want != "" { ui.view_open(ui.views(), r.want, &r.body); r.want = "" }
	}
	a := session.start(t, {size = WINDOW, user = &r, build = build})
	ui.set_views(a.state, &r.views)
	b := session.start(t, {size = WINDOW, user = &r, build = build})
	ui.set_views(b.state, &r.views)
	testing.expect(t, ui.state_views(a.state) == ui.state_views(b.state), "one Views")
	r.want = "ask"
	session.frame(b)
	wait_shown(b, "modal_view_ask")
	testing.expect(t, session.find(a, "modal_view_ask") == nil, "built in the window that opened it only")
	ui.view_close(&r.views, "ask")
}

// A dialog's header holds its title, the Detach icon and the close cross; no tools box when the program gives no tools;
// in the strip, only the Detach icon takes a click (the strip itself is dragged).
@(test)
the_header_adds_nothing_else :: proc(t: ^testing.T) {
	r: Run
	defer run_end(&r)
	r.want = "ask"
	s := run_start(t, &r)
	wait_shown(s, "modal_view_ask")
	header := session.find(s, "view_header")
	testing.expect(t, header != nil, "the header")
	if header == nil { return }
	testing.expect(t, session.find_text(s, "Question") != nil, "its title")
	detach := session.find(s, "view_detach", within = header)
	testing.expect(t, detach != nil && .Clickable in detach.flags && .Disabled not_in detach.flags, "the Detach icon, active")
	testing.expect(t, session.find(s, "view_tools") == nil, "no tools box: the program gave no tools")
	testing.expect(t, session.find(s, "dialog_close") != nil, "the close cross")
	clickable :: proc(b: ^ui.Box) -> int {
		n := .Clickable in b.flags ? 1 : 0
		for c := b.first; c != nil; c = c.next { n += clickable(c) }
		return n
	}
	testing.expect_value(t, clickable(header) - 1, 1)   // (the strip, and the Detach icon)
}

// A dialog that asks a least width for its opening (view_size's min_width_em) measures at least that: fitted to a small
// content, sized narrower by view_size, or resizable with a size of its own; and never past the window's edge.
@(private = "file") LEAST_EM :: 36
@(private = "file") ASKED_EM :: 10   // the width asked: under the least
@(test)
a_dialog_opened_with_a_least_width_measures_at_least_that :: proc(t: ^testing.T) {
	r: Run
	defer run_end(&r)
	least_view :: proc(v: ^ui.View, b: ^Body) {
		b.em = ui.font_size()
		ui.view_size(v, ASKED_EM, 0, b.least)
		if ui.dialog_body("least_body") { ui.label("A small picture###least_words") }
	}
	ui.view_register(&r.views, "least", least_view, ui.View_Options{title = "Least"})
	ui.view_register(&r.views, "least_sized", least_view, ui.View_Options{title = "Least, resizable", resizable = true, height_em = 12})
	s := run_start(t, &r)
	width :: proc(s: ^session.Session, panel: string) -> f32 {
		b := session.find(s, panel)
		return b != nil ? b.rect.max.x - b.rect.min.x : 0
	}
	for id in ([]string{"least", "least_sized"}) {
		panel := id == "least" ? "modal_view_least" : "modal_view_least_sized"
		r.body.least = LEAST_EM
		r.want = id
		wait_shown(s, panel)
		w := width(s, panel)
		testing.expectf(t, w >= LEAST_EM * r.body.em - 0.5, "%s: at least its least: %v < %v", id, w, LEAST_EM * r.body.em)
		ui.view_close(&r.views, id)
		session.wait_gone(s, panel)
		// (a least wider than the window: the window's edge holds it, its margins kept)
		r.body.least = 200
		r.want = id
		wait_shown(s, panel)
		w = width(s, panel)
		margin := ui.MODAL_MARGIN_EM * r.body.em
		testing.expectf(t, w <= f32(WINDOW.x) - 2 * margin + 0.5, "%s: held by the window: %v", id, w)
		b := session.find(s, panel)
		testing.expectf(t, b != nil && b.rect.min.x >= 0 && b.rect.max.x <= f32(WINDOW.x), "%s: inside the window: %v", id, b.rect if b != nil else ui.Rect{})
		ui.view_close(&r.views, id)
		session.wait_gone(s, panel)
	}
}

// A body that asks for tools gets them in its header, after the title.
@(test)
the_header_holds_the_program_s_tools :: proc(t: ^testing.T) {
	r: Run
	defer run_end(&r)
	ui.view_register(&r.views, "tooled", proc(v: ^ui.View, b: ^Body) {
		if ui.view_header_tools(v) { ui.button("tool", "A tool") }
		ui.label("The body###tooled_body")
	}, ui.View_Options{title = "With tools"})
	r.want = "tooled"
	s := run_start(t, &r)
	wait_shown(s, "modal_view_tooled")
	tools := session.find(s, "view_tools", within = session.find(s, "view_header"))
	testing.expect(t, tools != nil && session.find(s, "tool", within = tools) != nil, "the tool in the header's tools box")
	title := session.find(s, "view_header_title")
	if tools != nil && title != nil { testing.expect(t, tools.rect.min.x >= title.rect.max.x, "after the title") }
}

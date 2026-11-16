package views_test

// The palette's keys in a view's own window (src/md/features/palette.md, Keys): the program reads palette_keys in its
// own window's build only, and Ctrl+K in the window of a view opens the palette over that window. A choice made there
// reaches the program's palette_chosen; the keys in the other window move it there; the recorder of a key gives it back
// in the window it was asked from.

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") PW_FRAMES_MAX :: 40
@(private = "file") PW_BOUND :: 10 * time.Second

@(private = "file")
PW_COMMANDS := [?]ui.Command{
	{id = "notes", label = "Notes", group = "File"},
	{id = "open", label = "Open", group = "File", keys = {{.O, {.Ctrl}}}},
}

@(private = "file")
Pw :: struct {
	views:   ui.Views,
	pal:     ui.Command_Palette,
	keymap:  ui.Keymap,
	want:    bool,
	chosen:  string,   // the id of the last choice (owned)
	choices: int,
}

@(private = "file")
pw_build :: proc(s: ^session.Session) {
	r := (^Pw)(s.user)
	ui.palette_commands(&r.pal, PW_COMMANDS[:], nil)
	_ = ui.palette_keys(&r.pal)
	if r.want && ui.views_windows_ready(&r.views) { ui.view_open(&r.views, "side", r); r.want = false }
	if c, ok := ui.palette_chosen(&r.pal); ok {
		delete(r.chosen)
		r.chosen, r.choices = strings.clone(c.id), r.choices + 1
	}
	ui.label("The page###page")
}

@(private = "file")
pw_view :: proc(v: ^ui.View, r: ^Pw) {
	if ui.dialog_body("side_body") { ui.label("A view of its own###side_words") }
}

@(private = "file")
pw_end :: proc(r: ^Pw) {
	ui.palette_destroy(&r.pal)
	ui.views_destroy(&r.views)
	ui.keymap_destroy(&r.keymap)
	delete(r.chosen)
}

// The palette's dialog, built in the last build of `s`.
@(private = "file")
palette_in :: proc(s: ^session.Session, r: ^Pw) -> bool {
	if s == nil { return false }
	b := session.find(s, fmt.tprintf("modal_view_palette/%x", uintptr(&r.pal)))
	return b != nil && b.last_build == s.state.build_index && b.transparency < 1
}

// Frames of the program until `ready`, PW_FRAMES_MAX at most.
@(private = "file")
pw_wait :: proc(s, w: ^session.Session, r: ^Pw, ready: proc(s, w: ^session.Session, r: ^Pw) -> bool, what: string, loc := #caller_location) -> bool {
	for _ in 0 ..< PW_FRAMES_MAX {
		if ready(s, w, r) { return true }
		session.frame(s)
	}
	testing.expectf(s.t, false, "%s not in %d frames", what, PW_FRAMES_MAX, loc = loc)
	return false
}

@(private = "file")
over_view_window :: proc(s, w: ^session.Session, r: ^Pw) -> bool { return palette_in(w, r) && !palette_in(s, r) }
@(private = "file")
over_main_window :: proc(s, w: ^session.Session, r: ^Pw) -> bool { return palette_in(s, r) && !palette_in(w, r) }
@(private = "file")
nowhere :: proc(s, w: ^session.Session, r: ^Pw) -> bool { return !palette_in(s, r) && !palette_in(w, r) }

@(test)
the_palette_opens_in_a_view_s_window :: proc(t: ^testing.T) {
	r: Pw
	defer pw_end(&r)
	ui.keymap_known(&r.keymap, PW_COMMANDS[:])
	ui.view_register(&r.views, "side", pw_view, ui.View_Options{title = "Side", first = .External})
	r.want = true
	s := session.start(t, {size = {900, 640}, user = &r, build = pw_build})
	// (the program's Views is its window's: the palette opens on it, as on its views' windows)
	ui.set_views(s.state, &r.views)
	ui.keymap_use(s.state, &r.keymap)
	ui.views_set_windows(&r.views, session.view_windows(s))
	w: ^session.Session
	for _ in 0 ..< PW_FRAMES_MAX {
		w = session.view_window(s, &r.views, "side")
		if session.window_shown(w) { break }
		session.frame(s)
	}
	if !testing.expect(t, session.window_shown(w), "the view in a window of its own") { return }

	// Ctrl+K in the view's window: the palette opens over it, not over the program's window
	session.key(w, .K, {.Ctrl})
	if !pw_wait(s, w, &r, over_view_window, "the palette over the view's window") { return }
	// (the moves listed are those of the program's views: the view whose window it is, the first)
	moves_side := false
	for a in r.pal.moves.vc.acts { if a.id == "side" { moves_side = true } }
	testing.expect(t, moves_side, "the view's moves in the palette of its window")

	// a choice made there is the program's
	session.type_text(w, "notes")
	session.wait_until(s, &r, proc(s: ^session.Session, r: ^Pw) -> bool { return r.pal.pending == 0 }, "the ranking", PW_BOUND)
	session.frame(s)
	session.key(w, .Return)
	session.wait_until(s, &r, proc(s: ^session.Session, r: ^Pw) -> bool { return r.choices == 1 }, "the choice in the program's build", PW_BOUND)
	testing.expect_value(t, r.chosen, "notes")
	pw_wait(s, w, &r, nowhere, "the palette closed by the choice")

	// open in the program's window, Ctrl+K in the view's moves it there; again there, it closes
	session.key(s, .K, {.Ctrl})
	pw_wait(s, w, &r, over_main_window, "the palette over the program's window")
	session.key(w, .K, {.Ctrl})
	pw_wait(s, w, &r, over_view_window, "the palette moved to the view's window")
	session.key(w, .K, {.Ctrl})
	pw_wait(s, w, &r, nowhere, "the palette closed by its keys in its window")

	// the recorder of a key, asked from the view's window, gives the palette back there
	session.key(w, .K, {.Ctrl})
	if !pw_wait(s, w, &r, over_view_window, "the palette over the view's window again") { return }
	session.type_text(w, "open")
	session.wait_until(s, &r, proc(s: ^session.Session, r: ^Pw) -> bool { return r.pal.pending == 0 }, "the ranking", PW_BOUND)
	session.frame(s)
	session.key(w, .Return, {.Ctrl})
	recorder := fmt.tprintf("modal_view_keys/%x", uintptr(&r.pal))
	for _ in 0 ..< PW_FRAMES_MAX {
		if b := session.find(w, recorder); b != nil && b.last_build == w.state.build_index { break }
		session.frame(s)
	}
	b := session.find(w, recorder)
	testing.expect(t, b != nil && b.last_build == w.state.build_index, "the recorder over the view's window")
	session.key(w, .M, {.Ctrl})
	session.key(w, .Return)
	pw_wait(s, w, &r, over_view_window, "the palette back over the view's window")
	testing.expect_value(t, r.choices, 1)
}

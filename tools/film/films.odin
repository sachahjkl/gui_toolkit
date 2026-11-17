package film_tool

import "core:fmt"
import "core:math"
import "../../examples/showcase"
import "gt:film"
import "gt:ui"

// The films' scripts: what a person does, at a person's pace. A box is found by its name in the last build (`within`:
// under that box), a point of it by `at` (0..1 of its width and height).

// The pointer glides to the box and clicks it. False (and a word on standard error) when the box is not there: the film
// goes on without that step.
tap :: proc(t: ^Take, name: string, text := "", within: ^ui.Box = nil, at := [2]f32{0.5, 0.5}, glide := 0.55, after := 0.35) -> bool {
	b := film.box(&t.rec, name, text, within = within)
	if b == nil {
		fmt.eprintfln("film: no box %q %q to click", name, text)
		return false
	}
	film.move_to(&t.rec, film.center(b, at), glide)
	film.hold(&t.rec, 0.08)
	film.click(&t.rec)
	film.hold(&t.rec, after)
	return true
}

// The pointer glides over the box, nothing pressed.
point :: proc(t: ^Take, name: string, text := "", within: ^ui.Box = nil, at := [2]f32{0.5, 0.5}, glide := 0.55) {
	if b := film.box(&t.rec, name, text, within = within); b != nil { film.move_to(&t.rec, film.center(b, at), glide) }
}

// The sidebar's line of a scene.
scene :: proc(t: ^Take, s: showcase.Scene) { tap(t, fmt.tprintf("nav%v", s), after = 0.6) }

// The window's width goes from what it is to `width` pixels in `seconds`, a step each frame (its height kept).
narrow :: proc(t: ^Take, width: int, seconds: f64) {
	from := t.app.main.win.size
	n := max(film.frames_of(&t.rec, seconds), 1)
	for i in 1 ..= n {
		k := film.ease_in_out(f32(i) / f32(n))
		film.resize(&t.rec, {int(math.round(f32(from.x) + f32(width - from.x) * k)), from.y})
		film.frame(&t.rec)
	}
}

////////////////////////////////
// Themes

themes_film :: proc(t: ^Take) {
	t.app.scene = .Themes
	open_with(t, "Themes", "Every theme, every finish, the corners: one choice, the whole interface")
	film.pointer_show(&t.rec, true, film.center(film.box(&t.rec, "content"), {0.5, 0.6}))
	film.hold(&t.rec, 0.4)
	// a few themes, from both walls
	walls := [2]^ui.Box{film.box(&t.rec, "wall0"), film.box(&t.rec, "wall1")}
	for pick in ([][2]int{{0, 4}, {0, 7}, {1, 1}, {1, 5}, {0, 1}}) {
		tap(t, fmt.tprintf("th%d", pick[1]), within = walls[pick[0]], glide = 0.45, after = 0.55)
	}
	// the finishes
	finish := film.box(&t.rec, "finish")
	for seg in ([]int{2, 4, 0, 1, 3}) { tap(t, fmt.tprintf("seg%d", seg), within = finish, glide = 0.35, after = 0.6) }
	// the light version, then the corners: square, round, back
	tap(t, "seg1", within = film.box(&t.rec, "look_Version"), after = 0.7)
	if slider := film.box(&t.rec, "rounding"); slider != nil {
		film.move_to(&t.rec, film.center(slider, {0.5, 0.5}), 0.5)
		film.drag_to(&t.rec, film.center(slider, {0.02, 0.5}), 0.7)
		film.hold(&t.rec, 0.4)
		film.drag_to(&t.rec, film.center(slider, {0.98, 0.5}), 1.1)
		film.hold(&t.rec, 0.4)
		film.drag_to(&t.rec, film.center(slider, {0.5, 0.5}), 0.6)
	}
	// the look on two pages, then the dark again
	scene(t, .Intents)
	film.hold(&t.rec, 0.8)
	scene(t, .Controls)
	film.hold(&t.rec, 0.8)
	tap(t, "mode", after = 1.2)
	close_with(t)
}

////////////////////////////////
// The command palette

palette_film :: proc(t: ^Take) {
	t.app.scene = .Intents
	open_with(t, "Command palette", "Every command, setting and view, a few letters away")
	film.pointer_show(&t.rec, true, film.center(film.box(&t.rec, "content"), {0.55, 0.55}))
	film.hold(&t.rec, 0.4)
	// a command by a few of its letters
	film.key(&t.rec, .K, {.Ctrl}, after = 0.5)
	film.type_text(&t.rec, "theme next", 10)
	film.hold(&t.rec, 0.6)
	film.key(&t.rec, .Return, after = 0.9)
	// its keys, shown in the palette, do it too
	film.key(&t.rec, .T, {.Ctrl}, after = 0.7)
	film.key(&t.rec, .T, {.Ctrl}, after = 0.7)
	// the light version
	film.key(&t.rec, .K, {.Ctrl}, after = 0.4)
	film.type_text(&t.rec, "theme light", 10)
	film.hold(&t.rec, 0.5)
	film.key(&t.rec, .Return, after = 1.0)
	// a command with an argument: its form opens in the palette
	film.key(&t.rec, .K, {.Ctrl}, after = 0.4)
	film.type_text(&t.rec, "rename", 11)
	film.hold(&t.rec, 0.4)
	film.key(&t.rec, .Return, after = 0.5)
	film.key(&t.rec, .A, {.Ctrl}, after = 0.1)
	film.type_text(&t.rec, "Lighthouse at noon", 13)
	film.hold(&t.rec, 0.4)
	film.key(&t.rec, .Return, after = 1.2)
	close_with(t)
}

////////////////////////////////
// A window that narrows

layout_film :: proc(t: ^Take) {
	t.app.scene = .Controls
	open_with(t, "Layout", "A window that narrows: columns go under, rows wrap, nothing spills")
	full := t.app.main.win.size
	film.hold(&t.rec, 0.5)
	narrow(t, 980, 2.6)
	film.hold(&t.rec, 0.7)
	narrow(t, full.x, 1.4)
	t.app.scene = .Intents
	film.fade(&t.rec, 0.4)
	film.hold(&t.rec, 0.5)
	narrow(t, 900, 2.6)
	film.hold(&t.rec, 0.7)
	narrow(t, full.x, 1.4)
	t.app.scene = .Values
	film.fade(&t.rec, 0.4)
	film.hold(&t.rec, 0.5)
	narrow(t, 900, 2.2)
	film.hold(&t.rec, 0.9)
	narrow(t, full.x, 1.4)
	t.app.scene = .Steppers
	film.fade(&t.rec, 0.4)
	film.hold(&t.rec, 0.5)
	narrow(t, 900, 2.2)
	film.hold(&t.rec, 0.9)
	narrow(t, full.x, 1.2)
	close_with(t)
}

////////////////////////////////
// Tool bars

toolbars_film :: proc(t: ^Take) {
	t.app.scene = .Toolbar
	open_with(t, "Tool bars", "One tool bar, declared once: it wraps onto lines, or folds into its menu")
	full := t.app.main.win.size
	film.pointer_show(&t.rec, true, film.center(film.box(&t.rec, "content"), {0.5, 0.7}))
	film.hold(&t.rec, 0.5)
	// a few tools of the folding bar
	fold := film.box(&t.rec, "editor_fold")
	// (the colours and the style are in its "…" menu from the start: the tools are on the bar)
	for name in ([]string{"tool1", "tool4", "tool6", "tool7"}) { tap(t, name, within = fold, glide = 0.4, after = 0.35) }
	// narrower: the wrapping bar takes lines, the folding one puts more in its menu
	narrow(t, 1000, 2.4)
	film.hold(&t.rec, 0.5)
	if tap(t, "toolbar_more", within = film.box(&t.rec, "editor_fold"), after = 1.4) {
		film.key(&t.rec, .Escape, after = 0.4)
	}
	narrow(t, full.x, 1.6)
	film.hold(&t.rec, 0.6)
	close_with(t)
}

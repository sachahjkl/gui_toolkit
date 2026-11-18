package film_tool

import "../../examples/showcase"
import "gt:film"

// Old Head: the showcase in a theme of 1995 (grey faces, two-tone bevels, square corners, a navy selection), its densest
// scenes one after another: the controls, a tool bar, docked views, the file browser, a menu, the palette, the settings.
oldhead_film :: proc(t: ^Take) {
	t.app.scene = .Controls
	open_with(t, "Old Head", "Every control of the toolkit, as it looked in 1995")
	film.pointer_show(&t.rec, true, film.center(film.box(&t.rec, "content"), {0.5, 0.6}))
	film.hold(&t.rec, 0.6)
	// the controls: buttons, fields, checks, sliders, a pressed key goes in
	point(t, "", "Save", glide = 0.6)
	film.hold(&t.rec, 0.4)
	film.click(&t.rec)
	film.hold(&t.rec, 0.8)
	film.wheel(&t.rec, {0, 4}, 1.0)
	film.hold(&t.rec, 0.6)
	film.wheel(&t.rec, {0, -4}, 0.6)
	// the dense scenes, one after another from the sidebar
	for s in ([]showcase.Scene{.Toolbar, .Views, .Graph, .Steppers, .Values}) {
		scene(t, s)
		film.hold(&t.rec, 1.4)
	}
	// the file browser, over the page
	tap_text(t, "Open a file", after = 2.0)
	film.key(&t.rec, .Escape, after = 0.5)
	// a menu under the pointer, a submenu
	scene(t, .Menus)
	film.key(&t.rec, .Escape, after = 0.2)
	point(t, "file1", at = {0.35, 0.5})
	film.click(&t.rec, .Right)
	film.hold(&t.rec, 0.6)
	point(t, "", "Open with")
	film.hold(&t.rec, 1.0)
	film.key(&t.rec, .Escape, after = 0.3)
	film.key(&t.rec, .Escape, after = 0.3)
	// the palette: every command, found by a few letters
	film.key(&t.rec, .K, {.Ctrl}, after = 0.5)
	film.type_text(&t.rec, "theme", 8)
	film.hold(&t.rec, 1.2)
	film.key(&t.rec, .Escape, after = 0.4)
	// the settings page
	film.key(&t.rec, .Comma, {.Ctrl}, after = 1.4)
	film.wheel(&t.rec, {0, 5}, 1.2)
	film.hold(&t.rec, 1.0)
	close_with(t)
}

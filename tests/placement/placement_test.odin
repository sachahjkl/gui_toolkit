// A window's placement: the rectangle fitted to a work area (pure), and a window put where a placement says, read back, moved, and
// shown maximized (needs a desktop session; the window is never shown except the last test, which does not activate it).
//   odin test tests/placement -vet
package placement_test

import "core:testing"
import win "core:sys/windows"
import "../../platform"

@(test)
a_rectangle_that_fits_stays :: proc(t: ^testing.T) {
	testing.expect_value(t, platform.fit_rect_to_work({100, 50, 800, 600}, {0, 0, 1920, 1040}), [4]int{100, 50, 800, 600})
}

@(test)
a_rectangle_is_moved_into_the_work_area :: proc(t: ^testing.T) {
	work := [4]int{0, 0, 1920, 1040}
	testing.expect_value(t, platform.fit_rect_to_work({1800, 900, 800, 600}, work), [4]int{1120, 440, 800, 600})   // past the right and bottom edges
	testing.expect_value(t, platform.fit_rect_to_work({-300, -40, 800, 600}, work), [4]int{0, 0, 800, 600})
	// a monitor to the left of the main one has negative coordinates
	left := [4]int{-1920, 0, 1920, 1080}
	testing.expect_value(t, platform.fit_rect_to_work({-100, 100, 400, 300}, left), [4]int{-400, 100, 400, 300})
}

@(test)
a_rectangle_is_cut_to_the_work_area :: proc(t: ^testing.T) {
	testing.expect_value(t, platform.fit_rect_to_work({50, 50, 3000, 2000}, {0, 40, 1920, 1000}), [4]int{0, 40, 1920, 1000})
}

@(test)
a_window_goes_where_a_placement_says :: proc(t: ^testing.T) {
	w := platform.open_window("placement test", {300, 200})
	defer platform.destroy_window(w)
	platform.set_placement(w, {rect = {120, 90, 640, 480}})
	r := platform.outer_rect(w)
	testing.expect_value(t, r[2], 640)
	testing.expect_value(t, r[3], 480)
	testing.expect_value(t, r[0], 120)
	testing.expect_value(t, r[1], 90)
	p := platform.get_placement(w)
	testing.expect_value(t, p.rect, [4]int{120, 90, 640, 480})
	testing.expect(t, !p.maximized)
	platform.move_window(w, 200, 150)
	r = platform.outer_rect(w)
	testing.expect_value(t, r[0], 200)
	testing.expect_value(t, r[1], 150)
	testing.expect_value(t, r[2], 640)   // (no resize)
	o := platform.client_origin(w)
	testing.expect(t, o[0] >= r[0] && o[0] < r[0] + r[2] && o[1] >= r[1] && o[1] < r[1] + r[3], "the client area starts inside the window")
}

@(test)
a_window_is_shown_maximized_when_asked :: proc(t: ^testing.T) {
	w := platform.open_window("placement test 2", {300, 200})
	defer platform.destroy_window(w)
	platform.set_placement(w, {rect = {100, 100, 500, 400}, maximized = true})
	testing.expect(t, !platform.is_maximized(w), "set_placement shows nothing")
	win.ShowWindow(w.hwnd, win.SW_SHOWNOACTIVATE)   // (what show_window does, without taking the foreground)
	win.ShowWindow(w.hwnd, win.SW_SHOWMAXIMIZED)
	testing.expect(t, platform.get_placement(w).maximized)
	r := platform.get_placement(w).rect   // (where it is restored to: its corner stays; the system may widen a window past its smallest size)
	testing.expect(t, r[0] == 100 && r[1] == 100 && r[2] >= 500 && r[3] >= 400)
	win.ShowWindow(w.hwnd, win.SW_HIDE)
}

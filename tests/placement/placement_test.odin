// A window's placement: the rectangle fitted to a work area (pure), and a window put where a placement says, read back, moved, and
// shown maximized (needs a desktop session; the window is never shown except the last test, which does not activate it).
//   odin test tests/placement -vet
package placement_test

import "core:os"
import "core:testing"
import win "core:sys/windows"
import "../../src/platform"

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

// WINDOWPLACEMENT's rectangle is in workspace coordinates: with a taskbar along the left or top edge they are not those of
// the screen, and a position saved from it moved by the taskbar at each restore.
@(test)
workspace_coordinates_become_screen_coordinates :: proc(t: ^testing.T) {
	r := [4]int{52, 90, 640, 480}
	testing.expect_value(t, platform.placement_workspace_to_screen(r, {0, 0}, {0, 0}), r)                       // taskbar at the bottom
	testing.expect_value(t, platform.placement_workspace_to_screen(r, {0, 0}, {48, 0}), [4]int{100, 90, 640, 480})   // on the left
	testing.expect_value(t, platform.placement_workspace_to_screen(r, {0, 0}, {0, 40}), [4]int{52, 130, 640, 480})   // on top
	testing.expect_value(t, platform.placement_workspace_to_screen(r, {-1920, 0}, {-1872, 0}), [4]int{100, 90, 640, 480})   // a monitor on the left
}

// The saved rectangle is where the window is on the screen, wherever this machine's taskbar is, so saving and restoring
// does not move it.
@(test)
a_placement_read_back_does_not_move_the_window :: proc(t: ^testing.T) {
	w := platform.open_window("placement test 3", {300, 200})
	defer platform.destroy_window(w)
	platform.set_placement(w, {rect = {150, 120, 640, 480}})
	before := platform.outer_rect(w)
	p := platform.get_placement(w)
	testing.expect_value(t, p.rect, before)
	platform.set_placement(w, p)
	testing.expect_value(t, platform.outer_rect(w), before)
}

// A real offset between the workspace and the screen, as a taskbar on the left and on top makes: the work area of the
// primary monitor is moved for the time of the test, as a program may (SPI_SETWORKAREA, with no notice sent) and put back.
// The windows of the desktop feel it (maximized ones are resized), so only where nobody works: on CI, or asked with
// GUI_TEST_WORKAREA.
@(test)
a_side_taskbar_does_not_move_a_saved_window :: proc(t: ^testing.T) {
	if os.get_env("CI", context.temp_allocator) == "" && os.get_env("GUI_TEST_WORKAREA", context.temp_allocator) == "" { return }
	SPI_SETWORKAREA :: 0x002F
	SPI_GETWORKAREA :: 0x0030
	// (the window first: it makes the process dpi aware, and the rectangle read must be the one written back)
	w := platform.open_window("placement workarea", {300, 200})
	defer platform.destroy_window(w)
	before: win.RECT
	testing.expect(t, bool(win.SystemParametersInfoW(SPI_GETWORKAREA, 0, &before, 0)))
	moved := before
	moved.left += 96
	moved.top += 40
	if !win.SystemParametersInfoW(SPI_SETWORKAREA, 0, &moved, 0) { return }   // (a session that refuses it: nothing to prove here)
	defer win.SystemParametersInfoW(SPI_SETWORKAREA, 0, &before, 0)

	want := [4]int{int(moved.left) + 200, int(moved.top) + 150, 640, 480}
	platform.set_placement(w, {rect = want})
	testing.expect_value(t, platform.outer_rect(w), want)

	// what the system stores is relative to the work area: this is what made a saved window move
	wp := win.WINDOWPLACEMENT{length = size_of(win.WINDOWPLACEMENT)}
	win.GetWindowPlacement(w.hwnd, &wp)
	testing.expect_value(t, int(wp.rcNormalPosition.left), want[0] - 96)
	testing.expect_value(t, int(wp.rcNormalPosition.top), want[1] - 40)

	// saved and restored three times: it stays
	for _ in 0 ..< 3 {
		p := platform.get_placement(w)
		testing.expect_value(t, p.rect, want)
		platform.set_placement(w, p)
		testing.expect_value(t, platform.outer_rect(w), want)
	}
}

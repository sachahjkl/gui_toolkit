// A window's placement as a preference's text (platform.placement_text, placement_parse): pure, on every system.
//   odin test tests/placement_text -vet
package placement_text_test

import "core:testing"
import "../../src/platform"

// A placement as a preference's text and back; what is not one opens the window where the system puts it.
@(test)
a_placement_is_written_and_read :: proc(t: ^testing.T) {
	for p in ([]platform.Placement{{{120, 80, 1400, 900}, false}, {{-1800, -20, 1600, 1000}, true}}) {
		back, ok := platform.placement_parse(platform.placement_text(p))
		testing.expect(t, ok)
		testing.expect_value(t, back, p)
	}
	testing.expect_value(t, platform.placement_text({{-1800, -20, 1600, 1000}, true}), "-1800 -20 1600 1000 maximized")
	for bad in ([]string{"", "1 2 3", "1 2 3 4 5", "a 2 3 4", "1 2 0 4", "1 2 3 -4", "1 2 3 4 minimized"}) {
		_, ok := platform.placement_parse(bad)
		testing.expectf(t, !ok, "%q is no placement", bad)
	}
}

// The same place on another monitor: in the middle stays in the middle, in a corner in that corner; too large, fitted.
@(test)
a_rectangle_goes_to_the_same_place_of_another_work_area :: proc(t: ^testing.T) {
	left := [4]int{0, 0, 1920, 1040}
	right := [4]int{1920, -200, 2560, 1400}
	testing.expect_value(t, platform.rect_on_work({560, 240, 800, 560}, left, right), [4]int{1920 + 880, -200 + 420, 800, 560})
	testing.expect_value(t, platform.rect_on_work({0, 0, 800, 560}, left, right), [4]int{1920, -200, 800, 560})
	testing.expect_value(t, platform.rect_on_work({1120, 480, 800, 560}, left, right), [4]int{1920 + 1760, -200 + 840, 800, 560})
	testing.expect_value(t, platform.rect_on_work({0, 0, 1920, 1040}, right, left), left)
	testing.expect_value(t, platform.rect_on_work({1920, -200, 2560, 1400}, right, left), left)   // (larger than its new monitor)
}

@(test)
a_monitor_followed_by_its_name :: proc(t: ^testing.T) {
	a, ok := platform.active_monitor_parse("focus")
	testing.expect(t, ok && a == .Focus)
	a, ok = platform.active_monitor_parse("pointer")
	testing.expect(t, ok && a == .Pointer)
	_, ok = platform.active_monitor_parse("mouse")
	testing.expect(t, !ok)
}

// The portal's color-scheme: dark, light, or no preference, which says nothing (the desktop's other settings decide).
@(test)
a_color_scheme_of_no_preference_says_nothing :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		dark, ok := platform.color_scheme_of(1)
		testing.expect(t, ok && dark)
		dark, ok = platform.color_scheme_of(2)
		testing.expect(t, ok && !dark)
		_, ok = platform.color_scheme_of(0)
		testing.expect(t, !ok, "no preference: the GTK theme decides")
	}
}

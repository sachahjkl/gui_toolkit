// Overlay windows (platform/overlay.odin): the output an area names, the monitors' logical places, the input region in
// physical pixels. Pure: no window opens.
//   odin test tests/overlay -vet
package overlay_test

import "core:testing"
import "../../src/platform"

// Two outputs side by side, the second one at 1.5: as gt:capture gives them.
@(private = "file")
OUTPUTS := [2][4]int{{0, 0, 1920, 1080}, {1920, 0, 1707, 960}}

@(test)
an_area_names_its_output :: proc(t: ^testing.T) {
	testing.expect_value(t, platform.overlay_output_index(OUTPUTS[:], {1920, 0, 1707, 960}), 1)
	testing.expect_value(t, platform.overlay_output_index(OUTPUTS[:], {0, 0, 1920, 1080}), 0)
}

// A region of an output (not the output itself) names the output that holds its centre.
@(test)
a_region_names_the_output_under_its_centre :: proc(t: ^testing.T) {
	testing.expect_value(t, platform.overlay_output_index(OUTPUTS[:], {2000, 100, 300, 200}), 1)
	testing.expect_value(t, platform.overlay_output_index(OUTPUTS[:], {1850, 100, 200, 100}), 1)
	testing.expect_value(t, platform.overlay_output_index(OUTPUTS[:], {1800, 100, 200, 100}), 0)
}

// A centre in a gap between outputs: the one that overlaps it most.
@(test)
a_centre_off_every_output_takes_the_largest_overlap :: proc(t: ^testing.T) {
	outputs := [][4]int{{0, 0, 100, 100}, {200, 0, 100, 100}}
	testing.expect_value(t, platform.overlay_output_index(outputs, {50, 0, 140, 50}), 0)
	testing.expect_value(t, platform.overlay_output_index(outputs, {120, 0, 140, 50}), 1)
	testing.expect_value(t, platform.overlay_output_index(outputs, {500, 500, 10, 10}), -1)
}

@(test)
no_area_is_the_systems_choice :: proc(t: ^testing.T) {
	testing.expect_value(t, platform.overlay_output_index(OUTPUTS[:], {}), -1)
	testing.expect_value(t, platform.overlay_output_index(nil, {0, 0, 10, 10}), -1)
}

// gt:capture's rule: origins by the smallest scale, sizes by their own.
@(test)
monitors_have_gt_captures_logical_places :: proc(t: ^testing.T) {
	physical := [][4]int{{0, 0, 1920, 1080}, {1920, 0, 2560, 1440}}
	places := platform.desktop_logical_places(physical, {1, 1.5})
	testing.expect_value(t, places[0], [4]int{0, 0, 1920, 1080})
	testing.expect_value(t, places[1], [4]int{1920, 0, 1706, 960})
	same := platform.desktop_logical_places(physical, {2, 2})
	testing.expect_value(t, same[1], [4]int{960, 0, 1280, 720})
	left := platform.desktop_logical_places({{-1921, 0, 1920, 1080}}, {1})
	testing.expect_value(t, left[0][0], -1921)
	half := platform.desktop_logical_places({{-3, 0, 4, 4}}, {2})
	testing.expect_value(t, half[0][0], -2)
}

// Each edge rounded outwards at a fractional scale; empty rects dropped.
@(test)
an_input_region_in_physical_pixels :: proc(t: ^testing.T) {
	px := platform.overlay_input_rects_px({{10, 10, 101, 31}, {5, 5, 0, 10}}, 1.5)
	testing.expect_value(t, len(px), 1)
	if len(px) == 1 { testing.expect_value(t, px[0], [4]int{15, 15, 152, 47}) }
	one := platform.overlay_input_rects_px({{1, 2, 3, 4}}, 1)
	testing.expect_value(t, one[0], [4]int{1, 2, 3, 4})
}

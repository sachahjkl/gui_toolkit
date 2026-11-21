package platform

import "core:testing"

// Windows' 0..1024 and Wayland's 0..65535 both end on 0..1; a value past the scale is the scale.
@(test)
a_raw_pressure_is_scaled_to_one :: proc(t: ^testing.T) {
	testing.expect_value(t, pressure_of(512, 1024), 0.5)
	testing.expect_value(t, pressure_of(1024, 1024), 1)
	testing.expect_value(t, pressure_of(TABLET_PRESSURE_FULL, TABLET_PRESSURE_FULL), 1)
	testing.expect_value(t, pressure_of(0, TABLET_PRESSURE_FULL), 0)
	testing.expect_value(t, pressure_of(2000, 1024), 1)
	testing.expect_value(t, pressure_of(5, 0), 0)
}

// A pen's info: its pressure only while its tip is down; a pen that measures none says 0.5 in contact and is not
// `measured`; the eraser end and a puck are told apart.
@(test)
a_tool_s_info_follows_its_contact :: proc(t: ^testing.T) {
	tool := Tablet_Tool{id = 2, tool_type = 0x140, measures = true, pressure = TABLET_PRESSURE_FULL / 4}
	testing.expect_value(t, tablet_tool_info(tool).pressure, 0)   // (above the tablet)
	tool.contact = true
	info := tablet_tool_info(tool)
	testing.expect(t, abs(info.pressure - 0.25) < 0.001, "a quarter of the scale")
	testing.expect(t, info.measured && info.kind == .Pen && !info.eraser && info.id == 2, "a pen that measures")
	tool.measures = false
	info = tablet_tool_info(tool)
	testing.expect(t, info.pressure == 0.5 && !info.measured, "the Pointer Events value of a pen without pressure")
	tool.tool_type = TABLET_TOOL_ERASER
	testing.expect(t, tablet_tool_info(tool).eraser, "the eraser end")
	tool.tool_type = TABLET_TOOL_MOUSE
	testing.expect_value(t, tablet_tool_info(tool).kind, Pointer_Kind.Mouse)
}

// The frames of a stroke: in, down, moves, up, out; a down and an up in one frame (a tap); out with the tip down (no up
// came: the press is cancelled); a down while not near (on another client's surface) does nothing.
@(test)
a_tool_s_frames_make_the_steps_in_order :: proc(t: ^testing.T) {
	expect_steps :: proc(t: ^testing.T, tool: ^Tablet_Tool, want: []Tablet_Step, loc := #caller_location) {
		steps, n := tablet_tool_frame(tool)
		testing.expect_value(t, n, len(want), loc = loc)
		for s, i in want { if i < n { testing.expect_value(t, steps[i], s, loc = loc) } }
	}
	tool: Tablet_Tool
	tool.came, tool.moved = true, true
	expect_steps(t, &tool, {.Move})
	tool.moved, tool.went_down = true, true
	expect_steps(t, &tool, {.Move, .Down})
	testing.expect(t, tool.contact, "the tip is down")
	tool.moved = true
	expect_steps(t, &tool, {.Move})
	tool.went_up = true
	expect_steps(t, &tool, {.Up})
	tool.went_out = true
	expect_steps(t, &tool, {.Leave})
	testing.expect(t, !tool.near && !tool.contact, "gone")

	tool.went_down = true
	expect_steps(t, &tool, {})   // (not near one of our surfaces)

	tool.came, tool.went_down, tool.went_up = true, true, true
	expect_steps(t, &tool, {.Move, .Down, .Up})
	tool.went_down = true
	expect_steps(t, &tool, {.Down})
	tool.went_out = true
	expect_steps(t, &tool, {.Cancel, .Leave})
}

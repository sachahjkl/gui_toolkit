// The pure parts of the capture backends that start from physical pixels (Windows): the logical layout of the outputs,
// a window's rect in logical pixels, an output drawn into the desktop, and the Windows backend's decisions (which
// windows are listed, how a rotated output is read). No desktop needed: they run on every system.
//   odin test tests/capture -vet
package capture_test

import "core:testing"
import "../../src/capture"

@(private = "file")
overlap :: proc(a, b: capture.Rect) -> bool {
	return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

// One scale for every output: the layout is the physical one divided by it, with no gap.
@(test)
one_scale_divides_exactly :: proc(t: ^testing.T) {
	physical := []capture.Rect{{0, 0, 3840, 2160}, {3840, 0, 3840, 2160}, {-2880, 600, 2880, 1620}}
	scales := []f32{1.5, 1.5, 1.5}
	logical := make([]capture.Rect, 3, context.temp_allocator)
	capture.layout_logical(physical, scales, logical)
	testing.expect_value(t, logical[0], capture.Rect{0, 0, 2560, 1440})
	testing.expect_value(t, logical[1], capture.Rect{2560, 0, 2560, 1440})
	testing.expect_value(t, logical[2], capture.Rect{-1920, 400, 1920, 1080})
}

// Mixed scales: outputs never overlap, whichever side the larger scale is on, and each keeps its own logical size.
@(test)
mixed_scales_never_overlap :: proc(t: ^testing.T) {
	cases := [][2]capture.Rect{
		{{0, 0, 1920, 1080}, {1920, 0, 3840, 2160}},     // 1 then 2
		{{0, 0, 3840, 2160}, {3840, 0, 1920, 1080}},     // 2 then 1
		{{0, 0, 2560, 1440}, {-3840, -500, 3840, 2160}}, // 1, and 2 to the left and above
	}
	scale_sets := [][2]f32{{1, 2}, {2, 1}, {1, 2}}
	for c, i in cases {
		physical := []capture.Rect{c[0], c[1]}
		scales := []f32{scale_sets[i][0], scale_sets[i][1]}
		logical := make([]capture.Rect, 2, context.temp_allocator)
		capture.layout_logical(physical, scales, logical)
		testing.expectf(t, !overlap(logical[0], logical[1]), "case %d: %v and %v overlap", i, logical[0], logical[1])
		for r, j in logical {
			testing.expect_value(t, r.w, i32(f32(physical[j].w) / scales[j]))
			testing.expect_value(t, r.h, i32(f32(physical[j].h) / scales[j]))
		}
	}
	// 1 then 2: the second starts where the first ends, no gap.
	logical := make([]capture.Rect, 2, context.temp_allocator)
	capture.layout_logical([]capture.Rect{{0, 0, 1920, 1080}, {1920, 0, 3840, 2160}}, []f32{1, 2}, logical)
	testing.expect_value(t, logical[1], capture.Rect{1920, 0, 1920, 1080})
}

// A window's physical rect goes to logical through its output, and crop of that output's frame at that rect gives back
// the window's physical pixels: the frame and the windows agree.
@(test)
a_window_rect_and_a_frame_agree :: proc(t: ^testing.T) {
	output_physical := capture.Rect{1920, 0, 3840, 2160}
	output_logical := capture.Rect{1920, 0, 1920, 1080}
	window := capture.Rect{2120, 200, 1000, 600}
	r := capture.physical_to_logical(window, output_physical, output_logical, 2)
	testing.expect_value(t, r, capture.Rect{2020, 100, 500, 300})

	// A frame of the output: each pixel holds its physical x (low byte) and y (second byte).
	f := capture.Frame{width = 3840, height = 2160, stride = 3840 * 4, scale = 2, origin = {1920, 0}}
	f.pixels = make([]u8, int(f.stride * f.height), context.temp_allocator)
	px, py := i32(2120 - 1920), i32(200)
	f.pixels[int(py * f.stride + px * 4) + 0] = 0xAB
	cut, ok := capture.crop(f, r, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, cut.width, i32(1000))
	testing.expect_value(t, cut.height, i32(600))
	testing.expect_value(t, cut.pixels[0], u8(0xAB))
}

@(test)
the_output_of_a_rect :: proc(t: ^testing.T) {
	outputs := []capture.Rect{{0, 0, 1920, 1080}, {1920, 0, 2560, 1440}}
	testing.expect_value(t, capture.output_of({1800, 100, 400, 300}, outputs), 1)   // more of it on the second
	testing.expect_value(t, capture.output_of({1700, 100, 400, 300}, outputs), 0)
	testing.expect_value(t, capture.output_of({5000, 100, 10, 10}, outputs), 1)     // off every output: the nearest
	testing.expect_value(t, capture.output_of({-500, 100, 10, 10}, outputs), 0)
	testing.expect_value(t, capture.output_of({0, 0, 10, 10}, nil), -1)
}

@(test)
the_bounding_rect :: proc(t: ^testing.T) {
	testing.expect_value(t, capture.bounding_rect({{0, 0, 1920, 1080}, {-1280, 200, 1280, 1024}}), capture.Rect{-1280, 0, 3200, 1224})
	testing.expect_value(t, capture.bounding_rect(nil), capture.Rect{})
}

@(private = "file")
frame_make :: proc(w, h: i32) -> capture.Frame {
	f := capture.Frame{width = w, height = h, stride = w * 4, scale = 1}
	f.pixels = make([]u8, int(w * h * 4), context.temp_allocator)
	return f
}

// The same size: a copy, clipped to the destination. A larger size: every destination pixel filled.
@(test)
an_output_is_drawn_into_the_desktop :: proc(t: ^testing.T) {
	dst := frame_make(4, 2)
	src := frame_make(2, 2)
	for i in 0 ..< len(src.pixels) { src.pixels[i] = u8(i + 1) }
	capture.frame_draw(&dst, src, {3, 0, 2, 2})   // half of it off the right edge
	testing.expect_value(t, dst.pixels[3 * 4], u8(1))
	testing.expect_value(t, dst.pixels[4 * 4 + 3 * 4], u8(9))
	testing.expect_value(t, dst.pixels[0], u8(0))

	big := frame_make(4, 4)
	one := frame_make(1, 1)
	one.pixels = {10, 20, 30, 255}
	capture.frame_draw(&big, one, {0, 0, 4, 4})
	for i := 0; i < len(big.pixels); i += 4 {
		testing.expect_value(t, big.pixels[i], u8(10))
		testing.expect_value(t, big.pixels[i + 3], u8(255))
	}
}

@(test)
the_windows_a_screenshot_tool_lists :: proc(t: ^testing.T) {
	frame := capture.Rect{100, 100, 800, 600}
	Case :: struct { facts: capture.Win32_Window_Facts, listed: bool, why: string }
	cases := []Case{
		{{visible = true, title = "Notepad", class_name = "Notepad", frame = frame}, true, "a titled window"},
		{{visible = false, title = "Notepad", frame = frame}, false, "hidden"},
		{{visible = true, cloaked = true, title = "Settings", frame = frame}, false, "cloaked"},
		{{visible = true, title = "Program Manager", class_name = "Progman", frame = frame}, false, "the wallpaper"},
		{{visible = true, class_name = "Shell_TrayWnd", frame = frame}, false, "the taskbar"},
		{{visible = true, class_name = "WorkerW", frame = frame}, false, "the wallpaper's worker"},
		{{visible = true, title = "tip", ex_style = capture.WIN32_WS_EX_TOOLWINDOW, frame = frame}, false, "a tool window"},
		{{visible = true, title = "Palette", ex_style = capture.WIN32_WS_EX_TOOLWINDOW | capture.WIN32_WS_EX_APPWINDOW, frame = frame}, true, "a tool window that says it is an app window"},
		{{visible = true, title = "toast", ex_style = capture.WIN32_WS_EX_NOACTIVATE, frame = frame}, false, "a no-activate popup"},
		{{visible = true, frame = frame}, false, "untitled, not an app window"},
		{{visible = true, ex_style = capture.WIN32_WS_EX_APPWINDOW, frame = frame}, true, "untitled owner-less app window"},
		{{visible = true, ex_style = capture.WIN32_WS_EX_APPWINDOW, has_owner = true, frame = frame}, false, "untitled owned window"},
		{{visible = true, title = "Save as", has_owner = true, frame = frame}, true, "a titled dialog"},
		{{visible = true, title = "helper"}, false, "no area"},
		{{visible = true, title = "Mail", minimized = true}, true, "minimized: no area, still listed"},
	}
	for c in cases {
		testing.expectf(t, capture.win32_window_listed(c.facts) == c.listed, "%s: expected listed = %v", c.why, c.listed)
	}
}

// Every rotation maps the upright picture onto the whole surface, one pixel to one pixel, and a quarter turn sends the
// top-left corner to the surface's top-right one.
@(test)
a_rotated_output_is_read_upright :: proc(t: ^testing.T) {
	w, h := i32(3), i32(2)
	for rotation in capture.Win32_Rotation {
		sw, sh := w, h
		if rotation == .Rotate90 || rotation == .Rotate270 { sw, sh = h, w }
		seen := make([]bool, int(sw * sh), context.temp_allocator)
		for y in 0 ..< h {
			for x in 0 ..< w {
				sx, sy := capture.win32_rotated_source(rotation, x, y, w, h)
				testing.expectf(t, sx >= 0 && sx < sw && sy >= 0 && sy < sh, "%v: (%d, %d) -> (%d, %d)", rotation, x, y, sx, sy)
				if sx >= 0 && sx < sw && sy >= 0 && sy < sh {
					testing.expectf(t, !seen[sy * sw + sx], "%v: (%d, %d) read twice", rotation, sx, sy)
					seen[sy * sw + sx] = true
				}
			}
		}
	}
	sx, sy := capture.win32_rotated_source(.Rotate90, 0, 0, w, h)
	testing.expect_value(t, [2]i32{sx, sy}, [2]i32{h - 1, 0})
	sx, sy = capture.win32_rotated_source(.Identity, 2, 1, w, h)
	testing.expect_value(t, [2]i32{sx, sy}, [2]i32{2, 1})
}

@(test)
an_executable_name :: proc(t: ^testing.T) {
	testing.expect_value(t, capture.win32_executable_name("C:\\Windows\\System32\\notepad.exe"), "notepad.exe")
	testing.expect_value(t, capture.win32_executable_name("notepad.exe"), "notepad.exe")
	testing.expect_value(t, capture.win32_executable_name(""), "")
}

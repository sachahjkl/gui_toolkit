package prefs_page_test

// The Diagnostics page reads plain data: a program with a loop of its own fills a frame ring and gives its renderer,
// with no host.Host, and the page says the same lines a host's window would.

import "core:strings"
import "core:testing"
import host "gt:host"
import prefs_page "gt:prefs_page"
import "gt:render"

@(test)
the_diagnostics_need_no_host :: proc(t: ^testing.T) {
	r: render.Renderer   // (never made: the adapter is unknown, which the page says as "?")
	ring: host.Frame_Ring
	for i in 0 ..< 3 { host.frame_add(&ring, {build_ms = f32(i + 1), draw_ms = 1}) }
	rows, _ := prefs_page.diagnostics_rows({renderer = &r, frames = &ring}, "Wren 1.0.0", "")
	text := prefs_page.diagnostics_text(rows)
	testing.expectf(t, strings.contains(text, "Program: Wren 1.0.0\n"), "the program's line: %q", text)
	testing.expectf(t, strings.contains(text, "Frames: the last 3: median"), "the program's own frames: %q", text)
	testing.expectf(t, !strings.contains(text, "Window:"), "no window given, no window line: %q", text)
	testing.expectf(t, strings.contains(text, "Partial redraw: off\n"), "%q", text)

	// (no ring: nothing drawn yet; a host with no window shared says no page at all)
	rows, _ = prefs_page.diagnostics_rows({renderer = &r}, "", "")
	testing.expect(t, strings.contains(prefs_page.diagnostics_text(rows), "Frames: none drawn yet\n"))
	testing.expect(t, prefs_page.diagnostics_of(nil).renderer == nil, "no host, no source")
	h: host.Host
	testing.expect(t, prefs_page.diagnostics_of(&h).renderer == nil, "a host not opened, no source")
}

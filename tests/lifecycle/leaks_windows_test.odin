package lifecycle_test

// What a test session makes and ends, again and again, leaves nothing behind: the process's private memory and its handles
// stay where they were. (A package of a hundred and more sessions, each a WARP device with its atlas, came to its end in a
// crash when one of them kept a few megabytes: the test where it fell was the one after the last that fit.)

import "core:fmt"
import "core:testing"
import win "core:sys/windows"
import "../../src/draw"
import "../../src/font"
import "../../src/platform"
import "../../src/render"
import "../../src/ui"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	GetProcessHandleCount :: proc(process: win.HANDLE, count: ^win.DWORD) -> win.BOOL ---
}

@(private = "file") LEAK_WARM :: 3     // rounds before the count starts (what a first use keeps for good: caches, the WARP library)
@(private = "file") LEAK_ROUNDS :: 30
@(private = "file") LEAK_BYTES_PER_ROUND :: 64 * 1024   // the heap's own slack, not a renderer's atlas (megabytes)
@(private = "file") LEAK_HANDLES :: 2   // over all the rounds

// The pieces of a test session (testkit/session: start, a frame of text and shapes, the end), in its order.
@(private = "file")
session_pieces :: proc() -> bool {
	w := platform.open_window_offscreen("leaks", {720, 560})
	if w == nil { return false }
	fonts: font.State
	font.init(&fonts)
	face, _ := font.load_embedded(&fonts, font.FALLBACK_UI_DATA)
	_, _ = font.load_embedded(&fonts, font.FALLBACK_MONO_DATA)
	_, _ = font.load_embedded(&fonts, ui.ICON_FONT_DATA)
	r: render.Renderer
	if !render.init_offscreen(&r, w.size, warp = true) { font.destroy(&fonts); platform.destroy_window(w); return false }
	dc: draw.Context
	draw.init(&dc, &r, &fonts)
	theme: ui.Theme
	ui.apply_palette(&theme, ui.palette_of("Console"))
	state: ui.State
	ui.init(&state, &fonts, &theme)
	draw.begin_frame(&dc, {720, 560})
	render.frame_begin(&r, {0.04, 0.05, 0.08, 1})
	draw.rect(&dc, {{20, 20}, {300, 80}}, {0.2, 0.3, 0.5, 1}, 6)
	draw.box_shadow(&dc, {{20, 120}, {300, 180}}, {6, 6, 6, 6}, 8, {0, 0, 0, 0.6})
	draw.text(&dc, face, 16, {24, 60}, {1, 1, 1, 1}, "The quick brown fox jumps over the lazy dog 0123")
	draw.end_frame(&dc)
	render.frame_end(&r)
	_ = render.read_pixels(&r, context.temp_allocator)
	ui.destroy(&state)
	ui.theme_destroy(&theme)
	draw.destroy(&dc)
	render.destroy(&r)
	font.destroy(&fonts)
	platform.destroy_window(w)
	return true
}

@(private = "file")
process_use :: proc() -> (private_bytes: int, handles: int) {
	pmc: win.PROCESS_MEMORY_COUNTERS_EX
	pmc.cb = size_of(pmc)
	win.GetProcessMemoryInfo(win.GetCurrentProcess(), (^win.PROCESS_MEMORY_COUNTERS)(&pmc), size_of(pmc))
	n: win.DWORD
	GetProcessHandleCount(win.GetCurrentProcess(), &n)
	return int(pmc.PrivateUsage), int(n)
}

@(test)
a_session_s_pieces_leave_nothing :: proc(t: ^testing.T) {
	for _ in 0 ..< LEAK_WARM { if !testing.expect(t, session_pieces(), "a window, a renderer, the faces") { return } }
	m0, h0 := process_use()
	for _ in 0 ..< LEAK_ROUNDS { if !testing.expect(t, session_pieces(), "a window, a renderer, the faces") { return } }
	m1, h1 := process_use()
	per_round := (m1 - m0) / LEAK_ROUNDS
	said := fmt.tprintf("%d rounds: private memory %d KiB a round (%d -> %d KiB), handles %d -> %d", LEAK_ROUNDS, per_round / 1024, m0 / 1024, m1 / 1024, h0, h1)
	testing.expectf(t, per_round <= LEAK_BYTES_PER_ROUND, "memory kept: %s", said)
	testing.expectf(t, h1 - h0 <= LEAK_HANDLES, "handles kept: %s", said)
}

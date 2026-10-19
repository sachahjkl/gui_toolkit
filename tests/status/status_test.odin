// Sample history (ring, resize, aggregates, rates) and the frame graph's hit testing, without a window.
//   odin test tests/status -vet -define:ODIN_TEST_THREADS=1
package status_test

import "core:testing"
import "../../font"
import "../../platform"
import "../../ui"

@(test)
history_ring :: proc(t: ^testing.T) {
	h: ui.Frame_History
	ui.history_init(&h, 4, 2)
	defer ui.history_destroy(&h)
	testing.expect_value(t, ui.history_len(&h), 0)
	testing.expect(t, ui.history_last(&h) == nil)
	for i in 0 ..< 6 {
		s := ui.history_push(&h, f64(i) * 10, u64(i))
		s.v[0], s.v[1] = f32(i), 1
	}
	testing.expect_value(t, ui.history_len(&h), 4)
	testing.expect_value(t, ui.history_at(&h, 0).tag, 2)   // the two oldest went
	testing.expect_value(t, ui.history_last(&h).tag, 5)
	testing.expect(t, ui.history_at(&h, 4) == nil)
	testing.expect(t, ui.history_at(&h, -1) == nil)
	testing.expect_value(t, ui.sample_total(ui.history_last(&h), h.series), 6)

	// late values find their sample by tag
	if s := ui.history_find_tag(&h, 3); testing.expect(t, s != nil) { s.v[1] = 2 }
	testing.expect_value(t, ui.history_at(&h, 1).v[1], 2)
	testing.expect(t, ui.history_find_tag(&h, 1) == nil)

	// shrinking keeps the newest, growing keeps everything
	ui.history_resize(&h, 2)
	testing.expect_value(t, ui.history_len(&h), 2)
	testing.expect_value(t, ui.history_at(&h, 0).tag, 4)
	ui.history_resize(&h, 8)
	testing.expect_value(t, ui.history_len(&h), 2)
	ui.history_push(&h, 60, 6)
	testing.expect_value(t, ui.history_last(&h).tag, 6)
	testing.expect_value(t, ui.history_at(&h, 0).tag, 4)
	ui.history_clear(&h)
	testing.expect_value(t, ui.history_len(&h), 0)
}

@(test)
history_aggregates :: proc(t: ^testing.T) {
	h: ui.Frame_History
	ui.history_init(&h, 100, 2)
	defer ui.history_destroy(&h)
	// 100 frames, 10 ms apart: totals 1..100 ms (series 0 = total - 1, series 1 = 1)
	for i in 1 ..= 100 {
		s := ui.history_push(&h, f64(i) * 10)
		s.v[0], s.v[1] = f32(i - 1), 1
	}
	st := ui.history_stats(&h, 0, 16.7)
	testing.expect_value(t, st.n, 100)
	testing.expect_value(t, st.min, 1)
	testing.expect_value(t, st.max, 100)
	testing.expect_value(t, st.p50, 50)
	testing.expect_value(t, st.p95, 95)
	testing.expect_value(t, st.over, 84)   // 17 .. 100
	testing.expect(t, abs(st.mean - 50.5) < 1e-3)
	testing.expect(t, abs(st.series_mean[1] - 1) < 1e-6)
	testing.expect_value(t, st.series_max[0], 99)
	testing.expect_value(t, st.span_ms, 990)
	// a window: the samples taken at or after 910 ms (the last 10)
	w := ui.history_stats(&h, 910)
	testing.expect_value(t, w.n, 10)
	testing.expect_value(t, w.min, 91)
	// 100 samples per second: the last second holds 100 of them, the last 500 ms 51 (500 .. 1000 inclusive)
	testing.expect_value(t, ui.history_rate(&h, 1000), 100)
	testing.expect_value(t, ui.history_rate(&h, 1000, 500), 102)
	testing.expect_value(t, ui.history_rate(&h, 5000), 0)
	empty: ui.Frame_History
	ui.history_init(&empty, 4, 1)
	defer ui.history_destroy(&empty)
	testing.expect_value(t, ui.history_stats(&empty).n, 0)
}

@(test)
graph_scale :: proc(t: ^testing.T) {
	h: ui.Frame_History
	ui.history_init(&h, 8, 1)
	defer ui.history_destroy(&h)
	ui.history_push(&h, 0).v[0] = 4
	testing.expect_value(t, ui.graph_scale(&h, {budget = 16.7}), 16.7)       // the budget line stays in view
	ui.history_push(&h, 1).v[0] = 50
	testing.expect(t, ui.graph_scale(&h, {budget = 16.7}) >= 50)               // a peak too
	testing.expect_value(t, ui.graph_scale(&h, {budget = 16.7, max_scale = 33}), 33)   // up to a limit

	// a rare spike (under 10 % of the bars) among short frames: the short ones keep their height, the spike is cut
	sp: ui.Frame_History
	ui.history_init(&sp, 40, 1)
	defer ui.history_destroy(&sp)
	for _ in 0 ..< 30 { ui.history_push(&sp, 0).v[0] = 2 }
	ui.history_push(&sp, 0).v[0] = 200
	top := ui.graph_scale(&sp, {scale = 4})
	testing.expect(t, top >= 4 && top < 10)
	// the series drawn on top of the history's own count for the height
	g: ui.Frame_History
	ui.history_init(&g, 4, 1)
	defer ui.history_destroy(&g)
	s := ui.history_push(&g, 0)
	s.v[0], s.v[1] = 10, 10
	testing.expect(t, ui.graph_scale(&g, {}) < 20)
	testing.expect(t, ui.graph_scale(&g, {series = 2}) >= 20)
}

Fx :: struct { fonts: font.State, theme: ui.Theme, s: ui.State, base: font.Font_Id, h: ui.Frame_History, hovered: int, clicked: bool }

@(private = "file")
frame :: proc(f: ^Fx, events: []platform.Event) {
	ui.begin_build(&f.s, {
		window_size = {400, 200}, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base, font_size = 15, text_pad = 6},
	})
	// a 100 px graph of 10 bars at the top left of the window
	ui.next({width = ui.px(100), height = ui.px(20)})
	res := ui.frame_graph("###g", &f.h, {bars = 10, budget = 16.7})
	f.hovered, f.clicked = res.hovered, res.clicked
	ui.end_build()
	free_all(context.temp_allocator)
}

@(test)
graph_hover :: proc(t: ^testing.T) {
	f: Fx
	font.init(&f.fonts)
	defer font.destroy(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !testing.expect(t, ok) { return }
	f.base = id
	ui.apply_palette(&f.theme, ui.PALETTE_MIDNIGHT)
	defer ui.theme_destroy(&f.theme)
	ui.init(&f.s, &f.fonts, &f.theme)
	defer ui.destroy(&f.s)
	ui.history_init(&f.h, 32, 1)
	defer ui.history_destroy(&f.h)
	for i in 0 ..< 4 { ui.history_push(&f.h, f64(i)).v[0] = 5 }

	frame(&f, nil)   // laid out
	move :: proc(x: f32) -> platform.Event { return {kind = .Mouse_Move, pos = {x, 10}} }
	// 4 samples in 10 slots: the newest is in the last slot (90..100 px), the oldest in slot 6
	frame(&f, {move(95)})
	testing.expect_value(t, f.hovered, 3)
	frame(&f, {move(65)})
	testing.expect_value(t, f.hovered, 0)
	frame(&f, {move(30)})   // an empty slot
	testing.expect_value(t, f.hovered, -1)
	frame(&f, {move(300)})  // outside
	testing.expect_value(t, f.hovered, -1)
	frame(&f, {move(95), {kind = .Mouse_Press, button = .Left, pos = {95, 10}}})
	frame(&f, {{kind = .Mouse_Release, button = .Left, pos = {95, 10}}})
	testing.expect(t, f.clicked)
}

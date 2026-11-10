package status_test

// Value_History (a ring of the last N values), graph_top (a round top, at least a floor), line_graph_top, and a
// line graph and a meter bar built without a window.

import "core:testing"
import "../../src/font"
import "../../src/ui"

@(test)
a_value_history_keeps_the_last_values :: proc(t: ^testing.T) {
	h: ui.Value_History(4)
	testing.expect_value(t, ui.value_history_last(&h), 0)
	for i in 0 ..< 6 { ui.value_history_push(&h, f32(i)) }
	testing.expect_value(t, h.count, 4)
	testing.expect_value(t, ui.value_history_at(&h, 0), 2)
	testing.expect_value(t, ui.value_history_last(&h), 5)
	testing.expect_value(t, ui.value_history_max(&h), 5)
	v := ui.value_history_values(&h)
	testing.expect_value(t, len(v), 4)
	testing.expect(t, v[0] == 2 && v[3] == 5, "oldest first")
	ui.value_history_clear(&h)
	testing.expect_value(t, h.count, 0)
}

@(test)
a_graph_top_is_round :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.graph_top(0), 1)
	testing.expect_value(t, ui.graph_top(0.3), 0.5)
	testing.expect_value(t, ui.graph_top(0.3, 1), 1)
	testing.expect_value(t, ui.graph_top(100), 100)
	testing.expect_value(t, ui.graph_top(130), 200)
	testing.expect_value(t, ui.graph_top(4000), 5000)
	testing.expect_value(t, ui.graph_top(6000), 10000)
	// a disk at rest: 3 kB/s under a floor of 1 MB/s
	testing.expect_value(t, ui.graph_top(3000, 1e6), 1e6)
	series := []ui.Line_Series{{values = {1, 70, 3}}, {values = {120}}}
	testing.expect_value(t, ui.line_graph_top(series, {}), 200)
	testing.expect_value(t, ui.line_graph_top(series, {top = 100}), 100)
	testing.expect_value(t, ui.line_graph_top({}, {floor = 5}), 5)
}

@(test)
a_line_graph_and_a_meter_are_built :: proc(t: ^testing.T) {
	f: Fx
	font.init(&f.fonts)
	defer font.destroy(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !testing.expect(t, ok) { return }
	ui.apply_palette(&f.theme, ui.palette_of("Midnight"))
	defer ui.theme_destroy(&f.theme)
	ui.init(&f.s, &f.fonts, &f.theme)
	defer ui.destroy(&f.s)
	h: ui.Value_History(60)
	for i in 0 ..< 10 { ui.value_history_push(&h, f32(i * 10)) }
	graph, meter: ^ui.Box
	for _ in 0 ..< 2 {
		ui.begin_build(&f.s, {
			window_size = {400, 200}, dt = 1.0 / 60, animations = false, dpi_scale = 1,
			base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = id, font_size = 15, text_pad = 6},
		})
		ui.next({width = ui.px(200), height = ui.px(80)})
		graph = ui.line_graph("###g", {{ui.value_history_values(&h), ui.color("accent")}}, {top = 100, points = 60, grid = true})
		ui.next({width = ui.px(100), height = ui.px(4)})
		meter = ui.meter_bar("###m", 0.95, 0.9)
		ui.end_build()
		free_all(context.temp_allocator)
	}
	testing.expect(t, graph.custom != nil, "the graph draws itself")
	testing.expect_value(t, graph.rect.max.x - graph.rect.min.x, 200)
	testing.expect(t, meter.a11y != nil && meter.a11y.role == .Progress_Indicator)
	testing.expect_value(t, meter.a11y.numeric, 95)
}

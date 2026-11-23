package theme_look_test

// The chosen label of a segmented control reads on its pill (WCAG AA, 4.5) in every theme of ui.THEMES, dark and light,
// machined or flat, and also when the palette's accent_text does not read on the accent (a program's own scheme, Wren's).

import "core:fmt"
import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") SEGMENT_RATIO :: 4.5

@(private = "file")
Seg_Probe :: struct { chosen: int }

@(private = "file")
seg_build :: proc(s: ^session.Session) {
	p := (^Seg_Probe)(s.user)
	_ = ui.segmented("###seg_probe", {"System", "Window", "Off"}, &p.chosen)
}

@(test)
the_chosen_segment_reads_on_its_pill :: proc(t: ^testing.T) {
	p: Seg_Probe
	s := session.start(t, {size = {600, 200}, user = &p, no_renderer = true, build = seg_build})
	for th in ui.THEMES {
		for light in ([]bool{false, true}) {
			if (light && th.versions == .Dark_Only) || (!light && th.versions == .Light_Only) { continue }
			for spoiled in ([]bool{false, true}) {
				pal := ui.theme_palette(th, light)
				// (spoiled: accent_text set to the accent's own colour, the worst a scheme can give)
				if spoiled { pal.accent_text = pal.accent }
				name := fmt.tprintf("%s (%s%s)", th.name, light ? "light" : "dark", spoiled ? ", accent_text = accent" : "")
				ui.use(s.state)
				ui.apply_palette(s.state.theme, pal, s.state.space)
				session.frames(s, 2)
				ui.use(s.state)
				accent := ui.segmented_key_color()
				label := session.get(s, "seg0")
				if !testing.expectf(t, label != nil, "%s: the chosen segment is built", name) { continue }
				c := ui.contrast(label.target_text, accent)
				testing.expectf(t, c >= SEGMENT_RATIO, "%s: the chosen label on its pill (%.2f)", name, c)
			}
		}
	}
}

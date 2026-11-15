// A busy button (Button_Options.busy): its act under way. The day-one break of such a state is a button that jumps (a
// spinner put beside it, or its words moving when the act starts) or one that still acts on a click.
package states_test

import "core:math"
import "core:sync"
import "core:testing"
import "gt:font"
import "gt:platform"
import "gt:ui"

@(private = "file")
busy_lock: sync.Mutex

@(private = "file")
Busy_Run :: struct {
	busy:    bool,
	clicked: bool,
	b:       ^ui.Box,
}

@(private = "file")
busy_frame :: proc(fx: ^Fx_Faces, r: ^Busy_Run, events: []platform.Event) {
	ui.begin_build(&fx.s, {
		window_size = {800, 600}, events = events, dt = 1.0 / 60, animations = true, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = fx.base_font, font_size = 15, text_pad = 6},
	})
	ui.next({fixed_x = 20, fixed_y = 20})
	r.clicked = ui.button("###go", "Accept and install", ui.ICON_X, {busy = r.busy}).clicked
	r.b = ui.prev_box("###go")
	ui.end_build()
	free_all(context.temp_allocator)
}

@(test)
a_busy_button_keeps_its_place_and_does_not_act :: proc(t: ^testing.T) {
	sync.mutex_lock(&busy_lock)
	defer sync.mutex_unlock(&busy_lock)
	fx: Fx_Faces
	font.init(&fx.fonts)
	defer font.destroy(&fx.fonts)
	id, ok := font.load_embedded(&fx.fonts, font.FALLBACK_UI_DATA)
	if !testing.expect(t, ok, "font") { return }
	fx.base_font = id
	ui.apply_palette(&fx.theme, ui.palette_of("Graphite"))
	defer ui.theme_destroy(&fx.theme)
	ui.init(&fx.s, &fx.fonts, &fx.theme)
	defer ui.destroy(&fx.s)

	r: Busy_Run
	busy_frame(&fx, &r, nil)
	busy_frame(&fx, &r, nil)
	rest := r.b.rect
	c := (rest.min + rest.max) * 0.5
	r.busy = true
	busy_frame(&fx, &r, nil)
	busy_frame(&fx, &r, nil)
	testing.expect(t, math.abs((r.b.rect.max.x - r.b.rect.min.x) - (rest.max.x - rest.min.x)) < 0.5, "as wide busy as at rest")
	busy_frame(&fx, &r, {{kind = .Mouse_Move, pos = c}})
	busy_frame(&fx, &r, {{kind = .Mouse_Press, pos = c, button = .Left}})
	busy_frame(&fx, &r, {{kind = .Mouse_Release, pos = c, button = .Left}})
	testing.expect(t, !r.clicked, "a click does nothing while it is busy")
	ui.use(&fx.s)
	testing.expect(t, ui.needs_frame(&fx.s), "its spinner turns")

	// the act done: the same button acts again
	r.busy = false
	busy_frame(&fx, &r, nil)
	busy_frame(&fx, &r, {{kind = .Mouse_Press, pos = c, button = .Left}})
	busy_frame(&fx, &r, {{kind = .Mouse_Release, pos = c, button = .Left}})
	testing.expect(t, r.clicked, "and acts once it is not")
}

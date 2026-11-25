package theme_look_test

// The check mark inside `ui.checkbox` (and a `Toggle_Form.Check` toggle) reads on its accent fill (WCAG AA, 4.5) in
// every theme of ui.THEMES, dark and light, and even when a palette's `accent_text` does not read on its accent.

import "core:fmt"
import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") CHECK_RATIO :: 4.5

@(private = "file")
Check_Probe :: struct { checked: bool }

@(private = "file")
check_build :: proc(s: ^session.Session) {
	p := (^Check_Probe)(s.user)
	_ = ui.checkbox("###chk_probe", "Enabled", &p.checked)
}

@(test)
checkbox_mark_reads_on_accent_in_every_theme :: proc(t: ^testing.T) {
	p := Check_Probe{checked = true}
	s := session.start(t, {size = {400, 120}, user = &p, no_renderer = true, build = check_build})
	for th in ui.THEMES {
		for light in ([]bool{false, true}) {
			if (light && th.versions == .Dark_Only) || (!light && th.versions == .Light_Only) { continue }
			for spoiled in ([]bool{false, true}) {
				pal := ui.theme_palette(th, light)
				if spoiled { pal.accent_text = pal.accent }
				name := fmt.tprintf("%s (%s%s)", th.name, light ? "light" : "dark", spoiled ? ", accent_text = accent" : "")
				ui.use(s.state)
				ui.apply_palette(s.state.theme, pal, s.state.space)
				session.frames(s, 2)
				ui.use(s.state)
				row := session.get(s, "chk_probe")
				if !testing.expectf(t, row != nil, "%s: checkbox row built", name) { continue }
				mark := ui.box_from_key(ui.key_from_string(row.key, "mark"))
				if !testing.expectf(t, mark != nil && mark.custom_user != nil, "%s: mark box built", name) { continue }
				d := (^ui.Mark_Draw)(mark.custom_user)
				c := ui.contrast(d.check, d.accent)
				testing.expectf(t, c >= CHECK_RATIO, "%s: check mark on accent (%.2f)", name, c)
				if th.name == "Ember" && light && !spoiled {
					testing.expectf(t, ui.luminance(d.check) > 0.85, "Ember Light check mark must be light, got lum=%.3f", ui.luminance(d.check))
				}
			}
		}
	}
}

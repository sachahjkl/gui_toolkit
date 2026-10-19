package fidget

// Settings dialog (View > Settings..., Ctrl+, or the command palette). Every change applies at once and is saved by
// the frame loop (settings.txt), so there is no OK / Apply button.

import "core:fmt"
import "core:math"
import "../../draw"
import "../../platform"
import "../../render"
import "../../ui"

@(private)
section_title :: proc(text: string, width: f32) {
	em := ui.font_size()
	ui.spacer(ui.px(em * 0.9))
	if ui.tags("weak") {
		ui.next({width = ui.px(width), height = ui.px(ui.dense(em * 1.7)), font_size = math.round(em * 0.82)})
		ui.label(text)
	}
	ui.hline(ui.px(width))
	ui.spacer(ui.px(em * 0.4))
}

Pill_Draw :: struct { color: draw.Color, pos: ui.Toast_Position, filled: bool }

// one cell of the position picker: a little toast shape at the cell's corner / edge
@(private)
pill_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Pill_Draw)(user)
	r := b.rect
	em := b.font_size
	pw, ph := em * 1.7, em * 0.55
	inset := em * 0.35
	x, y: f32
	#partial switch d.pos {
	case .Top_Left, .Middle_Left, .Bottom_Left:    x = r.min.x + inset
	case .Top_Right, .Middle_Right, .Bottom_Right: x = r.max.x - inset - pw
	case:                                          x = (r.min.x + r.max.x - pw) * 0.5
	}
	#partial switch d.pos {
	case .Top_Left, .Top_Center, .Top_Right:          y = r.min.y + inset
	case .Bottom_Left, .Bottom_Center, .Bottom_Right: y = r.max.y - inset - ph
	case:                                             y = (r.min.y + r.max.y - ph) * 0.5
	}
	if d.filled {
		draw.rect(dc, {{x, y}, {x + pw, y + ph}}, d.color, ui.rad(ph * 0.5))
	} else {
		draw.rect(dc, {{x, y}, {x + pw, y + ph}}, d.color, ui.rad(ph * 0.5), 1.5)
	}
}

// A miniature window split in a 3x3 grid; click a cell to anchor the toasts there (the center cell is not a choice).
@(private)
position_picker :: proc(app: ^App, size: ui.Vec2) -> (changed: bool) {
	em := ui.font_size()
	grid := [3][3]Maybe(ui.Toast_Position){
		{.Top_Left, .Top_Center, .Top_Right},
		{.Middle_Left, nil, .Middle_Right},
		{.Bottom_Left, .Bottom_Center, .Bottom_Right},
	}
	cur := ui.toast_position(&app.ui_state)
	if ui.tags("input") {
		ui.next({width = ui.px(size.x), height = ui.px(size.y), axis = .Y, radius = em * 0.5})
		screen := ui.build_box({.Draw_Background, .Draw_Border, .Clip}, "###pos_screen")
		if ui.parent(screen) {
			for row, ri in grid {
				ui.next({width = ui.fill(), height = ui.pct(1.0 / 3), axis = .X})
				if ui.row(id = fmt.tprintf("###pos_row%d", ri)) {
					for cell, ci in row {
						ui.next({width = ui.pct(1.0 / 3), height = ui.pct(1)})
						p, is_pos := cell.?
						if !is_pos { ui.build_box({}, "###pos_center"); continue }
						selected := p == cur
						b := ui.build_box({.Clickable, .Draw_Hot_Effects}, fmt.tprintf("###pos_%d_%d", ri, ci))
						d := ui.frame_new(Pill_Draw)
						d.pos, d.filled = p, selected
						d.color = selected ? ui.color("accent") : ui.color("border")
						b.custom, b.custom_user = pill_draw, d
						sig := ui.signal(b)
						if sig.clicked && !selected {
							ui.set_toast_position(&app.ui_state, p)
							ui.toast(.Info, "Toasts: %s", ui.toast_position_names[p])
							changed = true
						}
						if ui.hovered_for(sig, 0.35) {
							if ui.tooltip() {
								ui.next({width = ui.text_size(em * 0.6), height = ui.px(ui.dense(em * 2))})
								ui.label(ui.toast_position_names[p])
							}
						}
					}
				}
			}
		}
	}
	return
}

anim_mode_labels := [?]string{"System", "On", "Off"}

build_settings :: proc(app: ^App) {
	em := ui.font_size()
	w := min(em * 34, f32(app.win.size.x) * 0.92)
	pad := em * 1.5
	inner := w - 2 * pad
	if ui.modal("settings", w, &app.settings_open, 0.10) {
		if ui.style({width = ui.px(w)}) {
			ui.spacer(ui.px(em * 1.1))
			// header
			ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 2.6))})
			if ui.row(.Center, id = "###st_head") {
				ui.spacer(ui.px(pad))
				if ui.tags("weak") { ui.icon(ICON_GEAR, em * 1.9) }
				ui.spacer(ui.px(em * 0.4))
				ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 1.35)})
				ui.label("Settings")
				ui.next({width = ui.px(em * 2.2), height = ui.px(em * 2.2)})
				if ui.icon_button("st_close", ui.ICON_X).clicked { app.settings_open = false }
				ui.spacer(ui.px(pad - em * 0.4))
			}

			ui.next({width = ui.px(w), height = ui.children_sum()})
			if ui.row(id = "###st_body_row") {
				ui.spacer(ui.px(pad))
				ui.next({width = ui.px(inner), height = ui.children_sum(), axis = .Y})
				if ui.column(id = "###st_body") {
					//- appearance
					section_title("APPEARANCE", inner)
					if ui.form_row("Theme") {
						names: [len(palettes)]string
						for p, i in palettes { names[i] = p.name }
						sel := app.palette_idx
						if ui.dropdown("###st_theme", names[:], &sel) { set_palette(app, sel) }
					}
					if ui.form_row("Zoom") {
						z := ui.zoom(&app.ui_state) * 100
						old := z
						ui.slider("###st_zoom", &z, ui.ZOOM_MIN * 100, ui.ZOOM_MAX * 100, 10, "%.0f%%")
						if z != old { ui.set_zoom(&app.ui_state, z / 100) }
					}
					if ui.tags("weak") {
						ui.next({width = ui.px(inner), height = ui.px(ui.dense(em * 1.6)), font_size = math.round(em * 0.82)})
						ui.label("Also Ctrl+wheel, Ctrl +, Ctrl -, Ctrl 0 anywhere.")
					}
					if ui.form_row("Density") {
						modes := [?]string{"Comfortable", "Compact"}
						sel := ui.density(&app.ui_state) < 0.99 ? 1 : 0
						if ui.segmented("###st_density", modes[:], &sel) { ui.set_density(&app.ui_state, sel == 1 ? ui.DENSITY_COMPACT : 1) }
					}
					if ui.form_row("Rounding") {
						rnd := ui.rounding(&app.ui_state) * 100
						old := rnd
						ui.slider("###st_round", &rnd, 0, 200, 5, rnd == 0 ? "Square" : "%.0f%%")
						if rnd != old { ui.set_rounding(&app.ui_state, rnd / 100) }
					}
					if ui.form_row("Corner shape") {
						shapes := [?]string{"Circular", "Squircle"}
						sel := app.corner_smoothing > 0.5 ? 1 : 0
						if ui.segmented("###st_shape", shapes[:], &sel) { app.corner_smoothing = f32(sel) }
					}
					if ui.form_row("Blending") {
						spaces := [?]string{"Linear light", "sRGB (web)"}
						sel := int(render.blend_space(&app.r))
						if ui.segmented("###st_blend", spaces[:], &sel) { render.set_blend_space(&app.r, render.Blend_Space(sel)) }
					}
					if ui.tags("weak") {
						ui.next({width = ui.px(inner), height = ui.px(ui.dense(em * 1.6)), font_size = math.round(em * 0.82)})
						ui.label("Where colors mix: edges, text and gradients change, the theme adapts.")
					}
					ui.next({width = ui.px(inner), height = ui.px(ui.dense(em * 2.4))})
					ui.toggle("###st_status", "Status bar", &app.show_status)

					//- motion
					section_title("MOTION", inner)
					if ui.form_row("Animations") {
						sel := int(app.anim_mode)
						if ui.segmented("###st_anim", anim_mode_labels[:], &sel) { app.anim_mode = Anim_Mode(sel); app.os_anim_checked_ms = 0 }
					}
					if ui.tags("weak") {
						ui.next({width = ui.px(inner), height = ui.px(ui.dense(em * 1.6)), font_size = math.round(em * 0.82)})
						ui.label(fmt.tprintf("System follows Windows (Accessibility > Visual effects), currently %s.", platform.os_animations_enabled() ? "on" : "off"))
					}

					//- notifications
					section_title("NOTIFICATIONS", inner)
					ui.next({width = ui.px(inner), height = ui.px(ui.dense(em * 7))})
					if ui.row(.Center, id = "###st_toast_row") {
						position_picker(app, {em * 10.5, em * 6.5})
						ui.spacer(ui.px(em * 1.2))
						ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
						if ui.column(id = "###st_toast_col") {
							if ui.tags("weak") {
								ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.6)), font_size = math.round(em * 0.82)})
								ui.label("Toast position")
							}
							ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
							ui.label(ui.toast_position_names[ui.toast_position(&app.ui_state)])
							ui.spacer(ui.px(em * 0.5))
							ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
							if ui.row(.Center, id = "###st_test_row") {
								if ui.button_icon("###st_test", ICON_PLAY, "Send a test toast").clicked {
									kinds := [?]ui.Toast_Kind{.Info, .Good, .Warn, .Bad}
									texts := [?]string{"Heads up: an info toast", "Saved successfully", "Careful: disk almost full", "Something went wrong"}
									k := int(rand_u64() % 4)
									ui.toast(kinds[k], "%s", texts[k])
								}
							}
						}
					}

					ui.spacer(ui.px(em * 1.2))
					ui.next({width = ui.px(inner), height = ui.px(ui.dense(em * 2.6))})
					if ui.row(.Center, id = "###st_foot") {
						if ui.tags("ghost_button") {
							if ui.button_icon("###st_reset", ICON_UNDO, "Restore defaults").clicked {
								set_palette(app, DEFAULT_PALETTE)
								app.anim_mode = .System
								app.os_anim_checked_ms = 0
								app.show_status = true
								ui.set_zoom(&app.ui_state, 1)
								ui.set_toast_position(&app.ui_state, .Top_Right)
								ui.set_rounding(&app.ui_state, 1)
								ui.set_density(&app.ui_state, 1)
								app.corner_smoothing = 1
								render.set_blend_space(&app.r, .Linear)
								ui.toast(.Good, "Settings restored to defaults")
							}
						}
						ui.spacer(ui.fill())
						if ui.tags("accent_button") {
							if ui.button_icon("###st_done", "", "Done").clicked { app.settings_open = false }
						}
					}
				}
				ui.spacer(ui.px(pad))
			}
			ui.spacer(ui.px(em * 1.3))
		}
	}
}

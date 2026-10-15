package fidget

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"
import "../../ui"

the_app: ^App

clip_get :: proc() -> string { return platform.get_clipboard(the_app.win, context.temp_allocator) }
clip_set :: proc(text: string) { platform.set_clipboard(the_app.win, text) }

////////////////////////////////
// Settings (%APPDATA%\gui_toolkit_fidget\settings.txt)

settings_dir :: proc() -> string {
	return fmt.tprintf("%s/gui_toolkit_fidget", platform.config_dir(context.temp_allocator))
}

snapshot :: proc(app: ^App) -> Saved_Settings {
	return {palette = i32(app.palette_idx), anim = i32(app.anim_mode), status = app.show_status ? 1 : 0, toast_pos = i32(ui.toast_position(&app.ui_state)), zoom = ui.zoom(&app.ui_state), rounding = ui.rounding(&app.ui_state), smoothing = app.corner_smoothing, density = ui.density(&app.ui_state)}
}

settings_save :: proc(app: ^App) {
	names := [Anim_Mode]string{.System = "system", .On = "on", .Off = "off"}
	pos_names := [ui.Toast_Position]string{.Top_Left = "top_left", .Top_Center = "top_center", .Top_Right = "top_right", .Middle_Left = "middle_left", .Middle_Right = "middle_right", .Bottom_Left = "bottom_left", .Bottom_Center = "bottom_center", .Bottom_Right = "bottom_right"}
	text := fmt.tprintf("animations=%s\npalette=%d\nstatus_bar=%d\ntoasts=%s\nzoom=%.3f\nrounding=%.2f\ncorners=%s\ndensity=%s\n", names[app.anim_mode], app.palette_idx, app.show_status ? 1 : 0, pos_names[ui.toast_position(&app.ui_state)], ui.zoom(&app.ui_state), ui.rounding(&app.ui_state), app.corner_smoothing > 0.5 ? "squircle" : "circular", ui.density(&app.ui_state) < 0.99 ? "compact" : "comfortable")
	_ = os.make_directory_all(settings_dir())
	_ = os.write_entire_file(fmt.tprintf("%s/settings.txt", settings_dir()), transmute([]byte)text)
	app.saved = snapshot(app)
}

settings_load :: proc(app: ^App) {
	data, err := os.read_entire_file(fmt.tprintf("%s/settings.txt", settings_dir()), context.temp_allocator)
	if err != nil { return }
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		eq := strings.index_byte(line, '=')
		if eq < 0 { continue }
		key, val := strings.trim_space(line[:eq]), strings.trim_space(line[eq + 1:])
		switch key {
		case "animations": app.anim_mode = val == "on" ? .On : (val == "off" ? .Off : .System)
		case "palette": if v, ok := strconv.parse_int(val); ok { set_palette(app, v) }
		case "status_bar": app.show_status = val != "0"
		case "zoom": if v, ok := strconv.parse_f32(val); ok { ui.set_zoom(&app.ui_state, v) }
		case "rounding": if v, ok := strconv.parse_f32(val); ok { ui.set_rounding(&app.ui_state, v) }
		case "corners": app.corner_smoothing = val == "circular" ? 0 : 1
		case "density": ui.set_density(&app.ui_state, val == "compact" ? ui.DENSITY_COMPACT : 1)
		case "toasts":
			for p in ui.Toast_Position {
				name, _ := strings.replace_all(strings.to_lower(ui.toast_position_names[p], context.temp_allocator), " ", "_", context.temp_allocator)
				if name == val { ui.set_toast_position(&app.ui_state, p) }
			}
		}
	}
}

////////////////////////////////
// Theme, animation mode

set_palette :: proc(app: ^App, idx: int) {
	app.palette_idx = (idx % len(palettes) + len(palettes)) % len(palettes)
	app.accent_override = false
	h, s, v := draw.hsv_from_hex(palettes[app.palette_idx].palette.accent)
	app.hue, app.sat, app.val = h, s, v
}

apply_theme :: proc(app: ^App) {
	p := palettes[app.palette_idx].palette
	ui.apply_palette(&app.theme, p)
	if app.accent_override {
		ui.theme_set(&app.theme, "accent", draw.hsv(app.hue, app.sat, app.val))
		ui.theme_set(&app.theme, "accent_button background", draw.hsv(app.hue, app.sat, app.val))
		ui.theme_set(&app.theme, "accent_button border", draw.hsv(app.hue, app.sat, app.val))
		ui.theme_set(&app.theme, "focus border", draw.hsv(app.hue, app.sat, app.val))
	}
}

animations_enabled :: proc(app: ^App) -> bool {
	switch app.anim_mode {
	case .On:  return true
	case .Off: return false
	case .System:
		now := ui.now_ms()
		if app.os_anim_checked_ms == 0 || now - app.os_anim_checked_ms > 500 {
			app.os_anim_on = platform.os_animations_enabled()
			app.os_anim_checked_ms = now
		}
		return app.os_anim_on
	}
	return true
}

////////////////////////////////
// Frame

frame :: proc(app: ^App) {
	// wait for the GPU first, read input second: the picture we build is the next one on screen
	render.wait_for_frame(&app.r)
	events := platform.poll_events(app.win, false)
	render.mark_input(&app.r)   // returns nil when re-entered from a live resize
	if len(events) > 0 { app.frames_requested = max(app.frames_requested, 4) }
	scale := app.win.dpi_scale
	render.resize(&app.r, app.win.size)
	size := draw.Vec2{f32(app.win.size.x), f32(app.win.size.y)}

	now := time.tick_now()
	dt := clamp(f32(time.duration_seconds(time.tick_diff(app.last_tick, now))), 0.0005, 0.1)
	app.last_tick = now
	app.real_dt = dt
	t_begin := time.tick_now()

	apply_theme(app)
	render.set_corner_smoothing(&app.r, app.corner_smoothing)
	if sq := ui.rounding(&app.ui_state) == 0; sq != app.window_square {
		app.window_square = sq
		platform.set_square_corners(app.win, sq)
	}
	platform.set_dark_title(app.win, palettes[app.palette_idx].palette.dark)
	if tr := palettes[app.palette_idx].palette.translucent; tr != app.translucent {
		app.translucent = tr
		app.backdrop_ok = platform.set_backdrop(app.win, tr)
	}

	dens := ui.density(&app.ui_state)
	base := ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(math.round(36 * dens))}, font = app.ui_font, font_size = 15, text_pad = 7 * (0.4 + 0.6 * dens), cursor = .Arrow}
	ui.begin_build(&app.ui_state, {
		window_size = size, events = events, dt = dt * (app.slowmo ? 0.2 : 1), animations = animations_enabled(app),
		dpi_scale = scale, base = base, clipboard_get = clip_get, clipboard_set = clip_set,
	})
	build_ui(app)
	ui.end_build()
	if app.debug_dump && app.frame_index == 5 { ui.debug_dump_tall(&app.ui_state, f32(app.win.size.y) * 0.5) }
	platform.set_cursor(app.win, ui.cursor(&app.ui_state))
	if ui.needs_frame(&app.ui_state) { app.frames_requested = max(app.frames_requested, 2) }
	if snapshot(app) != app.saved { settings_save(app) }

	// window title
	title := fmt.tprintf("gui_toolkit fidget  |  %s  |  %s", page_names[int(app.page)], palettes[app.palette_idx].name)
	if app.state_title {   // machine-readable state for scripted tests
		title = fmt.tprintf("S zoom=%d page=%d name=%s bio=%s agree=%d sw1=%d vol=%.0f lang=%d focus=%s editor_lines=%d editor_len=%d pal=%d settings=%d theme=%d round=%d menu=%d",
			int(math.round(ui.zoom(&app.ui_state) * 100)), int(app.page), ui.field_string(&app.name), ui.field_string(&app.bio), int(app.agree),
			int(app.sw[1]), app.slider[0], app.dd[0], ui.focused_name(), ui.area_line_count(&app.editor), len(app.editor.buf), int(app.palette_open), int(app.settings_open), app.palette_idx, int(math.round(ui.rounding(&app.ui_state) * 100)), int(ui.ctx_menu_any_open()))
	}
	if title != app.title_cache { app.title_cache = strings.clone(title); platform.set_title(app.win, title) }

	draw.begin_frame(&app.dc, size)
	// translucent palettes clear to transparent so the backdrop shows; others to the page colour (no dark seams)
	clear_c := app.translucent && app.backdrop_ok ? draw.Color{} : draw.hex(palettes[app.palette_idx].palette.bg | 0xff)
	render.frame_begin(&app.r, clear_c)
	ui.draw_tree(&app.ui_state, &app.dc)
	draw.end_frame(&app.dc)
	ms := f32(time.duration_milliseconds(time.tick_since(t_begin)))   // before present: vsync wait is not our cost
	render.frame_end(&app.r)

	if app.bench_n > 0 { bench_frame(app, ms) }
	app.ui_ms = math.lerp(app.ui_ms, ms, f32(0.25))
	app.ms_hist[app.ms_idx % 64] = ms
	app.ms_idx += 1
	app.frame_index += 1
	free_all(context.temp_allocator)
}

main :: proc() {
	app := new(App)
	the_app = app
	rng_state ~= u64(time.tick_now()._nsec) * 0x9e3779b97f4a7c15
	font.init(&app.fonts)
	// transparent: some palettes (Aero) let the OS backdrop show through the page background
	app.win = platform.open_window("gui_toolkit fidget", {1180, 780}, transparent = true)
	if !render.init(&app.r, app.win.hwnd, app.win.size, transparent = true) { fmt.eprintln("renderer init failed"); return }
	ok: bool
	app.ui_font, ok = font.load_from_file(&app.fonts, "C:/Windows/Fonts/segoeui.ttf")
	if !ok { fmt.eprintln("cannot load segoeui.ttf"); return }
	app.mono, _ = font.load_from_file(&app.fonts, "C:/Windows/Fonts/consola.ttf")
	if app.mono == 0 { app.mono = app.ui_font }
	exe_dir, _ := os.get_executable_directory(context.temp_allocator)
	app.icons, ok = font.load_from_file(&app.fonts, fmt.tprintf("%s/icons.ttf", exe_dir))
	if !ok { fmt.eprintln("cannot load icons.ttf (expected next to the exe)"); return }
	draw.init(&app.dc, &app.r, &app.fonts)
	ui.init(&app.ui_state, &app.fonts, &app.theme)
	app.ui_state.icon_font = app.icons
	app.ui_state.mono_font = app.mono

	app.show_status = true
	app.sliders_on = true
	app.corner_smoothing = 1
	set_palette(app, DEFAULT_PALETTE)
	reset_values(app)
	data_init(app)
	app.tree_open[0], app.tree_open[1], app.tree_open[6], app.tree_open[10] = true, true, true, true
	app.tree_sel = 2
	settings_load(app)
	args := os.args
	for a in args[1:] {   // test flags: --page=N --palette=N --anim=on|off
		if strings.has_prefix(a, "--page=") { if v, vok := strconv.parse_int(a[7:]); vok { app.page = Page(clamp(v, 0, len(Page) - 1)) } }
		if strings.has_prefix(a, "--theme=") { if v, vok := strconv.parse_int(a[8:]); vok { set_palette(app, v) } }
		if a == "--palette" { app.palette_open = true; app.palette_focus = true }
		if strings.has_prefix(a, "--palette_query=") { app.palette_open = true; app.palette_focus = true; ui.field_set(&app.palette_field, a[16:]) }
		if a == "--modal" { app.modal_open = true }
		if a == "--about" { app.about_open = true }
		if a == "--settings" { app.settings_open = true }
		if a == "--toasts" { app.debug_toasts = true }
		if a == "--state_title" { app.state_title = true }
		if strings.has_prefix(a, "--size=") {
			if x := strings.index_byte(a, 'x'); x > 7 {
				sw, ok1 := strconv.parse_int(a[7:x]); sh, ok2 := strconv.parse_int(a[x + 1:])
				if ok1 && ok2 { platform.set_size(app.win, {sw, sh}) }
			}
		}
		if a == "--long_text" {
			sb := strings.builder_make(context.temp_allocator)
			for i in 1 ..= 60 { fmt.sbprintf(&sb, "line %d: the quick brown fox jumps over the lazy dog, then keeps running far to the right %d\n", i, i * i) }
			ui.area_set(&app.editor, strings.to_string(sb))
		}
		if strings.has_prefix(a, "--toast_pos=") { if v, vok := strconv.parse_int(a[12:]); vok { ui.set_toast_position(&app.ui_state, ui.Toast_Position(clamp(v, 0, len(ui.Toast_Position) - 1))) } }
		if a == "--anim=off" { app.anim_mode = .Off }
		if a == "--anim=on" { app.anim_mode = .On }
		if a == "--dump" { app.debug_dump = true }
		if a == "--compact" { ui.set_density(&app.ui_state, ui.DENSITY_COMPACT) }
		if strings.has_prefix(a, "--bench=") { if v, vok := strconv.parse_int(a[8:]); vok { app.bench_n = v } }
		if strings.has_prefix(a, "--bench_out=") { app.bench_out = a[12:] }
	}
	app.saved = snapshot(app)

	app.last_tick = time.tick_now()
	app.frames_requested = 4
	app.win.user = app
	app.win.on_frame = proc(user: rawptr) { frame((^App)(user)) }
	platform.show_window(app.win)

	for !platform.is_closed(app.win) && !app.want_quit {
		if app.frames_requested == 0 && !ui.needs_frame(&app.ui_state) {
			when #config(LOOP_PROBE, false) { fmt.eprintln("loop: idle wait, frame", app.frame_index, "anim_mode", app.anim_mode, "enabled", animations_enabled(app), "os", platform.os_animations_enabled()) }
			platform.wait_event(app.win, ui.wake_ms(&app.ui_state))
		}
		frame(app)
		if app.frames_requested > 0 { app.frames_requested -= 1 }
	}
}

// --bench=N [--bench_out=file]: renders N frames back to back (after a warm-up), then writes the CPU time per frame
// (build + layout + draw, without present) and quits. Used to check that changes keep the toolkit fast.
bench_frame :: proc(app: ^App, ms: f32) {
	app.frames_requested = max(app.frames_requested, 2)
	if app.frame_index < 60 { return }
	append(&app.bench_ms, ms)
	if len(app.bench_ms) < app.bench_n { return }
	s := slice.clone(app.bench_ms[:], context.temp_allocator)
	slice.sort(s)
	sum: f32
	for v in s { sum += v }
	text := fmt.tprintf("frames=%d avg=%.3f p50=%.3f p95=%.3f max=%.3f boxes=%d\n", len(s), sum / f32(len(s)), s[len(s) / 2], s[len(s) * 95 / 100], s[len(s) - 1], ui.boxes_built(&app.ui_state))
	if app.bench_out != "" { _ = os.write_entire_file(app.bench_out, transmute([]u8)text) } else { fmt.print(text) }
	app.want_quit = true
}
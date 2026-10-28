// Every cursor in a grid: hover a cell to get its cursor. Each cell shows the cursor as the system draws it, over a
// light and a dark tile, with its CSS name and where it comes from (the system's, or drawn by the toolkit). The last
// cell has a custom cursor made from an image (custom_cursor_create), with its hotspot at the center.
//   odin run examples/cursors
package cursors_example

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:time"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"
import "../../ui"

App :: struct {
	win:      ^platform.Window,
	r:        render.Renderer,
	fonts:    font.State,
	dc:       draw.Context,
	ui_state: ui.State,
	theme:    ui.Theme,
	ui_font:  font.Font_Id,
	frames:   int,
	last:     time.Tick,
	previews: [platform.Cursor][2]render.Texture,   // light, dark tile
	preview_px: int,
	custom:   platform.Custom_Cursor,
	custom_tex: [2]render.Texture,
	want_custom: bool,   // the pointer is over the custom cursor's cell
	forced_px: int,      // --preview N: previews at N pixels (0: the size cursors have on the window)
}

the_app: ^App

Cell :: struct { app: ^App, tex: [2]render.Texture }

cell_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	c := (^Cell)(user)
	s := ui.scale()
	sz := f32(c.app.preview_px)
	y := b.rect.min.y + 8 * s
	for t, i in c.tex {
		if t == 0 { continue }
		x := b.rect.min.x + 8 * s + f32(i) * (sz + 6 * s)
		draw.image(dc, t, {{x, y}, {x + sz, y + sz}})
		draw.rect(dc, {{x, y}, {x + sz, y + sz}}, draw.hex(0x80808080), 0, 1)
	}
}

// A target: rings and a dot, the hotspot at the center.
target_image :: proc(n: int) -> []u8 {
	px := make([]u8, n * n * 4, context.temp_allocator)
	c := f32(n) * 0.5
	for y in 0 ..< n {
		for x in 0 ..< n {
			d := math.sqrt((f32(x) + 0.5 - c) * (f32(x) + 0.5 - c) + (f32(y) + 0.5 - c) * (f32(y) + 0.5 - c))
			o := (y * n + x) * 4
			switch {
			case d < 2.5:                   px[o], px[o + 1], px[o + 2], px[o + 3] = 230, 30, 60, 255
			case abs(d - c * 0.55) < 1.5:   px[o], px[o + 1], px[o + 2], px[o + 3] = 230, 30, 60, 255
			case abs(d - c * 0.9) < 1.8:    px[o], px[o + 1], px[o + 2], px[o + 3] = 255, 255, 255, 255
			case abs(d - c * 0.9) < 2.8:    px[o], px[o + 1], px[o + 2], px[o + 3] = 20, 20, 20, 255
			}
		}
	}
	return px
}

make_previews :: proc(app: ^App) {
	px := app.forced_px > 0 ? app.forced_px : platform.cursor_size_px(app.win)
	if px == app.preview_px { return }
	for &pair in app.previews { for t in pair { if t != 0 { render.destroy_texture(&app.r, t) } }; pair = {} }
	for t in app.custom_tex { if t != 0 { render.destroy_texture(&app.r, t) } }
	app.preview_px = px
	bgs := [2][3]u8{{240, 240, 240}, {40, 40, 44}}
	upload :: proc(app: ^App, handle: rawptr, px: int, bg: [3]u8) -> render.Texture {
		pixels := platform.cursor_render(handle, px, bg, context.temp_allocator)
		if pixels == nil { return 0 }
		t := render.create_texture_rgba(&app.r, px, px, false)
		render.update_texture_rgba(&app.r, t, 0, 0, px, px, pixels)
		return t
	}
	for c in platform.Cursor {
		if platform.cursor_source(c) == .Drawn && px != platform.cursor_size_px(app.win) {
			// another size than the window's (--preview): drawn at that size rather than scaled
			img, ok := platform.cursor_draw(c, px, platform.cursor_scheme(), context.temp_allocator)
			if !ok { continue }
			for bg, i in bgs {
				out := make([]u8, px * px * 4, context.temp_allocator)
				for k := 0; k < len(out); k += 4 {
					a := u32(img.pixels[k + 3])
					for ch in 0 ..< 3 { out[k + ch] = u8((u32(img.pixels[k + ch]) * a + u32(bg[ch]) * (255 - a)) / 255) }
					out[k + 3] = 255
				}
				t := render.create_texture_rgba(&app.r, px, px, false)
				render.update_texture_rgba(&app.r, t, 0, 0, px, px, out)
				app.previews[c][i] = t
			}
			continue
		}
		h := platform.cursor_handle_of(app.win, c)
		for bg, i in bgs { app.previews[c][i] = upload(app, h, px, bg) }
	}
	info := platform.custom_cursor_info(app.win, app.custom)
	for bg, i in bgs { app.custom_tex[i] = upload(app, info.handle, px, bg) }
}

build_ui :: proc(app: ^App) {
	s := ui.scale()
	em := ui.font_size()
	cols := max(int(f32(app.win.size.x) / max(190 * s, 2 * f32(app.preview_px) + 40 * s)), 1)
	cell_w := f32(app.win.size.x - 24) / f32(cols) - 8 * s
	cell_h := f32(app.preview_px) + 16 * s + em * 2.6
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.column(flags = {.View_Scroll_Y, .Clip}, id = "###grid_scroll") {
		ui.spacer(ui.px(12))
		i := 0
		n := len(platform.Cursor) + 1
		for i < n {
			ui.next({width = ui.fill(), height = ui.px(cell_h + 8 * s)})
			if ui.row(id = fmt.tprintf("###row%d", i)) {
				ui.spacer(ui.px(12))
				for _ in 0 ..< cols {
					if i >= n { break }
					custom := i == len(platform.Cursor)
					c := custom ? platform.Cursor.Arrow : platform.Cursor(i)
					cell := new(Cell, ui.frame_allocator())
					cell.app = app
					cell.tex = custom ? app.custom_tex : app.previews[c]
					ui.next({width = ui.px(cell_w), height = ui.px(cell_h), cursor = c})
					if ui.tags("card") {
						b := ui.build_box({.Clickable, .Draw_Background, .Draw_Border}, fmt.tprintf("###cell%d", i))
						b.custom, b.custom_user = cell_draw, cell
						sig := ui.signal(b)
						if custom && sig.hovering { app.want_custom = true }
						if ui.parent(b) {
							ui.spacer(ui.px(f32(app.preview_px) + 12 * s))
							name := custom ? "url(target) 24 24" : platform.cursor_css_name(c)
							src := custom ? "custom image" : fmt.tprint(platform.cursor_source(c))
							ui.next({width = ui.fill(), height = ui.px(em * 1.3)})
							ui.label(fmt.tprintf("%s###n%d", name, i))
							ui.next({width = ui.fill(), height = ui.px(em * 1.2)})
							if ui.tags("weak") { ui.label(fmt.tprintf("%s###s%d", src, i)) }
						}
					}
					ui.spacer(ui.px(8 * s))
					i += 1
				}
			}
		}
	}
}

frame :: proc(app: ^App) {
	render.wait_for_frame(&app.r)
	events := platform.poll_events(app.win, false)
	render.mark_input(&app.r)
	if len(events) > 0 { app.frames = max(app.frames, 3) }
	render.resize(&app.r, app.win.size)
	make_previews(app)
	size := draw.Vec2{f32(app.win.size.x), f32(app.win.size.y)}
	now := time.tick_now()
	dt := clamp(f32(time.duration_seconds(time.tick_diff(app.last, now))), 0.0005, 0.1)
	app.last = now
	ui.apply_palette(&app.theme, ui.PALETTE_GRAPHITE)
	platform.set_dark_title(app.win, true)
	app.want_custom = false
	ui.begin_build(&app.ui_state, {
		window_size = size, events = events, dt = dt, animations = platform.os_animations_enabled(), dpi_scale = app.win.dpi_scale,
		base = {pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = app.ui_font, font_size = 14, text_pad = 6, cursor = .Arrow},
	})
	build_ui(app)
	ui.end_build()
	if app.want_custom {
		platform.set_cursor_custom(app.win, app.custom, .Crosshair)
	} else {
		platform.set_cursor(app.win, ui.cursor(&app.ui_state))
	}
	if ui.needs_frame(&app.ui_state) { app.frames = max(app.frames, 2) }
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, {0, 0, 0, 1})
	ui.draw_tree(&app.ui_state, &app.dc)
	draw.end_frame(&app.dc)
	render.frame_end(&app.r)
	free_all(context.temp_allocator)
}

main :: proc() {
	app := new(App)
	the_app = app
	for i := 1; i + 1 < len(os.args); i += 1 {
		if os.args[i] == "--preview" {
			if n, ok := strconv.parse_int(os.args[i + 1]); ok { app.forced_px = clamp(n, 16, 256) }
		}
	}
	font.init(&app.fonts)
	app.win = platform.open_window("gui_toolkit cursors", {1000, 720})
	if !render.init_window(&app.r, app.win, app.win.size) { fmt.eprintln("renderer init failed"); return }
	ok: bool
	app.ui_font, ok, _ = font.load_system_or_embedded(&app.fonts, platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
	if !ok { fmt.eprintln("cannot load a UI font"); return }
	draw.init(&app.dc, &app.r, &app.fonts)
	ui.init(&app.ui_state, &app.fonts, &app.theme)
	err: platform.Custom_Cursor_Error
	app.custom, err = platform.custom_cursor_create(app.win, target_image(48), {48, 48}, {24, 24})
	if err != .None { fmt.eprintln("custom cursor:", err) }
	app.last = time.tick_now()
	app.frames = 4
	app.win.user = app
	app.win.on_frame = proc(user: rawptr) { frame((^App)(user)) }
	platform.show_window(app.win)
	for !platform.is_closed(app.win) {
		if app.frames == 0 && !ui.needs_frame(&app.ui_state) { platform.wait_event(app.win, ui.wake_ms(&app.ui_state)) }
		frame(app)
		if app.frames > 0 { app.frames -= 1 }
	}
	platform.custom_cursor_release(app.win, app.custom)
}

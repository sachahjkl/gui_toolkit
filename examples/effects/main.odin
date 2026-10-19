// Effects demo (draw layer only, no UI): filter chains on layers (blur, color matrices, drop shadows), blend modes,
// backdrops (frosted glass), ellipse and polygon clips, glowing text.
//
//   build.bat effects
//   effects.exe [--time=SECONDS]     freeze the animation at that time (screenshots)
//               [--stress=N]         N blurred, shadowed cards over a frosted backdrop each, instead of the demo
//               [--bench=FRAMES]     print instance / layer / pass counts and CPU (and GPU with
//                                    -define:GPU_TIMING=true) times, then quit
//               [--srgb]             blend in sRGB as web browsers do (render.Blend_Space.Srgb), not in linear light
package effects

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

App :: struct {
	win:     ^platform.Window,
	r:       render.Renderer,
	fonts:   font.State,
	dc:      draw.Context,
	ui:      font.Font_Id,
	photo:   render.Texture,
	start:   time.Tick,
	freeze:  f32,
	stress:  int,
	bench_n: int,
	bench_build, bench_submit, bench_gpu: [dynamic]f32,
	frames:  int,
	space:   render.Blend_Space,
}

photo_pixel :: proc(x, y, w, h: int) -> [4]u8 {
	u, v := f32(x) / f32(w), f32(y) / f32(h)
	c := draw.hsv(u * 0.7 + v * 0.3, 0.65, 0.95)
	// a few discs and a diagonal bar
	for i in 0 ..< 7 {
		cx, cy := f32(i * 37 % 100) / 100, f32(i * 61 % 100) / 100
		if (u - cx) * (u - cx) + (v - cy) * (v - cy) < 0.012 { c = draw.hsv(f32(i) / 7, 0.8, 0.9) }
	}
	if abs(v - (1 - u)) < 0.02 { c = {0.02, 0.02, 0.05, 1} }
	enc :: proc(l: f32) -> u8 { s := l <= 0.0031308 ? l * 12.92 : 1.055 * math.pow(l, 1 / 2.4) - 0.055; return u8(clamp(s, 0, 1) * 255 + 0.5) }
	return {enc(c.r), enc(c.g), enc(c.b), 255}
}

make_texture :: proc(r: ^render.Renderer, w, h: int, pixel: proc(x, y, w, h: int) -> [4]u8) -> render.Texture {
	px := make([]u8, w * h * 4, context.temp_allocator)
	for y in 0 ..< h { for x in 0 ..< w { c := pixel(x, y, w, h); copy(px[(y * w + x) * 4:][:4], c[:]) } }
	t := render.create_texture_rgba(r, w, h)
	render.update_texture_rgba(r, t, 0, 0, w, h, px)
	return t
}

panel :: proc(app: ^App, r: draw.Rect, title: string, s: f32) -> draw.Rect {
	dc := &app.dc
	draw.rect(dc, r, draw.hex(0x171b2fff), 14 * s)
	draw.rect(dc, r, draw.hex(0x2b3150ff), 14 * s, max(1, math.round(s)))
	draw.text(dc, app.ui, 14 * s, {r.min.x + 14 * s, r.min.y + 24 * s}, draw.hex(0x9aa3c7ff), title)
	return {{r.min.x + 10 * s, r.min.y + 34 * s}, r.max - 10 * s}
}

// Colored blobs drifting: something busy behind the glass.
blobs :: proc(dc: ^draw.Context, r: draw.Rect, t, s: f32) {
	c := draw.rect_center(r)
	sz := draw.rect_size(r)
	for i in 0 ..< 6 {
		a := t * (0.3 + f32(i) * 0.07) + f32(i)
		p := c + {math.cos(a) * sz.x * 0.32, math.sin(a * 1.3) * sz.y * 0.3}
		rad := (26 + f32(i % 3) * 14) * s
		draw.rect(dc, {p - rad, p + rad}, draw.hsv(f32(i) / 6, 0.75, 0.95), rad)
	}
	for k in 0 ..< 8 {
		y := r.min.y + f32(k) * sz.y / 8
		draw.rect(dc, {{r.min.x, y}, {r.max.x, y + 3 * s}}, draw.Color{1, 1, 1, 0.5})
	}
}

demo :: proc(app: ^App, size: draw.Vec2, t: f32, s: f32) {
	dc := &app.dc
	draw.text(dc, app.ui, 22 * s, {24 * s, 40 * s}, draw.hex(0xe6e9f5ff), "gui_toolkit: filters, blend modes, backdrops, clip shapes")
	cols, rows := 3, 2
	m := 16 * s
	top := 60 * s
	cw := (size.x - m * f32(cols + 1)) / f32(cols)
	ch := (size.y - top - m * f32(rows + 1)) / f32(rows)
	cell :: proc(i: int, cols: int, m, top, cw, ch: f32) -> draw.Rect {
		x, y := f32(i % cols), f32(i / cols)
		p := draw.Vec2{m + x * (cw + m), top + m + y * (ch + m)}
		return {p, p + {cw, ch}}
	}
	// 1. filter functions, one per thumbnail
	{
		r := panel(app, cell(0, cols, m, top, cw, ch), "filters: push_effects(filters = ...)", s)
		names := [?]string{"blur", "grayscale", "sepia", "hue-rotate", "invert", "saturate", "contrast", "brightness"}
		fs := [?]draw.Filter{
			draw.filter_blur((2 + 2 * math.sin(t)) * s), draw.filter_grayscale(1), draw.filter_sepia(1),
			draw.filter_hue_rotate(t), draw.filter_invert(1), draw.filter_saturate(3), draw.filter_contrast(2), draw.filter_brightness(1.5),
		}
		tw := (draw.rect_size(r).x - 3 * 8 * s) / 4
		th := (draw.rect_size(r).y - 8 * s) / 2 - 18 * s
		for i in 0 ..< 8 {
			p := r.min + {f32(i % 4) * (tw + 8 * s), f32(i / 4) * (th + 26 * s)}
			box := draw.Rect{p, p + {tw, th}}
			one := [1]draw.Filter{fs[i]}
			draw.push_effects(dc, box, draw.Layer_Effects{alpha = 1, filters = one[:]})
			draw.image(dc, app.photo, box, {}, draw.WHITE, 8 * s)
			draw.pop_layer(dc)
			draw.text(dc, app.ui, 12 * s, {p.x, box.max.y + 15 * s}, draw.hex(0x9aa3c7ff), names[i])
		}
	}
	// 2. frosted glass: a backdrop, blurred and saturated, under a translucent rounded panel
	{
		r := panel(app, cell(1, cols, m, top, cw, ch), "backdrop: blur(12) saturate(1.6)", s)
		draw.push_clip_rounded(dc, r, {10 * s, 10 * s, 10 * s, 10 * s})
		blobs(dc, r, t, s)
		c := draw.rect_center(r)
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(0.08 * math.sin(t * 0.5)), c))
		glass := draw.Rect{c - {draw.rect_size(r).x * 0.3, draw.rect_size(r).y * 0.3}, c + {draw.rect_size(r).x * 0.3, draw.rect_size(r).y * 0.3}}
		rad := [4]f32{22 * s, 22 * s, 22 * s, 22 * s}
		bf := [2]draw.Filter{draw.filter_blur(12 * s), draw.filter_saturate(1.6)}
		draw.backdrop(dc, glass, rad, bf[:])
		draw.rect_corners(dc, glass, {draw.Color{1, 1, 1, 0.18}, draw.Color{1, 1, 1, 0.08}, draw.Color{1, 1, 1, 0.18}, draw.Color{1, 1, 1, 0.08}}, rad)
		draw.rect_corners(dc, glass, {draw.Color{1, 1, 1, 0.6}, draw.Color{1, 1, 1, 0.2}, draw.Color{1, 1, 1, 0.6}, draw.Color{1, 1, 1, 0.2}}, rad, 1.2 * s)
		draw.text(dc, app.ui, 18 * s, glass.min + {20 * s, 36 * s}, draw.hex(0xffffffff), "Frosted glass")
		draw.pop_transform(dc)
		draw.pop_clip(dc)
	}
	// 3. blend modes: the same gradient bar over the photo
	{
		r := panel(app, cell(2, cols, m, top, cw, ch), "blend modes", s)
		n := len(draw.Blend_Mode)
		cols2 := 6
		tw := (draw.rect_size(r).x - f32(cols2 - 1) * 6 * s) / f32(cols2)
		th := (draw.rect_size(r).y - 2 * 6 * s) / 3 - 14 * s
		for i in 0 ..< n {
			p := r.min + {f32(i % cols2) * (tw + 6 * s), f32(i / cols2) * (th + 20 * s)}
			box := draw.Rect{p, p + {tw, th}}
			draw.image(dc, app.photo, box, {}, draw.WHITE, 6 * s)
			inner := draw.rect_pad(box, -6 * s)
			draw.push_effects(dc, inner, draw.Layer_Effects{alpha = 1, blend = draw.Blend_Mode(i)})
			a, b := draw.hex(0xff922bff), draw.hex(0x5c7cfaff)
			draw.rect_corners(dc, inner, {a, a, b, b}, {6 * s, 6 * s, 6 * s, 6 * s})
			draw.pop_layer(dc)
			draw.text(dc, app.ui, 10 * s, {p.x, box.max.y + 11 * s}, draw.hex(0x9aa3c7ff), fmt.tprintf("%v", draw.Blend_Mode(i)))
		}
	}
	// 4. drop shadow of a shape with holes (alpha), blurred and moving
	{
		r := panel(app, cell(3, cols, m, top, cw, ch), "drop shadow (alpha shape)", s)
		c := draw.rect_center(r)
		off := draw.Vec2{math.cos(t) * 14, 10 + math.sin(t) * 6} * s
		sh := [1]draw.Filter{draw.filter_drop_shadow(off, 6 * s, draw.Color{0, 0, 0.05, 0.7})}
		bounds := draw.Rect{c - 90 * s, c + 90 * s}
		draw.push_effects(dc, bounds, draw.Layer_Effects{alpha = 1, filters = sh[:]})
		draw.rect(dc, {c - {80 * s, 30 * s}, c + {-10 * s, 30 * s}}, draw.hex(0xff6b6bff), 30 * s)
		draw.rect(dc, {c + {10 * s, -40 * s}, c + {90 * s, 40 * s}}, draw.hex(0x339af0ff), 40 * s, 12 * s)
		draw.text(dc, app.ui, 22 * s, c + {-70 * s, 8 * s}, draw.hex(0xffffffff), "Wren")
		draw.pop_layer(dc)
	}
	// 5. clip shapes: an ellipse and a star (nonzero / even-odd), rotating
	{
		r := panel(app, cell(4, cols, m, top, cw, ch), "push_clip_ellipse / push_clip_polygon", s)
		sz := draw.rect_size(r)
		for k in 0 ..< 3 {
			c := r.min + {sz.x * (f32(k) + 0.5) / 3, sz.y * 0.5}
			rad := min(sz.x / 6, sz.y / 2) * 0.9
			draw.push_transform(dc, draw.affine_around(draw.affine_rotate(t * 0.4 * f32(k - 1)), c))
			if k == 0 {
				draw.push_clip_ellipse(dc, c, {rad, rad * 0.6})
			} else {
				pts: [5]draw.Vec2
				for i in 0 ..< 5 {
					a := -math.PI / 2 + f32(i) * 4 * math.PI / 5
					pts[i] = c + {math.cos(a), math.sin(a)} * rad
				}
				draw.push_clip_polygon(dc, pts[:], k == 2)
			}
			draw.image(dc, app.photo, {c - rad, c + rad})
			draw.pop_clip(dc)
			draw.pop_transform(dc)
			draw.text(dc, app.ui, 12 * s, {c.x - 30 * s, r.max.y - 4 * s}, draw.hex(0x9aa3c7ff), k == 0 ? "ellipse" : (k == 1 ? "nonzero" : "even-odd"))
		}
	}
	// 6. glow: the text drawn twice, the copy behind blurred in a layer; a layer with opacity and a blur together
	{
		r := panel(app, cell(5, cols, m, top, cw, ch), "glow, blur + opacity", s)
		c := draw.rect_center(r)
		label := "Glow"
		size_px := 54 * s
		w := font.text_width(&app.fonts, app.ui, size_px, label)
		pos := draw.Vec2{c.x - w * 0.5, c.y}
		g := [1]draw.Filter{draw.filter_blur((5 + 3 * math.sin(t * 2)) * s)}
		draw.push_effects(dc, {pos - {0, size_px}, pos + {w, size_px * 0.3}}, draw.Layer_Effects{alpha = 1, filters = g[:]})
		draw.text(dc, app.ui, size_px, pos, draw.hex(0x4dabf7ff), label)
		draw.pop_layer(dc)
		draw.text(dc, app.ui, size_px, pos, draw.hex(0xffffffff), label)
	}
}

stress :: proc(app: ^App, size: draw.Vec2, t: f32, s: f32) {
	dc := &app.dc
	blobs(dc, {{0, 0}, size}, t, s * 4)
	n := app.stress
	cols := max(1, int(math.sqrt(f32(n) * size.x / size.y)))
	cw := size.x / f32(cols)
	ch := cw * 0.6
	fl := [2]draw.Filter{draw.filter_drop_shadow({0, 4 * s}, 4 * s, {0, 0, 0, 0.5}), draw.filter_sepia(0.4)}
	bf := [1]draw.Filter{draw.filter_blur(10 * s)}
	for i in 0 ..< n {
		c := draw.Vec2{(f32(i % cols) + 0.5) * cw, (f32(i / cols) + 0.5) * ch}
		r := draw.Rect{c - draw.Vec2{cw, ch} * 0.38, c + draw.Vec2{cw, ch} * 0.38}
		draw.backdrop(dc, r, {8 * s, 8 * s, 8 * s, 8 * s}, bf[:])
		draw.push_effects(dc, r, draw.Layer_Effects{alpha = 0.9, filters = fl[:]})
		draw.rect(dc, draw.rect_pad(r, -6 * s), draw.Color{1, 1, 1, 0.25}, 6 * s)
		draw.text(dc, app.ui, 12 * s, {r.min.x + 10 * s, c.y + 4 * s}, draw.hex(0xffffffff), fmt.tprintf("#%d", i))
		draw.pop_layer(dc)
	}
}

frame :: proc(app: ^App) {
	render.resize(&app.r, app.win.size)
	size := draw.Vec2{f32(app.win.size.x), f32(app.win.size.y)}
	s := app.win.dpi_scale
	t := app.freeze >= 0 ? app.freeze : f32(time.duration_seconds(time.tick_since(app.start)))
	t0 := time.tick_now()
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, draw.hex(0x0f1220ff))
	if app.stress > 0 { stress(app, size, t, s) } else { demo(app, size, t, s) }
	t1 := time.tick_now()
	draw.end_frame(&app.dc)
	t2 := time.tick_now()
	render.frame_end(&app.r)
	app.frames += 1
	if app.bench_n > 0 && app.frames > 30 {
		append(&app.bench_build, f32(time.duration_milliseconds(time.tick_diff(t0, t1))))
		append(&app.bench_submit, f32(time.duration_milliseconds(time.tick_diff(t1, t2))))
		append(&app.bench_gpu, render.gpu_ms(&app.r))
		if len(app.bench_build) >= app.bench_n { bench_report(app) }
	}
	free_all(context.temp_allocator)
}

bench_report :: proc(app: ^App) {
	med :: proc(v: []f32) -> f32 { slice.sort(v); return v[len(v) / 2] }
	passes := 0
	for op in app.dc.ops { if op.kind == .Pass { passes += 1 } }
	fmt.printf("insts=%d batches=%d layers=%d passes=%d targets=%d (%.1f MB) | draw calls (CPU) p50=%.3f ms | end_frame p50=%.3f ms | GPU p50=%.3f ms\n",
		len(app.dc.insts), len(app.dc.batches), len(app.dc.layers), passes, len(app.r.targets), f32(render.targets_bytes(&app.r)) / (1 << 20),
		med(app.bench_build[:]), med(app.bench_submit[:]), med(app.bench_gpu[:]))
	os.exit(0)
}

main :: proc() {
	app := new(App)
	app.freeze = -1
	for a in os.args[1:] {
		if strings.has_prefix(a, "--time=") { if v, ok := strconv.parse_f32(a[7:]); ok { app.freeze = v } }
		if strings.has_prefix(a, "--stress=") { if v, ok := strconv.parse_int(a[9:]); ok { app.stress = v } }
		if strings.has_prefix(a, "--bench=") { if v, ok := strconv.parse_int(a[8:]); ok { app.bench_n = v } }
		if a == "--srgb" { app.space = .Srgb }
	}
	font.init(&app.fonts)
	app.win = platform.open_window("gui_toolkit effects", {1280, 820}, app)
	if !render.init(&app.r, app.win.hwnd, app.win.size, space = app.space) { fmt.eprintln("renderer init failed"); return }
	id, ok, _ := font.load_system_or_embedded(&app.fonts, platform.system_font_path("segoeuib.ttf"), font.FALLBACK_UI_DATA)
	if !ok { fmt.eprintln("font load failed"); return }
	app.ui = id
	draw.init(&app.dc, &app.r, &app.fonts)
	render.set_corner_smoothing(&app.r, 0)
	app.photo = make_texture(&app.r, 256, 160, photo_pixel)
	free_all(context.temp_allocator)
	app.start = time.tick_now()
	app.win.on_frame = proc(user: rawptr) { frame((^App)(user)) }
	platform.show_window(app.win)
	for !platform.is_closed(app.win) {
		platform.poll_events(app.win, wait = app.freeze >= 0 && app.frames > 2 && app.bench_n == 0)
		frame(app)
	}
}

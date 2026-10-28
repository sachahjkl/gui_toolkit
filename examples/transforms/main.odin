// Transforms and images demo (draw layer only, no UI): rounded rects, borders, shadows, gradients, text and images
// rotated, skewed and scaled with draw.push_transform; rounded clips (draw.push_clip_rounded); tiled and mipmapped
// images (render.create_texture_rgba, draw.image, draw.image_tiled).
//
//   build.bat transforms
//   transforms.exe [--time=SECONDS]     freeze the animation at that time (screenshots)
//                  [--stress=N]         N rotated cards (shape + border + text + image each) instead of the demo
//                  [--flat]             with --stress: no rotation (the CPU-baked path), for comparison
//                  [--retained]         with --stress: the cards are recorded once into a draw.Picture; each frame
//                                       changes their transform slots and replays it (CPU cost: the slots only)
//                  [--bench=FRAMES]     print instance / batch counts and CPU (and GPU with
//                                       -define:GPU_TIMING=true) times, then quit
//                  [--srgb]             blend in sRGB as web browsers do (render.Blend_Space.Srgb), not in linear light
package transforms

import "core:fmt"
import "core:image"
import "core:image/png"
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

LOGO_PNG :: #load("../../.project/image.png")

App :: struct {
	win:     ^platform.Window,
	r:       render.Renderer,
	fonts:   font.State,
	dc:      draw.Context,
	ui:      font.Font_Id,
	photo:   render.Texture,   // 512 x 512 opaque, fine rings: shows mip filtering when minified
	sticker: render.Texture,   // 64 x 64 with soft alpha over black transparent pixels: shows premultiplied filtering
	checker: render.Texture,   // 32 x 32 tile for image_tiled
	logo:    render.Texture,   // decoded from a PNG with core:image/png
	start:   time.Tick,
	freeze:  f32,              // < 0: live animation
	stress:  int,
	flat:    bool,
	bench_n: int,
	bench_build, bench_submit, bench_gpu: [dynamic]f32,
	frames:  int,
	space:   render.Blend_Space,
	retained: bool,             // --retained: the stress cards are a picture whose slots turn
	pic:     draw.Picture,
	slots:   [dynamic]u32,
	pic_size: draw.Vec2,
	pic_scale: f32,
}

////////////////////////////////
// Procedural test images (RGBA8, sRGB, straight alpha: what update_texture_rgba expects)

hsv_bytes :: proc(h, s, v: f32) -> [3]u8 {
	hh := (h - math.floor(h)) * 6
	i := int(hh)
	f := hh - f32(i)
	p, q, t := v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
	c: [3]f32
	switch i {
	case 0: c = {v, t, p}
	case 1: c = {q, v, p}
	case 2: c = {p, v, t}
	case 3: c = {p, q, v}
	case 4: c = {t, p, v}
	case: c = {v, p, q}
	}
	return {u8(c.x * 255 + 0.5), u8(c.y * 255 + 0.5), u8(c.z * 255 + 0.5)}
}

make_texture :: proc(r: ^render.Renderer, w, h: int, pixel: proc(x, y, w, h: int) -> [4]u8) -> render.Texture {
	px := make([]u8, w * h * 4, context.temp_allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			c := pixel(x, y, w, h)
			copy(px[(y * w + x) * 4:][:4], c[:])
		}
	}
	t := render.create_texture_rgba(r, w, h)
	render.update_texture_rgba(r, t, 0, 0, w, h, px)
	return t
}

photo_pixel :: proc(x, y, w, h: int) -> [4]u8 {
	u, v := (f32(x) + 0.5) / f32(w) - 0.5, (f32(y) + 0.5) / f32(h) - 0.5
	d := math.sqrt(u * u + v * v)
	c := hsv_bytes(math.atan2(v, u) / math.TAU + d * 0.8, 0.55, 0.95)
	// fine rings (period ~5 texels): turn into moire when minified without mips
	ring := 0.5 + 0.5 * math.sin(d * 640)
	k := 0.62 + 0.38 * ring
	// a 1-texel white grid every 64 texels
	if x % 64 == 0 || y % 64 == 0 { return {255, 255, 255, 255} }
	return {u8(f32(c.x) * k), u8(f32(c.y) * k), u8(f32(c.z) * k), 255}
}

sticker_pixel :: proc(x, y, w, h: int) -> [4]u8 {
	u, v := (f32(x) + 0.5) / f32(w) - 0.5, (f32(y) + 0.5) / f32(h) - 0.5
	d := math.sqrt(u * u + v * v)
	a := clamp((0.42 - d) * 30, 0, 1)
	if a <= 0 { return {0, 0, 0, 0} }   // black transparent texels: a straight-alpha filter would leak dark fringes
	star := 0.5 + 0.5 * math.cos(math.atan2(v, u) * 5)
	if d < 0.12 + 0.18 * star { return {255, 214, 10, u8(a * 255)} }
	return {230, 40, 90, u8(a * 255)}
}

checker_pixel :: proc(x, y, w, h: int) -> [4]u8 {
	if (x / (w / 2) + y / (h / 2)) % 2 == 0 { return {44, 62, 120, 255} }
	dx, dy := f32(x % (w / 2)) - f32(w / 4) + 0.5, f32(y % (h / 2)) - f32(h / 4) + 0.5
	if dx * dx + dy * dy < f32(w * w) / 100 { return {255, 180, 60, 255} }
	return {226, 232, 245, 255}
}

load_logo :: proc(r: ^render.Renderer) -> render.Texture {
	img: ^image.Image
	err: image.Error
	img, err = png.load_from_bytes(LOGO_PNG, {.alpha_add_if_missing})
	if err != nil || img.depth != 8 || img.channels != 4 {
		if img != nil { png.destroy(img) }
		return 0
	}
	defer png.destroy(img)
	t := render.create_texture_rgba(r, img.width, img.height)
	render.update_texture_rgba(r, t, 0, 0, img.width, img.height, img.pixels.buf[:])
	return t
}

////////////////////////////////
// Demo

// A demo cell: background, caption; returns the content area.
panel :: proc(app: ^App, r: draw.Rect, title: string, s: f32) -> draw.Rect {
	dc := &app.dc
	draw.rect(dc, r, draw.hex(0x171b2fff), 14 * s)
	draw.rect(dc, r, draw.hex(0x2b3150ff), 14 * s, max(1, math.round(s)))
	draw.text(dc, app.ui, 14 * s, {r.min.x + 14 * s, r.min.y + 24 * s}, draw.hex(0x9aa3c7ff), title)
	return {{r.min.x, r.min.y + 32 * s}, r.max}
}

// A card: drop shadow, vertical gradient, border, title, image.
card :: proc(app: ^App, c: draw.Vec2, s: f32, label: string, tex: render.Texture) {
	dc := &app.dc
	half := draw.Vec2{110, 70} * s
	r := draw.Rect{c - half, c + half}
	rad := 16 * s
	draw.rect(dc, draw.rect_shift(draw.rect_pad(r, 10 * s), {0, 6 * s}), draw.srgb(0, 0, 0, 0.55), rad + 10 * s, 0, 10 * s)
	top, bot := draw.hex(0x7c8cffff), draw.hex(0x4b5bd8ff)
	draw.rect_corners(dc, r, {top, bot, top, bot}, {rad, rad, rad, rad})
	draw.rect(dc, r, draw.hex(0xffffff60), rad, 1.5 * s)
	draw.text(dc, app.ui, 17 * s, {r.min.x + 16 * s, r.min.y + 32 * s}, draw.hex(0xffffffff), label)
	draw.text(dc, app.ui, 12 * s, {r.min.x + 16 * s, r.min.y + 54 * s}, draw.hex(0xdfe4ffff), "rounded, bordered, shadowed")
	img := draw.Rect{{r.min.x + 16 * s, r.max.y - 58 * s}, {r.min.x + 58 * s, r.max.y - 16 * s}}
	draw.image(dc, tex, img, {}, draw.WHITE, 8 * s)
	draw.rect(dc, {{img.max.x + 10 * s, img.min.y + 8 * s}, {r.max.x - 16 * s, img.min.y + 18 * s}}, draw.hex(0xffffff80), 5 * s)
	draw.rect(dc, {{img.max.x + 10 * s, img.min.y + 26 * s}, {r.max.x - 50 * s, img.min.y + 36 * s}}, draw.hex(0xffffff50), 5 * s)
}

demo :: proc(app: ^App, size: draw.Vec2, t: f32, s: f32) {
	dc := &app.dc
	draw.text(dc, app.ui, 22 * s, {24 * s, 40 * s}, draw.hex(0xe6e9f5ff), "gui_toolkit: affine transforms and images")
	cols, rows := 4, 2
	m := 16 * s
	top := 60 * s
	cw := (size.x - m * f32(cols + 1)) / f32(cols)
	ch := (size.y - top - m * f32(rows + 1)) / f32(rows)
	cell :: proc(i: int, cols: int, m, top, cw, ch: f32) -> draw.Rect {
		x, y := f32(i % cols), f32(i / cols)
		p := draw.Vec2{m + x * (cw + m), top + m + y * (ch + m)}
		return {p, p + {cw, ch}}
	}

	// 1. rotation
	{
		r := panel(app, cell(0, cols, m, top, cw, ch), "rotate()", s)
		c := draw.rect_center(r)
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(t * 0.5), c))
		card(app, c, s, "Rotated card", app.logo)
		draw.pop_transform(dc)
	}
	// 2. skew
	{
		r := panel(app, cell(1, cols, m, top, cw, ch), "skew()", s)
		c := draw.rect_center(r)
		draw.push_transform(dc, draw.affine_around(draw.affine_skew(math.sin(t * 0.9) * 0.5, 0), c))
		card(app, c, s, "Skewed card", app.checker)
		draw.pop_transform(dc)
	}
	// 3. scaled text: re-rasterized at the screen size (sharp), layout unchanged
	{
		r := panel(app, cell(2, cols, m, top, cw, ch), "scale() on text", s)
		c := draw.rect_center(r)
		k := math.pow(f32(5), 0.5 + 0.5 * math.sin(t * 0.7)) * 0.6   // 0.6 .. 3
		draw.push_transform(dc, draw.affine_around(draw.affine_scale({k, k}), c))
		w := font.text_width(&app.fonts, app.ui, 16 * s, "Scaled text")
		draw.text(dc, app.ui, 16 * s, {c.x - w * 0.5, c.y + 5 * s}, draw.hex(0xffffffff), "Scaled text")
		draw.pop_transform(dc)
		draw.text(dc, app.ui, 13 * s, {r.min.x + 14 * s, r.max.y - 14 * s}, draw.hex(0x9aa3c7ff), fmt.tprintf("x%.2f", k))
	}
	// 4. minified + rotated photo with rounded corners (mipmaps)
	{
		r := panel(app, cell(3, cols, m, top, cw, ch), "image, mipmapped", s)
		c := draw.rect_center(r)
		k := 0.25 + 0.75 * (0.5 + 0.5 * math.sin(t * 0.6))
		draw.push_transform(dc, draw.affine_around(draw.affine_mul(draw.affine_rotate(-t * 0.3), draw.affine_scale({k, k})), c))
		half := min(draw.rect_size(r).x, draw.rect_size(r).y) * 0.3
		draw.image(dc, app.photo, {c - half, c + half}, {}, draw.WHITE, 28 * s)
		draw.pop_transform(dc)
	}
	// 5. tiled image, rotated and scrolling, inside a rounded clip
	{
		r := panel(app, cell(4, cols, m, top, cw, ch), "image_tiled + clip", s)
		inner := draw.rect_pad(r, -14 * s)
		inner.min.y += 4 * s
		draw.push_clip_rounded(dc, inner, {24 * s, 24 * s, 24 * s, 24 * s})
		c := draw.rect_center(inner)
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(0.35), c))
		big := draw.rect_pad(inner, draw.rect_size(inner).x * 0.4)
		off := draw.Vec2{t * 30 * s, t * 12 * s}
		tile := draw.Rect{c + off, c + off + {48 * s, 48 * s}}
		draw.image_tiled(dc, app.checker, big, tile)
		draw.pop_transform(dc)
		draw.pop_clip(dc)
	}
	// 6. rounded clip in a rotated frame: content rotates inside, the clip edge stays antialiased
	{
		r := panel(app, cell(5, cols, m, top, cw, ch), "push_clip_rounded", s)
		c := draw.rect_center(r)
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(-0.25 + 0.15 * math.sin(t * 0.5)), c))
		box := draw.Rect{c - {95 * s, 95 * s}, c + {95 * s, 95 * s}}
		rad := [4]f32{60 * s, 12 * s, 12 * s, 60 * s}
		draw.rect_corners(dc, draw.rect_pad(box, 6 * s), {draw.hex(0x000000a0), draw.hex(0x000000a0), draw.hex(0x000000a0), draw.hex(0x000000a0)}, rad + 6 * s, 0, 6 * s)
		draw.push_clip_rounded(dc, box, rad)
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(t), c))
		draw.image(dc, app.photo, draw.rect_pad(box, 40 * s))
		draw.text(dc, app.ui, 20 * s, {c.x - 60 * s, c.y + 7 * s}, draw.hex(0x000000ff), "clipped text")
		draw.pop_transform(dc)
		draw.pop_clip(dc)
		draw.rect_corners(dc, box, {draw.hex(0xffffffff), draw.hex(0xffffffff), draw.hex(0xffffffff), draw.hex(0xffffffff)}, rad, 2 * s)
		draw.pop_transform(dc)
	}
	// 7. nested transforms: orbits
	{
		r := panel(app, cell(6, cols, m, top, cw, ch), "nested transforms + push_layer", s)
		c := draw.rect_center(r)
		draw.rect(dc, {c - 30 * s, c + 30 * s}, draw.hex(0xffb020ff), 30 * s)
		draw.rect(dc, {c - 46 * s, c + 46 * s}, draw.hex(0xffb02060), 46 * s, 0, 14 * s)
		draw.rect(dc, {c - 100 * s, c + 100 * s}, draw.hex(0xffffff30), 100 * s, 1.2 * s)
		draw.push_transform(dc, draw.affine_mul(draw.affine_translate(c), draw.affine_rotate(t * 0.8)))
		draw.push_transform(dc, draw.affine_mul(draw.affine_translate({100 * s, 0}), draw.affine_rotate(t * 2)))
		// the planet and its moon fade as one group: the ring does not show through the planet
		draw.push_layer(dc, {-50 * s, 50 * s}, 0.55 + 0.45 * math.sin(t * 1.3))
		draw.rect(dc, {-14 * s, 14 * s}, draw.hex(0x4ade80ff), 5 * s)
		draw.rect(dc, {-14 * s, 14 * s}, draw.hex(0x0b3d1cff), 5 * s, 1.5 * s)
		draw.rect(dc, {-36 * s, 36 * s}, draw.hex(0xffffff30), 36 * s, 1 * s)
		draw.push_transform(dc, draw.affine_mul(draw.affine_translate({36 * s, 0}), draw.affine_rotate(-t * 4)))
		draw.image(dc, app.sticker, {-10 * s, 10 * s})
		draw.pop_transform(dc)
		draw.pop_layer(dc)
		draw.pop_transform(dc)
		draw.pop_transform(dc)
	}
	// 8. static references: 1x text (pixel-snapped), scale(2.5) text, vertical text, magnified sticker
	{
		r := panel(app, cell(7, cols, m, top, cw, ch), "static: 1x / 2.5x / 90 deg", s)
		p := r.min + {14 * s, 30 * s}
		draw.text(dc, app.ui, 15 * s, p, draw.hex(0xe6e9f5ff), "Plain text at 1x")
		draw.push_transform(dc, draw.affine_mul(draw.affine_translate(p + {0, 28 * s}), draw.affine_scale({2.5, 2.5})))
		draw.text(dc, app.ui, 15 * s, {0, 15 * s}, draw.hex(0xe6e9f5ff), "Big 2.5x")
		draw.pop_transform(dc)
		draw.push_transform(dc, draw.affine_mul(draw.affine_translate({r.max.x - 20 * s, r.max.y - 16 * s}), draw.affine_rotate(-math.PI / 2)))
		draw.text(dc, app.ui, 15 * s, {0, 0}, draw.hex(0xe6e9f5ff), "vertical text")
		draw.pop_transform(dc)
		sq := draw.Rect{{r.min.x + 14 * s, r.max.y - 120 * s}, {r.min.x + 120 * s, r.max.y - 14 * s}}
		draw.rect(dc, draw.rect_pad(sq, 6 * s), draw.hex(0xf2f2f2ff), 8 * s)
		draw.image(dc, app.sticker, sq)   // 64 texels magnified: no dark fringe around the soft edge
	}
}

stress :: proc(app: ^App, size: draw.Vec2, t: f32, s: f32) {
	dc := &app.dc
	n := app.stress
	cols := max(1, int(math.sqrt(f32(n) * size.x / size.y)))
	cw := size.x / f32(cols)
	ch := cw * 0.6
	center :: proc(i, cols: int, cw, ch: f32) -> draw.Vec2 { return {(f32(i % cols) + 0.5) * cw, (f32(i / cols) + 0.5) * ch} }
	spin :: proc(app: ^App, i: int, c: draw.Vec2, t: f32) -> draw.Affine {
		return app.flat ? draw.AFFINE_IDENTITY : draw.affine_around(draw.affine_rotate(t + f32(i) * 0.1), c)
	}
	if app.retained {
		// recorded once (and when the window changes size); each frame only the cards' slots change
		if app.pic_size != size || app.pic_scale != s || len(app.slots) != n {
			app.pic_size, app.pic_scale = size, s
			resize(&app.slots, n)
			draw.picture_begin(dc, &app.pic)
			for i in 0 ..< n {
				c := center(i, cols, cw, ch)
				draw.push_transform(dc, spin(app, i, c, t))
				app.slots[i] = draw.current_slot(dc)
				stress_card(app, c, cw, ch, s, i)
				draw.pop_transform(dc)
			}
			draw.picture_end(dc)
		}
		if !app.flat {
			for i in 0 ..< n { draw.picture_set_slot(&app.pic, app.slots[i], spin(app, i, center(i, cols, cw, ch), t)) }
		}
		if draw.replay(dc, &app.pic, draw.AFFINE_IDENTITY) == .Stale { app.pic_size = {} }   // recorded again next frame
		return
	}
	for i in 0 ..< n {
		c := center(i, cols, cw, ch)
		if !app.flat { draw.push_transform(dc, spin(app, i, c, t)) }
		stress_card(app, c, cw, ch, s, i)
		if !app.flat { draw.pop_transform(dc) }
	}
}

stress_card :: proc(app: ^App, c: draw.Vec2, cw, ch, s: f32, i: int) {
	dc := &app.dc
	r := draw.Rect{c - {cw, ch} * 0.4, c + {cw, ch} * 0.4}
	draw.rect(dc, r, draw.hex(0x3b4a9aff), 6 * s)
	draw.rect(dc, r, draw.hex(0xffffff70), 6 * s, 1 * s)
	draw.image(dc, app.checker, {r.min + 4 * s, r.min + 4 * s + ch * 0.4}, {}, draw.WHITE, 3 * s)
	draw.text(dc, app.ui, 11 * s, {r.min.x + ch * 0.5, c.y + 4 * s}, draw.hex(0xffffffff), fmt.tprintf("#%d", i))
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
	used, _ := draw.retained_bytes(&app.dc)
	fmt.printf("insts=%d batches=%d xforms=%d clips=%d inst_bytes=%d retained=%d (%d bytes) | draw calls (CPU) p50=%.3f ms | end_frame (upload + submit) p50=%.3f ms | GPU p50=%.3f ms\n",
		len(app.dc.insts), len(app.dc.batches), len(app.dc.xform_table) - 1, len(app.dc.clip_table) - 1, size_of(render.Rect_Inst),
		draw.picture_size(&app.pic), used, med(app.bench_build[:]), med(app.bench_submit[:]), med(app.bench_gpu[:]))
	os.exit(0)
}

main :: proc() {
	app := new(App)
	app.freeze = -1
	for a in os.args[1:] {
		if strings.has_prefix(a, "--time=") { if v, ok := strconv.parse_f32(a[7:]); ok { app.freeze = v } }
		if strings.has_prefix(a, "--stress=") { if v, ok := strconv.parse_int(a[9:]); ok { app.stress = v } }
		if strings.has_prefix(a, "--bench=") { if v, ok := strconv.parse_int(a[8:]); ok { app.bench_n = v } }
		if a == "--flat" { app.flat = true }
		if a == "--retained" { app.retained = true }
		if a == "--srgb" { app.space = .Srgb }
	}
	font.init(&app.fonts)
	app.win = platform.open_window("gui_toolkit transforms", {1280, 820}, app)
	if !render.init_window(&app.r, app.win, app.win.size, space = app.space) { fmt.eprintln("renderer init failed"); return }
	id, ok, _ := font.load_system_or_embedded(&app.fonts, platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
	if !ok { fmt.eprintln("font load failed"); return }
	app.ui = id
	draw.init(&app.dc, &app.r, &app.fonts)
	render.set_corner_smoothing(&app.r, 0)   // circular corners: the orbits are circles
	app.photo = make_texture(&app.r, 512, 512, photo_pixel)
	app.sticker = make_texture(&app.r, 64, 64, sticker_pixel)
	app.checker = make_texture(&app.r, 32, 32, checker_pixel)
	app.logo = load_logo(&app.r)
	if app.logo == 0 { app.logo = app.sticker }
	free_all(context.temp_allocator)
	app.start = time.tick_now()
	app.win.on_frame = proc(user: rawptr) { frame((^App)(user)) }
	platform.show_window(app.win)

	for !platform.is_closed(app.win) {
		platform.poll_events(app.win, wait = app.freeze >= 0 && app.frames > 2 && app.bench_n == 0)
		frame(app)
	}
}

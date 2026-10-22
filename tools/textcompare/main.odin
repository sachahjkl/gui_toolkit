// Atlas text against Slug text, side by side: renders the same scenes with both renderers on an offscreen target and
// writes PNGs (atlas | Slug | difference) plus numbers (pixel difference, CPU time per frame, GPU time, memory).
//   odin run tools/textcompare -- -out <dir> [-dpr 1.75] [-space srgb|linear] [-warp] [-frames 300] [-scene name]
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import stbi "vendor:stb/image"
import "../../draw"
import "../../font"
import "../../render"

Scene :: struct {
	name: string,
	size: [2]int,   // CSS pixels
	zoom: f32,      // extra scale on top of dpr
	body: proc(c: ^draw.Context, ui, mono: font.Font_Id),
}

INK :: draw.Color{0.02, 0.02, 0.02, 1}
LINK :: draw.Color{0.0, 0.05, 0.6, 1}

PARA := [?]string{
	"The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.",
	"Sphinx of black quartz, judge my vow: 0123456789 {}[]() <html lang=\"en\"> & @#%",
	"Typography is the craft of endowing human language with a durable visual form.",
}

scene_page :: proc(c: ^draw.Context, ui, mono: font.Font_Id) {
	y: f32 = 20
	for size in ([?]f32{12, 13, 14, 15, 16}) {
		for p in PARA {
			draw.text(c, ui, size, {10, y}, INK, p)
			y += size * 1.4
		}
		y += 6
	}
	draw.text(c, mono, 13, {10, y}, INK, "fn main() { println!(\"Hello, wörld\"); } // monospace 13")
	y += 20
	draw.text(c, ui, 14, {10, y}, LINK, "A link in blue, underlined by the page, 14 px.")
}

scene_titles :: proc(c: ^draw.Context, ui, mono: font.Font_Id) {
	y: f32 = 36
	for size in ([?]f32{20, 24, 32, 48, 72}) {
		draw.text(c, ui, size, {10, y}, INK, "Hamburgefonstiv Qgj 123")
		y += size * 1.25
	}
}

scene_transforms :: proc(c: ^draw.Context, ui, mono: font.Font_Id) {
	draw.push_transform(c, draw.affine_around(draw.affine_rotate(0.21), {160, 100}))
	draw.text(c, ui, 14, {20, 40}, INK, "Rotated 12 degrees, 14 px: sharp?")
	draw.text(c, ui, 22, {20, 80}, INK, "Rotated, 22 px sans")
	draw.text(c, mono, 13, {20, 110}, INK, "monospace rotated 13 px")
	draw.pop_transform(c)
	draw.push_transform(c, draw.affine_mul(draw.affine_translate({20, 240}), draw.affine_mul(draw.affine_skew(-0.3), draw.affine_scale({1.4, 0.8}))))
	draw.text(c, ui, 18, {0, 0}, INK, "Skewed and squeezed text")
	draw.pop_transform(c)
	draw.push_transform(c, draw.affine_around(draw.affine_rotate(-1.5708), {300, 200}))
	draw.text(c, ui, 16, {220, 200}, LINK, "Quarter turn")
	draw.pop_transform(c)
}

DENSE := "It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of foolishness, it was the epoch of belief, it was the epoch of incredulity, it was the season of Light, it was the season of Darkness, it was the spring of hope, it was the winter of despair, we had everything before us, we had nothing before us"

// a full window of body text: the cost of many glyphs
scene_dense :: proc(c: ^draw.Context, ui, mono: font.Font_Id) {
	line := 0
	for y: f32 = 16; y < 790; y += 19 {
		off := (line * 37) % 120
		draw.text(c, ui, 14, {10, y}, INK, DENSE[off:min(off + 150, len(DENSE))])
		draw.text(c, ui, 14, {510, y}, INK, DENSE[(off + 40) % 120:][:min(150, len(DENSE) - (off + 40) % 120)])
		line += 1
	}
}

scene_tree :: proc(c: ^draw.Context, ui, mono: font.Font_Id) {
	// a history tree: small labels on nodes joined by lines
	for row in 0 ..< 6 {
		for col in 0 ..< 3 {
			x, y := f32(10 + col * 120), f32(14 + row * 26)
			draw.rect(c, {{x, y - 10}, {x + 108, y + 8}}, draw.Color{0.9, 0.93, 1, 1}, 3)
			draw.text(c, ui, 10, {x + 4, y + 3}, INK, fmt.tprintf("node %d.%d wren.dev/a", row, col))
		}
	}
}

SCENES := [?]Scene{
	{"page", {420, 300}, 1, scene_page},
	{"titles", {420, 330}, 1, scene_titles},
	{"transforms", {420, 300}, 1, scene_transforms},
	{"zoom300", {420, 110}, 3, scene_page_zoom},
	{"tree", {420, 170}, 1, scene_tree},
	{"tree_zoom", {420, 170}, 2.2, scene_tree},
	{"dense", {1000, 800}, 1, scene_dense},
}

scene_page_zoom :: proc(c: ^draw.Context, ui, mono: font.Font_Id) {
	draw.text(c, ui, 16, {4, 20}, INK, "Page zoom 300%: 16 px text")
	draw.text(c, ui, 12, {4, 36}, INK, "twelve pixels, zoomed")
}

Rig :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
	ui, mono: font.Font_Id,
}

rig_open :: proc(g: ^Rig, size: [2]int, space: render.Blend_Space, warp: bool, slug: bool) -> bool {
	if !render.init_offscreen(&g.r, size, warp, space) { return false }
	st := font.DEFAULT_SETTINGS
	st.text_renderer = slug ? .Slug : .Atlas
	font.init(&g.fonts, st)
	ok1, ok2: bool
	g.ui, ok1 = font.load_system(&g.fonts, "Segoe UI")
	g.mono, ok2 = font.load_system(&g.fonts, "Consolas")
	draw.init(&g.dc, &g.r, &g.fonts)
	return ok1 && ok2
}

rig_close :: proc(g: ^Rig) { draw.destroy(&g.dc); render.destroy(&g.r); font.destroy(&g.fonts) }

render_scene :: proc(g: ^Rig, s: Scene, dpr: f32) -> []u8 {
	scale := dpr * s.zoom
	size := [2]f32{f32(s.size.x) * dpr, f32(s.size.y) * dpr}
	draw.begin_frame(&g.dc, size)
	render.frame_begin(&g.r, {1, 1, 1, 1})
	draw.push_scale(&g.dc, {0, 0}, scale)
	s.body(&g.dc, g.ui, g.mono)
	draw.pop_xform(&g.dc)
	draw.end_frame(&g.dc)
	render.frame_end(&g.r)
	return render.read_pixels(&g.r)
}

main :: proc() {
	out, space_name, only := ".", "srgb", ""
	dpr: f32 = 1
	warp, sweep_only := false, false
	frames := 300
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-out": i += 1; out = args[i]
		case "-dpr": i += 1; dpr, _ = strconv.parse_f32(args[i])
		case "-space": i += 1; space_name = args[i]
		case "-scene": i += 1; only = args[i]
		case "-frames": i += 1; frames, _ = strconv.parse_int(args[i])
		case "-warp": warp = true
		case "-sweep": sweep_only = true
		}
	}
	if sweep_only {
		sweep(out, dpr, space_name == "linear" ? render.Blend_Space.Linear : .Srgb, warp, frames)
		return
	}
	space := space_name == "linear" ? render.Blend_Space.Linear : .Srgb
	_ = os.make_directory(out)
	fmt.printfln("dpr %.2f, space %s, %s", dpr, space_name, warp ? "WARP" : "GPU")
	for s in SCENES {
		if only != "" && s.name != only { continue }
		size := [2]int{int(f32(s.size.x) * dpr + 0.5), int(f32(s.size.y) * dpr + 0.5)}
		imgs: [2][]u8
		cpu, gpu, first: [2]f64
		mem: [2]int
		for mode in 0 ..< 2 {
			g := new(Rig)
			if !rig_open(g, size, space, warp, mode == 1) { fmt.eprintln("cannot open the renderer or the fonts"); os.exit(1) }
			render.set_gpu_timing(&g.r, true)
			// first paint: shaping, glyph bitmaps or curves, upload, the first draw (the fonts are loaded already)
			tf := time.tick_now()
			imgs[mode] = render_scene(g, s, dpr)
			first[mode] = time.duration_milliseconds(time.tick_since(tf))
			for _ in 0 ..< 8 { _ = render_scene(g, s, dpr) }
			// CPU time of building + submitting one frame (the offscreen target has no vsync), GPU time from the queries
			t0 := time.tick_now()
			sum, n: f64
			for _ in 0 ..< frames {
				_ = render_scene_nopixels(g, s, dpr)
				if ms := render.gpu_ms(&g.r); ms > 0 { sum += f64(ms); n += 1 }
			}
			cpu[mode] = time.duration_milliseconds(time.tick_since(t0)) / f64(frames)
			gpu[mode] = n > 0 ? sum / n : 0
			tm := render.texture_memory(&g.r)
			mem[mode] = tm.glyphs + tm.slug
			// the atlas pixels of a scene: keep the first image of each mode, then free
			imgs[mode] = clone(imgs[mode])
			rig_close(g)
			free(g)
		}
		w, h := size.x, size.y
		sheet := make([]u8, w * 3 * h * 4)
		diff_sum, ink_a, ink_s: f64
		for y in 0 ..< h {
			for x in 0 ..< w {
				a, b := imgs[0][(y * w + x) * 4:][:3], imgs[1][(y * w + x) * 4:][:3]
				d := 0
				for k in 0 ..< 3 { d += abs(int(a[k]) - int(b[k])); ink_a += f64(255 - int(a[k])) / 3; ink_s += f64(255 - int(b[k])) / 3 }
				diff_sum += f64(d) / 3
				copy(sheet[(y * w * 3 + x) * 4:][:4], imgs[0][(y * w + x) * 4:][:4])
				copy(sheet[(y * w * 3 + w + x) * 4:][:4], imgs[1][(y * w + x) * 4:][:4])
				v := u8(clamp(255 - d * 2, 0, 255))
				copy(sheet[(y * w * 3 + 2 * w + x) * 4:][:4], []u8{v, v, v, 255})
			}
		}
		name := fmt.tprintf("%s/%s_%s_%.0f.png", out, s.name, space_name, dpr * 100)
		stbi.write_png(strings.clone_to_cstring(name, context.temp_allocator), i32(w * 3), i32(h), 4, raw_data(sheet), i32(w * 3 * 4))
		fmt.printf("%-11s ink slug/atlas %.3f  ", s.name, ink_s / max(ink_a, 1))
		fmt.printfln("mean|diff| %.2f/255  first paint ms %.2f/%.2f  CPU ms/frame %.3f/%.3f  GPU ms %.3f/%.3f  glyph GPU memory KB %d/%d  (atlas/slug) -> %s",
			diff_sum / f64(w * h), first[0], first[1], cpu[0], cpu[1], gpu[0], gpu[1], mem[0] / 1024, mem[1] / 1024, name)
	}
}

// A pinch or Ctrl+wheel zoom: every frame is the page text at a new scale (1x to 3x and back). The atlas rasterizes every
// glyph again at each new size; Slug has nothing to make.
sweep :: proc(out: string, dpr: f32, space: render.Blend_Space, warp: bool, frames: int) {
	s := SCENES[0]
	size := [2]int{int(f32(s.size.x) * dpr * 3), int(f32(s.size.y) * dpr * 3)}
	res: [2][2]f64   // [mode] {mean CPU ms, worst CPU ms}
	for mode in 0 ..< 2 {
		g := new(Rig)
		if !rig_open(g, size, space, warp, mode == 1) { fmt.eprintln("cannot open the renderer or the fonts"); os.exit(1) }
		for i in 0 ..< 4 { _ = render_zoom(g, s, dpr, 1 + 0.01 * f32(i)) }   // warm up (the first glyphs, the pipelines)
		sum, worst: f64
		for i in 0 ..< frames {
			t := f32(i) / f32(frames)
			k := 1 + 2 * (t < 0.5 ? t * 2 : 2 - t * 2)
			t0 := time.tick_now()
			_ = render_zoom(g, s, dpr, k)
			ms := time.duration_milliseconds(time.tick_since(t0))
			sum += ms
			worst = max(worst, ms)
		}
		res[mode] = {sum / f64(frames), worst}
		st := font.slug_stats(&g.fonts)
		fmt.printfln("  %s: %d atlas evictions, %d Slug glyphs built", mode == 0 ? "atlas" : "slug ", font.atlas_evictions(&g.fonts), st.built)
		rig_close(g)
		free(g)
	}
	fmt.printfln("zoom sweep 1x-3x-1x, %d frames: CPU ms/frame mean atlas %.3f slug %.3f, worst frame atlas %.2f slug %.2f", frames, res[0][0], res[1][0], res[0][1], res[1][1])
}

render_zoom :: proc(g: ^Rig, s: Scene, dpr, k: f32) -> bool {
	size := [2]f32{f32(s.size.x) * dpr * 3, f32(s.size.y) * dpr * 3}
	draw.begin_frame(&g.dc, size)
	render.frame_begin(&g.r, {1, 1, 1, 1})
	draw.push_scale(&g.dc, {0, 0}, dpr * k)
	s.body(&g.dc, g.ui, g.mono)
	draw.pop_xform(&g.dc)
	draw.end_frame(&g.dc)
	render.frame_end(&g.r)
	return true
}

render_scene_nopixels :: proc(g: ^Rig, s: Scene, dpr: f32) -> bool {
	scale := dpr * s.zoom
	size := [2]f32{f32(s.size.x) * dpr, f32(s.size.y) * dpr}
	draw.begin_frame(&g.dc, size)
	render.frame_begin(&g.r, {1, 1, 1, 1})
	draw.push_scale(&g.dc, {0, 0}, scale)
	s.body(&g.dc, g.ui, g.mono)
	draw.pop_xform(&g.dc)
	draw.end_frame(&g.dc)
	render.frame_end(&g.r)
	return true
}

clone :: proc(b: []u8) -> []u8 {
	c := make([]u8, len(b))
	copy(c, b)
	return c
}

_ :: math.PI

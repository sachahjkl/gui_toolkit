// The cost of emoji: Direct2D and the system's emoji font against the COLR interpreter and the built-in Noto Color Emoji,
// on pages of emoji drawn to an offscreen target: first paint (glyphs drawn from nothing), a page-zoom sweep (every frame at a new
// size), steady frames (CPU, GPU), memory (process private bytes, atlas, outline cache).
//   odin run tools/emojiperf -- <NotoColorEmoji-COLRv1.ttf> [-dpr 1.75] [-frames 300] [-warp]
// Run build\gpuload.exe beside it (odin build src/tools/gpuload in Wren) to hold the GPU clocks for the GPU numbers.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "../../draw"
import "../../font"
import "../../render"

Scene :: struct {
	name:  string,
	size:  [2]int,   // CSS pixels
	count: int,      // distinct emoji
	font_size: f32,
}

SCENES := [?]Scene{
	{"emoji100", {640, 140}, 100, 20},     // a chat page
	{"emoji1000", {1280, 520}, 1000, 20},  // a page full of distinct emoji
	{"emoji100_big", {1000, 330}, 100, 48},
}

Rig :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
	ui:    font.Font_Id,
}

private_bytes :: proc() -> int {
	c: win.PROCESS_MEMORY_COUNTERS_EX
	c.cb = size_of(c)
	win.GetProcessMemoryInfo(win.GetCurrentProcess(), (win.PPROCESS_MEMORY_COUNTERS)(&c), size_of(c))
	return int(c.PrivateUsage)
}

emoji_text :: proc(first, n: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	k := 0
	for r := rune(0x1F300); r < 0x1FB00 && k < first + n; r += 1 {
		// code points that are emoji in the font are found by the shaping; a plain range is enough to take n distinct ones
		if !(r < 0x1F650 || (r >= 0x1F680 && r < 0x1F6D8) || (r >= 0x1F900 && r < 0x1FA00)) { continue }
		if k >= first { strings.write_rune(&sb, r) }
		k += 1
	}
	return strings.to_string(sb)
}

body :: proc(c: ^draw.Context, g: ^Rig, s: Scene) {
	text := emoji_text(0, s.count)
	per_line := int(f32(s.size.x) / (s.font_size * 1.25)) - 1
	y: f32 = s.font_size * 1.3
	runes := make([dynamic]rune, context.temp_allocator)
	for r in text { append(&runes, r) }
	for i := 0; i < len(runes); i += per_line {
		line := strings.builder_make(context.temp_allocator)
		for r in runes[i:min(i + per_line, len(runes))] { strings.write_rune(&line, r) }
		draw.text(c, g.ui, s.font_size, {8, y}, draw.Color{0.05, 0.05, 0.05, 1}, strings.to_string(line))
		y += s.font_size * 1.4
	}
}

frame :: proc(g: ^Rig, s: Scene, dpr, k: f32) {
	size := [2]f32{f32(s.size.x) * dpr, f32(s.size.y) * dpr}
	draw.begin_frame(&g.dc, size)
	render.frame_begin(&g.r, {1, 1, 1, 1})
	draw.push_scale(&g.dc, {0, 0}, dpr * k)
	body(&g.dc, g, s)
	draw.pop_xform(&g.dc)
	draw.end_frame(&g.dc)
	render.frame_end(&g.r)
}

main :: proc() {
	if len(os.args) < 2 { fmt.println("usage: emojiperf <font.ttf> [-dpr 1.75] [-frames 300] [-warp]"); os.exit(2) }
	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil { fmt.println("cannot read", os.args[1]); os.exit(2) }
	dpr: f32 = 1
	frames := 300
	warp := false
	args := os.args[2:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-dpr": i += 1; dpr, _ = strconv.parse_f32(args[i])
		case "-frames": i += 1; frames, _ = strconv.parse_int(args[i])
		case "-warp": warp = true
		}
	}
	fmt.printfln("dpr %.2f, %s; Direct2D + Segoe UI Emoji | interpreter + Noto Color Emoji", dpr, warp ? "WARP" : "GPU")
	for s in SCENES {
		size := [2]int{int(f32(s.size.x) * dpr + 0.5), int(f32(s.size.y) * dpr + 0.5)}
		first, steady, gpu, sweep, sweep_worst, load_ms: [2]f64
		mem, atlas: [2]int
		for mode in 0 ..< 2 {
			g := new(Rig)
			if !render.init_offscreen(&g.r, size, warp, .Srgb) { fmt.eprintln("no offscreen renderer"); os.exit(1) }
			st := font.DEFAULT_SETTINGS
			st.color_engine = mode == 1 ? .Builtin : .System
			font.init(&g.fonts, st)
			ok: bool
			g.ui, ok = font.load_system(&g.fonts, "Segoe UI")
			if !ok { fmt.eprintln("no Segoe UI"); os.exit(1) }
			if mode == 1 { font.set_emoji_source(&g.fonts, data = data) }
			draw.init(&g.dc, &g.r, &g.fonts)
			render.set_gpu_timing(&g.r, true)
			before := private_bytes()
			// the first emoji of the text loads the emoji face (a 5 MB file): what that costs by itself
			tl := time.tick_now()
			_ = font.shape(&g.fonts, g.ui, 20, "\U0001F600", {}, context.temp_allocator)
			load_ms[mode] = time.duration_milliseconds(time.tick_since(tl))
			// first paint: shaping, the emoji face (loaded now), every glyph drawn, uploaded
			t0 := time.tick_now()
			frame(g, s, dpr, 1)
			first[mode] = time.duration_milliseconds(time.tick_since(t0))
			for _ in 0 ..< 6 { frame(g, s, dpr, 1) }
			mem[mode] = private_bytes() - before
			n := font.atlas_page_count(&g.fonts)
			for i in 0 ..< n {
				kind, sz, _ := font.atlas_page_info(&g.fonts, i)
				if kind == .Color { atlas[mode] += sz * sz * 4 }
			}
			t1 := time.tick_now()
			sum, cnt: f64
			for _ in 0 ..< frames {
				frame(g, s, dpr, 1)
				if ms := render.gpu_ms(&g.r); ms > 0 { sum += f64(ms); cnt += 1 }
			}
			steady[mode] = time.duration_milliseconds(time.tick_since(t1)) / f64(frames)
			gpu[mode] = cnt > 0 ? sum / cnt : 0
			// page zoom 1x -> 2x -> 1x: every frame draws every emoji at a new size
			worst, total: f64
			nz := 60
			for i in 0 ..< nz {
				t := f32(i) / f32(nz)
				k := 1 + (t < 0.5 ? t * 2 : 2 - t * 2)
				tf := time.tick_now()
				frame(g, s, dpr, k)
				ms := time.duration_milliseconds(time.tick_since(tf))
				total += ms
				worst = max(worst, ms)
			}
			sweep[mode], sweep_worst[mode] = total / f64(nz), worst
			draw.destroy(&g.dc)
			render.destroy(&g.r)
			font.destroy(&g.fonts)
			free(g)
		}
		fmt.printfln("  first emoji shaped in %.1f ms (Segoe UI Emoji by DirectWrite fallback) | %.1f ms (Noto from the file)", load_ms[0], load_ms[1])
		fmt.printfln("%-13s first paint ms %.1f | %.1f   steady CPU ms/frame %.3f | %.3f   GPU ms %.3f | %.3f   zoom sweep ms/frame %.1f (worst %.1f) | %.1f (worst %.1f)   private MB +%.1f | +%.1f   color atlas MB %.1f | %.1f",
			s.name, first[0], first[1], steady[0], steady[1], gpu[0], gpu[1], sweep[0], sweep_worst[0], sweep[1], sweep_worst[1],
			f64(mem[0]) / 1048576, f64(mem[1]) / 1048576, f64(atlas[0]) / 1048576, f64(atlas[1]) / 1048576)
	}
}

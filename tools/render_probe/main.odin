// Draws a few primitives with the offscreen renderer and writes the pixels as a PPM; prints timings. For bringing up and
// comparing a render backend:
//   odin run tools/render_probe -define:TOOLKIT_RENDER=wgpu -- build/probe_wgpu.ppm [warp]
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "../../draw"
import "../../font"
import "../../render"

main :: proc() {
	out := len(os.args) > 1 ? os.args[1] : "build/probe.ppm"
	warp := len(os.args) > 2 && os.args[2] == "warp"
	t0 := time.tick_now()
	r: render.Renderer
	fonts: font.State
	dc: draw.Context
	size := [2]int{320, 200}
	if !render.init_offscreen(&r, size, warp = warp, space = .Srgb) { fmt.eprintln("probe: init_offscreen failed"); os.exit(1) }
	fmt.printfln("backend %s, adapter %s, init %.1f ms", render.backend_name(), render.adapter_description(&r), time.duration_milliseconds(time.tick_since(t0)))
	font.init(&fonts)
	draw.init(&dc, &r, &fonts)
	id, ok, _ := font.load_system_or_embedded(&fonts, "C:/Windows/Fonts/segoeui.ttf", font.FALLBACK_UI_DATA)
	if !ok { fmt.eprintln("probe: font"); os.exit(1) }
	for i in 0 ..< 3 {
		t1 := time.tick_now()
		draw.begin_frame(&dc, {f32(size.x), f32(size.y)})
		render.frame_begin(&r, {1, 1, 1, 1})
		draw.rect(&dc, {{10, 10}, {150, 90}}, draw.hex(0x3366ccff), 12)
		draw.rect(&dc, {{10, 10}, {150, 90}}, draw.hex(0x000000ff), 12, 2)
		a, b := draw.hex(0xff5533ff), draw.hex(0x33ff99ff)
		draw.rect_corners(&dc, {{170, 10}, {300, 90}}, {a, b, a, b}, {20, 20, 20, 20})
		draw.rect(&dc, {{20, 110}, {200, 170}}, draw.srgb(0, 0, 0, 0.5), 10, 0, 8)
		draw.text(&dc, id, 20, {24, 130}, draw.hex(0x101010ff), "Hello, wgpu 123")
		draw.end_frame(&dc)
		render.frame_end(&r)
		fmt.printfln("frame %d: %.2f ms", i, time.duration_milliseconds(time.tick_since(t1)))
	}
	px := render.read_pixels(&r)
	sb: strings.Builder
	fmt.sbprintf(&sb, "P6\n%d %d\n255\n", size.x, size.y)
	for i in 0 ..< size.x * size.y { strings.write_byte(&sb, px[i * 4]); strings.write_byte(&sb, px[i * 4 + 1]); strings.write_byte(&sb, px[i * 4 + 2]) }
	_ = os.write_entire_file(out, sb.buf[:])
	fmt.printfln("wrote %s; sample (30,30) = %v, (200,50) = %v", out, px[(30 * size.x + 30) * 4:][:4], px[(50 * size.x + 200) * 4:][:4])
	draw.destroy(&dc)
	font.destroy(&fonts)
	render.destroy(&r)
}

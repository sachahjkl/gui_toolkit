// Slug's small text against DirectWrite's bitmaps: the same scenes drawn by the atlas (DirectWrite, hinted bitmaps: the
// reference) and by Slug with each combination of its small-text settings (hinted outlines, stem darkening, four samples
// per pixel), stacked in one PNG per scene and scale, with a 3x enlargement of the first lines. Needs the native backend
// for hinting (tools\build_text.ps1 first):
//   odin run tools/slugsmall -define:FONT_BACKEND=native -- -out <dir> [-dpr 1.5] [-darken 0.15] [-hint 24] [-ss 20]
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import stbi "vendor:stb/image"
import "../../draw"
import "../../font"
import "../../render"

Variant :: struct {
	name:   string,
	slug:   bool,
	hint:   bool,
	darken: bool,
	ss:     bool,
}

VARIANTS := [?]Variant{
	{name = "A  DirectWrite bitmaps (reference)"},
	{name = "B  Slug as it is", slug = true},
	{name = "C  Slug + stem darkening", slug = true, darken = true},
	{name = "D  Slug + hinted outlines", slug = true, hint = true},
	{name = "E  Slug + hinted + darkening", slug = true, hint = true, darken = true},
	{name = "F  Slug + 4 samples", slug = true, ss = true},
	{name = "G  Slug + hinted + darkening + 4 samples", slug = true, hint = true, darken = true, ss = true},
}

Scene :: struct {
	name: string,
	size: [2]int,   // logical pixels
	bg:   [4]f32,
	body: proc(c: ^draw.Context, ui, mono: font.Font_Id, label: string),
}

// opencode native's palette: text on a near black window (sRGB values, made linear at start)
TEXT, WEAK, INK, ACCENT: draw.Color

LINES := [?]string{
	"The quick brown fox jumps over the lazy dog. Sphinx of black quartz, judge my vow.",
	"Settings  Appearance  Conversation  Behaviour  Server & shell  MCP servers  0123456789",
}

scene_ui :: proc(c: ^draw.Context, ui, mono: font.Font_Id, label: string) {
	draw.text(c, ui, 12, {10, 15}, ACCENT, label)
	y: f32 = 38
	for size in ([?]f32{11, 12, 13, 14, 16}) {
		draw.text(c, ui, size, {10, y}, TEXT, LINES[0])
		draw.text(c, ui, size, {10, y + size * 1.35}, WEAK, LINES[1])
		y += size * 2.9
	}
	draw.text(c, mono, 12, {10, y}, TEXT, "fn main() { let x = vec![1, 2, 3]; } // mono 12  {}[]() ilI1 O0")
	draw.text(c, mono, 13, {10, y + 18}, WEAK, "src/settings.odin:494  font_button :: proc(app: ^App)  mono 13")
}

scene_page :: proc(c: ^draw.Context, ui, mono: font.Font_Id, label: string) {
	draw.text(c, ui, 12, {10, 15}, draw.hex(0x9a4a10ff), label)
	y: f32 = 38
	for size in ([?]f32{11, 12, 13, 14, 16}) {
		draw.text(c, ui, size, {10, y}, INK, LINES[0])
		y += size * 1.6
	}
	draw.text(c, mono, 13, {10, y}, INK, "fn main() { let x = vec![1, 2, 3]; } // mono 13  ilI1 O0")
}

SCENES := [?]Scene{
	{"ui_dark", {640, 250}, {0.0042, 0.0042, 0.0042, 1}, scene_ui},   // #0e0e0e
	{"page_light", {640, 150}, {1, 1, 1, 1}, scene_page},
}

Params :: struct { darken, hint, ss: f32 }

render_variant :: proc(s: Scene, v: Variant, p: Params, dpr: f32) -> (img: []u8, ok: bool) {
	size := [2]int{int(f32(s.size.x) * dpr + 0.5), int(f32(s.size.y) * dpr + 0.5)}
	r: render.Renderer
	if !render.init_offscreen(&r, size, false, .Srgb) { return }
	defer render.destroy(&r)
	st := font.DEFAULT_SETTINGS
	st.text_renderer = v.slug ? .Slug : .Atlas
	if v.hint { st.slug_hint_ppem = p.hint }
	if v.darken { st.slug_darken = p.darken }
	if v.ss { st.slug_supersample_ppem = p.ss }
	fonts: font.State
	font.init(&fonts, st)
	defer font.destroy(&fonts)
	ui, ok1 := font.load_system(&fonts, "Segoe UI")
	mono, ok2 := font.load_system(&fonts, "Cascadia Mono")
	if !ok2 { mono, ok2 = font.load_system(&fonts, "Consolas") }
	if !ok1 || !ok2 { return }
	dc: draw.Context
	draw.init(&dc, &r, &fonts)
	defer draw.destroy(&dc)
	px: []u8
	for _ in 0 ..< 2 {   // the second frame draws from uploaded glyph data
		draw.begin_frame(&dc, {f32(size.x), f32(size.y)})
		render.frame_begin(&r, s.bg)
		draw.push_scale(&dc, {0, 0}, dpr)
		s.body(&dc, ui, mono, v.name)
		draw.pop_xform(&dc)
		draw.end_frame(&dc)
		render.frame_end(&r)
	}
	px = render.read_pixels(&r)
	img = make([]u8, len(px))
	copy(img, px)
	return img, true
}

main :: proc() {
	out := "build/slugsmall"
	dprs := [dynamic]f32{}
	p := Params{darken = 0.15, hint = 24, ss = 20}
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-out": i += 1; out = args[i]
		case "-dpr": i += 1; d, _ := strconv.parse_f32(args[i]); append(&dprs, d)
		case "-darken": i += 1; p.darken, _ = strconv.parse_f32(args[i])
		case "-hint": i += 1; p.hint, _ = strconv.parse_f32(args[i])
		case "-ss": i += 1; p.ss, _ = strconv.parse_f32(args[i])
		}
	}
	TEXT, WEAK, INK, ACCENT = draw.hex(0xd8d8d8ff), draw.hex(0x8a8a8aff), draw.hex(0x101010ff), draw.hex(0xfab283ff)
	if len(dprs) == 0 { append(&dprs, 1, 1.5) }
	_ = os.make_directory(out)
	fmt.printfln("darken %.2f px, hinted to %.0f px/em, 4 samples to %.0f px/em, native text: %v", p.darken, p.hint, p.ss, font.NATIVE_TEXT)
	for dpr in dprs {
		for s in SCENES {
			w, h := int(f32(s.size.x) * dpr + 0.5), int(f32(s.size.y) * dpr + 0.5)
			gap := 4
			sheet := make([]u8, w * (h + gap) * len(VARIANTS) * 4)
			// the enlargement: the first two text lines (logical y 26..72), 3x, nearest
			Z :: 3
			cx, cy, cw, ch := 0, int(26 * dpr), min(w, int(330 * dpr)), int(48 * dpr)
			zoom := make([]u8, cw * Z * (ch * Z + gap) * len(VARIANTS) * 4)
			for v, vi in VARIANTS {
				img, ok := render_variant(s, v, p, dpr)
				if !ok { fmt.eprintln("cannot render", v.name); os.exit(1) }
				copy(sheet[vi * w * (h + gap) * 4:][:w * h * 4], img)
				for y in 0 ..< ch * Z {
					for x in 0 ..< cw * Z {
						src := ((cy + y / Z) * w + cx + x / Z) * 4
						dst := ((vi * (ch * Z + gap) + y) * cw * Z + x) * 4
						copy(zoom[dst:][:4], img[src:][:4])
					}
				}
				delete(img)
			}
			name := fmt.tprintf("%s/%s_%.0f.png", out, s.name, dpr * 100)
			stbi.write_png(strings.clone_to_cstring(name, context.temp_allocator), i32(w), i32((h + gap) * len(VARIANTS)), 4, raw_data(sheet), i32(w * 4))
			zname := fmt.tprintf("%s/%s_%.0f_zoom.png", out, s.name, dpr * 100)
			stbi.write_png(strings.clone_to_cstring(zname, context.temp_allocator), i32(cw * Z), i32((ch * Z + gap) * len(VARIANTS)), 4, raw_data(zoom), i32(cw * Z * 4))
			fmt.println("wrote", name, zname)
		}
	}
}

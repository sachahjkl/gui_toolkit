// The logo and the icon, drawn by GDI+ through its flat API: the calls System.Drawing makes, so the pictures are the same, byte for byte.
package tk

import "core:fmt"
import win "core:sys/windows"

foreign import gdiplus "system:gdiplus.lib"
foreign import shlwapi "system:shlwapi.lib"

Gp_Status :: i32
Gp_Image :: distinct rawptr
Gp_Graphics :: distinct rawptr
Gp_Path :: distinct rawptr
Gp_Brush :: distinct rawptr
Gp_Pen :: distinct rawptr
Point_F :: struct { x, y: f32 }

Gdiplus_Startup_Input :: struct {
	version:                    u32,
	debug_event_callback:       rawptr,
	suppress_background_thread: win.BOOL,
	suppress_external_codecs:   win.BOOL,
}

GP_OK :: 0
GDIPLUS_VERSION :: 1
PIXEL_FORMAT_32BPP_ARGB :: 0x0026200A
INTERPOLATION_HIGH_QUALITY_BICUBIC :: 7
SMOOTHING_ANTI_ALIAS :: 4
PIXEL_OFFSET_HIGH_QUALITY :: 2
UNIT_WORLD :: 0
UNIT_PIXEL :: 2
FILL_MODE_ALTERNATE :: 0
WRAP_MODE_TILE :: 0
ARGB_TRANSPARENT :: 0x00FFFFFF   // Color.Transparent
ARGB_WHITE :: 0xFFFFFFFF
STREAM_SEEK_SET :: 0
STREAM_SEEK_END :: 2
// The PNG encoder of GDI+.
PNG_ENCODER := win.GUID{0x557CF406, 0x1A04, 0x11D3, {0x9A, 0x73, 0x00, 0x00, 0xF8, 0x1E, 0xF3, 0x2E}}

@(default_calling_convention = "system")
foreign gdiplus {
	GdiplusStartup :: proc(token: ^uintptr, input: ^Gdiplus_Startup_Input, output: rawptr) -> Gp_Status ---
	GdiplusShutdown :: proc(token: uintptr) ---
	GdipLoadImageFromFile :: proc(filename: win.wstring, image: ^Gp_Image) -> Gp_Status ---
	GdipCreateBitmapFromScan0 :: proc(width, height, stride, format: i32, scan0: rawptr, bitmap: ^Gp_Image) -> Gp_Status ---
	GdipDisposeImage :: proc(image: Gp_Image) -> Gp_Status ---
	GdipSaveImageToFile :: proc(image: Gp_Image, filename: win.wstring, encoder: ^win.GUID, params: rawptr) -> Gp_Status ---
	GdipSaveImageToStream :: proc(image: Gp_Image, stream: ^win.IStream, encoder: ^win.GUID, params: rawptr) -> Gp_Status ---
	GdipGetImageGraphicsContext :: proc(image: Gp_Image, graphics: ^Gp_Graphics) -> Gp_Status ---
	GdipDeleteGraphics :: proc(graphics: Gp_Graphics) -> Gp_Status ---
	GdipSetInterpolationMode :: proc(graphics: Gp_Graphics, mode: i32) -> Gp_Status ---
	GdipSetSmoothingMode :: proc(graphics: Gp_Graphics, mode: i32) -> Gp_Status ---
	GdipSetPixelOffsetMode :: proc(graphics: Gp_Graphics, mode: i32) -> Gp_Status ---
	GdipGraphicsClear :: proc(graphics: Gp_Graphics, argb: u32) -> Gp_Status ---
	GdipDrawImageRectI :: proc(graphics: Gp_Graphics, image: Gp_Image, x, y, w, h: i32) -> Gp_Status ---
	GdipDrawImageRectRectI :: proc(graphics: Gp_Graphics, image: Gp_Image, dx, dy, dw, dh, sx, sy, sw, sh, unit: i32, attributes, callback, data: rawptr) -> Gp_Status ---
	GdipCreatePath :: proc(fill_mode: i32, path: ^Gp_Path) -> Gp_Status ---
	GdipAddPathArc :: proc(path: Gp_Path, x, y, w, h, start, sweep: f32) -> Gp_Status ---
	GdipClosePathFigure :: proc(path: Gp_Path) -> Gp_Status ---
	GdipDeletePath :: proc(path: Gp_Path) -> Gp_Status ---
	GdipCreateLineBrush :: proc(from, to: ^Point_F, c1, c2: u32, wrap: i32, brush: ^Gp_Brush) -> Gp_Status ---
	GdipCreateSolidFill :: proc(argb: u32, brush: ^Gp_Brush) -> Gp_Status ---
	GdipDeleteBrush :: proc(brush: Gp_Brush) -> Gp_Status ---
	GdipCreatePen1 :: proc(argb: u32, width: f32, unit: i32, pen: ^Gp_Pen) -> Gp_Status ---
	GdipCreatePen2 :: proc(brush: Gp_Brush, width: f32, unit: i32, pen: ^Gp_Pen) -> Gp_Status ---
	GdipDeletePen :: proc(pen: Gp_Pen) -> Gp_Status ---
	GdipFillPath :: proc(graphics: Gp_Graphics, brush: Gp_Brush, path: Gp_Path) -> Gp_Status ---
	GdipDrawPath :: proc(graphics: Gp_Graphics, pen: Gp_Pen, path: Gp_Path) -> Gp_Status ---
	GdipFillEllipse :: proc(graphics: Gp_Graphics, brush: Gp_Brush, x, y, w, h: f32) -> Gp_Status ---
}

@(default_calling_convention = "system")
foreign shlwapi {
	SHCreateMemStream :: proc(init: [^]byte, size: u32) -> ^win.IStream ---
}

// Drawn 4 times larger, then made 512 px.
LOGO_SUPERSAMPLE :: 4
// The cobalt rounded square: lighter at the top, deeper at the bottom; a darker border just inside its edge (also a gradient, so it
// stays darker than the body everywhere); a faint highlight along the top inner edge.
LOGO_BOX_AT :: 56
LOGO_BOX_SIZE :: 400
LOGO_BOX_RADIUS :: 100
LOGO_BORDER :: 10
LOGO_HIGHLIGHT_WIDTH :: 2
LOGO_BODY_TOP :: 0xFF2F6FD8
LOGO_BODY_BOTTOM :: 0xFF0B3F9C
LOGO_EDGE_TOP :: 0xFF1A4FAE
LOGO_EDGE_BOTTOM :: 0xFF062A6E
LOGO_HIGHLIGHT :: 0x28FFFFFF
// A white switch (on), its knob a hole that shows the body; below it a white slider, its knob with a hole.
SWITCH_TRACK :: [5]f32{136, 150, 240, 104, 52}   // x, y, width, height, radius
SWITCH_KNOB :: [3]f32{324, 202, 38}               // centre, radius
SLIDER_TRACK :: [5]f32{136, 326, 240, 30, 15}
SLIDER_KNOB :: [3]f32{222, 341, 40}
SLIDER_HOLE :: 18

// GDI+ for the time of a drawing.
@(private = "file")
gdiplus_start :: proc() -> (token: uintptr, ok: bool) {
	input := Gdiplus_Startup_Input{version = GDIPLUS_VERSION}
	return token, GdiplusStartup(&token, &input, nil) == GP_OK
}

@(private = "file")
round_rect :: proc(x, y, w, h, r: f32) -> (p: Gp_Path) {
	GdipCreatePath(FILL_MODE_ALTERNATE, &p)
	d := 2 * r
	GdipAddPathArc(p, x, y, d, d, 180, 90)
	GdipAddPathArc(p, x + w - d, y, d, d, 270, 90)
	GdipAddPathArc(p, x + w - d, y + h - d, d, d, 0, 90)
	GdipAddPathArc(p, x, y + h - d, d, d, 90, 90)
	GdipClosePathFigure(p)
	return
}

@(private = "file")
fill_round_rect :: proc(g: Gp_Graphics, brush: Gp_Brush, r: [5]f32) {
	S :: LOGO_SUPERSAMPLE
	p := round_rect(r[0] * S, r[1] * S, r[2] * S, r[3] * S, r[4] * S)
	GdipFillPath(g, brush, p)
	GdipDeletePath(p)
}

@(private = "file")
fill_circle :: proc(g: Gp_Graphics, brush: Gp_Brush, x, y, r: f32) {
	S :: LOGO_SUPERSAMPLE
	GdipFillEllipse(g, brush, (x - r) * S, (y - r) * S, 2 * r * S, 2 * r * S)
}

draw_logo :: proc(out: string) -> string {
	S :: LOGO_SUPERSAMPLE
	N :: LOGO_PIXELS * S
	token, ok := gdiplus_start()
	if !ok { return "GDI+ does not start" }
	defer GdiplusShutdown(token)
	big: Gp_Image
	if GdipCreateBitmapFromScan0(N, N, 0, PIXEL_FORMAT_32BPP_ARGB, nil, &big) != GP_OK { return "no bitmap" }
	defer GdipDisposeImage(big)
	g: Gp_Graphics
	GdipGetImageGraphicsContext(big, &g)
	GdipSetSmoothingMode(g, SMOOTHING_ANTI_ALIAS)
	GdipGraphicsClear(g, ARGB_TRANSPARENT)

	top, bottom := Point_F{0, LOGO_BOX_AT * S}, Point_F{0, (LOGO_BOX_AT + LOGO_BOX_SIZE) * S}
	body, edge, white: Gp_Brush
	GdipCreateLineBrush(&top, &bottom, LOGO_BODY_TOP, LOGO_BODY_BOTTOM, WRAP_MODE_TILE, &body)
	GdipCreateLineBrush(&top, &bottom, LOGO_EDGE_TOP, LOGO_EDGE_BOTTOM, WRAP_MODE_TILE, &edge)
	GdipCreateSolidFill(ARGB_WHITE, &white)
	border, highlight: Gp_Pen
	GdipCreatePen2(edge, LOGO_BORDER * S, UNIT_WORLD, &border)
	GdipCreatePen1(LOGO_HIGHLIGHT, LOGO_HIGHLIGHT_WIDTH * S, UNIT_WORLD, &highlight)

	fill_round_rect(g, body, {LOGO_BOX_AT, LOGO_BOX_AT, LOGO_BOX_SIZE, LOGO_BOX_SIZE, LOGO_BOX_RADIUS})
	B :: f32(LOGO_BORDER)
	inner := round_rect((LOGO_BOX_AT + B / 2) * S, (LOGO_BOX_AT + B / 2) * S, (LOGO_BOX_SIZE - B) * S, (LOGO_BOX_SIZE - B) * S, (LOGO_BOX_RADIUS - B / 2) * S)
	GdipDrawPath(g, border, inner)
	GdipDeletePath(inner)
	shine := round_rect((LOGO_BOX_AT + B + 1) * S, (LOGO_BOX_AT + B + 1) * S, (LOGO_BOX_SIZE - 2 * B - 2) * S, (LOGO_BOX_SIZE - 2 * B - 2) * S, (LOGO_BOX_RADIUS - B) * S)
	GdipDrawPath(g, highlight, shine)
	GdipDeletePath(shine)
	fill_round_rect(g, white, SWITCH_TRACK)
	fill_circle(g, body, SWITCH_KNOB.x, SWITCH_KNOB.y, SWITCH_KNOB.z)
	fill_round_rect(g, white, SLIDER_TRACK)
	fill_circle(g, white, SLIDER_KNOB.x, SLIDER_KNOB.y, SLIDER_KNOB.z)
	fill_circle(g, body, SLIDER_KNOB.x, SLIDER_KNOB.y, SLIDER_HOLE)
	GdipDeletePen(border)
	GdipDeletePen(highlight)
	GdipDeleteBrush(body)
	GdipDeleteBrush(edge)
	GdipDeleteBrush(white)
	GdipDeleteGraphics(g)

	small: Gp_Image
	if GdipCreateBitmapFromScan0(LOGO_PIXELS, LOGO_PIXELS, 0, PIXEL_FORMAT_32BPP_ARGB, nil, &small) != GP_OK { return "no bitmap" }
	defer GdipDisposeImage(small)
	g2: Gp_Graphics
	GdipGetImageGraphicsContext(small, &g2)
	GdipSetInterpolationMode(g2, INTERPOLATION_HIGH_QUALITY_BICUBIC)
	GdipSetPixelOffsetMode(g2, PIXEL_OFFSET_HIGH_QUALITY)
	GdipDrawImageRectI(g2, big, 0, 0, LOGO_PIXELS, LOGO_PIXELS)
	GdipDeleteGraphics(g2)
	encoder := PNG_ENCODER
	if GdipSaveImageToFile(small, win.utf8_to_wstring(out), &encoder, nil) != GP_OK { return fmt.tprintf("%s cannot be written", out) }
	return ""
}

// The logo `png` cropped to its rounded square and drawn at each size, as PNG files.
icon_pngs :: proc(png: string, sizes: []int) -> (pngs: [][]byte, why: string) {
	token, ok := gdiplus_start()
	if !ok { return nil, "GDI+ does not start" }
	defer GdiplusShutdown(token)
	src: Gp_Image
	if GdipLoadImageFromFile(win.utf8_to_wstring(png), &src) != GP_OK { return nil, fmt.tprintf("%s cannot be read", png) }
	defer GdipDisposeImage(src)
	pngs = make([][]byte, len(sizes))
	for s, i in sizes {
		bmp: Gp_Image
		if GdipCreateBitmapFromScan0(i32(s), i32(s), 0, PIXEL_FORMAT_32BPP_ARGB, nil, &bmp) != GP_OK { return pngs, "no bitmap" }
		g: Gp_Graphics
		GdipGetImageGraphicsContext(bmp, &g)
		GdipSetInterpolationMode(g, INTERPOLATION_HIGH_QUALITY_BICUBIC)
		GdipSetSmoothingMode(g, SMOOTHING_ANTI_ALIAS)
		GdipSetPixelOffsetMode(g, PIXEL_OFFSET_HIGH_QUALITY)
		GdipGraphicsClear(g, ARGB_TRANSPARENT)
		GdipDrawImageRectRectI(g, src, 0, 0, i32(s), i32(s), ICON_CROP_AT, ICON_CROP_AT, ICON_CROP_SIZE, ICON_CROP_SIZE, UNIT_PIXEL, nil, nil, nil)
		pngs[i] = png_bytes(bmp)
		GdipDeleteGraphics(g)
		GdipDisposeImage(bmp)
		if pngs[i] == nil { return pngs, "the PNG encoder failed" }
	}
	return pngs, ""
}

// A bitmap encoded as PNG, in memory.
@(private = "file")
png_bytes :: proc(image: Gp_Image) -> []byte {
	stream := SHCreateMemStream(nil, 0)
	if stream == nil { return nil }
	defer stream->Release()
	encoder := PNG_ENCODER
	if GdipSaveImageToStream(image, stream, &encoder, nil) != GP_OK { return nil }
	size: win.ULARGE_INTEGER
	stream->Seek(0, STREAM_SEEK_END, &size)
	stream->Seek(0, STREAM_SEEK_SET, nil)
	out := make([]byte, int(size))
	read: win.ULONG
	stream->Read(raw_data(out), win.ULONG(len(out)), &read)
	if int(read) != len(out) { delete(out); return nil }
	return out
}

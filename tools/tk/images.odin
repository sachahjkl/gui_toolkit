// Pictures: the difference of two PPM files, the logo and the icon made from it (drawn by GDI+: gdiplus_windows.odin).
package tk

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strconv"

PPM_TOLERANCE :: 2
PPM_HEADER_TOKENS :: 4   // P6, width, height, the largest value
PPM_CHANNELS :: 3

// The logo is 512 px; the rounded square in it, from (56,56) and 400 wide, is what the icon shows (no transparent margin).
LOGO_PIXELS :: 512
LOGO_DEFAULT_OUT :: ".project/image.png"
ICON_CROP_AT :: 56
ICON_CROP_SIZE :: 400
@(rodata) ICON_SIZES := [?]int{16, 24, 32, 48, 64, 128, 256}
// The .ico format: a header, a 16-byte entry per picture; a picture of 256 px says 0 as its size.
ICO_HEADER :: 6
ICO_ENTRY :: 16
ICO_TYPE_ICON :: 1
ICO_PLANES :: 1
ICO_BITS :: 32
ICO_SIZE_256 :: 256

Ppm :: struct {
	w, h: int,
	data: []byte,   // RGB, a byte each
}

Ppm_Diff :: struct {
	w, h: int,
	max:  int,   // the largest difference of a channel
	mean: f64,   // of a channel
	over: int,   // pixels with a channel that differs by more than the tolerance
}

// A P6 PPM file: four tokens separated by white space, one byte of white space, the pixels.
read_ppm :: proc(b: []byte) -> (p: Ppm, ok: bool) {
	tokens: [PPM_HEADER_TOKENS]string
	pos := 0
	for &t in tokens {
		for pos < len(b) && b[pos] <= ' ' { pos += 1 }
		start := pos
		for pos < len(b) && b[pos] > ' ' { pos += 1 }
		if pos == start { return }
		t = string(b[start:pos])
	}
	pos += 1
	p.w = strconv.parse_int(tokens[1]) or_return
	p.h = strconv.parse_int(tokens[2]) or_return
	if pos > len(b) || len(b) - pos < p.w * p.h * PPM_CHANNELS { return }
	p.data = b[pos:]
	return p, true
}

ppm_diff :: proc(x, y: Ppm, tolerance: int) -> (d: Ppm_Diff, why: string) {
	if x.w != y.w || x.h != y.h { return d, fmt.tprintf("sizes differ: %dx%d vs %dx%d", x.w, x.h, y.w, y.h) }
	d.w, d.h = x.w, x.h
	n := x.w * x.h * PPM_CHANNELS
	sum := 0
	for i := 0; i < n; i += PPM_CHANNELS {
		worst := 0
		for c in 0 ..< PPM_CHANNELS {
			diff := abs(int(x.data[i + c]) - int(y.data[i + c]))
			sum += diff
			worst = max(worst, diff)
		}
		d.max = max(d.max, worst)
		if worst > tolerance { d.over += 1 }
	}
	d.mean = n > 0 ? f64(sum) / f64(n) : 0
	return d, ""
}

ppm_diff_files :: proc(a, b: string, tolerance: int) -> (d: Ppm_Diff, why: string) {
	files := [2]string{a, b}
	ppms: [2]Ppm
	for f, i in files {
		data, err := os.read_entire_file(f, context.temp_allocator)
		if err != nil { return d, fmt.tprintf("%s cannot be read", f) }
		ok: bool
		if ppms[i], ok = read_ppm(data); !ok { return d, fmt.tprintf("%s is not a P6 PPM file", f) }
	}
	return ppm_diff(ppms[0], ppms[1], tolerance)
}

// A .ico of PNG pictures, the sizes of `sizes` (one per picture).
ico_from_pngs :: proc(pngs: [][]byte, sizes: []int, allocator := context.allocator) -> []byte {
	total := ICO_HEADER + ICO_ENTRY * len(pngs)
	for p in pngs { total += len(p) }
	out := make([]byte, total, allocator)
	endian.put_u16(out[0:], .Little, 0)
	endian.put_u16(out[2:], .Little, ICO_TYPE_ICON)
	endian.put_u16(out[4:], .Little, u16(len(pngs)))
	offset := ICO_HEADER + ICO_ENTRY * len(pngs)
	for p, i in pngs {
		e := out[ICO_HEADER + ICO_ENTRY * i:]
		dim := sizes[i] >= ICO_SIZE_256 ? 0 : u8(sizes[i])
		e[0], e[1], e[2], e[3] = dim, dim, 0, 0
		endian.put_u16(e[4:], .Little, ICO_PLANES)
		endian.put_u16(e[6:], .Little, ICO_BITS)
		endian.put_u32(e[8:], .Little, u32(len(p)))
		endian.put_u32(e[12:], .Little, u32(offset))
		copy(out[offset:], p)
		offset += len(p)
	}
	return out
}

// A multi-size .ico (PNG-compressed, 16 to 256 px) from the 512 px logo `png`.
make_icon :: proc(png, out: string) -> string {
	pngs, why := icon_pngs(png, ICON_SIZES[:])
	if why != "" { return why }
	defer { for p in pngs { delete(p) }; delete(pngs) }
	ico := ico_from_pngs(pngs, ICON_SIZES[:])
	defer delete(ico)
	if os.write_entire_file(out, ico) != nil { return fmt.tprintf("%s cannot be written", out) }
	fmt.printfln("wrote %s", out)
	return ""
}

// Draws the logo, a PNG of 512 px, into `out`.
make_logo :: proc(out: string) -> string {
	if why := draw_logo(out); why != "" { return why }
	fmt.printfln("wrote %s", out)
	return ""
}

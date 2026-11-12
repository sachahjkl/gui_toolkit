// The decoder against the encoder: every mode and level, versions 1 to 40, damaged symbols, and pictures of symbols
// scaled (by whole and by fractional factors), turned, inverted and set in a larger picture.
//   odin test src/qr -vet
package qr

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:strings"
import "core:testing"

@(private = "file")
LEVELS :: [4]Ecc{.Low, .Medium, .Quartile, .High}

@(private = "file")
round_trip :: proc(t: ^testing.T, text: string, ecc: Ecc, loc := #caller_location) {
	code, err := encode(text, ecc)
	defer destroy(&code)
	testing.expectf(t, err == .None, "encode %v", err, loc = loc)
	d, derr := decode_modules(code.modules, code.size)
	defer decoded_destroy(&d)
	testing.expectf(t, derr == .None, "%d chars at %v: %v", len(text), ecc, derr, loc = loc)
	testing.expectf(t, string(d.data) == text, "%d chars at %v: read back %q", len(text), ecc, string(d.data), loc = loc)
	testing.expect_value(t, d.version, code.version, loc = loc)
	testing.expect_value(t, d.ecc, ecc, loc = loc)
	testing.expect_value(t, d.mask, code.mask, loc = loc)
	testing.expect_value(t, d.errors, 0, loc = loc)
}

@(test)
modules_round_trip_every_mode_and_level :: proc(t: ^testing.T) {
	texts := [?]string{"", "0", "01234567", "HELLO WORLD", "https://example.com/a?b=c", "Grüße, ça va ? 🙂", "AC-42"}
	for text in texts {
		for ecc in LEVELS { round_trip(t, text, ecc) }
	}
}

@(test)
modules_round_trip_every_version :: proc(t: ^testing.T) {
	// texts that fill versions 1 to 40, in bytes, digits and alphanumerics (version 7 and up hold version information)
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 3000 { strings.write_byte(&b, u8('a' + i % 26)) }
	letters := strings.to_string(b)
	for n := 1; n <= 2900; n += 97 {
		round_trip(t, letters[:n], .Low)
		round_trip(t, letters[:min(n, 1270)], .High)
	}
	digits := strings.repeat("31415926535", 700, context.temp_allocator)
	round_trip(t, digits[:7089], .Low)      // (version 40's capacity)
	alnum := strings.repeat("CLICHE QR $%*+-./:", 250, context.temp_allocator)
	round_trip(t, alnum[:4296], .Low)
}

// Modules of the data area flipped, a few per block, are corrected; too many are refused, not misread.
@(test)
modules_corrected :: proc(t: ^testing.T) {
	text := "https://github.com/sachahjkl/cliche"
	for ecc in LEVELS {
		code, _ := encode(text, ecc)
		defer destroy(&code)
		m := Matrix{size = code.size, version = code.version, ecc = ecc}
		m.modules = make([]bool, code.size * code.size, context.temp_allocator)
		m.function = make([]bool, code.size * code.size, context.temp_allocator)
		draw_function_patterns(&m)
		data_modules := make([dynamic]int, context.temp_allocator)
		for f, i in m.function { if !f { append(&data_modules, i) } }

		// one module in each of the first codewords (a module is one bit of one codeword): within any level's reach
		damaged := make([]bool, len(code.modules), context.temp_allocator)
		copy(damaged, code.modules)
		r := rand.create(u64(ecc) + 1)
		gen := rand.default_random_generator(&r)
		for _ in 0 ..< 2 {
			i := data_modules[rand.int_max(len(data_modules), gen)]
			damaged[i] = !damaged[i]
		}
		d, err := decode_modules(damaged, code.size)
		testing.expectf(t, err == .None && string(d.data) == text, "%v: %v %q", ecc, err, string(d.data))
		testing.expectf(t, d.errors >= 1, "%v: %d errors corrected", ecc, d.errors)
		decoded_destroy(&d)

		// half the data modules flipped: no code corrects that
		for i in data_modules[:len(data_modules) / 2] { damaged[i] = !damaged[i] }
		d2, err2 := decode_modules(damaged, code.size)
		testing.expectf(t, err2 != .None, "%v: half the modules flipped read as %q", ecc, string(d2.data))
		decoded_destroy(&d2)
	}
}

@(test)
modules_bad_input :: proc(t: ^testing.T) {
	m := make([]bool, 22 * 22, context.temp_allocator)
	_, err := decode_modules(m, 22)
	testing.expect_value(t, err, Decode_Error.Bad_Size)
	_, err = decode_modules(m[:10], 21)
	testing.expect_value(t, err, Decode_Error.Bad_Size)
}

////////////////////////////////
// Pictures

@(private = "file")
Picture :: struct {
	gray:          []u8,
	width, height: int,
}

// The code turned `quarters` quarter turns clockwise, `scale` pixels a module, its quiet zone around it, at (ox, oy)
// in a `width` x `height` picture of light grey; inverted: light modules on a dark ground.
@(private = "file")
render :: proc(code: Code, scale: f32, quarters: int, invert: bool, width, height, ox, oy: int) -> Picture {
	p := Picture{gray = make([]u8, width * height, context.temp_allocator), width = width, height = height}
	ground: u8 = invert ? 30 : 235
	for &g in p.gray { g = ground }
	n := code.size + 2 * QUIET_ZONE
	side := int(math.ceil(f32(n) * scale))
	for py in 0 ..< side {
		for px in 0 ..< side {
			x, y := ox + px, oy + py
			if x < 0 || y < 0 || x >= width || y >= height { continue }
			mx, my := int(f32(px) / scale) - QUIET_ZONE, int(f32(py) / scale) - QUIET_ZONE
			// (a quarter turn clockwise: what is at (mx, my) on the picture was at (my, size - 1 - mx))
			sx, sy := mx, my
			for _ in 0 ..< quarters % 4 { sx, sy = sy, code.size - 1 - sx }
			dark := module(code, sx, sy)
			light: u8 = invert ? 20 : 250
			darkv: u8 = invert ? 240 : 10
			p.gray[y * width + x] = dark ? darkv : light
		}
	}
	return p
}

@(private = "file")
read_picture :: proc(t: ^testing.T, p: Picture, want: string, what: string, loc := #caller_location) {
	d, err := decode_gray(p.gray, p.width, p.height, p.width)
	defer decoded_destroy(&d)
	testing.expectf(t, err == .None && string(d.data) == want, "%s: %v, read %q", what, err, string(d.data), loc = loc)
}

@(test)
picture_scaled_and_placed :: proc(t: ^testing.T) {
	text := "https://github.com/sachahjkl/cliche"
	code, _ := encode(text, .Medium)
	defer destroy(&code)
	for scale in ([?]f32{1, 2, 3, 4.5, 7.3}) {
		read_picture(t, render(code, scale, 0, false, 600, 500, 37, 51), text, fmt.tprintf("scale %v", scale))
	}
}

@(test)
picture_turned_and_inverted :: proc(t: ^testing.T) {
	text := "QUARTER TURNS 123"
	code, _ := encode(text, .Quartile)
	defer destroy(&code)
	for quarters in 0 ..< 4 {
		for invert in ([2]bool{false, true}) {
			read_picture(t, render(code, 5, quarters, invert, 300, 300, 20, 10), text, fmt.tprintf("%d quarters, inverted %v", quarters, invert))
		}
	}
}

@(test)
picture_large_version :: proc(t: ^testing.T) {
	text := strings.repeat("a long text for a larger symbol: ", 20, context.temp_allocator)
	code, _ := encode(text, .Medium)
	defer destroy(&code)
	testing.expect(t, code.version >= 7)
	read_picture(t, render(code, 3, 0, false, 900, 800, 100, 60), text, fmt.tprintf("version %d", code.version))
	read_picture(t, render(code, 2.6, 1, false, 900, 800, 0, 0), text, fmt.tprintf("version %d, turned, scale 2.6", code.version))
}

// A code beside other dark shapes, on a ground that is not flat: the local threshold and the triangle choice.
@(test)
picture_with_clutter :: proc(t: ^testing.T) {
	text := "found among other things"
	code, _ := encode(text, .Low)
	defer destroy(&code)
	p := render(code, 4, 0, false, 640, 400, 300, 120)
	for y in 0 ..< p.height {
		for x in 0 ..< 280 { p.gray[y * p.width + x] = u8(120 + (x + y) % 100) }   // (a gradient)
	}
	for y in 40 ..< 90 { for x in 20 ..< 260 { p.gray[y * p.width + x] = 15 } }   // (a dark bar)
	for y in 300 ..< 340 { for x in 30 ..< 70 { p.gray[y * p.width + x] = 15 } }  // (a dark square)
	read_picture(t, p, text, "cluttered")
}

@(test)
picture_bgra :: proc(t: ^testing.T) {
	text := "BGRA"
	code, _ := encode(text, .Medium)
	defer destroy(&code)
	p := render(code, 3, 0, false, 120, 110, 5, 5)
	px := make([]u8, p.width * p.height * 4, context.temp_allocator)
	for g, i in p.gray { px[i * 4], px[i * 4 + 1], px[i * 4 + 2], px[i * 4 + 3] = g, g, g, 255 }
	d, err := decode_rgba(px, p.width, p.height, p.width * 4, bgra = true)
	defer decoded_destroy(&d)
	testing.expectf(t, err == .None && string(d.data) == text, "%v %q", err, string(d.data))
}

@(test)
picture_without_code :: proc(t: ^testing.T) {
	blank := make([]u8, 200 * 150, context.temp_allocator)
	for &g in blank { g = 200 }
	_, err := decode_gray(blank, 200, 150, 200)
	testing.expect_value(t, err, Decode_Error.Not_Found)
	_, err = decode_gray(blank, 10, 10, 10)
	testing.expect_value(t, err, Decode_Error.Not_Found)
}

// Reed–Solomon alone: up to nsym / 2 errors of any value at any place are corrected; one more is refused.
@(test)
reed_solomon_corrects_its_reach :: proc(t: ^testing.T) {
	r := rand.create(7)
	gen := rand.default_random_generator(&r)
	gf := gf_make()
	for nsym in ([?]int{7, 10, 16, 22, 30}) {
		for trial in 0 ..< 40 {
			n := 10 + rand.int_max(100, gen)
			data := make([]u8, n, context.temp_allocator)
			for &b in data { b = u8(rand.int_max(256, gen)) }
			word := make([]u8, n + nsym, context.temp_allocator)
			copy(word, data)
			rs_remainder(data, rs_divisor(nsym), word[n:])
			clean := make([]u8, len(word), context.temp_allocator)
			copy(clean, word)

			errors := 1 + rand.int_max(nsym / 2, gen)
			placed := 0
			for placed < errors {
				i := rand.int_max(len(word), gen)
				if word[i] != clean[i] { continue }
				word[i] ~= u8(1 + rand.int_max(255, gen))
				placed += 1
			}
			fixed, ok := rs_correct(&gf, word, nsym)
			testing.expectf(t, ok && fixed == errors, "nsym %d trial %d: ok %v, %d of %d fixed", nsym, trial, ok, fixed, errors)
			testing.expectf(t, string(word) == string(clean), "nsym %d trial %d: the word differs", nsym, trial)
		}
	}
}

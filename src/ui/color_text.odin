package ui

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "../ascii"

// Colours as CSS writes them, for the colour picker's text field and for apps that edit colours in their own text (a style
// sheet): `color_parse` reads hex (#rgb, #rgba, #rrggbb, #rrggbbaa), rgb() / rgba(), hsl() / hsla() and oklch() (spaces or the
// legacy commas, an alpha after `/` or a fourth comma, numbers or percentages, hues in deg, rad, grad or turn) and says how it
// was written; `color_text` writes a colour in a style. Colours here are sRGB, 0..1, alpha last (`Srgba`); an oklch() outside
// sRGB is clipped to it. Names (red, rebeccapurple) are the app's: it knows its table.

Srgba :: [4]f32

Color_Format :: enum u8 { Hex, Rgb, Hsl, Oklch }
COLOR_FORMAT_NAMES := [Color_Format]string{.Hex = "HEX", .Rgb = "RGB", .Hsl = "HSL", .Oklch = "OKLCH"}

Color_Style :: struct {
	format: Color_Format,
	legacy: bool,   // rgb / hsl: the comma syntax (rgb(1, 2, 3), rgba(1, 2, 3, 0.5)); hex: the short form (#f00) where it is exact
}

@(private = "file") BYTE_MAX :: 255
@(private = "file") NIBBLE :: 17           // a short hex digit times this is its byte (f -> ff)
@(private = "file") PERCENT :: 100
@(private = "file") DEGREES :: 360
@(private = "file") GRAD_DEGREES :: 0.9
// oklch(): 100 % of chroma is 0.4 (CSS Color 4).
@(private = "file") OKLCH_CHROMA_FULL :: 0.4
// What the text keeps: alpha and oklch's lightness and chroma to 3 decimals, hsl and the hue of oklch to 1.
@(private = "file") ALPHA_DECIMALS :: 3
@(private = "file") OKLCH_DECIMALS :: 3
@(private = "file") HUE_DECIMALS :: 1
@(private = "file") HSL_DECIMALS :: 1
// Under this chroma oklch's hue means nothing (it is written 0).
@(private = "file") OKLCH_ACHROMATIC :: 0.0001

// The colour of `text`, and how it is written. ok false: not one of the syntaxes above.
color_parse :: proc(text: string) -> (c: Srgba, style: Color_Style, ok: bool) {
	s := ascii.lower(strings.trim_space(text))
	if strings.has_prefix(s, "#") { return hex_parse(s[1:]) }
	open := strings.index_byte(s, '(')
	if open <= 0 || !strings.has_suffix(s, ")") { return }
	name := strings.trim_space(s[:open])
	args := s[open + 1:len(s) - 1]
	parts := make([dynamic]string, context.temp_allocator)
	alpha_at := -1
	legacy := strings.contains_rune(args, ',')
	rest := args
	for len(rest) > 0 {
		i := strings.index_any(rest, " ,/\t")
		tok := i < 0 ? rest : rest[:i]
		if tok != "" { append(&parts, tok) }
		if i < 0 { break }
		if rest[i] == '/' { alpha_at = len(parts) }
		rest = rest[i + 1:]
	}
	if legacy && alpha_at < 0 && len(parts) == 4 { alpha_at = 3 }
	if len(parts) != (alpha_at < 0 ? 3 : 4) || (alpha_at >= 0 && alpha_at != 3) { return }
	c.a = 1
	if alpha_at >= 0 {
		v, unit, good := number_of(parts[3])
		if !good || (unit != "" && unit != "%") { return }
		c.a = f32(clamp(unit == "%" ? v / PERCENT : v, 0, 1))
	}
	switch name {
	case "rgb", "rgba":
		for k in 0 ..< 3 {
			v, unit, good := number_of(parts[k])
			if !good || (unit != "" && unit != "%") { return }
			c[k] = f32(clamp(unit == "%" ? v / PERCENT : v / BYTE_MAX, 0, 1))
		}
		style = {.Rgb, legacy}
	case "hsl", "hsla":
		h, hok := hue_of(parts[0])
		sv, su, sok := number_of(parts[1])
		lv, lu, lok := number_of(parts[2])
		if !hok || !sok || !lok || (su != "" && su != "%") || (lu != "" && lu != "%") { return }
		rgb := hsl_to_srgb(h, clamp(sv / PERCENT, 0, 1), clamp(lv / PERCENT, 0, 1))
		c[0], c[1], c[2] = rgb[0], rgb[1], rgb[2]
		style = {.Hsl, legacy}
	case "oklch":
		if legacy { return }
		lv, lu, lok := number_of(parts[0])
		cv, cu, cok := number_of(parts[1])
		h, hok := hue_of(parts[2])
		if !lok || !cok || !hok || (lu != "" && lu != "%") || (cu != "" && cu != "%") { return }
		l := lu == "%" ? lv / PERCENT : lv
		ch := cu == "%" ? cv / PERCENT * OKLCH_CHROMA_FULL : cv
		rgb := oklch_to_srgb(clamp(l, 0, 1), max(ch, 0), h)
		c[0], c[1], c[2] = rgb[0], rgb[1], rgb[2]
		style = {.Oklch, false}
	case: return
	}
	ok = true
	return
}

// `c` written in `style` (in the temporary allocator).
color_text :: proc(c: Srgba, style: Color_Style) -> string {
	a := clamp(c.a, 0, 1)
	opaque := byte_of(a) == BYTE_MAX
	switch style.format {
	case .Hex:
		r, g, b, al := byte_of(c.r), byte_of(c.g), byte_of(c.b), byte_of(a)
		if style.legacy && r % NIBBLE == 0 && g % NIBBLE == 0 && b % NIBBLE == 0 && al % NIBBLE == 0 {
			return opaque ? fmt.tprintf("#%x%x%x", r / NIBBLE, g / NIBBLE, b / NIBBLE) : fmt.tprintf("#%x%x%x%x", r / NIBBLE, g / NIBBLE, b / NIBBLE, al / NIBBLE)
		}
		return opaque ? fmt.tprintf("#%02x%02x%02x", r, g, b) : fmt.tprintf("#%02x%02x%02x%02x", r, g, b, al)
	case .Rgb:
		r, g, b := byte_of(c.r), byte_of(c.g), byte_of(c.b)
		if style.legacy {
			return opaque ? fmt.tprintf("rgb(%d, %d, %d)", r, g, b) : fmt.tprintf("rgba(%d, %d, %d, %s)", r, g, b, num_text(f64(a), ALPHA_DECIMALS))
		}
		return opaque ? fmt.tprintf("rgb(%d %d %d)", r, g, b) : fmt.tprintf("rgb(%d %d %d / %s)", r, g, b, num_text(f64(a), ALPHA_DECIMALS))
	case .Hsl:
		hsl := srgb_to_hsl(c.rgb)
		h, s, l := num_text(hsl[0], HSL_DECIMALS), num_text(hsl[1] * PERCENT, HSL_DECIMALS), num_text(hsl[2] * PERCENT, HSL_DECIMALS)
		if style.legacy {
			return opaque ? fmt.tprintf("hsl(%s, %s%%, %s%%)", h, s, l) : fmt.tprintf("hsla(%s, %s%%, %s%%, %s)", h, s, l, num_text(f64(a), ALPHA_DECIMALS))
		}
		return opaque ? fmt.tprintf("hsl(%s %s%% %s%%)", h, s, l) : fmt.tprintf("hsl(%s %s%% %s%% / %s)", h, s, l, num_text(f64(a), ALPHA_DECIMALS))
	case .Oklch:
		lch := srgb_to_oklch(c.rgb)
		l, ch, h := num_text(lch[0], OKLCH_DECIMALS), num_text(lch[1], OKLCH_DECIMALS), num_text(lch[2], HUE_DECIMALS)
		return opaque ? fmt.tprintf("oklch(%s %s %s)", l, ch, h) : fmt.tprintf("oklch(%s %s %s / %s)", l, ch, h, num_text(f64(a), ALPHA_DECIMALS))
	}
	return ""
}

// A number rounded to `decimals`, without the zeros at its end ("0.5", "12", never "-0").
num_text :: proc(v: f64, decimals: int) -> string {
	k := math.pow(10, f64(decimals))
	r := math.round(v * k) / k
	if r == 0 { r = 0 }   // (-0)
	s := fmt.tprintf(fmt.tprintf("%%.%df", decimals), r)
	if strings.contains_rune(s, '.') { s = strings.trim_right(strings.trim_right(s, "0"), ".") }
	return s
}

////////////////////////////////
// Conversions (sRGB 0..1)

// Hue (0..1, 0 for a grey), saturation and value of an sRGB colour.
srgb_to_hsv :: proc(c: [3]f32) -> (h, s, v: f32) {
	mx, mn := max(c.r, c.g, c.b), min(c.r, c.g, c.b)
	d := mx - mn
	v = mx
	s = mx == 0 ? 0 : d / mx
	switch {
	case d == 0:  h = 0
	case mx == c.r: h = math.mod((c.g - c.b) / d, 6) / 6
	case mx == c.g: h = ((c.b - c.r) / d + 2) / 6
	case:           h = ((c.r - c.g) / d + 4) / 6
	}
	if h < 0 { h += 1 }
	return
}

hsv_to_srgb :: proc(h, s, v: f32) -> [3]f32 {
	hh := (h - math.floor(h)) * 6
	i := int(hh)
	f := hh - f32(i)
	p, q, t := v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
	switch i {
	case 0: return {v, t, p}
	case 1: return {q, v, p}
	case 2: return {p, v, t}
	case 3: return {p, q, v}
	case 4: return {t, p, v}
	}
	return {v, p, q}
}

// (hue degrees, saturation 0..1, lightness 0..1)
srgb_to_hsl :: proc(c: [3]f32) -> [3]f64 {
	h, _, _ := srgb_to_hsv(c)
	mx, mn := f64(max(c.r, c.g, c.b)), f64(min(c.r, c.g, c.b))
	l := (mx + mn) * 0.5
	s := (l <= 0 || l >= 1) ? 0 : (mx - l) / min(l, 1 - l)
	return {f64(h) * DEGREES, s, l}
}

hsl_to_srgb :: proc(h, s, l: f64) -> [3]f32 {
	f :: proc(n, h, s, l: f64) -> f32 {
		k := math.mod(n + h / 30, 12)
		a := s * min(l, 1 - l)
		return f32(l - a * max(-1, min(k - 3, min(9 - k, 1))))
	}
	return {f(0, h, s, l), f(8, h, s, l), f(4, h, s, l)}
}

// (L 0..1, chroma, hue degrees)
srgb_to_oklch :: proc(c: [3]f32) -> [3]f64 {
	r, g, b := decode(c.r), decode(c.g), decode(c.b)
	l := math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
	m := math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
	s := math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
	L := 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
	A := 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
	B := 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
	ch := math.sqrt(A * A + B * B)
	h := ch < OKLCH_ACHROMATIC ? 0 : math.atan2(B, A) * 180 / math.PI
	if h < 0 { h += DEGREES }
	return {L, ch, h}
}

oklch_to_srgb :: proc(L, ch, h: f64) -> [3]f32 {
	A, B := ch * math.cos(h * math.PI / 180), ch * math.sin(h * math.PI / 180)
	l := L + 0.3963377774 * A + 0.2158037573 * B
	m := L - 0.1055613458 * A - 0.0638541728 * B
	s := L - 0.0894841775 * A - 1.2914855480 * B
	l, m, s = l * l * l, m * m * m, s * s * s
	return {encode(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s), encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s), encode(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)}
}

@(private = "file")
decode :: proc(x: f32) -> f64 {
	v := f64(x)
	return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4)
}

@(private = "file")
encode :: proc(x: f64) -> f32 {
	v := x <= 0.0031308 ? 12.92 * x : 1.055 * math.pow(x, 1 / 2.4) - 0.055
	return clamp(f32(v), 0, 1)
}

////////////////////////////////
// Reading

@(private = "file")
byte_of :: proc(v: f32) -> int { return int(math.round(clamp(v, 0, 1) * BYTE_MAX)) }

@(private = "file")
hex_parse :: proc(h: string) -> (c: Srgba, style: Color_Style, ok: bool) {
	digit :: proc(ch: u8) -> (int, bool) {
		switch ch {
		case '0' ..= '9': return int(ch - '0'), true
		case 'a' ..= 'f': return int(ch - 'a') + 10, true
		}
		return 0, false
	}
	n := len(h)
	if n != 3 && n != 4 && n != 6 && n != 8 { return }
	v: [8]int
	for i in 0 ..< n { d, good := digit(h[i]); if !good { return }; v[i] = d }
	c.a = 1
	short := n <= 4
	for k in 0 ..< n / (short ? 1 : 2) {
		b := short ? v[k] * NIBBLE : v[2 * k] * 16 + v[2 * k + 1]
		c[k] = f32(b) / BYTE_MAX
	}
	return c, {.Hex, short}, true
}

// A number and its unit ("50%" -> 50, "%"; "0.5" -> 0.5, ""; "none" -> 0).
@(private = "file")
number_of :: proc(s: string) -> (v: f64, unit: string, ok: bool) {
	if s == "none" { return 0, "", true }
	end := 0
	for end < len(s) && (s[end] == '-' || s[end] == '+' || s[end] == '.' || (s[end] >= '0' && s[end] <= '9') || (end > 0 && (s[end] == 'e') && end + 1 < len(s) && s[end + 1] >= '0' && s[end + 1] <= '9')) { end += 1 }
	if end == 0 { return }
	v, ok = strconv.parse_f64(s[:end])
	return v, s[end:], ok
}

// A hue in degrees, from a number (degrees) or an angle.
@(private = "file")
hue_of :: proc(s: string) -> (deg: f64, ok: bool) {
	v, unit, good := number_of(s)
	if !good { return }
	switch unit {
	case "", "deg": deg = v
	case "rad":     deg = v * 180 / math.PI
	case "grad":    deg = v * GRAD_DEGREES
	case "turn":    deg = v * DEGREES
	case: return
	}
	deg = math.mod(deg, DEGREES)
	if deg < 0 { deg += DEGREES }
	return deg, true
}

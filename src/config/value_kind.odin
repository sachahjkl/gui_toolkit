package tk_config

// A value's nature apart from its storage (Def.value_kind), and a number's unit from one table (Def.unit).
// src/md/features/everything-palette.md, "A value's nature, apart from its storage".

import "core:fmt"
import "core:math"
import "core:strings"
import "../ascii"
import i18n "../i18n"

// What a value is. `Plain`: nothing more than its storage says.
Value_Kind :: enum u8 { Plain, Font_Family, Theme, Color, Path, Address, Keys, Size, Duration, Fraction, Length, Factor, Rate }

// A number's unit; each belongs to one value kind (UNITS). `.None`: the kind's first unit (unit_of).
Unit :: enum u8 { None, Byte, Kibibyte, Mebibyte, Millisecond, Second, Minute, Hour, Day, Pixel, Em, Milli_Em, Percent, Times, Per_Second, Pixel_Per_Second }

// A unit's kind, its symbol (shown after the number; international, so not translated) and its size in the kind's first
// unit (0: it converts to no other, an em is the font's).
Unit_Info :: struct {
	kind:   Value_Kind,
	symbol: string,
	scale:  f64,
}

@(rodata)
UNITS := [Unit]Unit_Info{
	.None             = {.Plain, "", 0},
	.Byte             = {.Size, "B", 1},
	.Kibibyte         = {.Size, "KiB", 1 << 10},
	.Mebibyte         = {.Size, "MiB", 1 << 20},
	.Millisecond      = {.Duration, "ms", 1},
	.Second           = {.Duration, "s", MS_PER_S},
	.Minute           = {.Duration, "min", 60 * MS_PER_S},
	.Hour             = {.Duration, "h", 3600 * MS_PER_S},
	.Day              = {.Duration, "d", 86400 * MS_PER_S},
	.Pixel            = {.Length, "px", 0},
	.Em               = {.Length, "em", 0},
	.Milli_Em         = {.Length, "‰ em", 0},
	.Percent          = {.Fraction, "%", 0},
	.Times            = {.Factor, "×", 0},
	.Per_Second       = {.Rate, "/s", 0},
	.Pixel_Per_Second = {.Rate, "px/s", 0},
}

// The units of each kind, the first the one `.None` means.
@(rodata)
KIND_UNITS := [Value_Kind][]Unit{
	.Plain = nil, .Font_Family = nil, .Theme = nil, .Color = nil, .Path = nil, .Address = nil, .Keys = nil,
	.Size     = {.Byte, .Kibibyte, .Mebibyte},
	.Duration = {.Millisecond, .Second, .Minute, .Hour, .Day},
	.Fraction = {.Percent},
	.Length   = {.Pixel, .Em, .Milli_Em},
	.Factor   = {.Times},
	.Rate     = {.Per_Second, .Pixel_Per_Second},
}

// The kinds' names as a program or a tool writes them (an about:config column, the showcase's choice).
@(rodata)
VALUE_KIND_NAMES := [Value_Kind]string{
	.Plain = "plain", .Font_Family = "font_family", .Theme = "theme", .Color = "color", .Path = "path",
	.Address = "address", .Keys = "keys", .Size = "size", .Duration = "duration", .Fraction = "fraction",
	.Length = "length", .Factor = "factor", .Rate = "rate",
}

@(private = "file") MS_PER_S :: 1000
@(private = "file") PERCENT :: 100

// Whether a value kind can be kept in `storage`.
value_kind_stores :: proc(vk: Value_Kind, storage: Kind) -> bool {
	switch vk {
	case .Plain:                                                   return true
	case .Font_Family, .Theme, .Color, .Path, .Address, .Keys:     return storage == .String
	case .Size:                                                    return storage == .Int
	case .Fraction, .Factor:                                       return storage == .Float
	case .Duration, .Length, .Rate:                                return storage == .Int || storage == .Float
	}
	return false
}

// Whether the kind holds a number with a unit.
is_measure :: proc(vk: Value_Kind) -> bool { return len(KIND_UNITS[vk]) > 0 }

// The unit of `d`: its own, or its kind's first (.None for a kind with no unit).
unit_of :: proc(d: Def) -> Unit {
	if d.unit != .None { return d.unit }
	us := KIND_UNITS[d.value_kind]
	return len(us) > 0 ? us[0] : .None
}

// The symbol written after the value of `d` ("ms", "px", "%"; "": none).
unit_symbol :: proc(d: Def) -> string { return UNITS[unit_of(d)].symbol }

// How many of the shown number make one stored: a Fraction is shown in percent, every other as stored.
shown_scale :: proc(d: Def) -> f64 { return d.value_kind == .Fraction ? PERCENT : 1 }

// (register) A Def whose value kind its storage cannot keep, or whose unit is another kind's, is the program's mistake.
@(private)
value_kind_check :: proc(d: Def) {
	assert(value_kind_stores(d.value_kind, d.kind), "a value kind on a storage that cannot keep it")
	assert(d.unit == .None || UNITS[d.unit].kind == d.value_kind, "a unit of another value kind")
}

// What a value of `d` must look like, for a message under a field that refused one ("": nothing to add).
value_hint :: proc(d: Def) -> string {
	#partial switch d.value_kind {
	case .Color:    return i18n.tr("a colour: #rgb, #rrggbb or #rrggbbaa")
	case .Address:  return i18n.tr("an address with its scheme: https://…")
	case .Keys:     return i18n.tr("keys such as Ctrl+Shift+K")
	case .Path:     return i18n.tr("a path")
	case .Size:     return i18n.tr("a size: 512, 64 KiB, 4 MiB, 2 GB")
	case .Duration: return i18n.tr("a time: 300 ms, 1.5 s, 2 min, 1 d")
	case .Fraction: return i18n.tr("a share: 45% or 0.45")
	}
	return ""
}

// (parse_value) What a text kind refuses; .None when the text is one of its values. The empty text is a value of every
// kind: none, the program's own.
@(private)
text_check :: proc(d: Def, text: string) -> Set_Error {
	if text == "" { return .None }
	#partial switch d.value_kind {
	case .Color:   if !is_hex_color(text) { return .Bad_Type }
	case .Address: if !has_scheme(text) { return .Bad_Type }
	case .Keys:    if !is_keys(text) { return .Bad_Type }
	case .Path:    if strings.index_byte(text, 0) >= 0 { return .Bad_Type }
	}
	return .None
}

// "#" and 3, 4, 6 or 8 hex digits: what the colour picker writes and what a theme file reads.
@(private = "file")
is_hex_color :: proc(s: string) -> bool {
	if len(s) < 2 || s[0] != '#' { return false }
	n := len(s) - 1
	if n != 3 && n != 4 && n != 6 && n != 8 { return false }
	for c in transmute([]u8)s[1:] {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) { return false }
	}
	return true
}

// A URL's scheme (RFC 3986: a letter, then letters, digits, + - .), its ':' and something after it.
@(private = "file")
has_scheme :: proc(s: string) -> bool {
	colon := strings.index_byte(s, ':')
	if colon <= 0 || colon == len(s) - 1 { return false }
	for c, i in transmute([]u8)s[:colon] {
		letter := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
		if i == 0 && !letter { return false }
		if !letter && !(c >= '0' && c <= '9') && c != '+' && c != '-' && c != '.' { return false }
	}
	return true
}

// Chords apart by spaces, each a chord's parts apart by '+', none empty ("Ctrl+K Ctrl+S", "Ctrl++" is Ctrl and +).
// The names are the platform's to read: config does not import it (the platform imports config).
@(private = "file")
is_keys :: proc(s: string) -> bool {
	rest := strings.trim_space(s)
	if rest == "" { return false }
	for chord in strings.fields_iterator(&rest) {
		c := chord
		// (a chord ending in "++": its key is "+")
		if strings.has_suffix(c, "++") { c = c[:len(c) - 1] } else if c == "+" { continue }
		for part in strings.split_iterator(&c, "+") { if part == "" { return false } }
	}
	return true
}

// A suffix a measure's text may end with, and how many of the setting's unit one of it is.
@(private = "file")
Suffix :: struct { text: string, scale: f64 }

@(private = "file", rodata) SIZE_SUFFIXES := [?]Suffix{
	{"B", 1}, {"K", 1 << 10}, {"KiB", 1 << 10}, {"KB", 1e3}, {"M", 1 << 20}, {"MiB", 1 << 20}, {"MB", 1e6},
	{"G", 1 << 30}, {"GiB", 1 << 30}, {"GB", 1e9}, {"T", 1 << 40}, {"TiB", 1 << 40}, {"TB", 1e12},
}
@(private = "file", rodata) DURATION_SUFFIXES := [?]Suffix{{"ms", 1}, {"s", MS_PER_S}, {"min", 60 * MS_PER_S}, {"h", 3600 * MS_PER_S}, {"d", 86400 * MS_PER_S}}

// The number of `text` in the stored unit of `d`, read with the suffixes its kind takes: a Size's and a Duration's
// convert ("4 MiB", "1.5 s"); a Length, a Factor or a Rate take their own symbol ("12 px", "1.5x"); a Fraction takes
// "%". A bare number is in the setting's unit; a Fraction's is the stored share unless `shown` (the percent a field
// shows). ok false: no number, or a suffix of another unit.
measure_parse :: proc(d: Def, text: string, shown := false) -> (v: f64, ok: bool) {
	t := strings.trim_space(text)
	t, _ = strings.replace_all(t, "_", "", context.temp_allocator)
	// the number: its digits up to the first letter or symbol (a decimal written "1,5" too, as the language writes it)
	end := 0
	for end < len(t) {
		c := t[end]
		if (c >= '0' && c <= '9') || c == '.' || c == ',' || c == '-' || c == '+' || ((c == 'e' || c == 'E') && end > 0 && end + 1 < len(t) && (t[end + 1] == '-' || t[end + 1] == '+' || (t[end + 1] >= '0' && t[end + 1] <= '9'))) {
			end += 1
			continue
		}
		break
	}
	num := strings.trim_space(t[:end])
	suffix := strings.trim_space(t[end:])
	n, nok := i18n.parse_decimal(num)
	if !nok || math.is_nan(n) || math.is_inf(n) { return 0, false }
	if suffix == "" {
		if d.value_kind == .Fraction && shown { return n / PERCENT, true }
		return n, true
	}
	u := unit_of(d)
	#partial switch d.value_kind {
	case .Size, .Duration:
		list := d.value_kind == .Size ? SIZE_SUFFIXES[:] : DURATION_SUFFIXES[:]
		for s in list {
			// (case aside: "mib" is what a person typing fast means by MiB; no two suffixes differ by case alone)
			if !ascii.equal_fold(s.text, suffix) { continue }
			return n * s.scale / UNITS[u].scale, true
		}
		return 0, false
	case .Fraction:
		if suffix == "%" { return n / PERCENT, true }
		return 0, false
	case .Factor:
		if suffix == "×" || suffix == "x" || suffix == "X" { return n, true }
		return 0, false
	case .Length, .Rate:
		if ascii.equal_fold(suffix, UNITS[u].symbol) { return n, true }
		return 0, false
	}
	return 0, false
}

// parse_value of what a field shows: a Fraction's bare number is its percent.
parse_shown :: proc(d: Def, text: string) -> (v: Value, err: Set_Error) {
	if d.value_kind != .Fraction { return parse_value(d, text) }
	n, ok := measure_parse(d, text, shown = true)
	if !ok { return {}, .Bad_Type }
	return parse_value(d, float_text(n))
}

// The text a person reads for value `v` of `d` (temporary allocator): a number with its unit ("300 ms", "45 %",
// "4 MiB": the largest unit at which a size is exact to two decimals); a text as it is. Not the file's text (value_string).
shown_text :: proc(d: Def, v: Value) -> string {
	switch d.kind {
	case .Bool:   return v.b ? "true" : "false"
	case .String: return v.s
	case .Int, .Float:
	}
	n := d.kind == .Int ? f64(v.i) : v.f
	if d.value_kind == .Size { return size_text(n * UNITS[unit_of(d)].scale) }
	n *= shown_scale(d)
	digits := d.kind == .Int && d.value_kind != .Fraction ? fmt.tprintf("%d", i64(n)) : i18n.decimal_marks(float_text(round_shown(n)))
	sym := unit_symbol(d)
	return sym == "" ? digits : fmt.tprintf("%s %s", digits, sym)
}

// (a share times 100 leaves a binary tail: 0.07 is 7.000000000000001 %)
@(private = "file")
round_shown :: proc(n: f64) -> f64 {
	SHOWN_DIGITS :: 1e9
	return math.round(n * SHOWN_DIGITS) / SHOWN_DIGITS
}

// A count of bytes in the largest binary unit at which it is exact to two decimals (so the text reads back the same).
@(private = "file")
size_text :: proc(bytes: f64) -> string {
	NAMES := [?]string{"B", "KiB", "MiB", "GiB", "TiB"}
	CENTS :: 100
	for k := len(NAMES) - 1; k > 0; k -= 1 {
		unit := math.pow(1024, f64(k))
		if abs(bytes) < unit { continue }
		x := bytes / unit
		if math.round(x * CENTS) / CENTS * unit != bytes { continue }
		return fmt.tprintf("%s %s", i18n.decimal_marks(float_text(math.round(x * CENTS) / CENTS)), NAMES[k])
	}
	return fmt.tprintf("%d B", i64(bytes))
}

// The value kind named `name` (VALUE_KIND_NAMES), case aside.
value_kind_of :: proc(name: string) -> (vk: Value_Kind, ok: bool) {
	for n, k in VALUE_KIND_NAMES { if ascii.equal_fold(n, name) { return k, true } }
	return
}

package tk_i18n

// Numbers as the language in use writes them: its decimal mark ("7,8" in French, "7.8" in English) and its percent
// ("34 %" with a no-break space in French, "34%" in English). Every number a person reads goes through these, as every text
// goes through tr: the toolkit's settings, diagnostics, sizes and percents, and a program's own (docs/i18n.md).

import "core:fmt"
import "core:strconv"
import "core:strings"

// The decimal mark and whether a percent's sign has a space before it, for a language's primary subtag.
@(private)
number_style :: proc(primary: string) -> (mark: u8, percent_gap: bool) {
	// (CLDR's decimal symbol and percent pattern of each language)
	switch primary {
	case "fr", "de", "sv", "nb", "nn", "no", "da", "fi", "cs", "sk", "ru", "uk", "bg", "hu", "et", "es":
		return ',', true
	case "it", "pt", "nl", "pl", "tr", "el", "ro", "hr", "sl", "lt", "lv", "id", "vi":
		return ',', false
	}
	return '.', false   // English, Japanese, Chinese, Korean, Thai, Hebrew...
}

// The decimal mark of the language in use: ',' in French, '.' in English (no language in use).
decimal_mark :: proc "contextless" () -> u8 {
	l := current()
	return l != nil && l.decimal_mark != 0 ? l.decimal_mark : '.'
}

// `value` with `decimals` digits after the language's decimal mark: decimal(7.84, 1) is "7.8" in English, "7,8" in French.
decimal :: proc(value: f64, decimals: int, allocator := context.temp_allocator) -> string {
	d := clamp(decimals, 0, 9)
	s := fmt.aprintf(fmt.tprintf("%%.%df", d), value, allocator = allocator)
	mark := decimal_mark()
	if mark != '.' {
		b := transmute([]u8)s
		for c, i in b { if c == '.' { b[i] = mark } }
	}
	return s
}

// The share `share` (1 is all of it) as a percent with `decimals` digits: percent(0.34) is "34%" in English, "34 %" in
// French (a no-break space: the sign never starts a line).
percent :: proc(share: f64, decimals := 0, allocator := context.temp_allocator) -> string {
	n := decimal(share * 100, decimals, context.temp_allocator)
	l := current()
	gap := l != nil && l.percent_gap ? NO_BREAK_SPACE : ""
	return strings.concatenate({n, gap, "%"}, allocator)
}

// A text a printf made of numbers ("%.1f ms"), its decimal points as the language in use writes them: a '.' between two
// digits becomes the decimal mark. For a format a program keeps (a slider's "%.2f"); a number made here is decimal's. The
// text itself in a language that writes '.'.
decimal_marks :: proc(text: string, allocator := context.temp_allocator) -> string {
	mark := decimal_mark()
	if mark == '.' || strings.index_byte(text, '.') < 0 { return text }
	b := transmute([]u8)strings.clone(text, allocator)
	for i in 1 ..< max(len(b) - 1, 1) {
		if b[i] == '.' && is_digit(b[i - 1]) && is_digit(b[i + 1]) { b[i] = mark }
	}
	return string(b)
}

// A number a person typed, with either decimal mark ("7,8" or "7.8"), spaces around it allowed; ok false when it is not one.
parse_decimal :: proc(text: string) -> (value: f64, ok: bool) {
	t := strings.trim_space(text)
	if strings.index_byte(t, ',') >= 0 && strings.index_byte(t, '.') < 0 {
		t, _ = strings.replace_all(t, ",", ".", context.temp_allocator)
	}
	return strconv.parse_f64(t)
}

@(private = "file")
is_digit :: #force_inline proc(c: u8) -> bool { return c >= '0' && c <= '9' }

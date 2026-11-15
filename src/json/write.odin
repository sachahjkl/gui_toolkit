package tk_json

// JSON text written as the program walks its data: string literals with one set of escapes, and a writer that places the
// commas and the colons (src/md/features/json.md).

import "core:encoding/json"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "../ascii"

// The quotes and a few escapes before the builder grows.
QUOTE_SPARE_BYTES :: 8

// `s` as a JSON string literal, quotes included. In temp memory by default: it goes into a request's body, made at once.
quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, len(s) + QUOTE_SPARE_BYTES, allocator)
	quote_into(&b, s)
	return strings.to_string(b)
}

// `s` as a JSON string literal, written to `b`: `"` and `\` escaped, `\b \f \n \r \t` by their letter, the other control
// characters and DEL as \u00XX, text past ASCII as UTF-8, a byte that is no UTF-8 as U+FFFD.
quote_into :: proc(b: ^strings.Builder, s: string) {
	HEX := "0123456789ABCDEF"
	strings.write_byte(b, '"')
	rest := s
	for len(rest) > 0 {
		// a data URL is megabytes with nothing to escape: copy the runs whole
		k := ascii.index_any_byte(rest, "\"\\\x7f", below = 0x20, non_ascii = true)
		if k < 0 { strings.write_string(b, rest); break }
		strings.write_string(b, rest[:k])
		rest = rest[k:]
		if rest[0] >= 0x80 {
			run := 0
			for run < len(rest) && rest[run] >= 0x80 {
				r, w := utf8.decode_rune_in_string(rest[run:])
				if r == utf8.RUNE_ERROR && w <= 1 {
					strings.write_string(b, rest[:run])
					strings.write_string(b, "�")
					rest, run = rest[run + 1:], 0
					continue
				}
				run += w
			}
			strings.write_string(b, rest[:run])
			rest = rest[run:]
			continue
		}
		switch c := rest[0]; c {
		case '"':  strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\b': strings.write_string(b, `\b`)
		case '\f': strings.write_string(b, `\f`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case:
			strings.write_string(b, `\u00`)
			strings.write_byte(b, HEX[c >> 4])
			strings.write_byte(b, HEX[c & 0xF])
		}
		rest = rest[1:]
	}
	strings.write_byte(b, '"')
}

// `f` in its shortest form that reads back to the same bits; `null` for NaN and the infinities, which JSON cannot hold.
// A whole float is written without a decimal point ("2"): a reader that keeps the type of a number needs `.0` added.
write_float :: proc(b: ^strings.Builder, f: f64) {
	if math.is_nan(f) || math.is_inf(f) { strings.write_string(b, "null"); return }
	buf: [64]u8
	strings.write_string(b, strconv.write_float(buf[:], f, 'g', -1, 64, nil))
}

// The levels of nesting a Writer tracks.
WRITER_DEPTH_MAX :: 64

// A writer of one JSON document to a builder. Begin and end the objects and arrays, give each member of an object its
// `key` before its value; the writer places the commas, the colons and, with an indent, the line breaks.
Writer :: struct {
	b:      ^strings.Builder,
	indent: string,                                // "": one line; else written once per level before each item
	depth:  int,
	filled: bit_set[0 ..< WRITER_DEPTH_MAX; u64],  // the levels that hold an item: the next one needs a comma
	keyed:  bool,                                  // a key was written: its value follows it, with no comma
}

// A writer to `b`. With an `indent` ("  "), every item is on its own line and a key is followed by ": ".
writer_make :: proc(b: ^strings.Builder, indent := "") -> Writer {
	return Writer{b = b, indent = indent}
}

// The place of a new item: the comma after the previous one and its line, unless it is a key's value.
@(private = "file")
item :: proc(w: ^Writer) {
	if w.keyed { w.keyed = false; return }
	if w.depth == 0 { return }
	level := w.depth - 1
	if level in w.filled { strings.write_byte(w.b, ',') }
	w.filled += {level}
	line(w, w.depth)
}

@(private = "file")
line :: proc(w: ^Writer, depth: int) {
	if w.indent == "" { return }
	strings.write_byte(w.b, '\n')
	for _ in 0 ..< depth { strings.write_string(w.b, w.indent) }
}

@(private = "file")
open :: proc(w: ^Writer, c: u8) {
	item(w)
	assert(w.depth < WRITER_DEPTH_MAX, "tk_json.Writer: nesting deeper than WRITER_DEPTH_MAX")
	strings.write_byte(w.b, c)
	w.filled -= {w.depth}
	w.depth += 1
}

@(private = "file")
close :: proc(w: ^Writer, c: u8) {
	assert(w.depth > 0, "tk_json.Writer: an end with no begin")
	w.depth -= 1
	// an empty object or array stays on its line: "{}"
	if w.depth in w.filled { line(w, w.depth) }
	strings.write_byte(w.b, c)
}

begin_object :: proc(w: ^Writer) { open(w, '{') }
end_object   :: proc(w: ^Writer) { close(w, '}') }
begin_array  :: proc(w: ^Writer) { open(w, '[') }
end_array    :: proc(w: ^Writer) { close(w, ']') }

// The key of the next member of the current object.
key :: proc(w: ^Writer, k: string) {
	item(w)
	quote_into(w.b, k)
	strings.write_string(w.b, w.indent == "" ? ":" : ": ")
	w.keyed = true
}

write_text :: proc(w: ^Writer, s: string) {
	item(w)
	quote_into(w.b, s)
}

write_integer :: proc(w: ^Writer, n: i64) {
	item(w)
	strings.write_i64(w.b, n)
}

// A float in its shortest form (write_float); `null` for NaN and the infinities.
write_number :: proc(w: ^Writer, f: f64) {
	item(w)
	write_float(w.b, f)
}

write_boolean :: proc(w: ^Writer, on: bool) {
	item(w)
	strings.write_string(w.b, on ? "true" : "false")
}

write_null :: proc(w: ^Writer) {
	item(w)
	strings.write_string(w.b, "null")
}

// JSON text that the caller made (a number in a format of its own, a document read elsewhere), written as it is.
write_raw :: proc(w: ^Writer, json_text: string) {
	item(w)
	strings.write_string(w.b, json_text)
}

// A parsed value, whole. An object's keys are written sorted: the same value gives the same bytes.
write_value :: proc(w: ^Writer, v: json.Value) {
	switch x in v {
	case nil, json.Null: write_null(w)
	case json.Integer:   write_integer(w, x)
	case json.Float:     write_number(w, x)
	case json.Boolean:   write_boolean(w, x)
	case json.String:    write_text(w, x)
	case json.Array:
		begin_array(w)
		for e in x { write_value(w, e) }
		end_array(w)
	case json.Object:
		keys := make([]string, len(x), context.temp_allocator)
		i := 0
		for k in x { keys[i] = k; i += 1 }
		slice.sort(keys)
		begin_object(w)
		for k in keys {
			key(w, k)
			write_value(w, x[k])
		}
		end_object(w)
	}
}

// The words `display` says for what has no text of its own: a program gives them in its language.
Display_Words :: struct {
	yes, no, null: string,
}

DISPLAY_WORDS :: Display_Words{yes = "yes", no = "no", null = "—"}

// A value as a person reads it, not as JSON: a string without its quotes, a number as written, a boolean and null as
// `words` say; an object or an array as JSON text, indented by `indent`. In temp memory by default.
display :: proc(v: json.Value, words := DISPLAY_WORDS, indent := "  ", allocator := context.temp_allocator) -> string {
	#partial switch x in v {
	case json.String:  return strings.clone(string(x), allocator)
	case json.Boolean: return x ? words.yes : words.no
	case json.Null:    return words.null
	case json.Integer, json.Float: return to_text(v, "", allocator)
	}
	return to_text(v, indent, allocator)
}

// A parsed value as JSON text, with an indent per level ("": one line). In temp memory by default, as quote.
to_text :: proc(v: json.Value, indent := "", allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	w := writer_make(&b, indent)
	write_value(&w, v)
	return strings.to_string(b)
}

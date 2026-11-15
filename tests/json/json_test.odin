// The JSON helper: the quoter's escapes and its policy for bytes that are no UTF-8, path reads that never panic, the writer
// read back by core:encoding/json.
//   odin test tests/json -vet
package json_test

import "core:encoding/json"
import "core:math"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import tk_json "../../src/json"

// The quoter a rune at a time, as the policy says it: the reference of the one that copies runs whole.
@(private = "file")
quote_reference :: proc(s: string) -> string {
	HEX := "0123456789ABCDEF"
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\b': strings.write_string(&b, `\b`)
		case '\f': strings.write_string(&b, `\f`)
		case '\n': strings.write_string(&b, `\n`)
		case '\r': strings.write_string(&b, `\r`)
		case '\t': strings.write_string(&b, `\t`)
		case:
			if r < 0x20 || r == 0x7F {
				strings.write_string(&b, `\u00`)
				strings.write_byte(&b, HEX[int(r) >> 4])
				strings.write_byte(&b, HEX[int(r) & 0xF])
			} else {
				// (a byte that is no UTF-8 comes as RUNE_ERROR, which is U+FFFD)
				strings.write_rune(&b, r)
			}
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

@(test)
quote_escapes_what_json_needs :: proc(t: ^testing.T) {
	Case :: struct { s, want: string }
	cases := []Case{
		{"", `""`},
		{"plain", `"plain"`},
		{`say "hi" \ back`, `"say \"hi\" \\ back"`},
		{"\b\f\n\r\t", `"\b\f\n\r\t"`},
		{"\x00\x01\x1f\x7f", `"\u0000\u0001\u001F\u007F"`},
		{"/ and ' stay", `"/ and ' stay"`},
		{"é 中文 \U0001F600", "\"é 中文 \U0001F600\""},
		{"�", "\"�\""},
		{"\xff", "\"�\""},
		{"a\xffb", "\"a�b\""},
		{"é\xffé", "\"é�é\""},
		{"\xc3", "\"�\""},
	}
	for c in cases {
		got := tk_json.quote(c.s, context.temp_allocator)
		testing.expectf(t, got == c.want, "quote(% x) = %q, not %q", transmute([]u8)c.s, got, c.want)
	}
}

// The runs copied whole give the bytes of a rune at a time: every byte value, an escape or a rune past ASCII at every
// place of every length up to 40 (two registers and every tail), bytes that are no UTF-8 among them. The result is
// always valid UTF-8.
@(test)
quote_is_the_rune_at_a_time_one :: proc(t: ^testing.T) {
	all: [256]u8
	for &c, i in all { c = u8(i) }
	for c in 0 ..< 256 {
		s := string(all[c:c + 1])
		testing.expectf(t, tk_json.quote(s, context.temp_allocator) == quote_reference(s), "byte %02x", c)
	}
	testing.expect(t, tk_json.quote(string(all[:]), context.temp_allocator) == quote_reference(string(all[:])), "every byte")
	INSERTS :: [?]string{"\"", "\\", "\n", "\x00", "\x1f", "\x7f", "é", "中文", "\U0001F600", "\xff", "\x80", "\xe2\x82", "\xc0\x80", "\xed\xa0\x80"}
	inserts := INSERTS
	for n in 0 ..= 40 {
		plain := strings.repeat("aB0+/=", 7, context.temp_allocator)[:n]
		for at in 0 ..= n {
			for ins in inserts {
				s := strings.concatenate({plain[:at], ins, plain[at:]}, context.temp_allocator)
				got := tk_json.quote(s, context.temp_allocator)
				testing.expectf(t, got == quote_reference(s), "% x", transmute([]u8)s)
				testing.expectf(t, utf8.valid_string(got), "% x gives valid UTF-8", transmute([]u8)s)
			}
		}
	}
	url := strings.concatenate({"data:image/png;base64,", strings.repeat("iVBORw0KGgo+/=", 100_000, context.temp_allocator)}, context.temp_allocator)
	testing.expect_value(t, len(tk_json.quote(url, context.temp_allocator)), len(url) + 2)
}

// A quoted string reads back, with core:encoding/json, as the string: every ASCII character and runs past ASCII.
@(test)
quote_reads_back :: proc(t: ^testing.T) {
	ascii: [128]u8
	for &c, i in ascii { c = u8(i) }
	for s in ([]string{string(ascii[:]), "é 中文 \U0001F600 �", ""}) {
		text := tk_json.quote(s, context.temp_allocator)
		v, err := json.parse_string(text, spec = .JSON, allocator = context.temp_allocator)
		testing.expectf(t, err == .None, "%q parses: %v", text, err)
		got, is_string := v.(json.String)
		testing.expectf(t, is_string && got == s, "%q reads back as %q", text, got)
	}
}

DOC :: `{"a": {"b": "x", "n": 3, "neg": -4, "f": 2.5, "w": 3.0, "big": 1e300, "t": true, "z": null,
	"list": [10, "s", {"k": "v"}, [true]]}}`

@(private = "file")
parsed :: proc(t: ^testing.T) -> json.Value {
	v, err := json.parse_string(DOC, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	testing.expectf(t, err == .None, "the document parses: %v", err)
	return v
}

@(test)
reads_follow_keys :: proc(t: ^testing.T) {
	v := parsed(t)
	testing.expect_value(t, tk_json.text(v, "a", "b"), "x")
	testing.expect_value(t, tk_json.number(v, "a", "n"), 3.0)
	testing.expect_value(t, tk_json.number(v, "a", "f"), 2.5)
	testing.expect_value(t, tk_json.integer(v, "a", "n"), 3)
	testing.expect_value(t, tk_json.integer(v, "a", "neg"), -4)
	testing.expect_value(t, tk_json.integer(v, "a", "w"), 3)   // a whole float
	testing.expect_value(t, tk_json.boolean(v, "a", "t"), true)
	testing.expect(t, tk_json.object(v, "a") != nil, "an object")
	testing.expect_value(t, len(tk_json.array(v, "a", "list")), 4)
	key := "b"   // (a step that is a variable, not a literal)
	testing.expect_value(t, tk_json.text(v, "a", key), "x")
}

// A missing key, a step into a value that has none and a value of another type give the default; nothing panics.
@(test)
reads_give_the_default :: proc(t: ^testing.T) {
	v := parsed(t)
	testing.expect_value(t, tk_json.text(v, "a", "missing"), "")
	testing.expect_value(t, tk_json.text(v, "a", "missing", default = "d"), "d")
	testing.expect_value(t, tk_json.text(v, "a", "n", default = "d"), "d")
	testing.expect_value(t, tk_json.text(v, "a", "b", "deeper", default = "d"), "d")
	testing.expect_value(t, tk_json.text(v, "nothing", "at", "all", default = "d"), "d")
	testing.expect_value(t, tk_json.number(v, "a", "b", default = 7), 7.0)
	testing.expect_value(t, tk_json.number(v, "a", "t", default = 7), 7.0)
	testing.expect_value(t, tk_json.integer(v, "a", "f", default = 7), 7)     // not whole
	testing.expect_value(t, tk_json.integer(v, "a", "big", default = 7), 7)   // past i64
	testing.expect_value(t, tk_json.integer(v, "a", "b", default = 7), 7)
	testing.expect_value(t, tk_json.boolean(v, "a", "n", default = true), true)
	testing.expect_value(t, tk_json.boolean(v, "a", "z"), false)
	testing.expect(t, tk_json.array(v, "a", "b") == nil, "a string is no array")
	testing.expect(t, tk_json.array(v, "a", "missing") == nil, "a missing array is nil")
	testing.expect(t, tk_json.object(v, "a", "list") == nil, "an array is no object")
	testing.expect_value(t, tk_json.text(nil, "a"), "")
	testing.expect_value(t, tk_json.text(json.String("bare")), "bare")   // no path: the value itself
}

// The bounds of i64 as a float: -2^63 is one, 2^63 is past it.
@(test)
integer_takes_the_floats_of_i64 :: proc(t: ^testing.T) {
	testing.expect_value(t, tk_json.integer(json.Float(-9223372036854775808.0)), min(i64))
	testing.expect_value(t, tk_json.integer(json.Float(9223372036854775808.0), default = 7), 7)
	testing.expect_value(t, tk_json.integer(json.Float(math.inf_f64(1)), default = 7), 7)
	testing.expect_value(t, tk_json.integer(json.Float(math.nan_f64()), default = 7), 7)
}

@(test)
reads_follow_indices :: proc(t: ^testing.T) {
	v := parsed(t)
	testing.expect_value(t, tk_json.integer(v, "a", "list", 0), 10)
	testing.expect_value(t, tk_json.text(v, "a", "list", 1), "s")
	testing.expect_value(t, tk_json.text(v, "a", "list", 2, "k"), "v")
	testing.expect_value(t, tk_json.boolean(v, "a", "list", 3, 0), true)
	testing.expect_value(t, tk_json.text(v, "a", "list", -1, default = "d"), "d")
	testing.expect_value(t, tk_json.text(v, "a", "list", 4, default = "d"), "d")
	testing.expect_value(t, tk_json.text(v, "a", 0, default = "d"), "d")            // an index into an object
	testing.expect_value(t, tk_json.text(v, "a", "list", "k", default = "d"), "d")  // a key into an array
}

// Missing and null differ: get gives nil for the one and json.Null for the other.
@(test)
get_tells_missing_from_null :: proc(t: ^testing.T) {
	v := parsed(t)
	_, is_null := tk_json.get(v, "a", "z").(json.Null)
	testing.expect(t, is_null, "an explicit null")
	testing.expect(t, tk_json.has(v, "a", "z"), "a null is there")
	testing.expect(t, tk_json.get(v, "a", "missing") == nil, "a missing key is nil")
	testing.expect(t, !tk_json.has(v, "a", "missing"), "a missing key is not there")
}

@(private = "file")
document :: proc(w: ^tk_json.Writer) {
	tk_json.begin_object(w)
	tk_json.key(w, "s");   tk_json.write_text(w, "a\"b\n")
	tk_json.key(w, "n");   tk_json.write_integer(w, -12)
	tk_json.key(w, "f");   tk_json.write_number(w, 0.5)
	tk_json.key(w, "t");   tk_json.write_boolean(w, true)
	tk_json.key(w, "z");   tk_json.write_null(w)
	tk_json.key(w, "arr")
	tk_json.begin_array(w)
	tk_json.write_integer(w, 1)
	tk_json.begin_array(w); tk_json.end_array(w)
	tk_json.begin_object(w); tk_json.end_object(w)
	tk_json.write_raw(w, "2.0")
	tk_json.end_array(w)
	tk_json.key(w, "o")
	tk_json.begin_object(w)
	tk_json.key(w, "k");   tk_json.write_text(w, "v")
	tk_json.end_object(w)
	tk_json.end_object(w)
}

@(test)
writer_places_commas_and_colons :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	w := tk_json.writer_make(&b)
	document(&w)
	testing.expect_value(t, strings.to_string(b), `{"s":"a\"b\n","n":-12,"f":0.5,"t":true,"z":null,"arr":[1,[],{},2.0],"o":{"k":"v"}}`)
}

@(test)
writer_indents_one_item_per_line :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	w := tk_json.writer_make(&b, indent = "  ")
	tk_json.begin_object(&w)
	tk_json.key(&w, "a"); tk_json.write_integer(&w, 1)
	tk_json.key(&w, "b")
	tk_json.begin_array(&w)
	tk_json.write_integer(&w, 2)
	tk_json.write_integer(&w, 3)
	tk_json.end_array(&w)
	tk_json.key(&w, "c"); tk_json.begin_object(&w); tk_json.end_object(&w)
	tk_json.end_object(&w)
	testing.expect_value(t, strings.to_string(b), "{\n  \"a\": 1,\n  \"b\": [\n    2,\n    3\n  ],\n  \"c\": {}\n}")
	strings.builder_reset(&b)
	w = tk_json.writer_make(&b, indent = "  ")
	tk_json.begin_object(&w); tk_json.end_object(&w)
	testing.expect_value(t, strings.to_string(b), "{}")
}

// What the writer writes, compact or indented, reads back with core:encoding/json as what it was given.
@(test)
writer_reads_back :: proc(t: ^testing.T) {
	for indent in ([]string{"", "  ", "\t"}) {
		b := strings.builder_make(context.temp_allocator)
		w := tk_json.writer_make(&b, indent)
		document(&w)
		v, err := json.parse_string(strings.to_string(b), spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
		testing.expectf(t, err == .None, "%q parses: %v", strings.to_string(b), err)
		testing.expect_value(t, tk_json.text(v, "s"), "a\"b\n")
		testing.expect_value(t, tk_json.integer(v, "n"), -12)
		testing.expect_value(t, tk_json.number(v, "f"), 0.5)
		testing.expect_value(t, tk_json.boolean(v, "t"), true)
		_, is_null := tk_json.get(v, "z").(json.Null)
		testing.expect(t, is_null, "null")
		testing.expect_value(t, len(tk_json.array(v, "arr")), 4)
		testing.expect_value(t, tk_json.number(v, "arr", 3), 2.0)
		testing.expect_value(t, tk_json.text(v, "o", "k"), "v")
	}
}

// A float is written in its shortest form that reads back to the same bits; JSON has no NaN nor infinity.
@(test)
floats_read_back_to_the_bit :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	for f in ([]f64{0, 0.1, 0.30000000000000004, 1e300, -5e-324, 2, 123456789.125}) {
		strings.builder_reset(&b)
		tk_json.write_float(&b, f)
		v, err := json.parse_string(strings.to_string(b), spec = .JSON, allocator = context.temp_allocator)
		testing.expectf(t, err == .None, "%q parses", strings.to_string(b))
		got := tk_json.number(v)
		testing.expectf(t, transmute(u64)got == transmute(u64)f, "%v reads back as %v (%q)", f, got, strings.to_string(b))
	}
	for f in ([]f64{math.nan_f64(), math.inf_f64(1), math.inf_f64(-1)}) {
		strings.builder_reset(&b)
		tk_json.write_float(&b, f)
		testing.expect_value(t, strings.to_string(b), "null")
	}
}

// A parsed value written whole gives the same bytes each time (sorted keys), and reads back as itself.
@(test)
a_value_writes_back :: proc(t: ^testing.T) {
	v := parsed(t)
	once := tk_json.to_text(v, allocator = context.temp_allocator)
	again, err := json.parse_string(once, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	testing.expectf(t, err == .None, "%q parses: %v", once, err)
	testing.expect_value(t, tk_json.to_text(again, allocator = context.temp_allocator), once)
	// (keys sorted; the whole float 3.0 is written "3")
	testing.expectf(t, strings.has_prefix(once, `{"a":{"b":"x","big":`), "%s", once)
	testing.expectf(t, strings.has_suffix(once, `,"f":2.5,"list":[10,"s",{"k":"v"},[true]],"n":3,"neg":-4,"t":true,"w":3,"z":null}}`), "%s", once)
}

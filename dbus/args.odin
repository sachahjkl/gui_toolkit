package dbus

// Convenience builders for the common call-body shapes, and small reader helpers. A caller marshals a body with a
// Writer and these helpers, then passes writer.buf[:] to call / call_async. Pure; the Writer carries its allocator.

import "base:runtime"

// A fresh body writer on the temp allocator (the common case: the bytes are copied into the framed message by send).
body_writer :: proc(allocator := context.temp_allocator) -> Writer { return writer_make(allocator) }

// A variant holding one basic value: the signature then the value (used everywhere portals and properties want "v").
arg_variant_string :: proc(w: ^Writer, s: string) { w_signature(w, "s"); w_string(w, s) }
arg_variant_bool   :: proc(w: ^Writer, v: bool)    { w_signature(w, "b"); w_bool(w, v) }
arg_variant_u32    :: proc(w: ^Writer, v: u32)     { w_signature(w, "u"); w_u32(w, v) }
arg_variant_i32    :: proc(w: ^Writer, v: i32)     { w_signature(w, "i"); w_i32(w, v) }
arg_variant_object :: proc(w: ^Writer, s: string)  { w_signature(w, "o"); w_string(w, s) }

// Writes an a{sv} dictionary header and returns the bookkeeping for arg_dict_end. Each entry: arg_dict_entry then a
// variant value.
arg_dict_begin :: proc(w: ^Writer) -> (len_at, content_at: int) { return w_array_begin(w, 8) }
arg_dict_end   :: proc(w: ^Writer, len_at, content_at: int)     { w_array_end(w, len_at, content_at) }
arg_dict_entry :: proc(w: ^Writer, key: string) { w_struct(w); w_string(w, key) }

// Reads one string out of a reader positioned at a string value.
read_string :: proc(r: ^Reader) -> string { return r_string(r) }

// Reads a variant's basic value as a string when it is one ("s" / "o" / "g"), else "".
read_variant_string :: proc(r: ^Reader) -> string {
	vs := r_variant_sig(r)
	switch vs {
	case "s", "o": return r_string(r)
	case "g":      return r_signature(r)
	}
	r_skip(r, vs)
	return ""
}

// Reads a variant's value as a bool when it is one, else false.
read_variant_bool :: proc(r: ^Reader) -> bool {
	vs := r_variant_sig(r)
	if vs == "b" { return r_bool(r) }
	if vs == "u" || vs == "i" { return r_u32(r) != 0 }
	r_skip(r, vs)
	return false
}

// Reads a variant's value as a u32 when it is an integer, else 0.
read_variant_u32 :: proc(r: ^Reader) -> u32 {
	vs := r_variant_sig(r)
	switch vs {
	case "u", "i": return r_u32(r)
	case "y":      return u32(r_u8(r))
	case "q", "n": return u32(r_u16(r))
	case "t", "x": return u32(r_u64(r))
	}
	r_skip(r, vs)
	return 0
}

// Reads a variant and unwraps nested variants until a basic value, returning it as a u32 (portals sometimes wrap a
// value in v(v(u))). 0 when not an integer.
read_variant_u32_nested :: proc(r: ^Reader) -> u32 {
	vs := r_variant_sig(r)
	for vs == "v" { vs = r_variant_sig(r) }
	switch vs {
	case "u", "i": return r_u32(r)
	case "y":      return u32(r_u8(r))
	case "q", "n": return u32(r_u16(r))
	case "t", "x": return u32(r_u64(r))
	}
	r_skip(r, vs)
	return 0
}

// Reads and discards one variant value (its signature then the value).
read_variant_skip :: proc(r: ^Reader) {
	vs := r_variant_sig(r)
	r_skip(r, vs)
}

// Aligns the reader to a dict-entry / struct boundary (8), before reading an entry inside an a{..} loop.
r_align_entry :: proc(r: ^Reader) { r_align(r, 8) }

_ :: runtime

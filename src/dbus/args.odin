package dbus

// Convenience builders for the common call-body shapes, and small reader helpers. A caller marshals a body with a
// Writer and these helpers, then passes writer.buf[:] to call / call_async. Pure; the Writer carries its allocator.

import "base:runtime"

// A fresh body writer on the temp allocator (the common case: the bytes are copied into the framed message by send).
body_writer :: proc(allocator := context.temp_allocator) -> Writer { return writer_make(allocator) }

// A variant holding one basic value: the signature then the value (used everywhere portals and properties want "v").
arg_variant_string :: proc(w: ^Writer, s: string) { w_signature(w, "s"); w_string(w, s) }
arg_variant_bool   :: proc(w: ^Writer, v: bool)    { w_signature(w, "b"); w_bool(w, v) }
arg_variant_i32    :: proc(w: ^Writer, v: i32)     { w_signature(w, "i"); w_i32(w, v) }
arg_variant_object :: proc(w: ^Writer, s: string)  { w_signature(w, "o"); w_string(w, s) }

// Writes an a{sv} dictionary header and returns the bookkeeping for arg_dict_end. Each entry: arg_dict_entry then a
// variant value.
arg_dict_begin :: proc(w: ^Writer) -> (len_at, content_at: int) { return w_array_begin(w, STRUCT_ALIGN) }
arg_dict_end   :: proc(w: ^Writer, len_at, content_at: int)     { w_array_end(w, len_at, content_at) }
arg_dict_entry :: proc(w: ^Writer, key: string) { w_struct(w); w_string(w, key) }

// Reads one string out of a reader positioned at a string value.
read_string :: proc(r: ^Reader) -> string { return r_string(r) }

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

// Aligns the reader to a dict-entry / struct boundary, before reading an entry inside an a{..} loop.
r_align_entry :: proc(r: ^Reader) { r_align(r, STRUCT_ALIGN) }

_ :: runtime

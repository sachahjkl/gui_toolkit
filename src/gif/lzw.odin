// GIF's LZW (GIF89a, appendix F): codes of variable width (min_size + 1 to 12 bits), a clear code first and whenever the
// 4096 codes are taken, the end code last; the bits least significant first, in sub-blocks of at most 255 bytes.
package gif

import "base:runtime"
import "core:mem"

@(private = "file") MAX_BITS :: 12
@(private = "file") MAX_CODES :: 1 << MAX_BITS
@(private = "file") SLOTS :: 1 << 13   // the dictionary's hash: at most 4096 strings, half full
@(private = "file") BLOCK :: 255

// The dictionary: the string `prefix code` + `index` is `codes[h]` where keys[h] is (prefix << 8 | index) + 1 (0: empty).
@(private)
Lzw_State :: struct {
	keys:      []u32,
	codes:     []u16,
	allocator: runtime.Allocator,
}

@(private)
lzw_init :: proc(l: ^Lzw_State, allocator: runtime.Allocator) {
	l.allocator = allocator
	l.keys = make([]u32, SLOTS, allocator)
	l.codes = make([]u16, SLOTS, allocator)
}

@(private)
lzw_destroy :: proc(l: ^Lzw_State) {
	delete(l.keys, l.allocator)
	delete(l.codes, l.allocator)
}

// What packs the codes into sub-blocks: `size_at` is the length byte of the block being filled.
@(private = "file")
Bit_Out :: struct {
	out:     ^[dynamic]u8,
	bits:    u64,
	count:   uint,
	size_at: int,
	size:    int,
}

@(private = "file")
put_code :: #force_inline proc(w: ^Bit_Out, code: int, width: uint) {
	w.bits |= u64(code) << w.count
	w.count += width
	for w.count >= 8 {
		put_byte(w, u8(w.bits))
		w.bits >>= 8
		w.count -= 8
	}
}

@(private = "file")
put_byte :: #force_inline proc(w: ^Bit_Out, b: u8) {
	if w.size == BLOCK {
		w.out^[w.size_at] = BLOCK
		w.size_at = len(w.out^)
		append(w.out, 0)
		w.size = 0
	}
	append(w.out, b)
	w.size += 1
}

// The minimum code size byte, then `indices` (each < 1 << min_size) in sub-blocks, then the empty block that ends them.
@(private)
lzw_encode :: proc(l: ^Lzw_State, out: ^[dynamic]u8, indices: []u8, min_size: int) #no_bounds_check {
	append(out, u8(min_size))
	w := Bit_Out{out = out, size_at = len(out^)}
	append(out, 0)
	reserve(out, len(out^) + len(indices) / 2 + 16)   // (a guess at the size: the appends below seldom grow it)

	clear_code := 1 << uint(min_size)
	end_code := clear_code + 1
	width := uint(min_size + 1)
	next := end_code + 1
	mem.zero_slice(l.keys)
	put_code(&w, clear_code, width)

	prefix := int(indices[0])
	outer: for index in indices[1:] {
		key := (u32(prefix) << 8 | u32(index)) + 1
		h := (key * 0x9E3779B1) >> (32 - 13)   // (Fibonacci hashing to SLOTS)
		for l.keys[h] != 0 {
			if l.keys[h] == key {
				prefix = int(l.codes[h])
				continue outer
			}
			h = (h + 1) & (SLOTS - 1)
		}
		put_code(&w, prefix, width)
		if next < MAX_CODES {
			l.keys[h], l.codes[h] = key, u16(next)
			next += 1
			// (a decoder adds this string one code later, and widens when its next code reaches 1 << width: the
			// same code as here)
			if next > 1 << width && width < MAX_BITS { width += 1 }
		} else {
			put_code(&w, clear_code, width)
			mem.zero_slice(l.keys)
			width = uint(min_size + 1)
			next = end_code + 1
		}
		prefix = int(index)
	}
	put_code(&w, prefix, width)
	// (reading that last code, a decoder adds a string, unless it was the first after a clear: it may widen before the end code)
	if next > end_code + 1 && next == 1 << width && width < MAX_BITS { width += 1 }
	put_code(&w, end_code, width)
	if w.count > 0 { put_byte(&w, u8(w.bits)) }
	out^[w.size_at] = u8(w.size)
	if w.size > 0 { append(out, 0) }   // (an empty last block is the terminator itself)
}

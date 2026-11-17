package gt_base

// Big-endian integers in a byte slice, as file formats store them (OpenType tables, PNG chunks). A read past either end
// is ok = false with 0, never a panic: a font or a file is untrusted input. #optional_ok: a reader that checks the
// lengths itself takes the value alone, one that does not gets or_return.

// The unsigned 16 bits at `at` of `d`.
read_be16 :: proc "contextless" (d: []u8, at: int) -> (v: int, ok: bool) #optional_ok {
	if at < 0 || at > len(d) - 2 { return }
	return int(d[at]) << 8 | int(d[at + 1]), true
}

// The unsigned 32 bits at `at` of `d`.
read_be32 :: proc "contextless" (d: []u8, at: int) -> (v: int, ok: bool) #optional_ok {
	if at < 0 || at > len(d) - 4 { return }
	return int(d[at]) << 24 | int(d[at + 1]) << 16 | int(d[at + 2]) << 8 | int(d[at + 3]), true
}

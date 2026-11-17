package gt_base

import "core:testing"

// A read inside the slice gives its value; one that ends past the slice, or starts before it, gives no value and no panic.
@(test)
a_big_endian_read_past_the_end_is_no_value :: proc(t: ^testing.T) {
	d := []u8{0x12, 0x34, 0x56, 0x78, 0x9a}
	testing.expect_value(t, read_be16(d, 0), 0x1234)
	testing.expect_value(t, read_be32(d, 1), 0x3456789a)
	v, ok := read_be16(d, 3)
	testing.expect(t, ok && v == 0x789a)
	_, ok = read_be16(d, 4)
	testing.expect(t, !ok)
	_, ok = read_be32(d, 2)
	testing.expect(t, !ok)
	_, ok = read_be32(d, -1)
	testing.expect(t, !ok)
	_, ok = read_be16(nil, 0)
	testing.expect(t, !ok)
}

// gt:utf8: portable SIMD UTF-8 validation, sixteen bytes at a time (src/md/infrastructure/utf8.md).
// Algorithm: John Keiser and Daniel Lemire, "Validating UTF-8 In Less Than One Instruction Per Byte" (2021),
// ported from modus (work/utf8simd). Imports base:intrinsics only (no core: imports) so freestanding targets and
// modus can share the exact same algorithm and tests.
package tk_utf8

import "base:intrinsics"

@(private = "file")
Sixteen_Bytes :: #simd[16]u8

@(private = "file")
Sixteen_Signed_Bytes :: #simd[16]i8

// Bytes that a lead of 2, 3 or 4 bytes leaves to come, in bit 7 of a saturating subtraction:
// the last byte of a group from C0, the byte before it from E0, the byte before that from F0.
@(private = "file")
INCOMPLETE_SUBTRAHENDS :: Sixteen_Bytes{0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x70, 0x60, 0x40}

// Reports whether `bytes` is well-formed UTF-8 (RFC 3629). When `reject_controls` is true, also rejects C0 controls
// (U+0000..U+001F), DEL (U+007F), and C1 controls (U+0080..U+009F, encoded as C2 80..9F) in the same SIMD pass.
// Reads each byte once and never loads past `bytes`.
valid :: proc "contextless" (bytes: []u8, reject_controls := false) -> bool {
	if reject_controls { return valid_simd(bytes, true) }
	return valid_simd(bytes, false)
}

// Convenience wrapper of `valid` for a string.
valid_string :: proc "contextless" (s: string, reject_controls := false) -> bool {
	return valid(transmute([]u8)s, reject_controls)
}

// Scalar RFC 3629 reference: the oracle for fuzz and exhaustive tests.
valid_scalar :: proc "contextless" (bytes: []u8, reject_controls := false) -> bool {
	n := len(bytes)
	for i := 0; i < n; {
		b0 := bytes[i]
		if b0 < 0x80 {
			if reject_controls && (b0 <= 0x1F || b0 == 0x7F) { return false }
			i += 1
			continue
		}
		if b0 < 0xC2 || b0 > 0xF4 { return false }
		if b0 < 0xE0 {
			if i + 1 >= n { return false }
			b1 := bytes[i + 1]
			if b1 & 0xC0 != 0x80 { return false }
			if reject_controls && b0 == 0xC2 && b1 < 0xA0 { return false }
			i += 2
			continue
		}
		if b0 < 0xF0 {
			if i + 2 >= n { return false }
			b1, b2 := bytes[i + 1], bytes[i + 2]
			if b1 & 0xC0 != 0x80 || b2 & 0xC0 != 0x80 { return false }
			if b0 == 0xE0 && b1 < 0xA0 { return false }   // overlong
			if b0 == 0xED && b1 >= 0xA0 { return false }  // UTF-16 surrogates U+D800..U+DFFF
			i += 3
			continue
		}
		if i + 3 >= n { return false }
		b1, b2, b3 := bytes[i + 1], bytes[i + 2], bytes[i + 3]
		if b1 & 0xC0 != 0x80 || b2 & 0xC0 != 0x80 || b3 & 0xC0 != 0x80 { return false }
		if b0 == 0xF0 && b1 < 0x90 { return false }       // overlong
		if b0 == 0xF4 && b1 >= 0x90 { return false }      // above U+10FFFF
		i += 4
	}
	return true
}

@(private = "file")
valid_simd :: #force_inline proc "contextless" (bytes: []u8, $REJECT_CONTROLS: bool) -> bool {
	previous_group := Sixteen_Bytes(0)
	previous_incomplete := Sixteen_Bytes(0)
	place := 0
	for ; place + 16 <= len(bytes); place += 16 {
		group := intrinsics.unaligned_load((^Sixteen_Bytes)(&bytes[place]))
		errors := group_errors(group, previous_group, &previous_incomplete, REJECT_CONTROLS)
		if intrinsics.simd_extract_msbs(errors) != {} { return false }
		previous_group = group
	}
	if place < len(bytes) {
		last_bytes: [16]u8 = ' '
		for value, index in bytes[place:] { last_bytes[index] = value }
		errors := group_errors(transmute(Sixteen_Bytes)last_bytes, previous_group, &previous_incomplete, REJECT_CONTROLS)
		return intrinsics.simd_extract_msbs(errors) == {}
	}
	return intrinsics.simd_extract_msbs(previous_incomplete) == {}
}

// Bit 7 of each lane is set where a byte breaks UTF-8 (or the control rule when REJECT_CONTROLS).
@(private = "file")
group_errors :: #force_inline proc "contextless" (group, previous_group: Sixteen_Bytes, previous_incomplete: ^Sixteen_Bytes, $REJECT_CONTROLS: bool) -> Sixteen_Bytes {
	if intrinsics.simd_extract_msbs(group) == {} {
		// ASCII group: no leads or continuations; only an unfinished lead from the previous group (or a control) fails.
		errors := previous_incomplete^
		when REJECT_CONTROLS { errors = intrinsics.simd_bit_or(control_bytes(group), errors) }
		previous_incomplete^ = 0
		return errors
	}
	one_before := intrinsics.simd_shuffle(previous_group, group, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30)
	two_before := intrinsics.simd_shuffle(previous_group, group, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29)
	three_before := intrinsics.simd_shuffle(previous_group, group, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28)

	// Continuation bytes are 10xxxxxx: adding group to itself moves bit 6 into bit 7, so bit 7 of (group & ~(group+group)) is 1 iff 10xxxxxx.
	continuation := intrinsics.simd_bit_and_not(group, group + group)
	expected := intrinsics.simd_bit_or(
		intrinsics.simd_saturating_sub(one_before, Sixteen_Bytes(0xC0 - 0x80)),
		intrinsics.simd_bit_or(
			intrinsics.simd_saturating_sub(two_before, Sixteen_Bytes(0xE0 - 0x80)),
			intrinsics.simd_saturating_sub(three_before, Sixteen_Bytes(0xF0 - 0x80)),
		),
	)
	count_errors := intrinsics.simd_bit_xor(continuation, expected)

	// C0 and C1 start only overlong forms; F5..FF are never valid UTF-8.
	no_lead := intrinsics.simd_bit_or(
		lanes_equal(intrinsics.simd_bit_and(group, Sixteen_Bytes(0xFE)), 0xC0),
		intrinsics.simd_saturating_sub(group, Sixteen_Bytes(0xF5 - 0x80)),
	)

	// Second-byte bounds via signed compare (one SSE2 instruction): as i8, 0x80..0x9F < -0x60 (0xA0) and 0x80..0x8F < -0x70 (0x90).
	below_a0_bytes := intrinsics.simd_lanes_lt(transmute(Sixteen_Signed_Bytes)group, Sixteen_Signed_Bytes(-0x60))
	below_90_bytes := intrinsics.simd_lanes_lt(transmute(Sixteen_Signed_Bytes)group, Sixteen_Signed_Bytes(-0x70))
	lead_below_a0 := lanes_equal(one_before, 0xE0)
	when REJECT_CONTROLS { lead_below_a0 = intrinsics.simd_bit_or(lead_below_a0, lanes_equal(one_before, 0xC2)) }
	bound_errors := intrinsics.simd_bit_or(
		intrinsics.simd_bit_or(
			intrinsics.simd_bit_and(lead_below_a0, below_a0_bytes),
			intrinsics.simd_bit_and_not(lanes_equal(one_before, 0xED), below_a0_bytes),
		),
		intrinsics.simd_bit_or(
			intrinsics.simd_bit_and(lanes_equal(one_before, 0xF0), below_90_bytes),
			intrinsics.simd_bit_and_not(lanes_equal(one_before, 0xF4), below_90_bytes),
		),
	)

	previous_incomplete^ = intrinsics.simd_saturating_sub(group, INCOMPLETE_SUBTRAHENDS)
	out := intrinsics.simd_bit_or(intrinsics.simd_bit_or(count_errors, no_lead), bound_errors)
	when REJECT_CONTROLS { out = intrinsics.simd_bit_or(out, control_bytes(group)) }
	return out
}

@(private = "file")
control_bytes :: #force_inline proc "contextless" (group: Sixteen_Bytes) -> Sixteen_Bytes {
	below_space := intrinsics.simd_lanes_le(group, Sixteen_Bytes(0x1F))
	return intrinsics.simd_bit_or(below_space, lanes_equal(group, 0x7F))
}

@(private = "file")
lanes_equal :: #force_inline proc "contextless" (group: Sixteen_Bytes, $VALUE: u8) -> Sixteen_Bytes {
	return intrinsics.simd_lanes_eq(group, Sixteen_Bytes(VALUE))
}

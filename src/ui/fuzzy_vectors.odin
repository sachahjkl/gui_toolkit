package ui

// Portable SIMD vector fast path for fuzzy_score_folded (src/md/features/fuzzy-frecency.md), ported from modus
// (work/fuzzymatch). Uses #simd[16]u8 and base:intrinsics (lowers to SSE2 on x86-64, NEON on ARM64).
// Produces the exact same score, ranges and match boolean as fuzzy_score_scalar for every input; any non-ASCII byte,
// needle longer than FUZZY_VEC_QUERY_MAX or haystack longer than FUZZY_VEC_NAME_MAX falls back to fuzzy_score_scalar.

import "base:intrinsics"
import "core:unicode"
import "core:unicode/utf8"

@(private = "file") FUZZY_VEC_BLOCK :: 16
@(private = "file") FUZZY_VEC_NAME_MAX :: 128
@(private = "file") FUZZY_VEC_QUERY_MAX :: 64
@(private = "file") FUZZY_VEC_BLOCKS :: FUZZY_VEC_NAME_MAX / FUZZY_VEC_BLOCK
#assert(FUZZY_VEC_NAME_MAX == 128 && FUZZY_VEC_NAME_MAX % FUZZY_VEC_BLOCK == 0)

@(private = "file")
Fuzzy_Block :: #simd[FUZZY_VEC_BLOCK]u8

@(private)
fuzzy_score_vectors :: proc(needle: Fuzzy_Needle, h: Fuzzy_Text, allocator := context.temp_allocator) -> (score: int, ranges: []Fuzzy_Range, ok: bool) {
	want := needle.want
	if len(want) == 0 { return 0, nil, true }
	hay, low := h.text, h.low
	if len(want) > FUZZY_VEC_QUERY_MAX || len(low) > FUZZY_VEC_NAME_MAX || len(hay) != len(low) {
		return fuzzy_score_scalar(needle, h, allocator)
	}
	if len(low) == 0 { return 0, nil, false }

	// Check the needle is pure ASCII (len(want) == len(needle.runes) iff pure ASCII, also check high bit directly).
	if len(needle.runes) != len(want) { return fuzzy_score_scalar(needle, h, allocator) }
	for i in 0 ..< len(want) {
		if want[i] >= 0x80 { return fuzzy_score_scalar(needle, h, allocator) }
	}

	// Load `low` in 16-byte blocks (stack-copied tail so no load reads past the slice) and check for non-ASCII.
	length := len(low)
	block_count := (length + FUZZY_VEC_BLOCK - 1) / FUZZY_VEC_BLOCK
	low_ptr := raw_data(low)
	blocks: [FUZZY_VEC_BLOCKS]Fuzzy_Block = ---
	any_high: Fuzzy_Block
	for bi in 0 ..< block_count {
		start := bi * FUZZY_VEC_BLOCK
		blk: Fuzzy_Block
		if start + FUZZY_VEC_BLOCK <= length {
			blk = intrinsics.unaligned_load((^Fuzzy_Block)(&low_ptr[start]))
		} else {
			tail: [FUZZY_VEC_BLOCK]u8
			intrinsics.mem_copy_non_overlapping(&tail, &low_ptr[start], length - start)
			blk = transmute(Fuzzy_Block)tail
		}
		any_high = intrinsics.simd_bit_or(any_high, blk)
		blocks[bi] = blk
	}
	if intrinsics.simd_extract_msbs(any_high) != {} {
		return fuzzy_score_scalar(needle, h, allocator)
	}

	inside: u128 = length == FUZZY_VEC_NAME_MAX ? max(u128) : (u128(1) << uint(length)) - 1

	// Forward pass + per-character bitmasks: rejects non-matching candidates on the first missing character.
	masks: [FUZZY_VEC_QUERY_MAX]u128 = ---
	qlen := len(want)
	floor := 0
	end := 0
	for qi in 0 ..< qlen {
		wb := Fuzzy_Block(want[qi])
		mask: u128
		for bi in 0 ..< block_count {
			bits := transmute(u16)intrinsics.simd_extract_msbs(intrinsics.simd_lanes_eq(blocks[bi], wb))
			mask |= u128(bits) << uint(bi * FUZZY_VEC_BLOCK)
		}
		mask &= inside
		masks[qi] = mask
		if floor >= FUZZY_VEC_NAME_MAX { return 0, nil, false }
		after := mask & (max(u128) << uint(floor))
		if after == 0 { return 0, nil, false }
		end = int(intrinsics.count_trailing_zeros(after))
		floor = end + 1
	}

	// Backward pass: latest start ending at `end` (tightest window, identical to fuzzy_score_scalar).
	pos: [FUZZY_VEC_QUERY_MAX]int = ---
	ceiling := end
	for qi := qlen - 1; qi >= 0; qi -= 1 {
		at_or_below := ceiling >= FUZZY_VEC_NAME_MAX - 1 ? max(u128) : (u128(1) << uint(ceiling + 1)) - 1
		p := FUZZY_VEC_NAME_MAX - 1 - int(intrinsics.count_leading_zeros(masks[qi] & at_or_below))
		pos[qi] = p
		ceiling = p - 1
	}

	// Score and coalesce adjacent matched bytes into Fuzzy_Range runs (exact match with fuzzy_score_scalar).
	out := make([dynamic]Fuzzy_Range, 0, qlen, allocator)
	for j in 0 ..< qlen {
		p := pos[j]
		score += FUZZY_SCORE_CHAR
		if p == 0 {
			score += FUZZY_SCORE_TEXT_START
		} else {
			pb, cb := hay[p - 1], hay[p]
			if pb < 0x80 && cb < 0x80 {
				is_alnum := (pb >= 'a' && pb <= 'z') || (pb >= 'A' && pb <= 'Z') || (pb >= '0' && pb <= '9')
				if !is_alnum {
					score += FUZZY_SCORE_WORD_START
				} else if pb >= 'a' && pb <= 'z' && cb >= 'A' && cb <= 'Z' {
					score += FUZZY_SCORE_CAMEL_START
				}
			} else {
				prev, _ := utf8.decode_last_rune_in_string(hay[:p])
				cur, _ := utf8.decode_rune_in_string(hay[p:])
				if !unicode.is_letter(prev) && !unicode.is_digit(prev) {
					score += FUZZY_SCORE_WORD_START
				} else if unicode.is_lower(prev) && unicode.is_upper(cur) {
					score += FUZZY_SCORE_CAMEL_START
				}
			}
		}
		if j > 0 {
			gap := p - (pos[j - 1] + 1)
			if gap == 0 { score += FUZZY_SCORE_ADJACENT } else { score -= min(gap, FUZZY_GAP_PENALTY_MAX) }
		}
		if n := len(out); n > 0 && out[n - 1][1] == p { out[n - 1][1] = p + 1 } else { append(&out, Fuzzy_Range{p, p + 1}) }
	}
	score -= len(hay) / FUZZY_BYTES_PER_LENGTH_POINT
	return score, out[:], true
}

package fuzzy_test

// Tests for the SIMD vector fast path of ui.fuzzy_score (200k deterministic fuzz test against the scalar reference)
// and ui.Frecency (src/md/features/fuzzy-frecency.md).

import "core:fmt"
import "core:slice"
import "core:testing"
import "core:unicode"
import "core:unicode/utf8"
import "gt:ui"

// Independent scalar reference oracle for ui.fuzzy_score (exact same weights and algorithm).
@(private = "file")
scalar_oracle :: proc(needle: ui.Fuzzy_Needle, h: ui.Fuzzy_Text, allocator := context.temp_allocator) -> (score: int, ranges: []ui.Fuzzy_Range, ok: bool) {
	want := needle.runes
	if len(want) == 0 { return 0, nil, true }
	hay, low := h.text, h.low
	pos := make([]int, len(want), context.temp_allocator)
	k := 0
	end := -1
	for r, i in low {
		if r == want[k] {
			k += 1
			if k == len(want) { end = i; break }
		}
	}
	if end < 0 { return 0, nil, false }
	k = len(want) - 1
	_, w_end := utf8.decode_rune_in_string(low[end:])
	for i := end + w_end; i > 0 && k >= 0; {
		r, w := utf8.decode_last_rune_in_string(low[:i])
		i -= w
		if r == want[k] { pos[k] = i; k -= 1 }
	}
	out := make([dynamic]ui.Fuzzy_Range, allocator)
	for p, j in pos {
		_, w := utf8.decode_rune_in_string(low[p:])
		score += 16
		if p == 0 {
			score += 20
		} else {
			prev, _ := utf8.decode_last_rune_in_string(hay[:p])
			cur, _ := utf8.decode_rune_in_string(hay[p:])
			if !unicode.is_letter(prev) && !unicode.is_digit(prev) {
				score += 18
			} else if unicode.is_lower(prev) && unicode.is_upper(cur) {
				score += 14
			}
		}
		if j > 0 {
			_, pw := utf8.decode_rune_in_string(low[pos[j - 1]:])
			gap := p - (pos[j - 1] + pw)
			if gap == 0 { score += 24 } else { score -= min(gap, 12) }
		}
		if n := len(out); n > 0 && out[n - 1][1] == p { out[n - 1][1] = p + w } else { append(&out, ui.Fuzzy_Range{p, p + w}) }
	}
	score -= len(hay) / 8
	return score, out[:], true
}

@(test)
fuzzy_vectors_match_scalar_on_200k_inputs :: proc(t: ^testing.T) {
	state: u64 = 0xD1B5_4A32_D192_ED03
	next_u64 :: proc(s: ^u64) -> u64 {
		x := s^
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		s^ = x
		return x
	}
	alpha := "abcABC123._-/ xyzXYZ"
	qbuf: [70]u8
	hbuf: [140]u8
	for round in 0 ..< 200_000 {
		// Cover lengths across 16-byte blocks, exact 128-byte boundary, and >128 / >64 fallbacks.
		hlen := int(next_u64(&state) % 136)
		qlen := int(next_u64(&state) % 10)
		if round % 500 == 0 { hlen = 128; qlen = int(next_u64(&state) % 66) }
		for i in 0 ..< hlen { hbuf[i] = alpha[next_u64(&state) % u64(len(alpha))] }
		if round % 3 == 0 && hlen > 0 && qlen > 0 {
			// Guarantee a matching subsequence so scoring and range coalescing are heavily exercised
			qlen = min(qlen, hlen)
			for i in 0 ..< qlen {
				src := (i * hlen) / qlen
				qbuf[i] = hbuf[src]
			}
		} else {
			for i in 0 ..< qlen { qbuf[i] = alpha[next_u64(&state) % u64(len(alpha))] }
		}
		q := string(qbuf[:qlen])
		h := string(hbuf[:hlen])
		nd := ui.fuzzy_needle(q, context.temp_allocator)
		ft := ui.fuzzy_text(h, context.temp_allocator)
		vs, vr, vok := ui.fuzzy_score(nd, ft, context.temp_allocator)
		ss, sr, sok := scalar_oracle(nd, ft, context.temp_allocator)
		if vok != sok || vs != ss || !slice.equal(vr, sr) {
			testing.expectf(t, false, "round %d q=%q h=%q: vec=(%d,%v,%v) scalar=(%d,%v,%v)", round, q, h, vs, vr, vok, ss, sr, sok)
			return
		}
		free_all(context.temp_allocator)
	}
}

@(test)
fuzzy_handles_unicode_and_boundaries :: proc(t: ^testing.T) {
	pairs := [?][2]string{
		{"", "anything"},
		{"abc", ""},
		{"cs5", "claude-sonnet-5"},
		{"mcnt", "monitor.count"},
		{"fr", "Français"},
		{"é", "Café"},
		{"日本語", "test 日本語 path"},
	}
	for p in pairs {
		nd := ui.fuzzy_needle(p[0], context.temp_allocator)
		ft := ui.fuzzy_text(p[1], context.temp_allocator)
		vs, vr, vok := ui.fuzzy_score(nd, ft, context.temp_allocator)
		ss, sr, sok := scalar_oracle(nd, ft, context.temp_allocator)
		testing.expect_value(t, vok, sok)
		testing.expect_value(t, vs, ss)
		testing.expect(t, slice.equal(vr, sr), "ranges match")
	}
}

@(test)
frecency_decay_saturation_bonus_and_eviction :: proc(t: ^testing.T) {
	f: ui.Frecency
	testing.expect_value(t, ui.frecency_score(&f, "alpha"), u32(0))
	testing.expect_value(t, ui.frecency_bonus(&f, "alpha"), 0)
	testing.expect(t, ui.frecency_key("alpha") != 0, "key never 0")

	// One use gives W = 1024 and bonus = bit_length(1024 >> 7) = bit_length(8) = 4
	ui.frecency_note_use(&f, {"alpha", "alpha", ""})   // duplicate & empty ignored
	testing.expect_value(t, ui.frecency_score(&f, "alpha"), u32(ui.FRECENCY_USE_WEIGHT))
	testing.expect_value(t, ui.frecency_bonus(&f, "alpha"), 4)

	// 21 uses leave score >= 512 (bonus 3); 22 uses halve 1024 to 501 (501 >> 7 = 3 -> bit_length 2)
	for _ in 0 ..< 21 { ui.frecency_note_use(&f, {}) }
	testing.expect_value(t, ui.frecency_bonus(&f, "alpha"), 3)
	ui.frecency_note_use(&f, {})
	testing.expect_value(t, ui.frecency_score(&f, "alpha"), u32(501))
	testing.expect_value(t, ui.frecency_bonus(&f, "alpha"), 2)

	// Remaining 106 empty uses decay alpha all the way to 0 (evicted after 128 total other uses)
	for _ in 0 ..< 106 { ui.frecency_note_use(&f, {}) }
	testing.expect_value(t, ui.frecency_score(&f, "alpha"), u32(0))
	testing.expect_value(t, f.count, 0)

	// Saturation: repeated uses cap below FRECENCY_SCORE_LIMIT (32768) and give max bonus 8
	for _ in 0 ..< 400 { ui.frecency_note_use(&f, {"hot"}) }
	s_hot := ui.frecency_score(&f, "hot")
	testing.expectf(t, s_hot > 30000 && s_hot < ui.FRECENCY_SCORE_LIMIT, "saturated score: %d", s_hot)
	testing.expect_value(t, ui.frecency_bonus(&f, "hot"), ui.FRECENCY_BONUS_LIMIT)

	// Capacity eviction: 64 entries max, lowest score outside current use is evicted
	f = {}
	for i in 0 ..< ui.FRECENCY_CAPACITY + 10 {
		ui.frecency_note_use(&f, {fmt.tprintf("item_%03d", i)})
	}
	testing.expect_value(t, f.count, ui.FRECENCY_CAPACITY)
	testing.expect_value(t, ui.frecency_score(&f, "item_000"), u32(0))   // oldest evicted
	testing.expect(t, ui.frecency_score(&f, fmt.tprintf("item_%03d", ui.FRECENCY_CAPACITY + 9)) == ui.FRECENCY_USE_WEIGHT, "newest kept")

	// Encode/decode round-trip + malformed/clamping checks
	buf: [ui.FRECENCY_BYTES_MAX]u8
	enc := ui.frecency_encode(&f, buf[:])
	testing.expect(t, len(enc) == 8 + f.count * 12, "encoded length")
	dec, ok := ui.frecency_decode(enc)
	testing.expect(t, ok, "decode ok")
	testing.expect_value(t, dec.count, f.count)
	for i in 0 ..< f.count { testing.expect_value(t, dec.entries[i], f.entries[i]) }
	_, bad := ui.frecency_decode(enc[:len(enc) - 1])
	testing.expect(t, !bad, "truncated rejected")
	_, bad_magic := ui.frecency_decode({0, 0, 0, 0, 0, 0, 0, 0})
	testing.expect(t, !bad_magic, "bad magic rejected")
}

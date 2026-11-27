package platform

import "core:testing"

@(test)
native_shield_clamp_rects_clips_and_drops_empty :: proc(t: ^testing.T) {
	in_rects := [][4]int{
		{-10, -5, 50, 40},   // clamped to {0, 0, 40, 35}
		{90, 80, 30, 30},    // clamped to {90, 80, 10, 20}
		{100, 10, 20, 20},   // wholly outside -> dropped
		{10, 10, 0, 20},     // zero width -> dropped
		{10, 10, 20, -5},    // negative height -> dropped
	}
	got := native_shield_clamp_rects(in_rects, {100, 100}, context.temp_allocator)
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, got[0], [4]int{0, 0, 40, 35})
		testing.expect_value(t, got[1], [4]int{90, 80, 10, 20})
	}
	testing.expect_value(t, len(native_shield_clamp_rects(in_rects, {0, 100}, context.temp_allocator)), 0)
	testing.expect_value(t, len(native_shield_clamp_rects(nil, {100, 100}, context.temp_allocator)), 0)
}

@(test)
native_shield_rects_equal_checks_length_and_values :: proc(t: ^testing.T) {
	a := [][4]int{{10, 20, 30, 40}, {50, 60, 10, 10}}
	b := [][4]int{{10, 20, 30, 40}, {50, 60, 10, 10}}
	c := [][4]int{{10, 20, 30, 40}, {50, 60, 10, 11}}
	testing.expect(t, native_shield_rects_equal(a, b), "identical slices")
	testing.expect(t, !native_shield_rects_equal(a, c), "differing coordinate")
	testing.expect(t, !native_shield_rects_equal(a, a[:1]), "differing length")
	testing.expect(t, native_shield_rects_equal(nil, nil), "empty slices")
}

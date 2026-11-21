// gt:turn: exact quarters, agreement with core:math elsewhere, atan2 of the axes, wrap, the conversions.
//   odin test tests/turn -collection:gt=src -vet
package turn_test

import "core:math"
import "core:testing"
import turn "gt:turn"

@(test)
quarters_are_exact :: proc(t: ^testing.T) {
	s, c := turn.sincos(f32(0.25))
	testing.expect(t, s == 1 && c == 0, "sincos(0.25) is (1, 0)")
	testing.expect(t, turn.cos(f32(0.5)) == -1, "cos(0.5) is -1")
	testing.expect(t, turn.sin(f32(0.5)) == 0, "sin(0.5) is 0")
	testing.expect(t, turn.sin(f32(1)) == 0, "sin(1) is 0")
	testing.expect(t, turn.cos(f32(1)) == 1, "cos(1) is 1")
	testing.expect(t, turn.sin(f32(0.75)) == -1 && turn.cos(f32(0.75)) == 0, "0.75: (-1, 0)")
	testing.expect(t, turn.sin(f32(-0.25)) == -1 && turn.cos(f32(-0.25)) == 0, "-0.25: (-1, 0)")
	testing.expect(t, turn.tan(f32(0.5)) == 0, "tan(0.5) is 0")
	// far turns too: 1000.25 is still a quarter
	ss, cc := turn.sincos(f64(1000.25))
	testing.expect(t, ss == 1 && cc == 0, "sincos(1000.25) is (1, 0)")
	ss, cc = turn.sincos(f64(-7.5))
	testing.expect(t, ss == 0 && cc == -1, "sincos(-7.5) is (0, -1)")
	// no -0: a zero prints as 0
	testing.expect(t, !math.sign_bit(turn.cos(f32(0.25))) && !math.sign_bit(turn.sin(f32(0.5))), "zeros are +0")
}

@(test)
agrees_with_core_math :: proc(t: ^testing.T) {
	for i in -2000 ..= 2000 {
		a := f64(i) * 0.00137
		s, c := turn.sincos(a)
		testing.expectf(t, abs(s - math.sin(a * math.TAU)) < 1e-12 && abs(c - math.cos(a * math.TAU)) < 1e-12, "f64 at %v", a)
		s32, c32 := turn.sincos(f32(a))
		r := f64(f32(a)) * math.TAU
		testing.expectf(t, abs(f64(s32) - math.sin(r)) < 1e-6 && abs(f64(c32) - math.cos(r)) < 1e-6, "f32 at %v", a)
		if abs(math.cos(r)) > 0.1 {
			testing.expectf(t, abs(f64(turn.tan(f32(a))) - math.tan(r)) < 1e-5, "tan at %v", a)
		}
		y, x := math.sin(f64(i) * 0.01), math.cos(f64(i) * 0.013)
		testing.expectf(t, abs(turn.atan2(y, x) - math.atan2(y, x) / math.TAU) < 1e-12, "atan2 at %v", i)
	}
	for x in ([]f32{-0.9, -0.5, 0.1, 0.7}) {
		testing.expectf(t, abs(turn.asin(x) - math.asin(x) / math.TAU) < 1e-6, "asin %v", x)
		testing.expectf(t, abs(turn.acos(x) - math.acos(x) / math.TAU) < 1e-6, "acos %v", x)
	}
}

@(test)
atan2_of_the_axes :: proc(t: ^testing.T) {
	testing.expect(t, turn.atan2(f32(0), f32(1)) == 0, "+x: 0")
	testing.expect(t, turn.atan2(f32(1), f32(0)) == 0.25, "+y: 0.25")
	testing.expect(t, turn.atan2(f32(0), f32(-3)) == 0.5, "-x: 0.5")
	testing.expect(t, turn.atan2(f32(-2), f32(0)) == -0.25, "-y: -0.25")
	testing.expect(t, abs(turn.atan2(f64(1), f64(1)) - 0.125) < 1e-15, "the diagonal: 0.125")
	testing.expect(t, turn.asin(f32(1)) == 0.25 && turn.acos(f32(-1)) == 0.5 && turn.acos(f32(0)) == 0.25, "asin, acos exact")
}

@(test)
wraps :: proc(t: ^testing.T) {
	testing.expect(t, turn.wrap(f32(1.25)) == 0.25, "1.25 -> 0.25")
	testing.expect(t, turn.wrap(f32(-0.25)) == 0.75, "-0.25 -> 0.75")
	testing.expect(t, turn.wrap(f32(3)) == 0, "3 -> 0")
	testing.expect(t, turn.wrap(f32(-1e-9)) < 1, "a tiny negative angle stays below 1")
	testing.expect(t, turn.wrap(f64(-2.5)) == 0.5, "-2.5 -> 0.5")
}

@(test)
conversions :: proc(t: ^testing.T) {
	testing.expect(t, turn.from_degrees(f32(90)) == 0.25, "90 degrees: 0.25")
	testing.expect(t, turn.to_degrees(f32(0.5)) == 180, "0.5: 180 degrees")
	testing.expect(t, abs(turn.from_radians(f64(math.PI)) - 0.5) < 1e-15, "π radians: 0.5")
	testing.expect(t, abs(turn.to_radians(f32(0.25)) - math.PI / 2) < 1e-6, "0.25: π/2")
	testing.expect(t, abs(turn.from_radians(turn.to_radians(f64(0.3))) - 0.3) < 1e-15, "a round trip")
}

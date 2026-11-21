// gt:turn: angles in turns (a whole circle is 1), the one unit of every angle the toolkit takes or gives.
// The design: src/md/infrastructure/angles.md. Radians exist only here, at the calls to core:math.
package tk_turn

import "core:math"

// The trigonometry reduces its argument to the nearest quarter turn q and a residual r (|r| <= 1/8), then rotates the
// residual's (cos, sin) by q quarters with swaps and negations: a multiple of 0.25 gives 0, 1 or -1 exactly, which
// core:math's sin(π/2 · k) cannot (π is not a float).

@(private = "file")
reduce_f32 :: proc "contextless" (t: f32) -> (s, c: f32) {
	// f64 for the reduction: t - q/4 is exact for f32 inputs, and r · 2π keeps the residual's bits
	q := math.round(f64(t) * 4)
	r := (f64(t) - q * 0.25) * math.TAU
	rs, rc := math.sincos(r)
	s, c = f32(rs), f32(rc)
	return quarter(s, c, q)
}

@(private = "file")
reduce_f64 :: proc "contextless" (t: f64) -> (s, c: f64) {
	q := math.round(t * 4)
	r := (t - q * 0.25) * math.TAU
	s, c = math.sincos(r)
	return quarter(s, c, q)
}

// (s, c) turned by q quarter turns. q is a whole number held in a float: its value modulo 4, as an integer, picks the swap.
@(private = "file")
quarter :: proc "contextless" (s, c: $T, q: f64) -> (T, T) {
	k := int(q - 4 * math.floor(q / 4)) // 0..3, also for a negative q
	// (+ 0 turns a -0 into +0: an exact quarter gives a plain 0, which prints as 0)
	switch k {
	case 1: return c + 0, -s + 0
	case 2: return -s + 0, -c + 0
	case 3: return -c + 0, s + 0
	}
	return s + 0, c + 0
}

sincos_f32 :: proc "contextless" (turns: f32) -> (s, c: f32) { return reduce_f32(turns) }
sincos_f64 :: proc "contextless" (turns: f64) -> (s, c: f64) { return reduce_f64(turns) }
// The sine and the cosine of an angle (turns), together.
sincos :: proc {sincos_f32, sincos_f64}

sin_f32 :: proc "contextless" (turns: f32) -> f32 { s, _ := reduce_f32(turns); return s }
sin_f64 :: proc "contextless" (turns: f64) -> f64 { s, _ := reduce_f64(turns); return s }
// The sine of an angle (turns): exactly 0 at every half turn, 1 at 0.25, -1 at 0.75.
sin :: proc {sin_f32, sin_f64}

cos_f32 :: proc "contextless" (turns: f32) -> f32 { _, c := reduce_f32(turns); return c }
cos_f64 :: proc "contextless" (turns: f64) -> f64 { _, c := reduce_f64(turns); return c }
// The cosine of an angle (turns): exactly 0 at 0.25 and 0.75, -1 at 0.5.
cos :: proc {cos_f32, cos_f64}

tan_f32 :: proc "contextless" (turns: f32) -> f32 { s, c := reduce_f32(turns); return s / c }
tan_f64 :: proc "contextless" (turns: f64) -> f64 { s, c := reduce_f64(turns); return s / c }
// The tangent of an angle (turns): exactly 0 at every half turn, infinite at 0.25 and 0.75.
tan :: proc {tan_f32, tan_f64}

atan2_f32 :: proc "contextless" (y, x: f32) -> f32 { return f32(atan2_f64(f64(y), f64(x))) }
atan2_f64 :: proc "contextless" (y, x: f64) -> f64 {
	// the axes exactly: core:math's π/2 divided by 2π is not 0.25 to the last bit
	if y == 0 { return x < 0 ? 0.5 : 0 }
	if x == 0 { return y > 0 ? 0.25 : -0.25 }
	return math.atan2(y, x) / math.TAU
}
// The angle (turns, -0.5 .. 0.5) of the point (x, y) from +x, towards +y: clockwise on a screen whose y points down.
// The axes give 0, 0.25, 0.5 and -0.25 exactly.
atan2 :: proc {atan2_f32, atan2_f64}

asin_f32 :: proc "contextless" (x: f32) -> f32 { return f32(asin_f64(f64(x))) }
asin_f64 :: proc "contextless" (x: f64) -> f64 {
	if x == 1 { return 0.25 }
	if x == -1 { return -0.25 }
	return math.asin(x) / math.TAU
}
// The angle (turns, -0.25 .. 0.25) whose sine is x; exact at -1, 0 and 1.
asin :: proc {asin_f32, asin_f64}

acos_f32 :: proc "contextless" (x: f32) -> f32 { return f32(acos_f64(f64(x))) }
acos_f64 :: proc "contextless" (x: f64) -> f64 {
	if x == 0 { return 0.25 }
	if x == -1 { return 0.5 }
	return math.acos(x) / math.TAU
}
// The angle (turns, 0 .. 0.5) whose cosine is x; exact at -1, 0 and 1.
acos :: proc {acos_f32, acos_f64}

wrap_f32 :: proc "contextless" (turns: f32) -> f32 {
	w := turns - math.floor(turns)
	// (a tiny negative angle rounds up to 1: the result stays below a whole turn)
	return w >= 1 ? 0 : w
}
wrap_f64 :: proc "contextless" (turns: f64) -> f64 {
	w := turns - math.floor(turns)
	return w >= 1 ? 0 : w
}
// An angle (turns) as the same direction in [0, 1).
wrap :: proc {wrap_f32, wrap_f64}

// The boundaries: a system, a file format or a person gives degrees or radians; they become turns once, here.

from_degrees_f32 :: proc "contextless" (degrees: f32) -> f32 { return degrees / 360 }
from_degrees_f64 :: proc "contextless" (degrees: f64) -> f64 { return degrees / 360 }
// Degrees (360 a whole circle) as turns.
from_degrees :: proc {from_degrees_f32, from_degrees_f64}

to_degrees_f32 :: proc "contextless" (turns: f32) -> f32 { return turns * 360 }
to_degrees_f64 :: proc "contextless" (turns: f64) -> f64 { return turns * 360 }
// Turns as degrees.
to_degrees :: proc {to_degrees_f32, to_degrees_f64}

from_radians_f32 :: proc "contextless" (radians: f32) -> f32 { return f32(f64(radians) / math.TAU) }
from_radians_f64 :: proc "contextless" (radians: f64) -> f64 { return radians / math.TAU }
// Radians (2π a whole circle) as turns.
from_radians :: proc {from_radians_f32, from_radians_f64}

to_radians_f32 :: proc "contextless" (turns: f32) -> f32 { return f32(f64(turns) * math.TAU) }
to_radians_f64 :: proc "contextless" (turns: f64) -> f64 { return turns * math.TAU }
// Turns as radians, for a library outside the toolkit that wants them.
to_radians :: proc {to_radians_f32, to_radians_f64}

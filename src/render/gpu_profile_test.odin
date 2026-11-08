package render

import "core:testing"

// The per-step GPU profile's arithmetic (profile_add, both backends): timestamps in, steps summed by kind, the slowest
// kept longest first. Made-up timestamps: one tick is one millisecond.

@(private = "file") MS_PER_TICK :: 1.0
// More steps than the slowest list holds.
@(private = "file") STEPS :: GPU_PROFILE_SLOWEST + 4

@(test)
profile_add_sums_steps_by_kind :: proc(t: ^testing.T) {
	p: Gpu_Profile
	prev: u64 = 100
	profile_add(&p, Prof_Rec{kind = .Blur, pixels = 10, bytes = 40}, 103, &prev, MS_PER_TICK)
	profile_add(&p, Prof_Rec{kind = .Clear, pixels = 5, bytes = 20}, 104, &prev, MS_PER_TICK)
	profile_add(&p, Prof_Rec{kind = .Blur, pixels = 10, bytes = 40}, 109, &prev, MS_PER_TICK)
	testing.expect_value(t, p.steps[.Blur], Gpu_Step_Stat{count = 2, ms = 8, pixels = 20, bytes = 80})
	testing.expect_value(t, p.steps[.Clear], Gpu_Step_Stat{count = 1, ms = 1, pixels = 5, bytes = 20})
	testing.expect_value(t, prev, u64(109))
	// a timestamp before the previous one (a clock that went back): the step counts 0 and the reference stays
	profile_add(&p, Prof_Rec{kind = .Copy}, 105, &prev, MS_PER_TICK)
	testing.expect_value(t, p.steps[.Copy], Gpu_Step_Stat{count = 1, ms = 0})
	testing.expect_value(t, prev, u64(109))
	profile_add(&p, Prof_Rec{kind = .Copy}, 111, &prev, MS_PER_TICK)
	testing.expect_value(t, p.steps[.Copy].ms, 2)
}

@(test)
profile_add_keeps_the_slowest_longest_first :: proc(t: ^testing.T) {
	p: Gpu_Profile
	prev: u64
	// durations 1..STEPS ms in a shuffled order (7 is prime to STEPS: every duration once); each step's width says its duration
	for i in 0 ..< STEPS {
		d := u64((i * 7) % STEPS + 1)
		profile_add(&p, Prof_Rec{kind = .Draw_Layer, w = i32(d), detail = Gpu_Step_Rec{batch = i32(i)}}, prev + d, &prev, MS_PER_TICK)
	}
	testing.expect_value(t, p.n_slowest, GPU_PROFILE_SLOWEST)
	for s, k in p.slowest[:p.n_slowest] {
		testing.expectf(t, s.ms == f32(STEPS - k), "slowest[%d] is %v ms", k, s.ms)
		testing.expectf(t, s.w == i32(s.ms) && s.kind == .Draw_Layer, "slowest[%d] is its own step: %v", k, s)
	}
	testing.expect_value(t, p.steps[.Draw_Layer].count, STEPS)
	testing.expect_value(t, p.steps[.Draw_Layer].ms, f32(STEPS * (STEPS + 1) / 2))
}
package render

import "core:mem"
import "core:testing"

// surface_use moves a window as a block: all of it, and nothing else. As bytes, so that a field added to Window_Target is
// covered without this test being told of it. Neither has a device: nothing here is called on these pointers.
@(test)
an_exchange_moves_the_whole_window_and_only_it :: proc(t: ^testing.T) {
	OURS :: 0xA5
	THEIRS :: 0x5A
	r := new(Renderer)
	s := new(Surface)
	defer { free(r); free(s) }
	mem.set(&r.target, OURS, size_of(Window_Target))
	mem.set(&s.target, THEIRS, size_of(Window_Target))
	r.id, r.space_epoch, r.resize_slack = 7, 8, 9

	exchange(r, s)

	ours := ([^]u8)(&s.target)[:size_of(Window_Target)]
	theirs := ([^]u8)(&r.target)[:size_of(Window_Target)]
	for i in 0 ..< size_of(Window_Target) {
		if ours[i] != OURS || theirs[i] != THEIRS {
			testing.expectf(t, false, "byte %d of the window did not move", i)
			return
		}
	}
	testing.expect_value(t, r.id, 7)
	testing.expect_value(t, r.space_epoch, 8)
	testing.expect_value(t, r.resize_slack, 9)
}

// surface_scope hands the window back on any way out of the scope.
@(test)
a_scope_gives_the_window_back :: proc(t: ^testing.T) {
	when USE_WGPU { return }   // (the exchange of a surface with no wgpu window: the lifecycle package's real ones cover that)
	r := new(Renderer)
	s := new(Surface)
	defer { free(r); free(s) }
	r.size, s.size = {1, 1}, {2, 2}
	r.swap_gen, s.swap_gen = 1, 1
	r.device_generation = 1
	s.valid = true
	inside :: proc(t: ^testing.T, r: ^Renderer, s: ^Surface) {
		surface_scope(r, s)
		testing.expect_value(t, r.size, [2]int{2, 2})
		testing.expect(t, s.held, "the renderer has it")
	}
	inside(t, r, s)
	testing.expect_value(t, r.size, [2]int{1, 1})
	testing.expect_value(t, s.size, [2]int{2, 2})
	testing.expect(t, !s.held, "back")
}

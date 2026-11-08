// The queue of calls posted from other threads (ui.Post_Queue, ui.post): several producers, each one's order, a
// drain bounded per build, nothing lost when the ring is full (Block, Grow), Drop_Oldest and Fail, closing, the wake
// asked once per drain, and ui.post run by begin_build.
package post_test

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../../src/font"
import "../../src/platform"
import "../../src/ui"

PRODUCERS :: 4
PER_PRODUCER :: 20000

// What the consumer saw: the next number expected from each producer.
@(private = "file")
Seen :: struct {
	next:    [PRODUCERS]u64,
	total:   int,
	errors:  int,
	wakes:   int,   // atomic
	q:       ^ui.Post_Queue,
}

@(private = "file")
got :: proc(data: rawptr, word: u64) {
	s := (^Seen)(data)
	p, n := word >> 32, word & 0xffffffff
	if p >= PRODUCERS || n != s.next[p] { s.errors += 1 } else { s.next[p] += 1 }
	s.total += 1
}

@(private = "file")
Producer :: struct {
	seen:  ^Seen,
	index: u64,
	count: int,
	refused: int,
}

@(private = "file")
produce :: proc(t: ^thread.Thread) {
	p := (^Producer)(t.data)
	for i in 0 ..< p.count {
		if !ui.post_queue_push(p.seen.q, got, p.seen, p.index << 32 | u64(i)) { p.refused += 1 }
	}
}

// Producers on threads, the owner draining with a budget meanwhile; returns when every message ran or after a deadline.
@(private = "file")
run_producers :: proc(t: ^testing.T, seen: ^Seen, budget: int) -> (ps: [PRODUCERS]Producer) {
	threads: [PRODUCERS]^thread.Thread
	for i in 0 ..< PRODUCERS {
		ps[i] = {seen = seen, index = u64(i), count = PER_PRODUCER}
		threads[i] = thread.create(produce)
		threads[i].data = &ps[i]
		thread.start(threads[i])
	}
	deadline := time.tick_now()
	for seen.total < PRODUCERS * PER_PRODUCER {
		ran, _ := ui.post_queue_drain(seen.q, budget)
		testing.expect(t, ran <= budget, "a drain runs at most its budget")
		if ran == 0 { thread.yield() }
		if time.tick_since(deadline) > 60 * time.Second { break }   // (a safety net, not a timing check)
	}
	for th in threads { thread.join(th); thread.destroy(th) }
	return
}

@(private = "file")
count_wake :: proc(user: rawptr) { sync.atomic_add(&(^Seen)(user).wakes, 1) }

@(test)
block_many_producers_keeps_order :: proc(t: ^testing.T) {
	seen := new(Seen)
	defer free(seen)
	q := new(ui.Post_Queue)
	defer free(q)
	ui.post_queue_init(q, 64, .Block, count_wake, seen)
	defer ui.post_queue_destroy(q)
	seen.q = q
	ps := run_producers(t, seen, 50)
	testing.expect_value(t, seen.total, PRODUCERS * PER_PRODUCER)
	testing.expect_value(t, seen.errors, 0)
	for p in ps { testing.expect_value(t, p.refused, 0) }
	st := ui.post_queue_stats(q)
	testing.expect_value(t, st.posted, u64(PRODUCERS * PER_PRODUCER))
	testing.expect_value(t, st.dropped, u64(0))
	testing.expect(t, sync.atomic_load(&seen.wakes) > 0, "the owner was woken")
	testing.expect(t, int(st.wakes) < PRODUCERS * PER_PRODUCER, "wakes are coalesced")
}

// (several rounds and budgets: the races between spilling and draining are what is tested)
@(test)
grow_many_producers_keeps_order :: proc(t: ^testing.T) {
	for budget in ([]int{1000, 64, 7, 200, 63, 65, 1, 128}) {
		seen := new(Seen)
		q := new(ui.Post_Queue)
		ui.post_queue_init(q, 8, .Grow)
		seen.q = q
		ps := run_producers(t, seen, budget)
		testing.expect_value(t, seen.total, PRODUCERS * PER_PRODUCER)
		testing.expect_value(t, seen.errors, 0)
		for p in ps { testing.expect_value(t, p.refused, 0) }
		ui.post_queue_destroy(q)
		free(q)
		free(seen)
	}
}

@(private = "file") dropped_words: [dynamic]u64
@(private = "file") ran_words: [dynamic]u64

@(private = "file") note_drop :: proc(data: rawptr, word: u64) { append(&dropped_words, word) }
@(private = "file") note_run :: proc(data: rawptr, word: u64) { append(&ran_words, word) }

@(test)
drop_oldest_keeps_the_newest :: proc(t: ^testing.T) {
	q: ui.Post_Queue
	ui.post_queue_init(&q, 8, .Drop_Oldest, on_drop = note_drop)
	defer ui.post_queue_destroy(&q)
	defer { delete(dropped_words); delete(ran_words); dropped_words = nil; ran_words = nil }
	for i in 0 ..< 20 { testing.expect(t, ui.post_queue_push(&q, note_run, nil, u64(i))) }
	ran, more := ui.post_queue_drain(&q)
	testing.expect_value(t, ran, 8)
	testing.expect(t, !more)
	testing.expect_value(t, len(ran_words), 8)
	for w, i in ran_words { testing.expect_value(t, w, u64(12 + i)) }
	testing.expect_value(t, len(dropped_words), 12)
	for w, i in dropped_words { testing.expect_value(t, w, u64(i)) }
	testing.expect_value(t, ui.post_queue_stats(&q).dropped, u64(12))
}

@(test)
fail_refuses_when_full :: proc(t: ^testing.T) {
	q: ui.Post_Queue
	ui.post_queue_init(&q, 4, .Fail)
	defer ui.post_queue_destroy(&q)
	defer { delete(ran_words); ran_words = nil }
	ok := 0
	for i in 0 ..< 6 { if ui.post_queue_push(&q, note_run, nil, u64(i)) { ok += 1 } }
	testing.expect_value(t, ok, 4)
	testing.expect_value(t, ui.post_queue_stats(&q).refused, u64(2))
	ui.post_queue_drain(&q)
	testing.expect_value(t, len(ran_words), 4)
}

@(test)
drain_is_bounded :: proc(t: ^testing.T) {
	q: ui.Post_Queue
	ui.post_queue_init(&q, 128, .Block)
	defer ui.post_queue_destroy(&q)
	defer { delete(ran_words); ran_words = nil }
	for i in 0 ..< 100 { ui.post_queue_push(&q, note_run, nil, u64(i)) }
	ran, more := ui.post_queue_drain(&q, 30)
	testing.expect_value(t, ran, 30)
	testing.expect(t, more, "70 left")
	ran, more = ui.post_queue_drain(&q, 0)
	testing.expect_value(t, ran, 0)
	ran, more = ui.post_queue_drain(&q, 100)
	testing.expect_value(t, ran, 70)
	testing.expect(t, !more)
	for w, i in ran_words { testing.expect_value(t, w, u64(i)) }
}

// The owner's own push on a full Block ring cannot wait for itself: it spills, in order.
@(test)
block_from_owner_spills :: proc(t: ^testing.T) {
	q: ui.Post_Queue
	ui.post_queue_init(&q, 4, .Block)
	defer ui.post_queue_destroy(&q)
	defer { delete(ran_words); ran_words = nil }
	for i in 0 ..< 10 { testing.expect(t, ui.post_queue_push(&q, note_run, nil, u64(i))) }
	testing.expect_value(t, ui.post_queue_stats(&q).spilled, u64(6))
	ran, _ := ui.post_queue_drain(&q)
	testing.expect_value(t, ran, 10)
	for w, i in ran_words { testing.expect_value(t, w, u64(i)) }
}

@(private = "file")
Wake_Count :: struct { n: int }

@(private = "file") wake_inc :: proc(user: rawptr) { sync.atomic_add(&(^Wake_Count)(user).n, 1) }
@(private = "file") nothing :: proc(data: rawptr, word: u64) {}

@(test)
wake_once_per_drain :: proc(t: ^testing.T) {
	wc: Wake_Count
	q: ui.Post_Queue
	ui.post_queue_init(&q, 64, .Block, wake_inc, &wc)
	defer ui.post_queue_destroy(&q)
	for _ in 0 ..< 10 { ui.post_queue_push(&q, nothing) }
	testing.expect_value(t, wc.n, 1)
	ui.post_queue_drain(&q)
	ui.post_queue_push(&q, nothing)
	testing.expect_value(t, wc.n, 2)
}

@(private = "file")
Blocked :: struct { q: ^ui.Post_Queue, result: bool, done: bool }

// A producer waiting on a full ring is released by close (its push fails); the messages left go to on_drop at destroy.
@(test)
close_releases_blocked_producers :: proc(t: ^testing.T) {
	q := new(ui.Post_Queue)
	defer free(q)
	ui.post_queue_init(q, 2, .Block, on_drop = note_drop)
	defer { delete(dropped_words); dropped_words = nil }
	ui.post_queue_push(q, nothing)
	ui.post_queue_push(q, nothing)
	b := Blocked{q = q, result = true}
	th := thread.create(proc(th: ^thread.Thread) {
		b := (^Blocked)(th.data)
		b.result = ui.post_queue_push(b.q, nothing)
		sync.atomic_store(&b.done, true)
	})
	th.data = &b
	thread.start(th)
	for ui.post_queue_stats(q).blocked == 0 { thread.yield() }
	testing.expect(t, !sync.atomic_load(&b.done), "waits while full")
	ui.post_queue_close(q)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, !b.result, "a closed queue refuses")
	ui.post_queue_destroy(q)
	testing.expect_value(t, len(dropped_words), 2)
}

// A producer waiting on a full ring goes in once the owner drains.
@(test)
block_resumes_after_drain :: proc(t: ^testing.T) {
	q := new(ui.Post_Queue)
	defer free(q)
	wc: Wake_Count
	ui.post_queue_init(q, 2, .Block, wake_inc, &wc)
	defer ui.post_queue_destroy(q)
	ui.post_queue_push(q, nothing)
	ui.post_queue_push(q, nothing)
	b := Blocked{q = q}
	th := thread.create(proc(th: ^thread.Thread) {
		b := (^Blocked)(th.data)
		b.result = ui.post_queue_push(b.q, nothing)
		sync.atomic_store(&b.done, true)
	})
	th.data = &b
	thread.start(th)
	for ui.post_queue_stats(q).blocked == 0 { thread.yield() }
	ui.post_queue_drain(q)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, b.result)
	ran, _ := ui.post_queue_drain(q)
	testing.expect_value(t, ran, 1)
}

@(private = "file")
Post_Run :: struct {
	fonts: font.State,
	theme: ui.Theme,
	s:     ui.State,
	ran, woken, dropped: int,
	got_user: rawptr,
}

@(private = "file") count_run :: proc(data: rawptr, word: u64) { (^Post_Run)(data).ran += 1 }
@(private = "file") last_user: rawptr
@(private = "file") wakes_seen: int
@(private = "file") own_wake :: proc(user: rawptr) { last_user = user; wakes_seen += 1 }

// More calls than a build's budget wait when the queue is sized anew: all of them run, none is lost.
@(test)
post_configure_runs_what_waits :: proc(t: ^testing.T) {
	r := new(Post_Run)
	defer free(r)
	font.init(&r.fonts)
	defer font.destroy(&r.fonts)
	ui.init(&r.s, &r.fonts, &r.theme)
	defer ui.destroy(&r.s)
	for _ in 0 ..< ui.POST_PER_BUILD_DEFAULT + 1 { testing.expect(t, ui.post(&r.s, count_run, r)) }
	ui.post_configure(&r.s)
	testing.expect_value(t, r.ran, ui.POST_PER_BUILD_DEFAULT + 1)
}

// A queue that was closed stays closed when it is sized anew.
@(test)
post_configure_keeps_a_closed_queue_closed :: proc(t: ^testing.T) {
	r := new(Post_Run)
	defer free(r)
	font.init(&r.fonts)
	defer font.destroy(&r.fonts)
	ui.init(&r.s, &r.fonts, &r.theme)
	defer ui.destroy(&r.s)
	ui.post_close(&r.s)
	ui.post_configure(&r.s)
	testing.expect(t, !ui.post(&r.s, count_run, r), "refused")
}

// The app's own wake is called, whatever its user: nil is a user.
@(test)
set_post_wake_with_no_user_wakes :: proc(t: ^testing.T) {
	r := new(Post_Run)
	defer free(r)
	font.init(&r.fonts)
	defer font.destroy(&r.fonts)
	ui.init(&r.s, &r.fonts, &r.theme)
	defer ui.destroy(&r.s)
	wakes_seen = 0
	ui.set_post_wake(&r.s, own_wake, nil)
	testing.expect(t, ui.post(&r.s, count_run, r))
	testing.expect_value(t, wakes_seen, 1)
}

// No wake of its own any more: the window's again, not none.
@(test)
set_post_wake_nil_goes_back_to_the_window :: proc(t: ^testing.T) {
	r := new(Post_Run)
	defer free(r)
	font.init(&r.fonts)
	defer font.destroy(&r.fonts)
	ui.init(&r.s, &r.fonts, &r.theme)
	defer ui.destroy(&r.s)
	w := platform.open_window_offscreen("post", {100, 100})
	defer platform.destroy_window(w)
	build := proc(r: ^Post_Run, w: ^platform.Window) {
		ui.begin_build(&r.s, {window_size = {100, 100}, dt = 1.0 / 60, dpi_scale = 1, window = w, base = ui.Style{font_size = 15}})
		ui.end_build()
		free_all(context.temp_allocator)
	}
	ui.set_post_wake(&r.s, own_wake, r)
	build(r, w)
	ui.set_post_wake(&r.s, nil, nil)
	before := ui.post_stats(&r.s).wakes
	testing.expect(t, ui.post(&r.s, count_run, r))
	testing.expect_value(t, ui.post_stats(&r.s).wakes, before + 1)
}

// Of the two windows of a State, the one posts woke is gone: posts wake the other.
@(test)
posts_wake_the_window_that_stays :: proc(t: ^testing.T) {
	r := new(Post_Run)
	defer free(r)
	font.init(&r.fonts)
	defer font.destroy(&r.fonts)
	ui.init(&r.s, &r.fonts, &r.theme)
	defer ui.destroy(&r.s)
	a := platform.open_window_offscreen("post a", {100, 100})
	b := platform.open_window_offscreen("post b", {100, 100})
	defer platform.destroy_window(a)
	build := proc(r: ^Post_Run, w: ^platform.Window) {
		ui.begin_build(&r.s, {window_size = {100, 100}, dt = 1.0 / 60, dpi_scale = 1, window = w, base = ui.Style{font_size = 15}})
		ui.end_build()
		free_all(context.temp_allocator)
	}
	build(r, a)
	build(r, b)
	platform.destroy_window(b)
	before := ui.post_stats(&r.s).wakes
	testing.expect(t, ui.post(&r.s, count_run, r))
	testing.expect_value(t, ui.post_stats(&r.s).wakes, before + 1)
}

// A State that is gone refuses a call, as a closed queue does.
@(test)
post_on_a_state_that_is_gone_is_refused :: proc(t: ^testing.T) {
	r := new(Post_Run)
	defer free(r)
	font.init(&r.fonts)
	defer font.destroy(&r.fonts)
	ui.init(&r.s, &r.fonts, &r.theme)
	ui.destroy(&r.s)
	testing.expect(t, !ui.post(&r.s, count_run, r), "refused")
}

// ui.post: run by begin_build before the frame, at most the per-build budget, needs_frame while some wait.
@(private = "file")
Ui_Data :: struct { lines: [dynamic]u64 }

@(test)
ui_post_runs_in_begin_build :: proc(t: ^testing.T) {
	fonts: font.State
	font.init(&fonts)
	defer font.destroy(&fonts)
	ui_font, _ := font.load_embedded(&fonts, font.FALLBACK_UI_DATA)
	theme: ui.Theme
	ui.apply_palette(&theme, ui.PALETTE_MIDNIGHT)
	defer ui.theme_destroy(&theme)
	s := new(ui.State)
	defer free(s)
	ui.init(s, &fonts, &theme)
	defer ui.destroy(s)
	ui.post_configure(s, 64, .Grow, per_build = 10)
	d: Ui_Data
	defer delete(d.lines)
	for i in 0 ..< 25 {
		testing.expect(t, ui.post(s, proc(data: rawptr, word: u64) { append(&(^Ui_Data)(data).lines, word) }, &d, u64(i)))
	}
	build :: proc(s: ^ui.State, f: font.Font_Id) {
		ui.begin_build(s, {window_size = {200, 100}, dt = 1.0 / 60, dpi_scale = 1, base = ui.Style{font = f, font_size = 15}})
		ui.end_build()
	}
	build(s, ui_font)
	testing.expect_value(t, len(d.lines), 10)
	testing.expect(t, ui.needs_frame(s), "15 calls wait")
	build(s, ui_font)
	build(s, ui_font)
	testing.expect_value(t, len(d.lines), 25)
	testing.expect(t, !ui.needs_frame(s))
	for w, i in d.lines { testing.expect_value(t, w, u64(i)) }
	free_all(context.temp_allocator)
}

// ui.destroy: every window the State was built for forgets it, not only the last one (ui.post through one would use a
// queue that is gone).
@(test)
ui_destroy_leaves_no_window_with_its_queue :: proc(t: ^testing.T) {
	fonts: font.State
	font.init(&fonts)
	defer font.destroy(&fonts)
	ui_font, _ := font.load_embedded(&fonts, font.FALLBACK_UI_DATA)
	theme: ui.Theme
	ui.apply_palette(&theme, ui.PALETTE_MIDNIGHT)
	defer ui.theme_destroy(&theme)
	s := new(ui.State)
	defer free(s)
	a, b := new(platform.Window), new(platform.Window)
	defer { free(a); free(b) }
	ui.init(s, &fonts, &theme)
	build :: proc(s: ^ui.State, f: font.Font_Id, w: ^platform.Window) {
		ui.begin_build(s, {window_size = {200, 100}, dt = 1.0 / 60, dpi_scale = 1, window = w, base = ui.Style{font = f, font_size = 15}})
		ui.end_build()
	}
	build(s, ui_font, a)
	build(s, ui_font, b)
	build(s, ui_font, a)
	build(s, ui_font, b)
	build(s, ui_font, nil)
	testing.expect(t, a.post_queue != nil && b.post_queue != nil, "both published")
	ui.destroy(s)
	testing.expect(t, a.post_queue == nil && b.post_queue == nil, "both forgot it")
	free_all(context.temp_allocator)
}

// A window destroyed before the State: the State points to it no more (ui.destroy, a post's wake). The other order, and
// two States built for one window.
@(test)
ui_state_outlives_its_window :: proc(t: ^testing.T) {
	fonts: font.State
	font.init(&fonts)
	defer font.destroy(&fonts)
	ui_font, _ := font.load_embedded(&fonts, font.FALLBACK_UI_DATA)
	theme: ui.Theme
	ui.apply_palette(&theme, ui.PALETTE_MIDNIGHT)
	defer ui.theme_destroy(&theme)
	s, other := new(ui.State), new(ui.State)
	defer { free(s); free(other) }
	ui.init(s, &fonts, &theme)
	build :: proc(s: ^ui.State, f: font.Font_Id, w: ^platform.Window) {
		ui.begin_build(s, {window_size = {200, 100}, dt = 1.0 / 60, dpi_scale = 1, window = w, base = ui.Style{font = f, font_size = 15}})
		ui.end_build()
	}
	w := platform.open_window_offscreen("post", {200, 100})
	if !testing.expect(t, w != nil, "a window") { return }
	build(s, ui_font, w)
	testing.expect_value(t, len(s.post_windows), 1)
	platform.destroy_window(w)
	testing.expect_value(t, len(s.post_windows), 0)
	testing.expect(t, s.window == nil, "the State forgot it")
	wakes := ui.post_stats(s).wakes
	testing.expect(t, ui.post(s, proc(data: rawptr, word: u64) {}), "the queue still works")
	testing.expect_value(t, ui.post_stats(s).wakes, wakes)   // (nothing to wake: not a freed window)
	ui.drain_posts(s)

	// the State first: the window has nothing to call
	w = platform.open_window_offscreen("post", {200, 100})
	build(s, ui_font, w)
	ui.destroy(s)
	testing.expect(t, w.destroy_hook == nil && w.post_queue == nil, "the window forgot it")
	// two States: the last one built holds the window
	ui.init(s, &fonts, &theme)
	ui.init(other, &fonts, &theme)
	build(s, ui_font, w)
	build(other, ui_font, w)
	testing.expect_value(t, len(s.post_windows), 0)
	testing.expect_value(t, len(other.post_windows), 1)
	ui.destroy(s)
	testing.expect(t, w.post_queue == &other.posts, "the other State's queue stays")
	platform.destroy_window(w)
	testing.expect_value(t, len(other.post_windows), 0)
	ui.destroy(other)
	free_all(context.temp_allocator)
}

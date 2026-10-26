// The queue of calls posted from other threads (ui.Post_Queue, ui.post): several producers, each one's order, a
// drain bounded per build, nothing lost when the ring is full (Block, Grow), Drop_Oldest and Fail, closing, the wake
// asked once per drain, and ui.post run by begin_build.
package post_test

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../../font"
import "../../ui"

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

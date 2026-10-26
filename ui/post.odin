package ui

// Calls posted from other threads, run by the interface's thread at the start of begin_build (docs/post.md). A network
// thread reading a stream posts each line; the window wakes, the next build runs the calls before it reads the input,
// so the line is in the app's data when the frame is built. The queue is base.Post_Queue (a lock-free ring).

import "core:sync"
import "../base"
import "../platform"

// The ring's size and how many calls a build runs at most (the rest wait for the next frame: needs_frame says so).
POST_CAPACITY_DEFAULT :: 1024
POST_PER_BUILD_DEFAULT :: 512

Post_Proc :: base.Post_Proc
Post_Overflow :: base.Post_Overflow
Post_Stats :: base.Post_Stats

// Posts a call from any thread: `fn(data, word)` runs on the interface's thread at the start of the next build (or
// the next drain_posts). False when the queue is closed (the State is being destroyed) or full with .Fail.
post :: proc{post_state, post_window}

post_state :: proc(s: ^State, fn: Post_Proc, data: rawptr = nil, word: u64 = 0) -> bool {
	return base.post_queue_push(&s.posts, fn, data, word)
}

// The same through the window the State is built for (Build_Params.window): false when no State has been built for it
// yet, or after ui.destroy.
post_window :: proc(w: ^platform.Window, fn: Post_Proc, data: rawptr = nil, word: u64 = 0) -> bool {
	q := (^base.Post_Queue)(sync.atomic_load(&w.post_queue))
	if q == nil { return false }
	return base.post_queue_push(q, fn, data, word)
}

// Sizes the queue and says what a full ring does (default: 1024 slots, Block, 512 calls per build). Call it on the
// interface's thread before any thread posts: the calls waiting are run first. `on_drop` gets the calls that will
// never run (Drop_Oldest, or left when the State is destroyed), to free their data.
post_configure :: proc(s: ^State, capacity := POST_CAPACITY_DEFAULT, overflow := Post_Overflow.Block, per_build := POST_PER_BUILD_DEFAULT, on_drop: Post_Proc = nil) {
	drain_posts(s)
	wake, user := s.posts.wake, sync.atomic_load(&s.posts.wake_user)
	base.post_queue_destroy(&s.posts)
	s.posts = {}
	base.post_queue_init(&s.posts, capacity, overflow, wake, user, on_drop)
	s.post_budget = per_build
}

// Who to wake when a call is posted. By default the window of Build_Params.window (platform.wake); an app whose loop
// waits on something else (its own event, a socket) gives its own. Call it before any thread posts.
set_post_wake :: proc(s: ^State, wake: proc(user: rawptr), user: rawptr) {
	s.posts.wake = wake
	s.post_wake_own = wake != nil
	base.post_queue_set_wake_user(&s.posts, user)
}

// Runs the calls posted so far (at most `budget`, < 0: the State's per-build budget, 0: none), on the interface's thread.
// begin_build does it; an app that runs the calls elsewhere in its loop (before reading its own data) calls it there.
drain_posts :: proc(s: ^State, budget := -1) -> int {
	base.post_queue_set_owner(&s.posts, sync.current_thread_id())
	n := budget < 0 ? s.post_budget : budget
	ran, more := base.post_queue_drain(&s.posts, n)
	s.posts_more = more
	return ran
}

// Refuses further posts (they return false) and releases the threads waiting on a full ring. Shutting down: close,
// join the posting threads, then ui.destroy (which runs on_drop on the calls never run). Calls already queued still run
// at the next builds.
post_close :: proc(s: ^State) { base.post_queue_close(&s.posts) }

// Whether posted calls wait (the last drain left some, or more came since): another frame should run them.
posts_pending :: proc(s: ^State) -> bool { return base.post_queue_pending(&s.posts) }

post_stats :: proc(s: ^State) -> Post_Stats { return base.post_queue_stats(&s.posts) }

@(private)
post_init :: proc(s: ^State) {
	base.post_queue_init(&s.posts, POST_CAPACITY_DEFAULT, .Block, wake_window, nil)
	s.post_budget = POST_PER_BUILD_DEFAULT
}

@(private)
post_destroy :: proc(s: ^State) {
	if s.window != nil {
		_ = sync.atomic_compare_exchange_strong(&s.window.post_queue, rawptr(&s.posts), nil)
	}
	base.post_queue_destroy(&s.posts)
}

// begin_build: the window to wake follows Build_Params.window, then the calls run.
@(private)
post_begin_build :: proc(s: ^State, w: ^platform.Window) {
	if w != nil {
		sync.atomic_store(&w.post_queue, rawptr(&s.posts))
		if !s.post_wake_own { base.post_queue_set_wake_user(&s.posts, w) }
	}
	drain_posts(s)
}

@(private)
wake_window :: proc(user: rawptr) { platform.wake((^platform.Window)(user)) }

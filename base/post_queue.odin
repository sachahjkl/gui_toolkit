package base

// A bounded multi-producer queue of calls to run on one thread (the interface's): any thread posts a procedure, a
// pointer and a word; the owning thread runs them in order with post_queue_drain. ui.post is the interface's front end
// (docs/post.md).
//
//   * The ring is Dmitry Vyukov's bounded MPMC queue: a sequence number per slot, one compare-and-swap per push and per
//     pop, no lock and no allocation on the hot path (a message is a procedure, a pointer and a word: it lives in its
//     slot). Producers only ever pop to drop the oldest message (Drop_Oldest), the owner pops to run them.
//   * Order: messages of one producer run in the order it posted them, in every mode; messages of different producers
//     interleave as their pushes landed.
//   * A full ring is handled as `Post_Queue.overflow` says (Post_Overflow); the default is Block: no message is lost.
//   * Waking the owner: the first push after a drain calls `wake` (once until the next drain: a stream of a thousand
//     lines makes one wake, not a thousand PostMessage calls).
//   * Messages run with the owner's context (allocator, logger) inside post_queue_drain; their data belongs to whoever
//     the poster says. Messages that never run (dropped, or left when the queue is destroyed) go to `on_drop` so that
//     their data can be freed.

import "core:sync"
import "core:time"

// What a message runs: `data` and `word` are what was posted.
Post_Proc :: #type proc(data: rawptr, word: u64)

// What a push does when the ring is full.
Post_Overflow :: enum u8 {
	Block,        // the producer waits until the owner drained some (none lost). A push from the owner's own thread
	              // cannot wait for itself: it spills (as Grow) instead
	Drop_Oldest,  // the oldest message waiting is dropped (on_drop gets it) and the push goes in: newest data wins
	Grow,         // the message waits in a list behind the ring (one allocation and a lock per spilled message); the
	              // producers keep spilling until the owner emptied the list, so each one's order holds
	Fail,         // the push returns false and the producer decides
}

Post_Message :: struct {
	fn:   Post_Proc,
	data: rawptr,
	word: u64,
}

@(private = "file")
Post_Slot :: struct {
	seq:  uint,
	msg:  Post_Message,
}

Post_Stats :: struct {
	posted:  u64,   // pushes accepted (ring or spill)
	run:     u64,   // messages run by drains
	dropped: u64,   // messages dropped (Drop_Oldest) or left at destroy
	spilled: u64,   // messages that went to the spill list (Grow, or Block from the owner's thread)
	blocked: u64,   // pushes that had to wait (Block)
	refused: u64,   // pushes refused: Fail on a full ring, or a closed queue
	wakes:   u64,   // calls of `wake`
}

Post_Queue :: struct {
	slots:     []Post_Slot,
	mask:      uint,
	overflow:  Post_Overflow,
	on_drop:   Post_Proc,              // messages that will never run (nil: nothing to free)
	wake:      proc(user: rawptr),     // asks the owner to drain (set before producers start)
	wake_user: rawptr,                 // atomic: post_queue_set_wake_user may change it while producers run
	owner:     int,                    // atomic: the thread that drains (sync.current_thread_id)
	_:         [64]u8,
	head:      uint,                   // atomic: next slot to push
	_:         [64]u8,
	tail:      uint,                   // atomic: next slot to pop
	_:         [64]u8,
	wake_pending: bool,                // atomic: a wake was asked since the last drain
	closed:    bool,                   // atomic
	space:     sync.Futex,             // bumped by drains that freed slots while producers wait (Block)
	waiting:   i32,                    // atomic: producers waiting for space
	spill_lock: sync.Mutex,
	spill:     [dynamic]Post_Message,
	spill_count: int,                  // atomic: len(spill), read without the lock
	stats:     Post_Stats,             // atomic counters
}

// A queue of `capacity` slots (rounded up to a power of two, at least 2). `wake` is called with `wake_user` from the
// posting thread when the owner should drain (ui: platform.wake of the window). The thread that calls this is the owner
// until post_queue_set_owner says otherwise.
post_queue_init :: proc(q: ^Post_Queue, capacity: int, overflow := Post_Overflow.Block, wake: proc(user: rawptr) = nil, wake_user: rawptr = nil, on_drop: Post_Proc = nil, allocator := context.allocator) {
	n := 2
	for n < capacity { n *= 2 }
	q.slots = make([]Post_Slot, n, allocator)
	for &s, i in q.slots { s.seq = uint(i) }
	q.mask = uint(n - 1)
	q.overflow = overflow
	q.on_drop = on_drop
	q.wake = wake
	q.wake_user = wake_user
	q.owner = sync.current_thread_id()
	q.spill = make([dynamic]Post_Message, allocator)
}

// Refuses further pushes and releases the producers waiting for space (their push returns false). Messages already
// queued still run at the next drains.
post_queue_close :: proc(q: ^Post_Queue) {
	sync.atomic_store(&q.closed, true)
	sync.atomic_add(&q.space, 1)
	sync.futex_broadcast(&q.space)
}

// Closes the queue and frees it; the messages left go to on_drop. The producers must be done (joined) by now.
post_queue_destroy :: proc(q: ^Post_Queue) {
	if q.slots == nil { return }
	post_queue_close(q)
	for {
		m, ok := pop(q)
		if !ok { break }
		drop(q, m)
	}
	for m in q.spill { drop(q, m) }
	delete(q.slots)
	delete(q.spill)
	q.slots = nil
	q.spill = nil
}

post_queue_set_owner :: proc(q: ^Post_Queue, thread_id: int) { sync.atomic_store(&q.owner, thread_id) }
post_queue_set_wake_user :: proc(q: ^Post_Queue, user: rawptr) { sync.atomic_store(&q.wake_user, user) }

// Posts a call from any thread. False when the queue is closed, or full with Fail. A Block push waits for space as
// long as it takes (until a drain or post_queue_close).
post_queue_push :: proc(q: ^Post_Queue, fn: Post_Proc, data: rawptr = nil, word: u64 = 0) -> bool {
	m := Post_Message{fn, data, word}
	if sync.atomic_load(&q.closed) { refuse(q); return false }
	// once something spilled, every push spills until the owner took the list: a producer's later messages may not
	// overtake its earlier ones by going into the ring
	if sync.atomic_load(&q.spill_count) > 0 && spill(q, m) { accepted(q); return true }
	if try_push(q, m) { accepted(q); return true }
	switch q.overflow {
	case .Fail:
		refuse(q)
		return false
	case .Grow:
		spill(q, m)
		accepted(q)
		return true
	case .Drop_Oldest:
		for {
			if old, ok := pop(q); ok {
				sync.atomic_add(&q.stats.dropped, 1)
				if q.on_drop != nil { q.on_drop(old.data, old.word) }
			}
			if try_push(q, m) { accepted(q); return true }
			if sync.atomic_load(&q.closed) { refuse(q); return false }
		}
	case .Block:
		if sync.current_thread_id() == sync.atomic_load(&q.owner) {
			spill(q, m)
			accepted(q)
			return true
		}
		sync.atomic_add(&q.stats.blocked, 1)
		sync.atomic_add(&q.waiting, 1)
		defer sync.atomic_sub(&q.waiting, 1)
		for {
			epoch := u32(sync.atomic_load(&q.space))
			if try_push(q, m) { accepted(q); return true }
			if sync.atomic_load(&q.closed) { refuse(q); return false }
			ask_wake(q, true)   // the owner may have drained before the ring filled up: make sure it comes back
			// (bounded slices: a wake the owner's loop lost is asked again)
			sync.futex_wait_with_timeout(&q.space, epoch, 50 * time.Millisecond)
		}
	}
	return false
}

// Runs up to `budget` messages (< 0: all those waiting) on the calling thread, which should be the owner; `more` when
// some were left (ask for another frame). Messages posted by the messages themselves run in this drain or a later one,
// within the budget either way.
post_queue_drain :: proc(q: ^Post_Queue, budget := -1) -> (ran: int, more: bool) {
	if q.slots == nil { return }
	sync.atomic_store(&q.wake_pending, false)   // (before popping: a push after the last pop wakes again)
	limit := budget < 0 ? max(int) : budget
	for ran < limit {
		m, ok := pop(q)
		if !ok { break }
		ran += 1
		m.fn(m.data, m.word)
	}
	// the spill list follows only what is in the ring when every slot claimed has been taken (a slot claimed but not
	// yet filled may hold an earlier message of a producer that spilled since)
	if ran < limit && sync.atomic_load(&q.spill_count) > 0 && sync.atomic_load(&q.head) == sync.atomic_load(&q.tail) {
		// taken in chunks and run outside the lock (a message may post, and spill, again). Once the list was empty the
		// producers go back to the ring: what spills after that waits behind the ring, for the next drain
		chunk: [64]Post_Message
		for ran < limit {
			sync.mutex_lock(&q.spill_lock)
			take := min(len(q.spill), limit - ran, len(chunk))
			copy(chunk[:take], q.spill[:take])
			remove_range(&q.spill, 0, take)
			rest := len(q.spill)
			sync.atomic_store(&q.spill_count, rest)
			sync.mutex_unlock(&q.spill_lock)
			for m in chunk[:take] { ran += 1; m.fn(m.data, m.word) }
			if rest == 0 { break }
		}
	}
	sync.atomic_add(&q.stats.run, u64(ran))
	if ran > 0 && sync.atomic_load(&q.waiting) > 0 {
		sync.atomic_add(&q.space, 1)
		sync.futex_broadcast(&q.space)
	}
	more = post_queue_pending(q)
	return
}

// Whether messages wait (ring or spill list).
post_queue_pending :: proc(q: ^Post_Queue) -> bool {
	return sync.atomic_load(&q.head) != sync.atomic_load(&q.tail) || sync.atomic_load(&q.spill_count) > 0
}

post_queue_stats :: proc(q: ^Post_Queue) -> Post_Stats {
	return {
		posted = sync.atomic_load(&q.stats.posted), run = sync.atomic_load(&q.stats.run), dropped = sync.atomic_load(&q.stats.dropped),
		spilled = sync.atomic_load(&q.stats.spilled), blocked = sync.atomic_load(&q.stats.blocked),
		refused = sync.atomic_load(&q.stats.refused), wakes = sync.atomic_load(&q.stats.wakes),
	}
}

post_queue_capacity :: proc(q: ^Post_Queue) -> int { return len(q.slots) }

@(private = "file")
try_push :: proc(q: ^Post_Queue, m: Post_Message) -> bool {
	pos := sync.atomic_load_explicit(&q.head, .Relaxed)
	for {
		slot := &q.slots[pos & q.mask]
		seq := sync.atomic_load_explicit(&slot.seq, .Acquire)
		dif := int(seq) - int(pos)
		if dif == 0 {
			if cur, ok := sync.atomic_compare_exchange_weak_explicit(&q.head, pos, pos + 1, .Relaxed, .Relaxed); ok {
				slot.msg = m
				sync.atomic_store_explicit(&slot.seq, pos + 1, .Release)
				return true
			} else {
				pos = cur
			}
		} else if dif < 0 {
			return false   // full
		} else {
			pos = sync.atomic_load_explicit(&q.head, .Relaxed)
		}
	}
}

@(private = "file")
pop :: proc(q: ^Post_Queue) -> (m: Post_Message, ok: bool) {
	pos := sync.atomic_load_explicit(&q.tail, .Relaxed)
	for {
		slot := &q.slots[pos & q.mask]
		seq := sync.atomic_load_explicit(&slot.seq, .Acquire)
		dif := int(seq) - int(pos + 1)
		if dif == 0 {
			if cur, swapped := sync.atomic_compare_exchange_weak_explicit(&q.tail, pos, pos + 1, .Relaxed, .Relaxed); swapped {
				m = slot.msg
				sync.atomic_store_explicit(&slot.seq, pos + q.mask + 1, .Release)
				return m, true
			} else {
				pos = cur
			}
		} else if dif < 0 {
			return {}, false   // empty (or the next slot is claimed and not filled yet)
		} else {
			pos = sync.atomic_load_explicit(&q.tail, .Relaxed)
		}
	}
}

// Appends to the spill list; false when the owner emptied it meanwhile and the ring has room again (the caller pushes
// into the ring then).
@(private = "file")
spill :: proc(q: ^Post_Queue, m: Post_Message) -> bool {
	sync.mutex_lock(&q.spill_lock)
	defer sync.mutex_unlock(&q.spill_lock)
	if len(q.spill) == 0 && try_push(q, m) {
		// (pushed into the ring under the lock: no spilled message of anyone is waiting, the order holds)
		return true
	}
	append(&q.spill, m)
	sync.atomic_store(&q.spill_count, len(q.spill))
	sync.atomic_add(&q.stats.spilled, 1)
	return true
}

@(private = "file")
accepted :: proc(q: ^Post_Queue) {
	sync.atomic_add(&q.stats.posted, 1)
	ask_wake(q, false)
}

@(private = "file")
ask_wake :: proc(q: ^Post_Queue, again: bool) {
	if q.wake == nil { return }
	if sync.atomic_exchange(&q.wake_pending, true) && !again { return }
	user := sync.atomic_load(&q.wake_user)
	if user == nil { return }
	sync.atomic_add(&q.stats.wakes, 1)
	q.wake(user)
}

@(private = "file")
refuse :: proc(q: ^Post_Queue) { sync.atomic_add(&q.stats.refused, 1) }

@(private = "file")
drop :: proc(q: ^Post_Queue, m: Post_Message) {
	sync.atomic_add(&q.stats.dropped, 1)
	if q.on_drop != nil { q.on_drop(m.data, m.word) }
}

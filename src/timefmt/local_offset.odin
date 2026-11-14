package timefmt

// The machine's local time offset, for every program and every widget of the toolkit: one thread reads it (a system
// call, which may read the zone's file on Linux) at once and then every LOCAL_OFFSET_EVERY, and stores it atomically;
// the interface's thread only loads it. ui.init starts the watch, so a program of the toolkit has it with no call.

import "base:runtime"
import "core:sync"
import "core:thread"
import "core:time"

// How often the watch reads the offset again: a zone changed, or the daylight saving time began, during a run.
LOCAL_OFFSET_EVERY :: time.Minute

@(private = "file") offset_minutes: int    // (atomic) the last reading
@(private = "file") offset_known: bool     // (atomic) a reading was stored
@(private = "file") offset_watching: bool  // (atomic) the watch's thread started

// The local clock's offset from UTC now, in minutes (daylight saving included): the watch's last reading, 0 until its
// first one. An atomic load: any thread, any build.
local_offset_minutes :: proc() -> int { return sync.atomic_load(&offset_minutes) }

// Whether the watch has stored its first reading (a test waits for it; a program needs not).
local_offset_read_once :: proc() -> bool { return sync.atomic_load(&offset_known) }

// Starts the watch: the first call starts its thread, which reads the offset at once, then every LOCAL_OFFSET_EVERY,
// for the process's life. Any later call does nothing. Never reads the offset on the caller's thread.
local_offset_watch :: proc() {
	if _, first := sync.atomic_compare_exchange_strong(&offset_watching, false, true); !first { return }
	watch :: proc() {
		for {
			sync.atomic_store(&offset_minutes, local_offset_read())
			sync.atomic_store(&offset_known, true)
			time.sleep(LOCAL_OFFSET_EVERY)
		}
	}
	// (the process's own memory, for the thread and in it: not the caller's allocator, which may be a frame's or a
	// test's tracker)
	context.allocator = runtime.heap_allocator()
	c := runtime.default_context()
	c.allocator = runtime.heap_allocator()
	// (never joined: it lives as long as the process, as the zone it watches)
	_ = thread.create_and_start(watch, init_context = c, self_cleanup = true)
}

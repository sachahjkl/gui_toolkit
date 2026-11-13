package tk_config

// The user's file, written off the program's loop. A write is a disk call (and a flush), which may take long on a slow
// or busy disk: on the loop it froze the window, at each column dragged or theme picked. The loop calls
// user_writer_save once per round: when the user's values changed since the last text (`Prefs.user_version`), it
// serializes them (cheap, and it reads the registry, so on the loop) and hands the text to the writer's thread, which
// writes it (write_user_file). A text not written yet is replaced by a newer one: many changes, one write.
//
//	config.user_writer_start(&app.writer, &app.prefs, path)   // after the file was read
//	for running {
//		...
//		config.user_writer_save(&app.writer, &app.prefs)
//		if config.user_writer_failed(&app.writer) { show("The preferences cannot be written") }
//	}
//	config.user_writer_stop(&app.writer, &app.prefs)          // the last changes written, the thread ended

import "base:runtime"
import "core:sync"
import store "../store"

// (A store.Writer of the user's file: its thread, its atomic write, the newest text winning; the prefs' part is the
// version and the text.)
User_Writer :: struct {
	file:    store.Writer,
	version: u64,    // the user_version of the last text handed over (or read from the file)
	open:    bool,
	failed:  bool,   // (atomic) a write failed since user_writer_failed last said so
}

// Starts the writer of `path`. The file has the values `p` holds now (just read): nothing to write until they change.
user_writer_start :: proc(wr: ^User_Writer, p: ^Prefs, path: string) {
	wr.version, wr.open = p.user_version, true
	store.writer_open(&wr.file, path, on_failed = proc(user: rawptr, path: string) { sync.atomic_store(&(^User_Writer)(user).failed, true) }, user = wr, allocator = runtime.heap_allocator())
}

// The user's values, handed to the thread when they changed since the last text. On the loop, once per round.
user_writer_save :: proc(wr: ^User_Writer, p: ^Prefs) {
	if !wr.open || p.user_version == wr.version { return }
	wr.version = p.user_version
	store.writer_put(&wr.file, transmute([]u8)serialize_user(p, context.temp_allocator))
}

// Whether a write failed since the last call (a full disk, a folder that cannot be made); the next change tries again.
user_writer_failed :: proc(wr: ^User_Writer) -> bool { return sync.atomic_exchange(&wr.failed, false) }

// The last changes written, then the thread ends (when the program closes). False: a write failed and was not told.
user_writer_stop :: proc(wr: ^User_Writer, p: ^Prefs) -> bool {
	if !wr.open { return true }
	user_writer_save(wr, p)
	store.writer_close(&wr.file)
	ok := !sync.atomic_load(&wr.failed)
	wr^ = {}
	return ok
}

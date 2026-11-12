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
import "core:strings"
import "core:sync"
import "core:thread"

User_Writer :: struct {
	path:    string,           // owned
	version: u64,              // the user_version of the last text handed over (or read from the file)
	thread:  ^thread.Thread,
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	text:    string,           // the newest text the thread has not taken (heap)
	waiting: bool,
	failed:  bool,             // a write failed since user_writer_failed last said so
	stop:    bool,
}

// Starts the writer of `path`. The file has the values `p` holds now (just read): nothing to write until they change.
user_writer_start :: proc(wr: ^User_Writer, p: ^Prefs, path: string) {
	wr.path = strings.clone(path, runtime.heap_allocator())
	wr.version = p.user_version
	// (no context given: the thread's own, whose temporary allocator is its own)
	wr.thread = thread.create_and_start_with_data(wr, user_writer_run)
}

// The user's values, handed to the thread when they changed since the last text. On the loop, once per round.
user_writer_save :: proc(wr: ^User_Writer, p: ^Prefs) {
	if wr.thread == nil || p.user_version == wr.version { return }
	text := serialize_user(p, runtime.heap_allocator())
	wr.version = p.user_version
	sync.mutex_lock(&wr.mutex)
	old := wr.text
	wr.text, wr.waiting = text, true
	sync.cond_signal(&wr.cond)
	sync.mutex_unlock(&wr.mutex)
	if old != "" { delete(old, runtime.heap_allocator()) }
}

// Whether a write failed since the last call (a full disk, a folder that cannot be made); the next change tries again.
user_writer_failed :: proc(wr: ^User_Writer) -> bool {
	sync.mutex_lock(&wr.mutex)
	defer sync.mutex_unlock(&wr.mutex)
	failed := wr.failed
	wr.failed = false
	return failed
}

// The last changes written, then the thread ends (when the program closes). False: a write failed and was not told.
user_writer_stop :: proc(wr: ^User_Writer, p: ^Prefs) -> bool {
	if wr.thread == nil { return true }
	user_writer_save(wr, p)
	sync.mutex_lock(&wr.mutex)
	wr.stop = true
	sync.cond_signal(&wr.cond)
	sync.mutex_unlock(&wr.mutex)
	thread.join(wr.thread)
	thread.destroy(wr.thread)
	ok := !wr.failed
	delete(wr.path, runtime.heap_allocator())
	if wr.text != "" { delete(wr.text, runtime.heap_allocator()) }
	wr^ = {}
	return ok
}

@(private = "file")
user_writer_run :: proc(data: rawptr) {
	wr := (^User_Writer)(data)
	for {
		sync.mutex_lock(&wr.mutex)
		for !wr.waiting && !wr.stop { sync.cond_wait(&wr.cond, &wr.mutex) }
		if !wr.waiting {
			sync.mutex_unlock(&wr.mutex)
			return
		}
		text := wr.text
		wr.text, wr.waiting = "", false
		sync.mutex_unlock(&wr.mutex)
		ok := write_user_file(wr.path, text)
		delete(text, runtime.heap_allocator())
		free_all(context.temp_allocator)
		if !ok {
			sync.mutex_lock(&wr.mutex)
			wr.failed = true
			sync.mutex_unlock(&wr.mutex)
		}
	}
}

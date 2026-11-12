// Package store: a program's small files of keys and values (the last session, a server chosen, what a list remembers),
// kept in memory and written later, on a thread of their own, atomically.
//
// A Store is one file of lines `key<separator>value`, in their order. `open` reads it once (on the calling thread: a
// program opens its stores at its start, before its window, where nothing waits on it). After that, nothing a program
// calls touches the disk: `get` and `set` are in memory, and a worker thread writes the file once the changes rest
// (`wait_ms` after the last, at most `most_ms` after the first), through a temporary file renamed over it
// (fsx.write_atomic): a crash leaves the old file or the new one, never a part. `flush` writes what is pending now and
// waits (the end of the program), `close` flushes and ends the worker.
//
// A Writer is the same worker for a file a program formats itself (JSON...): `writer_put` hands it the whole content.
//
// A zero Store is one in memory only (no path: as in tests); every procedure takes it.
//
// The package is named `tk_store` (the directory is `store`, imported as `gt:store`), as the toolkit's others.
package tk_store

import "base:runtime"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "../fsx"

// The rest the changes wait for before the file is written, and the longest a change waits while others go on.
WAIT_MS :: 1000
MOST_MS :: 5000
// Between a key and its value when none is said (the zero Store's).
SEPARATOR :: '\t'

Entry :: struct {
	key, value: string,
}

// What the worker's write ends in, on the worker's thread: a program posts it to its interface (ui.post).
Failed_Proc :: #type proc(user: rawptr, path: string)

// The worker: one file written later. A program does not touch its fields.
Saver :: struct {
	path:      string,          // ("": nowhere, no worker)
	wait:      time.Duration,
	most:      time.Duration,
	private:   bool,
	on_failed: Failed_Proc,
	user:      rawptr,
	owner:     rawptr,
	produce:   proc(owner: rawptr, b: ^strings.Builder),   // the file's content, under the mutex
	mutex:     sync.Mutex,
	changed:   sync.Cond,       // a change, a flush or the close: the worker looks again
	written:   sync.Cond,       // a write ended: a flush waiting looks again
	dirty:     bool,            // changed since the content was last taken
	writing:   bool,            // the worker writes what it took
	flushes:   int,             // flushes waiting: the worker writes without waiting for the rest
	closing:   bool,
	first:     time.Tick,       // the first change not written, the last
	last:      time.Tick,
	thread:    ^thread.Thread,
	allocator: runtime.Allocator,
}

Store :: struct {
	saver:     Saver,
	separator: u8,
	entries:   [dynamic]Entry,   // in the file's order (keys and values owned)
	index:     map[string]int,   // a key's place in entries (its keys are the entries')
}

// Reads the file at `path` into `s` and starts its worker. `loaded` is false when there was no file to read (absent,
// unreadable): the store starts empty and the file is made at the first change. A line with no separator, or a key seen
// already (the first stays), is skipped; a leading byte-order mark and the `\r` of a line are dropped.
//
// It reads on the calling thread: call it at the program's start, before the interface's loop, or on a worker.
// `private`: the file is readable by its user only (fsx.write_atomic). `on_failed` runs on the worker after a write that failed.
open :: proc(s: ^Store, path: string, separator: u8 = SEPARATOR, wait_ms := WAIT_MS, most_ms := MOST_MS, private := false, on_failed: Failed_Proc = nil, user: rawptr = nil, allocator := context.allocator) -> (loaded: bool) {
	s.separator = separator
	ready(s, allocator)
	if path != "" {
		if data, ok := fsx.read_all(path, context.temp_allocator); ok {
			parse(s, string(data))
			loaded = true
		}
	}
	saver_start(&s.saver, path, wait_ms, most_ms, private, on_failed, user, s, store_produce, allocator)
	return
}

// The value of `key`, copied into `allocator` (whatever another thread sets meanwhile).
get :: proc(s: ^Store, key: string, allocator := context.temp_allocator) -> (value: string, ok: bool) {
	sync.guard(&s.saver.mutex)
	i, known := s.index[key]
	if !known { return "", false }
	return strings.clone(s.entries[i].value, allocator), true
}

// `key` to `value` in memory; the file follows. False when the line could not hold them: an empty key, a key with the
// separator, a key or a value with a line break. A new key goes at the end; a value that is the same changes nothing.
set :: proc(s: ^Store, key, value: string) -> bool {
	if !fits(s, key, value) { return false }
	sync.guard(&s.saver.mutex)
	ready(s, context.allocator)
	if i, known := s.index[key]; known {
		e := &s.entries[i]
		if e.value == value { return true }
		delete(e.value, s.saver.allocator)
		e.value = strings.clone(value, s.saver.allocator)
	} else {
		add(s, key, value)
	}
	saver_touch(&s.saver)
	return true
}

// Forgets `key` (nothing when it is not there).
remove :: proc(s: ^Store, key: string) {
	sync.guard(&s.saver.mutex)
	i, known := s.index[key]
	if !known { return }
	e := s.entries[i]
	delete_key(&s.index, e.key)
	ordered_remove(&s.entries, i)
	for j in i ..< len(s.entries) { s.index[s.entries[j].key] = j }   // (each after it one place back)
	delete(e.key, s.saver.allocator)
	delete(e.value, s.saver.allocator)
	saver_touch(&s.saver)
}

// Every entry becomes `entries`, in their order, at once: the worker never writes a part of the change (a list a program
// rewrites whole). An entry the line could not hold, or a key twice (the first stays), is left out.
replace :: proc(s: ^Store, entries: []Entry) {
	sync.guard(&s.saver.mutex)
	ready(s, context.allocator)
	clear_all(s)
	for e in entries {
		if !fits(s, e.key, e.value) || e.key in s.index { continue }
		add(s, e.key, e.value)
	}
	saver_touch(&s.saver)
}

// The entries in their order, copied into `allocator`.
list :: proc(s: ^Store, allocator := context.temp_allocator) -> []Entry {
	sync.guard(&s.saver.mutex)
	out := make([]Entry, len(s.entries), allocator)
	for e, i in s.entries { out[i] = {strings.clone(e.key, allocator), strings.clone(e.value, allocator)} }
	return out
}

// The keys in their order, copied into `allocator`.
keys :: proc(s: ^Store, allocator := context.temp_allocator) -> []string {
	sync.guard(&s.saver.mutex)
	out := make([]string, len(s.entries), allocator)
	for e, i in s.entries { out[i] = strings.clone(e.key, allocator) }
	return out
}

count :: proc(s: ^Store) -> int {
	sync.guard(&s.saver.mutex)
	return len(s.entries)
}

// Writes what changed now, and returns once it is on the disk (or failed). It waits on the disk: the end of a program, a
// test; never the interface's frames.
flush :: proc(s: ^Store) { saver_flush(&s.saver) }

// Writes what changed, ends the worker and frees the store. It is zero after.
close :: proc(s: ^Store) {
	saver_stop(&s.saver)   // (the worker ended: nothing else holds the store, and the mutex goes with it)
	clear_all(s)
	delete(s.entries)
	delete(s.index)
	s^ = {}
}

////////////////////////////////
// Writer: a whole file a program formats

Writer :: struct {
	saver: Saver,
	data:  [dynamic]byte,   // the content to write next
}

// A Writer of the file at `path` (nothing is read). `wait_ms` 0: what is put is written at once, on the worker; a program
// that puts at each change says how long to wait for the changes to rest.
writer_open :: proc(w: ^Writer, path: string, wait_ms := 0, most_ms := 0, private := false, on_failed: Failed_Proc = nil, user: rawptr = nil, allocator := context.allocator) {
	w.data = make([dynamic]byte, allocator)
	saver_start(&w.saver, path, wait_ms, most_ms, private, on_failed, user, w, writer_produce, allocator)
}

// The file's whole content next (copied).
writer_put :: proc(w: ^Writer, data: []byte) {
	sync.guard(&w.saver.mutex)
	clear(&w.data)
	append(&w.data, ..data)
	saver_touch(&w.saver)
}

writer_flush :: proc(w: ^Writer) { saver_flush(&w.saver) }

// Writes what was put last, ends the worker and frees the Writer. It is zero after.
writer_close :: proc(w: ^Writer) {
	saver_stop(&w.saver)
	delete(w.data)
	w^ = {}
}

////////////////////////////////
// Inside

@(private)
fits :: proc(s: ^Store, key, value: string) -> bool {
	if key == "" || strings.index_byte(key, separator_of(s)) >= 0 { return false }
	return strings.index_any(key, "\r\n") < 0 && strings.index_any(value, "\r\n") < 0
}

@(private)
separator_of :: proc(s: ^Store) -> u8 { return s.separator != 0 ? s.separator : SEPARATOR }

// The containers, in the store's allocator (a zero Store takes the caller's at its first change).
@(private)
ready :: proc(s: ^Store, allocator: runtime.Allocator) {
	if s.saver.allocator.procedure == nil { s.saver.allocator = allocator }
	if s.entries.allocator.procedure == nil {
		s.entries = make([dynamic]Entry, s.saver.allocator)
		s.index = make(map[string]int, s.saver.allocator)
	}
}

@(private)
add :: proc(s: ^Store, key, value: string) {
	e := Entry{strings.clone(key, s.saver.allocator), strings.clone(value, s.saver.allocator)}
	append(&s.entries, e)
	s.index[e.key] = len(s.entries) - 1
}

@(private)
clear_all :: proc(s: ^Store) {
	for e in s.entries { delete(e.key, s.saver.allocator); delete(e.value, s.saver.allocator) }
	clear(&s.entries)
	clear(&s.index)
}

@(private)
parse :: proc(s: ^Store, text: string) {
	sep := separator_of(s)
	rest := strings.trim_prefix(text, "\uFEFF")
	for line in strings.split_lines_iterator(&rest) {
		i := strings.index_byte(line, sep)
		if i <= 0 || line[:i] in s.index { continue }
		add(s, line[:i], line[i + 1:])
	}
}

@(private)
store_produce :: proc(owner: rawptr, b: ^strings.Builder) {
	s := (^Store)(owner)
	sep := separator_of(s)
	for e in s.entries {
		strings.write_string(b, e.key)
		strings.write_byte(b, sep)
		strings.write_string(b, e.value)
		strings.write_byte(b, '\n')
	}
}

@(private)
writer_produce :: proc(owner: rawptr, b: ^strings.Builder) {
	w := (^Writer)(owner)
	strings.write_bytes(b, w.data[:])
}

@(private)
saver_start :: proc(v: ^Saver, path: string, wait_ms, most_ms: int, private: bool, on_failed: Failed_Proc, user, owner: rawptr, produce: proc(owner: rawptr, b: ^strings.Builder), allocator: runtime.Allocator) {
	if v.allocator.procedure == nil { v.allocator = allocator }   // (a store used before it was opened keeps the one it has)
	v.wait = time.Duration(max(wait_ms, 0)) * time.Millisecond
	v.most = time.Duration(max(most_ms, wait_ms, 0)) * time.Millisecond
	v.private, v.on_failed, v.user, v.owner, v.produce = private, on_failed, user, owner, produce
	if path == "" { return }
	v.path = strings.clone(path, allocator)
	// (its own context: the worker's temporary allocator is its own, not the opener's)
	v.thread = thread.create_and_start_with_data(v, saver_run, name = "store")
}

// Under the mutex: a change to write. Without a worker (no path) nothing is pending.
@(private)
saver_touch :: proc(v: ^Saver) {
	if v.thread == nil { return }
	now := time.tick_now()
	if !v.dirty { v.first = now }
	v.dirty, v.last = true, now
	sync.cond_signal(&v.changed)
}

@(private)
saver_flush :: proc(v: ^Saver) {
	if v.thread == nil { return }
	sync.guard(&v.mutex)
	v.flushes += 1
	sync.cond_signal(&v.changed)
	for v.dirty || v.writing { sync.cond_wait(&v.written, &v.mutex) }
	v.flushes -= 1
}

@(private)
saver_stop :: proc(v: ^Saver) {
	if v.thread != nil {
		sync.mutex_lock(&v.mutex)
		v.closing = true
		sync.cond_signal(&v.changed)
		sync.mutex_unlock(&v.mutex)
		thread.join(v.thread)
		thread.destroy(v.thread)
		v.thread = nil
	}
	delete(v.path, v.allocator)
	v.path = ""
}

// The worker: waits for a change, for the changes to rest, takes the content under the mutex and writes it without it, so
// that a set never waits on the disk.
@(private)
saver_run :: proc(data: rawptr) {
	v := (^Saver)(data)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for {
		sync.mutex_lock(&v.mutex)
		for !v.closing && !(v.dirty && v.flushes > 0) {
			if !v.dirty {
				sync.cond_wait(&v.changed, &v.mutex)
				continue
			}
			due := time.tick_add(v.last, v.wait)
			if latest := time.tick_add(v.first, v.most); time.tick_diff(latest, due) > 0 { due = latest }
			left := time.tick_diff(time.tick_now(), due)
			if left <= 0 { break }
			_ = sync.cond_wait_with_timeout(&v.changed, &v.mutex, left)
		}
		if !v.dirty {   // (closing, nothing left)
			sync.mutex_unlock(&v.mutex)
			return
		}
		strings.builder_reset(&b)
		v.produce(v.owner, &b)
		v.dirty, v.writing = false, true
		sync.mutex_unlock(&v.mutex)

		ok := saver_write(v, b.buf[:])
		if !ok && v.on_failed != nil { v.on_failed(v.user, v.path) }
		free_all(context.temp_allocator)

		sync.mutex_lock(&v.mutex)
		v.writing = false
		sync.cond_broadcast(&v.written)
		sync.mutex_unlock(&v.mutex)
	}
}

// Its folder first (the first start has none), then through a temporary file, on the disk when it returns: a crash or a
// power cut after it keeps it.
@(private)
saver_write :: proc(v: ^Saver, data: []byte) -> bool {
	if dir := filepath.dir(v.path); dir != "" && dir != "." { fsx.make_dirs(dir) }
	return fsx.write_atomic(v.path, data, flush = true, private = v.private)
}

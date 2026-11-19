package fsx

// A file written in parts (src/md/features/downloads.md): the parts go to a temporary file beside the target, which
// takes the target's name at commit (replace: a reader sees the old file or the whole new one) or goes at abort. A
// transfer cut half-way never leaves a file of the target's name with a part of its content.
//
//	w: fsx.Writer
//	if !fsx.writer_open(&w, path) { return }
//	for chunk in chunks { if !fsx.writer_append(&w, chunk) { break } }
//	if !fsx.writer_commit(&w) { ... }   // or fsx.writer_abort(&w): the target as it was

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import base "../base"

// One file being written. The zero value is a writer that holds nothing. One thread uses it at a time (the thread
// that receives the parts); every call blocks on the disk.
Writer :: struct {
	target:  string,     // the file it becomes (heap)
	temp:    string,     // the file written: "<target>.<pid>.<id>.part", beside the target (heap)
	file:    ^os.File,   // nil: not open (zero, committed or aborted)
	written: i64,        // the bytes appended
	failed:  bool,       // an append failed: commit refuses
}

// Opens a temporary file beside `target` (the same folder: a rename never crosses a disk). `private`: readable by its
// user only (POSIX: mode 0600; Windows: the folder's access list, as any file). False: it cannot be made (the folder is
// missing or refused); `w` holds nothing then. `w` must hold nothing (zero, committed or aborted).
writer_open :: proc(w: ^Writer, target: string, private := false, loc := #caller_location) -> bool {
	base.blocking("fsx.writer_open", loc)
	a := runtime.heap_allocator()
	// (the writer's address tells two live writers of one process apart, the pid two processes; a leftover of a crash
	// with the same name is a part nobody reads, truncated)
	temp := fmt.aprintf("%s.%d.%x.part", target, os.get_pid(), uintptr(w), allocator = a)
	// (another thread may remove it while it is open: the program's end, a download still waiting for data)
	f, made := writer_temp_open(temp, private)
	if !made {
		delete(temp, a)
		w^ = {}
		return false
	}
	w^ = {target = strings.clone(target, a), temp = temp, file = f}
	return true
}

// Appends `bytes` at the end of the temporary file. False: the write failed (a full disk); every later append and the
// commit refuse, and abort removes what was written.
writer_append :: proc(w: ^Writer, bytes: []u8, loc := #caller_location) -> bool {
	base.blocking("fsx.writer_append", loc)
	if w.file == nil || w.failed { return false }
	at := 0
	for at < len(bytes) {
		n, err := os.write(w.file, bytes[at:min(len(bytes), at + IO_CHUNK_MAX_BYTES)])
		if err != nil || n <= 0 {
			w.failed = true
			return false
		}
		at += n
	}
	w.written += i64(len(bytes))
	return true
}

// Closes the temporary file and renames it over the target (replace: on Windows, a few tries while another program
// holds the target). `flush`: on the disk when it returns. False: the target is as it was and the temporary file is
// gone (an append failed, the close or the rename failed; with `flush`, the rename may be done but not on the disk).
// `w` holds nothing after it, whatever the answer.
writer_commit :: proc(w: ^Writer, flush := false, loc := #caller_location) -> bool {
	base.blocking("fsx.writer_commit", loc)
	if w.file == nil { return false }
	ok := !w.failed
	if ok && flush { ok = os.sync(w.file) == nil }
	if os.close(w.file) != nil { ok = false }
	w.file = nil
	if ok { ok = replace(w.temp, w.target, flush) }
	if !ok { delete_file(w.temp) }
	writer_free(w)
	return ok
}

// Closes and removes the temporary file: the target is as it was. Nothing for a writer that holds nothing (it may be
// called after a commit, or twice).
writer_abort :: proc(w: ^Writer, loc := #caller_location) {
	if w.file == nil && w.temp == "" { return }
	base.blocking("fsx.writer_abort", loc)
	if w.file != nil { os.close(w.file) }
	w.file = nil
	delete_file(w.temp)
	writer_free(w)
}

@(private = "file")
writer_free :: proc(w: ^Writer) {
	a := runtime.heap_allocator()
	delete(w.target, a)
	delete(w.temp, a)
	w^ = {}
}

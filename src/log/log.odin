// Package log: a program's log, a file of lines written off the thread that logs, with levels (core:log's: debug, info, warning,
// error, fatal). install gives a runtime.Logger: the program sets it as context.logger once, and core:log's procedures write there.
//
//	install  the log of a program: its file platform.user_dir(.State, program)/logs/<program>.log, rotated past a size
//	flush    what was logged is in the file when it returns
//	close    flushes, ends the writer, frees the log
//	tail     the last lines, for a crash report (a crash.Source_Proc: crash.install({log_tail = {tk_log.tail, logger.data}}))
//	path     the file's path
//
// A line is formatted and kept on the thread that logs, under one lock, in the order the lines came; the writer (one job of a pool
// of one thread, gt:tasks) appends what is waiting to the file and, with Options.echo, to standard error: the thread that logs never
// waits on the disk. Past Options.max_bytes the file is renamed <program>.log.1 (the one before .log.2, and so on, Options.keep of
// them) and a new one is started.
//
// The last lines are also kept in a ring in memory, read with no lock by tail: a crash report shows them, the ones the writer had
// not written yet included. The crash package does not import this one, nor this one the crash package: the program joins them with
// a Source (the direction keeps each usable alone).
//
// (Named tk_log: core:log is `log`. Import it as `import tk_log "gt:log"`.)
package tk_log

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "../platform"
import "../tasks"

// The file is rotated past this size; this many older files are kept.
MAX_BYTES_DEFAULT :: 1 << 20
KEEP_DEFAULT :: 3
// The lines tail gives.
TAIL_LINES_DEFAULT :: 100
// The ring of the last lines, in bytes.
TAIL_BYTES :: 32 * 1024
EXTENSION :: ".log"

Options :: struct {
	program:    string,                 // the file's name, and its folder when dir is ""
	dir:        string,                 // "": platform.user_dir(.State, program)/logs
	level:      runtime.Logger_Level,   // the lowest level written (the zero value: .Debug)
	options:    runtime.Logger_Options, // .Short_File_Path, .Long_File_Path, .Line, .Procedure: where each line was logged
	max_bytes:  int,                    // 0: MAX_BYTES_DEFAULT
	keep:       int,                    // the older files kept (0: KEEP_DEFAULT)
	echo:       bool,                   // each line on standard error too
	tail_lines: int,                    // what tail gives at most (0: TAIL_LINES_DEFAULT)
}

// A log. Its fields are the package's: a program holds the runtime.Logger install gives.
Log :: struct {
	o:         Options,
	path:      string,
	allocator: runtime.Allocator,
	lock:      sync.Mutex,
	written:   sync.Cond,       // a write ended: flush looks again
	pending:   [dynamic]u8,     // the lines not written yet, in their order (under lock)
	queued:    u64,             // lines logged (under lock)
	done:      u64,             // lines written (under lock)
	closing:   bool,
	pool:      tasks.Pool,
	job:       tasks.Job,
	// the writer's own
	file:      ^os.File,
	size:      i64,
	failed:    bool,            // the file could not be opened: lines go to the ring (and standard error) only
	chunk:     [dynamic]u8,
	// the ring of the last lines: written under lock, read by tail with none
	ring:      [TAIL_BYTES]u8,
	ring_end:  u64,             // (atomic) bytes ever put in the ring
}

// The log of a program, its writer started. Set what it returns as context.logger (core:log's procedures then write there).
install :: proc(o: Options, allocator := context.allocator) -> runtime.Logger {
	l := new(Log, allocator)
	l.o = o
	l.allocator = allocator
	if l.o.max_bytes <= 0 { l.o.max_bytes = MAX_BYTES_DEFAULT }
	if l.o.keep <= 0 { l.o.keep = KEEP_DEFAULT }
	if l.o.tail_lines <= 0 { l.o.tail_lines = TAIL_LINES_DEFAULT }
	dir := o.dir
	if dir == "" { dir = default_dir(o.program, context.temp_allocator) }
	l.o.dir = strings.clone(dir, allocator)
	l.o.program = strings.clone(o.program, allocator)
	l.path = dir == "" ? "" : strings.concatenate({dir, "/", o.program, EXTENSION}, allocator)
	l.pending = make([dynamic]u8, allocator)
	l.chunk = make([dynamic]u8, allocator)
	l.job = tasks.Job{work = drain, data = l}
	worker := context
	worker.logger = runtime.default_logger()   // (the writer logs nothing; what it might call must not come back here)
	worker.allocator = allocator
	{
		context = worker
		tasks.start(&l.pool, {threads = 1})
	}
	return runtime.Logger{procedure = logger_proc, data = l, lowest_level = o.level, options = o.options}
}

// The folder of `program`'s logs when Options.dir is "": platform.user_dir(.State, program)/logs ("": the system has none).
default_dir :: proc(program: string, allocator := context.allocator) -> string {
	state := platform.user_dir(.State, program, context.temp_allocator)
	if state == "" { return "" }
	return strings.concatenate({state, "/logs"}, allocator)
}

// The file of the log ("": none).
path :: proc(logger: runtime.Logger) -> string {
	l := (^Log)(logger.data)
	return l.path
}

// Waits until every line logged before the call is in the file.
flush :: proc(logger: runtime.Logger) {
	l := (^Log)(logger.data)
	sync.lock(&l.lock)
	target := l.queued
	sync.unlock(&l.lock)
	tasks.ask(&l.pool, &l.job)
	sync.lock(&l.lock)
	for l.done < target && !l.closing { sync.cond_wait(&l.written, &l.lock) }
	sync.unlock(&l.lock)
}

// Writes what waits, ends the writer and frees the log. A program first sets another context.logger: the log is gone after this.
close :: proc(logger: runtime.Logger) {
	l := (^Log)(logger.data)
	flush(logger)
	tasks.stop(&l.pool)
	sync.lock(&l.lock)
	l.closing = true
	sync.cond_broadcast(&l.written)
	sync.unlock(&l.lock)
	drain(l)   // (a line logged during the stop)
	if l.file != nil { os.close(l.file) }
	delete(l.pending)
	delete(l.chunk)
	delete(l.path, l.allocator)
	delete(l.o.dir, l.allocator)
	delete(l.o.program, l.allocator)
	free(l, l.allocator)
}

// The last lines (Options.tail_lines at most), whole, oldest first, copied into `buf`: how many bytes. `user` is the logger's data
// (runtime.Logger.data). It takes no lock and allocates nothing: a crash handler calls it, on a thread that may hold the log's lock.
// A line being logged meanwhile may be missing.
tail :: proc "contextless" (user: rawptr, buf: []u8) -> int {
	l := (^Log)(user)
	if l == nil || len(buf) == 0 { return 0 }
	end := intrinsics.atomic_load(&l.ring_end)
	n := u64(min(len(buf), TAIL_BYTES))
	if n > end { n = end }
	start := end - n
	for i in 0 ..< n { buf[i] = l.ring[(start + i) % TAIL_BYTES] }
	// what a line logged during the copy wrote over is dropped
	after := intrinsics.atomic_load(&l.ring_end)
	first := u64(0)
	if after > TAIL_BYTES && after - TAIL_BYTES > start { first = min(after - TAIL_BYTES - start, n) }
	// whole lines only: from the first line end, unless the copy starts at the ring's beginning
	if start + first > 0 {
		for first < n && buf[first] != '\n' { first += 1 }
		if first < n { first += 1 }
	}
	// the last tail_lines of them
	lines := 0
	from := n
	for from > first {
		if buf[from - 1] == '\n' && from != n {
			lines += 1
			if lines == l.o.tail_lines { break }
		}
		from -= 1
	}
	if from < first { from = first }
	m := int(n - from)
	copy(buf[:m], buf[from:n])
	return m
}

////////////////////////////////
// Inside

@(private)
logger_proc :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
	l := (^Log)(data)
	line := format_line(level, text, options, location, time.now())
	sync.lock(&l.lock)
	append(&l.pending, ..transmute([]u8)line)
	l.queued += 1
	ring_put(l, transmute([]u8)line)
	sync.unlock(&l.lock)
	tasks.ask(&l.pool, &l.job)
}

// "2026-11-13T17:03:00.123Z INFO  text (file.odin:12)\n"; a line end inside the text starts a line indented by four spaces.
@(private)
format_line :: proc(level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location: runtime.Source_Code_Location, now: time.Time) -> string {
	b := strings.builder_make(context.temp_allocator)
	y, mon, d := time.date(now)
	h, mi, s := time.clock_from_time(now)
	ms := (time.to_unix_nanoseconds(now) / 1_000_000) % 1000
	fmt.sbprintf(&b, "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ %-5s ", y, int(mon), d, h, mi, s, ms, level_name(level))
	rest := strings.trim_right(text, "\r\n")
	for i := 0; i < len(rest); i += 1 {
		c := rest[i]
		if c == '\r' { continue }
		strings.write_byte(&b, c)
		if c == '\n' { strings.write_string(&b, "    ") }
	}
	if options & {.Short_File_Path, .Long_File_Path, .Line, .Procedure} != {} {
		strings.write_string(&b, " (")
		file := location.file_path
		if .Short_File_Path in options {
			if i := strings.last_index_any(file, "/\\"); i >= 0 { file = file[i + 1:] }
		}
		wrote := false
		if options & {.Short_File_Path, .Long_File_Path} != {} { strings.write_string(&b, file); wrote = true }
		if .Line in options { fmt.sbprintf(&b, "%s%d", wrote ? ":" : "", location.line); wrote = true }
		if .Procedure in options { fmt.sbprintf(&b, "%s%s()", wrote ? " " : "", location.procedure) }
		strings.write_byte(&b, ')')
	}
	strings.write_byte(&b, '\n')
	return strings.to_string(b)
}

@(private)
level_name :: proc(level: runtime.Logger_Level) -> string {
	switch {
	case level < .Info:    return "DEBUG"
	case level < .Warning: return "INFO"
	case level < .Error:   return "WARN"
	case level < .Fatal:   return "ERROR"
	}
	return "FATAL"
}

// Under lock.
@(private)
ring_put :: proc(l: ^Log, line: []u8) {
	end := intrinsics.atomic_load(&l.ring_end)
	data := line
	if len(data) > TAIL_BYTES { data = data[len(data) - TAIL_BYTES:] }
	for c, i in data { l.ring[(end + u64(i)) % TAIL_BYTES] = c }
	intrinsics.atomic_store(&l.ring_end, end + u64(len(data)))
}

// The writer: what waits, taken under the lock and written without it.
@(private)
drain :: proc(data: rawptr) {
	l := (^Log)(data)
	sync.lock(&l.lock)
	l.pending, l.chunk = l.chunk, l.pending
	clear(&l.pending)
	count := l.queued
	sync.unlock(&l.lock)
	if len(l.chunk) > 0 {
		write_chunk(l, l.chunk[:])
		if l.o.echo { _, _ = os.write(os.stderr, l.chunk[:]) }
		clear(&l.chunk)
	}
	sync.lock(&l.lock)
	l.done = max(l.done, count)
	sync.cond_broadcast(&l.written)
	sync.unlock(&l.lock)
}

// The lines that fit in the file go there; the file is rotated before a line that would not fit (a file holds at least one line,
// however long).
@(private)
write_chunk :: proc(l: ^Log, chunk: []u8) {
	if l.path == "" || l.failed { return }
	rest := chunk
	for len(rest) > 0 {
		if l.file == nil && !open_file(l) { return }
		room := i64(l.o.max_bytes) - l.size
		take := 0
		for take < len(rest) {
			end := take
			for end < len(rest) && rest[end] != '\n' { end += 1 }
			if end < len(rest) { end += 1 }
			if i64(end) > room && (take > 0 || l.size > 0) { break }
			take = end
		}
		if take == 0 {
			rotate(l)
			continue
		}
		n, _ := os.write(l.file, rest[:take])
		l.size += i64(n)
		rest = rest[take:]
	}
}

@(private)
open_file :: proc(l: ^Log) -> bool {
	_ = os.make_directory_all(l.o.dir)
	f, err := os.open(l.path, {.Write, .Create, .Append})
	if err != nil { l.failed = true; return false }
	l.file = f
	size, serr := os.file_size(f)
	l.size = serr == nil ? size : 0
	return true
}

// <program>.log becomes .log.1, .log.1 becomes .log.2 ..., the oldest past Options.keep goes.
@(private)
rotate :: proc(l: ^Log) {
	if l.file != nil { os.close(l.file); l.file = nil }
	numbered :: proc(l: ^Log, n: int) -> string { return fmt.tprintf("%s.%d", l.path, n) }
	_ = os.remove(numbered(l, l.o.keep))
	for n := l.o.keep - 1; n >= 1; n -= 1 {
		from := numbered(l, n)
		if os.exists(from) { _ = os.rename(from, numbered(l, n + 1)) }
	}
	_ = os.rename(l.path, numbered(l, 1))
	l.size = 0
}

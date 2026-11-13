// Package crash: a report of each crash of a program, written by the program itself as it dies, and what the next start learns of
// it. Nothing is sent anywhere: the report is a text file in the program's folder, for the person to open or copy.
//
//	install        once, at the start: the handler of crashes (Linux: the fatal signals; Windows: the unhandled exceptions)
//	begin_session  a session runs: an end without a report (a kill, a power cut) is found at the next start
//	end_session    the clean end of the session
//	last_report    the report of a crash since the last clean end (the start after a crash says so)
//	report_parse   a report's text as a Report; report_text the other way
//
// The handler writes the report with no allocation and no lock: its buffers are taken at install, the text is written with system
// calls only (crash_<os>.odin). The faulting thread's stack comes first, then every other thread's, the modules with their base
// addresses, the last lines of the log and the settings that differ from their default (two Sources the program gives: this
// package imports neither the log nor the configuration). The frames are addresses with their module and offset: what
// toolbox.crash_symbolize names offline with the build's map or binary.
//
// Importing the package does nothing: a program opts in with one call to install. (Named tk_crash: a program may have a `crash`
// package of its own.)
package tk_crash

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import "../fsx"
import "../platform"

// What a report's file name ends with, and the names of the folder's other files.
REPORT_EXTENSION :: ".txt"
SESSION_FILE :: "session.txt"      // a session runs: its process id and start (begin_session)
CLEAN_END_FILE :: "clean-end.txt"  // the last clean end (end_session): a report older than it was seen
// The prefixes of the reports' file names, by kind.
CRASH_PREFIX :: "crash"
UNCLEAN_PREFIX :: "unclean"
EXIT_PREFIX :: "exit"

// The room for each text the handler keeps (longer text is cut).
NAME_BYTES :: 128
DIR_BYTES :: 1024
SOURCE_BYTES :: 64 * 1024   // what a Source may give

// Writes text into `buf` and returns how many bytes it wrote. It runs in the crash handler, on a thread that may hold any lock: it
// allocates nothing, takes no lock and waits for nothing (copy a snapshot the program keeps).
Source_Proc :: #type proc "contextless" (user: rawptr, buf: []u8) -> int

Source :: struct {
	text: Source_Proc,   // nil: no such section
	user: rawptr,
}

Install_Options :: struct {
	program:    string,   // the program's name: its report folder and the report's "program" line
	version:    string,
	commit:     string,   // the source's commit ("": not known)
	report_dir: string,   // "": platform.user_dir(.State, program)/crashes
	minidump:   bool,     // Windows: a minidump beside each report (<report>.dmp)
	log_tail:   Source,   // the last lines of the log (tk_log.tail)
	settings:   Source,   // the settings that differ from their default, one per line
}

// What install keeps for the handler, in fixed buffers: nothing is allocated while the process is crashing.
@(private)
Kept :: struct {
	installed: i32,   // (atomic)
	program:   [NAME_BYTES]u8, program_len: int,
	version:   [NAME_BYTES]u8, version_len: int,
	commit:    [NAME_BYTES]u8, commit_len: int,
	build:     [NAME_BYTES]u8, build_len: int,
	dir:       [DIR_BYTES]u8, dir_len: int,
	minidump:  bool,
	log_tail:  Source,
	settings:  Source,
	source:    [SOURCE_BYTES]u8,   // what a Source gives, in the handler
	session_open: i32,             // (atomic) begin_session ran, end_session not yet
}

@(private)
kept: Kept

@(private) kept_program :: proc "contextless" () -> string { return string(kept.program[:kept.program_len]) }
@(private) kept_version :: proc "contextless" () -> string { return string(kept.version[:kept.version_len]) }
@(private) kept_commit :: proc "contextless" () -> string { return string(kept.commit[:kept.commit_len]) }
@(private) kept_build :: proc "contextless" () -> string { return string(kept.build[:kept.build_len]) }
@(private) kept_dir :: proc "contextless" () -> string { return string(kept.dir[:kept.dir_len]) }

@(private)
keep :: proc(buf: []u8, s: string) -> int { return copy(buf, s) }

// What a Source gives, through the handler's buffer, as the section `name`.
@(private)
write_source :: proc "contextless" (o: ^Out, name: string, s: Source) {
	n := 0
	if s.text != nil { n = clamp(s.text(s.user, kept.source[:]), 0, len(kept.source)) }
	out_text_section(o, name, kept.source[:n])
}

// Installs the handler of crashes, once for the process (a second call does nothing and returns false). False too where this system
// has no handler (crash_other.odin): begin_session and last_report still work there.
install :: proc(o: Install_Options) -> bool {
	if intrinsics.atomic_exchange(&kept.installed, 1) != 0 { return false }
	kept.program_len = keep(kept.program[:], o.program)
	kept.version_len = keep(kept.version[:], o.version)
	kept.commit_len = keep(kept.commit[:], o.commit)
	dir := o.report_dir
	if dir == "" { dir = default_report_dir(o.program, context.temp_allocator) }
	kept.dir_len = keep(kept.dir[:], dir)
	kept.minidump = o.minidump
	kept.log_tail, kept.settings = o.log_tail, o.settings
	kept.build_len = read_build(kept.build[:])
	return install_handler()
}

// The folder where `program`'s reports go when Install_Options.report_dir is "": platform.user_dir(.State, program)/crashes ("": the system
// has no such folder).
default_report_dir :: proc(program: string, allocator := context.allocator) -> string {
	state := platform.user_dir(.State, program, context.temp_allocator)
	if state == "" { return "" }
	return strings.concatenate({state, "/crashes"}, allocator)
}

// The folder of the reports install was given ("": install was not called).
report_dir :: proc() -> string { return kept_dir() }

// The build of the running executable, as a report names it (Linux: its GNU build id, Windows: its PE time stamp and size).
build_id :: proc() -> string { return kept_build() }

// The system, as a report names it: "<os> <arch>".
@(private)
SYSTEM_NAME :: "linux amd64" when ODIN_OS == .Linux && ODIN_ARCH == .amd64 else
	"linux arm64" when ODIN_OS == .Linux && ODIN_ARCH == .arm64 else
	"windows amd64" when ODIN_OS == .Windows && ODIN_ARCH == .amd64 else
	"windows arm64" when ODIN_OS == .Windows && ODIN_ARCH == .arm64 else
	"other"

////////////////////////////////
// Sessions

// A session starts. A file in the report folder says it runs (its process id and start); end_session removes it. Found here with its
// process gone, the last session ended with no report at all (a kill, the out-of-memory killer, a power cut, a fail-fast): this writes
// an "unclean" report for it, which last_report then gives. Call it at the start, after install, before the interface's loop (it reads
// and writes files on the calling thread).
begin_session :: proc() {
	dir := kept_dir()
	if dir == "" { return }
	fsx.make_dirs(dir)
	path := strings.concatenate({dir, "/", SESSION_FILE}, context.temp_allocator)
	if prev, ok := fsx.read_all(path, context.temp_allocator); ok {
		s := parse_session(string(prev))
		if s.pid != 0 {
			now, alive := process_started(s.pid)
			if !alive || now != s.start { write_unclean(dir, s) }
		}
	}
	pid := u64(os.get_pid())
	start, _ := process_started(pid)
	text := fmt.tprintf("pid: %d\nstart: %d\nprogram: %s\nversion: %s\n", pid, start, kept_program(), kept_version())
	_ = fsx.write_atomic(path, transmute([]u8)text)
	intrinsics.atomic_store(&kept.session_open, 1)
}

// The session ends cleanly: its file goes, and the clean end is noted (a report older than it was the previous sessions').
// A thread of its own does the files, and the call waits for it (as config.user_writer_stop waits for its writer): the
// thread that calls it at the end of the program is often the one that ran the interface, which makes no disk call, and
// the files must be there before the process ends.
end_session :: proc() {
	intrinsics.atomic_store(&kept.session_open, 0)
	dir := kept_dir()
	if dir == "" { return }
	t := thread.create_and_start_with_data(rawptr(&dir), session_close)
	if t == nil { session_close(&dir); return }   // (no thread to be had: the files all the same)
	thread.join(t)
	thread.destroy(t)
}

@(private = "file")
session_close :: proc(data: rawptr) {
	dir := (^string)(data)^
	_ = fsx.delete_file(strings.concatenate({dir, "/", SESSION_FILE}, context.temp_allocator))
	_ = fsx.write_atomic(strings.concatenate({dir, "/", CLEAN_END_FILE}, context.temp_allocator), transmute([]u8)string("clean end\n"))
}

// The newest report written since the last clean end: the program crashed (or was killed) last time, and can say so ("open the
// report", "copy it"). ok is false when there is none, or the last session ended cleanly after it. Reads the folder on the calling thread.
last_report :: proc(allocator := context.allocator) -> (path: string, ok: bool) {
	dir := kept_dir()
	if dir == "" { return }
	_, clean, has_clean := fsx.stat(strings.concatenate({dir, "/", CLEAN_END_FILE}, context.temp_allocator))
	best_stamp: i64
	best := ""
	for f in fsx.list_files(dir, context.temp_allocator) {
		if !is_report_name(f.name) { continue }
		full := strings.concatenate({dir, "/", f.name}, context.temp_allocator)
		_, stamp, good := fsx.stat(full)
		if !good || (has_clean && stamp <= clean) { continue }
		if best == "" || stamp > best_stamp || (stamp == best_stamp && f.name > best) {
			best, best_stamp = f.name, stamp
		}
	}
	if best == "" { return }
	return strings.concatenate({dir, "/", best}, allocator), true
}

@(private)
is_report_name :: proc(name: string) -> bool {
	if !strings.has_suffix(name, REPORT_EXTENSION) { return false }
	for p in ([3]string{CRASH_PREFIX, UNCLEAN_PREFIX, EXIT_PREFIX}) {
		if strings.has_prefix(name, p) && len(name) > len(p) && name[len(p)] == '-' { return true }
	}
	return false
}

@(private)
Session :: struct {
	pid, start:       u64,
	program, version: string,
}

@(private)
parse_session :: proc(text: string) -> (s: Session) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		key, value, ok := split_field(strings.trim_right(line, "\r"))
		if !ok { continue }
		switch key {
		case "pid":     s.pid, _ = strconv.parse_u64(value, 10)
		case "start":   s.start, _ = strconv.parse_u64(value, 10)
		case "program": s.program = value
		case "version": s.version = value
		}
	}
	return
}

// The report of a session that ended with none of its own.
@(private)
write_unclean :: proc(dir: string, s: Session) {
	now := unix_now()
	date_buf, name_buf: [64]u8
	r := Report{
		program = s.program, version = s.version, system = SYSTEM_NAME, date = out_date(date_buf[:], now), pid = s.pid,
		kind = KIND_UNCLEAN, reason = UNCLEAN_REASON, complete = true,
	}
	text := report_text(r, context.temp_allocator)
	name := out_report_name(name_buf[:], UNCLEAN_PREFIX, now, s.pid)
	_ = fsx.write_atomic(strings.concatenate({dir, "/", name}, context.temp_allocator), transmute([]u8)text)
}

@(private)
unix_now :: proc() -> i64 { return time.to_unix_seconds(time.now()) }

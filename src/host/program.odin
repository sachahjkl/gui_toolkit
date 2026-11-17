package tk_host

// A program's start: its log (gt:log) and its crash handler (gt:crash), in the one order that works, before any thread
// and any window. Every program wrote the same five lines; their order matters twice: the crash handler takes the log's
// tail, so the log comes first, and the session begins before the last report is read, because begin_session is what
// turns a session that ended with no report (a kill, a power cut) into the "unclean" report last_report then gives.
//
//	p := host.program_start({name = APP_NAME, folder = APP_FOLDER, version = APP_VERSION})
//	context.logger = p.logger
//	defer host.program_end(&p)
//	...
//	crash_bar.init(&app.crash_bar, p.last_crash)   // "" leaves the bar empty
//
// It reads and writes the report folder on the calling thread: call it in main, before the interface's loop.

import "base:runtime"
import "core:log"
import "core:path/filepath"
import "core:strings"
import crash "../crash"
import tk_log "../log"

Program_Start_Options :: struct {
	name:    string,   // the technical name: the log's file and the reports' "program" line
	folder:  string,   // the program's folder in its vendor's (platform.user_dir's name): where the log and the reports go
	version: string,
	// the state folder that holds logs/ and crashes/ ("": platform.user_dir(.State, folder)); a test's or a portable
	// profile's
	dir:     string,
	quiet:   bool,           // the log's lines are not echoed on standard error (a program with no terminal to read them)
	settings: crash.Source,  // the settings that differ from their default, for a report (nil: none)
	// a process that is not the program's session (a torn-off window's own process, whose end is its tab's): no session
	// mark, and no last report read (the main process says it)
	no_session: bool,
}

// What program_start made: the log, as the caller's context.logger, and the report of the last session when it did not
// end cleanly.
Program_Start :: struct {
	logger:     runtime.Logger,
	last_crash: string,   // owned ("": none)
	session:    bool,     // a session began: program_end ends it
	allocator:  runtime.Allocator,
}

program_start :: proc(o: Program_Start_Options, allocator := context.allocator) -> (p: Program_Start) {
	p.allocator = allocator
	log_dir, report_dir: string
	if o.dir != "" {
		log_dir, _ = filepath.join({o.dir, "logs"}, context.temp_allocator)
		report_dir, _ = filepath.join({o.dir, "crashes"}, context.temp_allocator)
	} else {
		log_dir = tk_log.default_dir(o.folder, context.temp_allocator)
		report_dir = crash.default_report_dir(o.folder, context.temp_allocator)
	}
	p.logger = tk_log.install({program = o.name, dir = log_dir, echo = !o.quiet}, allocator)
	context.logger = p.logger
	crash.install({program = o.name, version = o.version, report_dir = report_dir, log_tail = {tk_log.tail, p.logger.data}, settings = o.settings})
	if o.no_session { return }
	crash.begin_session()
	p.session = true
	if path, crashed := crash.last_report(context.temp_allocator); crashed {
		p.last_crash = strings.clone(path, allocator)
		log.warnf("the last session did not end cleanly: %s", path)
	}
	return
}

// The clean end: the session's mark goes (the next start says no crash), then the log is written out and closed. Last,
// on every way out of the program that is not a crash. The caller's context.logger is no longer valid after it.
program_end :: proc(p: ^Program_Start) {
	if p.session { crash.end_session() }
	tk_log.close(p.logger)
	delete(p.last_crash, p.allocator)
	p^ = {}
}

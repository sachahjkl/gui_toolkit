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
//	...
//	host.restart_after_exit(&p)   // "Restart now" after an update: program_end starts the program again
//
// It reads and writes the report folder on the calling thread: call it in main, before the interface's loop.

import "base:runtime"
import "core:log"
import "core:path/filepath"
import "core:strings"
import crash "../crash"
import tk_log "../log"
import process "../process"
import setup "../setup"

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
	// what starts the program again at program_end after restart_after_exit (nil: setup.launch); a test's records it
	launch: proc(exe: string, args: []string) -> bool,
}

// What program_start made: the log, as the caller's context.logger, and the report of the last session when it did not
// end cleanly.
Program_Start :: struct {
	logger:     runtime.Logger,
	last_crash: string,   // owned ("": none)
	session:    bool,     // a session began: program_end ends it
	// the running executable, read at the start: after an update the running file can be <exe>.old, and the new
	// program is at the path the program started from (owned; "": the system could not say)
	executable: string,
	restart:    bool,       // restart_after_exit was asked: program_end starts `executable` again
	restart_args: []string, // owned, each string too
	launch:     proc(exe: string, args: []string) -> bool,
	allocator:  runtime.Allocator,
}

program_start :: proc(o: Program_Start_Options, allocator := context.allocator) -> (p: Program_Start) {
	p.allocator = allocator
	p.executable = strings.clone(process.executable_path(), allocator)
	p.launch = o.launch
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

// The clean end: the session's mark goes (the next start says no crash), then the program starts again when
// restart_after_exit asked it, then the log is written out and closed. Last, on every way out of the program that is
// not a crash, after the program let go of its single instance and after prefs_page.install_launch: a program started
// earlier finds this one still running and hands itself over to it. The caller's context.logger is no longer valid
// after it.
program_end :: proc(p: ^Program_Start) {
	if p.session { crash.end_session() }
	if p.restart {
		launch := p.launch != nil ? p.launch : proc(exe: string, args: []string) -> bool { return setup.launch(exe, args) }
		if p.executable == "" || !launch(p.executable, p.restart_args) { log.errorf("the program does not start again: %q", p.executable) }
	}
	if p.logger.data != nil { tk_log.close(p.logger) }
	delete(p.last_crash, p.allocator)
	delete(p.executable, p.allocator)
	restart_args_free(p)
	p^ = {}
}

// The program starts again once it ended: program_end starts the executable this process started from, with `args`
// (copied; nil: none), once the session ended. The program then ends itself as it does on a quit. Asked again, the last
// args win. "Restart now" after an update calls it (prefs_page's Page_Options.restart and update_badge are the
// program's procedure: it calls this, then quits).
restart_after_exit :: proc(p: ^Program_Start, args: []string = nil) {
	restart_args_free(p)
	p.restart = true
	if len(args) == 0 { return }
	p.restart_args = make([]string, len(args), p.allocator)
	for a, i in args { p.restart_args[i] = strings.clone(a, p.allocator) }
}

@(private = "file")
restart_args_free :: proc(p: ^Program_Start) {
	for a in p.restart_args { delete(a, p.allocator) }
	delete(p.restart_args, p.allocator)
	p.restart_args = nil
}

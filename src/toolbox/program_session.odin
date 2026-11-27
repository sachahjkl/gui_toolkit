package tk_toolbox

// A program driven by its tool (live, shots, bench): on a desktop nobody sees (sway.odin), with its DevTools server on a
// port the system has free, its window reached over gt:cdp, then asked to quit. src/md/infrastructure/program-session.md
// says why each part is so. The desktop is Linux's: elsewhere program_session_start says why it does not run.

import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import cdp "../cdp"

// How long the window has to answer a first time: on a CI runner a debug build drawn by lavapipe, with fontconfig
// making its cache, takes longer than any later step.
PROGRAM_START_WAIT :: 60 * time.Second
// How long a program asked to quit has to end before it is stopped with the desktop.
PROGRAM_END_WAIT :: 8 * time.Second
// What the toolkit's devtools server writes when the port is taken (src/devtools): then what answers there is another
// program's window.
@(private = "file") DEVTOOLS_NOT_LISTENING :: "devtools: cannot listen"

// A file the program reads at its start, written under the session's folder before it starts.
Program_File :: struct {
	path: string,   // under the session's folder ("config/FromentSoftware/Papier/prefs"); its folders are made
	text: string,
}

Program_Options :: struct {
	command: []string,         // the program and its arguments
	env:     []string,         // more "NAME=value" for it, over the desktop's (TOOLKIT_DEVTOOLS is the session's)
	desktop: Sway_Options,     // the desktop: its config, renderer, homes, cache
	files:   []Program_File,   // written once the desktop's folder is made, before the program starts
	log:     string,           // its standard output and error ("": <dir>/<program>.log)
	quit:    []string,         // a command run in the session that asks it to quit (nil: its window closed, Browser.close)
	wait:    time.Duration,    // the bound on the window's first answer (0: PROGRAM_START_WAIT)
	gpu:     bool,             // the machine's own graphics driver (a demo a person watches); false: Vulkan on the CPU (software_vulkan.odin)
}

Program_Session :: struct {
	sway:    Sway,
	dir:     string,           // the session's folder, absolute (the Sway's)
	port:    int,              // the window's DevTools port
	env:     []string,         // the program's whole environment: a command of the session runs with it (owned)
	command: []string,         // (owned)
	quit:    []string,         // (owned)
	log:     string,           // the program's output, a file (owned)
	wait:    time.Duration,
	program: os.Process,
	running: bool,             // the program was started and not yet ended
	started: time.Time,        // just before the program was started
	ended:   int,              // its exit code when it ended by itself, seen by a connect (-1: none seen)
}

// A port of 127.0.0.1 that no program listens on now: the system's choice for a listener on port 0, let go. Never a
// fixed port: a second run could not listen on it, and its tool would drive the first run's window as its own.
free_port :: proc() -> (port: int, ok: bool) {
	l, err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if err != nil { return }
	defer net.close(l)
	at, bound := net.bound_endpoint(l)
	if bound != nil { return }
	return at.port, true
}

// Starts the desktop in `dir` (made anew), writes `o.files`, then starts the program with its DevTools server on a free
// port. It does not connect: a program may show its window later (program_session_connect). why: "" when it runs;
// else what failed (program_session_stop still cleans up).
program_session_start :: proc(s: ^Program_Session, dir: string, o: Program_Options) -> (why: string) {
	if len(o.command) == 0 { return "program_session_start: no command" }
	// (a signal that ends the tool ends the desktop and the program with it; the groups are Linux's, as the desktop)
	when ODIN_OS == .Linux { guard_groups() }
	port, free := free_port()
	if !free { return "no free port on 127.0.0.1 for the DevTools server" }
	s.port = port
	s.wait = o.wait > 0 ? o.wait : PROGRAM_START_WAIT
	if why = sway_start(&s.sway, dir, o.desktop); why != "" { return }
	s.dir = s.sway.dir
	for f in o.files {
		path := fmt.tprintf("%s/%s", s.dir, f.path)
		folder := filepath.dir(path)
		if err := os.make_directory_all(folder); err != nil && err != .Exist { return fmt.tprintf("%s cannot be made", folder) }
		if os.write_entire_file(path, f.text) != nil { return fmt.tprintf("%s cannot be written", path) }
	}
	// (a tool's program draws on lavapipe unless it asks for the GPU: the same picture on every machine, and a test never
	// takes the person's graphics card. No lavapipe: no start, rather than the GPU)
	icd: string
	if !o.gpu {
		found: bool
		if icd, found = software_vulkan_driver(); !found { return "no software Vulkan driver (Mesa's lavapipe, lvp_icd.*.json) on this machine: install Mesa's Vulkan drivers, or set Program_Options.gpu" }
	}
	s.env = clone_strings(program_env(s.sway.env, port, o, icd))
	s.command = clone_strings(o.command)
	s.quit = clone_strings(o.quit)
	name := filepath.stem(o.command[0])
	s.log = strings.clone(o.log != "" ? o.log : fmt.tprintf("%s/%s.log", s.dir, name))
	return program_launch(s)
}

// The program's whole environment (temp memory): the desktop's, its DevTools port, then `o.env`. Unless `o.gpu`, Vulkan's
// drivers are lavapipe's manifest `icd` alone and its implicit layers are off (software_vulkan.odin).
@(private)
program_env :: proc(desktop: []string, port: int, o: Program_Options, icd: string) -> []string {
	extra := make([dynamic]string, context.temp_allocator)
	append(&extra, fmt.tprintf("TOOLKIT_DEVTOOLS=%d", port))
	without: []string
	if !o.gpu {
		append(&extra, fmt.tprintf("%s=%s", SOFTWARE_VULKAN_DRIVER_ENV, icd), SOFTWARE_VULKAN_LAYERS_OFF)
		without = {"VK_ICD_FILENAMES", "VK_ADD_DRIVER_FILES"}
	}
	append(&extra, ..o.env)
	return env_merge(desktop, without, extra[:])
}

// A connection to the window, tried until it answers (at most the session's wait). why: "" when connected; else what
// failed: the program ended, the window did not answer, or the port was taken by another program before this one listened.
program_session_connect :: proc(s: ^Program_Session) -> (c: cdp.Client, why: string) {
	if !s.running { return c, "the program does not run" }
	ok: bool
	state: os.Process_State
	if c, ok, state = cdp.connect_wait(s.port, s.wait, s.program); !ok {
		if state.exited {
			// (its end was collected by the wait: kept here, it is not waited for again at the stop)
			s.running, s.ended = false, state.exit_code
			return c, fmt.tprintf("the program ended (%d) before its window answered (%s)", state.exit_code, s.log)
		}
		return c, fmt.tprintf("the window does not answer on port %d (%s)", s.port, s.log)
	}
	// (a port given back by free_port can be taken again before the program listens: its log then says so, and what
	// answered is another program's window)
	if log, err := os.read_entire_file(s.log, context.temp_allocator); err == nil && strings.contains(string(log), DEVTOOLS_NOT_LISTENING) {
		cdp.close(&c)
		return {}, fmt.tprintf("the program cannot serve DevTools on port %d (%s)", s.port, s.log)
	}
	return c, ""
}

// Asks the program to quit and starts it again in the same desktop and folders: what it kept is read again. The new run's
// output replaces the first's. exit_code: the first run's (-1: it was stopped). Connect again after it.
program_session_restart :: proc(s: ^Program_Session) -> (exit_code: int, why: string) {
	exit_code = session_end(s)
	return exit_code, program_launch(s)
}

// Asks the program to quit (stopped with the desktop after PROGRAM_END_WAIT), then stops the desktop and frees the
// session. exit_code: the program's (-1: it was stopped, or it did not run).
program_session_stop :: proc(s: ^Program_Session) -> (exit_code: int) {
	exit_code = session_end(s)
	sway_stop(&s.sway)
	free_strings(s.env)
	free_strings(s.command)
	free_strings(s.quit)
	delete(s.log)
	s^ = {}
	return
}

@(private = "file")
program_launch :: proc(s: ^Program_Session) -> (why: string) {
	s.started = time.now()
	p: os.Process
	if p, why = sway_program(&s.sway, s.command, s.env, s.log); why != "" { return }
	s.program, s.running, s.ended = p, true, -1
	return ""
}

// The program asked to quit, its way, and waited for: its exit code, or -1.
@(private = "file")
session_end :: proc(s: ^Program_Session) -> (exit_code: int) {
	exit_code = -1
	if !s.running { return s.program.pid != 0 ? s.ended : -1 }
	s.running = false
	if len(s.quit) > 0 {
		_, _ = capture(s.quit, {env = s.env})
	} else if c, ok := cdp.connect(s.port); ok {
		c.quiet = true
		_ = cdp.send(&c, "Browser.close")
		cdp.close(&c)
	}
	// (one that does not end is stopped with the desktop)
	if state, ended := sway_wait(&s.sway, s.program, PROGRAM_END_WAIT); ended && state.exited { exit_code = state.exit_code }
	s.program = {}
	return
}

@(private = "file")
clone_strings :: proc(list: []string) -> []string {
	if len(list) == 0 { return nil }
	out := make([]string, len(list))
	for e, i in list { out[i] = strings.clone(e) }
	return out
}

@(private = "file")
free_strings :: proc(list: []string) {
	for e in list { delete(e) }
	delete(list)
}

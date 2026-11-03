// The whole test suite: every package below, each its own process, side by side. On Windows it all runs on a desktop of its own (desktop_windows.odin):
// what a test opens can take nobody's focus, mouse or keyboard.
//   odin run tools/run_tests                                every test of this system
//   odin run tools/run_tests -- text keyboard               those packages
//   build/run_tests -backend:wgpu -group:ci1    one group of the WebGPU backend (ci1..ci4 are all of them, sample a pull request's)
//   odin run tools/run_tests -- -list                       the names, and the groups
// Other flags: -jobs:N, -timeout:seconds (of one package's run), -define:NAME=value (to every package). Needs what the CI's steps build first: the native
// libraries (tools/tk build_text, build_a11y), the emoji font (tools/tk fetch_emoji -unicode), wgpu-native and DXC (tools/tk fetch_wgpu). A log of each step
// is left in build/test_logs/.
package run_tests

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// What a step does.
Kind :: enum {
	Test,    // builds a test program, runs it
	Build,   // builds a program (it must compile, -vet)
	Check,   // odin check for another system
}

Oses :: bit_set[Os]
Os :: enum { Windows, Linux }
WINDOWS_ONLY :: Oses{.Windows}
LINUX_ONLY :: Oses{.Linux}
EVERYWHERE :: Oses{.Windows, .Linux}

// The libraries a step links, which a CI step builds before it.
Need :: enum { None, Text_Lib, A11y_Lib, Emoji }

// A group of the WebGPU backend: about the same time each, on a runner.
Wgpu_Group :: enum { None, Ci1, Ci2, Ci3, Ci4 }

Step :: struct {
	name:    string,
	path:    string,            // the package ("": tests/<name>)
	kind:    Kind,
	oses:    Oses,              // ({}: every system this runner is told of: WINDOWS_ONLY is the usual one: most pixel tests have only run on WARP)
	one:     bool,              // one test at a time (-define:ODIN_TEST_THREADS=1): it drives the ui package's global state
	defines: []string,
	need:    Need,
	wgpu:    Wgpu_Group,        // on the WebGPU backend too, in this group
	sample:  bool,              // ... and in a pull request's quick set
	target:  string,            // Check: the system
	text:    bool,              // needs fonts: on Linux that is the native text backend (no system text stack is linked there)
}

STEPS := []Step{
	// no interface, no device
	{name = "affine", wgpu = .Ci1},
	{name = "arena", path = "arena"},
	{name = "base", path = "base"},
	{name = "config", path = "config", oses = EVERYWHERE},
	{name = "dbus", path = "dbus", oses = LINUX_ONLY},
	{name = "instance_pkg", path = "instance", oses = LINUX_ONLY},
	{name = "changelog", oses = EVERYWHERE},
	{name = "clipboard", oses = EVERYWHERE},
	{name = "clipboard_station"},
	{name = "clock", oses = EVERYWHERE},
	{name = "dialogs"},
	{name = "dragdrop", oses = EVERYWHERE},
	{name = "flate", oses = EVERYWHERE},
	{name = "frame_gate"},
	{name = "frame_slots", oses = EVERYWHERE},
	{name = "fsx"},
	{name = "i18n", oses = EVERYWHERE},
	{name = "instance"},
	{name = "key_repeat", oses = EVERYWHERE},
	{name = "pacing", oses = EVERYWHERE},
	{name = "placement"},
	{name = "size_move"},
	{name = "testkit"},
	{name = "tk"},
	{name = "autoscroll", oses = EVERYWHERE},
	// the interface, with no window
	{name = "post", one = true},
	{name = "panes", one = true},
	{name = "keyboard", one = true, wgpu = .Ci2},
	{name = "status", one = true, wgpu = .Ci1},
	{name = "states", one = true, wgpu = .Ci1},
	{name = "chrome", wgpu = .Ci1},
	{name = "ui_robust", one = true, wgpu = .Ci1},
	{name = "a11y", one = true},
	{name = "a11y_uia", path = "tests/a11y", one = true, defines = {"A11Y_ACCESSKIT=true"}, need = .A11y_Lib},
	{name = "devtools"},
	// the interface with real frames and input: testkit/session
	{name = "session", one = true, wgpu = .Ci1, oses = EVERYWHERE, text = true},
	{name = "scenarios", one = true, wgpu = .Ci1, sample = true, oses = EVERYWHERE, text = true},
	{name = "examples", one = true, oses = EVERYWHERE, text = true},
	// (each frame also drawn whole on the side: a partial frame must match it byte for byte; a difference ends the program with 1)
	{name = "examples_damage", path = "tests/examples", one = true, defines = {"TOOLKIT_DAMAGE_CHECK=true", "ODIN_TEST_NAMES=examples_test.whatsnew_pages_look_like_their_images,examples_test.whatsnew_lazy_column_after_a_wheel_burst,examples_test.fidget_controls_by_the_mouse,examples_test.fidget_editor_undo_and_redo"}},
	// real windows, hidden, on the runner's own desktop
	{name = "window"},
	{name = "cursors", one = true},
	{name = "tray", one = true},
	// pixels
	{name = "lifecycle"},
	{name = "lifecycle_faults", path = "tests/lifecycle", defines = {"TOOLKIT_RENDER_FAULTS=true"}},
	{name = "canvas"},
	{name = "layers", wgpu = .Ci4, sample = true},
	{name = "planes", wgpu = .Ci2},
	{name = "effects", wgpu = .Ci2, sample = true},
	{name = "blend_space", wgpu = .Ci3},
	{name = "gradients", wgpu = .Ci2},
	{name = "shadows", wgpu = .Ci4},
	{name = "retained", wgpu = .Ci4},
	{name = "masks", wgpu = .Ci3},
	{name = "gpufx", wgpu = .Ci1},
	{name = "shaders", wgpu = .Ci1},
	{name = "appshaders", wgpu = .Ci3},
	{name = "video", wgpu = .Ci2, sample = true},
	{name = "textures", wgpu = .Ci4},
	{name = "render_pkg", path = "render"},
	// text
	{name = "text", wgpu = .Ci1},
	{name = "slug", wgpu = .Ci1, sample = true},
	{name = "colr", need = .Emoji, wgpu = .Ci1},
	{name = "color_glyphs", wgpu = .Ci3},
	{name = "color_glyphs_builtin", path = "tests/color_glyphs", defines = {"COLR_ENGINE=builtin"}},
	{name = "color_native", oses = LINUX_ONLY, text = true},
	{name = "text_backends"},
	{name = "text_backends_native", path = "tests/text_backends", defines = {"FONT_BACKEND=native"}, need = .Text_Lib},
	// what must keep compiling
	{name = "uia_probe", path = "tools/uia_probe", kind = .Build},
	{name = "font_on_linux", path = "font", kind = .Check, target = "linux_amd64"},
	{name = "flate_on_linux", path = "flate", kind = .Check, target = "linux_amd64"},
	{name = "font_on_darwin", path = "font", kind = .Check, target = "darwin_arm64"},
	{name = "flate_on_darwin", path = "flate", kind = .Check, target = "darwin_arm64"},
}

// What ends a package that does not end, by default: a hang is a failure that names itself.
RUN_LIMIT_SECONDS :: 300
// How often a run that may not end is looked at.
POLL_INTERVAL :: 20 * time.Millisecond
// Of a failure, the last lines of its log are shown.
FAILURE_LINES :: 40
// Side by side, at most, however many processors there are.
MAX_JOBS :: 12
// With the WebGPU backend on WARP, one device at a time: d3d10warp.dll crashes now and then with several at once.
WGPU_JOBS :: 1
BUILD_DIR :: "build/tests"
LOG_DIR :: "build/test_logs"
THIS_OS :: Os.Windows when ODIN_OS == .Windows else Os.Linux
EXE_SUFFIX :: ".exe" when ODIN_OS == .Windows else ""

Options :: struct {
	only:    [dynamic]string,
	backend: string,
	group:   string,
	defines: [dynamic]string,
	jobs:    int,
	limit:   int,
	list:    bool,
}

Result :: struct {
	step:    ^Step,
	ok:      bool,
	skipped: string,      // why it did not run
	why:     string,
	seconds: f64,
}

Pool :: struct {
	steps:   []^Step,
	results: []Result,
	next:    int,
	o:       ^Options,
	print:   sync.Mutex,
}

main :: proc() {
	code := 0
	if on_own_desktop(&code) { os.exit(code) }
	o := Options{limit = RUN_LIMIT_SECONDS}
	for a in os.args[1:] {
		switch {
		case a == "-list": o.list = true
		case strings.has_prefix(a, "-backend:"): o.backend = a[len("-backend:"):]
		case strings.has_prefix(a, "-group:"): o.group = a[len("-group:"):]
		case strings.has_prefix(a, "-define:"): append(&o.defines, a[len("-define:"):])
		case strings.has_prefix(a, "-jobs:"): o.jobs, _ = strconv.parse_int(a[len("-jobs:"):])
		case strings.has_prefix(a, "-timeout:"): o.limit, _ = strconv.parse_int(a[len("-timeout:"):])
		case strings.has_prefix(a, "-"):
			fmt.eprintfln("unknown flag %s", a)
			os.exit(2)
		case: append(&o.only, a)
		}
	}
	chosen := choose(&o)
	if o.list {
		for s in chosen { fmt.printfln("%-24s %v%s", s.name, s.kind, s.wgpu != .None ? fmt.tprintf("  wgpu %v", s.wgpu) : "") }
		return
	}
	if len(chosen) == 0 { fmt.eprintln("nothing to run"); os.exit(2) }
	_ = os.make_directory_all(BUILD_DIR)
	_ = os.make_directory_all(LOG_DIR)
	pool := Pool{steps = chosen, results = make([]Result, len(chosen)), o = &o}
	jobs := o.jobs > 0 ? o.jobs : (o.backend == "wgpu" ? WGPU_JOBS : clamp(os.get_processor_core_count() * 3 / 4, 1, MAX_JOBS))
	began := time.tick_now()
	workers := make([]^thread.Thread, jobs)
	for &w in workers { w = thread.create_and_start_with_poly_data(&pool, worker) }
	for w in workers { thread.join(w) }
	failed, skipped := 0, 0
	slice.sort_by(pool.results, proc(a, b: Result) -> bool { return a.seconds > b.seconds })
	fmt.println("\nthe slowest:")
	for r, i in pool.results { if i < 8 && r.skipped == "" { fmt.printfln("  %6s s  %s", fmt.tprintf("%.1f", r.seconds), r.step.name) } }
	for r in pool.results {
		if r.skipped != "" { skipped += 1; continue }
		if !r.ok { failed += 1; fmt.printfln("FAIL %s: %s", r.step.name, r.why) }
	}
	fmt.printfln("%d steps, %d failed, %d skipped, in %.0f s", len(pool.results), failed, skipped, time.duration_seconds(time.tick_since(began)))
	os.exit(failed > 0 ? 1 : 0)
}

// The steps asked for, on this system and this backend.
choose :: proc(o: ^Options) -> []^Step {
	out: [dynamic]^Step
	for &s in STEPS {
		if s.path == "" { s.path = fmt.aprintf("tests/%s", s.name) }
		oses := s.oses == {} ? WINDOWS_ONLY : s.oses
		if s.kind != .Test && THIS_OS == .Linux { continue }   // (what compiles for Linux is the Linux job's own check: tools/linux_ci.sh)
		if THIS_OS not_in oses { continue }
		if len(o.only) > 0 && !slice.contains(o.only[:], s.name) { continue }
		if o.backend == "wgpu" {
			if s.wgpu == .None && len(o.only) == 0 { continue }
			if s.kind != .Test { continue }
			switch o.group {
			case "":
			case "sample": if !s.sample { continue }
			case: if !strings.equal_fold(fmt.tprintf("%v", s.wgpu), o.group) { continue }
			}
		}
		append(&out, &s)
	}
	return out[:]
}

worker :: proc(p: ^Pool) {
	for {
		i := sync.atomic_add(&p.next, 1)
		if i >= len(p.steps) { return }
		s := p.steps[i]
		r := run_step(s, p.o)
		r.why = strings.clone(r.why)   // (the rest is this thread's temporary memory)
		p.results[i] = r
		sync.lock(&p.print)
		switch {
		case r.skipped != "": fmt.printfln("SKIP %-24s %s", s.name, r.skipped)
		case r.ok: fmt.printfln("PASS %-24s %6s s", s.name, fmt.tprintf("%.1f", r.seconds))
		case:
			fmt.printfln("FAIL %-24s %6s s  %s", s.name, fmt.tprintf("%.1f", r.seconds), r.why)
			print_tail(log_path(s))
		}
		sync.unlock(&p.print)
		free_all(context.temp_allocator)
	}
}

log_path :: proc(s: ^Step) -> string { return fmt.tprintf("%s/%s.log", LOG_DIR, s.name) }

missing_need :: proc(n: Need) -> string {
	file: string
	switch n {
	case .None: return ""
	case .Text_Lib: file = ODIN_OS == .Windows ? "build/text/gt_text.lib" : "build/text/libgt_text.a"
	case .A11y_Lib: file = "build/a11y/gt_a11y.lib"
	case .Emoji: file = "build/emoji/NotoColorEmoji-COLRv1.ttf"
	}
	return os.exists(file) ? "" : fmt.tprintf("%s is not there: build it first", file)
}

run_step :: proc(s: ^Step, o: ^Options) -> Result {
	began := time.tick_now()
	r := Result{step = s}
	need := s.need
	if s.text && ODIN_OS == .Linux { need = .Text_Lib }
	if why := missing_need(need); why != "" {
		r.why = why
	} else {
		carry_out(s, o, &r)
	}
	r.seconds = time.duration_seconds(time.tick_since(began))
	return r
}

carry_out :: proc(s: ^Step, o: ^Options, r: ^Result) {
	log_file, err := os.open(log_path(s), os.O_WRONLY + os.O_CREATE + os.O_TRUNC + os.O_INHERITABLE)
	if err != nil { r.why = "cannot write its log"; return }
	defer os.close(log_file)

	cmd := make([dynamic]string, context.temp_allocator)
	suffix := o.backend != "" ? fmt.tprintf("_%s", o.backend) : ""
	// (the WebGPU programs next to DXC's DLLs, which tools/tk fetch_wgpu leaves in build/: without them wgpu falls back to FXC)
	exe := fmt.tprintf("%s/%s%s%s", o.backend == "wgpu" ? "build" : BUILD_DIR, s.name, suffix, EXE_SUFFIX)
	here, _ := os.get_working_directory(context.temp_allocator)
	exe_path := fmt.tprintf("%s/%s", here, exe)
	switch s.kind {
	case .Test:
		append(&cmd, "odin", "build", s.path, "-build-mode:test", "-vet", "-debug", fmt.tprintf("-out:%s", exe))
		append(&cmd, "-define:ODIN_TEST_FANCY=false", "-define:ODIN_TEST_LOG_STATE_CHANGES=true")
		if s.one || o.backend == "wgpu" { append(&cmd, "-define:ODIN_TEST_THREADS=1") }
		if o.backend != "" { append(&cmd, fmt.tprintf("-define:TOOLKIT_RENDER=%s", o.backend)) }
		when ODIN_OS == .Linux {
			if !s.one { append(&cmd, "-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true") }
			// (wgpu-native is the other Rust library in them: its few unmangled symbols of Rust's standard library are the same code)
			if s.text { append(&cmd, "-define:FONT_BACKEND=native", "-extra-linker-flags:-Wl,--allow-multiple-definition") }
		}
	case .Build:
		append(&cmd, "odin", "build", s.path, "-vet", fmt.tprintf("-out:%s", exe))
	case .Check:
		append(&cmd, "odin", "check", s.path, "-no-entry-point", "-vet", fmt.tprintf("-target:%s", s.target))
	}
	for d in s.defines { append(&cmd, fmt.tprintf("-define:%s", d)) }
	for d in o.defines { append(&cmd, fmt.tprintf("-define:%s", d)) }
	if !run_to_log(cmd[:], log_file, 0, r) {
		if r.why == "" { r.why = "it does not compile" }
		return
	}
	if s.kind == .Test {
		if !run_to_log({exe_path}, log_file, o.limit, r) {
			if r.why == "" { r.why = "a test failed" }
			return
		}
		text, _ := os.read_entire_file(log_path(s), context.temp_allocator)
		if !strings.contains(string(text), "successful") { r.why = "it ended without saying that its tests passed"; return }
	}
	r.ok = true
}

// Runs a command, its output in the log. `limit`: seconds, 0 none. False: it failed; `r.why` when it says more than its exit code does.
run_to_log :: proc(cmd: []string, log: ^os.File, limit: int, r: ^Result) -> bool {
	p, err := os.process_start({command = cmd, stdout = log, stderr = log})
	if err != nil { r.why = fmt.tprintf("%s cannot start: %v", cmd[0], err); return false }
	began := time.tick_now()
	for {
		st, werr := os.process_wait(p, POLL_INTERVAL)
		if st.exited {
			if st.exit_code != 0 {
				// (0xC0000005 an access violation, 0xC000001D an assertion's trap that nothing caught, 0xC00000FD a stack overflow)
				r.why = fmt.tprintf("exit code 0x%8X", u32(st.exit_code))
				return false
			}
			return true
		}
		if werr != nil && werr != .Timeout { r.why = fmt.tprintf("waiting for it: %v", werr); return false }
		if limit > 0 && time.duration_seconds(time.tick_since(began)) > f64(limit) {
			_ = os.process_kill(p)
			_, _ = os.process_wait(p)
			r.why = fmt.tprintf("no end after %d s", limit)
			return false
		}
	}
}

// The end of a log: what failed, and for a hang which test it was in (ODIN_TEST_LOG_STATE_CHANGES).
print_tail :: proc(path: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }
	lines := strings.split_lines(string(data), context.temp_allocator)
	first := max(len(lines) - FAILURE_LINES, 0)
	for l in lines[first:] { fmt.println(l) }
}

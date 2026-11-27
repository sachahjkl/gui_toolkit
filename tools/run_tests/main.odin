// The whole test suite: every package below, each its own process, side by side. On Windows it all runs on a desktop of its own (desktop_windows.odin):
// what a test opens can take nobody's focus, mouse or keyboard.
//   odin run tools/run_tests                                every test of this system
//   odin run tools/run_tests -- text keyboard               those packages
//   odin run tools/run_tests -- -backend:wgpu -group:ci1    one group of the WebGPU backend (ci1..ci11 are all of them, sample a pull request's)
//   odin run tools/run_tests -- -list                       the names, and the groups
//   odin run tools/run_tests -- -check:windows_amd64        every package of that system checked (odin check, its defines), not run:
//                                                           Windows' code compiled from Linux (toolbox.check_env)
// Other flags: -jobs:N, -timeout:seconds (of one package's run), -define:NAME=value (to every package). (PowerShell 7 splits a `-name:value` typed after
// `--` into `-name:` and `value`: toolbox.args_joined joins them again.) Needs what the CI's steps build first: the native
// library (tools/tk build_native), the emoji font (tools/tk fetch_emoji -unicode), wgpu-native and DXC (tools/tk fetch_wgpu). A log of each step
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
import "../../src/ascii"
import toolbox "../../src/toolbox"

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
Need :: enum { None, Native_Lib, Emoji }   // (Native_Lib: build/native, tools/tk build_native)

// A group of the WebGPU backend, on a runner of its own: under 4 minutes of WARP each (a package longer than that is
// sharded: Step.shards), so that a run that takes twice as long on a slow runner stays under a package's 600 s.
Wgpu_Group :: enum { None, Ci1, Ci2, Ci3, Ci4, Ci5, Ci6, Ci7, Ci8, Ci9, Ci10, Ci11 }

Step :: struct {
	name:    string,
	path:    string,            // the package ("": tests/<name>)
	kind:    Kind,
	oses:    Oses,              // ({}: every system this runner is told of: WINDOWS_ONLY is the usual one: most pixel tests have only run on WARP)
	one:     bool,              // one test at a time (-define:ODIN_TEST_THREADS=1): it drives the ui package's global state
	defines: []string,
	need:    Need,
	wgpu:    Wgpu_Group,        // on the WebGPU backend too, in this group
	// on the WebGPU backend, its tests dealt by name to one step per group (<name>_1, <name>_2...: shards_of); elsewhere
	// it runs whole. A new test lands in a shard with no change here
	shards:  []Wgpu_Group,
	sample:  bool,              // ... and in a pull request's quick set
	target:  string,            // Check: the system
	text:    bool,              // needs fonts: on Linux that is the native text backend (no system text stack is linked there)
}

STEPS := []Step{
	// no interface, no device
	{name = "affine", wgpu = .Ci1},
	{name = "path_dash", wgpu = .Ci1},
	{name = "arena", path = "src/arena"},
	{name = "ascii", path = "src/ascii", oses = EVERYWHERE},
	{name = "utf8", path = "src/utf8", oses = EVERYWHERE},
	{name = "fuzzy", oses = EVERYWHERE},
	{name = "crashsite", oses = EVERYWHERE},   // (a test's crash names its place on Linux: a child faults)
	{name = "timefmt", path = "src/timefmt", oses = EVERYWHERE},
	{name = "undo", path = "src/undo", oses = EVERYWHERE},
	{name = "flowgraph", path = "src/flowgraph", oses = EVERYWHERE},
	{name = "tasks", path = "src/tasks", oses = EVERYWHERE},
	{name = "base", path = "src/base", oses = EVERYWHERE},
	{name = "cdp", path = "src/cdp", oses = EVERYWHERE},
	{name = "site", path = "src/site", oses = EVERYWHERE},
	{name = "config", path = "src/config", oses = EVERYWHERE},
	{name = "dbus", path = "src/dbus", oses = LINUX_ONLY},
	{name = "desktop_pkg", path = "src/desktop", oses = EVERYWHERE},
	{name = "setup_pkg", path = "src/setup", oses = EVERYWHERE},
	{name = "crash_bar", path = "src/crash_bar", oses = EVERYWHERE},
	{name = "instance_pkg", path = "src/instance", oses = LINUX_ONLY},
	{name = "paint", path = "src/paint", oses = EVERYWHERE},
	{name = "png", path = "src/png", oses = EVERYWHERE},
	{name = "qr", path = "src/qr", oses = EVERYWHERE},
	{name = "ink", path = "src/ink", oses = EVERYWHERE},
	{name = "marks", path = "src/marks", oses = EVERYWHERE},
	// (one at a time: several of its tests start children, and os.process_start is not safe from two threads at once,
	// as the plugins' starts know; each_signal_is_its_own twice stopped on an illegal instruction beside another start)
	{name = "process", path = "src/process", oses = EVERYWHERE, one = true},
	{name = "rpc_pkg", path = "src/rpc", oses = EVERYWHERE},   // (framing, messages, the tail: pure)
	{name = "http", path = "src/http", oses = EVERYWHERE},
	{name = "secrets", path = "src/secrets", oses = EVERYWHERE},   // (Linux: the round trip only where a Secret Service answers)
	{name = "toolbox", path = "src/toolbox", oses = EVERYWHERE},
	{name = "release", path = "src/release", oses = EVERYWHERE},
	{name = "update", path = "src/update", oses = EVERYWHERE},
	{name = "licence", path = "src/licence", oses = EVERYWHERE},
	{name = "signing", path = "src/signing", oses = EVERYWHERE},
	{name = "changelog", oses = EVERYWHERE},
	{name = "clipboard", oses = EVERYWHERE},
	{name = "platform_pkg", path = "src/platform", oses = EVERYWHERE},   // (its Linux clipboard pipes; Windows: the file dialog's apartment)
	{name = "prefs_page_pkg", path = "src/prefs_page", oses = EVERYWHERE},   // (what its private procedures own: the changelog's texts freed once)
	{name = "clipboard_station"},
	{name = "clock", oses = EVERYWHERE},
	{name = "dialogs"},
	{name = "print", oses = EVERYWHERE},   // (the pure parts: the layout and the PDF; no dialog opens)
	{name = "dragdrop", oses = EVERYWHERE},
	{name = "flate", oses = EVERYWHERE},
	{name = "flate_pkg", path = "src/flate", oses = EVERYWHERE},
	{name = "archive", oses = EVERYWHERE},
	{name = "syntax", path = "src/syntax", oses = EVERYWHERE},
	// (gt:js: the engine's own unit tests, then two runtimes embedded as a program embeds one)
	{name = "js_pkg", path = "src/js", oses = EVERYWHERE},
	{name = "js_regexp", path = "src/js/regexp", oses = EVERYWHERE},
	{name = "js", oses = EVERYWHERE},
	// (gt:plugins: an endless handler chosen in a headless window's palette, Stop, the states; one window at a time)
	{name = "plugins", one = true, oses = EVERYWHERE, text = true},
	{name = "term", one = true, oses = EVERYWHERE, text = true},   // (the terminal widget on a screen of its own; its rows drawn in a session)
	{name = "remote", oses = EVERYWHERE},
	{name = "deferred", oses = EVERYWHERE},
	{name = "frame_gate"},
	{name = "frame_slots", oses = EVERYWHERE},
	{name = "fsx", oses = EVERYWHERE},
	{name = "store", oses = EVERYWHERE},
	{name = "json", oses = EVERYWHERE},
	{name = "file_request", oses = EVERYWHERE},
	{name = "crash", oses = EVERYWHERE},   // (the crashing process is the test program itself, started again)
	{name = "log", oses = EVERYWHERE},
	{name = "notices", oses = EVERYWHERE},
	{name = "capture", oses = EVERYWHERE},
	{name = "gif", oses = EVERYWHERE},
	{name = "exif", oses = EVERYWHERE},
	// (text = true: watermark_text's test draws the embedded face; WebP: the native library's part webp, built in)
	{name = "image", text = true, need = .Native_Lib, defines = {"IMAGE_WEBP=true", "IMAGE_JPEG=true"}, oses = EVERYWHERE},
	{name = "pdf", need = .Native_Lib, defines = {"GT_PDF=true"}, oses = EVERYWHERE},   // (the native library's part pdf, built in)
	{name = "filesearch", need = .Native_Lib, one = true, text = true, defines = {"GT_FILESEARCH=true"}, oses = EVERYWHERE},   // (the native library's part filesearch, fff-search)
	{name = "h264", oses = EVERYWHERE},
	{name = "mux", oses = EVERYWHERE},
	{name = "shortcuts", oses = EVERYWHERE},
	{name = "ocr", oses = EVERYWHERE},   // (the engine's test passes with a log line where none is installed)
	{name = "globals", oses = EVERYWHERE},
	{name = "turn", oses = EVERYWHERE},
	{name = "angles", oses = EVERYWHERE},
	{name = "unicode_case", oses = EVERYWHERE},
	// (the process restricts itself for good, as an elevated program or a machine copy is: its package alone)
	{name = "restricted", oses = EVERYWHERE, one = true},
	{name = "i18n", oses = EVERYWHERE, one = true},   // (the language in use is one for the process)
	{name = "ime", oses = EVERYWHERE},
	{name = "instance", oses = EVERYWHERE},   // (the launch message's encoding is every system's)
	// (gt:process's children: this test program started again; one at a time: a test counts the process's open handles,
	// and the pipes of another test would be among them)
	{name = "process_start", oses = EVERYWHERE, one = true},
	// (gt:process's trees and gt:rpc's peer: the test program started again as the tree's child, the peer's child)
	{name = "process_tree", oses = EVERYWHERE},
	{name = "rpc", oses = EVERYWHERE},
	{name = "hotkey", oses = EVERYWHERE},
	{name = "overlay", oses = EVERYWHERE},   // (the pure parts: no window opens)
	{name = "notify", one = true, oses = EVERYWHERE},   // (Linux: a bus and a notification server of its own)
	{name = "taskbar", one = true, oses = EVERYWHERE},   // (Linux: a bus and a dock of its own; Windows: a hidden window's button)
	{name = "winrt", path = "src/winrt", oses = EVERYWHERE},
	{name = "shell_thumbnail", path = "src/shell_thumbnail", oses = EVERYWHERE},   // (Windows: the COM path the shell takes, in this process)
	{name = "console_launcher", path = "src/console_launcher", oses = EVERYWHERE},
	{name = "key_repeat", oses = EVERYWHERE},
	{name = "pacing", oses = EVERYWHERE},
	{name = "sleep", oses = EVERYWHERE},
	{name = "netif", oses = EVERYWHERE},
	{name = "sigpipe", oses = EVERYWHERE},
	{name = "placement"},
	{name = "placement_text", oses = EVERYWHERE},
	{name = "render_trace", oses = EVERYWHERE},
	{name = "preview", one = true, oses = EVERYWHERE, text = true},
	{name = "markdown", one = true, oses = EVERYWHERE, text = true},
	{name = "svg", text = true, oses = EVERYWHERE},
	{name = "mermaid", one = true, need = .Native_Lib, text = true, oses = EVERYWHERE},   // (Linux: tk ci builds the library first)
	{name = "size_move"},
	{name = "testkit"},
	{name = "tk"},
	{name = "autoscroll", oses = EVERYWHERE},
	// the interface, with no window
	{name = "post", one = true, oses = EVERYWHERE, text = true},
	{name = "drag_autoscroll", one = true, oses = EVERYWHERE, text = true},
	{name = "text_selection", one = true, oses = EVERYWHERE, text = true},
	{name = "machines", one = true},
	{name = "panes", one = true},
	{name = "docking", one = true},
	{name = "views", one = true, oses = EVERYWHERE, text = true},
	// (a process of its own: in views', its session left Windows' WARP so that a later test crashed or hung)
	{name = "view_size", one = true, oses = EVERYWHERE, text = true},
	{name = "keyboard", one = true, wgpu = .Ci7},
	{name = "commands", one = true, oses = EVERYWHERE, text = true},
	{name = "keymap", one = true, oses = EVERYWHERE, text = true},   // (the person's keys: one language for the process)
	{name = "status", one = true, wgpu = .Ci1},
	{name = "status_line", one = true, oses = EVERYWHERE, text = true},   // (ui.Status_Line on the session's clock)
	{name = "states", one = true, wgpu = .Ci1, oses = EVERYWHERE, text = true},
	{name = "stepper", one = true, oses = EVERYWHERE, text = true},
	{name = "debug", one = true, oses = EVERYWHERE, text = true},   // (gt:debug: the debug panel, the dense drag field)
	{name = "chrome", wgpu = .Ci1},
	{name = "ui_robust", one = true, wgpu = .Ci1},
	{name = "a11y", one = true},
	{name = "a11y_uia", path = "tests/a11y", one = true, defines = {"A11Y_ACCESSKIT=true"}, need = .Native_Lib},
	{name = "devtools"},
	{name = "devtools_unit", path = "src/devtools"},
	// the interface with real frames and input: testkit/session
	{name = "session", one = true, wgpu = .Ci1, oses = EVERYWHERE, text = true},
	{name = "pictures", one = true, oses = EVERYWHERE, text = true},
	// (the check of what waits on the system in a frame: compiled in, as a program's tests have it)
	{name = "session_blocking", path = "tests/session", one = true, oses = EVERYWHERE, text = true, defines = {"TOOLKIT_BLOCKING_CHECK=true", "ODIN_TEST_NAMES=session_test.a_frame_that_waits_on_the_system_is_counted"}},
	{name = "data_views", one = true, oses = EVERYWHERE, text = true},
	{name = "file_browser", one = true, oses = EVERYWHERE, text = true},
	{name = "path_bar", one = true, oses = EVERYWHERE, text = true},
	{name = "tree", one = true, oses = EVERYWHERE, text = true},
	{name = "mark_editor", one = true, oses = EVERYWHERE, text = true},
	{name = "font_picker", one = true, oses = EVERYWHERE, text = true},
	{name = "diff", one = true, oses = EVERYWHERE, text = true},
	{name = "prefs_page", one = true, oses = EVERYWHERE, text = true},
	// (no WebGPU group: over WARP its motion takes five minutes, past a group's time; Linux runs it on WebGPU)
	{name = "licence_card", one = true, oses = EVERYWHERE, text = true},
	{name = "setup", one = true, oses = EVERYWHERE, text = true},
	// (on WARP 360 s, past a group's 4 minutes: two shards)
	{name = "scenarios", one = true, shards = {.Ci2, .Ci3}, sample = true, oses = EVERYWHERE, text = true},
	// (ui.node_graph and tooltip_near: a process of their own, each frame of a graph is half a second on WARP)
	{name = "node_graph", one = true, wgpu = .Ci9, sample = true, oses = EVERYWHERE, text = true},
	{name = "cli", oses = EVERYWHERE},
	{name = "prewarm", oses = EVERYWHERE, wgpu = .Ci5},   // (Linux's renderer is wgpu: it runs there as it is)
	{name = "edged", one = true, wgpu = .Ci1, oses = EVERYWHERE, text = true},   // (the edged finish, Kernel, the dashboard's pieces: a process of their own)
	{name = "theme_look", one = true, wgpu = .Ci1, oses = EVERYWHERE, text = true},   // (a theme's look beside its colours: its values reach the drawing)
	{name = "system_title", one = true, wgpu = .Ci1, oses = EVERYWHERE, text = true},   // (the system's title bar: a process of its own, the scenarios' is full)
	{name = "resize_grip", one = true, wgpu = .Ci1, oses = EVERYWHERE, text = true},   // (a dialog's grips and corner control: a process of its own, the scenarios' is full)
	// (ui.tween and ui.swap: a process of its own: the scenarios took 400 s of their 420 with them)
	{name = "transitions", one = true, wgpu = .Ci11, oses = EVERYWHERE, text = true},
	// (automatic partial redraw: every partial frame drawn whole on the side too, and compared)
	{name = "partial_redraw", one = true, wgpu = .Ci6, oses = EVERYWHERE, text = true},
	// (what covers a change: a process of its own; with the scenes above it passed 420 s on WARP, its six scenes 308 s:
	// two shards. Its quiet buttons in every finish are a process of their own too, each on its runner: 280 s and 212 s)
	{name = "partial_redraw_layers", one = true, shards = {.Ci4, .Ci5}, oses = EVERYWHERE, text = true, defines = {"ODIN_TEST_NAMES=partial_redraw_layers_test.a_change_under_a_dialog_redraws_the_dialog_over_it,partial_redraw_layers_test.text_that_changes_under_an_internal_window_stays_under_it,partial_redraw_layers_test.a_table_with_code_in_striped_rows_is_exact_and_opaque,partial_redraw_layers_test.framed_panels_and_a_dialog_over_them_stay_opaque,partial_redraw_layers_test.an_unseen_dialog_redraws_nothing,partial_redraw_layers_test.the_palette_redraws_nothing_before_it_shows"}},
	{name = "partial_redraw_buttons", path = "tests/partial_redraw_layers", one = true, wgpu = .Ci8, oses = EVERYWHERE, text = true, defines = {"ODIN_TEST_NAMES=partial_redraw_layers_test.quiet_buttons_above_framed_panels_are_exact_and_opaque"}},
	{name = "partial_redraw_buttons_half", path = "tests/partial_redraw_layers", one = true, wgpu = .Ci7, oses = EVERYWHERE, text = true, defines = {"ODIN_TEST_NAMES=partial_redraw_layers_test.quiet_buttons_above_framed_panels_are_exact_and_opaque_in_half_floats"}},
	{name = "examples", one = true, oses = EVERYWHERE, text = true},
	// (each frame also drawn whole on the side: a partial frame must match it byte for byte; a difference ends the program with 1)
	{name = "examples_damage", path = "tests/examples", one = true, defines = {"TOOLKIT_DAMAGE_CHECK=true", "ODIN_TEST_NAMES=examples_test.whatsnew_pages_look_like_their_images,examples_test.whatsnew_lazy_column_after_a_wheel_burst,examples_test.fidget_controls_by_the_mouse,examples_test.fidget_editor_undo_and_redo"}},
	// real windows, hidden, on the runner's own desktop
	{name = "window"},
	{name = "host", one = true, oses = EVERYWHERE, text = true},   // (Linux: its windows without a screen; those of the system are host_test_windows.odin's)
	{name = "film", one = true, oses = EVERYWHERE, text = true},   // (a headless window filmed; with no ffmpeg on the PATH, no film is made)
	// (Linux: a child in a headless sway whose Vulkan has no driver, sway from the flake; Windows: render's faults refuse
	// the Direct3D 11 devices)
	{name = "no_graphics", oses = Oses{.Linux, .Windows}, text = true, defines = {"TOOLKIT_RENDER_FAULTS=true"}},
	{name = "cursors", one = true},
	{name = "tray", one = true},
	// pixels
	{name = "lifecycle", wgpu = .Ci3},
	{name = "lifecycle_faults", path = "tests/lifecycle", defines = {"TOOLKIT_RENDER_FAULTS=true"}, wgpu = .Ci10},
	{name = "canvas"},
	{name = "layers", wgpu = .Ci10, sample = true},
	{name = "planes", wgpu = .Ci11},
	{name = "effects", wgpu = .Ci9, sample = true},
	{name = "blend_space", wgpu = .Ci10},
	{name = "gradients", wgpu = .Ci10},
	{name = "shadows", wgpu = .Ci2},
	{name = "retained", wgpu = .Ci6},
	{name = "masks", wgpu = .Ci4},
	{name = "gpufx", wgpu = .Ci11},
	{name = "shaders", wgpu = .Ci1},
	{name = "appshaders", wgpu = .Ci11},
	{name = "video", wgpu = .Ci4, sample = true},
	{name = "textures", wgpu = .Ci2},
	// (one test at a time: the device made early is the process's, and another test's init_offscreen would take it)
	{name = "render_pkg", path = "src/render", one = true},
	// (wgpu's GL backend, forced: EGL surfaceless, llvmpipe where there is no GPU; no EGL: the log says the tests drew nothing)
	{name = "gl_fallback", oses = LINUX_ONLY, text = true},
	// text
	{name = "text", wgpu = .Ci1},
	{name = "subpixel"},
	{name = "subpixel_slug", path = "tests/subpixel", one = true, defines = {"TOOLKIT_RENDER=wgpu", "FONT_TEXT_RENDERER=slug"}, oses = EVERYWHERE, text = true},
	{name = "subpixel_system", oses = LINUX_ONLY, text = true},
	// FXC, the compiler every Windows has (no DXC beside the program): one device, so every shader through it once. (Each device costs FXC
	// some ten seconds: the whole package with it was four minutes.)
	{name = "subpixel_fxc", path = "tests/subpixel", one = true, defines = {"TOOLKIT_RENDER=wgpu", "TOOLKIT_WGPU_DX12_COMPILER=fxc", "FONT_TEXT_RENDERER=slug", "ODIN_TEST_NAMES=subpixel_test.light_text_on_dark_reaches_its_colour"}},
	{name = "slug", wgpu = .Ci1, sample = true},
	{name = "colr", need = .Emoji, wgpu = .Ci1},
	{name = "color_glyphs", wgpu = .Ci9},
	{name = "color_glyphs_builtin", path = "tests/color_glyphs", defines = {"COLR_ENGINE=builtin"}},
	{name = "color_native", oses = LINUX_ONLY, text = true},
	{name = "text_backends"},
	{name = "font_memory", oses = EVERYWHERE},
	{name = "font_default", oses = EVERYWHERE},   // (built with no define: the backend each system gets by default)
	{name = "lucide_subset", oses = EVERYWHERE, text = true},
	{name = "lean_build", oses = EVERYWHERE, defines = {"TOOLKIT_DEVTOOLS=false", "FONT_EMBED_FALLBACK=false"}, text = true},
	{name = "text_backends_native", path = "tests/text_backends", defines = {"FONT_BACKEND=native"}, need = .Native_Lib},
	// what must keep compiling
	{name = "uia_probe", path = "tools/uia_probe", kind = .Build},
	{name = "font_on_linux", path = "src/font", kind = .Check, target = "linux_amd64"},
	{name = "flate_on_linux", path = "src/flate", kind = .Check, target = "linux_amd64"},
	{name = "font_on_darwin", path = "src/font", kind = .Check, target = "darwin_arm64"},
	{name = "flate_on_darwin", path = "src/flate", kind = .Check, target = "darwin_arm64"},
	{name = "png_on_darwin", path = "src/png", kind = .Check, target = "darwin_arm64"},
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

// The toolkit's packages as the collection gt, as a program has them: a test imports "gt:ui", not a path out of its
// folder, so the tests could live in a repository of their own.
gt_collection :: proc(root: string) -> string { return fmt.tprintf("-collection:gt=%s/src", root) }
LOG_DIR :: "build/test_logs"
// The crash reports of a test package (gt:crash's report_dir): build/crashes/<package>, named to it by CRASH_DIR_ENV.
CRASH_DIR :: "build/crashes"
CRASH_DIR_ENV :: "TOOLKIT_TEST_CRASH_DIR"
THIS_OS :: Os.Windows when ODIN_OS == .Windows else Os.Linux
EXE_SUFFIX :: ".exe" when ODIN_OS == .Windows else ""

Run_Options :: struct {
	only:    [dynamic]string,
	backend: string,
	group:   string,
	defines: [dynamic]string,
	jobs:    int,
	limit:   int,
	list:    bool,
	check:   string,     // -check:<target>: every step of that system checked for it, nothing run
	env:     []string,   // the check's environment (toolbox.check_env); nil: this process's
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
	o:       ^Run_Options,
	print:   sync.Mutex,
}

main :: proc() {
	code := 0
	if on_own_desktop(&code) { os.exit(code) }
	o := Run_Options{limit = RUN_LIMIT_SECONDS}
	for a in toolbox.args_joined(os.args[1:]) {
		switch {
		case a == "-list": o.list = true
		case strings.has_prefix(a, "-backend:"): o.backend = a[len("-backend:"):]
		case strings.has_prefix(a, "-group:"): o.group = a[len("-group:"):]
		case strings.has_prefix(a, "-define:"): append(&o.defines, a[len("-define:"):])
		case strings.has_prefix(a, "-jobs:"): o.jobs, _ = strconv.parse_int(a[len("-jobs:"):])
		case strings.has_prefix(a, "-check:"): o.check = a[len("-check:"):]
		case strings.has_prefix(a, "-timeout:"): o.limit, _ = strconv.parse_int(a[len("-timeout:"):])
		case strings.has_prefix(a, "-"):
			fmt.eprintfln("unknown flag %s", a)
			os.exit(2)
		case: append(&o.only, a)
		}
	}
	chosen := choose(&o)
	if o.list {
		for s in chosen {
			groups := s.wgpu != .None ? fmt.tprintf("  wgpu %v", s.wgpu) : len(s.shards) > 0 ? fmt.tprintf("  wgpu shards %v", s.shards) : ""
			fmt.printfln("%-28s %v%s", s.name, s.kind, groups)
		}
		return
	}
	if len(chosen) == 0 { fmt.eprintln("nothing to run"); os.exit(2) }
	if o.check != "" {
		why: string
		o.env, why = toolbox.check_env(o.check)
		if why != "" { fmt.eprintfln("-check:%s: %s", o.check, why); os.exit(1) }
	}
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
choose :: proc(o: ^Run_Options) -> []^Step {
	out: [dynamic]^Step
	for &s in STEPS {
		if s.path == "" { s.path = fmt.aprintf("tests/%s", s.name) }
		oses := s.oses == {} ? WINDOWS_ONLY : s.oses
		if o.check != "" {
			// (a check of another system: its tests and programs, compiled for it)
			target_os := strings.has_prefix(o.check, "windows") ? Os.Windows : Os.Linux
			if s.kind == .Check || target_os not_in oses { continue }
			if len(o.only) > 0 && !slice.contains(o.only[:], s.name) { continue }
			append(&out, &s)
			continue
		}
		if s.kind != .Test && THIS_OS == .Linux { continue }   // (what compiles for Linux is the Linux job's own check: tk ci)
		if THIS_OS not_in oses { continue }
		if o.backend == "wgpu" && len(s.shards) > 0 {
			// (a shard is asked for by its own name or by its package's)
			named := len(o.only) == 0 || slice.contains(o.only[:], s.name)
			for sh in shards_of(&s) {
				if !named && !slice.contains(o.only[:], sh.name) { continue }
				if in_wgpu_group(sh, o) { append(&out, sh) }
			}
			continue
		}
		if len(o.only) > 0 && !slice.contains(o.only[:], s.name) { continue }
		if o.backend == "wgpu" {
			if s.wgpu == .None && len(o.only) == 0 { continue }
			if !in_wgpu_group(&s, o) { continue }
		}
		append(&out, &s)
	}
	return out[:]
}

// Whether a step runs in the WebGPU group asked for (-group:).
in_wgpu_group :: proc(s: ^Step, o: ^Run_Options) -> bool {
	if s.kind != .Test { return false }
	switch o.group {
	case "": return true
	case "sample": return s.sample
	case: return ascii.equal_fold(fmt.tprintf("%v", s.wgpu), o.group)
	}
}

// The steps of a sharded step (Step.shards): its tests in the order of their names, dealt in turn to one step per group,
// each the package built to run only its own (ODIN_TEST_NAMES). Dealt and not cut in halves: a file's tests, often of
// one cost, share their names' start.
shards_of :: proc(s: ^Step) -> []^Step {
	names := test_names(s)
	n := len(s.shards)
	if len(names) < n {
		// (an empty ODIN_TEST_NAMES runs every test: a shard would run them all)
		fmt.eprintfln("%s: %d tests for %d shards", s.name, len(names), n)
		os.exit(2)
	}
	out := make([]^Step, n)
	for group, i in s.shards {
		b := strings.builder_make()
		for name, j in names {
			if j % n != i { continue }
			if strings.builder_len(b) > 0 { strings.write_byte(&b, ',') }
			strings.write_string(&b, name)
		}
		defines: [dynamic]string
		for d in s.defines { if !strings.has_prefix(d, TEST_NAMES_DEFINE) { append(&defines, d) } }
		append(&defines, fmt.aprintf("%s%s", TEST_NAMES_DEFINE, strings.to_string(b)))
		sh := new(Step)
		sh^ = s^
		sh.name = fmt.aprintf("%s_%d", s.name, i + 1)
		sh.defines = defines[:]
		sh.wgpu = group
		sh.shards = nil
		out[i] = sh
	}
	return out
}

TEST_NAMES_DEFINE :: "ODIN_TEST_NAMES="

// A step's tests, "<package>.<name>", sorted: those of its ODIN_TEST_NAMES, else every @(test) procedure of its folder
// (a file of another system left out by its suffix).
test_names :: proc(s: ^Step) -> []string {
	for d in s.defines {
		if !strings.has_prefix(d, TEST_NAMES_DEFINE) { continue }
		names := strings.split(d[len(TEST_NAMES_DEFINE):], ",")
		slice.sort(names)
		return names
	}
	out: [dynamic]string
	entries, err := os.read_all_directory_by_path(s.path, context.allocator)
	if err != nil { fmt.eprintfln("%s: cannot read %s: %v", s.name, s.path, err); os.exit(2) }
	for e in entries {
		if e.type == .Directory || !strings.has_suffix(e.name, ".odin") || !of_this_system(e.name) { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.allocator)
		if rerr != nil { fmt.eprintfln("%s: cannot read %s: %v", s.name, e.fullpath, rerr); os.exit(2) }
		pkg := ""
		lines := strings.split_lines(string(data))
		for line, i in lines {
			t := strings.trim_space(line)
			if pkg == "" && strings.has_prefix(t, "package ") { pkg = strings.trim_space(t[len("package "):]) }
			if !strings.has_prefix(t, "@(test)") { continue }
			// (the procedure on the same line, or on the next)
			decl := strings.trim_space(t[len("@(test)"):])
			if decl == "" && i + 1 < len(lines) { decl = strings.trim_space(lines[i + 1]) }
			name, sep, _ := strings.partition(decl, "::")
			name = strings.trim_space(name)
			if sep == "" || name == "" || pkg == "" {
				fmt.eprintfln("%s:%d: a @(test) whose procedure is not read", e.fullpath, i + 1)
				os.exit(2)
			}
			append(&out, fmt.aprintf("%s.%s", pkg, name))
		}
	}
	slice.sort(out[:])
	return out[:]
}

// Whether a file of a package is compiled on this system, by its suffix (_windows, _linux, _unix, _darwin, _other).
of_this_system :: proc(file: string) -> bool {
	stem := strings.trim_suffix(file, ".odin")
	switch {
	case strings.has_suffix(stem, "_windows"): return THIS_OS == .Windows
	case strings.has_suffix(stem, "_linux"), strings.has_suffix(stem, "_unix"): return THIS_OS == .Linux
	case strings.has_suffix(stem, "_darwin"), strings.has_suffix(stem, "_other"): return false
	}
	return true
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
	case .Native_Lib: file = ODIN_OS == .Windows ? "build/native/gt_native.lib" : "build/native/libgt_native.a"
	case .Emoji: file = "build/emoji/NotoColorEmoji-COLRv1.ttf"
	}
	return os.exists(file) ? "" : fmt.tprintf("%s is not there: build it first", file)
}

run_step :: proc(s: ^Step, o: ^Run_Options) -> Result {
	began := time.tick_now()
	r := Result{step = s}
	need := s.need
	if s.text && ODIN_OS == .Linux && need == .None { need = .Native_Lib }
	if o.check != "" { need = .None }   // (a check links nothing)
	if why := missing_need(need); why != "" {
		r.why = why
	} else {
		carry_out(s, o, &r)
	}
	r.seconds = time.duration_seconds(time.tick_since(began))
	return r
}

carry_out :: proc(s: ^Step, o: ^Run_Options, r: ^Result) {
	log_file, err := os.open(log_path(s), os.O_WRONLY + os.O_CREATE + os.O_TRUNC + os.O_INHERITABLE)
	if err != nil { r.why = "cannot write its log"; return }
	defer os.close(log_file)

	cmd := make([dynamic]string, context.temp_allocator)
	suffix := o.backend != "" ? fmt.tprintf("_%s", o.backend) : ""
	// (the WebGPU programs next to DXC's DLLs, which tools/tk fetch_wgpu leaves in build/: without them wgpu falls back to FXC, ten
	// seconds a device. A step asks for WebGPU by its backend or by its own defines)
	on_wgpu := o.backend == "wgpu"
	for d in s.defines { if d == "TOOLKIT_RENDER=wgpu" { on_wgpu = true } }
	exe := fmt.tprintf("%s/%s%s%s", on_wgpu ? "build" : BUILD_DIR, s.name, suffix, EXE_SUFFIX)
	here, _ := os.get_working_directory(context.temp_allocator)
	exe_path := fmt.tprintf("%s/%s", here, exe)
	if o.check != "" {
		append(&cmd, "odin", "check", s.path, "-vet", fmt.tprintf("-target:%s", o.check), gt_collection(here))
		// (odin check has no test mode, so ODIN_TEST is false: the hooks a test build turns on, turned on by name)
		if s.kind == .Test { append(&cmd, "-no-entry-point", "-ignore-unused-defineables", "-define:FONT_FAILURE_HOOKS=true", "-define:DRAW_FAILURE_HOOKS=true") }
		if s.one { append(&cmd, "-define:ODIN_TEST_THREADS=1") }
		for d in s.defines { append(&cmd, fmt.tprintf("-define:%s", d)) }
		for d in o.defines { append(&cmd, fmt.tprintf("-define:%s", d)) }
		if !run_to_log(cmd[:], log_file, 0, r, o.env) {
			if r.why == "" { r.why = "it does not compile" }
			return
		}
		r.ok = true
		return
	}
	switch s.kind {
	case .Test:
		append(&cmd, "odin", "build", s.path, "-build-mode:test", "-vet", "-debug", fmt.tprintf("-out:%s", exe))
		append(&cmd, "-define:ODIN_TEST_FANCY=false", "-define:ODIN_TEST_LOG_STATE_CHANGES=true")
		if s.one || o.backend == "wgpu" { append(&cmd, "-define:ODIN_TEST_THREADS=1") }
		if o.backend != "" { append(&cmd, fmt.tprintf("-define:TOOLKIT_RENDER=%s", o.backend)) }
		when ODIN_OS == .Linux {
			if !s.one { append(&cmd, "-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true") }
			// (wgpu-native is the other Rust library in them: its few unmangled symbols of Rust's standard library are the same code)
			if s.text { append(&cmd, "-extra-linker-flags:-Wl,--allow-multiple-definition") }
		}
	case .Build:
		append(&cmd, "odin", "build", s.path, "-vet", fmt.tprintf("-out:%s", exe))
	case .Check:
		append(&cmd, "odin", "check", s.path, "-no-entry-point", "-vet", fmt.tprintf("-target:%s", s.target))
	}
	append(&cmd, gt_collection(here))
	for d in s.defines { append(&cmd, fmt.tprintf("-define:%s", d)) }
	for d in o.defines { append(&cmd, fmt.tprintf("-define:%s", d)) }
	if !run_to_log(cmd[:], log_file, 0, r) {
		if r.why == "" { r.why = "it does not compile" }
		return
	}
	if s.kind == .Test {
		// (a test package that installs gt:crash writes its reports there: a crash's stack then reaches the log, which
		// is all a CI run keeps)
		crash_dir := fmt.tprintf("%s/%s/%s", here, CRASH_DIR, s.name)
		_ = os.remove_all(crash_dir)
		_ = os.make_directory_all(crash_dir)
		env, _ := os.environ(context.temp_allocator)
		env_crash := make([dynamic]string, 0, len(env) + 1, context.temp_allocator)
		append(&env_crash, ..env)
		append(&env_crash, fmt.tprintf("%s=%s", CRASH_DIR_ENV, crash_dir))
		if !run_to_log({exe_path}, log_file, o.limit, r, env_crash[:]) {
			if r.why == "" { r.why = "a test failed" }
			reports_to_log(crash_dir, log_file)
			return
		}
		text, _ := os.read_entire_file(log_path(s), context.temp_allocator)
		if !strings.contains(string(text), "successful") { r.why = "it ended without saying that its tests passed"; return }
	}
	r.ok = true
}

// Runs a command, its output in the log. `limit`: seconds, 0 none. False: it failed; `r.why` when it says more than its exit code does.
run_to_log :: proc(cmd: []string, log: ^os.File, limit: int, r: ^Result, env: []string = nil) -> bool {
	p, err := os.process_start({command = cmd, stdout = log, stderr = log, env = env})
	if err != nil { r.why = fmt.tprintf("%s cannot start: %v", cmd[0], err); return false }
	began := time.tick_now()
	for {
		st, werr := os.process_wait(p, POLL_INTERVAL)
		if st.exited {
			if st.exit_code != 0 {
				// (0xC0000005 an access violation, 0xC000001D an assertion's trap that nothing caught, 0xC00000FD a stack overflow)
				r.why = fmt.tprintf("exit code 0x%08X", u32(st.exit_code))
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

// The crash reports a failed test package left, at the end of its log (the stack's symbols come last in a report, so
// the log's tail shows them).
reports_to_log :: proc(dir: string, log: ^os.File) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for e in entries {
		if e.type == .Directory || !strings.has_suffix(e.name, ".txt") { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil { continue }
		fmt.fprintfln(log, "\n---- crash report %s ----", e.name)
		_, _ = os.write(log, data)
	}
}

// The end of a log: what failed, and for a hang which test it was in (ODIN_TEST_LOG_STATE_CHANGES).
print_tail :: proc(path: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }
	lines := strings.split_lines(string(data), context.temp_allocator)
	report := -1
	for l, i in lines { if strings.has_prefix(l, "---- crash report") { report = i; break } }
	if report < 0 {
		// (a failed wait's words: on Windows its test ends as "Test timed out", far below them)
		first := max(len(lines) - FAILURE_LINES, 0)
		for l in lines[:first] { if strings.contains(l, "[ERROR]") { fmt.println(l) } }
		for l in lines[first:] { fmt.println(l) }
		return
	}
	// a crash: what the runtime said before it (an assertion's or a bounds check's words come before its trap), the
	// tests that had started, then the reports without their list of modules
	for l in lines[:report] {
		if strings.contains(l, "changed state to Running") || is_runtime_words(l) { fmt.println(l) }
	}
	for l in lines[report:] {
		if strings.has_prefix(l, "  0x") && (strings.contains(l, ".so") || strings.contains(l, ".dll") || strings.contains(l, ".exe")) { continue }
		fmt.println(l)
	}
}

// The words of Odin's runtime when it stops the process: an assertion, a bounds check, a panic, a bad free.
is_runtime_words :: proc(l: string) -> bool {
	for w in ([]string{"assertion", "Index ", "out of bounds", "panic", "Panic", "Invalid slice", "unreachable"}) {
		if strings.contains(l, w) { return true }
	}
	return false
}

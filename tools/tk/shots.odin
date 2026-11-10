package tk

// screenshots [-build] [-only:name,name] [-width:px]: docs/screenshots/*.png, and the copies of them in site/img, from the examples,
// over the Chrome DevTools Protocol (src/cdp): the picture is the frame the program rendered, so the mouse, the keyboard and the
// windows in front are left alone. Each program runs with an empty settings folder: the user's settings are neither read nor changed.
//   -build   builds the examples first
//   -only    just these pictures
//   -width   the width of the pictures (default 1400; 0: as rendered); a wider picture is made smaller, a narrower one stays
//
// finish_shots [-build] [-out:folder] [-page:N] [-theme:N]: a picture of a page of fidget (0: the controls, 1: the inputs) in
// each finish (flat, gradient, glass, machined), into build/finish_shots by default: to look at what a change of a finish does.
//
// theme_shots [-build] [-out:folder] [-page:name] [-find:text] [-only:name,name]: a picture of a page of examples/whatsnew in every
// theme of ui.THEMES (its dark version, or its only one), with no window (--headless): to look at what a change of colours does in
// all of them. By default the find page, searching "the", into build/theme_shots.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import cdp "../../src/cdp"

SHOTS_PORT        :: 9390
THEME_SHOTS_PORT  :: 9393
SHOTS_WIDTH       :: 1400
@(private = "file") START_TRIES :: 100
@(private = "file") START_POLL :: 100 * time.Millisecond
@(private = "file") END_LIMIT :: 5 * time.Second
@(private = "file") IDLE_LIMIT :: 5 * time.Second

// What a picture shows: the program, its arguments, how long its animations are given (ms).
Shot :: struct {
	name, example: string,
	args:          []string,
	ms:            int,
}

SHOTS := []Shot {
	{"controls",   "fidget",     {"--page=0", "--anim=on"}, 1500},
	{"inputs",     "fidget",     {"--page=1", "--anim=on"}, 1500},
	{"data",       "fidget",     {"--page=2", "--anim=on"}, 1500},
	{"playground", "fidget",     {"--page=3", "--anim=on"}, 3200},
	{"palette",    "fidget",     {"--palette_query=theme", "--theme=3", "--anim=on"}, 1500},
	{"settings",   "fidget",     {"--settings", "--anim=on"}, 1500},
	{"toasts",     "fidget",     {"--page=2", "--toasts", "--toast_pos=2", "--anim=on"}, 1800},
	{"about",      "fidget",     {"--about", "--theme=4", "--anim=on"}, 1500},
	{"light",      "fidget",     {"--page=0", "--theme=2", "--anim=on"}, 1500},
	{"bootstrap",  "fidget",     {"--page=0", "--theme=7", "--anim=on"}, 1500},
	{"compact",    "fidget",     {"--page=2", "--compact", "--anim=on"}, 1500},
	{"todo",       "todo",       {}, 1500},
	{"transforms", "transforms", {"--time=2.0"}, 1500},
	{"effects",    "effects",    {"--time=2.0"}, 1500},
}

Shots_Options :: struct {
	build: bool,
	only:  []string,   // nil: all
	width: int,
}

run_screenshots :: proc(a: ^Args) -> string {
	o := Shots_Options{build = has_flag(a, "build"), only = list_flag(a, "only")}
	why: string
	if o.width, why = int_flag(a, "width", SHOTS_WIDTH); why != "" { return why }
	return screenshots(toolkit_root(), o)
}

// "a,b" -> {"a", "b"}; nil when the flag is not given.
list_flag :: proc(a: ^Args, name: string) -> []string {
	if !has_flag(a, name) { return nil }
	return strings.split(flag_value(a, name), ",", context.temp_allocator)
}

@(private = "file")
wanted :: proc(only: []string, name: string) -> bool {
	if only == nil { return true }
	for n in only { if n == name { return true } }
	return false
}

screenshots :: proc(root: string, o: Shots_Options) -> string {
	shots := make([dynamic]Shot, context.temp_allocator)
	for s in SHOTS { if wanted(o.only, s.name) { append(&shots, s) } }
	if o.build {
		built := make(map[string]bool, context.temp_allocator)
		for s in shots {
			if built[s.example] { continue }
			built[s.example] = true
			if why := build_example(root, s.example, false); why != "" { return why }
		}
	}
	for s in shots {
		if why := capture_shot(root, s, o.width); why != "" { return why }
	}
	return ""
}

// A program of the toolkit with its devtools on `port`, until its client answers. The process is the caller's to end (end_program).
start_program :: proc(command: []string, port: int, extra_env: []string, dir := "", stderr: ^os.File = nil) -> (p: os.Process, c: cdp.Client, why: string) {
	env := make([dynamic]string, context.temp_allocator)
	all, _ := os.environ(context.temp_allocator)
	next: for e in all {
		if strings.has_prefix(e, "TOOLKIT_DEVTOOLS=") { continue }
		for x in extra_env {
			if eq := strings.index_byte(x, '='); eq > 0 && strings.has_prefix(e, x[:eq + 1]) { continue next }
		}
		append(&env, e)
	}
	append(&env, fmt.tprintf("TOOLKIT_DEVTOOLS=%d", port))
	append(&env, ..extra_env)
	err: os.Error
	p, err = os.process_start({command = command, env = env[:], working_dir = dir, stderr = stderr})
	if err != nil { return p, c, fmt.tprintf("%s does not start: %v", command[0], err) }
	for _ in 0 ..< START_TRIES {
		connected: bool
		if c, connected = cdp.connect(port); connected {
			c.quiet = true
			if _, ok := cdp.call(&c, "Browser.getVersion"); ok { return p, c, "" }   // (transforms and effects have no box tree)
			cdp.close(&c)
		}
		if state, _ := os.process_wait(p, 0); state.exited { return p, c, fmt.tprintf("%s ended (%d)", filepath.base(command[0]), state.exit_code) }
		time.sleep(START_POLL)
	}
	end_program(p)
	return p, c, fmt.tprintf("%s does not answer on port %d", filepath.base(command[0]), port)
}

// (once a wait saw it end, its handle is closed: it is not asked again)
end_program :: proc(p: os.Process) {
	if state, _ := os.process_wait(p, 0); state.exited { return }
	_ = os.process_kill(p)
	_, _ = os.process_wait(p, END_LIMIT)
}

@(private = "file")
// `out`: the folder of the picture ("": docs/screenshots, copied to site/img when it is there).
capture_shot :: proc(root: string, s: Shot, width: int, out_dir := "") -> string {
	exe := join({root, "build", fmt.tprintf("%s%s", s.example, EXE)})
	if !os.exists(exe) { return fmt.tprintf("%s is missing: run with -build", exe) }
	settings, err := os.make_directory_temp("", "gui_toolkit_shot_*", context.temp_allocator)
	if err != nil { return fmt.tprintf("no temporary folder: %v", err) }
	defer os.remove_all(settings)
	command := make([dynamic]string, context.temp_allocator)
	append(&command, exe)
	append(&command, ..s.args)
	p, c, why := start_program(command[:], SHOTS_PORT, {fmt.tprintf("APPDATA=%s", settings), fmt.tprintf("XDG_CONFIG_HOME=%s", settings)}, filepath.dir(exe))
	if why != "" { return why }
	defer end_program(p)
	defer cdp.close(&c)
	time.sleep(time.Duration(s.ms) * time.Millisecond)
	png, ok := cdp.screenshot(&c, nil, context.temp_allocator)
	if !ok { return fmt.tprintf("%s: %s", s.name, c.failure) }
	out := join({out_dir != "" ? out_dir : join({root, "docs", "screenshots"}), fmt.tprintf("%s.png", s.name)})
	if why = write_picture(out, png, width); why != "" { return why }
	if out_dir != "" { fmt.println("saved", out); return "" }
	site := join({root, "site", "img", fmt.tprintf("%s.png", s.name)})
	if os.exists(site) && os.copy_file(site, out) != nil { return fmt.tprintf("%s cannot be written", site) }
	fmt.println("saved", s.name)
	return ""
}

// A picture made `width` wide when it is wider (0: as it is).
@(private = "file")
write_picture :: proc(path: string, png: []byte, width: int) -> string {
	if width <= 0 {
		if os.write_entire_file(path, png) != nil { return fmt.tprintf("%s cannot be written", path) }
		return ""
	}
	pic, ok := cdp.png_decode(png, context.temp_allocator)
	if !ok { return fmt.tprintf("%s: the window's picture is no PNG", path) }
	small := cdp.shrink(pic, width, context.temp_allocator)
	if !cdp.png_write(path, small) { return fmt.tprintf("%s cannot be written", path) }
	return ""
}

Theme_Shots_Options :: struct {
	build:      bool,
	out:        string,
	page, find: string,
	only:       []string,
}

run_theme_shots :: proc(a: ^Args) -> string {
	root := toolkit_root()
	return theme_shots(root, {
		build = has_flag(a, "build"), out = flag_value(a, "out", join({root, "build", "theme_shots"})),
		page = flag_value(a, "page", "Find"), find = flag_value(a, "find", "the"), only = list_flag(a, "only"),
	})
}

// The names of ui.THEMES, from the source (tk does not import the interface): each line of the list that opens a theme,
// `\t{"Name",`.
theme_names :: proc(source: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	at := strings.index(source, "THEMES := [?]Theme_Def{")
	if at < 0 { return nil }
	list := source[at:]
	if end := strings.index(list, "\n}"); end >= 0 { list = list[:end] }
	for line in strings.split_lines(list, context.temp_allocator) {
		if !strings.has_prefix(line, "\t{\"") { continue }
		rest := line[3:]
		if close := strings.index_byte(rest, '"'); close > 0 { append(&out, rest[:close]) }
	}
	return out[:]
}

theme_shots :: proc(root: string, o: Theme_Shots_Options) -> string {
	exe := join({root, "build", fmt.tprintf("whatsnew%s", EXE)})
	if o.build {
		if why := build_example(root, "whatsnew", false); why != "" { return why }
	}
	if !os.exists(exe) { return fmt.tprintf("%s is missing: run with -build", exe) }
	_ = os.make_directory_all(o.out)
	source, read := read_text(join({root, "src", "ui", "themes.odin"}))
	if !read { return "src/ui/themes.odin cannot be read" }
	names := theme_names(source)
	if len(names) == 0 { return "no THEMES in src/ui/themes.odin" }
	for name in names {
		if !wanted(o.only, name) { continue }
		if why := theme_shot(exe, name, o); why != "" { return why }
	}
	return ""
}

@(private = "file")
theme_shot :: proc(exe, name: string, o: Theme_Shots_Options) -> string {
	p, c, why := start_program({exe, "--headless", fmt.tprintf("--page=%s", o.page), fmt.tprintf("--palette=%s", name)}, THEME_SHOTS_PORT, nil)
	if why != "" { return why }
	defer end_program(p)
	defer cdp.close(&c)
	if _, ok := cdp.wait_idle(&c, IDLE_LIMIT); !ok { return c.failure }
	if o.find != "" {
		if !cdp.key(&c, "ctrl+f") || !cdp.type_text(&c, o.find) { return c.failure }
		if _, ok := cdp.wait_idle(&c, IDLE_LIMIT); !ok { return c.failure }
	}
	file, _ := strings.replace_all(name, " ", "_", context.temp_allocator)
	out := join({o.out, fmt.tprintf("%s.png", file)})
	if !cdp.shot(&c, out) { return fmt.tprintf("%s: %s", out, c.failure) }
	fmt.println("saved", name)
	return ""
}

FINISHES :: [?]string{"flat", "gradient", "glass", "machined"}

run_finish_shots :: proc(a: ^Args) -> string {
	root := toolkit_root()
	if has_flag(a, "build") {
		if why := build_example(root, "fidget", false); why != "" { return why }
	}
	out := flag_value(a, "out", join({root, "build", "finish_shots"}))
	_ = os.make_directory_all(out)
	page := flag_value(a, "page", "0")
	theme := flag_value(a, "theme", "0")
	for f in FINISHES {
		s := Shot{fmt.tprintf("page%s_%s", page, f), "fidget", {fmt.tprintf("--page=%s", page), fmt.tprintf("--theme=%s", theme), fmt.tprintf("--finish=%s", f), "--anim=off"}, 1200}
		if why := capture_shot(root, s, 0, out); why != "" { return why }
	}
	return ""
}

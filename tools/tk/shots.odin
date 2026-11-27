package tk

// screenshots [-build] [-only:name,name] [-width:px]: docs/screenshots/*.png, and the copies of them in site/img, from the examples,
// over the Chrome DevTools Protocol (src/cdp): the picture is the frame the program rendered, so the mouse, the keyboard and the
// windows in front are left alone. Each program runs with an empty settings folder: the user's settings are neither read nor changed.
// Every program runs with no window at all (--headless): a picture never opens a window on the person's desktop.
// The showcase's scenes (examples/showcase, SHOWCASE_SHOTS) are kept as WebP
// (toolbox.webp_encode, cwebp): docs/screenshots/showcase_*.webp and site/img/showcase_*.webp, a tenth of their PNG.
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
import base "../../src/base"
import cdp "../../src/cdp"
import toolbox "../../src/toolbox"

SHOTS_WIDTH       :: 1400
@(private = "file") START_LIMIT :: 10 * time.Second
@(private = "file") END_LIMIT :: 5 * time.Second
@(private = "file") IDLE_LIMIT :: 5 * time.Second

// What a picture shows: the program, its arguments, how long its animations are given (ms; 0: until the program is at rest,
// IDLE_LIMIT at most), the text typed then (a menu's search; "": none), whether it is kept as WebP, and the keys pressed
// before the text (cdp.key's names: "ctrl+l"; nil: none).
Shot :: struct {
	name, example: string,
	args:          []string,
	ms:            int,
	typed:         string,
	webp:          bool,
	keys:          []string,
}

// The showcase's scenes, each a picture: its scene, its theme and finish where they show it off.
SHOWCASE_SHOTS := []Shot {
	{name = "showcase_intents", example = "showcase", args = {"--headless", "--scene=intents", "--theme=Graphite", "--size=1280x680"}, webp = true},
	{name = "showcase_intents_light", example = "showcase", args = {"--headless", "--scene=intents", "--theme=Midnight", "--light", "--size=1280x680"}, webp = true},
	{name = "showcase_controls", example = "showcase", args = {"--headless", "--scene=controls", "--theme=Midnight", "--size=1280x680"}, webp = true},
	{name = "showcase_controls_light", example = "showcase", args = {"--headless", "--scene=controls", "--theme=Champagne", "--light", "--size=1280x680"}, webp = true},
	{name = "showcase_controls_edged", example = "showcase", args = {"--headless", "--scene=controls", "--theme=Kernel", "--finish=edged", "--size=1280x680"}, webp = true},
	{name = "showcase_controls_glass", example = "showcase", args = {"--headless", "--scene=controls", "--theme=Aero", "--size=1280x680"}, webp = true},
	{name = "showcase_controls_gradient", example = "showcase", args = {"--headless", "--scene=controls", "--theme=Bootstrap", "--size=1280x680"}, webp = true},
	// (an active step turns for ever: the program is never at rest, so a time)
	{name = "showcase_steppers", example = "showcase", args = {"--headless", "--scene=steppers", "--theme=Graphite", "--size=1280x720"}, ms = 1500, webp = true},
	{name = "showcase_steppers_light", example = "showcase", args = {"--headless", "--scene=steppers", "--theme=Glacier", "--light", "--finish=gradient", "--size=1280x720"}, ms = 1500, webp = true},
	{name = "showcase_wheels", example = "showcase", args = {"--headless", "--scene=wheels", "--theme=Graphite", "--size=1280x680"}, webp = true},
	{name = "showcase_wheels_light", example = "showcase", args = {"--headless", "--scene=wheels", "--theme=Champagne", "--light", "--finish=flat", "--size=1280x680"}, webp = true},
	{name = "showcase_palette", example = "showcase", args = {"--headless", "--scene=palette", "--theme=Tokyo Night", "--size=1280x680"}, webp = true},
	{name = "showcase_menus", example = "showcase", args = {"--headless", "--scene=menus", "--theme=Nord", "--size=1280x720"}, webp = true},
	{name = "showcase_menu_search", example = "showcase", args = {"--headless", "--scene=menus", "--theme=Nord", "--light", "--size=1280x720"}, typed = "co", webp = true},
	{name = "showcase_toolbar", example = "showcase", args = {"--headless", "--scene=toolbar", "--theme=Graphite", "--size=1280x720"}, webp = true},
	{name = "showcase_toolbar_light", example = "showcase", args = {"--headless", "--scene=toolbar", "--theme=Silver", "--light", "--size=1280x720"}, webp = true},
	{name = "showcase_views_docked", example = "showcase", args = {"--headless", "--scene=views", "--views=docked", "--theme=Graphite", "--size=1280x720"}, webp = true},
	{name = "showcase_views_floating", example = "showcase", args = {"--headless", "--scene=views", "--views=floating", "--theme=Tokyo Night", "--size=1280x720"}, webp = true},
	{name = "showcase_views_dialog", example = "showcase", args = {"--headless", "--scene=views", "--views=dialog", "--theme=Nord", "--size=1280x720"}, webp = true},
	{name = "showcase_views_light", example = "showcase", args = {"--headless", "--scene=views", "--views=floating", "--theme=Glacier", "--light", "--size=1280x720"}, webp = true},
	// (six terminals in a small window: their tabs overflow the stack's strip, the one shown on its plate brought into
	// view, the left arrow; the sidebar's scenes overflow its vertical strip: its down arrow. No bar anywhere)
	{name = "views_span_full", example = "showcase", args = {"--headless", "--scene=views", "--views=span_full", "--theme=Graphite", "--size=1280x720"}, webp = true},
	{name = "views_span_content", example = "showcase", args = {"--headless", "--scene=views", "--views=span_content", "--theme=Graphite", "--size=1280x720"}, webp = true},
	{name = "views_main", example = "showcase", args = {"--headless", "--scene=views", "--views=main", "--theme=Graphite", "--size=1280x720"}, webp = true},
	{name = "views_kept", example = "showcase", args = {"--headless", "--scene=views", "--views=kept", "--theme=Graphite", "--size=1280x720"}, webp = true},
	{name = "showcase_views_tabs", example = "showcase", args = {"--headless", "--scene=views", "--views=tabs", "--theme=Graphite", "--size=760x560"}, webp = true},
	{name = "showcase_dialog", example = "showcase", args = {"--headless", "--scene=dialog", "--theme=Graphite", "--size=1280x680"}, webp = true},
	{name = "showcase_confirm", example = "showcase", args = {"--headless", "--scene=confirm", "--theme=Gruvbox", "--size=1280x680"}, webp = true},
	{name = "showcase_prompt", example = "showcase", args = {"--headless", "--scene=prompt", "--theme=Catppuccin", "--light", "--size=1280x680"}, webp = true},
	// (eight rows down: the five folders, then CHANGELOG.md, LICENSE, README.md, its text in the preview)
	{name = "showcase_file_browser", example = "showcase", args = {"--headless", "--scene=files", "--theme=Graphite", "--size=1280x720"}, webp = true, keys = {"down", "down", "down", "down", "down", "down", "down", "down"}},
	{name = "showcase_path_bar", example = "showcase", args = {"--headless", "--scene=files", "--theme=Tokyo Night", "--size=1280x720"}, webp = true, keys = {"ctrl+l", "end"}, typed = "/s"},
	{name = "showcase_settings", example = "showcase", args = {"--headless", "--scene=settings", "--theme=Graphite", "--page=appearance", "--size=1280x1180"}, webp = true},
	{name = "showcase_settings_advanced", example = "showcase", args = {"--headless", "--scene=settings", "--theme=Midnight", "--page=scrolling", "--advanced"}, webp = true},
	{name = "showcase_settings_search", example = "showcase", args = {"--headless", "--scene=settings", "--theme=Silver", "--light"}, typed = "scroll", webp = true},
	// (the values scene: a value kind and the control the table gives it; the family list and the colour picker opened)
	{name = "showcase_values_font_family", example = "showcase", args = {"--headless", "--scene=values", "--value=font_family", "--open", "--theme=Graphite", "--size=1280x860"}, webp = true},
	{name = "showcase_values_color", example = "showcase", args = {"--headless", "--scene=values", "--value=color", "--open", "--theme=Tokyo Night", "--size=1280x760"}, webp = true},
	{name = "showcase_values_size", example = "showcase", args = {"--headless", "--scene=values", "--value=size", "--theme=Nord", "--light", "--size=1280x520"}, webp = true},
	{name = "showcase_values_duration", example = "showcase", args = {"--headless", "--scene=values", "--value=duration", "--theme=Graphite", "--size=1280x520"}, webp = true},
	{name = "showcase_graph", example = "showcase", args = {"--headless", "--scene=graph", "--theme=Graphite"}, webp = true},
	{name = "showcase_graph_light", example = "showcase", args = {"--headless", "--scene=graph", "--theme=Glacier", "--light", "--finish=edged"}, webp = true},
	{name = "showcase_toasts", example = "showcase", args = {"--headless", "--scene=toasts", "--theme=Dracula"}, ms = 1500, webp = true},
	{name = "showcase_themes", example = "showcase", args = {"--headless", "--scene=themes", "--theme=Graphite", "--size=1280x590"}, webp = true},
	// (examples/debug_panel: the drone and its panel in the debug window, the time held)
	{name = "debug_panel", example = "debug_panel", args = {"--headless", "--still", "--debug"}, webp = true},
	{name = "debug_panel_light", example = "debug_panel", args = {"--headless", "--still", "--debug", "--theme=Glacier", "--light"}, webp = true},
	// (its Flight panel: the drone's curves and its landing's easing)
	{name = "debug_curves", example = "debug_panel", args = {"--headless", "--still", "--debug=Flight"}, webp = true},
	{name = "debug_curves_light", example = "debug_panel", args = {"--headless", "--still", "--debug=Flight", "--theme=Glacier", "--light"}, webp = true},
}

SHOTS := []Shot {
	{"controls",   "fidget",     {"--headless", "--page=0", "--anim=on"}, 1500, "", false, nil},
	{"inputs",     "fidget",     {"--headless", "--page=1", "--anim=on"}, 1500, "", false, nil},
	{"data",       "fidget",     {"--headless", "--page=2", "--anim=on"}, 1500, "", false, nil},
	{"playground", "fidget",     {"--headless", "--page=3", "--anim=on"}, 3200, "", false, nil},
	{"palette",    "fidget",     {"--headless", "--palette_query=theme", "--theme=3", "--anim=on"}, 1500, "", false, nil},
	{"settings",   "fidget",     {"--headless", "--settings", "--anim=on"}, 1500, "", false, nil},
	{"toasts",     "fidget",     {"--headless", "--page=2", "--toasts", "--toast_pos=2", "--anim=on"}, 1800, "", false, nil},
	{"about",      "fidget",     {"--headless", "--about", "--theme=4", "--anim=on"}, 1500, "", false, nil},
	{"light",      "fidget",     {"--headless", "--page=0", "--theme=2", "--anim=on"}, 1500, "", false, nil},
	{"bootstrap",  "fidget",     {"--headless", "--page=0", "--theme=7", "--anim=on"}, 1500, "", false, nil},
	{"compact",    "fidget",     {"--headless", "--page=2", "--compact", "--anim=on"}, 1500, "", false, nil},
	{"todo",       "todo",       {"--headless"}, 1500, "", false, nil},
	{"transforms", "transforms", {"--headless", "--time=2.0"}, 1500, "", false, nil},
	{"effects",    "effects",    {"--headless", "--time=2.0"}, 1500, "", false, nil},
}

Shots_Options :: struct {
	build: bool,
	only:  []string,   // nil: all
	width: int,
}

run_screenshots :: proc(args: []string) -> string {
	o := Shots_Options{build = toolbox.has_flag(args, "build"), only = list_flag(args, "only")}
	why: string
	if o.width, why = toolbox.int_flag(args, "width", SHOTS_WIDTH); why != "" { return why }
	return screenshots(toolkit_root(), o)
}

// "a,b" -> {"a", "b"}; nil when the flag is not given.
list_flag :: proc(args: []string, name: string) -> []string {
	if !toolbox.has_flag(args, name) { return nil }
	return strings.split(toolbox.flag_value(args, name), ",", context.temp_allocator)
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
	for s in SHOWCASE_SHOTS { if wanted(o.only, s.name) { append(&shots, s) } }
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

// A program of the toolkit with its devtools on `port` (0: a free one, so that two tools never drive each other's
// program), until its client answers. The process is the caller's to end (end_program).
start_program :: proc(command: []string, extra_env: []string, dir := "", stderr: ^os.File = nil, port := 0) -> (p: os.Process, c: cdp.Client, why: string) {
	port := port
	if port == 0 {
		free, ok := toolbox.free_port()
		if !ok { return p, c, "no free port for the devtools" }
		port = free
	}
	env := make([dynamic]string, context.temp_allocator)
	all, _ := os.environ(context.temp_allocator)
	next: for e in all {
		if e == "" || strings.has_prefix(e, "TOOLKIT_DEVTOOLS=") { continue }
		for x in extra_env {
			if eq := strings.index_byte(x, '='); eq > 0 && strings.has_prefix(e, x[:eq + 1]) { continue next }
		}
		append(&env, e)
	}
	append(&env, fmt.tprintf("TOOLKIT_DEVTOOLS=%d", port))
	append(&env, ..extra_env)
	// (a picture never takes the person's desktop, bus nor graphics card: base.isolated_env)
	err: os.Error
	p, err = os.process_start({command = command, env = base.isolated_env(env[:]), working_dir = dir, stderr = stderr})
	if err != nil { return p, c, fmt.tprintf("%s does not start: %v", command[0], err) }
	connected: bool
	ended: os.Process_State
	if c, connected, ended = cdp.connect_wait(port, START_LIMIT, p); connected {
		c.quiet = true
		if _, ok := cdp.call(&c, "Browser.getVersion"); ok { return p, c, "" }   // (transforms and effects have no box tree)
		cdp.close(&c)
	}
	// (an end the wait saw was collected there: its state is the wait's)
	if ended.exited { return p, c, fmt.tprintf("%s ended (%d)", filepath.base(command[0]), ended.exit_code) }
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
	p, c, why := start_program(command[:], {fmt.tprintf("APPDATA=%s", settings), fmt.tprintf("XDG_CONFIG_HOME=%s", settings)}, filepath.dir(exe))
	if why != "" { return why }
	defer end_program(p)
	defer cdp.close(&c)
	if s.ms > 0 {
		time.sleep(time.Duration(s.ms) * time.Millisecond)
	} else if _, ok := cdp.wait_idle(&c, IDLE_LIMIT); !ok {   // (still moving at the limit, a spinner: the picture all the same)
		return fmt.tprintf("%s: %s", s.name, c.failure)
	}
	// (at rest after each key: a key that opens a field gives it the keyboard in a later build than its own)
	for k in s.keys {
		if !cdp.key(&c, k) { return fmt.tprintf("%s: %s", s.name, c.failure) }
		if _, ok := cdp.wait_idle(&c, IDLE_LIMIT); !ok { return fmt.tprintf("%s: %s", s.name, c.failure) }
	}
	if s.typed != "" {
		if !cdp.type_text(&c, s.typed) { return fmt.tprintf("%s: %s", s.name, c.failure) }
		if _, ok := cdp.wait_idle(&c, IDLE_LIMIT); !ok { return fmt.tprintf("%s: %s", s.name, c.failure) }
	}
	png, ok := cdp.screenshot(&c, nil, context.temp_allocator)
	if !ok { return fmt.tprintf("%s: %s", s.name, c.failure) }
	if s.webp && out_dir == "" { return write_webp(root, s.name, png, width, settings) }
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

// A picture as WebP, `width` wide when it is wider: docs/screenshots/<name>.webp and its copy in site/img. Its PNG goes through
// `scratch` (a folder of the caller's): cwebp reads a file.
@(private = "file")
write_webp :: proc(root, name: string, png: []byte, width: int, scratch: string) -> string {
	encoder, why := toolbox.webp_encoder(join({root, "build"}))
	if why != "" { return why }
	from := join({scratch, fmt.tprintf("%s.png", name)})
	if why = write_picture(from, png, width); why != "" { return why }
	out := join({root, "docs", "screenshots", fmt.tprintf("%s.webp", name)})
	if !toolbox.webp_encode(encoder, from, out) { return fmt.tprintf("%s was not encoded", out) }
	site := join({root, "site", "img", fmt.tprintf("%s.webp", name)})
	if os.copy_file(site, out) != nil { return fmt.tprintf("%s cannot be written", site) }
	fmt.println("saved", name)
	return ""
}

Theme_Shots_Options :: struct {
	build:      bool,
	out:        string,
	page, find: string,
	only:       []string,
}

run_theme_shots :: proc(args: []string) -> string {
	root := toolkit_root()
	return theme_shots(root, {
		build = toolbox.has_flag(args, "build"), out = toolbox.flag_value(args, "out", join({root, "build", "theme_shots"})),
		page = toolbox.flag_value(args, "page", "Find"), find = toolbox.flag_value(args, "find", "the"), only = list_flag(args, "only"),
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
	p, c, why := start_program({exe, "--headless", fmt.tprintf("--page=%s", o.page), fmt.tprintf("--palette=%s", name)}, nil)
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

run_finish_shots :: proc(args: []string) -> string {
	root := toolkit_root()
	if toolbox.has_flag(args, "build") {
		if why := build_example(root, "fidget", false); why != "" { return why }
	}
	out := toolbox.flag_value(args, "out", join({root, "build", "finish_shots"}))
	_ = os.make_directory_all(out)
	page := toolbox.flag_value(args, "page", "0")
	theme := toolbox.flag_value(args, "theme", "0")
	for f in FINISHES {
		s := Shot{fmt.tprintf("page%s_%s", page, f), "fidget", {"--headless", fmt.tprintf("--page=%s", page), fmt.tprintf("--theme=%s", theme), fmt.tprintf("--finish=%s", f), "--anim=off"}, 1200, "", false, nil}
		if why := capture_shot(root, s, 0, out); why != "" { return why }
	}
	return ""
}

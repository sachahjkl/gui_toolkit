// tk: the toolkit's tools that build, fetch and draw what the code needs, one program with a command each.
//   odin run tools/tk -- <command> [flags]        (or odin build tools/tk -out:build/tk.exe once, then build/tk <command>)
//
//   build_text [-force]                       the native text backend (native/text, cargo) -> build/text/gt_text.lib; nothing to do
//                                             when build/text/STAMP is the hash of the crate's sources, Cargo.lock and tools/tk/native.odin
//   build_a11y [-force]                       the AccessKit adapter (native/a11y) -> build/a11y/gt_a11y.lib, the same way
//   build_mermaid [-force]                    Mermaid diagrams to SVG (native/mermaid) -> build/mermaid/gt_mermaid.lib, the same way
//   build_naga                                the WGSL to HLSL translator (tools/wgsl2hlsl, naga) -> build/naga/wgsl2hlsl.exe: its Cargo.lock
//                                             pinned by SHA-256 (NAGA_LOCK_SHA256), rebuilt when build/naga/wgsl2hlsl.sources differs
//   fetch_emoji [-dest:dir] [-unicode]        Noto Color Emoji COLR v1 (pinned by commit and SHA-256, its SVG table dropped) and OFL.txt
//                                             -> build/emoji; -unicode: also Unicode 18.0's emoji-test.txt and emoji-data.txt
//   fetch_wgpu [-dest:dir] [-no-dxc] [-odin:exe]
//                                             Windows: checks the wgpu-native Odin ships (downloads it when it is not as pinned), copies
//                                             wgpu_native.dll and puts DXC's dxcompiler.dll + dxil.dll in -dest (default build/; -no-dxc: not DXC).
//                                             Linux: puts the static wgpu-native in Odin's vendor/wgpu/lib/wgpu-linux-x86_64-release.
//                                             -odin: the compiler whose vendor folder it is (default: odin on the PATH)
//   gen_emoji_data [-data:file]               font/emoji_data.odin from Unicode's emoji-data.txt (default build/emoji/emoji-data.txt)
//   make_icon -png:file -out:file             a multi-size .ico (PNG, 16 to 256 px) from the 512 px logo
//   make_logo [-out:file]                     draws the logo, 512 px (default .project/image.png)
//   ppm_diff a.ppm b.ppm [-tolerance:2]       two P6 PPM files (tools/render_probe): the largest and mean difference of a channel, and
//                                             how many pixels differ by more than the tolerance
//   emoji_board [-size:32] [-scale:1] [-step:37] [-font:ttf] [-out-dir:dir]
//                                             the COLR interpreter against a headless Edge on the same font (tools/colrboard): every
//                                             step-th emoji of emoji-test.txt and a few hard ones -> <out-dir>/side.png and the numbers
//   build [example] [-debug]                 an example (default fidget) -> build/<example>[.exe], optimized or with debug
//                                             information; Windows: no console, its .rc; Linux: the native text backend first
//   ci                                        what the CI checks on this system: odin check of every package, the examples, the
//                                             tests (tools/run_tests); every step runs, then the failures are said
//   desktop_tests [x11|randr|wayland]       Linux: the backends against real servers on a virtual desktop nobody sees (Xvfb and
//                                             openbox, Xorg's dummy driver with two monitors, headless sway): tests/linux_desktop
//   site_build <site> <out>                   the site as published: site_changelog, site_meta, site_docs into <out>, then its links (site.odin)
//   site_changelog <site> <out>               a copy of <site> with the history from CHANGELOG.md and the classic pages (src/site)
//   site_meta <site> <out>                    what each page says when shared, the feed, the sitemap, the files around the pages
//   site_docs <site> <out>                    every docs/*.md as <out>/docs/<name>/index.html with src/site's menu, search and contents,
//                                             docs/_nav.txt the menu (site_docs.odin); <site>/index.html gives the header and script
//   site_card                                 draws site/img/card.png in a local Chromium, once, by hand
//   site_check [--site folder] [--shot file.png] [--browser program]
//                                             the site's pages in Chrome or Edge with no window, served on 127.0.0.1
//   cdp [--port 9222] <command> [args] [, <command> [args]]...
//                                             drives a toolkit window over the DevTools protocol: tree, find, click, key, type, shot,
//                                             idle, wait-for, record, play, timelines... (cdp.odin lists them)
//   screenshots [-build] [-only:a,b] [-width:1400]
//                                             docs/screenshots/*.png and site/img from the examples, their own frames (shots.odin)
//   theme_shots [-build] [-out:dir] [-page:Find] [-find:the] [-only:a,b]
//                                             examples/whatsnew in every named palette, no window -> build/theme_shots
//   timeline_test [-exe:file] [-out:dir] [-port:9477]
//                                             the timelines of src/cdp against examples/whatsnew --headless over a real socket
//   doc_check [--root folder] [--extra folder]...
//                                             the files, flags and names the documentation cites exist (doc_check.odin)
//   release <version> [-summary:text] [-no-push]
//                                             publishes a version, on Windows or Linux (release.odin, CONTRIBUTING.md): the CHANGELOG
//                                             section, the version, the commit, the tag, the push and the GitHub release
// A relative path given is the working directory's; the defaults are in the toolkit's checkout (two folders above this file), from
// wherever tk runs, except emoji_board's, which runs in the checkout. Every download is checked against its SHA-256 before it is used.
// Exit code 0 when the work is done, 1 when it failed, 2 for a command line it does not understand. tests/tk calls the procedures below.
package tk

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "../cmdline"
import toolbox "../../src/toolbox"

// What a stamp file ends with, as PowerShell's Set-Content wrote them (the ones already built stay valid).
NEWLINE :: "\r\n" when ODIN_OS == .Windows else "\n"
// Exit codes.
EXIT_FAILED :: 1
EXIT_USAGE :: 2

Command :: struct {
	name:        string,
	flags:       []string,                 // what it takes: "name" a switch, "name:" a flag with a value
	positionals: int,                      // how many plain arguments it takes (-1: none or one)
	run:         proc(a: ^Args) -> string, // "" when the work is done, else why it is not
	raw:         bool,                     // every argument is a plain one: the command reads its own (--name value)
}

COMMANDS := []Command {
	{name = "build_text", flags = {"force"}, run = run_build_text},
	{name = "build_a11y", flags = {"force"}, run = run_build_a11y},
	{name = "build_mermaid", flags = {"force"}, run = run_build_mermaid},
	{name = "build_naga", run = run_build_naga},
	{name = "fetch_emoji", flags = {"dest:", "unicode"}, run = run_fetch_emoji},
	{name = "fetch_wgpu", flags = {"dest:", "no-dxc", "odin:"}, run = run_fetch_wgpu},
	{name = "gen_emoji_data", flags = {"data:"}, run = run_gen_emoji_data},
	{name = "make_icon", flags = {"png:", "out:"}, run = run_make_icon},
	{name = "make_logo", flags = {"out:"}, run = run_make_logo},
	{name = "ppm_diff", flags = {"tolerance:"}, positionals = 2, run = run_ppm_diff},
	{name = "emoji_board", flags = {"size:", "scale:", "step:", "font:", "out-dir:"}, run = run_emoji_board},
	{name = "release", flags = {"summary:", "no-push"}, positionals = 1, run = run_release},
	{name = "build", flags = {"debug"}, positionals = -1, run = run_build},
	{name = "site_docs", positionals = 2, run = run_site_docs},
	{name = "site_build", positionals = 2, run = run_site_build},
	{name = "site_changelog", positionals = 2, run = run_site_changelog},
	{name = "site_meta", positionals = 2, run = run_site_meta},
	{name = "site_card", run = run_site_card},
	{name = "site_check", raw = true, run = run_site_check},
	{name = "cdp", raw = true, run = run_cdp},
	{name = "screenshots", flags = {"build", "only:", "width:"}, run = run_screenshots},
	{name = "theme_shots", flags = {"build", "out:", "page:", "find:", "only:"}, run = run_theme_shots},
	{name = "finish_shots", flags = {"build", "out:", "page:", "theme:"}, run = run_finish_shots},
	{name = "timeline_test", flags = {"exe:", "out:", "port:"}, run = run_timeline_test},
	{name = "doc_check", raw = true, run = run_doc_check},
	{name = "ci", run = run_ci},
	{name = "desktop_tests", positionals = -1, run = run_desktop_tests},
}

Flag :: struct {
	name, value: string,
}

Args :: struct {
	command:     ^Command,
	flags:       [dynamic]Flag,
	positionals: [dynamic]string,
}

main :: proc() {
	a, why := parse(cmdline.joined(os.args[1:]))
	if why != "" {
		fmt.eprintfln("tk: %s", why)
		fmt.eprint("commands:")
		for c in COMMANDS { fmt.eprintf(" %s", c.name) }
		fmt.eprintln(" (see the head of tools/tk/main.odin)")
		os.exit(EXIT_USAGE)
	}
	if why = a.command.run(&a); why != "" {
		fmt.eprintfln("tk %s: %s", a.command.name, why)
		os.exit(EXIT_FAILED)
	}
}

// The command line (without the program) read against COMMANDS. why != "": not one tk understands.
parse :: proc(args: []string, allocator := context.temp_allocator) -> (a: Args, why: string) {
	a.flags = make([dynamic]Flag, allocator)
	a.positionals = make([dynamic]string, allocator)
	if len(args) == 0 { return a, "no command" }
	for &c in COMMANDS { if c.name == args[0] { a.command = &c } }
	if a.command == nil { return a, fmt.tprintf("no command %s", args[0]) }
	if a.command.raw {
		append(&a.positionals, ..args[1:])
		return a, ""
	}
	for arg in args[1:] {
		if len(arg) < 2 || arg[0] != '-' { append(&a.positionals, arg); continue }
		name, value := arg[1:], ""
		colon := strings.index_byte(name, ':')
		if colon >= 0 { name, value = name[:colon], name[colon + 1:] }
		spelled := colon >= 0 ? fmt.tprintf("%s:", name) : name
		known := false
		for f in a.command.flags { known ||= f == spelled }
		if !known { return a, fmt.tprintf("%s takes no flag -%s", a.command.name, spelled) }
		append(&a.flags, Flag{name, value})
	}
	if a.command.positionals >= 0 && len(a.positionals) != a.command.positionals || len(a.positionals) > 1 && a.command.positionals < 0 {
		return a, fmt.tprintf("%s takes %d plain arguments, not %d", a.command.name, a.command.positionals, len(a.positionals))
	}
	return a, ""
}

has_flag :: proc(a: ^Args, name: string) -> bool {
	for f in a.flags { if f.name == name { return true } }
	return false
}

// The value of a flag, or `default` when it is not given (the last one given wins).
flag_value :: proc(a: ^Args, name: string, default := "") -> string {
	v := default
	for f in a.flags { if f.name == name { v = f.value } }
	return v
}

int_flag :: proc(a: ^Args, name: string, default: int) -> (int, string) {
	if !has_flag(a, name) { return default, "" }
	n, ok := strconv.parse_int(flag_value(a, name))
	return n, ok ? "" : fmt.tprintf("-%s: not a whole number", name)
}

f64_flag :: proc(a: ^Args, name: string, default: f64) -> (f64, string) {
	if !has_flag(a, name) { return default, "" }
	n, ok := strconv.parse_f64(flag_value(a, name))
	return n, ok ? "" : fmt.tprintf("-%s: not a number", name)
}

// The toolkit's checkout: two folders above this file.
toolkit_root :: proc() -> string {
	return join({#directory, "..", ".."})
}

join :: proc(parts: []string) -> string {
	p, _ := filepath.join(parts, context.temp_allocator)
	return p
}

read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return string(data), err == nil
}

// Unpacks a zip archive into `dir`.
unzip :: proc(zip, dir: string) -> bool {
	when ODIN_OS == .Windows {
		return toolbox.run({toolbox.system_program("tar"), "-xf", zip, "-C", dir})   // (bsdtar, which reads zip archives)
	} else {
		return toolbox.run({"unzip", "-qo", zip, "-d", dir})
	}
}

// The first file named `name` under `dir` (a folder named `within` on its path when that is not "").
find_file :: proc(dir, name, within: string) -> string {
	w := os.walker_create_path(dir)
	defer os.walker_destroy(&w)
	for fi in os.walker_walk(&w) {
		if fi.type == .Directory || !strings.equal_fold(fi.name, name) { continue }
		path, _ := strings.replace_all(fi.fullpath, "\\", "/", context.temp_allocator)
		if within != "" && !strings.contains(path, fmt.tprintf("/%s/", within)) { continue }
		return strings.clone(fi.fullpath, context.temp_allocator)
	}
	return ""
}

// The text of a stamp file, with its line end.
write_stamp :: proc(path, text: string) -> bool {
	return os.write_entire_file(path, fmt.tprintf("%s%s", text, NEWLINE)) == nil
}

// The output is there and the stamp beside it says `expected`.
stamp_holds :: proc(output, stamp, expected: string) -> bool {
	if !os.exists(output) { return false }
	text, ok := read_text(stamp)
	return ok && strings.trim_space(text) == expected
}

run_build_text :: proc(a: ^Args) -> string { return build_rust_lib(toolkit_root(), TEXT_LIB, has_flag(a, "force")) }
run_build_a11y :: proc(a: ^Args) -> string { return build_rust_lib(toolkit_root(), A11Y_LIB, has_flag(a, "force")) }
run_build_mermaid :: proc(a: ^Args) -> string { return build_rust_lib(toolkit_root(), MERMAID_LIB, has_flag(a, "force")) }
run_build_naga :: proc(a: ^Args) -> string { return build_naga(toolkit_root()) }

run_fetch_emoji :: proc(a: ^Args) -> string {
	return fetch_emoji({dest = flag_value(a, "dest", join({toolkit_root(), EMOJI_DEST})), unicode = has_flag(a, "unicode")})
}

run_fetch_wgpu :: proc(a: ^Args) -> string {
	return fetch_wgpu({dest = flag_value(a, "dest", join({toolkit_root(), "build"})), no_dxc = has_flag(a, "no-dxc"), odin = flag_value(a, "odin", "odin")})
}

run_gen_emoji_data :: proc(a: ^Args) -> string {
	root := toolkit_root()
	return gen_emoji_data(root, flag_value(a, "data", join({root, EMOJI_DEST, "emoji-data.txt"})))
}

run_make_icon :: proc(a: ^Args) -> string {
	png, out := flag_value(a, "png"), flag_value(a, "out")
	if png == "" || out == "" { return "-png:<logo.png> and -out:<icon.ico> are both needed" }
	return make_icon(png, out)
}

run_make_logo :: proc(a: ^Args) -> string {
	return make_logo(flag_value(a, "out", join({toolkit_root(), LOGO_DEFAULT_OUT})))
}

run_ppm_diff :: proc(a: ^Args) -> string {
	tolerance, why := int_flag(a, "tolerance", PPM_TOLERANCE)
	if why != "" { return why }
	d: Ppm_Diff
	d, why = ppm_diff_files(a.positionals[0], a.positionals[1], tolerance)
	if why != "" { return why }
	fmt.printfln("%dx%d: max %d, mean %.3f, pixels over %d: %d", d.w, d.h, d.max, d.mean, tolerance, d.over)
	return ""
}

run_emoji_board :: proc(a: ^Args) -> string {
	o := Board_Options{font = flag_value(a, "font"), out_dir = flag_value(a, "out-dir")}
	why: string
	if o.size, why = int_flag(a, "size", BOARD_SIZE); why != "" { return why }
	if o.scale, why = f64_flag(a, "scale", BOARD_SCALE); why != "" { return why }
	if o.step, why = int_flag(a, "step", BOARD_STEP); why != "" { return why }
	if o.step < 1 { return "-step: at least 1" }
	return emoji_board(toolkit_root(), o)
}

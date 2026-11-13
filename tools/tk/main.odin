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
//   gen_lucide                                src/lucide/lucide.odin from lucide.ttf: a constant per icon, named after its glyph
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
//   release <patch|minor|major|x.y.z> [-summary:text] [-no-push]
//                                             publishes a version, on Windows or Linux, from any clean checkout (release.odin,
//                                             CONTRIBUTING.md): the next number after the last tag, the CHANGELOG section, the
//                                             version, the commit, the tag, master and the tag pushed at once, the GitHub release
// A relative path given is the working directory's; the defaults are in the toolkit's checkout (two folders above this file), from
// wherever tk runs, except emoji_board's, which runs in the checkout. Every download is checked against its SHA-256 before it is used.
// Exit code 0 when the work is done, 1 when it failed, 2 for a command line it does not understand. tests/tk calls the procedures below.
package tk

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import toolbox "../../src/toolbox"

COMMANDS := []toolbox.Command {
	{name = "build_text", usage = "[-force]: the native text backend (native/text) -> build/text, unless its stamp says it is up to date", checked = true, flags = {"force"}, run = proc(args: []string) -> int { return toolbox.done(run_build_text(args)) }},
	{name = "build_a11y", usage = "[-force]: the AccessKit adapter (native/a11y) -> build/a11y, the same way", checked = true, flags = {"force"}, run = proc(args: []string) -> int { return toolbox.done(run_build_a11y(args)) }},
	{name = "build_mermaid", usage = "[-force]: Mermaid diagrams to SVG (native/mermaid) -> build/mermaid, the same way", checked = true, flags = {"force"}, run = proc(args: []string) -> int { return toolbox.done(run_build_mermaid(args)) }},
	{name = "build_naga", usage = ": the WGSL to HLSL translator (tools/wgsl2hlsl) -> build/naga/wgsl2hlsl.exe, its Cargo.lock pinned", checked = true, run = proc(args: []string) -> int { return toolbox.done(run_build_naga(args)) }},
	{name = "fetch_emoji", usage = "[-dest:dir] [-unicode]: Noto Color Emoji COLR v1 and OFL.txt -> build/emoji; -unicode: Unicode's emoji files too", checked = true, flags = {"dest:", "unicode"}, run = proc(args: []string) -> int { return toolbox.done(run_fetch_emoji(args)) }},
	{name = "fetch_wgpu", usage = "[-dest:dir] [-no-dxc] [-odin:exe]: wgpu-native as pinned (Windows: its DLL and DXC's; Linux: Odin's vendor library)", checked = true, flags = {"dest:", "no-dxc", "odin:"}, run = proc(args: []string) -> int { return toolbox.done(run_fetch_wgpu(args)) }},
	{name = "gen_emoji_data", usage = "[-data:file]: font/emoji_data.odin from Unicode's emoji-data.txt", checked = true, flags = {"data:"}, run = proc(args: []string) -> int { return toolbox.done(run_gen_emoji_data(args)) }},
	{name = "make_icon", usage = "-png:file -out:file: a multi-size .ico (PNG, 16 to 256 px) from the 512 px logo", checked = true, flags = {"png:", "out:"}, run = proc(args: []string) -> int { return toolbox.done(run_make_icon(args)) }},
	{name = "make_logo", usage = "[-out:file]: draws the logo, 512 px (default .project/image.png)", checked = true, flags = {"out:"}, run = proc(args: []string) -> int { return toolbox.done(run_make_logo(args)) }},
	{name = "ppm_diff", usage = "a.ppm b.ppm [-tolerance:2]: the largest and mean difference of two P6 PPM files, the pixels over the tolerance", checked = true, flags = {"tolerance:"}, positionals = 2, run = proc(args: []string) -> int { return toolbox.done(run_ppm_diff(args)) }},
	{name = "emoji_board", usage = "[-size:32] [-scale:1] [-step:37] [-font:ttf] [-out-dir:dir]: the COLR interpreter against a headless Edge", checked = true, flags = {"size:", "scale:", "step:", "font:", "out-dir:"}, run = proc(args: []string) -> int { return toolbox.done(run_emoji_board(args)) }},
	{name = "gen_lucide", usage = ": src/lucide/lucide.odin from lucide.ttf, a constant per icon", checked = true, run = proc(args: []string) -> int { return toolbox.done(run_gen_lucide(args)) }},
	{name = "release", usage = "<patch|minor|major|x.y.z> [-summary:text] [-no-push]: publishes a version of the toolkit (release.odin)", checked = true, flags = {"summary:", "no-push"}, positionals = 1, run = proc(args: []string) -> int { return toolbox.done(run_release(args)) }},
	{name = "build", usage = "[example] [-debug]: an example (default fidget) -> build/<example>, optimized or with debug information", checked = true, flags = {"debug"}, positionals = -1, run = proc(args: []string) -> int { return toolbox.done(run_build(args)) }},
	{name = "site_docs", usage = "<site> <out>: every docs/*.md as a page of <out>/docs, docs/_nav.txt the menu", checked = true, positionals = 2, run = proc(args: []string) -> int { return toolbox.done(run_site_docs(args)) }},
	{name = "site_build", usage = "<site> <out>: the site as published (site_changelog, site_meta, site_docs), then its links", checked = true, positionals = 2, run = proc(args: []string) -> int { return toolbox.done(run_site_build(args)) }},
	{name = "site_changelog", usage = "<site> <out>: a copy of <site> with the history from CHANGELOG.md and the classic pages", checked = true, positionals = 2, run = proc(args: []string) -> int { return toolbox.done(run_site_changelog(args)) }},
	{name = "site_meta", usage = "<site> <out>: what each page says when shared, the feed, the sitemap, the files around the pages", checked = true, positionals = 2, run = proc(args: []string) -> int { return toolbox.done(run_site_meta(args)) }},
	{name = "site_card", usage = ": draws site/img/card.png in a local Chromium, once, by hand", checked = true, run = proc(args: []string) -> int { return toolbox.done(run_site_card(args)) }},
	{name = "site_check", usage = "[--site folder] [--shot file.png] [--browser program]: the site's pages in Chrome or Edge with no window", run = proc(args: []string) -> int { return toolbox.done(run_site_check(args)) }},
	{name = "cdp", usage = "[--port 9222] <command> [args] [, <command> [args]]...: drives a toolkit window over the DevTools protocol (cdp.odin)", run = proc(args: []string) -> int { return toolbox.done(run_cdp(args)) }},
	{name = "screenshots", usage = "[-build] [-only:a,b] [-width:1400]: docs/screenshots and site/img from the examples, their own frames", checked = true, flags = {"build", "only:", "width:"}, run = proc(args: []string) -> int { return toolbox.done(run_screenshots(args)) }},
	{name = "theme_shots", usage = "[-build] [-out:dir] [-page:Find] [-find:the] [-only:a,b]: examples/whatsnew in every named palette", checked = true, flags = {"build", "out:", "page:", "find:", "only:"}, run = proc(args: []string) -> int { return toolbox.done(run_theme_shots(args)) }},
	{name = "finish_shots", usage = "[-build] [-out:dir] [-page:0] [-theme:0]: fidget's page in every finish", checked = true, flags = {"build", "out:", "page:", "theme:"}, run = proc(args: []string) -> int { return toolbox.done(run_finish_shots(args)) }},
	{name = "timeline_test", usage = "[-exe:file] [-out:dir] [-port:9477]: the timelines of src/cdp against examples/whatsnew --headless", checked = true, flags = {"exe:", "out:", "port:"}, run = proc(args: []string) -> int { return toolbox.done(run_timeline_test(args)) }},
	{name = "doc_check", usage = "[--root folder] [--extra folder]...: the files, flags and names the documentation cites exist", run = proc(args: []string) -> int { return toolbox.done(run_doc_check(args)) }},
	{name = "ci", usage = ": what the CI checks on this system: odin check of every package, the examples, the tests", checked = true, run = proc(args: []string) -> int { return toolbox.done(run_ci(args)) }},
	{name = "desktop_tests", usage = "[x11|randr|wayland]: Linux: the backends against real servers on a virtual desktop nobody sees", checked = true, positionals = -1, run = proc(args: []string) -> int { return toolbox.done(run_desktop_tests(args)) }},
}

// (each command's work says why it fails; done turns that into the exit code and says it as "tk <command>: why")
main :: proc() {
	toolbox.tool_main("tk", COMMANDS[:])
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

run_build_text :: proc(args: []string) -> string { return build_rust_lib(toolkit_root(), TEXT_LIB, toolbox.has_flag(args, "force")) }
run_build_a11y :: proc(args: []string) -> string { return build_rust_lib(toolkit_root(), A11Y_LIB, toolbox.has_flag(args, "force")) }
run_build_mermaid :: proc(args: []string) -> string { return build_rust_lib(toolkit_root(), MERMAID_LIB, toolbox.has_flag(args, "force")) }
run_build_naga :: proc(args: []string) -> string { return build_naga(toolkit_root()) }

run_fetch_emoji :: proc(args: []string) -> string {
	return fetch_emoji({dest = toolbox.flag_value(args, "dest", join({toolkit_root(), EMOJI_DEST})), unicode = toolbox.has_flag(args, "unicode")})
}

run_fetch_wgpu :: proc(args: []string) -> string {
	return fetch_wgpu({dest = toolbox.flag_value(args, "dest", join({toolkit_root(), "build"})), no_dxc = toolbox.has_flag(args, "no-dxc"), odin = toolbox.flag_value(args, "odin", "odin")})
}

run_gen_emoji_data :: proc(args: []string) -> string {
	root := toolkit_root()
	return gen_emoji_data(root, toolbox.flag_value(args, "data", join({root, EMOJI_DEST, "emoji-data.txt"})))
}

run_make_icon :: proc(args: []string) -> string {
	png, out := toolbox.flag_value(args, "png"), toolbox.flag_value(args, "out")
	if png == "" || out == "" { return "-png:<logo.png> and -out:<icon.ico> are both needed" }
	return make_icon(png, out)
}

run_make_logo :: proc(args: []string) -> string {
	return make_logo(toolbox.flag_value(args, "out", join({toolkit_root(), LOGO_DEFAULT_OUT})))
}

run_ppm_diff :: proc(args: []string) -> string {
	tolerance, why := toolbox.int_flag(args, "tolerance", PPM_TOLERANCE)
	if why != "" { return why }
	d: Ppm_Diff
	d, why = ppm_diff_files(toolbox.plain_args(args)[0], toolbox.plain_args(args)[1], tolerance)
	if why != "" { return why }
	fmt.printfln("%dx%d: max %d, mean %.3f, pixels over %d: %d", d.w, d.h, d.max, d.mean, tolerance, d.over)
	return ""
}

run_emoji_board :: proc(args: []string) -> string {
	o := Board_Options{font = toolbox.flag_value(args, "font"), out_dir = toolbox.flag_value(args, "out-dir")}
	why: string
	if o.size, why = toolbox.int_flag(args, "size", BOARD_SIZE); why != "" { return why }
	if o.scale, why = toolbox.f64_flag(args, "scale", BOARD_SCALE); why != "" { return why }
	if o.step, why = toolbox.int_flag(args, "step", BOARD_STEP); why != "" { return why }
	if o.step < 1 { return "-step: at least 1" }
	return emoji_board(toolkit_root(), o)
}

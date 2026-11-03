// tk: the toolkit's tools that build, fetch and draw what the code needs, one program with a command each.
//   odin run tools/tk -- <command> [flags]        (or odin build tools/tk -out:build/tk.exe once, then build/tk <command>)
//
//   build_text [-force]                       the native text backend (native/text, cargo) -> build/text/gt_text.lib; nothing to do
//                                             when build/text/STAMP is the hash of the crate's sources, Cargo.lock and tools/tk/native.odin
//   build_a11y [-force]                       the AccessKit adapter (native/a11y) -> build/a11y/gt_a11y.lib, the same way
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
//   make_icon -png:file -out:file             a multi-size .ico (PNG, 16 to 256 px) from the 512 px logo (Windows: GDI+)
//   make_logo [-out:file]                     draws the logo, 512 px (default .project/image.png; Windows: GDI+)
//   ppm_diff a.ppm b.ppm [-tolerance:2]       two P6 PPM files (tools/render_probe): the largest and mean difference of a channel, and
//                                             how many pixels differ by more than the tolerance
//   emoji_board [-size:32] [-scale:1] [-step:37] [-font:ttf] [-out-dir:dir]
//                                             the COLR interpreter against a headless Edge on the same font (tools/colrboard): every
//                                             step-th emoji of emoji-test.txt and a few hard ones -> <out-dir>/side.png and the numbers
// A relative path given is the working directory's; the defaults are in the toolkit's checkout (two folders above this file), from
// wherever tk runs, except emoji_board's, which runs in the checkout. Every download is checked against its SHA-256 before it is used.
// Exit code 0 when the work is done, 1 when it failed, 2 for a command line it does not understand. tests/tk calls the procedures below.
package tk

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// What a stamp file ends with, as PowerShell's Set-Content wrote them (the ones already built stay valid).
NEWLINE :: "\r\n" when ODIN_OS == .Windows else "\n"
// Exit codes.
EXIT_FAILED :: 1
EXIT_USAGE :: 2

Command :: struct {
	name:        string,
	flags:       []string,                 // what it takes: "name" a switch, "name:" a flag with a value
	positionals: int,                      // how many plain arguments it takes
	run:         proc(a: ^Args) -> string, // "" when the work is done, else why it is not
}

COMMANDS := []Command {
	{name = "build_text", flags = {"force"}, run = run_build_text},
	{name = "build_a11y", flags = {"force"}, run = run_build_a11y},
	{name = "build_naga", run = run_build_naga},
	{name = "fetch_emoji", flags = {"dest:", "unicode"}, run = run_fetch_emoji},
	{name = "fetch_wgpu", flags = {"dest:", "no-dxc", "odin:"}, run = run_fetch_wgpu},
	{name = "gen_emoji_data", flags = {"data:"}, run = run_gen_emoji_data},
	{name = "make_icon", flags = {"png:", "out:"}, run = run_make_icon},
	{name = "make_logo", flags = {"out:"}, run = run_make_logo},
	{name = "ppm_diff", flags = {"tolerance:"}, positionals = 2, run = run_ppm_diff},
	{name = "emoji_board", flags = {"size:", "scale:", "step:", "font:", "out-dir:"}, run = run_emoji_board},
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
	a, why := parse(os.args[1:])
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
	if len(a.positionals) != a.command.positionals {
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

sha256_hex :: proc(data: []byte) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	digest: [sha2.DIGEST_SIZE_256]byte
	sha2.final(&ctx, digest[:])
	return string(hex.encode(digest[:], context.temp_allocator))
}

// The SHA-256 of a file, in lower case. ok = false: it cannot be read.
sha256_file :: proc(path: string) -> (sum: string, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return "", false }
	defer delete(data)
	return sha256_hex(data), true
}

// Runs a program, its output on this one's. `dir`: its working directory ("" this one's).
run :: proc(command: []string, dir := "") -> bool {
	p, err := os.process_start({command = command, working_dir = dir, stdout = os.stdout, stderr = os.stderr})
	if err != nil { return false }
	st, werr := os.process_wait(p)
	return werr == nil && st.exited && st.exit_code == 0
}

// Runs a program, its output returned.
capture :: proc(command: []string) -> (out: string, ok: bool) {
	st, stdout, _, err := os.process_exec({command = command}, context.temp_allocator)
	return string(stdout), err == nil && st.exited && st.exit_code == 0
}

// `path` as pinned: kept when its SHA-256 is `sha256`, else downloaded from `url` and checked (a file that does not match is removed).
download_pinned :: proc(url, path, sha256: string, quiet := false) -> string {
	if got, ok := sha256_file(path); !ok || got != sha256 {
		if !quiet { fmt.printfln("downloading %s", url) }
		if !run({system_program("curl"), "-fsSL", "-o", path, url}) {
			_ = os.remove(path)
			return fmt.tprintf("downloading %s failed", url)
		}
	}
	got, _ := sha256_file(path)
	if got != sha256 {
		_ = os.remove(path)
		return fmt.tprintf("%s: SHA-256 mismatch (%s, expected %s)", filepath.base(path), got, sha256)
	}
	return ""
}

// Unpacks a zip archive into `dir`.
unzip :: proc(zip, dir: string) -> bool {
	when ODIN_OS == .Windows {
		return run({system_program("tar"), "-xf", zip, "-C", dir})   // (bsdtar, which reads zip archives)
	} else {
		return run({"unzip", "-qo", zip, "-d", dir})
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

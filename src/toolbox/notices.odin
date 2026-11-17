package tk_toolbox

import cli "../cli"

// THIRD-PARTY-NOTICES: the licences of what a program's executable holds besides its own code, as a binary's distribution
// must give them:
//
//   - gui_toolkit (MIT) and its attributions (NOTICE.md), the fonts it embeds (Roboto, Inconsolata), Lucide's icons;
//   - Odin's core library (the compiler's root, `odin root`);
//   - wgpu-native (MIT or Apache-2.0), linked statically (its release archive has no licence: the texts are kept here);
//   - the works the program states (Project.works): a library it links or a font it embeds, with its licence's text;
//   - the Rust crates of the toolkit's native libraries the program links (native_crates of Project.features) and of its
//     own (Project.crates): those a library's build links (not its build scripts' crates, not a procedural macro, not a
//     path crate: the program's code or the toolkit's), from `cargo metadata`, each with its licence files.
//
// One file covers every target the program ships (NOTICES_TARGETS): it goes beside each build, and its check must say the
// same on every system. A crate only one system links (windows on Windows) is listed for both: a licence given that a
// binary does not need costs a line, one missing breaks the licence.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../ascii"
import tk_json "../json"

NOTICES_FILE :: "THIRD-PARTY-NOTICES"
// The targets whose crates the notices give: those the programs ship.
@(rodata) NOTICES_TARGETS := [?]string{"x86_64-unknown-linux-gnu", "x86_64-pc-windows-msvc"}
// What a crate's licence files are named, in upper case.
@(rodata) NOTICE_FILE_PREFIXES := [?]string{"LICENSE", "LICENCE", "COPYING", "NOTICE", "PATENTS"}

@(private = "file") WGPU_MIT    :: #load("licences/wgpu-native-LICENSE.MIT", string)
@(private = "file") WGPU_APACHE :: #load("licences/wgpu-native-LICENSE.APACHE", string)
@(private = "file") NOTICE_RULE :: "================================================================================"

// A work the executable holds and its licence's texts.
Notice_Work :: struct {
	name, licence: string,
	texts:         []string,
}

// A work a program states (Project.works): its licence's text is the file `file` (relative to the project's root) or
// `text`, one of them.
Project_Work :: struct {
	name, licence: string,
	file, text:    string,
	// a crate's name: this text is that crate's licence, for a crate that ships no licence file (webview2-com: its
	// repository has one, its package none). It is listed with the crates, not as a work
	crate:         string,
}

// A Rust crate linked into the executable.
Notice_Crate :: struct {
	name, version, licence: string,
	texts:                  []string,
}

// The toolkit's files of a notice: the work, its licence, the file in the toolkit's checkout.
@(rodata) TOOLKIT_NOTICES := [?][3]string{
	{"gui_toolkit", "MIT", "LICENSE"},
	{"gui_toolkit's attributions (the RAD Debugger's design, MIT; Slug's shader, MIT)", "MIT", "NOTICE.md"},
	{"Roboto (the embedded interface font)", "Apache-2.0", "src/font/data/Roboto-LICENSE.txt"},
	{"Inconsolata (the embedded monospace font)", "OFL-1.1", "src/font/data/Inconsolata-OFL.txt"},
	{"Lucide (the icons)", "ISC", "src/lucide/LICENSE.txt"},
	{"The Nix snowflake (the setup's screen for a copy from the Nix store)", "CC-BY-4.0", "src/setup/nix-snowflake-LICENSE.txt"},
}

// The licence texts of crates the toolkit links that ship no licence file in their package (their repositories have
// them), in the toolkit's checkout: a crate's name, then its files. A program never states them itself.
@(rodata) ACCESSKIT_LICENCE_FILES := [?]string{"native/a11y/licences/accesskit-LICENSE-MIT", "native/a11y/licences/accesskit-LICENSE-APACHE", "native/a11y/licences/accesskit-LICENSE.chromium"}
// (alloc-stdlib: hayro's Brotli decoder's; alloc-no-stdlib, of the same repository, ships the text)
@(rodata) ALLOC_STDLIB_LICENCE_FILES := [?]string{"native/pdf/licences/alloc-stdlib-LICENSE"}
TOOLKIT_CRATE_LICENCES := [?]struct{ crate: string, files: []string }{
	{"accesskit", ACCESSKIT_LICENCE_FILES[:]},
	{"accesskit_consumer", ACCESSKIT_LICENCE_FILES[:]},
	{"accesskit_windows", ACCESSKIT_LICENCE_FILES[:]},
	{"alloc-stdlib", ALLOC_STDLIB_LICENCE_FILES[:]},
}

// The `notices` command of a project's tool: `notices` writes THIRD-PARTY-NOTICES, `notices --check` fails when it is not
// what it would write (`p` copied).
notices_command :: proc(p: Project) -> Command {
	return {name = "notices", usage = "[--check]: " + NOTICES_FILE + ", the licences of the toolkit, its fonts and icons, Odin's core library, wgpu-native, the program's works and the native libraries' crates", run_with = notices_run, user = new_clone(p)}
}

@(private = "file")
notices_run :: proc(args: []string, user: rawptr) -> cli.Exit {
	if len(args) > 1 || len(args) == 1 && args[0] != "--check" { fmt.eprintln("notices [--check]"); return .Usage }
	return done(third_party_notices((^Project)(user)^, NOTICES_FILE, len(args) == 1))
}

// Where two texts part, for a person: the first line that differs, as each has it.
@(private)
first_difference :: proc(old, new: string) -> string {
	a, b := old, new
	for n := 1; ; n += 1 {
		la, more_a := strings.split_lines_iterator(&a)
		lb, more_b := strings.split_lines_iterator(&b)
		if !more_a && !more_b { return "they differ in their ends of line" }
		if la != lb || more_a != more_b { return fmt.tprintf("line %d is %q, would be %q", n, la, lb) }
	}
}

// Writes the notices of the project's executable at `out`, or with `check_only` says whether `out` is what it would write.
// why: "" when it is written (or up to date).
third_party_notices :: proc(p: Project, out: string, check_only := false) -> (why: string) {
	gt := toolkit_dir(p)
	works := make([dynamic]Notice_Work, context.temp_allocator)
	for f in TOOLKIT_NOTICES {
		data, err := os.read_entire_file(fmt.tprintf("%s/%s", gt, f[2]), context.temp_allocator)
		if err != nil { return fmt.tprintf("%s/%s cannot be read", gt, f[2]) }
		append(&works, Notice_Work{f[0], f[1], slice.clone([]string{string(data)}, context.temp_allocator)})
	}
	root, code := capture({"odin", "root"})
	odin_licence := fmt.tprintf("%s/LICENSE", strings.trim_right(strings.trim_space(root), "/\\"))
	odin_text, oerr := os.read_entire_file(odin_licence, context.temp_allocator)
	if code != 0 || oerr != nil { return fmt.tprintf("Odin's licence cannot be read (%s)", odin_licence) }
	append(&works, Notice_Work{"Odin's core library", "BSD-3-Clause", slice.clone([]string{string(odin_text)}, context.temp_allocator)})
	append(&works, Notice_Work{"wgpu-native (wgpu, naga)", "MIT OR Apache-2.0", slice.clone([]string{WGPU_MIT, WGPU_APACHE}, context.temp_allocator)})
	given := make(map[string]string, 8, context.temp_allocator)   // a crate's name: the licence text the program gives it
	for c in TOOLKIT_CRATE_LICENCES {
		texts := make([dynamic]string, context.temp_allocator)
		for f in c.files {
			data, err := os.read_entire_file(fmt.tprintf("%s/%s", gt, f), context.temp_allocator)
			if err != nil { return fmt.tprintf("%s/%s cannot be read", gt, f) }
			append(&texts, string(data))
		}
		given[c.crate] = strings.join(texts[:], "\n\n", context.temp_allocator)
	}
	for w in p.works {
		if (w.file == "") == (w.text == "") { return fmt.tprintf("the work %s states neither or both of a licence file and a text", w.name) }
		text := w.text
		if w.file != "" {
			data, err := os.read_entire_file(w.file, context.temp_allocator)
			if err != nil { return fmt.tprintf("%s (the licence of %s) cannot be read", w.file, w.name) }
			text = string(data)
		}
		if w.crate != "" { given[w.crate] = text; continue }
		append(&works, Notice_Work{w.name, w.licence, slice.clone([]string{text}, context.temp_allocator)})
	}

	crates := make([dynamic]Notice_Crate, context.temp_allocator)
	// The libraries as the file names them, and their manifests.
	libraries := make([dynamic]string, context.temp_allocator)
	manifests := make([dynamic]string, context.temp_allocator)
	for dir in native_crates(p.features) {
		append(&libraries, fmt.tprintf("gui_toolkit's %s", dir))
		append(&manifests, fmt.tprintf("%s/%s/Cargo.toml", gt, dir))
	}
	for m in p.crates {
		append(&libraries, dir_of(m))
		append(&manifests, m)
	}
	for manifest in manifests {
		cmd := make([dynamic]string, context.temp_allocator)
		// (not --offline: a system's build fetches only its own target's crates, and the file needs every target's)
		append(&cmd, "cargo", "metadata", "--format-version", "1", "--locked", "--manifest-path", manifest)
		for target in NOTICES_TARGETS { append(&cmd, "--filter-platform", target) }
		meta, mcode := capture(cmd[:])
		if mcode != 0 { return fmt.tprintf("cargo metadata of %s failed", manifest) }
		linked, cwhy := notices_crates(meta, given)
		if cwhy != "" { return cwhy }
		for c in linked {
			seen := false
			for x in crates { seen ||= x.name == c.name && x.version == c.version }
			if !seen { append(&crates, c) }
		}
	}
	slice.sort_by(crates[:], crate_less)
	text := notices_text(p, works[:], crates[:], libraries[:])
	// (one file for every system: a licence read on Windows may end its lines with CRLF (Odin's own, in its Windows
	// release), the same licence elsewhere with LF; the file is committed with LF)
	text, _ = strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	if check_only {
		old, err := os.read_entire_file(out, context.temp_allocator)
		if err != nil { return fmt.tprintf("%s cannot be read (the notices command writes it)", out) }
		if string(old) != text { return fmt.tprintf("%s is not up to date (the notices command writes it): %s", out, first_difference(string(old), text)) }
		fmt.printfln("%s is up to date", out)
		return ""
	}
	if os.write_entire_file(out, text) != nil { return fmt.tprintf("%s cannot be written", out) }
	fmt.printfln("wrote %s", out)
	return ""
}

// The text of the notices: the list of the works and crates, then each work's texts, then each crate's text once with
// the crates that ship it. libraries: the native libraries whose crates they are, as the list names them.
notices_text :: proc(p: Project, works: []Notice_Work, crates: []Notice_Crate, libraries: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "Third-party notices\n\n")
	fmt.sbprintf(&b, "%s is under the %s licence (LICENSE). Its executable also holds the works below, each under its own\n", p.name, p.licence != "" ? p.licence : "MIT")
	strings.write_string(&b, "licence, whose text follows. This file is written by the notices command of the project's tool.\n\n")
	for w in works { fmt.sbprintf(&b, "- %s: %s\n", w.name, w.licence) }
	if len(crates) > 0 {
		fmt.sbprintf(&b, "- the Rust crates of the native libraries (%s):\n", strings.join(libraries, ", ", context.temp_allocator))
		for c in crates { fmt.sbprintf(&b, "  - %s %s: %s\n", c.name, c.version, c.licence) }
	}
	for w in works {
		fmt.sbprintf(&b, "\n%s\n%s (%s)\n%s\n\n", NOTICE_RULE, w.name, w.licence, NOTICE_RULE)
		for t, i in w.texts {
			if i > 0 { strings.write_string(&b, "\n----\n\n") }
			strings.write_string(&b, strings.trim_space(t))
			strings.write_byte(&b, '\n')
		}
	}
	Group :: struct { text: string, names: [dynamic]string }
	groups := make([dynamic]Group, context.temp_allocator)
	at := make(map[string]int, 64, context.temp_allocator)
	for c in crates {
		for t in c.texts {
			key := sha256_hex(transmute([]u8)strings.trim_space(t))
			k, seen := at[key]
			if !seen {
				k = len(groups)
				at[key] = k
				append(&groups, Group{text = t, names = make([dynamic]string, context.temp_allocator)})
			}
			name := fmt.tprintf("%s %s", c.name, c.version)
			if !slice.contains(groups[k].names[:], name) { append(&groups[k].names, name) }
		}
	}
	for g in groups {
		fmt.sbprintf(&b, "\n%s\n%s\n%s\n\n%s\n", NOTICE_RULE, strings.join(g.names[:], ", ", context.temp_allocator), NOTICE_RULE, strings.trim_space(g.text))
	}
	return strings.to_string(b)
}

// The crates a library links, from its `cargo metadata` (JSON): from its own package, the dependencies of the normal kind
// (not a build script's, not a test's, not a procedural macro), crate after crate, but the path crates; each with its licence files (those
// named NOTICE_FILE_PREFIXES, and the file its manifest names), sorted by name; a crate that ships none takes the text
// `given` holds for its name (Project_Work.crate). why: the metadata cannot be read, or crates ship no licence file and
// none is given (every one named).
notices_crates :: proc(metadata: string, given: map[string]string = nil) -> (out: []Notice_Crate, why: string) {
	root, err := json.parse_string(metadata, allocator = context.temp_allocator)
	if err != nil { return nil, "cargo metadata's output cannot be read" }
	by_id := make(map[string]json.Value, 128, context.temp_allocator)
	for p in tk_json.array(root, "packages") { by_id[tk_json.text(p, "id")] = p }
	nodes := make(map[string]json.Value, 128, context.temp_allocator)
	for n in tk_json.array(root, "resolve", "nodes") { nodes[tk_json.text(n, "id")] = n }
	linked := make(map[string]bool, 128, context.temp_allocator)
	todo := make([dynamic]string, context.temp_allocator)
	append(&todo, tk_json.text(root, "resolve", "root"))
	for len(todo) > 0 {
		id := pop(&todo)
		for dep in tk_json.array(nodes[id], "deps") {
			normal := false
			for k in tk_json.array(dep, "dep_kinds") {
				// (a normal dependency's kind is an explicit null; a missing kind is none)
				if _, is_null := tk_json.get(k, "kind").(json.Null); is_null { normal = true }
			}
			pkg := tk_json.text(dep, "pkg")
			// (a procedural macro runs in the compiler: none of it is linked)
			if !normal || linked[pkg] || proc_macro(by_id[pkg]) { continue }
			linked[pkg] = true
			append(&todo, pkg)
		}
	}
	list := make([dynamic]Notice_Crate, context.temp_allocator)
	missing := make([dynamic]string, context.temp_allocator)   // (all of them in one answer, not one per run)
	for id in linked {
		p := by_id[id]
		// (a path crate has no source: the program's code or the toolkit's, whose licences the file gives already. Its
		// crates were walked above. A third party's crate kept in a project is one of the program's works)
		if tk_json.text(p, "source") == "" { continue }
		folder := os.dir(tk_json.text(p, "manifest_path"))
		names := make([dynamic]string, context.temp_allocator)
		licence_files :: proc(folder, under: string, names: ^[dynamic]string) {
			fis, ferr := os.read_all_directory_by_path(folder, context.temp_allocator)
			if ferr != nil { return }
			for fi in fis {
				up := ascii.upper(fi.name)
				for prefix in NOTICE_FILE_PREFIXES {
					if strings.has_prefix(up, prefix) { append(names, under == "" ? fi.name : fmt.tprintf("%s/%s", under, fi.name)); break }
				}
			}
		}
		licence_files(folder, "", &names)
		// (a crate that carries another work keeps that work's licence with it, one level down, whatever its root has:
		// libwebp-sys's vendor/COPYING and PATENTS, hayro-font's assets/LICENSE_FOXIT for the fonts it embeds)
		if fis, ferr := os.read_all_directory_by_path(folder, context.temp_allocator); ferr == nil {
			for fi in fis { if fi.type == .Directory { licence_files(fmt.tprintf("%s/%s", folder, fi.name), fi.name, &names) } }
		}
		if lf := tk_json.text(p, "license_file"); lf != "" && !slice.contains(names[:], lf) { append(&names, lf) }
		slice.sort(names[:])
		texts := make([dynamic]string, context.temp_allocator)
		for n in names {
			if data, rerr := os.read_entire_file(fmt.tprintf("%s/%s", folder, n), context.temp_allocator); rerr == nil { append(&texts, string(data)) }
		}
		if len(texts) == 0 {
			if text, ok := given[tk_json.text(p, "name")]; ok {
				append(&texts, text)
			} else {
				append(&missing, fmt.tprintf("%s %s", tk_json.text(p, "name"), tk_json.text(p, "version")))
				continue
			}
		}
		licence := tk_json.text(p, "license")
		append(&list, Notice_Crate{tk_json.text(p, "name"), tk_json.text(p, "version"), licence != "" ? licence : "see its licence file", texts[:]})
	}
	if len(missing) > 0 {
		slice.sort(missing[:])
		return nil, fmt.tprintf("these crates ship no licence file (give each its text: a work with `crate`): %s", strings.join(missing[:], ", ", context.temp_allocator))
	}
	slice.sort_by(list[:], crate_less)
	return list[:], ""
}

@(private = "file")
crate_less :: proc(a, b: Notice_Crate) -> bool { return a.name != b.name ? a.name < b.name : a.version < b.version }

@(private = "file")
proc_macro :: proc(p: json.Value) -> bool {
	for t in tk_json.array(p, "targets") {
		for k in tk_json.array(t, "kind") { if tk_json.text(k) == "proc-macro" { return true } }
	}
	return false
}

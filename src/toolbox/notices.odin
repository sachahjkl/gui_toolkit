package tk_toolbox

// THIRD-PARTY-NOTICES: the licences of what a program's executable holds besides its own code, as a binary's distribution
// must give them:
//
//   - gui_toolkit (MIT) and its attributions (NOTICE.md), the fonts it embeds (Roboto, Inconsolata), Lucide's icons;
//   - Odin's core library (the compiler's root, `odin root`);
//   - wgpu-native (MIT or Apache-2.0), linked statically (its release archive has no licence: the texts are kept here);
//   - the Rust crates of the toolkit's native libraries the program links (native_crates of Project.features): those a library's build
//     links (not its build scripts' crates, not a procedural macro), from `cargo metadata`, each with its licence files.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../ascii"

NOTICES_FILE :: "THIRD-PARTY-NOTICES"
// The target the crates are linked for: this system's.
NOTICES_TARGET :: "x86_64-pc-windows-msvc" when ODIN_OS == .Windows else "x86_64-unknown-linux-gnu"
// What a crate's licence files are named, in upper case.
@(rodata) NOTICE_FILE_PREFIXES := [?]string{"LICENSE", "LICENCE", "COPYING", "NOTICE"}

@(private = "file") WGPU_MIT    :: #load("licences/wgpu-native-LICENSE.MIT", string)
@(private = "file") WGPU_APACHE :: #load("licences/wgpu-native-LICENSE.APACHE", string)
@(private = "file") NOTICE_RULE :: "================================================================================"

// A work the executable holds and its licence's texts.
Notice_Work :: struct {
	name, licence: string,
	texts:         []string,
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
}

// The `notices` command of a project's tool: `notices` writes THIRD-PARTY-NOTICES, `notices --check` fails when it is not
// what it would write (`p` copied).
notices_command :: proc(p: Project) -> Command {
	return {name = "notices", usage = "[--check]: " + NOTICES_FILE + ", the licences of the toolkit, its fonts and icons, Odin's core library, wgpu-native and the native libraries' crates", run_with = notices_run, user = new_clone(p)}
}

@(private = "file")
notices_run :: proc(args: []string, user: rawptr) -> int {
	if len(args) > 1 || len(args) == 1 && args[0] != "--check" { fmt.eprintln("notices [--check]"); return EXIT_USAGE }
	return done(third_party_notices((^Project)(user)^, NOTICES_FILE, len(args) == 1))
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

	crates := make([dynamic]Notice_Crate, context.temp_allocator)
	native := native_crates(p.features)
	for dir in native {
		meta, mcode := capture({"cargo", "metadata", "--format-version", "1", "--locked", "--offline", "--filter-platform", NOTICES_TARGET, "--manifest-path", fmt.tprintf("%s/%s/Cargo.toml", gt, dir)})
		if mcode != 0 { return fmt.tprintf("cargo metadata of %s failed (its crates are fetched by a build)", dir) }
		linked, cwhy := notices_crates(meta)
		if cwhy != "" { return cwhy }
		for c in linked {
			seen := false
			for x in crates { seen ||= x.name == c.name && x.version == c.version }
			if !seen { append(&crates, c) }
		}
	}
	slice.sort_by(crates[:], crate_less)
	text := notices_text(p, works[:], crates[:], native)
	if check_only {
		old, err := os.read_entire_file(out, context.temp_allocator)
		if err != nil || string(old) != text { return fmt.tprintf("%s is not up to date (the notices command writes it)", out) }
		fmt.printfln("%s is up to date", out)
		return ""
	}
	if os.write_entire_file(out, text) != nil { return fmt.tprintf("%s cannot be written", out) }
	fmt.printfln("wrote %s", out)
	return ""
}

// The text of the notices: the list of the works and crates, then each work's texts, then each crate's text once with
// the crates that ship it.
notices_text :: proc(p: Project, works: []Notice_Work, crates: []Notice_Crate, native: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "Third-party notices\n\n")
	fmt.sbprintf(&b, "%s is under the %s licence (LICENSE). Its executable also holds the works below, each under its own\n", p.name, p.licence != "" ? p.licence : "MIT")
	strings.write_string(&b, "licence, whose text follows. This file is written by the notices command of the project's tool.\n\n")
	for w in works { fmt.sbprintf(&b, "- %s: %s\n", w.name, w.licence) }
	if len(crates) > 0 {
		fmt.sbprintf(&b, "- the Rust crates of gui_toolkit's native libraries (%s):\n", strings.join(native, ", ", context.temp_allocator))
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
// (not a build script's, not a test's, not a procedural macro), crate after crate; each with its licence files (those
// named NOTICE_FILE_PREFIXES, and the file its manifest names), sorted by name. why: the metadata cannot be read, or a
// crate ships no licence file.
notices_crates :: proc(metadata: string) -> (out: []Notice_Crate, why: string) {
	root, err := json.parse_string(metadata, allocator = context.temp_allocator)
	if err != nil { return nil, "cargo metadata's output cannot be read" }
	top := root.(json.Object) or_else nil
	packages := top["packages"].(json.Array) or_else nil
	resolve := top["resolve"].(json.Object) or_else nil
	by_id := make(map[string]json.Object, 128, context.temp_allocator)
	for p in packages {
		o := p.(json.Object) or_else nil
		by_id[json_text(o["id"])] = o
	}
	nodes := make(map[string]json.Object, 128, context.temp_allocator)
	for n in resolve["nodes"].(json.Array) or_else nil {
		o := n.(json.Object) or_else nil
		nodes[json_text(o["id"])] = o
	}
	linked := make(map[string]bool, 128, context.temp_allocator)
	todo := make([dynamic]string, context.temp_allocator)
	append(&todo, json_text(resolve["root"]))
	for len(todo) > 0 {
		id := pop(&todo)
		for d in nodes[id]["deps"].(json.Array) or_else nil {
			dep := d.(json.Object) or_else nil
			normal := false
			for k in dep["dep_kinds"].(json.Array) or_else nil {
				if kind, is_obj := k.(json.Object); is_obj { if _, is_null := kind["kind"].(json.Null); is_null { normal = true } }
			}
			pkg := json_text(dep["pkg"])
			// (a procedural macro runs in the compiler: none of it is linked)
			if !normal || linked[pkg] || proc_macro(by_id[pkg]) { continue }
			linked[pkg] = true
			append(&todo, pkg)
		}
	}
	list := make([dynamic]Notice_Crate, context.temp_allocator)
	for id in linked {
		p := by_id[id]
		folder := os.dir(json_text(p["manifest_path"]))
		names := make([dynamic]string, context.temp_allocator)
		if fis, ferr := os.read_all_directory_by_path(folder, context.temp_allocator); ferr == nil {
			for fi in fis {
				up := ascii.upper(fi.name)
				for prefix in NOTICE_FILE_PREFIXES {
					if strings.has_prefix(up, prefix) { append(&names, fi.name); break }
				}
			}
		}
		if lf := json_text(p["license_file"]); lf != "" && !slice.contains(names[:], lf) { append(&names, lf) }
		slice.sort(names[:])
		texts := make([dynamic]string, context.temp_allocator)
		for n in names {
			if data, rerr := os.read_entire_file(fmt.tprintf("%s/%s", folder, n), context.temp_allocator); rerr == nil { append(&texts, string(data)) }
		}
		if len(texts) == 0 { return nil, fmt.tprintf("the crate %s %s ships no licence file", json_text(p["name"]), json_text(p["version"])) }
		licence := json_text(p["license"])
		append(&list, Notice_Crate{json_text(p["name"]), json_text(p["version"]), licence != "" ? licence : "see its licence file", texts[:]})
	}
	slice.sort_by(list[:], crate_less)
	return list[:], ""
}

@(private = "file")
crate_less :: proc(a, b: Notice_Crate) -> bool { return a.name != b.name ? a.name < b.name : a.version < b.version }

@(private = "file")
proc_macro :: proc(p: json.Object) -> bool {
	for t in p["targets"].(json.Array) or_else nil {
		for k in (t.(json.Object) or_else nil)["kind"].(json.Array) or_else nil { if json_text(k) == "proc-macro" { return true } }
	}
	return false
}

@(private = "file")
json_text :: proc(v: json.Value) -> string { return v.(json.String) or_else "" }

// The package-level variables of the toolkit's packages (GLOBALS_DIRS; not the constants, procedures and types: `name :: ...`; those of
// `when` blocks too, every branch, and a procedure's `@(static)` ones), against the list of those allowed (tools/globals_allowed.txt, one line each:
// "<dir>/<file> <name> <class>  # why"). A global that is not in the list fails, and so does one the list names that is gone (the list
// follows the code). The rule (docs/getting-started.md, "Where state lives"): what is one window's or one app's lives in the struct that owns it
// (the Window, the Renderer, ui.State). A global is allowed only as what it is:
//   const     a table: written by the compiler, or once before anything reads it, and never again. Any thread reads it.
//   process   a resource of the process: one whatever the number of apps (a library of the system, a lock, a counter). Any thread may
//             reach it: it is locked or atomic, or the note says which thread it is bound to.
//   thread    @(thread_local): each thread its own (and a global marked so is of this class)
//   test      a test's own
//   odin test tests/globals -vet                                   the check (the sources are read relative to this file, not the cwd)
//   odin test tests/globals -define:GLOBALS_WRITE=true             the list rewritten from the code, keeping the classes known; new
//                                                                  ones get "?": to classify by hand (or to move into their struct)
package globals_test

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

GLOBALS_WRITE :: #config(GLOBALS_WRITE, false)
// The repository, from this file's own place (tests/globals).
ROOT :: #directory + "/../.."
GLOBALS_LIST :: ROOT + "/tools/globals_allowed.txt"
// The packages whose globals are listed, under the repository's src (tools/globals_allowed.txt names them from there).
GLOBALS_DIRS :: [?]string{
	"arena", "ascii", "base", "config", "dbus", "devtools", "draw", "flate", "font", "fsx", "i18n", "instance", "platform", "render", "update",
	"testkit", "testkit/session", "ui",
}
GLOBAL_CLASSES :: [?]string{"const", "process", "thread", "test"}
// What a global not yet classified is given by the write mode.
UNCLASSIFIED :: "?"

Global :: struct { dir, file, name: string, test, thread_local: bool }
Listed :: struct { class, why: string }
List :: struct {
	header: [dynamic]string,
	known:  map[string]Listed,
}

// What the compiler's own parser reads: the top level, its `when` blocks and the procedures' `@(static)` variables; not a struct's fields,
// nor a foreign block's.
find_globals :: proc(found: ^[dynamic]Global, dir: string) {
	entries, err := os.read_all_directory_by_path(fmt.tprintf("%s/src/%s", ROOT, dir), context.temp_allocator)
	if err != nil { return }
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for e in entries {
		if e.type == .Directory || !strings.has_suffix(e.name, ".odin") { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.allocator)
		if rerr != nil { continue }
		file := ast.File{src = string(data), fullpath = e.fullpath}
		p := parser.default_parser({.Optional_Semicolons})
		p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
		p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
		if !parser.parse_file(&p, &file) { fmt.eprintfln("%s does not parse", e.fullpath); continue }
		top_level(found, file.decls[:], dir, e.name, context.allocator)
	}
}

// The variables of a file's top level, and of its `when` blocks (every branch: a global of one system is a global all the same).
@(private = "file")
top_level :: proc(found: ^[dynamic]Global, stmts: []^ast.Stmt, dir, file: string, allocator: mem.Allocator) {
	for decl in stmts {
		#partial switch s in decl.derived_stmt {
		case ^ast.When_Stmt:
			for w := s; w != nil; {
				if b, is_block := w.body.derived_stmt.(^ast.Block_Stmt); is_block { top_level(found, b.stmts, dir, file, allocator) }
				if w.else_stmt == nil { break }
				#partial switch e in w.else_stmt.derived_stmt {
				case ^ast.When_Stmt: w = e; continue
				case ^ast.Block_Stmt: top_level(found, e.stmts, dir, file, allocator)
				}
				break
			}
		case ^ast.Value_Decl:
			if !s.is_mutable {
				// a procedure's `@(static)` variables are globals too: "<proc>.<name>"
				for v, i in s.values {
					lit, is_proc := v.derived_expr.(^ast.Proc_Lit)
					if !is_proc || lit.body == nil || i >= len(s.names) { continue }
					id, is_ident := s.names[i].derived_expr.(^ast.Ident)
					if !is_ident { continue }
					statics := Statics{found = found, dir = dir, file = file, owner = id.name, allocator = allocator}
					visitor := ast.Visitor{visit = visit_statics, data = &statics}
					ast.walk(&visitor, lit.body)
				}
				continue
			}
			add_globals(found, s, dir, file, "", allocator)
		}
	}
}

@(private = "file")
Statics :: struct {
	found:     ^[dynamic]Global,
	dir, file: string,
	owner:     string,
	allocator: mem.Allocator,
}

@(private = "file")
visit_statics :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil { return nil }
	if d, is_decl := node.derived.(^ast.Value_Decl); is_decl && d.is_mutable && has_attribute(d, "static") {
		s := (^Statics)(v.data)
		add_globals(s.found, d, s.dir, s.file, s.owner, s.allocator)
	}
	return v
}

@(private = "file")
add_globals :: proc(found: ^[dynamic]Global, d: ^ast.Value_Decl, dir, file, owner: string, allocator: mem.Allocator) {
	local := has_attribute(d, "thread_local")
	for name in d.names {
		id, is_ident := name.derived_expr.(^ast.Ident)
		if !is_ident { continue }
		full := owner == "" ? id.name : fmt.tprintf("%s.%s", owner, id.name)
		if already_found(found[:], dir, file, full) { continue }
		append(found, Global{dir, strings.clone(file, allocator), strings.clone(full, allocator), strings.has_suffix(file, "_test.odin"), local})
	}
}

// A global of two branches of a `when` is one.
@(private = "file")
already_found :: proc(found: []Global, dir, file, name: string) -> bool {
	for g in found { if g.dir == dir && g.file == file && g.name == name { return true } }
	return false
}

// `@(thread_local)`, `@(static)`, alone or among other attributes (`@(private = "file", thread_local)`).
@(private = "file")
has_attribute :: proc(v: ^ast.Value_Decl, want: string) -> bool {
	for a in v.attributes {
		for elem in a.elems {
			name := elem
			if fv, is_field := elem.derived_expr.(^ast.Field_Value); is_field { name = fv.field }
			if id, is_ident := name.derived_expr.(^ast.Ident); is_ident && id.name == want { return true }
		}
	}
	return false
}

@(private = "file")
global_key :: proc(g: Global) -> string { return strings.concatenate({g.dir, "/", g.file, " ", g.name}) }

@(private = "file")
read_list :: proc() -> (l: List) {
	data, err := os.read_entire_file(GLOBALS_LIST, context.allocator)
	if err != nil { return }
	in_header := true
	text := string(data)
	for raw in strings.split_lines_iterator(&text) {
		line := strings.trim_right(raw, "\r")
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == '#' {
			if in_header && trimmed != "" { append(&l.header, line) }
			continue
		}
		in_header = false
		fields := strings.fields(trimmed)
		if len(fields) < 3 { continue }
		why := ""
		if at := strings.index(trimmed, "#"); at >= 0 { why = strings.trim_space(trimmed[at + 1:]) }
		l.known[strings.concatenate({fields[0], " ", fields[1]})] = {fields[2], why}
	}
	return
}

@(private = "file")
write_list :: proc(t: ^testing.T, l: List, found: []Global) {
	b := strings.builder_make()
	for h in l.header { fmt.sbprintln(&b, h) }
	for g in found {
		c, has := l.known[global_key(g)]
		if !has { c = {g.test ? "test" : (g.thread_local ? "thread" : UNCLASSIFIED), ""} }
		fmt.sbprintf(&b, "%s/%s %s %s", g.dir, g.file, g.name, c.class)
		if c.why != "" { fmt.sbprintf(&b, "  # %s", c.why) }
		fmt.sbprintln(&b)
	}
	testing.expect(t, os.write_entire_file(GLOBALS_LIST, transmute([]u8)strings.to_string(b)) == nil, "tools/globals_allowed.txt written")
	fmt.printfln("%d globals written to %s", len(found), GLOBALS_LIST)
}

@(test)
every_global_is_listed_with_its_class :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	found := make([dynamic]Global)
	for dir in GLOBALS_DIRS { find_globals(&found, dir) }
	testing.expect(t, len(found) > 0, "the sources are found next to this file")
	l := read_list()
	when GLOBALS_WRITE {
		write_list(t, l, found[:])
		return
	}
	classes := GLOBAL_CLASSES
	seen := make(map[string]bool)
	counts := make(map[string]map[string]int)
	for g in found {
		k := global_key(g)
		seen[k] = true
		c, has := l.known[k]
		if g.dir not_in counts { counts[g.dir] = make(map[string]int) }
		per := &counts[g.dir]
		per[has ? c.class : "NEW"] += 1
		switch {
		case !has:
			testing.expectf(t, false, "%s/%s: a new global '%s'. One window's or app's state goes into the struct that owns it; a table, a resource of the process or a thread's is added to tools/globals_allowed.txt with its class and why (docs/getting-started.md, Where state lives)", g.dir, g.file, g.name)
		case !slice.contains(classes[:], c.class):
			testing.expectf(t, false, "tools/globals_allowed.txt gives '%s' the class '%s': it is one of const, process, thread, test", k, c.class)
		case g.thread_local && c.class != "thread":
			testing.expectf(t, false, "%s/%s: '%s' is @(thread_local): its class is thread, not %s", g.dir, g.file, g.name, c.class)
		case !g.thread_local && c.class == "thread":
			testing.expectf(t, false, "%s/%s: '%s' is of the class thread and is not @(thread_local): every thread would share it", g.dir, g.file, g.name)
		}
	}
	for k in l.known {
		testing.expectf(t, k in seen, "tools/globals_allowed.txt names '%s', which is no longer a global: take it out of the list", k)
	}
	out := strings.builder_make()
	fmt.sbprintf(&out, "globals: %d", len(found))
	for dir in GLOBALS_DIRS {
		per, any := counts[dir]
		if !any { continue }
		names := make([dynamic]string, context.temp_allocator)
		total := 0
		for c, n in per { append(&names, c); total += n }
		slice.sort(names[:])
		fmt.sbprintf(&out, "; %s %d (", dir, total)
		for c, i in names { fmt.sbprintf(&out, "%s%s %d", i > 0 ? ", " : "", c, per[c]) }
		fmt.sbprint(&out, ")")
	}
	fmt.println(strings.to_string(out))
}

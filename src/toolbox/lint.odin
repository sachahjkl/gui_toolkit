package tk_toolbox

// Checks of a program's sources that the compiler does not make.

import "core:fmt"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// The toolkit's packages, beside this one: where their scopes are read.
TOOLKIT_SRC_DEFAULT :: #directory + "/.."

// A procedure with a deferred end (`@(deferred_out = section_end) section :: proc ...`): its call opens a scope that ends
// where the scope of the call ends. `dir`: the folder of its package.
Scope :: struct {
	name: string,
	dir:  string,
}

// The words of a comment that pass a misuse on its line: a test that builds the misuse to see what it does.
SCOPE_ON_PURPOSE :: "check_scopes: on purpose"

// A scope opened under a negation: the file's line and the call as written ("debug.section", "row").
Scope_Misuse :: struct {
	line:  int,
	scope: string,
}

// The names of the procedures with a deferred end (any of @(deferred_none), deferred_in, deferred_out, deferred_in_out,
// alone or among other attributes) in the texts of one package's sources, in their order.
scope_names :: proc(sources: []string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for source in sources {
		text := source
		deferred := false
		for line in strings.split_lines_iterator(&text) {
			l := strings.trim_space(line)
			if strings.has_prefix(l, "@(") {
				if strings.contains(l, "deferred_") { deferred = true }
				continue
			}
			if !deferred || l == "" || strings.has_prefix(l, "//") { continue }
			deferred = false
			if i := strings.index(l, " :: proc"); i > 0 { append(&out, l[:i]) }
		}
	}
	return out[:]
}

// The lines of `text` where an `if` opens a scope under a negation: `if !debug.section("x") { continue }` and
// `if ui.menu("m") == false { return }` close the scope at the end of the `if`, and what follows is built outside it.
// The compiler accepts both. `local`: the scopes of the file's own package (called without a package's name);
// `qualified`: every scope's name (called as `pkg.name`). A call assigned first (`open := ui.menu("m")`) is right:
// its scope is the block's. A line whose comment holds SCOPE_ON_PURPOSE is passed (a test of the misuse itself).
scope_misuses :: proc(text: string, local, qualified: []string, allocator := context.temp_allocator) -> []Scope_Misuse {
	toks := make([dynamic]tokenizer.Token, context.temp_allocator)
	passed := make([dynamic]int, context.temp_allocator)
	t: tokenizer.Tokenizer
	tokenizer.init(&t, text, "", proc(pos: tokenizer.Pos, msg: string, args: ..any) {})
	for {
		tok := tokenizer.scan(&t)
		if tok.kind == .EOF { break }
		if tok.kind != .Comment { append(&toks, tok); continue }
		if strings.contains(tok.text, SCOPE_ON_PURPOSE) { append(&passed, tok.pos.line) }
	}
	// the scope called at toks[k] ("" none), and the index of its "("
	call_at :: proc(toks: []tokenizer.Token, k: int, local, qualified: []string) -> (call: string, paren: int) {
		n := len(toks)
		if k + 3 < n && toks[k].kind == .Ident && toks[k + 1].kind == .Period && toks[k + 2].kind == .Ident && toks[k + 3].kind == .Open_Paren {
			if slice.contains(qualified, toks[k + 2].text) { return fmt.tprintf("%s.%s", toks[k].text, toks[k + 2].text), k + 3 }
			return "", -1
		}
		if k + 1 < n && toks[k].kind == .Ident && toks[k + 1].kind == .Open_Paren && (k == 0 || toks[k - 1].kind != .Period) {
			if slice.contains(local, toks[k].text) { return toks[k].text, k + 1 }
		}
		return "", -1
	}
	out := make([dynamic]Scope_Misuse, allocator)
	for i in 0 ..< len(toks) {
		if toks[i].kind != .If || slice.contains(passed[:], toks[i].pos.line) { continue }
		depth := 0
		for k := i + 1; k < len(toks); k += 1 {
			kind := toks[k].kind
			if depth == 0 && (kind == .Open_Brace || kind == .Do) { break }   // (the block: the header ends)
			#partial switch kind {
			case .Open_Paren, .Open_Bracket, .Open_Brace: depth += 1
			case .Close_Paren, .Close_Bracket, .Close_Brace: depth -= 1
			}
			if depth < 0 { break }
			// `!scope(...)`
			if toks[k].kind == .Not {
				if call, _ := call_at(toks[:], k + 1, local, qualified); call != "" { append(&out, Scope_Misuse{toks[k].pos.line, call}) }
				continue
			}
			// `scope(...) == false`, `scope(...) != true`
			call, paren := call_at(toks[:], k, local, qualified)
			if call == "" || (k > 0 && toks[k - 1].kind == .Not) { continue }
			inner, end := 0, -1
			for j in paren ..< len(toks) {
				if toks[j].kind == .Open_Paren { inner += 1 }
				if toks[j].kind == .Close_Paren { inner -= 1; if inner == 0 { end = j; break } }
			}
			if end < 0 || end + 2 >= len(toks) { continue }
			op, v := toks[end + 1], toks[end + 2]
			if (op.kind == .Cmp_Eq && v.text == "false") || (op.kind == .Not_Eq && v.text == "true") {
				append(&out, Scope_Misuse{toks[k].pos.line, call})
			}
		}
	}
	return out[:]
}

// The scopes of every package under `dirs` (each folder a package), each found once.
scopes_in :: proc(dirs: []string, allocator := context.temp_allocator) -> []Scope {
	files := make([dynamic]string, context.temp_allocator)
	for d in dirs { append(&files, ..odin_files(d)) }
	slice.sort(files[:])
	out := make([dynamic]Scope, allocator)
	for f in files {
		data, err := os.read_entire_file(f, context.temp_allocator)
		if err != nil { continue }
		dir := strings.clone(filepath.dir(f), allocator)
		for name in scope_names({string(data)}) {
			s := Scope{strings.clone(name, allocator), dir}
			if !slice.contains(out[:], s) { append(&out, s) }
		}
	}
	return out[:]
}

// Every .odin file under `src_dir` checked for a scope opened under a negation: the scopes of the toolkit's packages (read
// in `toolkit_dir`: ui.menu, debug.section, ...) and of the program's own (read in `src_dir`). Each misuse is said with its
// file and line and the right form. True when there is none.
check_scopes :: proc(src_dir: string, toolkit_dir := TOOLKIT_SRC_DEFAULT) -> bool {
	scopes := scopes_in({toolkit_dir, src_dir})
	if len(scopes) == 0 { fmt.eprintfln("check_scopes: no scope found in %s", toolkit_dir); return false }
	qualified := make([dynamic]string, context.temp_allocator)
	for s in scopes { if !slice.contains(qualified[:], s.name) { append(&qualified, s.name) } }
	ok := true
	for f in odin_files(src_dir) {
		data, err := os.read_entire_file(f, context.temp_allocator)
		if err != nil { fmt.eprintfln("%s cannot be read", f); ok = false; continue }
		dir := filepath.dir(f)
		local := make([dynamic]string, context.temp_allocator)
		for s in scopes { if s.dir == dir { append(&local, s.name) } }
		for m in scope_misuses(string(data), local[:], qualified[:]) {
			fmt.eprintfln("%s:%d: `if !%s(...)` ends its scope at the end of the `if`: what follows is outside it. Build " +
				"inside `if %s(...) {{ ... }}`, or assign it first: `open := %s(...)`, then `if !open {{ ... }}`",
				f, m.line, m.scope, m.scope, m.scope)
			ok = false
		}
	}
	return ok
}

// The .odin files under `dir`, its folders' too, in the order of their paths (a file written from them is the same at
// each run).
@(private)
odin_files :: proc(dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	w := os.walker_create_path(dir)
	defer os.walker_destroy(&w)
	for fi in os.walker_walk(&w) {
		if fi.type != .Directory && strings.has_suffix(fi.name, ".odin") { append(&out, strings.clone(fi.fullpath, context.temp_allocator)) }
	}
	slice.sort(out[:])
	return out[:]
}

// Every angle the toolkit takes or gives is in turns (src/md/infrastructure/angles.md). This test holds the rule: in the
// sources of src (not the _test files, not src/turn), no public declaration speaks of radians or degrees (its name, its
// parameters' and fields' names, the comment above it or beside it), and no code uses math.PI, math.TAU, RAD_PER_DEG,
// DEG_PER_RAD, math.to_radians or math.to_degrees. A file that is a boundary (a system's, a file format's or a shader's
// unit) is listed in tools/angles_allowed.txt with its reason: "<dir>/<file>  # why". A listed file with nothing to
// allow fails too: the list follows the code.
//   odin test tests/angles -collection:gt=src -vet
package angles_test

import "core:fmt"
import vmem "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import ascii "gt:ascii"

// The repository, from this file's own place (tests/angles).
ROOT :: #directory + "/../.."
ANGLES_LIST :: ROOT + "/tools/angles_allowed.txt"
// The package that holds the radians: the only place they are not a boundary.
TURN_DIR :: "turn"
// The words of another unit, compared with a name's or a comment's words, ASCII case folded. Not "rad": the toolkit's
// short name of a radius.
UNIT_WORDS :: [?]string{"radian", "radians", "degree", "degrees", "deg"}
// What code that computes in radians or degrees calls.
UNIT_CODE :: [?]string{"math.PI", "math.TAU", "RAD_PER_DEG", "DEG_PER_RAD", "math.to_radians", "math.to_degrees"}

// A file's sources, cut in lines, and what it found wrong.
Source :: struct {
	path:     string,   // from src: "draw/affine.odin"
	lines:    []string,
	problems: [dynamic]string,
}

// The files of src, recursively, but src/turn and the tests.
find_sources :: proc(found: ^[dynamic]string, dir: string) {
	entries, err := os.read_all_directory_by_path(fmt.tprintf("%s/src/%s", ROOT, dir), context.allocator)
	if err != nil { return }
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for e in entries {
		rel := dir == "" ? e.name : fmt.aprintf("%s/%s", dir, e.name)
		if e.type == .Directory {
			if rel != TURN_DIR { find_sources(found, rel) }
			continue
		}
		if !strings.has_suffix(e.name, ".odin") || strings.has_suffix(e.name, "_test.odin") { continue }
		append(found, rel)
	}
}

// Whether `text` has a word of another unit: words split on what is not a letter or a digit (an underscore splits too:
// `angle_deg` has the word "deg").
has_unit_word :: proc(text: string) -> (word: string, has: bool) {
	words := UNIT_WORDS
	start := -1
	for i in 0 ..= len(text) {
		letter := i < len(text) && (text[i] >= 'a' && text[i] <= 'z' || text[i] >= 'A' && text[i] <= 'Z' || text[i] >= '0' && text[i] <= '9')
		if letter {
			if start < 0 { start = i }
			continue
		}
		if start >= 0 {
			for u in words {
				if ascii.equal_fold(text[start:i], u) { return text[start:i], true }
			}
			start = -1
		}
	}
	return "", false
}

// The comment beside line `n` (1-based) and the comment lines just above it (attributes between them skipped).
comments_at :: proc(src: ^Source, n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	if n >= 1 && n <= len(src.lines) {
		if at := strings.index(src.lines[n - 1], "//"); at >= 0 { strings.write_string(&b, src.lines[n - 1][at:]) }
	}
	for i := n - 2; i >= 0; i -= 1 {
		line := strings.trim_space(src.lines[i])
		// (an attribute alone on its line belongs to the declaration; one before another declaration ends the comment)
		if strings.has_prefix(line, "@(") && !strings.contains(line, "::") { continue }
		if !strings.has_prefix(line, "//") { break }
		strings.write_byte(&b, '\n')
		strings.write_string(&b, line)
	}
	return strings.to_string(b)
}

check_text :: proc(src: ^Source, what, text: string, line: int) {
	if w, has := has_unit_word(text); has {
		append(&src.problems, fmt.aprintf("%s:%d: %s says '%s'", src.path, line, what, w))
	}
}

// A public name, with its comments.
check_named :: proc(src: ^Source, name: string, line: int) {
	check_text(src, fmt.tprintf("'%s'", name), name, line)
	check_text(src, fmt.tprintf("the comment of '%s'", name), comments_at(src, line), line)
}

// Parameters or fields: their names, and the comments of those on a line of their own (the declaration's line and the
// comment above it are the owner's, already read).
check_fields :: proc(src: ^Source, owner: string, owner_line: int, fields: ^ast.Field_List) {
	if fields == nil { return }
	for f in fields.list {
		for n in f.names {
			id, is_ident := n.derived_expr.(^ast.Ident)
			if !is_ident { continue }
			check_text(src, fmt.tprintf("'%s' of '%s'", id.name, owner), id.name, n.pos.line)
			if n.pos.line == owner_line { continue }
			check_text(src, fmt.tprintf("the comment of '%s' of '%s'", id.name, owner), comments_at(src, n.pos.line), n.pos.line)
		}
	}
}

is_private :: proc(v: ^ast.Value_Decl) -> bool {
	for a in v.attributes {
		for elem in a.elems {
			name := elem
			if fv, is_field := elem.derived_expr.(^ast.Field_Value); is_field { name = fv.field }
			if id, is_ident := name.derived_expr.(^ast.Ident); is_ident && id.name == "private" { return true }
		}
	}
	return false
}

check_decls :: proc(src: ^Source, stmts: []^ast.Stmt) {
	for decl in stmts {
		#partial switch s in decl.derived_stmt {
		case ^ast.When_Stmt:
			for w := s; w != nil; {
				if b, is_block := w.body.derived_stmt.(^ast.Block_Stmt); is_block { check_decls(src, b.stmts) }
				if w.else_stmt == nil { break }
				#partial switch e in w.else_stmt.derived_stmt {
				case ^ast.When_Stmt: w = e; continue
				case ^ast.Block_Stmt: check_decls(src, e.stmts)
				}
				break
			}
		case ^ast.Value_Decl:
			if is_private(s) { continue }
			for n, i in s.names {
				id, is_ident := n.derived_expr.(^ast.Ident)
				if !is_ident { continue }
				check_named(src, id.name, n.pos.line)
				if i >= len(s.values) { continue }
				#partial switch v in s.values[i].derived_expr {
				case ^ast.Proc_Lit:
					if v.type != nil {
						check_fields(src, id.name, n.pos.line, v.type.params)
						check_fields(src, id.name, n.pos.line, v.type.results)
					}
				case ^ast.Struct_Type:
					check_fields(src, id.name, n.pos.line, v.fields)
				}
			}
		}
	}
}

check_source :: proc(src: ^Source) {
	data, err := os.read_entire_file(fmt.tprintf("%s/src/%s", ROOT, src.path), context.allocator)
	if err != nil { append(&src.problems, fmt.aprintf("%s: not read", src.path)); return }
	text := string(data)
	src.lines = strings.split_lines(text)
	codes := UNIT_CODE
	private_file := false
	for line, i in src.lines {
		code := line
		if at := strings.index(code, "//"); at >= 0 { code = code[:at] }
		for c in codes {
			if strings.contains(code, c) { append(&src.problems, fmt.aprintf("%s:%d: uses %s", src.path, i + 1, c)) }
		}
		if strings.has_prefix(strings.trim_space(line), "#+private") { private_file = true }
	}
	if private_file { return }
	file := ast.File{src = text, fullpath = src.path}
	p := parser.default_parser({.Optional_Semicolons})
	p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
	p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
	if !parser.parse_file(&p, &file) { append(&src.problems, fmt.aprintf("%s: does not parse", src.path)); return }
	check_decls(src, file.decls[:])
}

// The allowed files: "<dir>/<file>  # why"; a line without its reason is refused.
read_list :: proc(t: ^testing.T) -> map[string]string {
	known := make(map[string]string)
	data, err := os.read_entire_file(ANGLES_LIST, context.allocator)
	if !testing.expectf(t, err == nil, "%s is read", ANGLES_LIST) { return known }
	text := string(data)
	for raw in strings.split_lines_iterator(&text) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' { continue }
		at := strings.index(line, "#")
		why := at >= 0 ? strings.trim_space(line[at + 1:]) : ""
		path := strings.trim_space(at >= 0 ? line[:at] : line)
		testing.expectf(t, why != "", "tools/angles_allowed.txt: '%s' has no reason (\"<dir>/<file>  # why\")", path)
		known[path] = why
	}
	return known
}

@(test)
every_angle_is_in_turns :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	paths := make([dynamic]string)
	find_sources(&paths, "")
	testing.expect(t, len(paths) > 0, "the sources are found next to this file")
	allowed := read_list(t)
	boundaries := 0
	for path in paths {
		src := Source{path = path, problems = make([dynamic]string)}
		check_source(&src)
		_, listed := allowed[path]
		if listed {
			boundaries += 1
			testing.expectf(t, len(src.problems) > 0, "tools/angles_allowed.txt names '%s', which no longer speaks of radians or degrees: take it out of the list", path)
			continue
		}
		for p in src.problems {
			testing.expectf(t, false, "%s. Every angle is in turns (gt:turn); a boundary (a system's, a file format's, a shader's unit) is listed in tools/angles_allowed.txt with its reason", p)
		}
	}
	for path in allowed {
		testing.expectf(t, slice.contains(paths[:], path), "tools/angles_allowed.txt names '%s', which is not a source of src", path)
	}
	fmt.printfln("angles: %d files, %d boundaries", len(paths), boundaries)
}

// The words are matched whole: "radius" and "degraded" are not units, "angle_deg" and "Radians" are.
@(test)
unit_words :: proc(t: ^testing.T) {
	_, has := has_unit_word("radius, rad, degraded, gradient, radial")
	testing.expect(t, !has, "no unit in other words")
	w, has2 := has_unit_word("angle_deg")
	testing.expect(t, has2 && w == "deg", "angle_deg")
	_, has3 := has_unit_word("// A rotation by `turns` (Radians no more)")
	testing.expect(t, has3, "a word in a comment, any case")
}

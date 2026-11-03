// The calls that fold case by Unicode (strings.to_lower, to_upper, equal_fold; unicode.to_lower, to_upper: the Kelvin sign
// U+212A is 'k' to them, the long s U+017F 's') in the toolkit's .odin files, against the list of those meant to
// (tools/unicode_case_allowed.txt, one line each: "<path> <code>  # why", the line of <path> that holds <code>). Names and
// protocols (header names, hosts, font family keys, keywords, enum names, extensions) are ASCII: ascii.lower,
// ascii.equal_fold...; Unicode is for user text (a search, find in page, type-ahead), display text and Windows paths.
// A call the list does not name fails, and so does an entry that matches no line (the list follows the code).
//   odin test tests/unicode_case -vet          (the sources are read relative to this file, not the cwd)
package unicode_case_test

import "core:fmt"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// The repository, from this file's own place (tests/unicode_case).
ROOT :: #directory + "/../.."
LIST :: "tools/unicode_case_allowed.txt"
// Not the toolkit's sources: what the builds leave.
SKIP_DIRS :: [?]string{"build"}
CASE_PACKAGES :: [?]string{"strings", "unicode"}
CASE_PROCS :: [?]string{"to_lower", "to_upper", "equal_fold"}
WHY :: "  # "

Use :: struct { path: string, line: int, code: string }
Entry :: struct { path, code: string, used: bool }

// The lines of `src` (1 the first) that call one of CASE_PROCS of CASE_PACKAGES: in the code, not in a comment or a string.
case_call_lines :: proc(src: string, allocator := context.allocator) -> []int {
	out := make([dynamic]int, allocator)
	t: tokenizer.Tokenizer
	tokenizer.init(&t, src, "", proc(pos: tokenizer.Pos, msg: string, args: ..any) {})
	pkgs, procs := CASE_PACKAGES, CASE_PROCS
	a, b: tokenizer.Token   // the two before
	for {
		c := tokenizer.scan(&t)
		if c.kind == .EOF { break }
		if c.kind == .Comment { continue }
		if a.kind == .Ident && slice.contains(pkgs[:], a.text) && b.kind == .Period && c.kind == .Ident && slice.contains(procs[:], c.text) {
			if len(out) == 0 || out[len(out) - 1] != a.pos.line { append(&out, a.pos.line) }
		}
		a, b = b, c
	}
	return out[:]
}

find_uses :: proc(found: ^[dynamic]Use, rel: string) {
	entries, err := os.read_all_directory_by_path(fmt.tprintf("%s/%s", ROOT, rel), context.temp_allocator)
	if err != nil { return }
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	skip := SKIP_DIRS
	for e in entries {
		path := rel == "" ? e.name : strings.concatenate({rel, "/", e.name})
		if e.type == .Directory {
			if !strings.has_prefix(e.name, ".") && !(rel == "" && slice.contains(skip[:], e.name)) { find_uses(found, path) }
			continue
		}
		if !strings.has_suffix(e.name, ".odin") { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.allocator)
		if rerr != nil { continue }
		lines := strings.split_lines(string(data))
		for n in case_call_lines(string(data)) { append(found, Use{path, n, strings.trim_space(lines[n - 1])}) }
	}
}

// The entries of the list ('#' lines are comments), and the lines that are no "<path> <code>  # why" whose code calls one.
parse_list :: proc(text: string) -> (entries: [dynamic]Entry, bad: [dynamic]string) {
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' { continue }
		sp := strings.index_byte(line, ' ')
		why := strings.last_index(line, WHY)
		if sp < 0 || why <= sp || strings.trim_space(line[why + len(WHY):]) == "" || len(case_call_lines(line[sp:why])) == 0 {
			append(&bad, line)
			continue
		}
		append(&entries, Entry{path = line[:sp], code = strings.trim_space(line[sp:why])})
	}
	return
}

@(test)
unicode_case_calls_are_listed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	data, err := os.read_entire_file(ROOT + "/" + LIST, context.allocator)
	if !testing.expectf(t, err == nil, "%s: %v", LIST, err) { return }
	entries, bad := parse_list(string(data))
	for b in bad { testing.expectf(t, false, "%s: '%s' is no \"<path> <code>  # why\" whose code calls a Unicode case procedure", LIST, b) }
	uses: [dynamic]Use
	find_uses(&uses, "")
	testing.expect(t, len(uses) > 0, "no call found: the sources were not read")
	for u in uses {
		listed := false
		for &e in entries {
			if e.path == u.path && strings.contains(u.code, e.code) { e.used, listed = true, true }
		}
		testing.expectf(t, listed, "%s(%d): '%s' folds by Unicode; a name or a protocol wants ascii.lower, ascii.equal_fold...; user text goes in %s with why", u.path, u.line, u.code, LIST)
	}
	for e in entries { testing.expectf(t, e.used, "%s: '%s %s' matches no line of the code: drop it", LIST, e.path, e.code) }
}

// A call is found in the code, not in a comment or a string, nor a procedure of another package of the same name.
@(test)
a_call_is_code_alone :: proc(t: ^testing.T) {
	src := "a := strings.to_lower(x)\n" +
		"// strings.equal_fold(a, b)\n" +
		"s := \"unicode.to_upper(r)\"; r := `strings.to_upper(s)`\n" +
		"b := ascii.lower(x); c := my_strings.to_lower(x)\n" +
		"if strings.equal_fold(a, b) && unicode.to_upper(r) == 'K' { /* strings.to_lower(x) */ }\n"
	lines := case_call_lines(src, context.temp_allocator)
	testing.expect(t, slice.equal(lines, []int{1, 5}), fmt.tprint(lines))
}

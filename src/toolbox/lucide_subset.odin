package tk_toolbox

// The Lucide icons a program draws, and the font of only those: its build passes the file to the toolkit's lucide package
// (-define:LUCIDE_SUBSET=<absolute path>), whose DATA is then that font instead of all of lucide.ttf.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// Where a project's subset of the Lucide font is written, in the project.
LUCIDE_SUBSET_FILE :: "build/lucide_subset.ttf"
// The package name of the toolkit's lucide package: what a file that imports it with no alias names it by.
@(private = "file")
LUCIDE_PACKAGE :: "tk_lucide"

// The Lucide icons the Odin sources under `dirs` name, sorted, each once: every `<name>.ICON` of a file that imports the
// toolkit's lucide package as <name> (its own name, tk_lucide, without an alias). A name that is not an icon (DATA) is
// there too: lucide_codes leaves it out. An icon a program reaches otherwise (its character written out) is not seen.
lucide_names_used :: proc(dirs: []string, allocator := context.temp_allocator) -> []string {
	seen := make(map[string]bool, context.temp_allocator)
	for dir in dirs {
		w := os.walker_create_path(dir)
		for fi in os.walker_walk(&w) {
			if fi.type == .Directory || !strings.has_suffix(fi.name, ".odin") { continue }
			text, err := os.read_entire_file(fi.fullpath, context.temp_allocator)
			if err != nil { continue }
			for name in lucide_names_in(string(text)) { seen[name] = true }
		}
		os.walker_destroy(&w)
	}
	out := make([dynamic]string, 0, len(seen), allocator)
	for name in seen { append(&out, strings.clone(name, allocator)) }
	slice.sort(out[:])
	return out[:]
}

// The names one Odin source takes from the lucide package (lucide_names_used), in the order met, with repeats.
lucide_names_in :: proc(text: string) -> []string {
	aliases := make([dynamic]string, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "@(require)") { l = strings.trim_space(l[len("@(require)"):]) }
		if !strings.has_prefix(l, "import ") { continue }
		l = strings.trim_space(l[len("import "):])
		q := strings.index_byte(l, '"')
		if q < 0 { continue }
		end := strings.index_byte(l[q + 1:], '"')
		if end < 0 { continue }
		path := l[q + 1:q + 1 + end]
		if !strings.has_suffix(path, "/lucide") && !strings.has_suffix(path, ":lucide") { continue }
		alias := strings.trim_space(l[:q])
		append(&aliases, alias != "" ? alias : LUCIDE_PACKAGE)
	}
	out := make([dynamic]string, context.temp_allocator)
	for alias in aliases {
		for at := 0; true; /**/ {
			i := strings.index(text[at:], alias)
			if i < 0 { break }
			i += at
			at = i + len(alias)
			if i > 0 && is_ident_byte(text[i - 1]) { continue }
			if at >= len(text) || text[at] != '.' { continue }
			e := at + 1
			for e < len(text) && is_ident_byte(text[e]) { e += 1 }
			if e > at + 1 { append(&out, text[at + 1:e]) }
		}
	}
	return out[:]
}

@(private = "file")
is_ident_byte :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// The characters of the icons `names`, as the toolkit's lucide.odin (`source`) defines them (`NAME :: "\uXXXX"`); a name
// it does not define as an icon is left out.
lucide_codes :: proc(source: string, names: []string, allocator := context.temp_allocator) -> []rune {
	table := make(map[string]rune, context.temp_allocator)
	rest := source
	for line in strings.split_lines_iterator(&rest) {
		sep := strings.index(line, "::")
		if sep <= 0 { continue }
		name := strings.trim_space(line[:sep])
		value := strings.trim_space(line[sep + 2:])
		if !strings.has_prefix(value, `"\u`) || len(value) < 8 { continue }
		hex := value[3:]
		if end := strings.index_byte(hex, '"'); end > 0 { hex = hex[:end] } else { continue }
		code, ok := strconv.parse_int(hex, 16)
		if ok { table[name] = rune(code) }
	}
	out := make([dynamic]rune, allocator)
	for n in names { if c, ok := table[n]; ok { append(&out, c) } }
	return out[:]
}

// Writes the project's subset of the Lucide font at LUCIDE_SUBSET_FILE (in the working directory, the project's root): the
// icons named by the program's sources and the toolkit's (lucide_names_used). path: its absolute path, for
// -define:LUCIDE_SUBSET=<path>.
lucide_subset :: proc(p: Project) -> (path: string, why: string) {
	gt := toolkit_dir(p)
	ttf := fmt.tprintf("%s/src/lucide/lucide.ttf", gt)
	odin := fmt.tprintf("%s/src/lucide/lucide.odin", gt)
	font, ferr := os.read_entire_file(ttf, context.temp_allocator)
	if ferr != nil { return "", fmt.tprintf("%s cannot be read", ttf) }
	source, serr := os.read_entire_file(odin, context.temp_allocator)
	if serr != nil { return "", fmt.tprintf("%s cannot be read", odin) }
	codes := lucide_codes(string(source), lucide_names_used({project_src(p), fmt.tprintf("%s/src", gt)}))
	subset, swhy := font_subset(font, codes, context.temp_allocator)
	if swhy != "" { return "", fmt.tprintf("%s: %s", ttf, swhy) }
	_ = os.make_directory_all(dir_of(LUCIDE_SUBSET_FILE))
	// (written only when it changed: an unchanged file keeps its time, and what builds from it is not made again)
	old, oerr := os.read_entire_file(LUCIDE_SUBSET_FILE, context.temp_allocator)
	if oerr != nil || !slice.equal(old, subset) {
		if os.write_entire_file(LUCIDE_SUBSET_FILE, subset) != nil { return "", fmt.tprintf("%s cannot be written", LUCIDE_SUBSET_FILE) }
	}
	abs, aerr := os.get_absolute_path(LUCIDE_SUBSET_FILE, context.temp_allocator)
	if aerr != nil { return "", fmt.tprintf("%s: no absolute path", LUCIDE_SUBSET_FILE) }
	fmt.printfln("%s: %d icons, %d of %d bytes", LUCIDE_SUBSET_FILE, len(codes), len(subset), len(font))
	return abs, ""
}

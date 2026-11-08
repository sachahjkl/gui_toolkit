package tk

// doc_check [--root folder] [--extra folder]...: what the documentation names must exist: the files and folders it cites, the command
// line flags and -define: it gives, and the identifiers of a package (`ui.something`). A name it cannot place is printed with its
// file and line; it fails if any. It says nothing of whether a sentence is true, only that what it names is there.
//   --root    the repository whose documentation is read (default: the toolkit's)
//   --extra   also look for names in that folder (a submodule); may be given more than once
// The documents: every Markdown file git tracks (not the CHANGELOGs, changelog.d, NOTICE, ext/), and site/index.html.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import toolbox "../../src/toolbox"

// What the code is, where a name is looked for.
@(private = "file") CODE_EXTENSIONS :: [?]string{".odin", ".mjs", ".js", ".ps1", ".sh", ".bat", ".rs", ".yml", ".toml", ".nix"}
@(private = "file") CODE_SKIPPED :: [?]string{"tests/e2e/baseline/", "font/slug_ref/"}
// The folders a cited path starts with.
@(private = "file") PATH_ROOTS :: [?]string{"tools", "examples", "tests", "docs", "src", "native", "res", "assets", "ui", "draw", "render", "font", "platform", "devtools"}
// The packages whose names are checked: `ui.box`, `cdp.connect`.
@(private = "file") PACKAGES :: [?]string{"ui", "draw", "render", "font", "platform", "config", "arena", "instance", "testkit", "i18n", "fsx", "flate", "devtools", "cdp", "site", "desktop", "process", "update", "paint", "toolbox"}
// Flags of other programs (git, cargo).
@(private = "file") SYSTEM_FLAGS :: [?]string{"--recursive", "--init", "--locked", "--release", "--force", "--target-dir", "--no-verify"}
@(private = "file") NOT_NAMES :: [?]string{"odin", "md", "mjs", "exe", "wgsl"}

run_doc_check :: proc(a: ^Args) -> string {
	root := toolkit_root()
	extra := make([dynamic]string, context.temp_allocator)
	args := a.positionals[:]
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "--root" && i + 1 < len(args):
			i += 1
			root = args[i]
		case args[i] == "--extra" && i + 1 < len(args):
			i += 1
			append(&extra, args[i])
		case:
			return fmt.tprintf("what is %s? (--root folder, --extra folder)", args[i])
		}
	}
	problems, why := doc_check(root, extra[:])
	if why != "" { return why }
	for p in problems { fmt.println(p) }
	if len(problems) > 0 {
		fmt.printfln("%d names not found", len(problems))
		return "names not found"
	}
	fmt.println("every name found")
	return ""
}

@(private = "file")
Docs :: struct {
	root: string,
	dirs: []string,   // the root, then the extra folders
	code: string,     // every file of code, one after the other
}

@(private = "file")
tracked :: proc(dir: string) -> (files: []string, ok: bool) {
	out, code := toolbox.capture({"git", "-C", dir, "ls-files"})
	if code != 0 { return nil, false }
	list := make([dynamic]string, context.temp_allocator)
	for l in strings.split_lines(out, context.temp_allocator) { if l != "" { append(&list, l) } }
	return list[:], true
}

@(private = "file")
is_word :: proc(c: byte) -> bool { return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }

// A path of the documentation in one of the folders (its last slash dropped, a backslash a slash).
@(private = "file")
exists_in :: proc(d: ^Docs, p: string) -> bool {
	path, _ := strings.replace_all(strings.trim_right(p, "/\\"), "\\", "/", context.temp_allocator)
	for dir in d.dirs { if os.exists(join({dir, path})) { return true } }
	return false
}

// `word` as a whole word of the code (\bword\b).
@(private = "file")
whole_word :: proc(code, word: string) -> bool {
	from := 0
	for {
		at := strings.index(code[from:], word)
		if at < 0 { return false }
		start := from + at
		end := start + len(word)
		if (start == 0 || !is_word(code[start - 1])) && (end == len(code) || !is_word(code[end])) { return true }
		from = start + 1
	}
}

// The names the documentation gives that are nowhere: "<file>:<line>: <what>". why: the folders cannot be read.
doc_check :: proc(root: string, extra: []string) -> (problems: []string, why: string) {
	d := Docs{root = root}
	dirs := make([dynamic]string, context.temp_allocator)
	append(&dirs, root)
	append(&dirs, ..extra)
	d.dirs = dirs[:]
	root_files, ok := tracked(root)
	if !ok { return nil, fmt.tprintf("%s: git ls-files failed", root) }
	code := strings.builder_make(context.temp_allocator)
	extensions, skipped := CODE_EXTENSIONS, CODE_SKIPPED
	for dir in d.dirs {
		files, listed := tracked(dir)
		if !listed { return nil, fmt.tprintf("%s: git ls-files failed", dir) }
		next: for f in files {
			is_code := false
			for e in extensions { is_code ||= strings.has_suffix(f, e) }
			if !is_code { continue }
			for s in skipped { if strings.has_prefix(f, s) { continue next } }
			text, _ := read_text(join({dir, f}))
			strings.write_string(&code, text)
			strings.write_byte(&code, '\n')
		}
	}
	d.code = strings.to_string(code)

	docs := make([dynamic]string, context.temp_allocator)
	for f in root_files {
		if !strings.has_suffix(f, ".md") || strings.has_prefix(f, "CHANGELOG") || strings.has_prefix(f, "changelog.d/") || strings.has_prefix(f, "NOTICE") || strings.has_prefix(f, "docs/changes-") { continue }
		if strings.contains(f, "/CHANGELOG") || strings.has_prefix(f, "ext/") { continue }
		append(&docs, f)
	}
	for f in root_files { if f == "site/index.html" { append(&docs, f) } }

	out := make([dynamic]string, context.temp_allocator)
	for doc in docs {
		text, _ := read_text(join({root, doc}))
		lines := strings.split(text, "\n", context.temp_allocator)
		for raw, n in lines {
			check_line(&d, doc, strings.trim_suffix(raw, "\r"), n + 1, &out)
		}
	}
	return out[:], ""
}

@(private = "file")
check_line :: proc(d: ^Docs, doc, line: string, n: int, out: ^[dynamic]string) {
	seen := make(map[string]bool, context.temp_allocator)
	// once per line: what it says it is, and whether it is there
	once :: proc(seen: ^map[string]bool, out: ^[dynamic]string, doc: string, n: int, what: string, ok: bool) {
		if what in seen { return }
		seen[what] = true
		if !ok { append(out, fmt.tprintf("%s:%d: %s", doc, n, what)) }
	}

	// links: ](target) or ](target#anchor)
	for i := 0; i + 1 < len(line); {
		if !strings.has_prefix(line[i:], "](") { i += 1; continue }
		j := i + 2
		for j < len(line) && line[j] != ')' && line[j] != '#' && !is_space(line[j]) { j += 1 }
		target := line[i + 2:j]
		k := j
		if k < len(line) && line[k] == '#' { for k < len(line) && line[k] != ')' { k += 1 } }
		if target == "" || k >= len(line) || line[k] != ')' { i += 1; continue }
		i = k + 1
		if strings.has_prefix(target, "http:") || strings.has_prefix(target, "https:") || strings.has_prefix(target, "mailto:") { continue }
		here := join({d.root, filepath.dir(doc), target})
		once(&seen, out, doc, n, fmt.tprintf("link %s", target), os.exists(here) || exists_in(d, target))
	}

	// cited paths: a known folder, a slash, what a path holds, ending with a letter or digit
	roots := PATH_ROOTS
	for i := 0; i < len(line); {
		if i > 0 && is_path_byte(line[i - 1]) { i += 1; continue }
		end := -1
		for r in roots {
			if strings.has_prefix(line[i:], r) && i + len(r) < len(line) && (line[i + len(r)] == '/' || line[i + len(r)] == '\\') {
				j := i + len(r) + 1
				last := -1
				for j < len(line) && is_path_byte(line[j]) {
					if is_word(line[j]) { last = j }
					j += 1
				}
				if last >= 0 { end = last + 1 }
				break
			}
		}
		if end < 0 { i += 1; continue }
		p := line[i:end]
		i = end
		after := line[end:]
		k := 0
		star := false
		for k < len(after) && (after[k] == '.' || after[k] == '*') { star ||= after[k] == '*'; k += 1 }
		first := p[:strings.index_any(p, "/\\")]
		if star || !exists_in(d, first) { continue }   // (a pattern; a folder of the reader's project)
		// (docs/index.html is the page tk site_docs makes, the home page's link to the Docs section)
		once(&seen, out, doc, n, fmt.tprintf("path %s", p), exists_in(d, p) || exists_in(d, fmt.tprintf("%s.exe", p)) || p == "docs/index.html")
	}

	// flags and names, in code spans only
	for i := 0; i < len(line); {
		if line[i] != '`' { i += 1; continue }
		close := strings.index_byte(line[i + 1:], '`')
		if close < 0 { break }
		if close == 0 { i += 1; continue }
		span := line[i + 1:i + 1 + close]
		i += close + 2
		check_span(d, doc, span, n, &seen, out)
	}
}

@(private = "file")
is_space :: proc(c: byte) -> bool { return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f' }

@(private = "file")
is_path_byte :: proc(c: byte) -> bool { return is_word(c) || c == '.' || c == '/' || c == '\\' || c == '-' }

@(private = "file")
check_span :: proc(d: ^Docs, doc, span: string, n: int, seen: ^map[string]bool, out: ^[dynamic]string) {
	report :: proc(seen: ^map[string]bool, out: ^[dynamic]string, doc: string, n: int, what: string, ok: bool) {
		if what in seen { return }
		seen[what] = true
		if !ok { append(out, fmt.tprintf("%s:%d: %s", doc, n, what)) }
	}
	// -define:NAME
	rest := span
	for {
		at := strings.index(rest, "-define:")
		if at < 0 { break }
		rest = rest[at + len("-define:"):]
		j := 0
		for j < len(rest) && ((rest[j] >= 'A' && rest[j] <= 'Z') || rest[j] == '_') { j += 1 }
		if j > 0 { report(seen, out, doc, n, fmt.tprintf("define %s", rest[:j]), strings.contains(d.code, rest[:j])) }
	}
	// --flag
	system := SYSTEM_FLAGS
	for i := 0; i + 3 < len(span); i += 1 {
		if span[i] != '-' || span[i + 1] != '-' || !(span[i + 2] >= 'a' && span[i + 2] <= 'z') { continue }
		if i > 0 && (is_word(span[i - 1]) || span[i - 1] == '-') { continue }
		j := i + 3
		for j < len(span) && ((span[j] >= 'a' && span[j] <= 'z') || span[j] == '_' || span[j] == '-') { j += 1 }
		if j == i + 3 { continue }
		flag := span[i:j]
		i = j - 1
		is_system := false
		for s in system { is_system ||= s == flag }
		if is_system { continue }
		report(seen, out, doc, n, fmt.tprintf("flag %s", flag), strings.contains(d.code, fmt.tprintf("\"%s", flag)) || strings.contains(d.code, fmt.tprintf("'%s", flag)) || strings.contains(d.code, flag[2:]))
	}
	// package.name
	packages, not_names := PACKAGES, NOT_NAMES
	for i := 0; i < len(span); i += 1 {
		if i > 0 && (is_word(span[i - 1]) || span[i - 1] == '.' || span[i - 1] == ':') { continue }
		for pkg in packages {
			if !strings.has_prefix(span[i:], pkg) || i + len(pkg) >= len(span) || span[i + len(pkg)] != '.' { continue }
			start := i + len(pkg) + 1
			if start >= len(span) || !(is_word(span[start]) && !(span[start] >= '0' && span[start] <= '9')) { continue }
			j := start
			for j < len(span) && is_word(span[j]) { j += 1 }
			name := span[start:j]
			i = j - 1
			skip := strings.has_suffix(name, "_")
			for x in not_names { skip ||= x == name }
			if !skip { report(seen, out, doc, n, fmt.tprintf("name %s.%s", pkg, name), whole_word(d.code, name)) }
			break
		}
	}
}

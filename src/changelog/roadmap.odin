package tk_changelog

// ROADMAP.md, beside CHANGELOG.md, holds a project's planned work: plain Markdown that a reader understands without a tool,
// "# Roadmap" then "## Now", "## Next" and "## Later", each a list of entries that start with a bold summary, no dates (a
// plan is an order, not a promise). `check` checks it with the changelog: a project keeps both, and one check sees both.

import "core:fmt"
import "core:strings"

ROADMAP_FILE :: "ROADMAP.md"
ROADMAP_TITLE :: "# Roadmap"
ROADMAP_SECTIONS :: [3]string{"## Now", "## Next", "## Later"}

// What is wrong in a roadmap's text, each error naming its line (temp allocator).
roadmap_errors :: proc(text: string) -> [dynamic]string {
	errors := make([dynamic]string, context.temp_allocator)
	sections := ROADMAP_SECTIONS
	lines := strings.split_lines(text, context.temp_allocator)
	// (a file that ends with a newline has one empty line more, which is no line of the file)
	if len(lines) > 0 && lines[len(lines) - 1] == "" { lines = lines[:len(lines) - 1] }
	if len(lines) == 0 { append(&errors, "line 1: an empty file"); return errors }

	next := 0           // the index of the section expected next
	in_section := false
	in_entry := false   // (a continuation line needs an entry above it)
	for raw, i in lines {
		n := i + 1
		line := strings.trim_right(raw, "\r")
		if roadmap_has_date(line) { append(&errors, fmt.tprintf("line %d: a date; a roadmap gives none", n)) }
		if i == 0 {
			if line == "---" {
				append(&errors, "line 1: front matter; a roadmap is plain Markdown")
			} else if line != ROADMAP_TITLE {
				append(&errors, fmt.tprintf("line 1: %q, not %q", line, ROADMAP_TITLE))
			}
			continue
		}
		if strings.trim_space(line) == "" { continue }   // (a blank line ends nothing: an entry may hold one)
		if strings.has_prefix(line, "#") {
			in_entry = false
			at := -1
			for s, k in sections { if line == s { at = k } }
			switch {
			case at < 0:
				append(&errors, fmt.tprintf("line %d: %q; the only headings are ## Now, ## Next and ## Later", n, line))
			case at < next:
				append(&errors, fmt.tprintf("line %d: %s after %s", n, line, sections[next - 1]))
			case at > next:
				append(&errors, fmt.tprintf("line %d: %s before %s", n, line, sections[next]))
				next = at + 1
				in_section = true
			case:
				next += 1
				in_section = true
			}
			continue
		}
		if !in_section { append(&errors, fmt.tprintf("line %d: text outside ## Now, ## Next and ## Later", n)); continue }
		if strings.has_prefix(line, "- ") {
			bold := strings.has_prefix(line, "- **") && strings.contains(line[4:], "**")
			if !bold { append(&errors, fmt.tprintf("line %d: an entry starts with a bold summary: - **...**", n)) }
			in_entry = true
			continue
		}
		if (line[0] == ' ' || line[0] == '\t') && in_entry { continue }
		append(&errors, fmt.tprintf("line %d: neither an entry (- **...**) nor its indented continuation", n))
	}
	for k in next ..< len(sections) {
		append(&errors, fmt.tprintf("line %d: no %s", len(lines), sections[k]))
	}
	return errors
}

// A date as 2026-11-14 anywhere in the line, as a whole word.
@(private = "file")
roadmap_has_date :: proc(line: string) -> bool {
	word :: proc(c: u8) -> bool { return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
	digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }
	for i := 0; i + 10 <= len(line); i += 1 {
		s := line[i:i + 10]
		if s[0] != '2' || s[1] != '0' || s[4] != '-' || s[7] != '-' { continue }
		if !digit(s[2]) || !digit(s[3]) || !digit(s[5]) || !digit(s[6]) || !digit(s[8]) || !digit(s[9]) { continue }
		if i > 0 && word(line[i - 1]) { continue }
		if i + 10 < len(line) && word(line[i + 10]) { continue }
		return true
	}
	return false
}

// The roadmap of the project at `root`, checked: what is wrong, each error naming the file and its line.
@(private)
roadmap_check :: proc(root: string, errors: ^[dynamic]string) {
	path := fmt.tprintf("%s/%s", root != "" ? root : ".", ROADMAP_FILE)
	text, ok := read_text(path)
	if !ok {
		append(errors, fmt.tprintf("no %s: a project keeps its planned work there (# Roadmap, ## Now, ## Next, ## Later)", ROADMAP_FILE))
		return
	}
	for e in roadmap_errors(text) { append(errors, fmt.tprintf("%s: %s", ROADMAP_FILE, e)) }
}

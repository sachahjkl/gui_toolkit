package fsx

// The rules of .gitignore files (git's gitignore(5)), for a walk that leaves out what a repository ignores: a search of
// a folder's names (ui.file_tree's filter). Pure: the program reads the files and gives their text.
//
//   rules: Ignore
//   ignore_add(&rules, "", root_gitignore_text)          // the repository's top
//   ignore_add(&rules, "src/ui", nested_gitignore_text)  // a folder's own, relative to the top, "/" between its parts
//   if ignore_match(&rules, "src/ui/build", true) { ... skip it ... }
//
// What it reads: blank lines and "#" comments, a backslash before a leading "#" or "!", trailing spaces, "!" (the
// pattern takes back what an earlier one ignored), a trailing "/" (folders only), a "/" at the start or inside (relative
// to the file's folder; else the name at any depth), "*", "?", "[...]" (with "!" or "^" for none of them, ranges) and
// "**" ("**/" any folders before, "/**" everything inside, "/**/" any folders between). The last pattern that matches
// decides. A path inside an ignored folder is not asked: a walk does not enter that folder (git cannot take a file back
// from an ignored folder either).

import "core:strings"

Ignore :: struct {
	rules: [dynamic]Ignore_Rule,
	text:  [dynamic]string,   // the texts given (owned): the rules are slices of them
}

Ignore_Rule :: struct {
	base:     string,   // the folder of its file, relative to the top ("": the top)
	pattern:  string,
	negate:   bool,
	dir_only: bool,
	anchored: bool,     // relative to `base`; else the name at any depth under it
}

ignore_destroy :: proc(ig: ^Ignore) {
	for t in ig.text { delete(t, ig.text.allocator) }
	delete(ig.text)
	delete(ig.rules)
	ig^ = {}
}

// The rules of one .gitignore's `text` (copied), the file in the folder `base` (relative to the top, "/" separated).
ignore_add :: proc(ig: ^Ignore, base, text: string) {
	if ig.text == nil { ig.text = make([dynamic]string) }
	own := strings.concatenate({base, "\n", text}, ig.text.allocator)
	append(&ig.text, own)
	b := own[:len(base)]
	rest := own[len(base) + 1:]
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_right(line, "\r")
		// (trailing spaces go, unless the last one is escaped)
		for len(l) > 0 && l[len(l) - 1] == ' ' && !(len(l) >= 2 && l[len(l) - 2] == '\\') { l = l[:len(l) - 1] }
		if l == "" || l[0] == '#' { continue }
		r := Ignore_Rule{base = b}
		if l[0] == '!' { r.negate = true; l = l[1:] } else if len(l) >= 2 && l[0] == '\\' && (l[1] == '#' || l[1] == '!') { l = l[1:] }
		if len(l) > 0 && l[len(l) - 1] == '/' { r.dir_only = true; l = l[:len(l) - 1] }
		if l == "" { continue }
		if strings.index_byte(l, '/') >= 0 { r.anchored = true }
		if l[0] == '/' { l = l[1:] }
		r.pattern = l
		append(&ig.rules, r)
	}
}

// Whether the path `rel` (relative to the top, "/" separated, no "/" at its ends) is ignored; `dir`: it is a folder.
ignore_match :: proc(ig: ^Ignore, rel: string, dir: bool) -> bool {
	#reverse for r in ig.rules {
		if r.dir_only && !dir { continue }
		sub := rel
		if r.base != "" {
			if !strings.has_prefix(rel, r.base) || len(rel) <= len(r.base) || rel[len(r.base)] != '/' { continue }
			sub = rel[len(r.base) + 1:]
		}
		hit := false
		if r.anchored {
			hit = glob_match(r.pattern, sub)
		} else {
			name := sub
			if k := strings.last_index_byte(sub, '/'); k >= 0 { name = sub[k + 1:] }
			hit = glob_match(r.pattern, name)
		}
		if hit { return !r.negate }
	}
	return false
}

// Whether `name` matches the glob `pattern`: "*" and "?" never take a "/", "**" does ("**/": any folders, none
// included), "[...]" is a class, a backslash escapes the next character.
//
// A pass per part of the pattern over the name's prefixes (which of them the pattern so far matches): at most the
// pattern's length times the name's, whatever the stars. A matcher that tries each place of each star in turn takes
// the name's length to the power of the stars, and a .gitignore's "*a*a*a*a*a*a*b" stops a search for minutes.
glob_match :: proc(pattern, name: string) -> bool {
	n := len(name)
	// (two rows of the name's prefixes: on the stack for a name of a usual length)
	stack: [2 * 256]bool
	rows := stack[:]
	if 2 * (n + 1) > len(stack) { rows = make([]bool, 2 * (n + 1), context.temp_allocator) }
	cur, next := rows[:n + 1], rows[n + 1:2 * (n + 1)]
	cur[0] = true
	for j in 1 ..= n { cur[j] = false }
	p := pattern
	for len(p) > 0 {
		for j in 0 ..= n { next[j] = false }
		switch {
		case strings.has_prefix(p, "**/"):
			// (none, or any run that ends with a "/")
			seen := false
			for j in 0 ..= n {
				next[j] = cur[j] || (seen && j > 0 && name[j - 1] == '/')
				if cur[j] { seen = true }
			}
			p = p[3:]
		case strings.has_prefix(p, "**"):
			for j in 0 ..= n { next[j] = cur[j] || (j > 0 && next[j - 1]) }
			p = p[2:]
		case p[0] == '*':
			for j in 0 ..= n { next[j] = cur[j] || (j > 0 && next[j - 1] && name[j - 1] != '/') }
			p = p[1:]
		case p[0] == '?':
			for j in 0 ..< n { next[j + 1] = cur[j] && name[j] != '/' }
			p = p[1:]
		case p[0] == '[':
			// (a "]" right after the "[" or its "!" is one of the class)
			from := 1
			if from < len(p) && (p[from] == '!' || p[from] == '^') { from += 1 }
			if from < len(p) && p[from] == ']' { from += 1 }
			close := strings.index_byte(p[from:], ']')
			if close < 0 {
				// (no end: a plain "[")
				for j in 0 ..< n { next[j + 1] = cur[j] && name[j] == '[' }
				p = p[1:]
				break
			}
			end := from + close
			class := p[1:end]
			none := len(class) > 0 && (class[0] == '!' || class[0] == '^')
			if none { class = class[1:] }
			for j in 0 ..< n {
				if !cur[j] || name[j] == '/' { continue }
				next[j + 1] = glob_in_class(class, name[j]) != none
			}
			p = p[end + 1:]
		case p[0] == '\\' && len(p) > 1:
			for j in 0 ..< n { next[j + 1] = cur[j] && name[j] == p[1] }
			p = p[2:]
		case:
			for j in 0 ..< n { next[j + 1] = cur[j] && name[j] == p[0] }
			p = p[1:]
		}
		cur, next = next, cur
	}
	return cur[n]
}

@(private = "file")
glob_in_class :: proc(class: string, c: u8) -> bool {
	for i := 0; i < len(class); i += 1 {
		if i + 2 < len(class) && class[i + 1] == '-' {
			if c >= class[i] && c <= class[i + 2] { return true }
			i += 2
		} else if class[i] == c {
			return true
		}
	}
	return false
}

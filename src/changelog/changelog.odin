// Package changelog: a CHANGELOG.md made of fragments, one file per change in changelog.d/, assembled into a version's section
// when the version is published. Branches never touch CHANGELOG.md nor the version, so two merges never conflict on them.
// The package is named tk_changelog; tools/changelog and release.ship call it.
//
// A fragment is changelog.d/<yyyyMMdd-HHmmss>-<subject>.md (subject: lowercase letters, digits and '-'):
//     type: Added                       (Added | Changed | Deprecated | Removed | Fixed | Security)
//                                       (a blank line, optional)
//     **What changed**: the one entry, as it will read in the list (no leading "- "); indented "  - " lines are sub-items.
//
// CHANGELOG.md follows Keep a Changelog: `## [x.y.z] - yyyy-mm-dd` sections, newest first, the versions' links at its end.
// An `## [Unreleased]` section written by hand (a project from before the fragments) is read too: assemble moves its entries
// into the version, after the fragments', and removes it.
package tk_changelog

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "../ascii"

// Keep a Changelog's, in the order of a version's subsections.
TYPE_NAMES := [?]string{"Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"}
// A subject in a fragment's name, at most, and from where it may be cut at a '-'.
SLUG_MAX :: 48
SLUG_CUT_MIN :: 16
// yyyyMMdd-HHmmss-
NAME_STAMP_BYTES :: 16
// a badge's colour, after its version
@(private = "file") BADGE_HEX_BYTES :: 6

// What is particular to a project.
Project_Options :: struct {
	root:        string,   // the checkout: its CHANGELOG.md and changelog.d/ ("": the current folder)
	link:        string,   // a version's link, %s for the version: "https://github.com/o/r/releases/tag/v%s" ("": none)
	// where the project keeps its version (nil: nowhere the package knows). check says when it differs from the last
	// released one (a branch never writes it); assemble writes the new one after CHANGELOG.md. Each gets `user`.
	version:     proc(root: string, user: rawptr) -> string,
	set_version: proc(root, version: string, user: rawptr) -> bool,
	user:        rawptr,
}

// A change: a fragment's file, or an entry of a hand-written [Unreleased] section (no name, no path).
Fragment :: struct {
	name, path: string,
	type:       string,
	lines:      []string,
	problems:   [dynamic]string,
}

Changelog :: struct {
	nl:             string,
	lines:          []string,
	first_release:  int,      // the line of the newest version's heading (-1: none)
	last_version:   string,
	unreleased:     int,      // the line of a hand-written "## [Unreleased]" (-1: none)
	unreleased_end: int,      // the line after its body
}

@(private = "file") is_digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }

// The canonical name of a type ("added" -> "Added"), "" when it is none.
canonical_type :: proc(t: string) -> string {
	for n in TYPE_NAMES { if ascii.equal_fold(n, strings.trim_space(t)) { return n } }
	return ""
}

@(private = "file")
split_lines :: proc(s: string) -> []string {
	t, _ := strings.replace_all(s, "\r\n", "\n", context.temp_allocator)
	return strings.split(t, "\n", context.temp_allocator)
}

@(private = "file")
read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return string(data), err == nil
}

@(private = "file") write_text :: proc(path, text: string) -> bool { return os.write_entire_file(path, transmute([]byte)text) == nil }

@(private = "file") root_of :: proc(o: Project_Options) -> string { return o.root != "" ? o.root : "." }

// A link's definition at the end of the file: "[label]: url".
@(private = "file") is_link :: proc(l: string) -> bool { return strings.has_prefix(l, "[") && strings.contains(l, "]: ") }

name_is_good :: proc(name: string) -> bool {
	if !strings.has_suffix(name, ".md") || len(name) <= NAME_STAMP_BYTES + len(".md") { return false }
	for i in 0 ..< NAME_STAMP_BYTES {
		c := name[i]
		if i == 8 || i == 15 { if c != '-' { return false } } else if !is_digit(c) { return false }
	}
	subject := name[NAME_STAMP_BYTES:len(name) - len(".md")]
	if subject[0] == '-' || subject[len(subject) - 1] == '-' || strings.contains(subject, "--") { return false }
	for c in transmute([]u8)subject { if !(c == '-' || is_digit(c) || (c >= 'a' && c <= 'z')) { return false } }
	return true
}

read_fragment :: proc(name, path: string) -> (f: Fragment) {
	f.name, f.path = name, path
	f.problems.allocator = context.temp_allocator
	if !name_is_good(name) { append(&f.problems, "its name is not <yyyyMMdd-HHmmss>-<subject>.md (subject: a-z, 0-9 and -)") }
	text, _ := read_text(path)
	lines := split_lines(text)
	i := 0
	for i < len(lines) && strings.trim_space(lines[i]) == "" { i += 1 }
	if i >= len(lines) { append(&f.problems, "it is empty"); return }
	head := strings.trim_space(lines[i])
	colon := strings.index_byte(head, ':')
	if colon < 0 || !ascii.equal_fold(strings.trim_space(head[:colon]), "type") {
		append(&f.problems, "its first line is not 'type: Added|Changed|Deprecated|Removed|Fixed|Security'")
		return
	}
	said := strings.trim_space(head[colon + 1:])
	f.type = canonical_type(said)
	if f.type == "" { append(&f.problems, fmt.tprintf("unknown type '%s' (Added, Changed, Deprecated, Removed, Fixed or Security)", said)) }
	body := make([dynamic]string, context.temp_allocator)
	for l in lines[i + 1:] { append(&body, strings.trim_right_space(l)) }
	for len(body) > 0 && body[0] == "" { ordered_remove(&body, 0) }
	for len(body) > 0 && body[len(body) - 1] == "" { pop(&body) }
	if len(body) == 0 { append(&f.problems, "it has a type but no text"); return }
	body[0] = strings.trim_prefix(body[0], "- ")
	if strings.trim_space(body[0]) == "" { append(&f.problems, "its text is empty") }
	for l in body {
		if l == "" { append(&f.problems, `a blank line inside its text (one entry: sub-items are indented "  - " lines)`); break }
		if strings.has_prefix(l, "#") { append(&f.problems, "a heading inside its text (the type gives the section)"); break }
		if strings.has_prefix(l, "- ") { append(&f.problems, `several entries in one fragment (one change per fragment; sub-items are indented "  - ")`); break }
	}
	f.lines = body[:]
	return
}

// Newest first: a version lists its latest changes at the top.
read_fragments :: proc(root: string, errors: ^[dynamic]string) -> []Fragment {
	out := make([dynamic]Fragment, context.temp_allocator)
	dir := fmt.tprintf("%s/changelog.d", root)
	entries, err := os.read_directory_by_path(dir, 0, context.temp_allocator)
	if err != nil { return nil }
	for e in entries {
		if e.type == .Directory { append(errors, fmt.tprintf("changelog.d/%s: a folder (fragments are files)", e.name)); continue }
		if e.name == "README.md" { continue }
		append(&out, read_fragment(e.name, fmt.tprintf("%s/%s", dir, e.name)))
	}
	slice.sort_by(out[:], proc(a, b: Fragment) -> bool { return a.name > b.name })
	return out[:]
}

// A released version's heading "## [x.y.z] - ...": its version ("": it is not one).
heading_version :: proc(line: string) -> string {
	if !strings.has_prefix(line, "## [") { return "" }
	rest := line[len("## ["):]
	end := strings.index_byte(rest, ']')
	if end <= 0 || !is_digit(rest[0]) || strings.count(rest[:end], ".") < 2 { return "" }
	return rest[:end]
}

@(private = "file")
is_unreleased :: proc(line: string) -> bool {
	rest := strings.trim_prefix(strings.trim_space(line), "## [")
	end := strings.index_byte(rest, ']')
	return len(rest) < len(strings.trim_space(line)) && end > 0 && ascii.equal_fold(rest[:end], "unreleased")
}

version_is_good :: proc(v: string) -> bool {
	end := len(v)
	if i := strings.index_any(v, "-+"); i >= 0 { end = i }
	parts := strings.split(v[:end], ".", context.temp_allocator)
	if len(parts) != 3 { return false }
	for p in parts {
		if p == "" { return false }
		for c in transmute([]u8)p { if !is_digit(c) { return false } }
	}
	return true
}

read_changelog :: proc(root: string) -> (c: Changelog) {
	text, _ := read_text(fmt.tprintf("%s/CHANGELOG.md", root))
	c.nl = strings.contains(text, "\r\n") ? "\r\n" : "\n"
	c.lines = split_lines(text)
	c.first_release, c.unreleased = -1, -1
	for l, i in c.lines {
		if c.unreleased < 0 && is_unreleased(l) { c.unreleased = i }
		if v := heading_version(l); v != "" {
			c.first_release, c.last_version = i, v
			break
		}
	}
	if c.unreleased >= 0 {
		c.unreleased_end = len(c.lines)
		for i in c.unreleased + 1 ..< len(c.lines) {
			if strings.has_prefix(c.lines[i], "## ") || is_link(c.lines[i]) { c.unreleased_end = i; break }
		}
	}
	return
}

// The entries of a hand-written [Unreleased] section, as fragments of its subsections' types, in their order.
unreleased_entries :: proc(c: Changelog) -> (entries: []Fragment, problems: [dynamic]string) {
	problems.allocator = context.temp_allocator
	if c.unreleased < 0 { return }
	out := make([dynamic]Fragment, context.temp_allocator)
	type := ""
	lines: [dynamic]string
	flush :: proc(into: ^[dynamic]Fragment, kind: string, entry: ^[dynamic]string) {
		if len(entry^) == 0 { return }
		for len(entry^) > 0 && entry^[len(entry^) - 1] == "" { pop(entry) }
		append(into, Fragment{type = kind, lines = entry^[:]})
		entry^ = {}
	}
	for raw in c.lines[c.unreleased + 1:c.unreleased_end] {
		l := strings.trim_right_space(raw)
		switch {
		case strings.has_prefix(l, "### "):
			flush(&out, type, &lines)
			said := strings.trim_space(l[len("### "):])
			type = canonical_type(said)
			if type == "" { append(&problems, fmt.tprintf("CHANGELOG.md: [Unreleased] has a subsection '%s' (Added, Changed, Deprecated, Removed, Fixed or Security)", said)) }
		case strings.has_prefix(l, "- "):
			flush(&out, type, &lines)
			if type == "" && len(problems) == 0 { append(&problems, "CHANGELOG.md: [Unreleased] has an entry outside a subsection ### Added, ### Fixed...") }
			lines = make([dynamic]string, context.temp_allocator)
			append(&lines, l[len("- "):])
		case l == "":
			// (kept: an indented line after it is still the entry's; flush drops the blank lines at its end)
			if len(lines) > 0 { append(&lines, l) }
		case:
			if len(lines) > 0 { append(&lines, l) } else { append(&problems, fmt.tprintf("CHANGELOG.md: [Unreleased] has text outside an entry: '%s'", l)) }
		}
	}
	flush(&out, type, &lines)
	return out[:], problems
}

// The body of a version's section: its subsections in the order of TYPE_NAMES, each with its changes in the given order.
render_body :: proc(frags: []Fragment) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for t in TYPE_NAMES {
		first_of := true
		for f in frags {
			if f.type != t { continue }
			if first_of {
				if len(out) > 0 { append(&out, "") }
				append(&out, fmt.tprintf("### %s", t))
				first_of = false
			}
			for l, i in f.lines { append(&out, i == 0 ? fmt.tprintf("- %s", l) : l) }
		}
	}
	return out[:]
}

// What identifies an entry: its spaces do not count.
entry_key :: proc(first: string) -> string {
	return strings.join(strings.fields(first, context.temp_allocator), " ", context.temp_allocator)
}

// A fragment's subject from a text: its `strong` part first when there is one.
slug :: proc(s: string) -> string {
	text := s
	if a := strings.index(text, "**"); a >= 0 {
		if b := strings.index(text[a + 2:], "**"); b > 0 { text = text[a + 2:][:b] }
	}
	sb := strings.builder_make(context.temp_allocator)
	dash := true   // (no dash at the start)
	for c in transmute([]u8)ascii.lower(text) {
		if is_digit(c) || (c >= 'a' && c <= 'z') {
			strings.write_byte(&sb, c)
			dash = false
		} else if !dash {
			strings.write_byte(&sb, '-')
			dash = true
		}
	}
	out := strings.trim(strings.to_string(sb), "-")
	if len(out) > SLUG_MAX {
		cut := strings.last_index_byte(out[:SLUG_MAX + 1], '-')
		out = strings.trim(out[:cut > SLUG_CUT_MIN ? cut : SLUG_MAX], "-")
	}
	return out != "" ? out : "change"
}

@(private = "file")
date_of :: proc(when_: time.Time) -> string {
	y, mo, d := time.date(when_)
	return fmt.tprintf("%04d-%02d-%02d", y, int(mo), d)
}

// The folder of the fragments of the checkout at `root` ("": the current folder, as Project_Options.root; "/changelog.d" was
// written at the root of the disk).
@(private = "package")
fragments_dir :: proc(root: string) -> string { return fmt.tprintf("%s/changelog.d", root != "" ? root : ".") }

// Writes a fragment: its path, or why not. `root`: the checkout ("": the current folder).
new_fragment :: proc(root, type, subject, text: string, when_ := time.Time{}) -> (path: string, why: string) {
	t := canonical_type(type)
	if t == "" { return "", fmt.tprintf("the type is Added, Changed, Deprecated, Removed, Fixed or Security (got '%s')", type) }
	entry := strings.trim_space(text)
	if entry == "" { return "", "no text" }
	entry = strings.trim_prefix(entry, "- ")
	now := when_ == {} ? time.now() : when_
	y, mo, d := time.date(now)
	h, mi, s := time.clock(now)
	stem := fmt.tprintf("%04d%02d%02d-%02d%02d%02d-%s", y, int(mo), d, h, mi, s, slug(subject != "" ? subject : text))
	dir := fragments_dir(root)
	_ = os.make_directory_all(dir)
	name := fmt.tprintf("%s.md", stem)
	for k := 2; os.exists(fmt.tprintf("%s/%s", dir, name)); k += 1 { name = fmt.tprintf("%s-%d.md", stem, k) }
	path = fmt.tprintf("%s/%s", dir, name)
	body := strings.join(split_lines(entry), "\n", context.temp_allocator)
	write_text(path, fmt.tprintf("type: %s\n\n%s\n", t, body))
	f := read_fragment(name, path)
	if len(f.problems) > 0 {
		_ = os.remove(path)
		return "", fmt.tprintf("not a fragment: %s", strings.join(f.problems[:], "; ", context.temp_allocator))
	}
	return
}

// Whether all is well: what is wrong in `errors`, the number of fragments. `release`: and ready to tag that version.
check :: proc(o: Project_Options, release := "") -> (errors: [dynamic]string, fragments: int) {
	errors.allocator = context.temp_allocator
	root := root_of(o)
	c := read_changelog(root)
	frags := read_fragments(root, &errors)
	fragments = len(frags)
	_, hand_problems := unreleased_entries(c)
	append(&errors, ..hand_problems[:])
	released := make(map[string]bool, allocator = context.temp_allocator)
	for l, i in c.lines {
		if c.unreleased >= 0 && i >= c.unreleased && i < c.unreleased_end { continue }
		if strings.has_prefix(l, "- ") { released[entry_key(l[2:])] = true }
	}
	seen := make(map[string]string, allocator = context.temp_allocator)
	for f in frags {
		for p in f.problems { append(&errors, fmt.tprintf("changelog.d/%s: %s", f.name, p)) }
		if len(f.lines) == 0 { continue }
		key := entry_key(f.lines[0])
		if key in released { append(&errors, fmt.tprintf("changelog.d/%s: already in a released section of CHANGELOG.md (assembled but not deleted)", f.name)) }
		if other, twice := seen[key]; twice { append(&errors, fmt.tprintf("changelog.d/%s: the same text as changelog.d/%s", f.name, other)) } else { seen[key] = f.name }
	}
	if o.version != nil {
		said := o.version(root, o.user)
		if said == "" {
			append(&errors, "the version is not found in the sources")
		} else if c.last_version != "" && said != c.last_version {
			append(&errors, fmt.tprintf("the sources say version %s, the last released one is %s: the version is written when a version is published, never by a branch", said, c.last_version))
		}
		if release != "" && said != release { append(&errors, fmt.tprintf("the sources say version %s, not %s", said, release)) }
	}
	if release != "" {
		if len(frags) > 0 { append(&errors, fmt.tprintf("%d fragments are not assembled into %s", len(frags), release)) }
		if c.unreleased >= 0 { append(&errors, fmt.tprintf("CHANGELOG.md still has an [Unreleased] section, not assembled into %s", release)) }
		if c.last_version != release { append(&errors, fmt.tprintf("the latest section of CHANGELOG.md is '%s', not %s", c.last_version, release)) }
	}
	return
}

// The changes of the next version: the fragments, newest first, then a hand-written [Unreleased] section's entries.
@(private = "file")
pending :: proc(root: string, c: Changelog) -> (changes: []Fragment, errors: [dynamic]string) {
	errors.allocator = context.temp_allocator
	frags := read_fragments(root, &errors)
	for f in frags { for p in f.problems { append(&errors, fmt.tprintf("changelog.d/%s: %s", f.name, p)) } }
	hand, problems := unreleased_entries(c)
	append(&errors, ..problems[:])
	all := make([dynamic]Fragment, context.temp_allocator)
	append(&all, ..frags)
	append(&all, ..hand)
	return all[:], errors
}

// What the next version brings ("": nothing).
preview :: proc(root: string) -> (text: string, errors: [dynamic]string) {
	changes: []Fragment
	changes, errors = pending(root, read_changelog(root))
	body := render_body(changes)
	if len(body) == 0 { return "", errors }
	return fmt.tprintf("%s\n", strings.join(body, "\n", context.temp_allocator)), errors
}

// The release: the version's section above the last one, its link with the others, a hand-written [Unreleased] section
// gone, the version written (Project_Options.set_version), the fragments deleted. `date` "": today. `entries`: the changes.
assemble :: proc(o: Project_Options, version: string, date := "") -> (entries: int, errors: [dynamic]string) {
	root := root_of(o)
	c := read_changelog(root)
	changes: []Fragment
	changes, errors = pending(root, c)
	if len(errors) > 0 { return }
	if !version_is_good(version) { append(&errors, fmt.tprintf("the version is x.y.z (got '%s')", version)); return }
	for l in c.lines {
		if heading_version(l) == version { append(&errors, fmt.tprintf("CHANGELOG.md already has a section %s", version)); return }
	}
	if len(changes) == 0 { append(&errors, "nothing to publish: no fragment in changelog.d/"); return }
	// (without the [Unreleased] section nor its link: the fragments are what is not released)
	lines := make([dynamic]string, context.temp_allocator)
	first_release := -1
	for l, i in c.lines {
		if c.unreleased >= 0 && i >= c.unreleased && i < c.unreleased_end { continue }
		if is_link(l) && is_unreleased(fmt.tprintf("## %s", l)) { continue }
		if i == c.first_release { first_release = len(lines) }
		append(&lines, l)
	}
	day := date != "" ? date : date_of(time.now())
	all := make([dynamic]string, context.temp_allocator)
	at := first_release >= 0 ? first_release : len(lines)
	append(&all, ..lines[:at])
	if first_release < 0 {
		for len(all) > 0 && all[len(all) - 1] == "" { pop(&all) }
		append(&all, "")
	}
	append(&all, fmt.tprintf("## [%s] - %s", version, day), "")
	append(&all, ..render_body(changes))
	append(&all, "")
	if first_release >= 0 { append(&all, ..lines[at:]) } else { append(&all, "") }
	if o.link != "" {
		ref := fmt.tprintf("[%s]: %s", version, fmt.tprintf(o.link, version))
		link_at := -1
		for l, i in all {
			if is_link(l) && len(l) > 1 && is_digit(l[1]) { link_at = i; break }
		}
		if link_at >= 0 {
			inject_at(&all, link_at, ref)
		} else {
			for len(all) > 0 && all[len(all) - 1] == "" { pop(&all) }
			append(&all, "", ref, "")
		}
	}
	if !write_text(fmt.tprintf("%s/CHANGELOG.md", root), strings.join(all[:], c.nl, context.temp_allocator)) {
		append(&errors, "CHANGELOG.md cannot be written")
		return
	}
	if o.set_version != nil && !o.set_version(root, version, o.user) { append(&errors, fmt.tprintf("the version %s cannot be written in the sources", version)) }
	for f in changes { if f.path != "" { _ = os.remove(f.path) } }
	return len(changes), errors
}

// The body of a version's section (its ### parts). ok = false: it has none.
section :: proc(root, version: string) -> (body: string, ok: bool) {
	c := read_changelog(root)
	start := -1
	for l, i in c.lines { if heading_version(l) == version { start = i; break } }
	if start < 0 { return }
	end := len(c.lines)
	for i in start + 1 ..< len(c.lines) { if strings.has_prefix(c.lines[i], "## ") || is_link(c.lines[i]) { end = i; break } }
	return fmt.tprintf("%s\n", strings.trim_space(strings.join(c.lines[start + 1:end], "\n", context.temp_allocator))), true
}

// A README's version badge (shields.io): `badge/version-<v>-<hex6>` and `alt="version <v>"`, the version replaced. What a
// project's set_version writes along with its sources.
with_badge :: proc(text, version: string) -> string {
	out := text
	BADGE :: "badge/version-"
	if at := strings.index(out, BADGE); at >= 0 {
		rest := out[at + len(BADGE):]
		if end := strings.index_byte(rest, '"'); end > BADGE_HEX_BYTES {
			escaped, _ := strings.replace_all(version, "-", "--", context.temp_allocator)
			out = fmt.tprintf("%s%s%s%s", out[:at + len(BADGE)], escaped, rest[end - BADGE_HEX_BYTES - 1:end], rest[end:])
		}
	}
	ALT :: `alt="version `
	if at := strings.index(out, ALT); at >= 0 {
		rest := out[at + len(ALT):]
		if end := strings.index_byte(rest, '"'); end >= 0 {
			out = fmt.tprintf("%s%s%s", out[:at + len(ALT)], version, rest[end:])
		}
	}
	return out
}

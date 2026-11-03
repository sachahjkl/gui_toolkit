// The CHANGELOG is made of fragments: one file per change in changelog.d/, assembled into CHANGELOG.md when a version is published. Branches never touch
// CHANGELOG.md nor the version, so two merges never conflict on them.
//
// A fragment is changelog.d/<yyyyMMdd-HHmmss>-<subject>.md (subject: lowercase letters, digits and '-'):
//     type: Added                       (Added | Changed | Deprecated | Removed | Fixed | Security)
//                                       (a blank line, optional)
//     **What changed**: the one entry, as it will read in the list (no leading "- "); indented "  - " lines are sub-items.
//
//   odin run tools/changelog -- -new -type:Added -subject:storage -text:"**...**: ..."    writes one
//   odin run tools/changelog -- -check                       every fragment well formed, none already in CHANGELOG.md (CI)
//   odin run tools/changelog -- -check -release:0.4.0        ready to tag 0.4.0: no fragment left, its section there, the version said
//   odin run tools/changelog -- -assemble                    what the next version brings, printed
//   odin run tools/changelog -- -assemble -version:0.4.0     the release: a "## [0.4.0] - <date>" section in CHANGELOG.md, the version written in
//                                                            ui/version.odin and the README's badge, the fragments deleted (tools/release.ps1 does it)
//   odin run tools/changelog -- -section -version:0.4.0 [-out:f.md]   the body of that version's section (release notes)
// -root:dir works on another checkout. Exit code 0 when all is well, 1 otherwise. The procedures below are what tests/changelog calls.
package changelog_tool

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../cmdline"
import "core:time"
import "../../base"

// Keep a Changelog's, in the order of a version's subsections.
TYPE_NAMES := [?]string{"Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"}
LINK :: "https://github.com/sachahjkl/gui_toolkit/releases/tag/v%s"
VERSION_FILE :: "ui/version.odin"
// A subject in a fragment's name, at most, and from where it may be cut at a '-'.
SLUG_MAX :: 48
SLUG_CUT_MIN :: 16
// yyyyMMdd-HHmmss-
NAME_STAMP_BYTES :: 16
BADGE_HEX_BYTES :: 6

Fragment :: struct {
	name, path: string,
	type:       string,
	lines:      []string,
	problems:   [dynamic]string,
}

is_digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }

canonical_type :: proc(t: string) -> string {
	for n in TYPE_NAMES { if base.ascii_equal_fold(n, strings.trim_space(t)) { return n } }
	return ""
}

split_lines :: proc(s: string) -> []string {
	t, _ := strings.replace_all(s, "\r\n", "\n", context.temp_allocator)
	return strings.split(t, "\n", context.temp_allocator)
}

read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return string(data), err == nil
}

write_text :: proc(path, text: string) -> bool { return os.write_entire_file(path, transmute([]byte)text) == nil }

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
	if colon < 0 || !base.ascii_equal_fold(strings.trim_space(head[:colon]), "type") {
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

Changelog :: struct {
	nl:            string,
	lines:         []string,
	first_release: int,
	last_version:  string,
}

read_changelog :: proc(root: string) -> (c: Changelog) {
	text, _ := read_text(fmt.tprintf("%s/CHANGELOG.md", root))
	c.nl = strings.contains(text, "\r\n") ? "\r\n" : "\n"
	c.lines = split_lines(text)
	c.first_release = -1
	for l, i in c.lines {
		if v := heading_version(l); v != "" {
			c.first_release, c.last_version = i, v
			break
		}
	}
	return
}

// A value of `name :: "text"` at the start of a line of a source.
source_version :: proc(root: string) -> string {
	text, _ := read_text(fmt.tprintf("%s/%s", root, VERSION_FILE))
	for l in split_lines(text) {
		rest := strings.trim_prefix(l, "VERSION ")
		if rest == l { continue }
		first := strings.index_byte(rest, '"')
		if first < 0 { continue }
		last := strings.last_index_byte(rest, '"')
		if last > first { return rest[first + 1:last] }
	}
	return ""
}

// The version is written in the sources and in the README's badge.
write_source_version :: proc(root, version: string) {
	path := fmt.tprintf("%s/%s", root, VERSION_FILE)
	text, ok := read_text(path)
	if ok {
		end := strings.index_any(version, "-+")
		parts := strings.split(end >= 0 ? version[:end] : version, ".", context.temp_allocator)
		sb := strings.builder_make(context.temp_allocator)
		nl := strings.contains(text, "\r\n") ? "\r\n" : "\n"
		lines := split_lines(text)
		for l, i in lines {
			line := l
			switch {
			case strings.has_prefix(l, "VERSION_MAJOR "): line = fmt.tprintf("VERSION_MAJOR :: %s", parts[0])
			case strings.has_prefix(l, "VERSION_MINOR "): line = fmt.tprintf("VERSION_MINOR :: %s", parts[1])
			case strings.has_prefix(l, "VERSION_PATCH "): line = fmt.tprintf("VERSION_PATCH :: %s", parts[2])
			case strings.has_prefix(l, "VERSION "): line = fmt.tprintf("VERSION :: %q", version)
			}
			strings.write_string(&sb, line)
			if i + 1 < len(lines) { strings.write_string(&sb, nl) }
		}
		write_text(path, strings.to_string(sb))
	}
	path = fmt.tprintf("%s/README.md", root)
	if readme, has := read_text(path); has {
		write_text(path, with_badge(readme, version))
	}
}

// `badge/version-<v>-<hex6>` and `alt="version <v>"`: the version replaced.
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

// `strong` text first when there is some.
slug :: proc(s: string) -> string {
	text := s
	if a := strings.index(text, "**"); a >= 0 {
		if b := strings.index(text[a + 2:], "**"); b > 0 { text = text[a + 2:][:b] }
	}
	sb := strings.builder_make(context.temp_allocator)
	dash := true   // (no dash at the start)
	for c in transmute([]u8)base.ascii_lower(text) {
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

date_of :: proc(when_: time.Time) -> string {
	y, mo, d := time.date(when_)
	return fmt.tprintf("%04d-%02d-%02d", y, int(mo), d)
}

// Writes a fragment: its path, or why not.
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
	dir := fmt.tprintf("%s/changelog.d", root)
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

// Whether all is well: what is wrong in `errors`. `release`: and ready to tag that version.
check :: proc(root: string, release := "") -> (errors: [dynamic]string, fragments: int) {
	errors.allocator = context.temp_allocator
	c := read_changelog(root)
	frags := read_fragments(root, &errors)
	fragments = len(frags)
	released := make(map[string]bool, allocator = context.temp_allocator)
	for l in c.lines { if strings.has_prefix(l, "- ") { released[entry_key(l[2:])] = true } }
	seen := make(map[string]string, allocator = context.temp_allocator)
	for f in frags {
		for p in f.problems { append(&errors, fmt.tprintf("changelog.d/%s: %s", f.name, p)) }
		if len(f.lines) == 0 { continue }
		key := entry_key(f.lines[0])
		if key in released { append(&errors, fmt.tprintf("changelog.d/%s: already in a released section of CHANGELOG.md (assembled but not deleted)", f.name)) }
		if other, twice := seen[key]; twice { append(&errors, fmt.tprintf("changelog.d/%s: the same text as changelog.d/%s", f.name, other)) } else { seen[key] = f.name }
	}
	said := source_version(root)
	if said == "" {
		append(&errors, fmt.tprintf("VERSION not found in %s", VERSION_FILE))
	} else if c.last_version != "" && said != c.last_version {
		append(&errors, fmt.tprintf("the sources say version %s, the last released one is %s: the version is written when a version is published (tools/changelog -assemble -version), never by a branch", said, c.last_version))
	}
	if release != "" {
		if len(frags) > 0 { append(&errors, fmt.tprintf("%d fragments are not assembled: tools/changelog -assemble -version:%s", len(frags), release)) }
		if c.last_version != release { append(&errors, fmt.tprintf("the latest section of CHANGELOG.md is '%s', not %s", c.last_version, release)) }
		if said != release { append(&errors, fmt.tprintf("the sources say version %s, not %s", said, release)) }
	}
	return
}

// What the next version brings ("": nothing).
preview :: proc(root: string) -> (text: string, errors: [dynamic]string) {
	errors.allocator = context.temp_allocator
	frags := read_fragments(root, &errors)
	for f in frags { for p in f.problems { append(&errors, fmt.tprintf("changelog.d/%s: %s", f.name, p)) } }
	body := render_body(frags)
	if len(body) == 0 { return "", errors }
	return fmt.tprintf("%s\n", strings.join(body, "\n", context.temp_allocator)), errors
}

// The release: the section, the version, the fragments gone. `date` "": today.
assemble :: proc(root, version: string, date := "") -> (entries: int, errors: [dynamic]string) {
	errors.allocator = context.temp_allocator
	frags := read_fragments(root, &errors)
	for f in frags { for p in f.problems { append(&errors, fmt.tprintf("changelog.d/%s: %s", f.name, p)) } }
	if len(errors) > 0 { return }
	if !version_is_good(version) { append(&errors, fmt.tprintf("the version is x.y.z (got '%s')", version)); return }
	c := read_changelog(root)
	for l in c.lines {
		if heading_version(l) == version { append(&errors, fmt.tprintf("CHANGELOG.md already has a section %s", version)); return }
	}
	if len(frags) == 0 { append(&errors, "nothing to publish: no fragment in changelog.d/"); return }
	day := date != "" ? date : date_of(time.now())
	all := make([dynamic]string, context.temp_allocator)
	at := c.first_release >= 0 ? c.first_release : len(c.lines)
	append(&all, ..c.lines[:at])
	if c.first_release < 0 {
		for len(all) > 0 && all[len(all) - 1] == "" { pop(&all) }
		append(&all, "")
	}
	append(&all, fmt.tprintf("## [%s] - %s", version, day), "")
	append(&all, ..render_body(frags))
	append(&all, "")
	if c.first_release >= 0 { append(&all, ..c.lines[at:]) } else { append(&all, "") }
	ref := fmt.tprintf("[%s]: %s", version, fmt.tprintf(LINK, version))
	link_at := -1
	for l, i in all {
		if strings.has_prefix(l, "[") && strings.contains(l, "]: ") && len(l) > 1 && is_digit(l[1]) { link_at = i; break }
	}
	if link_at >= 0 {
		inject_at(&all, link_at, ref)
	} else {
		for len(all) > 0 && all[len(all) - 1] == "" { pop(&all) }
		append(&all, "", ref, "")
	}
	write_text(fmt.tprintf("%s/CHANGELOG.md", root), strings.join(all[:], c.nl, context.temp_allocator))
	write_source_version(root, version)
	for f in frags { _ = os.remove(f.path) }
	return len(frags), errors
}

// The body of a version's section. ok = false: it has none.
section :: proc(root, version: string) -> (body: string, ok: bool) {
	c := read_changelog(root)
	start := -1
	for l, i in c.lines { if heading_version(l) == version { start = i; break } }
	if start < 0 { return }
	end := len(c.lines)
	for i in start + 1 ..< len(c.lines) { if strings.has_prefix(c.lines[i], "## ") { end = i; break } }
	return fmt.tprintf("%s\n", strings.trim_space(strings.join(c.lines[start + 1:end], "\n", context.temp_allocator))), true
}

main :: proc() {
	flag :: proc(name: string) -> (string, bool) {
		for a in cmdline.joined(os.args[1:], context.temp_allocator) {
			if a == name { return "", true }
			if strings.has_prefix(a, name) && len(a) > len(name) && a[len(name)] == ':' { return a[len(name) + 1:], true }
		}
		return "", false
	}
	root, has_root := flag("-root")
	if !has_root { root = "." }
	version, _ := flag("-version")
	out, _ := flag("-out")
	report :: proc(errors: []string) { for e in errors { fmt.printfln("error: %s", e) } }
	if _, on := flag("-new"); on {
		type, _ := flag("-type")
		subject, _ := flag("-subject")
		text, _ := flag("-text")
		path, why := new_fragment(root, type, subject, text)
		if why != "" { fmt.printfln("error: %s", why); os.exit(1) }
		fmt.println(path)
		return
	}
	if _, on := flag("-section"); on {
		body, ok := section(root, version)
		if !ok { fmt.printfln("error: CHANGELOG.md has no section %s", version); os.exit(1) }
		if out != "" { write_text(out, body) } else { fmt.print(body) }
		return
	}
	if _, on := flag("-check"); on {
		release, _ := flag("-release")
		errors, n := check(root, release)
		report(errors[:])
		if len(errors) > 0 { os.exit(1) }
		fmt.printfln("changelog: %d fragments, well formed%s", n, release != "" ? fmt.tprintf("; ready to publish %s", release) : "")
		return
	}
	if _, on := flag("-assemble"); on {
		if version == "" {
			text, errors := preview(root)
			report(errors[:])
			if len(errors) > 0 { os.exit(1) }
			if out != "" { write_text(out, text) } else { fmt.print(text) }
			return
		}
		date, _ := flag("-date")
		n, errors := assemble(root, version, date)
		report(errors[:])
		if len(errors) > 0 { os.exit(1) }
		fmt.printfln("CHANGELOG.md: section %s (%d entries); commit the deletion of the fragments with it", version, n)
		return
	}
	fmt.println("tools/changelog: -new, -check, -assemble or -section (see the head of its source)")
	os.exit(1)
}

// The toolkit's CHANGELOG, on the command line: the fragments of changelog.d/ (src/changelog, docs/changelog.md says the
// format), with what is the toolkit's own: its releases' links, its version in src/ui/version.odin and the README's badge.
//
//   odin run tools/changelog -- -new -type:Added -subject:storage -text:"**...**: ..."    writes one
//   odin run tools/changelog -- -check                       every fragment well formed, none already in CHANGELOG.md (CI)
//   odin run tools/changelog -- -check -release:0.4.0        ready to tag 0.4.0: no fragment left, its section there, the version said
//   odin run tools/changelog -- -assemble                    what the next version brings, printed
//   odin run tools/changelog -- -assemble -version:0.4.0     the release: a "## [0.4.0] - <date>" section in CHANGELOG.md, the version written in
//                                                            ui/version.odin and the README's badge, the fragments deleted (tk release does it)
//   odin run tools/changelog -- -section -version:0.4.0 [-out:f.md]   the body of that version's section (release notes)
// -root:dir works on another checkout. Exit code 0 when all is well, 1 otherwise. tests/changelog calls `options` and the package.
package changelog_tool

import "core:fmt"
import "core:os"
import "core:strings"
import "../cmdline"
import changelog "../../src/changelog"

LINK :: "https://github.com/sachahjkl/gui_toolkit/releases/tag/v%s"
VERSION_FILE :: "src/ui/version.odin"

// The toolkit's checkout at `root`, for the package.
options :: proc(root: string) -> changelog.Options {
	return {root = root, link = LINK, version = source_version, set_version = write_source_version}
}

@(private = "file")
read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return string(data), err == nil
}

@(private = "file") write_text :: proc(path, text: string) -> bool { return os.write_entire_file(path, transmute([]byte)text) == nil }

@(private = "file")
split_lines :: proc(s: string) -> []string {
	t, _ := strings.replace_all(s, "\r\n", "\n", context.temp_allocator)
	return strings.split(t, "\n", context.temp_allocator)
}

// The value of `VERSION :: "text"` in ui/version.odin.
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
write_source_version :: proc(root, version: string) -> bool {
	path := fmt.tprintf("%s/%s", root, VERSION_FILE)
	text, ok := read_text(path)
	if !ok { return false }
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
	if !write_text(path, strings.to_string(sb)) { return false }
	path = fmt.tprintf("%s/README.md", root)
	if readme, has := read_text(path); has { return write_text(path, changelog.with_badge(readme, version)) }
	return true
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
		path, why := changelog.new_fragment(root, type, subject, text)
		if why != "" { fmt.printfln("error: %s", why); os.exit(1) }
		fmt.println(path)
		return
	}
	if _, on := flag("-section"); on {
		body, ok := changelog.section(root, version)
		if !ok { fmt.printfln("error: CHANGELOG.md has no section %s", version); os.exit(1) }
		if out != "" { write_text(out, body) } else { fmt.print(body) }
		return
	}
	if _, on := flag("-check"); on {
		release, _ := flag("-release")
		errors, n := changelog.check(options(root), release)
		report(errors[:])
		if len(errors) > 0 { os.exit(1) }
		fmt.printfln("changelog: %d fragments, well formed%s", n, release != "" ? fmt.tprintf("; ready to publish %s", release) : "")
		return
	}
	if _, on := flag("-assemble"); on {
		if version == "" {
			text, errors := changelog.preview(root)
			report(errors[:])
			if len(errors) > 0 { os.exit(1) }
			if out != "" { write_text(out, text) } else { fmt.print(text) }
			return
		}
		date, _ := flag("-date")
		n, errors := changelog.assemble(options(root), version, date)
		report(errors[:])
		if len(errors) > 0 { os.exit(1) }
		fmt.printfln("CHANGELOG.md: section %s (%d entries); commit the deletion of the fragments with it", version, n)
		return
	}
	fmt.println("tools/changelog: -new, -check, -assemble or -section (see the head of its source)")
	os.exit(1)
}

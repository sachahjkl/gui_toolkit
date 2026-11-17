package tk_desktop

// The edit of a mimeapps.list (the MIME Applications specification) that the File_Manager and Default_Documents parts
// of Linux make: the default application of one type, in [Default Applications]. Pure text, so the tests run it on every system; the
// backend reads and writes the file (integration_linux.odin). open_with_linux.odin reads the same files for a whole
// database; this edits one line and keeps every other byte of the person's file.

import "core:strings"

// The type of a folder (shared-mime-info): its default application is the file manager.
DIRECTORY_MIME :: "inode/directory"

// The first desktop file id that [Default Applications] gives `mime` ("" when none).
mimeapps_default :: proc(text, mime: string) -> string {
	ids := mimeapps_defaults(text, mime)
	return len(ids) > 0 ? ids[0] : ""
}

// The desktop file ids that [Default Applications] gives `mime`, in their order (temp memory; the first line of the
// type: a second one is the person's mistake, which applications read differently).
mimeapps_defaults :: proc(text, mime: string) -> []string {
	group := ""
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' { continue }
		if l[0] == '[' { group = l; continue }
		if group != "[Default Applications]" { continue }
		eq := strings.index_byte(l, '=')
		if eq < 0 || strings.trim_space(l[:eq]) != mime { continue }
		return split_ids(l[eq + 1:])
	}
	return nil
}

// `text` with `id` first in the [Default Applications] line of `mime` (`on`), or taken out of it (not `on`; a line left
// empty goes). The ids the line had stay after it, so removal gives the person's former default back. Every other line
// is kept as it was. In `allocator`.
mimeapps_with_default :: proc(text, mime, id: string, on: bool, allocator := context.temp_allocator) -> string {
	out := make([dynamic]string, context.temp_allocator)
	group := ""
	placed := false
	header := -1   // the index in `out` of the [Default Applications] header
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l != "" && l[0] == '[' {
			group = l
			append(&out, line)
			if l == "[Default Applications]" && header < 0 { header = len(out) - 1 }
			continue
		}
		eq := strings.index_byte(l, '=')
		if group != "[Default Applications]" || l == "" || l[0] == '#' || eq < 0 || strings.trim_space(l[:eq]) != mime {
			append(&out, line)
			continue
		}
		others := make([dynamic]string, context.temp_allocator)
		if on && !placed { append(&others, id) }
		for x in split_ids(l[eq + 1:]) { if x != id { append(&others, x) } }
		placed ||= on
		if len(others) > 0 { append(&out, ids_line(mime, others[:])) }
	}
	if on && !placed {
		if header >= 0 {
			inject_at(&out, header + 1, ids_line(mime, {id}))
		} else {
			if len(out) > 0 && strings.trim_space(out[len(out) - 1]) != "" { append(&out, "") }
			append(&out, "[Default Applications]", ids_line(mime, {id}))
		}
	}
	sb := strings.builder_make(allocator)
	for line in out { strings.write_string(&sb, line); strings.write_byte(&sb, '\n') }
	return strings.to_string(sb)
}

// "a.desktop;b.desktop;" -> ["a.desktop", "b.desktop"] (the specification separates by ';'; empty items go).
@(private = "file")
split_ids :: proc(value: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	rest := value
	for item in strings.split_iterator(&rest, ";") {
		if x := strings.trim_space(item); x != "" { append(&out, x) }
	}
	return out[:]
}

@(private = "file")
ids_line :: proc(mime: string, ids: []string) -> string {
	return strings.concatenate({mime, "=", strings.join(ids, ";", context.temp_allocator), ";"}, context.temp_allocator)
}

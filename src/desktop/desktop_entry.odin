package tk_desktop

// The text of a freedesktop.org Desktop Entry (https://specifications.freedesktop.org/desktop-entry-spec/latest/): made
// and read here, whatever the platform, so the Linux backend's output is checked by the tests on any machine. Nothing in
// this file touches the disk.

import "core:fmt"
import "core:strings"

// The file's marker line is `Identity.entry_marker`: the Linux backend writes it and trusts only files that carry it (or
// that run the executable) when it removes or repairs one. Keys that begin with X- are for applications' own use.

Content_Type :: struct { ext, mime: string }

// The web documents a browser may be offered for. The extension is what Windows registers, the MIME type what the
// desktop entry lists.
CONTENT_TYPES := [?]Content_Type{
	{".htm", "text/html"}, {".html", "text/html"}, {".shtml", "text/html"},
	{".xhtml", "application/xhtml+xml"}, {".xht", "application/xhtml+xml"},
	{".svg", "image/svg+xml"}, {".webp", "image/webp"}, {".avif", "image/avif"},
	{".png", "image/png"}, {".jpg", "image/jpeg"}, {".jpeg", "image/jpeg"}, {".gif", "image/gif"},
	{".pdf", "application/pdf"}, {".txt", "text/plain"}, {".xml", "text/xml"},
}

SCHEME_MIME_TYPES :: [?]string{"x-scheme-handler/http", "x-scheme-handler/https"}
SCHEME_MIME_PREFIX :: "x-scheme-handler/"

mime_of_extension :: proc(ext: string) -> string {
	e := normalize_extension(ext)
	for c in CONTENT_TYPES { if c.ext == e { return c.mime } }
	return ""
}

// The MIME types a browser's entry lists: the two web schemes, the program's own URL schemes, then those of the file
// types (each once, in order).
mime_types :: proc(file_types: []string, url_schemes: []string = nil, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for s in SCHEME_MIME_TYPES { append(&out, s) }
	for s in url_schemes { append(&out, strings.concatenate({SCHEME_MIME_PREFIX, s}, allocator)) }
	for ft in file_types {
		m := mime_of_extension(ft)
		if m == "" { continue }
		seen := false
		for o in out { if o == m { seen = true; break } }
		if !seen { append(&out, m) }
	}
	return out[:]
}

// A string value of the file: backslash, newline, tab and carriage return are escaped.
escape_value :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !strings.contains_any(s, "\\\n\t\r") { return s }
	sb := strings.builder_make(allocator)
	for r in s {
		switch r {
		case '\\': strings.write_string(&sb, "\\\\")
		case '\n': strings.write_string(&sb, "\\n")
		case '\t': strings.write_string(&sb, "\\t")
		case '\r': strings.write_string(&sb, "\\r")
		case:      strings.write_rune(&sb, r)
		}
	}
	return strings.to_string(sb)
}

unescape_value :: proc(s: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(s, '\\') < 0 { return s }
	sb := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] != '\\' || i + 1 >= len(s) { strings.write_byte(&sb, s[i]); continue }
		i += 1
		switch s[i] {
		case 's':  strings.write_byte(&sb, ' ')
		case 'n':  strings.write_byte(&sb, '\n')
		case 't':  strings.write_byte(&sb, '\t')
		case 'r':  strings.write_byte(&sb, '\r')
		case '\\': strings.write_byte(&sb, '\\')
		case:      strings.write_byte(&sb, '\\'); strings.write_byte(&sb, s[i])
		}
	}
	return strings.to_string(sb)
}

// One argument of an Exec line, as the specification quotes it: any of the reserved characters puts it in double
// quotes, with the backslash, quote, dollar and backtick escaped; `%` is doubled (a field code otherwise). The result
// is still to be escaped as a string value (`escape_value`).
quote_exec_argument :: proc(arg: string, allocator := context.temp_allocator) -> string {
	reserved := strings.contains_any(arg, " \t\n\"'\\><~|&;$*?#()`") || arg == ""
	sb := strings.builder_make(allocator)
	if reserved { strings.write_byte(&sb, '"') }
	for r in arg {
		switch r {
		case '"', '`', '$', '\\':
			if reserved { strings.write_byte(&sb, '\\') }
			strings.write_rune(&sb, r)
		case '%': strings.write_string(&sb, "%%")
		case:     strings.write_rune(&sb, r)
		}
	}
	if reserved { strings.write_byte(&sb, '"') }
	return strings.to_string(sb)
}

// The program an Exec value launches (its first argument, unquoted); "" for an empty value.
exec_program :: proc(exec_value: string, allocator := context.temp_allocator) -> string {
	args := exec_arguments(exec_value, context.temp_allocator)
	if len(args) == 0 { return "" }
	program, _ := strings.replace_all(args[0].text, "%%", "%", allocator)
	return program
}

// One argument of an Exec value, unquoted. `quoted`: some of it was in double quotes, where the specification forbids
// field codes (exec_expand refuses them there: a file name put in `sh -c "viewer %f"` would be read by the shell).
Exec_Argument :: struct {
	text:   string,
	quoted: bool,
}

// The arguments of an Exec value, unquoted as the specification says: a string value first (unescape_value), then
// arguments apart by spaces, a double-quoted one with `\"`, `` \` ``, `\$` and `\\` escaped. A field code stays as it is
// (`%f`), and `%%` stays `%%`: exec_expand reads them.
exec_arguments :: proc(exec_value: string, allocator := context.temp_allocator) -> []Exec_Argument {
	v := unescape_value(exec_value)
	out := make([dynamic]Exec_Argument, allocator)
	sb := strings.builder_make(context.temp_allocator)
	in_arg, quoted, was_quoted := false, false, false
	for i := 0; i < len(v); i += 1 {
		c := v[i]
		switch {
		case quoted && c == '"': quoted = false
		case quoted && c == '\\' && i + 1 < len(v):
			i += 1
			strings.write_byte(&sb, v[i])
		case !quoted && c == '"': quoted, in_arg, was_quoted = true, true, true
		case !quoted && (c == ' ' || c == '\t'):
			if in_arg { append(&out, Exec_Argument{strings.clone(strings.to_string(sb), allocator), was_quoted}) }
			strings.builder_reset(&sb)
			in_arg, was_quoted = false, false
		case:
			strings.write_byte(&sb, c)
			in_arg = true
		}
	}
	if in_arg { append(&out, Exec_Argument{strings.clone(strings.to_string(sb), allocator), was_quoted}) }
	return out[:]
}

// The command an application's Exec value runs to open `path`: its field codes replaced (%f %F %u %U the path, %c the
// name, %k the desktop file, %i "--icon" and the icon when there is one, %% a %; the deprecated ones dropped). A value
// with no file code gets the path at its end. Not `ok`, as the specification says, for: an unknown field code (a `%`
// at the end too), a field code other than %% in a quoted argument, %F %U or %i inside an argument, more than one
// file code, no program.
exec_expand :: proc(exec_value, path, name, icon, desktop_file: string, allocator := context.temp_allocator) -> (args: []string, ok: bool) {
	out := make([dynamic]string, allocator)
	placed := false
	for a in exec_arguments(exec_value, context.temp_allocator) {
		if !a.quoted {
			switch a.text {
			case "%f", "%F", "%u", "%U":
				if placed { return nil, false }
				append(&out, strings.clone(path, allocator))
				placed = true
				continue
			case "%i":
				if icon != "" { append(&out, strings.clone("--icon", allocator), strings.clone(icon, allocator)) }
				continue
			case "%d", "%D", "%n", "%N", "%v", "%m":
				continue
			}
		}
		sb := strings.builder_make(allocator)
		for i := 0; i < len(a.text); i += 1 {
			if a.text[i] != '%' { strings.write_byte(&sb, a.text[i]); continue }
			if i + 1 >= len(a.text) { return nil, false }
			i += 1
			code := a.text[i]
			if code == '%' { strings.write_byte(&sb, '%'); continue }
			if a.quoted { return nil, false }
			switch code {
			case 'c': strings.write_string(&sb, name)
			case 'k': strings.write_string(&sb, desktop_file)
			case 'f', 'u':
				if placed { return nil, false }
				strings.write_string(&sb, path)
				placed = true
			case 'd', 'D', 'n', 'N', 'v', 'm':
			case: return nil, false   // %F %U %i inside an argument, or a code the specification does not list
			}
		}
		append(&out, strings.to_string(sb))
	}
	if len(out) == 0 { return nil, false }
	if !placed { append(&out, strings.clone(path, allocator)) }
	return out[:], true
}

// The value of `key` in the [Desktop Entry] group ("" when absent). Comments, blank lines, other groups and
// localized keys (Name[fr]) are skipped; the value is returned as written (not unescaped).
entry_value :: proc(text, key: string) -> (value: string, found: bool) {
	in_group := false
	rest := text
	for len(rest) > 0 {
		line: string
		if i := strings.index_byte(rest, '\n'); i >= 0 { line, rest = rest[:i], rest[i + 1:] } else { line, rest = rest, "" }
		line = strings.trim_right(line, "\r")
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == '#' { continue }
		if trimmed[0] == '[' { in_group = trimmed == "[Desktop Entry]"; continue }
		if !in_group { continue }
		eq := strings.index_byte(trimmed, '=')
		if eq < 0 { continue }
		if strings.trim_space(trimmed[:eq]) == key { return strings.trim_left_space(trimmed[eq + 1:]), true }
	}
	return "", false
}

// The desktop entry of an integration of `o`. Lines are LF-terminated and in the order the specification's own examples
// use; every value is escaped, the Exec line quoted. A program that opens addresses (a browser, URL schemes of its own)
// takes them as `%U`.
desktop_entry_text :: proc(o: ^Options, allocator := context.temp_allocator) -> string {
	id := o.identity
	sb := strings.builder_make(allocator)
	line :: proc(sb: ^strings.Builder, key, value: string) { fmt.sbprintf(sb, "%s=%s\n", key, value) }
	strings.write_string(&sb, "[Desktop Entry]\n")
	line(&sb, "Type", "Application")
	line(&sb, "Version", "1.0")
	line(&sb, "Name", escape_value(id.name))
	if id.generic_name != "" { line(&sb, "GenericName", escape_value(id.generic_name)) }
	if id.description != "" { line(&sb, "Comment", escape_value(id.description)) }
	opens := o.register_browser || len(id.url_schemes) > 0
	line(&sb, "Exec", escape_value(strings.concatenate({quote_exec_argument(o.exe), opens ? " %U" : ""}, context.temp_allocator)))
	line(&sb, "TryExec", escape_value(o.exe))
	line(&sb, "Icon", id.slug)
	line(&sb, "Terminal", "false")
	line(&sb, "StartupNotify", "true")
	// (the window's class is the slug: a launcher and a dock match the window to this entry by it, on X11 and Wayland)
	line(&sb, "StartupWMClass", id.slug)
	if id.categories != "" { line(&sb, "Categories", escape_value(id.categories)) }
	if id.keywords != "" { line(&sb, "Keywords", escape_value(id.keywords)) }
	if o.register_browser {
		sb2 := strings.builder_make(context.temp_allocator)
		for m in mime_types(o.file_types, id.url_schemes) { strings.write_string(&sb2, m); strings.write_byte(&sb2, ';') }
		line(&sb, "MimeType", strings.to_string(sb2))
	}
	if len(id.actions) > 0 {
		ids := strings.builder_make(context.temp_allocator)
		for a in id.actions { strings.write_string(&ids, a.id); strings.write_byte(&ids, ';') }
		line(&sb, "Actions", strings.to_string(ids))
	}
	line(&sb, id.entry_marker, id.slug)
	// (the actions' groups after the main one: a key after a group's header is that group's)
	for a in id.actions {
		fmt.sbprintf(&sb, "\n[Desktop Action %s]\n", a.id)
		line(&sb, "Name", escape_value(a.name))
		exec := quote_exec_argument(o.exe)
		if a.arguments != "" { exec = strings.concatenate({exec, " ", a.arguments}, context.temp_allocator) }
		line(&sb, "Exec", escape_value(exec))
	}
	return strings.to_string(sb)
}

// The autostart entry of `o` (the XDG Autostart specification): the program with `autostart_arguments`, at the start of
// the session, marked as the program's as its desktop entry is.
autostart_entry_text :: proc(o: ^Options, allocator := context.temp_allocator) -> string {
	id := o.identity
	sb := strings.builder_make(allocator)
	line :: proc(sb: ^strings.Builder, key, value: string) { fmt.sbprintf(sb, "%s=%s\n", key, value) }
	strings.write_string(&sb, "[Desktop Entry]\n")
	line(&sb, "Type", "Application")
	line(&sb, "Version", "1.0")
	line(&sb, "Name", escape_value(id.name))
	if id.description != "" { line(&sb, "Comment", escape_value(id.description)) }
	exec := quote_exec_argument(o.exe)
	if o.autostart_arguments != "" { exec = strings.concatenate({exec, " ", o.autostart_arguments}, context.temp_allocator) }
	line(&sb, "Exec", escape_value(exec))
	line(&sb, "TryExec", escape_value(o.exe))
	line(&sb, "Icon", id.slug)
	line(&sb, "Terminal", "false")
	line(&sb, "X-GNOME-Autostart-enabled", "true")
	line(&sb, id.entry_marker, id.slug)
	return strings.to_string(sb)
}

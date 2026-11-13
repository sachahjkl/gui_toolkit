package tk_config

// The preferences as text: our own format (the profile file, that load_file reads back), and the formats of other
// programs' settings files (JSON, TOML, INI) for a user who keeps them with the rest of their configuration. Those are
// written only: a foreign file is no layer this registry reads.
//
// `all`: every preference with its value for this run; else the user's layer only (what differs from the defaults).
// The foreign formats hold the settings: a hidden preference (the program's state) is not in them, nor a user value no
// definition registers or accepts in this run (it has no type to write). Our own format holds all of them, so a round
// trip loses none.
//
// The writers build the text by hand: a value is data and never reaches a format string.

import "core:slice"
import "core:strconv"
import "core:strings"

// Our own format: a tag line (USER_MAGIC), then `name<TAB>value` sorted by name, with `\\`, `\n`, `\r`, `\t` escapes.
// With `all = false` it is the profile file's text: the user's changes (and only those), with the values a higher layer
// hides and those no definition registers in this run. Pure and cheap (a few KiB): the loop calls it, then hands the text
// to write_user_file on any thread, and records `p.user_version` as the version this text has.
export_own :: proc(p: ^Prefs, all := false, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, USER_MAGIC)
	strings.write_byte(&sb, '\n')
	for name in sorted_names(p) {
		e := &p.entries[p.index[name]]
		if all || e.source == .User {
			own_line(&sb, name, value_text(e.def, e.value))
		} else if e.has_user {
			own_line(&sb, name, e.user_text)
		}
	}
	// values for preferences that are not registered in this run must survive a round trip; sorted, so the same layer
	// gives the same bytes whatever the map's order
	waiting := make([dynamic]string, context.temp_allocator)
	for name, pv in p.pending { if pv.has[.User] { append(&waiting, name) } }
	slice.sort(waiting[:])
	for name in waiting { own_line(&sb, name, p.pending[name].value[.User]) }
	return strings.to_string(sb)
}

// One flat object, a key per preference, as the settings.json of Zed or VS Code:
//
//   {
//     "appearance.text.gamma": 1.8,
//     "appearance.theme": "dark"
//   }
//
// A Float always has a decimal point or an exponent, so a reader keeps its type.
export_json :: proc(p: ^Prefs, all := false, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	items := exported(p, all)
	if len(items) == 0 {
		strings.write_string(&sb, "{}\n")
		return strings.to_string(sb)
	}
	strings.write_string(&sb, "{\n")
	for it, i in items {
		strings.write_string(&sb, "  ")
		quoted(&sb, it.name)
		strings.write_string(&sb, ": ")
		typed(&sb, it, .JSON)
		strings.write_string(&sb, i + 1 < len(items) ? ",\n" : "\n")
	}
	strings.write_string(&sb, "}\n")
	return strings.to_string(sb)
}

// A table per group, a key per preference (its name's last segment):
//
//   [appearance]
//   theme = "dark"
//
//   [appearance.text]
//   gamma = 1.8
//
// A name of one segment goes before the first table. A preference whose name is also a group's path ("browser.tabs" and
// "browser.tabs.width") cannot be a key and a table at once: it goes there too, under its whole name quoted
// (`"browser.tabs" = true`).
export_toml :: proc(p: ^Prefs, all := false, allocator := context.allocator) -> string {
	return export_tables(p, all, .TOML, allocator)
}

// A section per group, `key=value` per preference (its name's last segment):
//
//   [appearance]
//   theme=dark
//
//   [appearance.text]
//   gamma=1.8
//
// A name of one segment goes before the first section. INI has no standard escapes: a string is written as it is, and
// between double quotes with the escapes of JSON when it would not read back so (spaces at an end, a control character,
// `"`, `\`, `;` or `#`).
export_ini :: proc(p: ^Prefs, all := false, allocator := context.allocator) -> string {
	return export_tables(p, all, .INI, allocator)
}

@(private = "file")
Format :: enum u8 { JSON, TOML, INI }

// A preference an export writes, with the value it has in the chosen layer.
@(private = "file")
Item :: struct {
	name:  string,
	kind:  Kind,
	value: Value,
	table: string,   // the path of its last group ("": none)
	key:   string,   // what is written before its value in a table
}

// The settings an export writes, sorted by name (see the head of the file).
@(private = "file")
exported :: proc(p: ^Prefs, all: bool) -> []Item {
	out := make([dynamic]Item, context.temp_allocator)
	for name in sorted_names(p) {
		e := &p.entries[p.index[name]]
		if e.def.hidden { continue }
		v: Value
		if all || e.source == .User {
			v = e.value
		} else if e.has_user {
			err: Set_Error
			v, err = parse_value(e.def, e.user_text)
			if err != .None { continue }   // refused in this run: no type to write
		} else {
			continue
		}
		path := path_of(name)
		table := len(path) > 0 ? path[len(path) - 1] : ""
		append(&out, Item{name = name, kind = e.def.kind, value = v, table = table, key = leaf_of(name)})
	}
	return out[:]
}

// TOML and INI: the preferences of no group first, then a table per group, in the order of their paths.
@(private = "file")
export_tables :: proc(p: ^Prefs, all: bool, format: Format, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	items := exported(p, all)
	if format == .TOML {
		// a key cannot also be a table: a name that is a group's path goes to the top, whole
		groups := make(map[string]bool, context.temp_allocator)
		for it in items { for path in path_of(it.name) { groups[path] = true } }
		for &it in items { if groups[it.name] { it.table, it.key = "", it.name } }
	}
	tables := make([dynamic]string, context.temp_allocator)
	for it in items { if it.table != "" && !slice.contains(tables[:], it.table) { append(&tables, it.table) } }
	slice.sort(tables[:])
	for it in items { if it.table == "" { table_line(&sb, it, format) } }
	for table in tables {
		if len(sb.buf) > 0 { strings.write_byte(&sb, '\n') }
		strings.write_byte(&sb, '[')
		if format == .TOML {
			rest := table
			first := true
			for segment in strings.split_iterator(&rest, ".") {
				if !first { strings.write_byte(&sb, '.') }
				first = false
				toml_key(&sb, segment)
			}
		} else {
			strings.write_string(&sb, table)
		}
		strings.write_string(&sb, "]\n")
		for it in items { if it.table == table { table_line(&sb, it, format) } }
	}
	return strings.to_string(sb)
}

@(private = "file")
table_line :: proc(sb: ^strings.Builder, it: Item, format: Format) {
	if format == .TOML {
		toml_key(sb, it.key)
		strings.write_string(sb, " = ")
	} else {
		strings.write_string(sb, it.key)
		strings.write_byte(sb, '=')
	}
	typed(sb, it, format)
	strings.write_byte(sb, '\n')
}

// A value in the syntax of `format`.
@(private = "file")
typed :: proc(sb: ^strings.Builder, it: Item, format: Format) {
	switch it.kind {
	case .Bool:
		strings.write_string(sb, it.value.b ? "true" : "false")
	case .Int:
		strings.write_i64(sb, it.value.i)
	case .Float:
		s := float_text(it.value.f)
		strings.write_string(sb, s)
		// "2" would read back as an integer
		if format != .INI && strings.index_any(s, ".eE") < 0 { strings.write_string(sb, ".0") }
	case .String:
		if format == .INI && !ini_needs_quotes(it.value.s) {
			strings.write_string(sb, it.value.s)
		} else {
			quoted(sb, it.value.s)
		}
	}
}

// A string between double quotes with the escapes JSON and TOML's basic strings share: `"`, `\`, the usual control
// characters by their letter, the others (and DEL, which TOML refuses raw) as \u00XX.
@(private = "file")
quoted :: proc(sb: ^strings.Builder, s: string) {
	hex := "0123456789ABCDEF"
	strings.write_byte(sb, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"':  strings.write_string(sb, "\\\"")
		case '\\': strings.write_string(sb, "\\\\")
		case '\b': strings.write_string(sb, "\\b")
		case '\f': strings.write_string(sb, "\\f")
		case '\n': strings.write_string(sb, "\\n")
		case '\r': strings.write_string(sb, "\\r")
		case '\t': strings.write_string(sb, "\\t")
		case:
			if c < 0x20 || c == 0x7F {
				strings.write_string(sb, "\\u00")
				strings.write_byte(sb, hex[c >> 4])
				strings.write_byte(sb, hex[c & 0xF])
			} else {
				strings.write_byte(sb, c)
			}
		}
	}
	strings.write_byte(sb, '"')
}

// A TOML key: bare when it has only letters, digits, `_` and `-`; quoted else.
@(private = "file")
toml_key :: proc(sb: ^strings.Builder, key: string) {
	bare := len(key) > 0
	for c in transmute([]u8)key {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
		case: bare = false
		}
	}
	if bare { strings.write_string(sb, key) } else { quoted(sb, key) }
}

// Whether an INI value would not read back as it is: spaces at an end (a reader trims them), a control character, a
// quote or an escape (a reader may take them as ours), a comment's mark.
@(private = "file")
ini_needs_quotes :: proc(s: string) -> bool {
	if len(s) == 0 { return false }
	if s[0] == ' ' || s[len(s) - 1] == ' ' { return true }
	for c in transmute([]u8)s {
		if c < 0x20 || c == 0x7F || c == '"' || c == '\\' || c == ';' || c == '#' { return true }
	}
	return false
}

@(private = "file")
own_line :: proc(sb: ^strings.Builder, name, value: string) {
	strings.write_string(sb, name)
	strings.write_byte(sb, '\t')
	strings.write_string(sb, escape(value))
	strings.write_byte(sb, '\n')
}

// The shortest text that reads back as the same f64 (parse_value), in temp memory.
@(private)
float_text :: proc(f: f64) -> string {
	buf: [64]u8
	return strings.clone(strconv.write_float(buf[:], f, 'g', -1, 64, nil), context.temp_allocator)
}

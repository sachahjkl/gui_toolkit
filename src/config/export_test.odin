package tk_config

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../fsx"

// Every kind, strings a format must escape, floats that print in few digits only when printed with care, a name that
// is also a group's path, and the program's state.
@(private = "file")
EXPORT_DEFS := [?]Def{
	{name = "solo", kind = .Int, default = {i = 1}},
	{name = "browser.tabs", kind = .Bool},
	{name = "browser.tabs.width", kind = .Int, default = {i = 200}},
	{name = "appearance.theme", kind = .String, default = {s = "auto"}},
	{name = "appearance.text.gamma", kind = .Float, default = {f = 1.8}},
	{name = "appearance.text.label", kind = .String},
	{name = "general.name", kind = .String},
	{name = "general.on", kind = .Bool, default = {b = true}},
	{name = "layout.split", kind = .Float, default = {f = 0.5}, hidden = true},
	{name = "num.tenth", kind = .Float},
	{name = "num.sum", kind = .Float},
	{name = "num.huge", kind = .Float},
	{name = "num.tiny", kind = .Float},
	{name = "num.big", kind = .Int},
}

@(private = "file")
AWKWARD :: "say \"hi\"\\ back\\slash\nnew\tline\r\x01\x7F é ; # end "

@(private = "file")
export_prefs :: proc(p: ^Prefs) {
	p^ = prefs_make()
	register(p, EXPORT_DEFS[:])
	set_from_string(p, "solo", "3", .User)
	set_from_string(p, "browser.tabs", "true", .User)
	set_from_string(p, "browser.tabs.width", "240", .User)
	set_from_string(p, "appearance.theme", "dark \"x\"\\y", .User)
	set_from_string(p, "appearance.text.gamma", "2", .User)
	set_from_string(p, "appearance.text.label", "a\tb\n", .User)
	set_from_string(p, "general.name", "plain words", .User)
	set_from_string(p, "layout.split", "0.25", .User)
}

// The JSON reads back, with core:encoding/json, as the values the registry holds: types, escapes, floats to the bit.
@(test)
json_reads_back_as_the_values :: proc(t: ^testing.T) {
	p: Prefs
	export_prefs(&p)
	defer prefs_destroy(&p)
	set_from_string(&p, "general.name", AWKWARD, .User)
	set_from_string(&p, "num.tenth", "0.1", .User)
	set_from_string(&p, "num.sum", "0.30000000000000004", .User)
	set_from_string(&p, "num.huge", "1e300", .User)
	set_from_string(&p, "num.tiny", "-5e-324", .User)
	set_from_string(&p, "num.big", "-9223372036854775808", .User)
	set_from_string(&p, "general.on", "false", .User)
	set_from_string(&p, "general.on", "true", .Command_Line)   // the user's value under it is the one exported

	for all in ([]bool{false, true}) {
		text := export(&p, .Json, all, context.temp_allocator)
		v, err := json.parse_string(text, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
		testing.expectf(t, err == .None, "%v parses: %v", text, err)
		obj, ok := v.(json.Object)
		testing.expect(t, ok, "an object")
		testing.expect(t, "layout.split" not_in obj, "the program's state is no setting")
		count := 0
		for e in p.entries {
			if e.def.hidden { continue }
			got, found := obj[e.def.name]
			if !all && e.source != .User && !e.has_user {
				testing.expectf(t, !found, "%s: a default is not in the user's layer", e.def.name)
				continue
			}
			count += 1
			testing.expectf(t, found, "%s is exported", e.def.name)
			want := e.value
			if !all && e.source != .User { want, _ = parse_value(e.def, e.user_text) }
			same := false
			switch e.def.kind {
			case .Bool:   b, is := got.(json.Boolean); same = is && bool(b) == want.b
			case .Int:    i, is := got.(json.Integer); same = is && i64(i) == want.i
			case .Float:  f, is := got.(json.Float);   same = is && f64(f) == want.f
			case .String: s, is := got.(json.String);  same = is && string(s) == want.s
			}
			testing.expectf(t, same, "%s: %v", e.def.name, got)
		}
		testing.expect_value(t, len(obj), count)
	}
	q := prefs_make()
	defer prefs_destroy(&q)
	testing.expect_value(t, export(&q, .Json, allocator = context.temp_allocator), "{}\n")
}

@(test)
toml_has_a_table_per_group :: proc(t: ^testing.T) {
	p: Prefs
	export_prefs(&p)
	defer prefs_destroy(&p)
	testing.expect_value(t, export(&p, .Toml, allocator = context.temp_allocator), `"browser.tabs" = true
solo = 3

[appearance]
theme = "dark \"x\"\\y"

[appearance.text]
gamma = 2.0
label = "a\tb\n"

[browser.tabs]
width = 240

[general]
name = "plain words"
`)
	// every value: the defaults too, never the program's state
	all := export(&p, .Toml, all = true, allocator = context.temp_allocator)
	testing.expect(t, contains_line(all, "on = true"), "a default")
	testing.expect(t, !contains_line(all, "split = 0.25"), "hidden")
	// a key that is no bare key, and the control characters TOML does not take raw
	q := prefs_make()
	defer prefs_destroy(&q)
	register(&q, []Def{{name = "odd.with space", kind = .String}})
	set_from_string(&q, "odd.with space", "\x01\x7F", .User)
	testing.expect_value(t, export(&q, .Toml, allocator = context.temp_allocator), "[odd]\n\"with space\" = \"\\u0001\\u007F\"\n")
}

@(test)
ini_has_a_section_per_group :: proc(t: ^testing.T) {
	p: Prefs
	export_prefs(&p)
	defer prefs_destroy(&p)
	testing.expect_value(t, export(&p, .Ini, allocator = context.temp_allocator), `solo=3

[appearance]
theme="dark \"x\"\\y"

[appearance.text]
gamma=2
label="a\tb\n"

[browser]
tabs=true

[browser.tabs]
width=240

[general]
name=plain words
`)
	set_from_string(&p, "general.name", " padded", .User)
	testing.expect(t, contains_line(export(&p, .Ini, allocator = context.temp_allocator), `name=" padded"`), "a space a reader trims")
	set_from_string(&p, "general.name", "a ; b", .User)
	testing.expect(t, contains_line(export(&p, .Ini, allocator = context.temp_allocator), `name="a ; b"`), "a comment's mark")
}

// Our own format is what the profile file holds; with `all`, every value, and load_file reads either back.
@(test)
own_format_round_trips :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/wb_config_export_own_test.txt", fsx.temp_dir(context.temp_allocator))
	defer os.remove(path)
	p: Prefs
	export_prefs(&p)
	defer prefs_destroy(&p)
	set_from_string(&p, "general.name", AWKWARD, .User)
	set_from_string(&p, "num.sum", "0.30000000000000004", .User)
	set_from_string(&p, "num.tiny", "5e-324", .Command_Line)
	testing.expect_value(t, export(&p, .Own, allocator = context.temp_allocator),
		"wbprefs 1\n" +
		"appearance.text.gamma\t2\n" +
		"appearance.text.label\ta\\tb\\n\n" +
		"appearance.theme\tdark \"x\"\\\\y\n" +
		"browser.tabs\ttrue\n" +
		"browser.tabs.width\t240\n" +
		"general.name\tsay \"hi\"\\\\ back\\\\slash\\nnew\\tline\\r\x01\x7F é ; # end \n" +
		"layout.split\t0.25\n" +
		"num.sum\t0.30000000000000004\n" +
		"solo\t3\n")
	testing.expect(t, write_user_file(path, export(&p, .Own, all = true, allocator = context.temp_allocator)))
	q := prefs_make()
	defer prefs_destroy(&q)
	register(&q, EXPORT_DEFS[:])
	_, problems := load_file(&q, path, .User)
	testing.expect_value(t, len(problems), 0)
	for e in p.entries {
		f := q.entries[q.index[e.def.name]]
		testing.expectf(t, f.value == e.value, "%s: %v, not %v", e.def.name, f.value, e.value)
		testing.expectf(t, f.source == .User, "%s: in the user's layer", e.def.name)
	}
}

@(private = "file")
contains_line :: proc(text, line: string) -> bool {
	rest := text
	for l in strings.split_lines_iterator(&rest) { if l == line { return true } }
	return false
}

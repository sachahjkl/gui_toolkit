package tk_plugins

// A plugin's plugin.json: what the folder's chore reads, before any JavaScript runs (plugins.md, decision 5).

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import tk_json "../json"
import plugin_api "../plugin_api"

MANIFEST_FILE :: "plugin.json"
// The most a manifest may weigh: it is read whole, at each start.
MANIFEST_MAX_BYTES :: 256 * 1024
// The longest id of a plugin or of a command.
ID_MAX_BYTES :: 64

// A command a manifest declares: its id in the plugin, and what the palette shows.
Command_Decl :: struct {
	id:    string,
	label: string,
	group: string,
	icon:  string,
	tags:  []string,
}

// A manifest, read. Its strings are owned (manifest_destroy).
Manifest :: struct {
	id:       string,
	name:     string,
	version:  string,
	api:      int,
	main:     string,
	program:  string,   // "": any program
	commands: []Command_Decl,
}

manifest_destroy :: proc(m: ^Manifest) {
	delete(m.id); delete(m.name); delete(m.version); delete(m.main); delete(m.program)
	for c in m.commands {
		delete(c.id); delete(c.label); delete(c.group); delete(c.icon)
		for t in c.tags { delete(t) }
		delete(c.tags)
	}
	delete(m.commands)
	m^ = {}
}

// Whether `s` is an id: lower case ASCII letters, digits, '_' and '-' (a command's alphabet, ui.Command.id), and '.'
// when `dots` (a command's id may have them; a plugin's may not: `plugin.<id>.<command>` is split at its dots).
id_valid :: proc(s: string, dots: bool) -> bool {
	if s == "" || len(s) > ID_MAX_BYTES { return false }
	for c in transmute([]u8)s {
		switch c {
		case 'a' ..= 'z', '0' ..= '9', '_', '-':
		case '.': if !dots { return false }
		case: return false
		}
	}
	return true
}

// Reads a manifest's text. `refused`: why the plugin cannot load ("": none), in words for the Plugins page. A plugin
// refused keeps what was read of it (its id and name, when they are good), for the page to name it. `program`: the
// program's id (Host_Options.program_id); a manifest that names another program is refused.
manifest_parse :: proc(text: string, program: string, allocator := context.allocator) -> (m: Manifest, refused: string) {
	context.allocator = allocator
	v, err := json.parse_string(text, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if err != nil { return {}, fmt.aprintf("plugin.json is not JSON (%v)", err) }
	if _, is := v.(json.Object); !is { return {}, strings.clone("plugin.json is not an object") }

	m.id = strings.clone(tk_json.text(v, "id"))
	m.name = strings.clone(tk_json.text(v, "name", default = m.id))
	m.version = strings.clone(tk_json.text(v, "version"))
	m.main = strings.clone(tk_json.text(v, "main", default = "main.js"))
	m.program = strings.clone(tk_json.text(v, "program"))
	if !id_valid(m.id, false) {
		return m, fmt.aprintf("its id \"%s\" is not an id (lower case letters, digits, '_' and '-')", m.id)
	}
	api := tk_json.number(v, "api", default = -1)
	if api != math.floor(api) || api < 1 {
		return m, strings.clone("it does not say the level of the API it was written for (\"api\")")
	}
	m.api = int(api)
	if m.api > plugin_api.PLUGIN_API_LEVEL {
		return m, fmt.aprintf("it needs level %d of the API; this program has level %d", m.api, plugin_api.PLUGIN_API_LEVEL)
	}
	if m.api < plugin_api.PLUGIN_API_OLDEST {
		return m, fmt.aprintf("it was written for level %d of the API; this program gives levels %d to %d", m.api, plugin_api.PLUGIN_API_OLDEST, plugin_api.PLUGIN_API_LEVEL)
	}
	if m.program != "" && m.program != program {
		return m, fmt.aprintf("it is a plugin of %s", m.program)
	}
	if !main_valid(m.main) {
		return m, fmt.aprintf("its main file \"%s\" is not a file of its folder", m.main)
	}
	cmds := tk_json.array(v, "commands")
	list := make([dynamic]Command_Decl, 0, len(cmds))
	for c in cmds {
		id := tk_json.text(c, "id")
		d := Command_Decl{
			id = strings.clone(id),
			label = strings.clone(tk_json.text(c, "label", default = id)),
			group = strings.clone(tk_json.text(c, "group", default = m.name)),
			icon = strings.clone(tk_json.text(c, "icon")),
		}
		tags := tk_json.array(c, "tags")
		d.tags = make([]string, len(tags))
		for t, k in tags { d.tags[k] = strings.clone(tk_json.text(t)) }
		append(&list, d)
		if !id_valid(d.id, true) {
			m.commands = list[:]
			return m, fmt.aprintf("its command id \"%s\" is not an id", d.id)
		}
		for o in list[:len(list) - 1] {
			if o.id == d.id {
				m.commands = list[:]
				return m, fmt.aprintf("it declares the command \"%s\" twice", d.id)
			}
		}
	}
	m.commands = list[:]
	return m, ""
}

// A main file: a relative path inside the folder, ending in .js or .mjs.
@(private)
main_valid :: proc(path: string) -> bool {
	if path == "" || strings.has_prefix(path, "/") || strings.contains(path, "\\") || strings.contains(path, ":") { return false }
	for part in strings.split(path, "/", context.temp_allocator) {
		if part == ".." || part == "" { return false }
	}
	return strings.has_suffix(path, ".js") || strings.has_suffix(path, ".mjs")
}

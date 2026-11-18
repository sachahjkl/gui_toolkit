package tk_plugins

// A plugin's plugin.json: what the folder's chore reads, before any JavaScript runs (plugins.md, decision 5).

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "../ascii"
import config "../config"
import tk_json "../json"
import lucide "../lucide"
import plugin_api "../plugin_api"
import "../ui"

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

// Where a view first opens (the manifest's "place"): the four presentations of views.md.
View_Place :: enum u8 {
	Internal,   // "internal" (the default): a window inside the program's window
	Dialog,     // "dialog": over the window, modal
	Panel,      // "panel": docked at the right of the window
	Window,     // "window": a window of the system
}

VIEW_PLACE_NAMES :: [View_Place]string{.Internal = "internal", .Dialog = "dialog", .Panel = "panel", .Window = "window"}

// A view a manifest declares.
View_Decl :: struct {
	id:    string,
	title: string,
	icon:  string,
	place: View_Place,
}

// A setting a manifest declares: a preference of the program, plugins.<plugin id>.<id> (config.Def's fields).
Setting_Decl :: struct {
	id:          string,
	title:       string,
	description: string,
	kind:        config.Kind,
	default:     config.Value,   // its `s` owned
	min, max:    f64,
	bounded:     bool,
	choices:     []string,
}

SETTING_KIND_NAMES :: [config.Kind]string{.Bool = "bool", .Int = "int", .Float = "float", .String = "string"}

// A manifest, read. Its strings are owned (manifest_destroy).
Manifest :: struct {
	id:       string,
	name:     string,
	version:  string,
	api:      int,
	main:     string,
	program:  string,   // "": any program
	commands: []Command_Decl,
	views:    []View_Decl,
	settings: []Setting_Decl,
	permissions: []string,   // what it asks, each in its one form (permission_parse)
	app:      int,           // the level of the program's module "app" it needs (0: none said)
	palette:  []Palette_Decl,   // its palette sources (palette_sources.odin)
	menus:    []Menu_Decl,      // its commands in the program's menus (menus.odin)
	toolbar:  []Toolbar_Decl,   // its commands in the program's tool bar
	l10n:     []L10n_Text,      // its own words in other languages (l10n.odin)
}

// A palette source a manifest declares: its id, its label (the palette's "reading…" row, its hint), its prefix.
Palette_Decl :: struct {
	id:     string,
	label:  string,
	prefix: ui.Palette_Prefix,   // .None: the plain search only
}

// A command of the plugin's in a menu of the program: the program's place's name ("file", "item").
Menu_Decl :: struct {
	command: string,   // the plugin's command id
	place:   string,   // the manifest's "where": the program's place (Host_Options.menu_places)
}

// A command of the plugin's in the program's tool bar, its icon (a Lucide name; "": the command's).
Toolbar_Decl :: struct {
	command: string,
	icon:    string,
}

// One of the manifest's words in a language: the "l10n" object's.
L10n_Text :: struct {
	language:    string,   // "fr", "fr-ca" (in lower case)
	text:        string,   // the manifest's English
	translation: string,
}

manifest_destroy :: proc(m: ^Manifest) {
	delete(m.id); delete(m.name); delete(m.version); delete(m.main); delete(m.program)
	for c in m.commands {
		delete(c.id); delete(c.label); delete(c.group); delete(c.icon)
		for t in c.tags { delete(t) }
		delete(c.tags)
	}
	delete(m.commands)
	for v in m.views { delete(v.id); delete(v.title); delete(v.icon) }
	delete(m.views)
	for s in m.settings {
		delete(s.id); delete(s.title); delete(s.description); delete(s.default.s)
		for c in s.choices { delete(c) }
		delete(s.choices)
	}
	delete(m.settings)
	for p in m.permissions { delete(p) }
	delete(m.permissions)
	for d in m.palette { delete(d.id); delete(d.label) }
	delete(m.palette)
	for d in m.menus { delete(d.command); delete(d.place) }
	delete(m.menus)
	for d in m.toolbar { delete(d.command); delete(d.icon) }
	delete(m.toolbar)
	for t in m.l10n { delete(t.language); delete(t.text); delete(t.translation) }
	delete(m.l10n)
	m^ = {}
}

// The manifest's view `id` (nil: none).
manifest_view :: proc(m: ^Manifest, id: string) -> ^View_Decl {
	for &v in m.views { if v.id == id { return &v } }
	return nil
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
// program's id (Host_Options.program_id); a manifest that names another program is refused. `app`: the program's own
// module (Host_Options.app; nil: none): a manifest that needs a level of it the program does not give, or asks for a
// permission word it does not declare, is refused.
manifest_parse :: proc(text: string, program: string, app: ^App_Module = nil, allocator := context.allocator) -> (m: Manifest, refused: string) {
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
	decls := tk_json.array(v, "views")
	views := make([dynamic]View_Decl, 0, len(decls))
	for d in decls {
		id := tk_json.text(d, "id")
		place_name := tk_json.text(d, "place", default = "internal")
		vd := View_Decl{id = strings.clone(id), title = strings.clone(tk_json.text(d, "title", default = m.name)), icon = strings.clone(tk_json.text(d, "icon"))}
		known := false
		place_names := VIEW_PLACE_NAMES
		for name, place in place_names {
			if name == place_name { vd.place = place; known = true }
		}
		append(&views, vd)
		m.views = views[:]   // (each time: what was read is the manifest's, refused or not, and manifest_destroy frees it)
		if !id_valid(id, false) { return m, fmt.aprintf("its view id \"%s\" is not an id", id) }
		if !known { return m, fmt.aprintf("its view \"%s\" opens in \"%s\", not in internal, dialog, panel or window", id, place_name) }
		for o in views[:len(views) - 1] {
			if o.id == id { return m, fmt.aprintf("it declares the view \"%s\" twice", id) }
		}
	}
	if why := settings_parse(&m, v); why != "" { return m, why }
	words := tk_json.array(v, "permissions")
	perms := make([dynamic]string, 0, len(words))
	for w in words {
		word := tk_json.text(w)
		_, normal, ok := permission_parse(word, context.allocator)
		if !ok {
			m.permissions = perms[:]
			return m, fmt.aprintf("it asks for \"%s\", which is no permission", word)
		}
		known := false
		for p in perms { known ||= p == normal }
		if known { delete(normal); continue }
		if strings.has_prefix(normal, "app:") && plugin_api.app_permission_words(app, normal) == "" {
			delete(normal)
			m.permissions = perms[:]
			if app == nil { return m, fmt.aprintf("it asks for \"%s\", but this program gives no module \"app\"", word) }
			return m, fmt.aprintf("it asks for \"%s\", which %s's module \"app\" does not have", word, app.name)
		}
		append(&perms, normal)
	}
	m.permissions = perms[:]
	// (the level of the program's module it needs: the program's own, beside the API's)
	need := tk_json.number(v, "app", default = 0)
	if need != math.floor(need) || need < 0 { return m, strings.clone("its \"app\" is not the level of the program's module it needs") }
	m.app = int(need)
	if m.app > 0 {
		if app == nil { return m, fmt.aprintf("it needs level %d of a program's module \"app\"; this program gives none", m.app) }
		if m.app > app.level { return m, fmt.aprintf("it needs level %d of %s's module \"app\"; this program gives level %d", m.app, app.name, app.level) }
	}
	if why := contributions_parse(&m, v); why != "" { return m, why }
	return m, ""
}

// The manifest's palette sources, menus, tool bar and languages (slice 7). Each part is the manifest's as soon as it
// is read, refused or not: manifest_destroy frees it.
@(private)
contributions_parse :: proc(m: ^Manifest, v: json.Value) -> string {
	has_command :: proc(m: ^Manifest, id: string) -> bool {
		for c in m.commands { if c.id == id { return true } }
		return false
	}
	sources := make([dynamic]Palette_Decl)
	defer m.palette = sources[:]
	for d in tk_json.array(v, "palette") {
		id := tk_json.text(d, "id")
		mark := tk_json.text(d, "prefix")
		// (the palette's own table: a prefix means the same in every program; commands, settings and secrets are the
		// program's alone)
		prefix: ui.Palette_Prefix
		switch mark {
		case "":  prefix = .None
		case "@": prefix = .Go_To
		case "#": prefix = .Choose
		case "/": prefix = .Paths
		case ">", ":", "$":
			return fmt.aprintf("its palette source \"%s\" takes the prefix \"%s\", which is the program's own (one of @, # or /, or none)", id, mark)
		case:
			return fmt.aprintf("its palette source \"%s\" has the prefix \"%s\", which is no prefix of the palette (one of @, # or /, or none)", id, mark)
		}
		append(&sources, Palette_Decl{id = strings.clone(id), label = strings.clone(tk_json.text(d, "label", default = m.name)), prefix = prefix})
		if !id_valid(id, false) { return fmt.aprintf("its palette source id \"%s\" is not an id", id) }
		for o in sources[:len(sources) - 1] { if o.id == id { return fmt.aprintf("it declares the palette source \"%s\" twice", id) } }
	}
	menus := make([dynamic]Menu_Decl)
	defer m.menus = menus[:]
	for d in tk_json.array(v, "menus") {
		// (the manifest's key is "where"; Odin keeps the word for itself)
		command, place := tk_json.text(d, "command"), tk_json.text(d, "where")
		append(&menus, Menu_Decl{command = strings.clone(command), place = strings.clone(place)})
		if !has_command(m, command) { return fmt.aprintf("its menu entry names \"%s\", which is none of its commands", command) }
		if place == "" { return fmt.aprintf("its menu entry of \"%s\" says no \"where\"", command) }
	}
	tools := make([dynamic]Toolbar_Decl)
	defer m.toolbar = tools[:]
	for d in tk_json.array(v, "toolbar") {
		command, icon := tk_json.text(d, "command"), tk_json.text(d, "icon")
		append(&tools, Toolbar_Decl{command = strings.clone(command), icon = strings.clone(icon)})
		if !has_command(m, command) { return fmt.aprintf("its tool bar entry names \"%s\", which is none of its commands", command) }
		// (a tool shows its icon alone: one the font does not have would be an empty button)
		if icon != "" {
			if _, known := lucide.glyph_of(icon); !known { return fmt.aprintf("its tool bar entry of \"%s\" has the icon \"%s\", which is no Lucide icon", command, icon) }
		}
	}
	texts := make([dynamic]L10n_Text)
	defer m.l10n = texts[:]
	for language, words in tk_json.object(v, "l10n") {
		table, is_object := words.(json.Object)
		if !is_object { return fmt.aprintf("its l10n's \"%s\" is not an object of texts", language) }
		for text, translation in table {
			t, is_text := translation.(json.String)
			if !is_text { return fmt.aprintf("its l10n's \"%s\" translates \"%s\" with something that is not a text", language, text) }
			append(&texts, L10n_Text{language = ascii.lower(language, context.allocator), text = strings.clone(text), translation = strings.clone(string(t))})
		}
	}
	return ""
}

// The manifest's "settings". `why`: the first that is not a setting.
@(private)
settings_parse :: proc(m: ^Manifest, v: json.Value) -> (why: string) {
	decls := tk_json.array(v, "settings")
	list := make([dynamic]Setting_Decl, 0, len(decls))
	defer m.settings = list[:]
	kind_names := SETTING_KIND_NAMES
	for d in decls {
		id := tk_json.text(d, "id")
		s := Setting_Decl{
			id = strings.clone(id), title = strings.clone(tk_json.text(d, "title")),
			description = strings.clone(tk_json.text(d, "description")),
		}
		kind_name := tk_json.text(d, "kind")
		known := false
		for name, k in kind_names { if name == kind_name { s.kind = k; known = true } }
		switch s.kind {
		case .Bool:   s.default.b = tk_json.boolean(d, "default")
		case .Int:    s.default.i = tk_json.integer(d, "default")
		case .Float:  s.default.f = tk_json.number(d, "default")
		case .String: s.default.s = strings.clone(tk_json.text(d, "default"))
		}
		if tk_json.has(d, "min") && tk_json.has(d, "max") {
			s.bounded, s.min, s.max = true, tk_json.number(d, "min"), tk_json.number(d, "max")
		}
		choices := tk_json.array(d, "choices")
		s.choices = make([]string, len(choices))
		for c, k in choices { s.choices[k] = strings.clone(tk_json.text(c)) }
		append(&list, s)
		if !id_valid(id, false) { return fmt.aprintf("its setting id \"%s\" is not an id", id) }
		if !known { return fmt.aprintf("its setting \"%s\" is of kind \"%s\", not bool, int, float or string", id, kind_name) }
		if s.bounded && s.min > s.max { return fmt.aprintf("its setting \"%s\" has a min above its max", id) }
		// (the registry takes a definition as a program's own, checked by its author: a plugin's is checked here)
		if s.bounded && (s.kind == .Int || s.kind == .Float) {
			n := s.kind == .Int ? f64(s.default.i) : s.default.f
			if n < s.min || n > s.max { return fmt.aprintf("its setting \"%s\" has a default out of its bounds", id) }
		}
		if len(s.choices) > 0 {
			if s.kind != .String { return fmt.aprintf("its setting \"%s\" has choices and is not a string", id) }
			found := false
			for c in s.choices { found ||= c == s.default.s }
			if !found { return fmt.aprintf("its setting \"%s\" has a default that is not one of its choices", id) }
		}
		for o in list[:len(list) - 1] {
			if o.id == id { return fmt.aprintf("it declares the setting \"%s\" twice", id) }
		}
	}
	return ""
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

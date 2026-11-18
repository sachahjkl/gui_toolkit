package tk_plugins

// A plugin's commands in the program's menus and tool bar (plugins.md, "As built: palette sources, menus, the tool bar,
// a plugin's languages"): data of the manifests ("menus", "toolbar"), read without running a plugin. The program names
// its places (Host_Options.menu_places) and adds the entries to its own menu and tool bar builds; choosing one runs its
// command as the palette does (run_command).
//
//	if ui.menu("file") {
//		...
//		for e in plugins.menu_entries(&app.plugins, "file") {
//			if ui.menu_item(e.label, icon = e.icon, icon_font = ui.lucide_icons(), disabled = e.disabled).clicked { plugins.run_command(&app.plugins, e.command) }
//		}
//	}
//	for e in plugins.toolbar_entries(&app.plugins) {
//		if ui.toolbar_tool(e.command, plugins.toolbar_tool(e)) { plugins.run_command(&app.plugins, e.command) }
//	}

import lucide "../lucide"
import "../ui"

// An entry of a plugin's in a menu or the tool bar. Its strings are the host's, valid for the build that asked.
Menu_Entry :: struct {
	command:  string,   // plugin.<plugin id>.<command id>: what run_command runs
	label:    string,   // the command's label, in the person's language
	icon:     string,   // a Lucide glyph ("": none; draw it with ui.lucide_icons())
	group:    string,   // the plugin's name: a heading, when the program groups them
	disabled: bool,     // its plugin failed: shown, not chosen
}

// The entries of the plugins for the program's menu place `place` ("file", "item"), in the plugins' order, then their
// manifests'. A place the program does not name in Host_Options.menu_places gives none. Temp memory.
menu_entries :: proc(h: ^Host, place: string) -> []Menu_Entry {
	out := make([dynamic]Menu_Entry, context.temp_allocator)
	known := false
	for p in h.o.menu_places { known ||= p == place }
	if !known { return nil }
	for p in h.plugins {
		if !gives_entries(p) { continue }
		for d in p.manifest.menus {
			if d.place != place { continue }
			if e, ok := entry_of(p, d.command, ""); ok { append(&out, e) }
		}
	}
	return out[:]
}

// The entries of the plugins for the program's tool bar, in the plugins' order, then their manifests'. Temp memory.
toolbar_entries :: proc(h: ^Host) -> []Menu_Entry {
	out := make([dynamic]Menu_Entry, context.temp_allocator)
	for p in h.plugins {
		if !gives_entries(p) { continue }
		for d in p.manifest.toolbar {
			if e, ok := entry_of(p, d.command, d.icon); ok { append(&out, e) }
		}
	}
	return out[:]
}

// An entry as a tool of a ui.toolbar: its label, its glyph in Lucide's face, disabled when its plugin failed.
toolbar_tool :: proc(e: Menu_Entry) -> ui.Toolbar_Tool {
	return {label = e.label, icon = e.icon, disabled = e.disabled, icon_font = ui.lucide_icons()}
}

// (off, refused, suspended, or not read yet: no entry; a failed plugin's are shown, disabled, as in the palette)
@(private)
gives_entries :: proc(p: ^Plugin) -> bool {
	#partial switch p.state {
	case .Refused, .Off, .Suspended, .Found: return false
	}
	return true
}

@(private)
entry_of :: proc(p: ^Plugin, command, icon: string) -> (Menu_Entry, bool) {
	for c in p.manifest.commands {
		if c.id != command { continue }
		return Menu_Entry{
			command = command_id(p.manifest.id, c.id), label = manifest_tr(&p.manifest, c.label),
			icon = icon_glyph_of(icon != "" ? icon : c.icon), group = p.manifest.name, disabled = p.state == .Failed,
		}, true
	}
	return {}, false
}

// A manifest's icon as a glyph: a Lucide name ("search"), or a glyph written out as is.
@(private)
icon_glyph_of :: proc(icon: string) -> string {
	if g, ok := lucide.glyph_of(icon); ok { return g }
	return icon
}

package tk_plugins

// The palette's plugin source: each command of a plugin that is on, as plugin.<plugin id>.<command id>, and Reload
// plugins. Its answer is made at once from the manifests: no JavaScript runs to list a command.

import "core:fmt"
import "core:strings"
import "../ui"

@(private)
source_read :: proc(pal: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	h := (^Host)(src.user)
	a: ui.Palette_Answer
	al := ui.palette_answer_allocator(&a)
	items := make([dynamic]ui.Palette_Item, al)
	append(&items, ui.palette_item_clone({id = RELOAD_COMMAND, title = "Reload plugins", group = "Plugins", tags = {"plugins", "refresh"}}, al))
	for p in h.plugins {
		#partial switch p.state {
		case .Refused, .Off, .Suspended, .Found: continue
		}
		for c in p.manifest.commands {
			it := ui.Palette_Item{
				// (no detail: the group is the plugin's name unless its manifest names another)
				id = command_id(p.manifest.id, c.id), title = manifest_tr(&p.manifest, c.label), group = manifest_tr(&p.manifest, c.group), icon = c.icon, tags = c.tags,
				disabled = p.state == .Failed,
			}
			append(&items, ui.palette_item_clone(it, al))
		}
		for v in p.manifest.views {
			// (a view the program builds in its own layout is always shown: nothing to open)
			if r := view_record(h, p.manifest.id, v.id); r != nil && r.embedded { continue }
			id := strings.concatenate({VIEW_PREFIX, p.manifest.id, ".", v.id}, context.temp_allocator)
			append(&items, ui.palette_item_clone({id = id, title = manifest_tr(&p.manifest, v.title), group = p.manifest.name, tags = {"view", "open"}, disabled = p.state == .Failed}, al))
		}
	}
	a.items = items[:]
	ui.palette_answer(q, &a)
}

@(private)
source_act :: proc(pal: ^ui.Command_Palette, src: ^ui.Palette_Source, c: ui.Palette_Choice) {
	h := (^Host)(src.user)
	if !run_command(h, c.id) {
		say(h, .Warn, fmt.tprintf("%s cannot run now", c.id))
	}
}

package tk_setup

// The Setup dialog: the program, its version, the state of its install in a sentence, where its files are, and what can
// be done: Install (or Repair, Upgrade, Update the shortcuts), Uninstall, Open the installed copy, Keep standalone.
//
//   d: setup.Dialog                          kept by the program
//   setup.open(&d, cfg)                      at a start when setup.wanted(...), from a menu, from `--setup`
//   ev := setup.dialog(&d, cfg, em, logo)    each frame (a modal: nothing when closed)
//   setup.finish(&d, cfg)                    at the end of the process (what an uninstall left goes then)
//   setup.destroy(&d)
//
// The events tell the program what to keep (Choice_*) and when to end (Launched: the installed copy runs).

import "core:fmt"
import "core:math"
import "core:strings"
import desktop "../desktop"
import "../draw"
import "../render"
import "../ui"

Dialog :: struct {
	open:      bool,
	facts:     Facts,              // as last read (strings owned)
	shortcut:  bool,               // Windows: the Desktop's shortcut, asked of Install
	note:      string,             // what the last action said (owned)
	note_good: bool,
	installed: string,             // the copy just installed, to open (owned; "": none)
	removed:   bool,               // this copy was uninstalled while it runs: its file goes when the process ends
	leftovers: [dynamic]string,    // ... with these (owned)
	copied:    string,             // the line whose path was just copied (its id, owned): a check until the pointer leaves
}

Event :: enum u8 {
	None,
	Installed,         // keep CHOICE_INSTALLED
	Uninstalled,
	Kept_Standalone,   // keep CHOICE_STANDALONE
	Dismissed,         // closed without an answer: keep choice_dismissed(version)
	Launched,          // the installed copy was started: this one ends
}

// The program's mark beside its name (a texture of the program's renderer, and its size in pixels).
Logo :: struct {
	texture: render.Texture,
	size:    [2]f32,
}

@(private = "file") DIALOG_WIDTH_EM :: 36
@(private = "file") DIALOG_TOP      :: 0.18   // of the window's height
@(private = "file") MARGIN_EM       :: 1.5
@(private = "file") LOGO_EM         :: 4.2

// Opens the dialog on the facts of now.
open :: proc(d: ^Dialog, c: Config) {
	d.open = true
	refresh(d, c)
	d.shortcut = d.facts.desk_lnk
}

// Reads the facts again (after an action).
refresh :: proc(d: ^Dialog, c: Config) {
	f := facts(c)
	f.dir, f.exe, f.running, f.version = strings.clone(f.dir), strings.clone(f.exe), strings.clone(f.running), strings.clone(f.version)
	facts_free(&d.facts)
	if d.removed { f.state = .Removal_Scheduled }   // (the file is still there: the disk would say Repair)
	d.facts = f
}

// At the end of the process: what an uninstall left because this process held it goes then (a helper of the system's
// waits for the process).
finish :: proc(d: ^Dialog, c: Config) {
	if len(d.leftovers) > 0 { _ = remove_later(c, d.leftovers[:]) }
	for l in d.leftovers { delete(l) }
	delete(d.leftovers)
	d.leftovers = nil
}

destroy :: proc(d: ^Dialog) {
	facts_free(&d.facts)
	delete(d.note)
	delete(d.installed)
	delete(d.copied)
	for l in d.leftovers { delete(l) }
	delete(d.leftovers)
	d^ = {}
}

@(private)
facts_free :: proc(f: ^Facts) {
	delete(f.dir); delete(f.exe); delete(f.running); delete(f.version)
	f^ = {}
}

@(private = "file")
say :: proc(d: ^Dialog, good: bool, text: string) {
	delete(d.note)
	d.note, d.note_good = strings.clone(text), good
}

// What the state is, in a sentence, and its tone ("good", "warn", "bad", "accent").
state_words :: proc(f: Facts, c: Config) -> (words, tone: string) {
	switch f.state {
	case .Not_Installed: return "Not installed: this copy runs on its own.", "warn"
	case .This_Copy:     return "Installed: this is the installed copy.", "good"
	case .Repair:
		switch {
		case !f.exe_there: return "The installed program is missing: what is left of it can be repaired or removed.", "bad"
		case !f.manifest:  return "A copy is installed by an earlier setup: Repair puts this copy in its place.", "accent"
		}
		return fmt.tprintf("Installed, but %s is missing.", WORDS_PIECES_MISSING), "bad"
	case .Other_Copy:
		if is_upgrade(f, c.version) { return fmt.tprintf("An older copy is installed (%s): upgrade it to %s?", f.version, c.version), "accent" }
		return fmt.tprintf("A copy is installed (%s): this one runs on its own.", f.version != "" ? f.version : "?"), "warn"
	case .Removal_Scheduled: return "Uninstalled: the program is deleted when this window closes.", "warn"
	case .Nix_Package:   return "Installed by Nix: the Nix package has the menu entry and the icon.", "good"
	}
	return "", ""
}

// The words of this system for the pieces of an install.
when ODIN_OS == .Windows {
	WORDS_MENU           :: "Start menu"
	WORDS_RECORD         :: "Settings > Apps"
	WORDS_PIECES_MISSING :: "a shortcut, the Settings entry or a file"
} else {
	WORDS_MENU           :: "applications menu"
	WORDS_RECORD         :: "icons"
	WORDS_PIECES_MISSING :: "the menu entry, an icon or a file"
}

// The dialog, while it is open (a modal over the window). What the user did, if anything.
dialog :: proc(d: ^Dialog, c: Config, em: f32, logo: Maybe(Logo) = nil) -> (ev: Event) {
	was_open := d.open
	if ui.modal("setup", em * DIALOG_WIDTH_EM, &d.open, DIALOG_TOP) {
		f := &d.facts
		ui.spacer(ui.px(em * 1.3))
		head(d, c, em, logo)
		ui.spacer(ui.px(em))
		line_next()
		if ui.row(id = "###setup_where_row") {
			ui.spacer(ui.px(em * MARGIN_EM))
			// (a sunken well, as a field is)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y, radius = em * 0.5})
			well: ^ui.Box
			if ui.tags("input") { well = ui.build_box({.Draw_Background, .Draw_Border, .Sunken}, "###setup_where") }
			if ui.parent(well) {
				ui.spacer(ui.px(em * 0.5))
				where_row(d, "###w1", "program", f.exe, true, em)
				where_row(d, "###w2", WORDS_MENU, f.start_lnk ? c.identity.name : "-", false, em)
				where_row(d, "###w3", WORDS_RECORD, f.record ? c.identity.name : "-", false, em)
				where_row(d, "###w4", "this copy", f.running, true, em)
				ui.spacer(ui.px(em * 0.5))
			}
			ui.spacer(ui.px(em * MARGIN_EM))
		}
		when ODIN_OS == .Windows {
			if !f.from_nix {
				ui.spacer(ui.px(em * 0.7))
				line_next()
				if ui.row(id = "###setup_desk_row") {
					ui.spacer(ui.px(em * MARGIN_EM))
					ui.checkbox("###setup_shortcut", "Shortcut on the Desktop", &d.shortcut)
				}
			}
		}
		if d.note != "" {
			ui.spacer(ui.px(em * 0.6))
			line_next()
			if ui.row(.Center, id = "###setup_note_row") {
				ui.spacer(ui.px(em * MARGIN_EM))
				if ui.tags(d.note_good ? "good" : "bad") {
					ui.next({width = ui.fill(), text_pad = 0})
					ui.paragraph(fmt.tprintf("%s###setup_note", d.note))
				}
				ui.spacer(ui.px(em * MARGIN_EM))
			}
		}
		ui.spacer(ui.px(em * 1.1))
		ev = buttons(d, c, em)
		ui.spacer(ui.px(em * 1.3))
	}
	// closed without an answer: not again for this version
	if was_open && !d.open && ev == .None && d.facts.state != .Removal_Scheduled && d.installed == "" {
		if d.facts.state != .This_Copy { ev = .Dismissed }
	}
	return
}

// A line of the dialog: as wide as it, as tall as what it holds.
@(private = "file")
line_next :: proc() {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
}

// A line of the well: what, at a fixed width and weak, then where. A path that does not fit is cut; the pointer over it
// shows it whole, and a click on it or on the copy button after it puts it on the clipboard.
@(private = "file")
where_row :: proc(d: ^Dialog, id, key, value: string, path: bool, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.55)), axis = .X, cross = .Center})
	if ui.row(.Center, id = id) {
		ui.spacer(ui.px(em * 0.9))
		if ui.tags("weak") {
			ui.next({width = ui.px(em * 9), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.tprintf("%s###k", key))
		}
		mono := ui.Style_Mod{width = ui.fill(), height = ui.pct(1), text_pad = 0, font = ui.mono_font(), font_size = math.round(em * 0.86)}
		if !path || value == "" {
			ui.next(mono)
			ui.label(fmt.tprintf("%s###v", value))
		} else {
			ui.next(mono)
			ui.a11y({role = .Button, name = fmt.tprintf("Copy %s", value)})
			text := ui.build_box({.Clickable, .Draw_Text}, fmt.tprintf("%s###v", value))
			sig := ui.signal(text)
			ui.spacer(ui.px(em * 0.4))
			side := math.round(em * 1.3)
			ui.next({width = ui.px(side), height = ui.px(side), cursor = .Hand})
			ui.a11y({role = .Button, name = fmt.tprintf("Copy %s", value)})
			button := ui.build_box({.Clickable, .Focusable, .Draw_Hot_Effects}, "###copy")
			bsig := ui.signal(button)
			copied := d.copied == id
			glyph := ui.frame_new(Copy_Glyph)
			glyph^ = {ui.color("text"), copied}
			button.custom, button.custom_user = copy_draw, glyph
			if sig.clicked || bsig.clicked {
				ui.window_clipboard_set(value)
				delete(d.copied)
				d.copied = strings.clone(id)
			} else if copied && !sig.hovering && !bsig.hovering {
				delete(d.copied)
				d.copied = ""   // (the check goes when the pointer leaves)
			}
			if ui.hovered_for(sig, 0.4) || ui.hovered_for(bsig, 0.4) {
				if ui.tooltip() {
					ui.next({width = ui.text_size(em * 0.6), height = ui.px(em * 1.8), font = ui.mono_font(), font_size = math.round(em * 0.86)})
					ui.label(fmt.tprintf("%s###tip", copied ? "Copied" : value))
				}
			}
		}
		ui.spacer(ui.px(em * 0.9))
	}
}

@(private = "file")
Copy_Glyph :: struct { color: draw.Color, copied: bool }

// Two sheets, one over the other (copy); a check once copied. Drawn: the icons' font has no such glyph.
@(private = "file")
copy_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	g := (^Copy_Glyph)(user)
	r := b.rect
	side := min(r.max.x - r.min.x, r.max.y - r.min.y)
	c := (r.min + r.max) * 0.5
	w := max(1, math.round(side * 0.08))
	if g.copied {
		pts := [3][2]f32{c + {-0.28, 0.02} * side, c + {-0.08, 0.22} * side, c + {0.3, -0.2} * side}
		draw.polyline(dc, pts[:], w * 1.4, g.color)
		return
	}
	u := side * 0.42
	back := draw.Rect{c + {-0.32, -0.32} * side, c + {-0.32, -0.32} * side + u}
	front := draw.Rect{c + {-0.1, -0.1} * side, c + {-0.1, -0.1} * side + u}
	draw.rect(dc, back, g.color, side * 0.08, w)
	draw.rect(dc, front, g.color, side * 0.08, w)
}

// The logo, the name, the version and the state.
@(private = "file")
head :: proc(d: ^Dialog, c: Config, em: f32, logo: Maybe(Logo)) {
	f := &d.facts
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###setup_head") {
		ui.spacer(ui.px(em * MARGIN_EM))
		if l, has := logo.?; has {
			side := math.round(em * LOGO_EM)
			ui.next({width = ui.px(side), height = ui.px(side)})
			b := ui.build_box({}, "###setup_logo")
			p := ui.frame_new(Logo)
			p^ = l
			b.custom, b.custom_user = logo_draw, p
			ui.spacer(ui.px(em * 1.1))
		}
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###setup_words") {
			ui.spacer(ui.px(em * 0.3))
			ui.next({width = ui.fill(), height = ui.px(em * 2), font_size = math.round(em * 1.5), text_pad = 0})
			ui.label(fmt.tprintf("%s###setup_name", c.identity.name))
			if ui.tags("weak") {
				ui.next({width = ui.fill(), height = ui.px(em * 1.4), font_size = math.round(em * 0.86), text_pad = 0})
				vendor := c.identity.vendor != "" ? fmt.tprintf("  ·  %s", c.identity.vendor) : ""
				ui.label(fmt.tprintf("version %s%s###setup_version", c.version, vendor))
				if c.note != "" {
					ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
					ui.paragraph(fmt.tprintf("%s###setup_about", c.note))
				}
			}
			ui.spacer(ui.px(em * 0.6))
			words, tone := state_words(f^, c)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###setup_state_row") {
				if ui.tags(tone) {
					lamp := tone == "accent" ? ui.color("accent") : ui.color("text")
					ui.next({width = ui.px(math.round(em * 0.7)), height = ui.px(math.round(em * 0.7))})
					b := ui.build_box({}, "###setup_lamp")
					p := ui.frame_new(draw.Color)
					p^ = lamp
					b.custom, b.custom_user = lamp_draw, p
				}
				ui.spacer(ui.px(em * 0.5))
				ui.next({width = ui.fill(), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###setup_state", words))
			}
			if f.nixos && f.state != .Nix_Package && f.state != .This_Copy {
				ui.spacer(ui.px(em * 0.4))
				if ui.tags("weak") {
					ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
					ui.paragraph("On NixOS, a Nix package is the better install: Nix updates it. An install here makes this copy run by itself (nix-build makes the libraries it needs).###setup_nixos")
				}
			}
		}
		ui.spacer(ui.px(em * MARGIN_EM))
	}
}

@(private = "file")
logo_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	l := (^Logo)(user)
	r := b.rect
	room := r.max - r.min
	if l.size.x <= 0 || l.size.y <= 0 || room.x <= 0 { return }
	scale := min(room.x / l.size.x, room.y / l.size.y)
	sz := l.size * scale
	at := r.min + (room - sz) * 0.5
	draw.image(dc, l.texture, {at, at + sz})
}

@(private = "file")
lamp_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	c := (^draw.Color)(user)^
	r := b.rect
	prev := draw.set_circular_corners(dc, true)
	defer draw.set_circular_corners(dc, prev)
	draw.rect(dc, r, c, (r.max.x - r.min.x) * 0.5)
}

// Uninstall on the left; on the right, what closes, and what installs (or the installed copy to open).
@(private = "file")
buttons :: proc(d: ^Dialog, c: Config, em: f32) -> (ev: Event) {
	f := &d.facts
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###setup_buttons") {
		ui.spacer(ui.px(em * MARGIN_EM))
		if f.state == .This_Copy || f.state == .Repair || f.state == .Other_Copy {
			if button("###setup_uninstall", "Uninstall", "danger_button", em) {
				ok, leftovers, why := uninstall(c)
				for l in leftovers { append(&d.leftovers, l) }
				delete(leftovers)
				if ok {
					delete(d.installed)
					d.installed = ""
					d.removed = len(d.leftovers) > 0
					say(d, true, d.removed ? "Removed. The program is deleted when this window closes." : "Removed.")
					ev = .Uninstalled
				} else {
					say(d, false, why)
				}
				refresh(d, c)
			}
		}
		ui.spacer(ui.fill())
		just_installed := d.installed != "" && f.state != .This_Copy
		upgrade := is_upgrade(f^, c.version)
		switch {
		case just_installed:
			if button("###setup_close", "Close", "button", em) { d.open = false }
			ui.spacer(ui.px(em * 0.5))
			if button("###setup_launch", "Open the installed copy", "accent_button", em) {
				if launch(d.installed) { ev = .Launched } else { say(d, false, fmt.tprintf("%s does not start", d.installed)) }
			}
		case upgrade:
			if button("###setup_later", "Not now", "button", em) { d.open = false; ev = .Dismissed }
		case f.state == .Not_Installed || f.state == .Other_Copy:
			if button("###setup_standalone", "Keep standalone", "button", em) { d.open = false; ev = .Kept_Standalone }
		case:
			if button("###setup_close", "Close", "button", em) { d.open = false }
		}
		if !just_installed && f.state != .Removal_Scheduled && !f.from_nix {
			label := "Install"
			#partial switch f.state {
			case .Other_Copy: label = upgrade ? fmt.tprintf("Upgrade to %s", c.version) : "Replace the installed copy"
			case .Repair:     label = "Repair"
			case .This_Copy:  label = "Update the shortcuts"
			}
			ui.spacer(ui.px(em * 0.5))
			if button("###setup_install", label, "accent_button", em) {
				ok, exe_or_why := install(c, d.shortcut)
				if ok {
					ev = .Installed
					if desktop.same_path(exe_or_why, f.running) {
						say(d, true, "Done: everything is in place.")
					} else {
						say(d, true, fmt.tprintf("Installed. Start it from the %s, or now:", WORDS_MENU))
						delete(d.installed)
						d.installed = strings.clone(exe_or_why)
					}
				} else {
					say(d, false, exe_or_why)
				}
				refresh(d, c)
			}
		}
		ui.spacer(ui.px(em * MARGIN_EM))
	}
	return
}

@(private = "file")
button :: proc(id, label, tag: string, em: f32) -> bool {
	ui.next({width = ui.text_size(em * 1.2), height = ui.px(math.round(em * 2.2))})
	clicked := false
	if ui.tags(tag) { clicked = ui.button(fmt.tprintf("%s%s", label, id)).clicked }
	return clicked
}

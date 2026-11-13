package tk_setup

// The install as a page of the settings (gt:prefs_page's Installation page): the same Dialog, its facts, its work and its
// events as the modal, drawn in the flow of a page. What the page says: the program and its state, where the installed
// copy is and which version, this copy and whether it is the installed one, each piece the install puts on the desktop
// (the menu's entry, Settings > Apps, the start with the session, the PATH and its console launcher), the program's
// options, and Install (Repair, Upgrade...), Uninstall, Open the installed copy.
//
//   ev := setup.page(&d, cfg, em)   in the page's build, each frame it is shown (setup.update runs each frame too)
//
// The page opens the Dialog when it is first built (the facts are read on its thread, the places watched); a build that
// does not draw it closes it again (update), with no event: leaving a page answers nothing.

import "core:fmt"
import "core:math"
import i18n "../i18n"
import lucide "../lucide"
import "../ui"

page :: proc(d: ^Dialog, o: Setup_Options, em: f32) -> (ev: Event) {
	if !d.open {
		open(d, o)
		d.in_page = true
	}
	if s := ui.current_state(); s != nil { d.page_build = s.build_index }
	ev = update(d, o)
	f := &d.facts
	is_busy := busy(d)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###setup_page") {
		// the program, what the page offers and the state in a word
		title, badge := i18n.tr("Reading the install…"), ""
		if d.known { title, badge = headline(f^, o) }
		page_line()
		if ui.row(.Center, id = "###setup_page_head") {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.8)), font_size = math.round(em * 1.15), text_pad = 0})
			ui.label(fmt.tprintf("%s###setup_page_title", title))
			if badge != "" {
				_, tone := state_words(f^, o)
				ui.next({width = ui.text_size(em * 1.2), height = ui.px(math.round(em * 1.8)), radius = rad(o, em, 0.3), text_pad = 0})
				if ui.tags("button", tone) {
					b := ui.build_box({.Draw_Background, .Draw_Border, .Draw_Text}, fmt.tprintf("%s###setup_page_badge", badge))
					b.text_align = .Center
				}
			}
		}
		if d.known {
			words, tone := state_words(f^, o)
			if ui.tags(tone == "accent" ? "" : tone) {
				ui.next({width = ui.fill(), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###setup_page_state", words))
			}
			ui.spacer(ui.px(em * 0.6))
			// where everything is
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y, radius = rad(o, em, 0.4)})
			well: ^ui.Box
			if ui.tags("input") { well = ui.build_box({.Draw_Background, .Draw_Border}, "###setup_page_where") }
			if ui.parent(well) {
				ui.spacer(ui.px(em * 0.35))
				installed := f.state != .Not_Installed && f.state != .Nix_Package
				where_row(d, "###p_exe", i18n.tr("Installed program"), installed ? f.exe : "-", installed, em)
				where_row(d, "###p_version", i18n.tr("Version installed"), installed && f.version != "" ? f.version : "-", false, em)
				here := f.running_it ? fmt.tprintf(i18n.tr("%s (the installed copy)"), o.version) : o.version
				where_row(d, "###p_this_version", i18n.tr("This copy"), here, false, em)
				if !f.running_it { where_row(d, "###p_this", "", f.running, true, em) }
				yes_no :: proc(on: bool) -> string { return on ? i18n.tr("yes") : "-" }
				where_row(d, "###p_menu", words_menu(), yes_no(f.start_lnk), false, em)
				when ODIN_OS == .Windows { where_row(d, "###p_record", words_record(), yes_no(f.record), false, em) }
				where_row(d, "###p_autostart", i18n.tr("With the session"), yes_no(f.autostart), false, em)
				when ODIN_OS == .Windows {
					where_row(d, "###p_path", i18n.tr("On the PATH"), f.on_path ? i18n.tr("yes (with its console launcher)") : "-", false, em)
				} else {
					where_row(d, "###p_path", i18n.tr("On the PATH"), yes_no(f.on_path), false, em)
				}
				ui.spacer(ui.px(em * 0.35))
			}
			// before an install: where it goes and its options
			if !f.from_nix && install_label(d, o) != "" {
				if o.folder && f.state == .Not_Installed { page_folder(d, o, em, is_busy) }
				ui.spacer(ui.px(em * 0.6))
				ui.next({width = ui.fill()})
				ui.checkbox("###setup_page_shortcut", i18n.tr("Shortcut on the Desktop"), &d.shortcut, wrap = true)
				for i in 0 ..< min(len(o.choices), len(d.choices)) {
					ui.next({width = ui.fill()})
					ui.checkbox(fmt.tprintf("###setup_page_choice_%d", i), i18n.tr(o.choices[i].label), &d.choices[i], wrap = true)
				}
			}
			if f.nixos && f.state != .Nix_Package && f.state != .This_Copy {
				if ui.tags("weak") {
					ui.next({width = ui.fill(), text_pad = 0, font_size = math.round(em * 0.86)})
					ui.paragraph(fmt.tprintf("%s###setup_page_nixos", i18n.tr("On NixOS, a Nix package is the better install: Nix updates it. An install here makes this copy run by itself (nix-build makes the libraries it needs).")))
				}
			}
		}
		if d.note != "" || is_busy {
			ui.spacer(ui.px(em * 0.4))
			if ui.tags(is_busy ? "weak" : d.note_good ? "good" : "bad") {
				ui.next({width = ui.fill(), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###setup_page_note", is_busy ? i18n.tr("Working…") : d.note))
			}
		}
		ui.spacer(ui.px(em * 0.8))
		if bev := page_buttons(d, o, em); bev != .None { ev = bev }
	}
	return
}

@(private = "file")
page_line :: proc() {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
}

// The install folder and the system's picker, before the first install.
@(private = "file")
page_folder :: proc(d: ^Dialog, o: Setup_Options, em: f32, is_busy: bool) {
	ui.spacer(ui.px(em * 0.6))
	if ui.tags("weak") {
		ui.next({width = ui.fill(), text_pad = 0})
		ui.label(fmt.tprintf("%s###setup_page_loc", i18n.tr("Install location")))
	}
	page_line()
	if ui.row(.Center, id = "###setup_page_folder_row") {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.1)), radius = rad(o, em, 0.3)})
		_ = ui.line_edit("###setup_page_folder", &d.folder)
		ui.spacer(ui.px(em * 0.4))
		if button(o, "###setup_page_pick", i18n.tr("Choose…"), lucide.FOLDER_OPEN, .Primary, em) && !is_busy { pick_folder(d, o) }
	}
}

// Install (or Repair, Upgrade...), Open the installed copy, and Uninstall on the right, which asks once before it acts.
@(private = "file")
page_buttons :: proc(d: ^Dialog, o: Setup_Options, em: f32) -> (ev: Event) {
	d.at = {}
	mark :: proc(d: ^Dialog, role: Button_Role, id: string) { if b := ui.prev_box(id); b != nil { d.at[role] = b.rect } }
	page_line()
	if ui.row(.Center, id = "###setup_page_buttons") {
		if label := install_label(d, o); label != "" {
			if button(o, "###setup_install", label, d.facts.state == .Repair ? lucide.WRENCH : lucide.DOWNLOAD, .Success, em) && !busy(d) { start_install(d, o) }
			mark(d, .Install, "###setup_install")
			ui.spacer(ui.px(em * 0.5))
		}
		if d.installed != "" && d.facts.state != .This_Copy {
			if button(o, "###setup_launch", i18n.tr("Open the installed copy"), lucide.EXTERNAL_LINK, .Success, em) { ev = open_installed(d) }
			mark(d, .Secondary, "###setup_launch")
			ui.spacer(ui.px(em * 0.5))
		}
		ui.spacer(ui.fill())
		if can_uninstall(d) {
			nix := d.facts.state == .Nix_Package
			words := d.confirm ? (nix ? i18n.tr("Click again to remove") : i18n.tr("Click again to uninstall")) : (nix ? i18n.tr("Remove what is left") : i18n.tr("Uninstall"))
			if button(o, "###setup_uninstall", words, lucide.TRASH_2, .Danger, em) && !busy(d) {
				if d.confirm { start_uninstall(d, o) } else { d.confirm = true }
			}
			mark(d, .Uninstall, "###setup_uninstall")
		}
	}
	if d.confirm && ui.key_press(.Escape) { d.confirm = false }
	return
}

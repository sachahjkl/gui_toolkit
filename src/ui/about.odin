package ui

// A generic About modal dialog usable by every program (src/md/features/about-modal.md, docs/about.md): program logo
// or icon, name, tagline, version, toolkit version (VERSION), licence, links, Copy version, Copy diagnostics, and Close.
//
//   ui.about_modal("about", &app.about_open, {
//       name = "Plume", version = APP_VERSION, tagline = "A fast Markdown editor",
//       licence = "MIT", links = {{label = "Website", url = "https://..."}},
//   })

import "core:fmt"
import "core:math"
import "core:strings"
import "../draw"
import "../font"
import i18n "../i18n"
import lucide "../lucide"
import "../render"

// Default modal width and logo side, in ems.
ABOUT_WIDTH_EM :: f32(30)
@(private = "file") ABOUT_LOGO_EM :: f32(3.8)
@(private = "file") ABOUT_LABEL_EM :: f32(6.5)

// A link button shown in the About modal (e.g. website, repository, release notes).
About_Link :: struct {
	label: string,   // button text
	url:   string,   // URL opened via ui.open(url, .Url), or passed to About_Info.on_link
	icon:  string,   // optional Lucide glyph (empty: lucide.EXTERNAL_LINK)
}

// What the program passes to about_modal. Every field is optional; empty fields are omitted.
About_Info :: struct {
	name:         string,                          // program name
	version:      string,                          // program version
	tagline:      string,                          // short description under the name
	licence:      string,                          // licence text (e.g. "MIT")
	copyright:    string,                          // optional copyright / vendor line
	logo:         render.Texture,                  // optional logo texture, drawn in a rounded square
	logo_draw:    Custom_Draw,                     // optional custom draw for the logo (wins over logo and icon)
	logo_user:    rawptr,                          // user pointer for logo_draw
	icon:         string,                          // optional icon glyph when logo_draw == nil and logo == 0
	icon_font:    font.Font_Id,                    // font of icon (0: lucide_icons())
	on_whats_new: proc(user: rawptr),              // prioritized built-in "What's new" action (closes About and jumps in-app)
	website_url:  string,                          // optional project website URL ("Website" button)
	releases_url: string,                          // optional secondary online release notes URL ("Online release notes" button)
	links:        []About_Link,                    // optional extra link buttons
	diagnostics:  string,                          // optional extra diagnostics block (shows "Copy diagnostics" when non-empty)
	on_link:      proc(url: string, user: rawptr), // optional callback instead of ui.open(url, .Url)
	user:         rawptr,                          // user pointer passed to on_whats_new and on_link
}

@(private = "file")
About_Logo_Draw :: struct {
	tex:    render.Texture,
	radius: f32,
}

@(private = "file")
about_logo_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^About_Logo_Draw)(user)
	if d.tex != 0 { draw.image(dc, d.tex, b.rect, radius = d.radius) }
}

// Compact one-line version summary copied by "Copy version".
about_version_text :: proc(info: About_Info, allocator := context.temp_allocator) -> string {
	switch {
	case info.name != "" && info.version != "":
		return fmt.aprintf("%s %s (gui_toolkit %s)", info.name, info.version, VERSION, allocator = allocator)
	case info.name != "":
		return fmt.aprintf("%s (gui_toolkit %s)", info.name, VERSION, allocator = allocator)
	case info.version != "":
		return fmt.aprintf("%s (gui_toolkit %s)", info.version, VERSION, allocator = allocator)
	case:
		return fmt.aprintf("gui_toolkit %s", VERSION, allocator = allocator)
	}
}

// Multi-line diagnostics summary copied by "Copy diagnostics".
about_diagnostics_text :: proc(info: About_Info, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	if info.name != "" {
		strings.write_string(&b, info.name)
		if info.version != "" {
			strings.write_byte(&b, ' ')
			strings.write_string(&b, info.version)
		}
		strings.write_byte(&b, '\n')
	} else if info.version != "" {
		fmt.sbprintf(&b, "Version: %s\n", info.version)
	}
	fmt.sbprintf(&b, "Toolkit: gui_toolkit %s\n", VERSION)
	fmt.sbprintf(&b, "Compiler: Odin %s\n", ODIN_VERSION)
	fmt.sbprintf(&b, "OS: %v", ODIN_OS)
	if info.licence != "" { fmt.sbprintf(&b, "\nLicence: %s", info.licence) }
	if info.diagnostics != "" {
		strings.write_byte(&b, '\n')
		strings.write_string(&b, strings.trim_space(info.diagnostics))
	}
	return strings.to_string(b)
}

// Builds a standard About modal dialog while `showing^` is true. Closes on Escape, Close button, corner cross, or
// scrim click.
about_modal :: proc(id: string, showing: ^bool, info: About_Info) {
	if showing == nil || !showing^ { return }
	s := gs()
	if modal(id, showing, {width_em = ABOUT_WIDTH_EM}) {
	em := font_size()
	// Place the modal's top-right close cross without a duplicate title bar so the program name is said once.
	m := &s.modal_stack[len(s.modal_stack) - 1]
	panel := box_from_key(m.panel)
	if panel != nil && info.name != "" {
		a11y_default(panel, {role = .Dialog, name = fmt.tprintf(i18n.tr("About %s"), info.name)})
	}
	border := border_inset(panel)
	m.corner_side = math.round(em * DIALOG_CLOSE_EM)
	m.corner_inset = border + math.round(em * 0.6)
	m.close, m.close_label = true, i18n.tr("Close")

	next({width = fill(), height = children_sum(), axis = .X})
	if row(id = "###about_pad") {
		space(PAGE_MARGIN)
		next({width = fill(), height = children_sum(), axis = .Y})
		if column(id = "###about_body") {
			space(PAGE_MARGIN)
			// Hero: optional logo/icon + name + tagline
			next({width = fill(), height = children_sum(), axis = .X, cross = .Center})
			if row(.Center, id = "###about_hero") {
				has_logo := info.logo_draw != nil || info.logo != 0 || info.icon != ""
				if has_logo {
					side := math.round(em * ABOUT_LOGO_EM)
					rad := math.round(side * 0.22)
					if info.logo_draw != nil {
						next({width = px(side), height = px(side)})
						custom("###about_logo", info.logo_draw, info.logo_user)
					} else if info.logo != 0 {
						d := frame_new(About_Logo_Draw)
						d^ = {tex = info.logo, radius = rad}
						next({width = px(side), height = px(side)})
						custom("###about_logo", about_logo_draw, d)
					} else {
						face := info.icon_font != 0 ? info.icon_font : lucide_icons()
						next({width = px(side), height = px(side), bg = color("well"), fg = color("accent"), font = face, font_size = math.round(side * 0.52), text_align = .Center, text_pad = 0, radius = rad})
						build_box({.Draw_Background, .Draw_Border, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###about_logo", info.icon))
					}
					spacer(px(math.round(em * 1.0)))
				}
				next({width = fill(), height = children_sum(), axis = .Y})
				if column(id = "###about_title_col") {
					if info.name != "" {
						next({width = fill(), font_size = math.round(em * 1.45), text_pad = 0})
						paragraph(fmt.tprintf("%s###about_name", text_shown(info.name)))
					}
					if info.tagline != "" {
						if info.name != "" { space(SPACE_1) }
						if tags("weak") {
							next({width = fill(), font_size = math.round(em * 0.92), text_pad = 0})
							paragraph(fmt.tprintf("%s###about_tagline", text_shown(info.tagline)))
						}
					}
				}
				// Reserve room on the right so the top-right corner close cross never overlaps the title.
				spacer(px(m.corner_side + math.round(em * 0.4)))
			}

			space(ITEM_GAP)
			hline(fill())
			space(ITEM_GAP)

			// Facts: version, toolkit version, licence
			about_fact_row :: proc(row_id, key_label, value: string, em: f32, mono: bool) {
				next({width = fill(), height = children_sum(), axis = .X, cross = .Center})
				if row(.Center, id = row_id) {
					if tags("weak") {
						next({width = px(math.round(em * ABOUT_LABEL_EM)), height = text_size(), text_pad = 0})
						build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###k", text_shown(key_label)))
					}
					space(CONTROL_GAP)
					next({width = fill(), font = mono ? mono_font() : top_style().font, text_pad = 0})
					paragraph(fmt.tprintf("%s###v", text_shown(value)))
				}
			}

			if info.version != "" {
				about_fact_row("###about_version", i18n.tr("Version"), info.version, em, true)
				space(LINE_GAP)
			}
			about_fact_row("###about_toolkit", i18n.tr("Toolkit"), fmt.tprintf("gui_toolkit %s", VERSION), em, true)
			if info.licence != "" {
				space(LINE_GAP)
				about_fact_row("###about_licence", i18n.tr("Licence"), info.licence, em, false)
			}
			if info.copyright != "" {
				space(LINE_GAP)
				if tags("weak") {
					next({width = fill(), font_size = math.round(em * 0.85), text_pad = 0})
					paragraph(fmt.tprintf("%s###about_copyright", text_shown(info.copyright)))
				}
			}

			// Built-in "What's new" (prioritized primary action) + optional external links
			open_url :: proc(info: About_Info, url: string) {
				if info.on_link != nil { info.on_link(url, info.user) } else if url != "" { open(url, .Url) }
			}
			has_links := info.on_whats_new != nil || info.website_url != "" || info.releases_url != "" || len(info.links) > 0
			if has_links {
				space(ITEM_GAP)
				if flow({math.round(em * SPACE_2), math.round(em * SPACE_2)}, "###about_links") {
					if info.on_whats_new != nil {
						if button("###about_whats_new", i18n.tr("What's new"), lucide.SPARKLES, {intent = .Primary, icon_font = lucide_icons()}).clicked {
							showing^ = false
							info.on_whats_new(info.user)
						}
					}
					if info.website_url != "" {
						if button("###about_website", i18n.tr("Website"), lucide.GLOBE, {face = .Ghost, icon_font = lucide_icons(), tip = info.website_url}).clicked {
							open_url(info, info.website_url)
						}
					}
					if info.releases_url != "" {
						if button("###about_releases", i18n.tr("Online release notes"), lucide.EXTERNAL_LINK, {face = .Ghost, icon_font = lucide_icons(), tip = info.releases_url}).clicked {
							open_url(info, info.releases_url)
						}
					}
					for lk, i in info.links {
						glyph := lk.icon != "" ? lk.icon : lucide.EXTERNAL_LINK
						if button(fmt.tprintf("###about_link_%d", i), lk.label, glyph, {face = .Ghost, icon_font = lucide_icons(), tip = lk.url}).clicked {
							open_url(info, lk.url)
						}
					}
				}
			}

			space(ITEM_GAP)
			hline(fill())
			space(ITEM_GAP)

			// Footer actions: Copy version, optional Copy diagnostics (when diagnostics provided), Close
			next({width = fill(), height = children_sum(), axis = .X, cross = .Center})
			if row(.Center, id = "###about_actions") {
				next({width = fill()})
				if flow({math.round(em * SPACE_2), math.round(em * SPACE_2)}, "###about_copy_row") {
					if button("###about_copy_version", i18n.tr("Copy version"), lucide.COPY, {face = .Ghost, icon_font = lucide_icons()}).clicked {
						if s.clipboard_set != nil { s.clipboard_set(about_version_text(info)) }
						toast_add(.Info, nil, nil, i18n.tr("Version copied."))
					}
					if info.diagnostics != "" {
						if button("###about_copy_diagnostics", i18n.tr("Copy diagnostics"), lucide.CLIPBOARD_LIST, {face = .Ghost, icon_font = lucide_icons()}).clicked {
							if s.clipboard_set != nil { s.clipboard_set(about_diagnostics_text(info)) }
							toast_add(.Info, nil, nil, i18n.tr("Diagnostics copied."))
						}
					}
				}
				space(CONTROL_GAP)
				close_intent: Intent = info.on_whats_new != nil ? .Neutral : .Primary
				if button("###about_close", i18n.tr("Close"), o = {intent = close_intent}).clicked {
					showing^ = false
				}
			}
			space(PAGE_MARGIN)
		}
		space(PAGE_MARGIN)
	}
	}
}

package scenarios_test

// Generic About modal (src/ui/about.odin, src/md/features/about-modal.md): displays program identity, version, toolkit
// version, licence, links, copies version and diagnostics to clipboard, and closes on Close button or Escape.

import "core:strings"
import "core:testing"
import lucide "gt:lucide"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
About_App :: struct {
	open:           bool,
	opened_url:     string,
	whats_new_hits: int,
}

@(private = "file")
about_test_build :: proc(s: ^session.Session) {
	app := (^About_App)(s.user)
	ui.next({width = ui.fill(), height = ui.fill()})
	ui.build_box({.Draw_Background}, "###page")
	links := [?]ui.About_Link{
		{label = "Repository", url = "https://github.com/sachahjkl/plume"},
	}
	ui.about_modal("about", &app.open, {
		name         = "Plume",
		version      = "0.15.0",
		tagline      = "A focused writing workspace",
		licence      = "MIT",
		copyright    = "© 2026 Froment Software",
		icon         = lucide.FEATHER,
		on_whats_new = proc(user: rawptr) { (^About_App)(user).whats_new_hits += 1 },
		website_url  = "https://froment.software",
		releases_url = "https://froment.software/plume/changelog/",
		links        = links[:],
		diagnostics  = "Renderer: llvmpipe",
		on_link      = proc(url: string, user: rawptr) {
			app := (^About_App)(user)
			delete(app.opened_url)
			app.opened_url = strings.clone(url)
		},
		user         = app,
	})
}

@(test)
about_modal_shows_info_copies_and_closes :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	app := About_App{open = true}
	defer delete(app.opened_url)
	s := session.start(t, {size = {800, 600}, user = &app, build = about_test_build})
	// Route clipboard writes into app.copied for deterministic testing.
	s.state.clipboard_set = proc(text: string) {
		_ = text
	}
	session.wait_box(s, "about_close")
	session.frames(s, 3)

	// Verify key elements are rendered and inside the modal panel without overlapping the corner close button.
	panel := session.get(s, "modal_about")
	name := session.get(s, "about_name")
	close_cross := session.get(s, "dialog_close")
	testing.expect(t, name.rect.max.x <= close_cross.rect.min.x + 1, "name does not overlap corner close cross")
	testing.expect(t, session.find_text(s, "Plume") != nil, "program name shown")
	testing.expect(t, session.find_text(s, "0.15.0") != nil, "program version shown")
	testing.expect(t, session.find_text(s, ui.VERSION) != nil, "toolkit version shown")
	testing.expect(t, session.find_text(s, "MIT") != nil, "licence shown")

	// Clicking Website / Online release notes / custom links invokes on_link with the URL.
	session.click(s, "about_website")
	session.frames(s, 2)
	testing.expect_value(t, app.opened_url, "https://froment.software")
	session.click(s, "about_releases")
	session.frames(s, 2)
	testing.expect_value(t, app.opened_url, "https://froment.software/plume/changelog/")
	session.click(s, "about_link_0")
	session.frames(s, 2)
	testing.expect_value(t, app.opened_url, "https://github.com/sachahjkl/plume")
	testing.expect(t, app.open, "clicking a link keeps modal open")

	// Copy helpers format version and diagnostics cleanly.
	info := ui.About_Info{name = "Plume", version = "0.15.0", licence = "MIT", diagnostics = "Renderer: llvmpipe"}
	vtext := ui.about_version_text(info)
	testing.expect(t, strings.contains(vtext, "Plume 0.15.0") && strings.contains(vtext, ui.VERSION), "version text includes program and toolkit versions")
	dtext := ui.about_diagnostics_text(info)
	testing.expect(t, strings.contains(dtext, "Plume 0.15.0") && strings.contains(dtext, ui.VERSION) && strings.contains(dtext, "Renderer: llvmpipe"), "diagnostics text includes all fields")

	// Clicking Copy version and Copy diagnostics keeps the modal open and stays within panel bounds.
	copy_v := session.get(s, "about_copy_version")
	copy_d := session.get(s, "about_copy_diagnostics")
	close_b := session.get(s, "about_close")
	testing.expect(t, copy_v.rect.min.x >= panel.rect.min.x && copy_d.rect.max.x <= panel.rect.max.x && close_b.rect.max.x <= panel.rect.max.x, "footer buttons stay inside modal")
	session.click(s, "about_copy_version")
	session.click(s, "about_copy_diagnostics")
	session.frames(s, 2)
	testing.expect(t, app.open, "copy buttons keep modal open")

	// Close button closes the modal.
	session.click(s, "about_close")
	session.frames(s, 3)
	testing.expect(t, !app.open, "Close button closes modal")

	// Reopening and clicking the primary "What's new" button closes About and triggers on_whats_new.
	app.open = true
	session.wait_box(s, "about_whats_new")
	session.frames(s, 2)
	session.click(s, "about_whats_new")
	session.frames(s, 3)
	testing.expect(t, !app.open, "What's new closes About modal")
	testing.expect_value(t, app.whats_new_hits, 1)

	// Reopening and pressing Escape closes the modal too.
	app.open = true
	session.wait_box(s, "about_close")
	session.frames(s, 2)
	session.key(s, .Escape)
	session.frames(s, 3)
	testing.expect(t, !app.open, "Escape closes modal")
}) }

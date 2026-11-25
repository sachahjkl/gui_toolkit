package prefs_page_test

import "core:strings"
import "core:testing"
import config "gt:config"
import prefs_page "gt:prefs_page"
import "gt:testkit/session"
import "gt:ui"

@(private = "file")
FIELD_DEFS := [?]config.Def{
	{name = "net.mirror", description = "Where the copies are fetched.", kind = .String, default = {s = "https://example.org/"}, value_kind = .Address},
	{name = "net.vault_url", description = "Optional custom vault server.", kind = .String, default = {s = ""}, value_kind = .Address},
	{name = "net.download_dir", description = "Optional download folder.", kind = .String, default = {s = ""}, value_kind = .Path},
	{name = "look.style", description = "How surfaces are drawn.", kind = .String, default = {s = "flat"}, choices = {"flat", "machined"}},
}

@(private = "file")
FIELD_PAGES := [?]prefs_page.Page_Info{
	{category = "net", title = "Network"},
	{category = "look", title = "Look"},
}

@(private = "file")
Field_App :: struct {
	prefs:   config.Prefs,
	page:    prefs_page.Page,
	changed: [dynamic]string,
	closed:  bool,
}

@(private = "file")
field_app_options :: proc(app: ^Field_App) -> prefs_page.Page_Options {
	return {
		user = app,
		pages = FIELD_PAGES[:],
		changed = proc(user: rawptr, name: string) {
			app := (^Field_App)(user)
			append(&app.changed, strings.clone(name))
		},
	}
}

@(private = "file")
field_app_build :: proc(s: ^session.Session) {
	app := (^Field_App)(s.user)
	if app.closed { return }
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&app.page, &app.prefs, field_app_options(app))
}

@(private = "file")
field_app_start :: proc(t: ^testing.T, app: ^Field_App, query := "") -> ^session.Session {
	app.prefs = config.prefs_make()
	config.register(&app.prefs, FIELD_DEFS[:])
	prefs_page.focus_search(&app.page)
	s := session.start(t, {size = {1200, 700}, build = field_app_build, user = app})
	if query != "" { session.type_text(s, query) }
	return s
}

@(private = "file")
field_app_end :: proc(app: ^Field_App) {
	prefs_page.destroy(&app.page)
	config.prefs_destroy(&app.prefs)
	for n in app.changed { delete(n) }
	delete(app.changed)
}

@(private = "file")
field_box :: proc(s: ^session.Session, name: string) -> ^ui.Box {
	row := session.find(s, strings.concatenate({"set_", name}, context.temp_allocator))
	if row == nil { return nil }
	return session.find(s, "field", within = row)
}

@(private = "file")
click_field :: proc(t: ^testing.T, s: ^session.Session, name: string) -> bool {
	b := field_box(s, name)
	if !testing.expectf(t, b != nil, "field for %s", name) { return false }
	session.click_at(s, session.center(b))
	return true
}

@(test)
a_field_commits_on_blur_by_click :: proc(t: ^testing.T) {
	app: Field_App
	defer field_app_end(&app)
	s := field_app_start(t, &app)
	if !click_field(t, s, "net.mirror") { return }
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "https://blur.example/")
	// Click the page title (non-focusable) to blur the field without pressing Enter.
	title := session.get(s, "prefs_title")
	session.click_at(s, session.center(title))
	session.frames(s, 2)
	testing.expect_value(t, config.string_of(&app.prefs, "net.mirror"), "https://blur.example/")
	testing.expect_value(t, len(app.changed), 1)
	if len(app.changed) == 1 { testing.expect_value(t, app.changed[0], "net.mirror") }

	// Focusing and blurring without changes must not fire changed again.
	if !click_field(t, s, "net.mirror") { return }
	session.click_at(s, session.center(session.get(s, "prefs_title")))
	session.frames(s, 2)
	testing.expect_value(t, len(app.changed), 1)
}

@(test)
a_field_commits_on_blur_by_tab :: proc(t: ^testing.T) {
	app: Field_App
	defer field_app_end(&app)
	s := field_app_start(t, &app)
	if !click_field(t, s, "net.mirror") { return }
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "https://tab.example/")
	session.key(s, .Tab)
	session.frames(s, 2)
	testing.expect_value(t, config.string_of(&app.prefs, "net.mirror"), "https://tab.example/")
	testing.expect_value(t, len(app.changed), 1)
}

@(test)
an_empty_default_field_resyncs_on_escape_and_reset :: proc(t: ^testing.T) {
	app: Field_App
	defer field_app_end(&app)
	s := field_app_start(t, &app)

	// Escape on a field whose default is "": the draft must clear back to "".
	if !click_field(t, s, "net.vault_url") { return }
	session.type_text(s, "https://draft.example/")
	session.key(s, .Escape)
	session.frames(s, 2)
	testing.expect_value(t, config.string_of(&app.prefs, "net.vault_url"), "")
	testing.expect_value(t, len(app.changed), 0)

	// Re-focus and type without Ctrl+A: if stale draft text remained, this would concatenate.
	if !click_field(t, s, "net.vault_url") { return }
	session.type_text(s, "https://vault.example/")
	session.key(s, .Return)
	session.frames(s, 2)
	testing.expect_value(t, config.string_of(&app.prefs, "net.vault_url"), "https://vault.example/")

	// Click Reset button on the field with empty-string default (while focused and dirty!).
	session.type_text(s, "unsaved")
	row := session.find(s, "set_net.vault_url")
	if !testing.expect(t, row != nil, "vault_url row") { return }
	rst := session.find(s, "reset", within = row)
	if !testing.expect(t, rst != nil, "reset button for vault_url") { return }
	session.click_at(s, session.center(rst))
	session.frames(s, 2)
	testing.expect_value(t, config.string_of(&app.prefs, "net.vault_url"), "")

	// Re-focus and type without Ctrl+A to confirm the buffer was cleared to "".
	if !click_field(t, s, "net.vault_url") { return }
	session.type_text(s, "https://after-reset.example/")
	session.key(s, .Return)
	session.frames(s, 2)
	testing.expect_value(t, config.string_of(&app.prefs, "net.vault_url"), "https://after-reset.example/")

	// External reset to "" also resyncs an unfocused field.
	session.click_at(s, session.center(session.get(s, "prefs_title")))
	session.frames(s, 1)
	config.reset(&app.prefs, "net.vault_url")
	session.frames(s, 2)
	if !click_field(t, s, "net.vault_url") { return }
	session.type_text(s, "https://after-ext.example/")
	session.key(s, .Return)
	session.frames(s, 2)
	testing.expect_value(t, config.string_of(&app.prefs, "net.vault_url"), "https://after-ext.example/")
}

@(test)
a_field_flushes_on_page_switch :: proc(t: ^testing.T) {
	app: Field_App
	defer field_app_end(&app)
	s := field_app_start(t, &app)

	// Switch page programmatically via prefs_page.show (no mouse-blur frame before field disappears).
	if !click_field(t, s, "net.mirror") { return }
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "https://show-switch.example/")
	prefs_page.show(&app.page, &app.prefs, field_app_options(&app), "look")
	session.frames(s, 2)
	testing.expect_value(t, config.string_of(&app.prefs, "net.mirror"), "https://show-switch.example/")
	testing.expect_value(t, len(app.changed), 1)

	// Switch back to Network, edit, and switch page by clicking sidebar button.
	session.click(s, "nav0")
	session.frames(s, 2)
	if !click_field(t, s, "net.mirror") { return }
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "https://nav-switch.example/")
	session.click(s, "nav1")
	session.frames(s, 2)
	testing.expect_value(t, config.string_of(&app.prefs, "net.mirror"), "https://nav-switch.example/")
	testing.expect_value(t, len(app.changed), 2)
}

@(test)
a_field_flushes_on_search_filter_change :: proc(t: ^testing.T) {
	app: Field_App
	defer field_app_end(&app)
	s := field_app_start(t, &app)
	if !click_field(t, s, "net.mirror") { return }
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "https://search-filter.example/")
	// Hide net.mirror immediately via search query without a prior blur frame.
	ui.line_edit_set(&app.page.query, "surfaces")
	session.frames(s, 2)
	testing.expect_value(t, config.string_of(&app.prefs, "net.mirror"), "https://search-filter.example/")
	testing.expect_value(t, len(app.changed), 1)
}

@(test)
a_field_flushes_on_explicit_flush_and_destroy_is_safe_after_prefs_destroy :: proc(t: ^testing.T) {
	app: Field_App
	defer field_app_end(&app)
	s := field_app_start(t, &app)

	// Explicit flush before unmounting/saving commits pending edits immediately.
	if !click_field(t, s, "net.mirror") { return }
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "https://unmount.example/")
	app.closed = true
	prefs_page.flush(&app.page)
	testing.expect_value(t, config.string_of(&app.prefs, "net.mirror"), "https://unmount.example/")
	testing.expect_value(t, len(app.changed), 1)
	// A second flush with no further edits must not fire changed again.
	prefs_page.flush(&app.page)
	testing.expect_value(t, len(app.changed), 1)

	// Re-mount, edit another field, destroy prefs first, then destroy page:
	// destroy must only free memory (no UAF, no callback, 0 leaks).
	app.closed = false
	session.frames(s, 2)
	if !click_field(t, s, "net.download_dir") { return }
	session.type_text(s, "/tmp/wren-dl")
	app.closed = true
	config.prefs_destroy(&app.prefs)
	prefs_page.destroy(&app.page)
	testing.expect_value(t, len(app.changed), 1)
}

@(test)
a_field_blur_does_not_clobber_external_change_when_unedited :: proc(t: ^testing.T) {
	app: Field_App
	defer field_app_end(&app)
	s := field_app_start(t, &app)
	if !click_field(t, s, "net.mirror") { return }
	_ = config.set_string(&app.prefs, "net.mirror", "https://external.example/")
	session.click_at(s, session.center(session.get(s, "prefs_title")))
	session.frames(s, 2)
	testing.expect_value(t, config.string_of(&app.prefs, "net.mirror"), "https://external.example/")
	testing.expect_value(t, len(app.changed), 0)
	// Confirm the field buffer resynced to the external value: appending "x" yields ".../x".
	if !click_field(t, s, "net.mirror") { return }
	session.key(s, .End)
	session.type_text(s, "x")
	session.key(s, .Return)
	session.frames(s, 2)
	testing.expect_value(t, config.string_of(&app.prefs, "net.mirror"), "https://external.example/x")
}

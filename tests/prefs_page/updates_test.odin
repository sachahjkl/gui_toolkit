package prefs_page_test

// prefs_page.Updates: only the installed copy updates by itself, with update.auto on; the rule follows the preference
// and the install's reading with no call of the program. No server is reached: update.base_url names a port nothing
// listens on, and no check is due before the test ends (update.FIRST_CHECK).

import "core:testing"
import config "gt:config"
import prefs_page "gt:prefs_page"
import update "gt:update"

@(test)
only_the_installed_copy_updates_by_itself :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	prefs_page.standard_register(&p, {.Update}, prefs_page.STANDARD_DEFAULTS, context.temp_allocator)
	testing.expect_value(t, config.set_from_string(&p, prefs_page.UPDATE_BASE_URL_PREF, "http://127.0.0.1:9", .User), config.Set_Error.None)
	in_: prefs_page.Install
	prefs_page.install_init(&in_, &p, {version = "1.0.0"})
	u: prefs_page.Updates
	prefs_page.updates_start(&u, {product = {name = "sample"}, repository = "owner/sample", version = "1.0.0", prefs = &p, install = &in_})
	defer prefs_page.updates_stop(&u)
	testing.expect_value(t, u.folder, "http://127.0.0.1:9/")   // (update.base_url over the repository's release)

	changed, _ := prefs_page.updates_follow(&u)
	testing.expect(t, !changed, "nothing happened yet")
	testing.expect_value(t, u.mode, update.Auto_Mode.Off)   // (the install not read yet)

	in_.known, in_.running_it = true, false
	_, _ = prefs_page.updates_follow(&u)
	testing.expect_value(t, u.mode, update.Auto_Mode.Off)   // (a copy run where it was unpacked)

	in_.running_it = true
	_, _ = prefs_page.updates_follow(&u)
	testing.expect_value(t, u.mode, update.Auto_Mode.Install)

	testing.expect_value(t, config.set_from_string(&p, prefs_page.UPDATE_AUTO_PREF, "false", .User), config.Set_Error.None)
	_, _ = prefs_page.updates_follow(&u)
	testing.expect_value(t, u.mode, update.Auto_Mode.Off)
}

// With no update.base_url, the folder is the repository's latest release.
@(test)
the_folder_is_the_repository_s_latest_release :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	prefs_page.standard_register(&p, {.Update}, prefs_page.STANDARD_DEFAULTS, context.temp_allocator)
	u: prefs_page.Updates
	prefs_page.updates_start(&u, {product = {name = "sample"}, repository = "owner/sample", version = "1.0.0", prefs = &p})
	defer prefs_page.updates_stop(&u)
	testing.expect_value(t, u.folder, "https://github.com/owner/sample/releases/latest/download/")
	_, _ = prefs_page.updates_follow(&u)
	testing.expect_value(t, u.mode, update.Auto_Mode.Off)   // (no Install: never by itself)
}

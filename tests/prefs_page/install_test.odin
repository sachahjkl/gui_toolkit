package prefs_page_test

// prefs_page.Install: the offer obeys install.choice's value for this run (the command line over the user's file), and an
// uninstall from the Installation page keeps "standalone": the next start offers nothing.

import "core:testing"
import config "../../src/config"
import prefs_page "../../src/prefs_page"
import setup "../../src/setup"

@(test)
the_offer_obeys_the_choice_in_force :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	// (as a program reads them: the user's file, then the command line, both before install_init registers the name)
	_ = config.set_from_string(&p, prefs_page.INSTALL_CHOICE_PREF, setup.CHOICE_INSTALLED, .User)
	rest, errors := config.apply_args(&p, {"--pref", "install.choice=standalone"}, context.temp_allocator)
	testing.expect_value(t, len(rest), 0)
	testing.expect_value(t, len(errors), 0)
	in_: prefs_page.Install
	prefs_page.install_init(&in_, &p, {version = "1.0"})
	testing.expect_value(t, prefs_page.install_choice(&in_), setup.CHOICE_STANDALONE)
	// the page's Install writes the user's answer; the command line's still decides this run
	choice, set := prefs_page.choice_after(.Installed, false, prefs_page.install_choice(&in_), "1.0")
	testing.expect(t, set)
	_ = config.set_from_string(&p, prefs_page.INSTALL_CHOICE_PREF, choice, .User)
	testing.expect_value(t, prefs_page.install_choice(&in_), setup.CHOICE_STANDALONE)
	user, has := config.user_text(&p, prefs_page.INSTALL_CHOICE_PREF)
	testing.expect(t, has, "the user's answer kept for the file")
	testing.expect_value(t, user, setup.CHOICE_INSTALLED)
	testing.expect(t, !setup.wanted({state = .Not_Installed}, "1.0", prefs_page.install_choice(&in_)), "nothing offered")
}

@(test)
an_uninstall_is_a_choice_to_run_standalone :: proc(t: ^testing.T) {
	expect :: proc(t: ^testing.T, ev: setup.Event, upgrade: bool, saved, want: string, set: bool, loc := #caller_location) {
		c, s := prefs_page.choice_after(ev, upgrade, saved, "1.0")
		testing.expect_value(t, s, set, loc = loc)
		if set { testing.expect_value(t, c, want, loc = loc) }
	}
	expect(t, .Installed, false, "", setup.CHOICE_INSTALLED, true)
	expect(t, .Kept_Standalone, false, "", setup.CHOICE_STANDALONE, true)
	expect(t, .Uninstalled, false, setup.CHOICE_INSTALLED, setup.CHOICE_STANDALONE, true)
	expect(t, .Dismissed, false, "", "dismissed:1.0", true)
	expect(t, .Dismissed, false, setup.CHOICE_STANDALONE, "", false)
	expect(t, .Dismissed, true, setup.CHOICE_STANDALONE, "dismissed:1.0", true)   // (an upgrade declined: for this version)
	expect(t, .None, false, "", "", false)
	expect(t, .Launched, false, "", "", false)
	// after the page's Uninstall, the next start of a copy that is not installed offers nothing
	c, _ := prefs_page.choice_after(.Uninstalled, false, setup.CHOICE_INSTALLED, "1.0")
	testing.expect(t, !setup.wanted({state = .Not_Installed}, "1.0", c), "not offered after an uninstall")
}

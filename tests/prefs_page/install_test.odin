package prefs_page_test

// prefs_page.Install: the offer obeys install.choice's value for this run (the command line over the user's file), and an
// uninstall from the Installation page keeps "standalone": the next start offers nothing.

import "core:testing"
import config "gt:config"
import prefs_page "gt:prefs_page"
import setup "gt:setup"
import "gt:testkit/session"
import "gt:ui"

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

// The vendor's mark is made once, whatever the count of calls (a window that opens again calls it again), and
// install_end frees it: no program frees it by hand.
@(test)
the_vendor_mark_is_made_once_and_freed_by_the_end :: proc(t: ^testing.T) {
	s := session.start(t, {size = {320, 200}, build = proc(s: ^session.Session) { ui.label("install###install") }})
	session.frames(s, 1)
	in_: prefs_page.Install
	testing.expect(t, !prefs_page.install_vendor_mark(&in_, s.renderer, transmute([]u8)string("not an image")), "other bytes make none")
	testing.expect(t, in_.vendor_mark == nil, "the name alone")
	testing.expect(t, prefs_page.install_vendor_mark(&in_, s.renderer, MARK_PNG), "the PNG makes the mark")
	first, made := in_.vendor_mark.?
	testing.expect(t, made, "a mark")
	testing.expect(t, prefs_page.install_vendor_mark(&in_, s.renderer, MARK_PNG), "a second call")
	again, _ := in_.vendor_mark.?
	testing.expect_value(t, again.texture, first.texture)   // (the same texture: none made twice)
	prefs_page.install_end(&in_)
	testing.expect(t, in_.vendor_mark == nil, "freed by the end")
}

@(private = "file") MARK_PNG :: #load("../../site/img/logo.png")

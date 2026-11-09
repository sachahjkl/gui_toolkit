package tk_setup

import "core:testing"

// What the facts of an install make of it.
@(test)
the_state_of_an_install :: proc(t: ^testing.T) {
	testing.expect_value(t, state_of({}), State.Not_Installed)
	testing.expect_value(t, state_of({start_lnk = true}), State.Repair)   // (no program, its launcher left)
	testing.expect_value(t, state_of({desk_lnk = true}), State.Repair)
	testing.expect_value(t, state_of({exe_there = true}), State.Repair)   // (no manifest)
	testing.expect_value(t, state_of({exe_there = true, manifest = true}), State.Other_Copy)
	whole := Facts{exe_there = true, manifest = true, running_it = true, start_lnk = true, record = true}
	testing.expect_value(t, state_of(whole), State.This_Copy)
	missing := whole
	missing.missing = 1
	testing.expect_value(t, state_of(missing), State.Repair)
	no_menu := whole
	no_menu.start_lnk = false
	testing.expect_value(t, state_of(no_menu), State.Repair)
}

// Versions compare number by number; one that does not read as a version is never older.
@(test)
versions_compare_by_number :: proc(t: ^testing.T) {
	testing.expect(t, version_older("0.5.6", "0.6.0"))
	testing.expect(t, version_older("0.9.0", "0.10.0"), "by number, not by text")
	testing.expect(t, version_older("1.2", "1.2.1"), "a missing number is 0")
	testing.expect(t, !version_older("0.6.0", "0.6.0"))
	testing.expect(t, !version_older("0.6.1", "0.6.0"))
	testing.expect(t, !version_older("", "0.6.0"))
	testing.expect(t, !version_older("dev", "0.6.0"))
}

// A start opens the dialog for an older install (unless closed for this version), for no install or one to repair (unless
// the user keeps this copy standalone), never for a copy of the Nix store.
@(test)
a_start_offers_the_dialog_when_there_is_something_to_do :: proc(t: ^testing.T) {
	older := Facts{state = .Other_Copy, version = "0.0.1"}
	testing.expect(t, wanted(older, "0.2.0", ""), "older")
	testing.expect(t, wanted(older, "0.2.0", CHOICE_STANDALONE), "standalone was said of no install, not of an older one")
	testing.expect(t, wanted(older, "0.2.0", CHOICE_INSTALLED))
	testing.expect(t, !wanted(older, "0.2.0", choice_dismissed("0.2.0")), "closed for this version")
	testing.expect(t, wanted(older, "0.2.0", choice_dismissed("0.1.0")), "closed for another version")
	testing.expect(t, wanted({state = .Not_Installed}, "0.2.0", ""))
	testing.expect(t, !wanted({state = .Not_Installed}, "0.2.0", CHOICE_STANDALONE))
	testing.expect(t, wanted({state = .Repair}, "0.2.0", CHOICE_INSTALLED))
	testing.expect(t, !wanted({state = .This_Copy}, "0.2.0", ""))
	testing.expect(t, !wanted({state = .Other_Copy, version = "0.3.0"}, "0.2.0", ""), "a newer copy is installed")
	testing.expect(t, !wanted({state = .Not_Installed, from_nix = true}, "0.2.0", ""), "a copy of the Nix store")
	testing.expect(t, !wanted({state = .Nix_Package}, "0.2.0", ""))
}

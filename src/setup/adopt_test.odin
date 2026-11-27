package tk_setup

import "core:strings"
import "core:testing"

// What a start does with an earlier install, for each scope and system (src/md/features/identity-change.md): a person's
// install moves with its choices, an install for everyone is an administrator's, a Nix package is Nix's, and what an
// install left goes.
@(test)
the_plan_of_an_adoption :: proc(t: ^testing.T) {
	testing.expect_value(t, adopt_plan({}, false).move, Adopt_Move.Nothing)
	testing.expect_value(t, adopt_plan({}, true).move, Adopt_Move.Nothing)   // (the new one alone: nothing to adopt)

	mine := Facts{scope = .User, exe_there = true, manifest = true, start_lnk = true, record = true, desk_lnk = true, parts = {.Launcher, .Path, .Autostart}}
	// a download, a portable copy, a build: nothing installed; the setup offers it
	testing.expect_value(t, adopt_plan(mine, false), Adopt_Plan{move = .Offer})

	// the update bridge: this copy is the earlier install's program; it moves, and the adopted copy starts in its place
	bridged := mine
	bridged.running_it = true
	p := adopt_plan(bridged, false)
	testing.expect_value(t, p.move, Adopt_Move.Move)
	testing.expect(t, p.shortcut, "the desktop shortcut comes along")
	testing.expect_value(t, p.parts, mine.parts)
	testing.expect(t, p.relaunch, "the adopted copy starts in its place")
	testing.expect(t, adopt_plan(bridged, true).relaunch, "... also when the new one was installed already")

	testing.expect_value(t, adopt_plan(mine, true).move, Adopt_Move.Remove_Earlier)
	testing.expect_value(t, adopt_plan({scope = .User, start_lnk = true}, false).move, Adopt_Move.Remove_Earlier)   // (a launcher left)

	everyone := mine
	everyone.scope = .System
	testing.expect_value(t, adopt_plan(everyone, false).move, Adopt_Move.Administered)
	testing.expect_value(t, adopt_plan(everyone, true).move, Adopt_Move.Administered)

	nix := mine
	nix.from_nix = true
	testing.expect_value(t, adopt_plan(nix, false).move, Adopt_Move.Managed)
	testing.expect_value(t, adopt_plan({from_nix = true}, false).move, Adopt_Move.Nothing)
}

// The words say each step once, a failure or a folder left as bad, and only what happened.
@(test)
the_words_of_an_adoption :: proc(t: ^testing.T) {
	words, bad := adoption_words({})
	testing.expect(t, words == "" && !bad, "nothing adopted: nothing said")

	done := Adoption{earlier = "Old", name = "New", folders = .Done, install = .Done, command = "old", new_command = "new"}
	words, bad = adoption_words(done)
	testing.expect(t, !bad)
	testing.expect(t, strings.contains(words, "New replaces the install of Old."), words)
	testing.expect(t, strings.contains(words, "The settings and data of Old came along."), words)
	testing.expect(t, strings.contains(words, "The command old is now new."), words)
	testing.expect(t, !strings.contains(words, "taskbar"), words)

	kept := Adoption{earlier = "Old", name = "New", folders = .Kept_Both, folders_detail = "/home/a/.config/V/Old"}
	words, bad = adoption_words(kept)
	testing.expect(t, bad && strings.contains(words, "/home/a/.config/V/Old"), words)

	pinned := Adoption{earlier = "Old", name = "New", install = .Done, pinned = true}
	words, _ = adoption_words(pinned)
	testing.expect(t, strings.contains(words, "Pin New to the taskbar again"), words)

	running := Adoption{earlier = "Old", name = "New", folders = .Running, install = .Running}
	words, bad = adoption_words(running)
	testing.expect(t, bad && strings.has_prefix(words, "Close Old, then start New again"), words)

	busy := Adoption{earlier = "Old", name = "New", folders = .Busy, install = .Busy, stop = true}
	words, bad = adoption_words(busy)
	testing.expect(t, bad && strings.has_prefix(words, "Another start of New is taking over Old"), words)

	failed := Adoption{earlier = "Old", name = "New", folders = .Failed, folders_detail = "in use", stop = true}
	words, bad = adoption_words(failed)
	testing.expect(t, bad && strings.contains(words, "they stay where they were. Start New again"), words)

	copied := Adoption{earlier = "Old", name = "New", folders = .Copied, folders_detail = "/home/a/.config/V/Old"}
	words, bad = adoption_words(copied)
	testing.expect(t, !bad && strings.contains(words, "as a copy: the earlier folder stays in /home/a/.config/V/Old"), words)

	admin := Adoption{earlier = "Old", name = "New", install = .Administered}
	words, bad = adoption_words(admin)
	testing.expect(t, bad && strings.contains(words, "administrator"), words)
}

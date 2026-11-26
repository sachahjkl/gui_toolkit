package platform

import "core:testing"

// The taskbar's state machine, with no window and no system (taskbar.odin): a call that changes nothing answers false, so
// the system is called only for a change.

// A progress told again, or told in the same thousandth, changes nothing; another state with the same fraction does.
@(test)
a_progress_changes_only_by_a_step :: proc(t: ^testing.T) {
	s: Taskbar_State
	testing.expect(t, !taskbar_progress_step(&s, .None, 0), "the button shows none already")
	testing.expect(t, taskbar_progress_step(&s, .Normal, 0.4))
	testing.expect_value(t, s.done, 400)
	testing.expect(t, !taskbar_progress_step(&s, .Normal, 0.4004), "the same thousandth")
	testing.expect(t, taskbar_progress_step(&s, .Paused, 0.4), "another state")
	testing.expect(t, taskbar_progress_step(&s, .Paused, 2), "past the end")
	testing.expect_value(t, s.done, TASKBAR_STEPS)
	testing.expect(t, taskbar_progress_step(&s, .Indeterminate, 0.7))
	testing.expect_value(t, s.done, 0)   // (no fraction: another one told later is no change)
	testing.expect(t, !taskbar_progress_step(&s, .Indeterminate, 0.2))
	nan: f32 = 0
	nan = nan / nan
	testing.expect(t, taskbar_progress_step(&s, .Error, nan))
	testing.expect_value(t, s.done, 0)
}

// The count with its words and its accent; the accent of no count is no change, and no count keeps no words.
@(test)
a_badge_changes_by_its_count_words_and_disc :: proc(t: ^testing.T) {
	s: Taskbar_State
	defer delete(s.words)
	testing.expect(t, !taskbar_badge_step(&s, 0, "", TASKBAR_BADGE_RED))
	testing.expect(t, !taskbar_badge_step(&s, -2, "ignored", 0x123456), "a count under 1 is none")
	testing.expect(t, taskbar_badge_step(&s, 3, "3 sessions are waiting for you", 0x3366FF))
	words := "3 sessions are waiting for you"
	testing.expect(t, !taskbar_badge_step(&s, 3, words[:], 0x3366FF), "the same words in other memory")
	testing.expect(t, taskbar_badge_step(&s, 3, words, 0x3366FE), "another accent")
	testing.expect(t, taskbar_badge_step(&s, 3, "", 0x3366FE), "the toolkit's words")
	testing.expect_value(t, taskbar_badge_words(s), "3 waiting")
	testing.expect(t, taskbar_badge_step(&s, 0, "kept?", 0x3366FE))
	testing.expect_value(t, s.words, "")
	testing.expect(t, !taskbar_badge_step(&s, 0, "", 0x000000), "no count: its colour does not count")
	testing.expect_value(t, taskbar_badge_words(s), "")
}

// Wayland's token with no serial is asked only where the compositor marks the window; elsewhere it can take the focus.
@(test)
a_token_with_no_serial_is_asked_only_where_it_marks :: proc(t: ^testing.T) {
	testing.expect(t, wayland_attention_marks("KDE"))
	testing.expect(t, wayland_attention_marks("ubuntu:GNOME"))
	testing.expect(t, wayland_attention_marks("sway"))
	testing.expect(t, !wayland_attention_marks(""), "an unknown desktop: no token")
	testing.expect(t, !wayland_attention_marks("ShojiWM"))
	testing.expect(t, !wayland_attention_marks("Hyprland"))
	testing.expect(t, !wayland_attention_marks("GNOME-Flashback-ish:X"), "a whole name, not a prefix")
}

// Attention is refused to an active window; its flashes count; off is off whatever the flashes.
@(test)
attention_is_for_a_window_the_person_is_not_in :: proc(t: ^testing.T) {
	s: Taskbar_State
	testing.expect(t, !taskbar_attention_step(&s, true, 0, true), "the person is there")
	testing.expect(t, !s.attention)
	testing.expect(t, taskbar_attention_step(&s, true, 0, false))
	testing.expect(t, !taskbar_attention_step(&s, true, 0, false))
	testing.expect(t, taskbar_attention_step(&s, true, 3, false), "another count of flashes")
	testing.expect(t, taskbar_attention_step(&s, false, 5, false))
	testing.expect_value(t, s.flashes, 0)
	testing.expect(t, !taskbar_attention_step(&s, false, 0, true))
}

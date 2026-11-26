package taskbar_test

// Windows: a real window, never shown, given TaskbarButtonCreated as Explorer gives it. Nothing is asked of the taskbar
// before that message; after it the list exists and gets the whole state; the message again (Explorer restarted) makes the
// list again with the state kept. An offscreen window has no button and keeps its state.

import "core:testing"
import "gt:platform"

@(test)
the_button_gets_the_state_once_explorer_made_it :: proc(t: ^testing.T) {
	w := platform.open_window("taskbar", {200, 100})
	if !testing.expect(t, w != nil, "a window (never shown)") { return }
	defer platform.destroy_window(w)

	testing.expect(t, platform.taskbar_progress(w, .Error, 0.5))
	testing.expect(t, platform.taskbar_badge(w, 4, "4 sessions are waiting for you", 0x2563EB))
	testing.expect(t, !platform.taskbar_button_known(w), "no button yet: nothing asked")
	testing.expect(t, !platform.taskbar_overlay_shown(w))

	platform.taskbar_inject_button_created(w)
	testing.expect(t, platform.taskbar_button_known(w), "the list, once the button exists")
	testing.expect(t, platform.taskbar_overlay_shown(w), "the count given when the button came")

	// Explorer restarted: a new list, the state given again
	platform.taskbar_inject_button_created(w)
	testing.expect(t, platform.taskbar_button_known(w))
	testing.expect(t, platform.taskbar_overlay_shown(w))
	testing.expect_value(t, platform.taskbar_state(w).count, 4)

	testing.expect(t, !platform.taskbar_badge(w, 4, "4 sessions are waiting for you", 0x2563EB), "no change, no call")
	testing.expect(t, platform.taskbar_badge(w, 0))
	testing.expect(t, !platform.taskbar_overlay_shown(w), "no count, no picture")
	badge_in_the_theme_s_accent(t, w, 12)
	testing.expect(t, platform.taskbar_overlay_shown(w), "the theme's disc")

	// a window never shown is not the active one: the attention is taken (its flash asks nothing of a hidden button)
	testing.expect(t, platform.taskbar_attention(w, true, 3))
	testing.expect(t, platform.taskbar_attention(w, false))
	testing.expect(t, platform.taskbar_progress(w, .None))
}

@(test)
an_offscreen_window_keeps_its_state :: proc(t: ^testing.T) {
	w := platform.open_window_offscreen("taskbar", {200, 100})
	if !testing.expect(t, w != nil) { return }
	defer platform.destroy_window(w)
	testing.expect(t, platform.taskbar_badge(w, 2))
	testing.expect(t, platform.taskbar_progress(w, .Normal, 0.75))
	platform.taskbar_inject_button_created(w)
	testing.expect(t, !platform.taskbar_button_known(w), "no window of the system, no button")
	s := platform.taskbar_state(w)
	testing.expect(t, s.count == 2 && s.progress == .Normal && s.done == 750)
}

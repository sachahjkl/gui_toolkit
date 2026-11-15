package prefs_page_test

// The main window's place kept in window.placement (placement.odin): restored before the window shows, kept when it
// moves (not twice for the same place, not while minimized), and nothing restored at a first start.

import "core:testing"
import config "gt:config"
import "gt:platform"
import prefs_page "gt:prefs_page"

@(test)
the_window_comes_back_where_it_was :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	prefs_page.standard_register(&p, {.Appearance}, prefs_page.STANDARD_DEFAULTS, context.temp_allocator)
	win := platform.open_window_offscreen("placement", {800, 600})
	if !testing.expect(t, win != nil, "a window") { return }
	defer platform.destroy_window(win)
	k: prefs_page.Placement_Keeper
	defer prefs_page.placement_keeper_destroy(&k)

	testing.expect(t, !prefs_page.placement_restore(&k, &p, win), "a first start: nothing kept")
	// (kept as it is now; then once only)
	testing.expect(t, prefs_page.placement_track(&k, &p, win, 10_000), "kept the first time it is looked at")
	testing.expect(t, !prefs_page.placement_track(&k, &p, win, 20_000), "the same place: not kept again")
	// (moved and made bigger; looked at too soon, then after the delay)
	platform.set_placement(win, {rect = {120, 80, 1000, 700}})
	testing.expect(t, !prefs_page.placement_track(&k, &p, win, 21_000), "not before PLACEMENT_CHECK_MS")
	testing.expect(t, prefs_page.placement_track(&k, &p, win, 23_000), "moved: kept")
	kept := config.string_of(&p, prefs_page.PLACEMENT_PREF)
	testing.expect_value(t, kept, platform.placement_text({rect = {120, 80, 1000, 700}}))

	// the next start: another window goes where the first was, maximized again when it was
	platform.set_placement(win, {rect = {120, 80, 1000, 700}, maximized = true})
	testing.expect(t, prefs_page.placement_keep(&k, &p, win), "at the close: kept whatever the time")
	again := platform.open_window_offscreen("placement again", {640, 480})
	if !testing.expect(t, again != nil, "a second window") { return }
	defer platform.destroy_window(again)
	k2: prefs_page.Placement_Keeper
	defer prefs_page.placement_keeper_destroy(&k2)
	testing.expect(t, prefs_page.placement_restore(&k2, &p, again), "restored")
	got := platform.get_placement(again)
	testing.expect_value(t, got.rect, [4]int{120, 80, 1000, 700})
	testing.expect(t, got.maximized, "maximized again")
}

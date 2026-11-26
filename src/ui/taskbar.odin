package ui

// The count on a window's taskbar button in the theme's accent (platform.taskbar_badge has the rest; src/md/features/
// taskbar.md the reasons). Cheap at each build: the system is called only when the count, the words or the accent change,
// so a theme changed later recolours the badge at the next build that calls it.

import "core:math"
import "../platform"
import "../render"

// Shows `count` on `w`'s button (0 takes it away), its disc in the accent of the theme in use. `words` is what a screen
// reader says of it ("": the toolkit's "3 waiting"). False when the button already showed it. A ui State is in use.
taskbar_badge :: proc(w: ^platform.Window, count: int, words := "") -> (changed: bool) {
	return platform.taskbar_badge(w, count, words, rgb_of(color("accent")))
}

// A linear colour as 0xRRGGBB in sRGB, what the system's pictures take.
@(private = "file")
rgb_of :: proc(c: Color) -> u32 {
	byte :: proc(l: f32) -> u32 { return u32(math.round(render.linear_to_srgb(l) * 255)) }
	return byte(c.r) << 16 | byte(c.g) << 8 | byte(c.b)
}

package chrome_test

import "core:math"
import "core:testing"
import "../../ui"

@(private = "file")
luminance :: proc(c: u32) -> f64 {
	lin :: proc(v: u32) -> f64 {
		s := f64(v) / 255
		return s <= 0.04045 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4)
	}
	return 0.2126 * lin(c >> 24 & 255) + 0.7152 * lin(c >> 16 & 255) + 0.0722 * lin(c >> 8 & 255)
}

@(private = "file")
ratio :: proc(a, b: u32) -> f64 {
	la, lb := luminance(a), luminance(b)
	return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

// Every named palette reads: its text and its muted text on its background and panels, its text on its accent, and its
// `dark` flag matches its background.
@(test)
named_palettes_are_legible :: proc(t: ^testing.T) {
	testing.expect(t, len(ui.NAMED_PALETTES) >= 19)
	for np in ui.NAMED_PALETTES {
		p := np.palette
		testing.expectf(t, ratio(p.text, p.bg) >= 4.5, "%s: text on bg %.2f", np.name, ratio(p.text, p.bg))
		testing.expectf(t, ratio(p.text, p.panel2) >= 4.0, "%s: text on panel2 %.2f", np.name, ratio(p.text, p.panel2))
		testing.expectf(t, ratio(p.weak, p.bg) >= 3.4, "%s: weak on bg %.2f", np.name, ratio(p.weak, p.bg))
		testing.expectf(t, ratio(p.accent_text, p.accent) >= 3, "%s: accent_text on accent %.2f", np.name, ratio(p.accent_text, p.accent))
		testing.expectf(t, (luminance(p.bg) < 0.25) == p.dark, "%s: dark flag %v on luminance %.2f", np.name, p.dark, luminance(p.bg))
		_, ok := ui.palette_named(np.name)
		testing.expectf(t, ok, "%s: palette_named finds it", np.name)
	}
}

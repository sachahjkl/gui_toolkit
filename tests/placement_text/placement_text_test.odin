// A window's placement as a preference's text (platform.placement_text, placement_parse): pure, on every system.
//   odin test tests/placement_text -vet
package placement_text_test

import "core:testing"
import "../../src/platform"

// A placement as a preference's text and back; what is not one opens the window where the system puts it.
@(test)
a_placement_is_written_and_read :: proc(t: ^testing.T) {
	for p in ([]platform.Placement{{{120, 80, 1400, 900}, false}, {{-1800, -20, 1600, 1000}, true}}) {
		back, ok := platform.placement_parse(platform.placement_text(p))
		testing.expect(t, ok)
		testing.expect_value(t, back, p)
	}
	testing.expect_value(t, platform.placement_text({{-1800, -20, 1600, 1000}, true}), "-1800 -20 1600 1000 maximized")
	for bad in ([]string{"", "1 2 3", "1 2 3 4 5", "a 2 3 4", "1 2 0 4", "1 2 3 -4", "1 2 3 4 minimized"}) {
		_, ok := platform.placement_parse(bad)
		testing.expectf(t, !ok, "%q is no placement", bad)
	}
}

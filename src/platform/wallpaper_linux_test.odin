#+build linux
package platform

// set_wallpaper's ways out that touch nobody's desktop: a file that cannot be read fails before any bus; a bus that is
// nowhere says Unsupported; a portal's answer codes. (The call itself is never made here: it would change the background
// of the person running the tests. The bus is named to the call, not by DBUS_SESSION_BUS_ADDRESS: the other tests of
// the package run on other threads and read the environment.)

import "core:os"
import "core:strings"
import "core:testing"

@(test)
set_wallpaper_says_why_it_cannot :: proc(t: ^testing.T) {
	testing.expect_value(t, set_wallpaper("/nonexistent/picture.png"), Wallpaper_Result.Failed)

	// (a path with spaces: the portal takes a descriptor, the name is never quoted)
	dir := os.get_env("TMPDIR", context.temp_allocator)
	if dir == "" { dir = "/tmp" }
	picture := strings.concatenate({dir, "/gt wallpaper test.png"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(picture, []u8{0x89, 'P', 'N', 'G'}) == nil, "a file to give")
	defer os.remove(picture)
	nowhere := strings.concatenate({"unix:path=", dir, "/gt_no_bus_here"}, context.temp_allocator)
	testing.expect_value(t, wallpaper_set_at(picture, nowhere), Wallpaper_Result.Unsupported)

	testing.expect_value(t, wallpaper_result({done = true, code = 0}), Wallpaper_Result.Set)
	testing.expect_value(t, wallpaper_result({done = true, code = 1}), Wallpaper_Result.Cancelled)
	testing.expect_value(t, wallpaper_result({done = true, code = 2}), Wallpaper_Result.Failed)
	testing.expect_value(t, wallpaper_result({}), Wallpaper_Result.Failed)   // (the bus went away before the answer)
	testing.expect(t, len(wallpaper_body("gt1")) > 0, "its arguments")
}

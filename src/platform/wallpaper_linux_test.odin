#+build linux
package platform

// set_wallpaper's ways out that touch nobody's desktop: a file that cannot be read fails before any bus; a session with
// no bus says Unsupported; a portal's answer codes. (The call itself is never made here: it would change the background
// of the person running the tests.)

import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(test)
set_wallpaper_says_why_it_cannot :: proc(t: ^testing.T) {
	testing.expect_value(t, set_wallpaper("/nonexistent/picture.png"), Wallpaper_Result.Failed)

	// (a session whose bus is nowhere: the address points at a socket that does not exist)
	dir := os.get_env("TMPDIR", context.temp_allocator)
	if dir == "" { dir = "/tmp" }
	picture := strings.concatenate({dir, "/gt_wallpaper_test.png"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(picture, []u8{0x89, 'P', 'N', 'G'}) == nil, "a file to give")
	defer os.remove(picture)
	old := os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator)
	nowhere := strings.concatenate({"unix:path=", dir, "/gt_no_bus_here"}, context.temp_allocator)
	posix.setenv("DBUS_SESSION_BUS_ADDRESS", strings.clone_to_cstring(nowhere, context.temp_allocator), true)
	defer {
		if old != "" { posix.setenv("DBUS_SESSION_BUS_ADDRESS", strings.clone_to_cstring(old, context.temp_allocator), true) } else { posix.unsetenv("DBUS_SESSION_BUS_ADDRESS") }
	}
	testing.expect_value(t, set_wallpaper(picture), Wallpaper_Result.Unsupported)

	testing.expect_value(t, wallpaper_result({done = true, code = 0}), Wallpaper_Result.Set)
	testing.expect_value(t, wallpaper_result({done = true, code = 1}), Wallpaper_Result.Cancelled)
	testing.expect_value(t, wallpaper_result({done = true, code = 2}), Wallpaper_Result.Failed)
	testing.expect_value(t, wallpaper_result({}), Wallpaper_Result.Failed)   // (the bus went away before the answer)
	testing.expect(t, len(wallpaper_body("gt1")) > 0, "its arguments")
}

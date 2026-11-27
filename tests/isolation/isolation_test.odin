// A test process reaches neither the person's desktop nor their session bus (base.isolated_env, applied before main):
// whatever its environment named when it started, a window does not open and the session bus does not answer, unless the
// test runs on a server or a bus of its own (GT_TEST_DISPLAY, GT_TEST_BUS). Linux.
//   DISPLAY=:91 odin run tools/run_tests -- isolation     (:91 standing for the person's server: no window opens on it)
package isolation_test

import "core:os"
import "core:testing"
import base "gt:base"
import "gt:dbus"
import "gt:platform"

@(test)
no_window_opens_on_a_display_the_test_did_not_start :: proc(t: ^testing.T) {
	if os.get_env(base.ISOLATION_DISPLAY_ENV, context.temp_allocator) != "" { return }   // (on a server of its own: tests/linux_desktop's)
	w := platform.open_window("isolation", {100, 100})
	testing.expect(t, w == nil, "no window: the test process reaches no display")
	if w != nil { platform.destroy_window(w) }
}

@(test)
the_session_bus_does_not_answer :: proc(t: ^testing.T) {
	if os.get_env(base.ISOLATION_BUS_ENV, context.temp_allocator) != "" { return }
	c := dbus.connect_bus(.Session)
	testing.expect(t, c == nil, "no session bus: the test process reaches nobody's")
	if c != nil { dbus.conn_close(c) }
	testing.expect_value(t, os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator), base.ISOLATION_NO_BUS)
}

@(test)
vulkan_and_egl_are_mesa_s :: proc(t: ^testing.T) {
	vk := os.get_env("VK_DRIVER_FILES", context.temp_allocator)
	lvp, found := base.software_vulkan_driver()
	testing.expect(t, vk == (found ? lvp : base.ISOLATION_NO_VULKAN), "lavapipe alone, or no Vulkan driver")
	testing.expect_value(t, os.get_env("VK_LOADER_LAYERS_DISABLE", context.temp_allocator), "~implicit~")
	egl := os.get_env("__EGL_VENDOR_LIBRARY_FILENAMES", context.temp_allocator)
	testing.expect(t, egl != "", "an EGL vendor named")
}

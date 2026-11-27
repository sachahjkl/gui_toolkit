package gt_base

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
env_value :: proc(env: []string, name: string) -> (v: string, n: int) {
	for e in env {
		if strings.has_prefix(e, name) && len(e) > len(name) && e[len(name)] == '=' { v, n = e[len(name) + 1:], n + 1 }
	}
	return
}

@(private = "file")
scratch_folder :: proc(t: ^testing.T, what: string) -> string {
	dir := fmt.tprintf("%s/gt_base_%s_%d", os.get_env("TMPDIR", context.temp_allocator) != "" ? os.get_env("TMPDIR", context.temp_allocator) : "/tmp", what, os.get_pid())
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil, "a folder")
	return dir
}

// lavapipe's manifest is found among the others of an icd.d folder, for this architecture; a VK_DRIVER_FILES that names
// it alone is kept; one that names another driver is not taken.
@(test)
lavapipe_is_found_among_the_drivers :: proc(t: ^testing.T) {
	dir := scratch_folder(t, "icd")
	defer os.remove_all(dir)
	other := fmt.tprintf("%s/other", dir)
	icd := fmt.tprintf("%s/icd.d", dir)
	for d in ([]string{other, icd}) { testing.expect(t, os.make_directory_all(d) == nil, "a folder") }
	names := []string{"nvidia_icd.json", "lvp_icd.i686.json", "radeon_icd.x86_64.json", fmt.tprintf("lvp_icd.%s.json", SOFTWARE_VULKAN_ARCH)}
	for name in names { testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", icd, name), "{}") == nil, "a manifest") }
	want := fmt.tprintf("%s/lvp_icd.%s.json", icd, SOFTWARE_VULKAN_ARCH)

	path, ok := software_vulkan_find("", {fmt.tprintf("%s/none", dir), other, icd})
	testing.expect(t, ok, "found")
	testing.expect_value(t, path, want)
	path, ok = software_vulkan_find(fmt.tprintf("%s/nvidia_icd.json", icd), {icd})
	testing.expect_value(t, path, want)   // (the person's NVIDIA driver is not taken)
	path, ok = software_vulkan_find(want, nil)
	testing.expect(t, ok && path == want, "VK_DRIVER_FILES naming lavapipe is kept")
	_, ok = software_vulkan_find(fmt.tprintf("%s/nvidia_icd.json", icd), {other})
	testing.expect(t, !ok, "no lavapipe: none, never another driver")
	testing.expect(t, !software_vulkan_is("lvp_icd.i686.json"), "another architecture's")
	testing.expect(t, software_vulkan_is("/a/b/lvp_icd.json"), "a manifest with no architecture")
}

// The person's desktop, bus and drivers are taken away; a server of the test's own, and a setting that names no driver
// at all (a test of a machine without one), are kept.
@(test)
an_isolated_environment_reaches_nothing_of_the_person :: proc(t: ^testing.T) {
	dir := scratch_folder(t, "isolation")
	defer os.remove_all(dir)
	nvidia_egl := fmt.tprintf("%s/10_nvidia.json", dir)
	nvidia_icd := fmt.tprintf("%s/nvidia_icd.json", dir)
	for f in ([]string{nvidia_egl, nvidia_icd}) { testing.expect(t, os.write_entire_file(f, "{}") == nil, "a file") }
	person := []string{
		"HOME=/home/someone", "DISPLAY=:0", "WAYLAND_DISPLAY=wayland-1", "XDG_RUNTIME_DIR=/run/user/1000",
		"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus", fmt.tprintf("VK_DRIVER_FILES=%s", nvidia_icd), "VK_ICD_FILENAMES=/x.json",
		fmt.tprintf("__EGL_VENDOR_LIBRARY_FILENAMES=%s", nvidia_egl), "LIBVA_DRIVER_NAME=nvidia",
	}
	env := isolated_env(person)
	for gone in ([]string{"DISPLAY", "WAYLAND_DISPLAY", "VK_ICD_FILENAMES", "LIBVA_DRIVER_NAME"}) {
		_, n := env_value(env, gone)
		testing.expectf(t, n == 0, "%s goes", gone)
	}
	v, n := env_value(env, "DBUS_SESSION_BUS_ADDRESS")
	testing.expect(t, v == ISOLATION_NO_BUS && n == 1, "no bus answers")
	v, _ = env_value(env, "VK_DRIVER_FILES")
	testing.expect(t, v != nvidia_icd && (v == ISOLATION_NO_VULKAN || software_vulkan_is(v)), "lavapipe or no Vulkan driver")
	v, _ = env_value(env, "VK_LOADER_LAYERS_DISABLE")
	testing.expect_value(t, v, "~implicit~")
	v, _ = env_value(env, "__EGL_VENDOR_LIBRARY_FILENAMES")
	testing.expect(t, v != nvidia_egl && (v == ISOLATION_NO_EGL || isolation_is_mesa_egl(v)), "Mesa's EGL or none")
	v, _ = env_value(env, "HOME")
	testing.expect_value(t, v, "/home/someone")

	// a server of the test's own, a bus of its own, and a machine without drivers: kept
	own := []string{
		"DISPLAY=:97", "WAYLAND_DISPLAY=wayland-1", "XDG_RUNTIME_DIR=/tmp/s/run",
		fmt.tprintf("%s=/tmp/s/run/wayland-1", ISOLATION_DISPLAY_ENV), fmt.tprintf("%s=unix:path=/tmp/b", ISOLATION_BUS_ENV),
		"VK_DRIVER_FILES=/nonexistent/icd.json", "__EGL_VENDOR_LIBRARY_DIRS=/nonexistent/egl_vendor.d",
	}
	env = isolated_env(own)
	_, n = env_value(env, "WAYLAND_DISPLAY")
	testing.expect(t, n == 1, "the test's own Wayland server stays")
	_, n = env_value(env, "DISPLAY")
	testing.expect(t, n == 0, "an X server that is not the one named goes")
	v, _ = env_value(env, "DBUS_SESSION_BUS_ADDRESS")
	testing.expect_value(t, v, "unix:path=/tmp/b")
	v, _ = env_value(env, "VK_DRIVER_FILES")
	testing.expect_value(t, v, "/nonexistent/icd.json")
	_, n = env_value(env, "__EGL_VENDOR_LIBRARY_FILENAMES")
	testing.expect(t, n == 0, "no EGL vendor at all stays so")

	// a demo a person watches: the machine's own drivers, still no desktop nor bus of the person's
	env = isolated_env(person, gpu = true)
	v, _ = env_value(env, "VK_DRIVER_FILES")
	testing.expect_value(t, v, nvidia_icd)
	_, n = env_value(env, "WAYLAND_DISPLAY")
	testing.expect(t, n == 0, "not the person's desktop")
}

// This test process was isolated before its main: what isolated_env gives for its environment is what it has.
@(test)
a_test_process_is_isolated_before_its_main :: proc(t: ^testing.T) {
	now, err := os.environ(context.temp_allocator)
	if !testing.expect(t, err == nil) { return }
	again := isolated_env(now)
	for e in again {
		eq := strings.index_byte(e, '=')
		if eq <= 0 { continue }
		v, found := os.lookup_env(e[:eq], context.temp_allocator)
		testing.expectf(t, found && v == e[eq + 1:], "%s is already as isolated_env says (%q)", e[:eq], v)
	}
	if own := os.get_env(ISOLATION_DISPLAY_ENV, context.temp_allocator); own == "" {
		testing.expect(t, os.get_env("WAYLAND_DISPLAY", context.temp_allocator) == "", "no Wayland display")
		testing.expect(t, os.get_env("DISPLAY", context.temp_allocator) == "", "no X display")
	}
}

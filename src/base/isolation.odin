package gt_base

// A test, and a program a tool runs (a screenshot, a probe, a bench), never reaches the person's desktop, their session
// bus or their graphics card: src/md/infrastructure/test-isolation.md. One policy, isolated_env, applied to a test
// process's own environment before its main (isolation_linux.odin) and to every program a tool starts (toolbox).
//
//	display   DISPLAY and WAYLAND_DISPLAY go, unless they name the server the test or tool started itself
//	          (ISOLATION_DISPLAY_ENV: X11's DISPLAY, or the Wayland socket's path)
//	bus       DBUS_SESSION_BUS_ADDRESS is the bus of their own (ISOLATION_BUS_ENV), else an address where nothing answers
//	gpu       Vulkan's drivers are Mesa's lavapipe alone, its implicit layers off; EGL's vendor is Mesa's alone; VA-API
//	          finds no driver. A setting that already narrows (a driver that does not exist: a test of a machine without
//	          one) is kept. `gpu`: the machine's own driver, for a demo a person watches

import "core:strings"
import "../ascii"

// The display a server of the test's or the tool's own serves: X11's DISPLAY value (":97"), or the path of the Wayland
// socket (XDG_RUNTIME_DIR/WAYLAND_DISPLAY). Set by who starts the server (toolbox.sway_start, tk desktop_tests).
ISOLATION_DISPLAY_ENV :: "GT_TEST_DISPLAY"
// The address of a session bus of the test's own (a dbus-daemon it started).
ISOLATION_BUS_ENV :: "GT_TEST_BUS"
// Where nothing answers: a connection to it fails at once.
ISOLATION_NO_BUS :: "unix:path=/nonexistent/gt-isolated-bus"
ISOLATION_NO_VULKAN :: "/nonexistent/gt-isolated/vulkan_icd.json"
ISOLATION_NO_EGL :: "/nonexistent/gt-isolated/egl_vendor.json"
ISOLATION_NO_VA :: "/nonexistent/gt-isolated/va"

// `env` ("NAME=value" entries) as a test or a tool's program gets it (the rules above). In temp memory.
isolated_env :: proc(env: []string, gpu := false) -> []string {
	get :: proc(env: []string, name: string) -> string {
		for e in env { if strings.has_prefix(e, name) && len(e) > len(name) && e[len(name)] == '=' { return e[len(name) + 1:] } }
		return ""
	}
	drop := make([dynamic]string, context.temp_allocator)
	set := make([dynamic]string, context.temp_allocator)
	own := get(env, ISOLATION_DISPLAY_ENV)
	if x := get(env, "DISPLAY"); x != "" && x != own { append(&drop, "DISPLAY") }
	if w := get(env, "WAYLAND_DISPLAY"); w != "" {
		socket := strings.has_prefix(w, "/") ? w : strings.concatenate({get(env, "XDG_RUNTIME_DIR"), "/", w}, context.temp_allocator)
		if own == "" || socket != own { append(&drop, "WAYLAND_DISPLAY") }
	}
	bus := get(env, ISOLATION_BUS_ENV)
	append(&set, strings.concatenate({"DBUS_SESSION_BUS_ADDRESS=", bus != "" ? bus : ISOLATION_NO_BUS}, context.temp_allocator))
	if !gpu {
		// Vulkan
		files := get(env, "VK_DRIVER_FILES")
		if !isolation_all(files, isolation_is_lavapipe) {
			lvp, found := software_vulkan_driver()
			append(&set, strings.concatenate({"VK_DRIVER_FILES=", found ? lvp : ISOLATION_NO_VULKAN}, context.temp_allocator))
		}
		append(&drop, "VK_ICD_FILENAMES", "VK_ADD_DRIVER_FILES")
		append(&set, "VK_LOADER_LAYERS_DISABLE=~implicit~")
		// EGL (libglvnd)
		names := get(env, "__EGL_VENDOR_LIBRARY_FILENAMES")
		keep := names != "" ? isolation_all(names, isolation_is_mesa_egl) : isolation_none_exist(get(env, "__EGL_VENDOR_LIBRARY_DIRS"))
		if !keep {
			mesa, found := mesa_egl_vendor(get(env, "TOOLKIT_TEST_MESA_EGL"), get(env, "__EGL_VENDOR_LIBRARY_DIRS"), get(env, "XDG_DATA_DIRS"))
			append(&set, strings.concatenate({"__EGL_VENDOR_LIBRARY_FILENAMES=", found ? mesa : ISOLATION_NO_EGL}, context.temp_allocator))
		}
		// VA-API (gt:h264's encoder on the GPU): none, its software encoder draws the film
		append(&drop, "LIBVA_DRIVER_NAME")
		append(&set, strings.concatenate({"LIBVA_DRIVERS_PATH=", ISOLATION_NO_VA}, context.temp_allocator))
	}
	out := make([dynamic]string, 0, len(env) + len(set), context.temp_allocator)
	next: for e in env {
		eq := strings.index_byte(e, '=')
		name := eq > 0 ? e[:eq] : e
		for d in drop { if name == d { continue next } }
		for s in set { if strings.has_prefix(s, name) && len(s) > len(name) && s[len(name)] == '=' { continue next } }
		append(&out, e)
	}
	append(&out, ..set[:])
	return out[:]
}

// Every path of a ':' list is `ok` or does not exist (and there is one).
@(private)
isolation_all :: proc(list: string, ok: proc(path: string) -> bool) -> bool {
	if list == "" { return false }
	for p in strings.split(list, ":", context.temp_allocator) {
		if p == "" { continue }
		if !ok(p) && isolation_exists(p) { return false }
	}
	return true
}

// None of the folders of a ':' list exists (and there is one): EGL finds no vendor there.
@(private)
isolation_none_exist :: proc(list: string) -> bool {
	if list == "" { return false }
	for p in strings.split(list, ":", context.temp_allocator) { if p != "" && isolation_exists(p) { return false } }
	return true
}

@(private)
isolation_is_lavapipe :: proc(path: string) -> bool { return software_vulkan_is(path) }

// Mesa's EGL vendor file (50_mesa.json): its name says Mesa.
@(private)
isolation_is_mesa_egl :: proc(path: string) -> bool {
	name := path
	if i := strings.last_index_any(name, "/\\"); i >= 0 { name = name[i + 1:] }
	return ascii.contains_fold(name, "mesa") && strings.has_suffix(name, ".json")
}

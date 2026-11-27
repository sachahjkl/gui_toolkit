package gt_base

@(require) import "base:runtime"   // (the init's, in a test build only)
import "core:fmt"
import "core:os"
import "core:strings"

// A test process isolates itself before its main: whatever started it (run_tests, odin test by hand, a test's own child),
// it reaches neither the person's desktop nor their bus nor their graphics card (isolation.odin).
@(init, private = "file")
isolation_init :: proc "contextless" () {
	when ODIN_TEST {
		context = runtime.default_context()
		defer free_all(context.temp_allocator)
		isolate_process()
	}
}

// Applies isolated_env to this process's own environment: what its later connections and its children read.
isolate_process :: proc() {
	before, err := os.environ(context.temp_allocator)
	if err != nil { return }
	after := isolated_env(before)
	name :: proc(e: string) -> string { eq := strings.index_byte(e, '='); return eq > 0 ? e[:eq] : e }
	next: for b in before {
		for a in after { if name(a) == name(b) { continue next } }
		_ = os.unset_env(name(b))
	}
	for a in after {
		eq := strings.index_byte(a, '=')
		if eq <= 0 { continue }
		if v, _ := os.lookup_env(a[:eq], context.temp_allocator); v != a[eq + 1:] { _ = os.set_env(a[:eq], a[eq + 1:]) }
	}
}

@(private)
isolation_exists :: proc(path: string) -> bool { return os.exists(path) }

// Mesa's EGL vendor file (50_mesa.json): `given` (TOOLKIT_TEST_MESA_EGL, the dev shell's) when it is one, else the first in
// libglvnd's folders (`dirs`, __EGL_VENDOR_LIBRARY_DIRS, then XDG_DATA_DIRS's, NixOS's and the system's). In temp memory.
mesa_egl_vendor :: proc(given, dirs, data_dirs: string) -> (path: string, ok: bool) {
	if given != "" && isolation_is_mesa_egl(given) && os.exists(given) { return given, true }
	folders := make([dynamic]string, context.temp_allocator)
	for d in strings.split(dirs, ":", context.temp_allocator) { if d != "" { append(&folders, d) } }
	data := data_dirs != "" ? data_dirs : "/usr/local/share:/usr/share"
	for d in strings.split(data, ":", context.temp_allocator) { if d != "" { append(&folders, fmt.tprintf("%s/glvnd/egl_vendor.d", d)) } }
	append(&folders, "/run/opengl-driver/share/glvnd/egl_vendor.d", "/etc/glvnd/egl_vendor.d", "/usr/share/glvnd/egl_vendor.d")
	for folder in folders {
		entries, rerr := os.read_all_directory_by_path(folder, context.temp_allocator)
		if rerr != nil { continue }
		for e in entries {
			if e.type != .Directory && isolation_is_mesa_egl(e.name) { return strings.clone(e.fullpath, context.temp_allocator), true }
		}
	}
	return "", false
}

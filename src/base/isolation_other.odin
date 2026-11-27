#+build !linux
package gt_base

import "core:os"

// Windows runs its tests on a desktop of their own (tools/run_tests) and draws them on WARP; elsewhere there is no window
// yet. The policy (isolated_env) still applies to a tool's programs; nothing is done before a test's main.
isolate_process :: proc() {}

@(private)
isolation_exists :: proc(path: string) -> bool { return os.exists(path) }

mesa_egl_vendor :: proc(given, dirs, data_dirs: string) -> (path: string, ok: bool) { return "", false }

package tk_toolbox

// A desktop nobody sees, for a tool's live tests and pictures: sway with no screen (headless; pixman, the CPU, by
// default) in a folder of its own. Nothing of the person's desktop is reached: its own runtime directory (so its own
// Wayland socket and IPC), no DISPLAY, no session bus, no XDG_CURRENT_DESKTOP, and on demand its own configuration, data,
// state and cache folders. Sway and every program started in it run in process groups of their own (start_group),
// stopped with all they started, also when a signal ends the tool (guard_groups). Linux only: sway_start says so elsewhere.

import "core:fmt"
import "core:os"
import "core:time"

// How long sway has to make its socket and answer, and the step of the wait.
SWAY_WAIT :: 8 * time.Second
SWAY_POLL :: 50 * time.Millisecond
// Its one output's mode when none is given.
SWAY_OUTPUT_DEFAULT :: "1600x1000"

Sway_Options :: struct {
	output:   string,          // HEADLESS-1's mode ("": SWAY_OUTPUT_DEFAULT; "1280x1024@60Hz")
	config:   string,          // more lines of sway's config (for_window [app_id="x"] floating enable...)
	renderer: string,          // "pixman" ("": that) or "vulkan" (the GPU, as on a desktop)
	homes:    bool,            // the programs' XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME: <dir>/config, data, state
	cache:    bool,            // and their XDG_CACHE_HOME: <dir>/cache (an empty cache makes fontconfig build it again)
	wait:     time.Duration,   // 0: SWAY_WAIT
}

Sway :: struct {
	dir:      string,                // absolute: run/, sway.conf, sway.log, the programs' logs
	runtime:  string,                // XDG_RUNTIME_DIR, the user's alone
	display:  string,                // WAYLAND_DISPLAY
	ipc:      string,                // SWAYSOCK
	env:      []string,              // what a program in the session gets
	process:  os.Process,
	programs: [dynamic]os.Process,   // started by sway_program, stopped by sway_stop
	up:       bool,                  // sway runs
}

// The config of a session: no XWayland, the one headless output at its mode, then the caller's lines.
sway_config :: proc(o: Sway_Options) -> string {
	return fmt.tprintf("xwayland disable\noutput HEADLESS-1 resolution %s\n%s", o.output != "" ? o.output : SWAY_OUTPUT_DEFAULT, o.config)
}


package tk_toolbox

// The sway session of sway.odin, on Linux.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// Starts sway in `dir` (made anew) and waits, at most `o.wait`, until it answers on its socket. why: "" when it runs;
// else what failed (sway_stop still cleans up).
sway_start :: proc(s: ^Sway, dir: string, o := Sway_Options{}) -> (why: string) {
	// (the folder need not exist yet: get_absolute_path resolves only what exists)
	absolute := dir
	if !strings.has_prefix(dir, "/") {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		absolute = fmt.tprintf("%s/%s", cwd, dir)
	}
	if absolute == "" || absolute == "/" { return "sway_start: no folder" }
	s.dir = strings.clone(absolute)
	_ = os.remove_all(s.dir)
	s.runtime = strings.clone(fmt.tprintf("%s/run", s.dir))
	if os.make_directory_all(s.runtime) != nil { return fmt.tprintf("%s cannot be made", s.runtime) }
	_ = os.chmod(s.runtime, {.Read_User, .Write_User, .Execute_User})   // (a runtime directory is the user's alone)
	homes := make([dynamic]string, context.temp_allocator)
	if o.homes { append(&homes, "config", "data", "state") }
	if o.cache { append(&homes, "cache") }
	for h in homes {
		if os.make_directory_all(fmt.tprintf("%s/%s", s.dir, h)) != nil { return fmt.tprintf("%s/%s cannot be made", s.dir, h) }
	}
	conf := fmt.tprintf("%s/sway.conf", s.dir)
	if os.write_entire_file(conf, sway_config(o)) != nil { return fmt.tprintf("%s cannot be written", conf) }

	sway_env := env_with({"WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "SWAYSOCK", "XDG_CURRENT_DESKTOP"},
		fmt.tprintf("XDG_RUNTIME_DIR=%s", s.runtime), "WLR_BACKENDS=headless", fmt.tprintf("WLR_RENDERER=%s", o.renderer != "" ? o.renderer : "pixman"),
		"WLR_LIBINPUT_NO_DEVICES=1", "WLR_HEADLESS_OUTPUTS=1")
	log, lerr := os.open(fmt.tprintf("%s/sway.log", s.dir), {.Write, .Create, .Trunc})
	if lerr != nil { return "sway's log cannot be written" }
	p, serr := start_group({"sway", "--unsupported-gpu", "-c", conf}, sway_env, log)
	os.close(log)
	if serr != nil { return "sway does not start (is it on the PATH? nix develop has it)" }
	s.process, s.up = p, true

	wait := o.wait > 0 ? o.wait : SWAY_WAIT
	deadline := time.tick_add(time.tick_now(), wait)
	for s.display == "" || s.ipc == "" {
		if fis, err := os.read_all_directory_by_path(s.runtime, context.temp_allocator); err == nil {
			for fi in fis {
				if s.display == "" && strings.has_prefix(fi.name, "wayland-") && !strings.has_suffix(fi.name, ".lock") { s.display = strings.clone(fi.name) }
				if s.ipc == "" && strings.has_prefix(fi.name, "sway-ipc.") { s.ipc = strings.clone(fi.fullpath) }
			}
		}
		if s.display != "" && s.ipc != "" { break }
		if _, ended := os.process_wait(s.process, 0); ended == nil {
			group_ended(s.process)
			s.up = false
			return fmt.tprintf("sway ended (%s/sway.log)", s.dir)
		}
		if time.tick_diff(time.tick_now(), deadline) <= 0 { return fmt.tprintf("sway made no Wayland socket in %v (%s/sway.log)", wait, s.dir) }
		time.sleep(SWAY_POLL)
	}

	extra := make([dynamic]string, context.temp_allocator)
	append(&extra, fmt.tprintf("XDG_RUNTIME_DIR=%s", s.runtime), fmt.tprintf("WAYLAND_DISPLAY=%s", s.display), fmt.tprintf("SWAYSOCK=%s", s.ipc))
	if o.homes {
		append(&extra, fmt.tprintf("XDG_CONFIG_HOME=%s/config", s.dir), fmt.tprintf("XDG_DATA_HOME=%s/data", s.dir), fmt.tprintf("XDG_STATE_HOME=%s/state", s.dir))
	}
	if o.cache { append(&extra, fmt.tprintf("XDG_CACHE_HOME=%s/cache", s.dir)) }
	env := env_with({"DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "XDG_CURRENT_DESKTOP"}, ..extra[:])
	s.env = make([]string, len(env))
	for e, i in env { s.env[i] = strings.clone(e) }

	// (the socket is there before sway reads its config: it answers once its outputs are made)
	for {
		state, _, _, err := os.process_exec({command = {"swaymsg", "-t", "get_outputs"}, env = s.env}, context.temp_allocator)
		if err == nil && succeeded(state) { return "" }
		if time.tick_diff(time.tick_now(), deadline) <= 0 { return fmt.tprintf("sway does not answer in %v (%s/sway.log)", wait, s.dir) }
		time.sleep(SWAY_POLL)
	}
}

// Starts `command` in the session, in a group of its own, with the session's environment and `env` ("NAME=value", over
// it); its output in `log` ("": <dir>/<program>.log). sway_wait waits for its end and its exit code; sway_stop stops it.
sway_program :: proc(s: ^Sway, command: []string, env: []string = nil, log := "") -> (p: os.Process, why: string) {
	if !s.up || len(command) == 0 { return {}, "no session" }
	path := log != "" ? log : fmt.tprintf("%s/%s.log", s.dir, strings.trim_suffix(command[0][strings.last_index_byte(command[0], '/') + 1:], ".exe"))
	f, err := os.open(path, {.Write, .Create, .Trunc})
	if err != nil { return {}, fmt.tprintf("%s cannot be written", path) }
	defer os.close(f)
	perr: os.Error
	p, perr = start_group(command, env_merge(s.env, nil, env), f)
	if perr != nil { return {}, fmt.tprintf("%s does not start", command[0]) }
	append(&s.programs, p)
	return p, ""
}

// Waits at most `limit` for a program of the session to end (a quit asked). ended: it did, `state` says how, and what it
// left in its group is killed; else sway_stop stops it.
sway_wait :: proc(s: ^Sway, p: os.Process, limit: time.Duration) -> (state: os.Process_State, ended: bool) {
	st, err := os.process_wait(p, limit)
	if err != nil { return st, false }
	group_ended(p)
	for q, i in s.programs {
		if q.pid == p.pid { unordered_remove(&s.programs, i); break }
	}
	return st, true
}

// Stops the programs of the session, then sway, each with all it started; frees what sway_start kept.
sway_stop :: proc(s: ^Sway) {
	for p in s.programs { stop_group(p) }
	delete(s.programs)
	if s.up { stop_group(s.process) }
	for e in s.env { delete(e) }
	delete(s.env)
	delete(s.dir)
	delete(s.runtime)
	delete(s.display)
	delete(s.ipc)
	s^ = {}
}

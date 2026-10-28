#+build !windows
#+build !linux
package tk_instance

// Other platforms: no hand-over yet (instance_linux.odin's lock file and Unix socket would do on macOS and the BSDs, with
// their own runtime directory). Every start owns its name, as if there were no one else.

Owner :: struct {
	name:     string,
	identity: string,
	closing:  bool,
}

@(private)
Reply :: enum u8 { No_Window, Accepted, Other_Instance, Refused, Timeout }

@(private)
forward_once :: proc(name, identity: string, message: []byte, timeout_ms: int) -> Reply { return .No_Window }

send :: proc(cfg: Config, message: []byte) -> Outcome { return .Unresponsive }

acquire :: proc(cfg: Config, message: []byte) -> (Outcome, Owner) { return .First, Owner{name = cfg.name, identity = cfg.identity} }

owner_start :: proc(o: ^Owner, handler: Handler, user: rawptr) -> bool { return true }

owner_closing :: proc(o: ^Owner) {}

owner_stop :: proc(o: ^Owner) {}

is_elevated :: proc() -> bool { return false }

raise_window :: proc(handle: rawptr) {}

pump_messages :: proc() {}

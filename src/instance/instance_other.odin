#+build !windows
#+build !linux
package tk_instance

// Other platforms: no hand-over yet (instance_linux.odin's lock file and Unix socket would do on macOS and the BSDs, with
// their own runtime directory). Every start owns its name, as if there were no one else.

Owner :: struct {
	name:     string,
	identity: string,
	state:    Owner_State,
}

@(private)
Reply :: enum u8 { No_Window, Accepted, Other_Instance, Refused, Timeout }

@(private)
forward_once :: proc(name, identity: string, message: []byte, timeout_ms: int) -> Reply { return .No_Window }

send :: proc(o: Instance_Options, message: []byte) -> Outcome { return .Unresponsive }

acquire :: proc(o: Instance_Options, message: []byte) -> (Outcome, Owner) { return .First, Owner{name = o.name, identity = o.identity, state = .Claimed} }

owner_start :: proc(o: ^Owner, handler: Handler, user: rawptr) -> bool {
	if o.state != .Claimed { return false }
	o.state = .Serving
	return true
}

owner_closing :: proc(o: ^Owner) { if o.state != .None { o.state = .Closing } }

owner_stop :: proc(o: ^Owner) { o.state = .None }

is_elevated :: proc() -> bool { return false }

raise_window :: proc(handle: rawptr) {}

pump_messages :: proc() {}

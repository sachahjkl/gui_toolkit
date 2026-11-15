#+build !windows
#+build !linux
package tk_secrets

// The systems with no store here yet (macOS: the Keychain comes with its port): nothing is sealed, a sealed field is
// Refused.

@(private)
seal_system :: proc(app, name, secret: string, allocator := context.allocator) -> (field: string, result: Seal_Result) {
	return "", .Unavailable
}

@(private)
open_system :: proc(app, field: string, allocator := context.allocator) -> (secret: string, result: Open_Result) {
	return "", .Refused
}

@(private)
forget_system :: proc(app, field: string) {}

@(private)
available_system :: proc() -> bool { return false }

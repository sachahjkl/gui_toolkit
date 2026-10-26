#+build !windows
package platform

// Accessibility on the systems that have no adapter yet (a11y.odin has the API; AccessKit has adapters for AT-SPI and
// macOS that native/a11y can wrap): nobody reads the windows, nothing is built.

a11y_available :: proc() -> bool { return false }
a11y_state :: proc(w: ^Window) -> A11y_State { return .Off }
a11y_send :: proc(w: ^Window, u: ^A11y_Update, toolkit_name := "gui_toolkit", toolkit_version := "") -> A11y_Send { return .Inactive }
a11y_take_request :: proc(w: ^Window) -> (r: A11y_Request, ok: bool) { return }

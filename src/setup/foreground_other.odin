#+build !windows
package tk_setup

// Off Windows a new process's window is not kept from the front: Wayland and X11 compositors decide by the activation
// token, which the program passes itself (platform.activation_token_from_env).
@(private)
foreground_allow :: proc(pid: int) {}

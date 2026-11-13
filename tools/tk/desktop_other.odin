#+build !linux
package tk

// desktop_tests runs the Linux backends on a virtual desktop: Linux only.
run_desktop_tests :: proc(args: []string) -> string { return "the virtual desktops are Linux's (Xvfb, Xorg, sway)" }

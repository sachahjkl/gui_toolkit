#+build !windows
#+build !linux
package tk_shortcuts

import "../platform"

@(private) system_start :: proc(s: ^Service) { set_backend(s, .None, false) }
@(private) system_stop :: proc(s: ^Service) {}
@(private) system_bind :: proc(s: ^Service, list: []Shortcut) { set_all(s, .Unavailable) }
@(private) system_configure :: proc(s: ^Service) -> bool { return false }
@(private) system_feed :: proc(s: ^Service, e: platform.Event) -> bool { return false }
@(private) system_hold :: proc(s: ^Service, held: bool) {}

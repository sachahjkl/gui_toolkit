#+build !linux
package file_request

// The XDG portal is Linux's: elsewhere the server opens nothing.

Portal_Server :: struct {}

portal_open :: proc(s: ^Portal_Server, child: []string, address := "") -> (why: string) { return "the XDG desktop portal is Linux's" }
portal_run :: proc(s: ^Portal_Server) {}
portal_stop :: proc(s: ^Portal_Server) {}
portal_close :: proc(s: ^Portal_Server) {}

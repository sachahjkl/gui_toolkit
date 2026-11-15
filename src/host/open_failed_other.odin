#+build !windows
package tk_host

// Elsewhere the line on standard error is the message: a program started from a desktop file has its errors in the
// session's journal, where a person who asks for help finds them.
@(private)
open_failed_box :: proc(title, why: string) {}

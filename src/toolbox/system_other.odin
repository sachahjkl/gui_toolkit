#+build !windows
package tk_toolbox

// A program of the system (curl, unzip): the one on the PATH.
system_program :: proc(name: string) -> string { return name }

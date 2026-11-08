#+build !windows
package tk

// A program of the system (curl, unzip): the one on the PATH.
system_program :: proc(name: string) -> string { return name }

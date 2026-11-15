#+build !windows
#+build !linux
package tk_toolbox

// The options of `odin` that this system adds: none yet.
@(private)
system_odin_flags :: proc(p: Project, verb, pkg: string, cmd: ^[dynamic]string) {}

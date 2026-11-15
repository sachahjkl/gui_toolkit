package tk_toolbox

// The options of `odin` that this system adds: the program's Linux defines, and the link flag (LINUX_LINK_FLAG).
@(private)
system_odin_flags :: proc(p: Project, verb, pkg: string, cmd: ^[dynamic]string) {
	append(cmd, ..p.linux_defines)
	if verb != "check" { append(cmd, LINUX_LINK_FLAG) }
}

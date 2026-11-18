package tk_toolbox

// The options of `odin` that this system adds: the program's Linux defines. (Its linker flag is linker_flag's, with
// every other.)
@(private)
system_odin_flags :: proc(p: Project, verb, pkg: string, cmd: ^[dynamic]string) {
	append(cmd, ..p.linux_defines)
}

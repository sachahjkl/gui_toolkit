package gt_base

import "core:sys/linux"

// Root (its effective id): the one account whose rights the user's files must never get. (A process that cannot say
// is not one: geteuid cannot fail.)
@(private)
elevation_query :: proc() -> bool { return linux.geteuid() == 0 }

// (Windows only: the dynamic linker here does not search the working folder)
dll_search_restrict :: proc() {}

// A program by its full path in a folder that only root writes: the Nix store and the system's folders.
trusted_program :: proc(program: string) -> bool {
	if len(program) == 0 || program[0] != '/' || contains_dot_dot(program) { return false }
	for prefix in ([]string{"/nix/store/", "/run/current-system/sw/", "/usr/", "/bin/", "/sbin/", "/lib/", "/lib64/"}) {
		if len(program) > len(prefix) && program[:len(prefix)] == prefix { return true }
	}
	return false
}

package tk_process

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

// /proc's names: one read of a few hundred processes; a path of an executable.
@(private = "file") PROC_LIST_BYTES :: 32 * 1024
@(private = "file") EXE_PATH_BYTES :: 4096

// The processes whose /proc/<pid>/exe is `exe`. Another user's processes cannot be read: they are not this user's
// programs, and they are left out. A process whose file was replaced since it started reads "<path> (deleted)": it no
// longer holds the file at `exe`, and it is left out too.
processes_of :: proc(exe: string, allocator := context.allocator) -> []Process_Ref {
	found := make([dynamic]Process_Ref, allocator)
	if exe == "" { return found[:] }
	dir, err := linux.open("/proc", {.DIRECTORY, .CLOEXEC})
	if err != .NONE { return found[:] }
	defer linux.close(dir)
	self := i32(os.get_pid())
	names: [PROC_LIST_BYTES]u8
	for {
		n, derr := linux.getdents(dir, names[:])
		if derr != .NONE || n <= 0 { break }
		off := 0
		for d in linux.dirent_iterate_buf(names[:n], &off) {
			pid, is_num := strconv.parse_int(linux.dirent_name(d), 10)
			if !is_num || i32(pid) == self { continue }
			if !same_executable(exe_of(i32(pid)), exe) { continue }
			// (a process that ended since it was listed: nothing to name)
			if start, ok := process_start_time(i32(pid)); ok { append(&found, Process_Ref{i32(pid), start}) }
		}
	}
	return found[:]
}

same_executable :: proc(found, exe: string) -> bool { return found != "" && found == exe }

// The executable of the process `pid` (temp memory; "" when it cannot be read).
@(private = "file")
exe_of :: proc(pid: i32) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "/proc/")
	strings.write_int(&b, int(pid))
	strings.write_string(&b, "/exe")
	path := strings.to_cstring(&b) or_else ""
	buf := make([]u8, EXE_PATH_BYTES, context.temp_allocator)
	n, err := linux.readlink(path, buf)
	if err != .NONE || n <= 0 || n >= len(buf) { return "" }
	return string(buf[:n])
}

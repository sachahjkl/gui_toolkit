#+build linux
package tk_plugins

// A plugin's process sandboxed by the system, on Linux (plugins.md, "As built: the sandbox"): Landlock takes away
// every path and TCP port (and, from its ABI 6, the signals and abstract sockets out of the process), and a seccomp
// filter every socket. The child sets both itself, after it read its Start and its modules, alone on its thread.
// The system calls are made by number: core:sys/linux has no wrapper for Landlock nor for a seccomp filter.

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "../fsx"
import "../process"

// The program starts the child as before: Linux's sandbox is the child's own to set (sandbox_enter).
@(private)
sandbox_spawn :: proc(exe: string, stdin, stdout: ^os.File) -> (os.Process, os.Error) {
	return process.start({command = {exe, CHILD_ARG}, stdin = stdin, stdout = stdout, stderr = os.stderr})
}

// Whether this system can isolate a plugin's process, and why not (for a test that must skip, or a program's page).
sandbox_available :: proc() -> (ok: bool, why: string) {
	if FILTER_ARCH == 0 { return false, "no seccomp filter is written for this processor" }
	abi := landlock_abi()
	if abi < 1 { return false, landlock_missing(abi) }
	return true, ""
}

////////////////////////////////
// Landlock (include/uapi/linux/landlock.h)

@(private = "file") LANDLOCK_CREATE_RULESET_VERSION :: 1 << 0

// The file system's rights, each from the ABI that added it.
@(private = "file") ACCESS_FS_ABI_1 :: u64(1 << 13) - 1   // execute .. make_sym: the thirteen of ABI 1
@(private = "file") ACCESS_FS_REFER :: u64(1 << 13)       // ABI 2
@(private = "file") ACCESS_FS_TRUNCATE :: u64(1 << 14)    // ABI 3
@(private = "file") ACCESS_FS_IOCTL_DEV :: u64(1 << 15)   // ABI 5
@(private = "file") ACCESS_NET_BIND_TCP :: u64(1 << 0)    // ABI 4
@(private = "file") ACCESS_NET_CONNECT_TCP :: u64(1 << 1)
@(private = "file") SCOPE_ABSTRACT_UNIX_SOCKET :: u64(1 << 0)   // ABI 6
@(private = "file") SCOPE_SIGNAL :: u64(1 << 1)

// (the kernel takes a longer struct than it knows when the rest is zero: one size for every ABI)
@(private = "file")
Ruleset_Attr :: struct {
	handled_access_fs:  u64,
	handled_access_net: u64,
	scoped:             u64,
}

// The kernel's Landlock ABI: 1 or more, or the negative errno of the query (-ENOSYS: no such call, -EOPNOTSUPP: not
// enabled at boot).
@(private = "file")
landlock_abi :: proc() -> int {
	return int(intrinsics.syscall(linux.SYS_landlock_create_ruleset, 0, 0, uintptr(LANDLOCK_CREATE_RULESET_VERSION)))
}

@(private = "file")
landlock_missing :: proc(abi: int) -> string {
	switch abi {
	case -38: return "the kernel has no Landlock (older than 5.13)"
	case -95: return "the kernel's Landlock is off (not in its lsm= list)"
	}
	return fmt.tprintf("the kernel refused Landlock (%d)", abi)
}

// A rule set with every right the kernel knows handled and no rule: no path, no TCP port. ok false: `why`.
@(private = "file")
landlock_restrict :: proc(abi: int) -> (said: string, ok: bool) {
	attr := Ruleset_Attr{handled_access_fs = ACCESS_FS_ABI_1}
	if abi >= 2 { attr.handled_access_fs |= ACCESS_FS_REFER }
	if abi >= 3 { attr.handled_access_fs |= ACCESS_FS_TRUNCATE }
	if abi >= 5 { attr.handled_access_fs |= ACCESS_FS_IOCTL_DEV }
	if abi >= 4 { attr.handled_access_net = ACCESS_NET_BIND_TCP | ACCESS_NET_CONNECT_TCP }
	if abi >= 6 { attr.scoped = SCOPE_ABSTRACT_UNIX_SOCKET | SCOPE_SIGNAL }
	fd := int(intrinsics.syscall(linux.SYS_landlock_create_ruleset, uintptr(&attr), uintptr(size_of(attr)), 0))
	if fd < 0 { return fmt.tprintf("Landlock's rule set was refused (%d)", fd), false }
	defer sys_close(fd)
	if r := int(intrinsics.syscall(linux.SYS_landlock_restrict_self, uintptr(fd), 0)); r < 0 {
		return fmt.tprintf("Landlock's restriction was refused (%d)", r), false
	}
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, "no file")
	append(&parts, abi >= 4 ? "no TCP port" : "TCP ports (Landlock ABI < 4; the socket filter closes them)")
	append(&parts, abi >= 6 ? "no signal out" : "signals out (Landlock ABI < 6)")
	return fmt.tprintf("Landlock ABI %d: %s", abi, strings.join(parts[:], ", ", context.temp_allocator)), true
}

////////////////////////////////
// seccomp-bpf (include/uapi/linux/seccomp.h, filter.h, audit.h)

when ODIN_ARCH == .amd64 {
	@(private = "file") FILTER_ARCH :: u32(0xC000003E)   // AUDIT_ARCH_X86_64
} else when ODIN_ARCH == .arm64 {
	@(private = "file") FILTER_ARCH :: u32(0xC00000B7)   // AUDIT_ARCH_AARCH64
} else {
	@(private = "file") FILTER_ARCH :: u32(0)            // no filter written: not isolated
}

@(private = "file") BPF_LD_W_ABS :: u16(0x20)
@(private = "file") BPF_JEQ_K :: u16(0x15)
@(private = "file") BPF_JGE_K :: u16(0x35)
@(private = "file") BPF_RET_K :: u16(0x06)
@(private = "file") SECCOMP_RET_KILL_PROCESS :: u32(0x80000000)
@(private = "file") SECCOMP_RET_ERRNO :: u32(0x00050000)
@(private = "file") SECCOMP_RET_ALLOW :: u32(0x7fff0000)
@(private = "file") EPERM :: u32(1)
@(private = "file") X32_SYSCALL_BIT :: u32(0x40000000)
// seccomp_data's offsets: the call's number, then the architecture
@(private = "file") DATA_NR :: u32(0)
@(private = "file") DATA_ARCH :: u32(4)
@(private = "file") PR_SET_NO_NEW_PRIVS :: 38
@(private = "file") PR_SET_SECCOMP :: 22
@(private = "file") SECCOMP_MODE_FILTER :: 2

@(private = "file")
Sock_Filter :: struct {
	code: u16,
	jt:   u8,
	jf:   u8,
	k:    u32,
}

@(private = "file")
Sock_Fprog :: struct {
	len:    u16,
	filter: [^]Sock_Filter,
}

// The filter: another architecture's call kills the process (its numbers are not these); x32's numbers, `socket`,
// `socketpair` and `io_uring_setup` (a ring makes sockets without `socket`) give EPERM; the rest is allowed.
@(private = "file")
seccomp_install :: proc() -> (said: string, ok: bool) {
	when FILTER_ARCH == 0 {
		return "no seccomp filter is written for this processor", false
	} else {
		denied := [?]u32{u32(linux.SYS_socket), u32(linux.SYS_socketpair), u32(linux.SYS_io_uring_setup)}
		x32 := ODIN_ARCH == .amd64
		prog := make([dynamic]Sock_Filter, context.temp_allocator)
		append(&prog, Sock_Filter{code = BPF_LD_W_ABS, k = DATA_ARCH})
		append(&prog, Sock_Filter{code = BPF_JEQ_K, jt = 1, jf = 0, k = FILTER_ARCH})
		append(&prog, Sock_Filter{code = BPF_RET_K, k = SECCOMP_RET_KILL_PROCESS})
		append(&prog, Sock_Filter{code = BPF_LD_W_ABS, k = DATA_NR})
		// (each test jumps to the last instruction, the refusal, when it holds: n - k ahead of the one after it)
		n := len(denied) + (x32 ? 1 : 0)
		k := 0
		if x32 {
			append(&prog, Sock_Filter{code = BPF_JGE_K, jt = u8(n - k), jf = 0, k = X32_SYSCALL_BIT})
			k += 1
		}
		for nr in denied {
			append(&prog, Sock_Filter{code = BPF_JEQ_K, jt = u8(n - k), jf = 0, k = nr})
			k += 1
		}
		append(&prog, Sock_Filter{code = BPF_RET_K, k = SECCOMP_RET_ALLOW})
		append(&prog, Sock_Filter{code = BPF_RET_K, k = SECCOMP_RET_ERRNO | EPERM})
		fprog := Sock_Fprog{len = u16(len(prog)), filter = raw_data(prog)}
		r := int(intrinsics.syscall(linux.SYS_prctl, uintptr(PR_SET_SECCOMP), uintptr(SECCOMP_MODE_FILTER), uintptr(&fprog), 0, 0))
		if r < 0 { return fmt.tprintf("the seccomp filter was refused (%d)", r), false }
		return "no socket", true
	}
}

////////////////////////////////
// The child's side

// Isolates this process, alone on its thread, for good. `isolated`: both layers hold; `said`: what holds, or why not
// (the plugin's log says it once).
@(private)
sandbox_enter :: proc(mode: Sandbox_Mode) -> (isolated: bool, said: string) {
	if mode == .Off { return false, "not isolated: the program turned its sandbox off (Host_Options.sandbox)" }
	// (Landlock binds this thread and those it makes later: one made before would be free)
	if n := threads(); n != 1 { return false, fmt.tprintf("not isolated: %d threads ran before its sandbox", n) }
	// (neither layer can be set without it, and with it no set-uid program can lift them)
	if r := int(intrinsics.syscall(linux.SYS_prctl, uintptr(PR_SET_NO_NEW_PRIVS), 1, 0, 0, 0)); r < 0 {
		return false, fmt.tprintf("not isolated: no_new_privs was refused (%d)", r)
	}
	files := ""
	files_ok := false
	if abi := landlock_abi(); abi >= 1 {
		files, files_ok = landlock_restrict(abi)
	} else {
		files = landlock_missing(abi)
	}
	sockets, sockets_ok := seccomp_install()
	if files_ok && sockets_ok { return true, fmt.tprintf("isolated: %s; %s", files, sockets) }
	return false, fmt.tprintf("not isolated: %s; %s", files, sockets)
}

// This process's threads now (/proc/self/stat's 20th field; 0: unknown).
@(private = "file")
threads :: proc() -> int {
	// (read_at, not read_all: a /proc file says it has no size, and read_all reads the size it says)
	buf: [4096]u8
	n_read, ok := fsx.read_at("/proc/self/stat", 0, buf[:])
	if !ok || n_read == 0 { return 0 }
	text := string(buf[:n_read])
	// (the name in parentheses may hold spaces: the fields count from the last ')')
	paren := strings.last_index_byte(text, ')')
	if paren < 0 { return 0 }
	fields := strings.fields(text[paren + 1:], context.temp_allocator)
	if len(fields) < 18 { return 0 }
	n, _ := strconv.parse_int(fields[17], 10)
	return n
}

// What test_escape tries, each by its system call: what the sandbox must refuse.
@(private)
escape_try :: proc(read_path, create_dir: string) -> (read, create, socket: bool) {
	O_WRONLY :: 0o1
	O_CREAT :: 0o100
	O_EXCL :: 0o200
	O_CLOEXEC :: 0o2000000
	AF_INET :: 2
	SOCK_STREAM :: 1
	at_cwd := -100   // (AT_FDCWD: a variable, so that its conversion to a word wraps)
	if fd := int(intrinsics.syscall(linux.SYS_openat, uintptr(at_cwd), uintptr(rawptr(strings.clone_to_cstring(read_path, context.temp_allocator))), uintptr(O_CLOEXEC))); fd >= 0 {
		sys_close(fd)
		read = true
	}
	// (a name of its own, made only if absent: the test's folder is new)
	path := strings.clone_to_cstring(fsx.path_join(create_dir, "escape.txt"), context.temp_allocator)
	if fd := int(intrinsics.syscall(linux.SYS_openat, uintptr(at_cwd), uintptr(rawptr(path)), uintptr(O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC), uintptr(0o600))); fd >= 0 {
		sys_close(fd)
		_ = intrinsics.syscall(linux.SYS_unlinkat, uintptr(at_cwd), uintptr(rawptr(path)), 0)
		create = true
	}
	// (SOCK_CLOEXEC is O_CLOEXEC on x86_64 and arm64)
	if fd := int(intrinsics.syscall(linux.SYS_socket, uintptr(AF_INET), uintptr(SOCK_STREAM | O_CLOEXEC), 0)); fd >= 0 {
		sys_close(fd)
		socket = true
	}
	return
}

@(private = "file")
sys_close :: proc(fd: int) {
	_ = intrinsics.syscall(linux.SYS_close, uintptr(fd))
}

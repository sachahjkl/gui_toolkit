#+build linux
package platform

// The trash of the freedesktop.org specification (Trash 1.0), which every Linux desktop reads: a file goes to the home
// trash ($XDG_DATA_HOME/Trash) when it is on the same volume, else to the trash at the top of its own volume
// (<top>/.Trash-<uid>). Beside it, info/<name>.trashinfo says where it was and when it went, so that the desktop's trash
// can put it back too. The file is renamed, never copied: a trash is always on the file's volume.

import "core:c/libc"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import base "../base"

// Moves `path` to the system's trash. `in_trash`: where it is now (put_back's argument), in `allocator`. It asks the
// disk: call it from a task.
move_to_trash :: proc(path: string, allocator := context.allocator, loc := #caller_location) -> (in_trash: string, ok: bool) {
	base.blocking("platform.move_to_trash", loc)
	clean := strings.trim_right(path, "/")
	if clean == "" { return }
	dev, dev_ok := trash_device_of(clean)
	if !dev_ok { return }
	data := user_dir_base(.Data)
	if data == "" { return }
	dir := trash_join(data, "Trash")
	_ = linux.mkdir(trash_cpath(data), {.IRUSR, .IWUSR, .IXUSR})   // (a new account may have no ~/.local/share yet)
	if hdev, hok := trash_device_of(data); !hok || hdev != dev {
		dir = trash_join(trash_volume_top(clean, dev), fmt.tprintf(".Trash-%d", u32(linux.getuid())))
	}
	files := trash_join(dir, "files")
	info := trash_join(dir, "info")
	for d in ([]string{dir, files, info}) {
		if e := linux.mkdir(trash_cpath(d), {.IRUSR, .IWUSR, .IXUSR}); e != .NONE && e != .EEXIST { return }
	}
	// (a name of its own in the trash, taken by making its .trashinfo with O_EXCL: two programs never take the same)
	name := filepath.base(clean)
	info_path := ""
	fd: linux.Fd = -1
	for n := 1; n < 10000; n += 1 {
		candidate := name
		if n > 1 {
			stem, ext := trash_split_ext(name)
			candidate = fmt.tprintf("%s (%d)%s", stem, n, ext)
		}
		if _, taken := trash_device_of(trash_join(files, candidate)); taken { continue }
		p := trash_join(info, strings.concatenate({candidate, ".trashinfo"}, context.temp_allocator))
		f, e := linux.open(trash_cpath(p), {.WRONLY, .CREAT, .EXCL, .CLOEXEC}, {.IRUSR, .IWUSR})
		if e == .EEXIST { continue }
		if e != .NONE { return }
		fd, name, info_path = f, candidate, p
		break
	}
	if fd < 0 { return }
	text := fmt.tprintf("[Trash Info]\nPath=%s\nDeletionDate=%s\n", trash_url_path(clean), trash_local_time())
	_, werr := linux.write(fd, transmute([]u8)text)
	linux.close(fd)
	if werr != .NONE {
		linux.unlink(trash_cpath(info_path))
		return
	}
	to := trash_join(files, name)
	if linux.renameat2(linux.AT_FDCWD, trash_cpath(clean), linux.AT_FDCWD, trash_cpath(to), {.NOREPLACE}) != .NONE {
		linux.unlink(trash_cpath(info_path))
		return
	}
	return strings.clone(to, allocator), true
}

// Puts back what move_to_trash moved to `in_trash`, at `to` (where it was), and removes its .trashinfo. False when
// something is at `to` again: it never goes over it. It asks the disk: call it from a task.
put_back :: proc(in_trash, to: string, loc := #caller_location) -> bool {
	base.blocking("platform.put_back", loc)
	if in_trash == "" || to == "" { return false }
	if linux.renameat2(linux.AT_FDCWD, trash_cpath(in_trash), linux.AT_FDCWD, trash_cpath(to), {.NOREPLACE}) != .NONE { return false }
	// (<trash>/files/<name> -> <trash>/info/<name>.trashinfo)
	trash := filepath.dir(filepath.dir(in_trash))
	linux.unlink(trash_cpath(trash_join(trash_join(trash, "info"), strings.concatenate({filepath.base(in_trash), ".trashinfo"}, context.temp_allocator))))
	return true
}

@(private = "file")
trash_cpath :: proc(path: string) -> cstring { return strings.clone_to_cstring(path, context.temp_allocator) }

@(private = "file")
trash_join :: proc(dir, name: string) -> string { return strings.concatenate({dir, "/", name}, context.temp_allocator) }

// The device of `path` itself (a link not followed: the link goes to the trash, not what it points to).
@(private = "file")
trash_device_of :: proc(path: string) -> (dev: u64, ok: bool) {
	sx: linux.Statx
	if linux.statx(linux.AT_FDCWD, trash_cpath(path), {.SYMLINK_NOFOLLOW}, {.TYPE}, &sx) != .NONE { return }
	return u64(sx.dev_major) << 32 | u64(sx.dev_minor), true
}

// The folder at the top of the volume that holds `path`: the last folder up the path still on device `dev`.
@(private = "file")
trash_volume_top :: proc(path: string, dev: u64) -> string {
	at := path
	for {
		up := filepath.dir(at)
		if up == at || up == "" || up == "." { return at }
		d, ok := trash_device_of(up)
		if !ok || d != dev { return at }
		at = up
	}
}

// "notes.txt" -> "notes", ".txt"; a name without a dot, or a dot first (".bashrc"), has no extension.
@(private = "file")
trash_split_ext :: proc(name: string) -> (stem, ext: string) {
	dot := strings.last_index_byte(name, '.')
	if dot <= 0 { return name, "" }
	return name[:dot], name[dot:]
}

// The path as the specification writes it: every byte but the unreserved ones and '/' as %XX.
@(private = "file")
trash_url_path :: proc(path: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(path) {
		c := path[i]
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.', '~', '/': strings.write_byte(&b, c)
		case: fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}

// "2026-11-20T14:00:05", the local time, as the specification asks.
@(private = "file")
trash_local_time :: proc() -> string {
	now := libc.time(nil)
	tm: posix.tm
	if posix.localtime_r(&now, &tm) == nil { return "" }
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02d", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec)
}

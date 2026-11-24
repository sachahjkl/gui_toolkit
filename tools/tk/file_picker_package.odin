package tk

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import archive "../../src/archive"
import flate "../../src/flate"
import toolbox "../../src/toolbox"

FILE_PICKER_OUT_DEFAULT :: "build/release"

// The portal's files of the Linux archive: where the person's portal finds the backend, and how the session bus starts
// it (apps/file-picker/README.md says where each goes).
@(private = "file") FILE_PICKER_PORTAL_FILE :: "share/xdg-desktop-portal/portals/gtfilepicker.portal"
@(private = "file") FILE_PICKER_SERVICE_FILE :: "share/dbus-1/services/org.freedesktop.impl.portal.desktop.gtfilepicker.service"

// file_picker_package [-out:dir]: gt-file-picker built as `tk build file-picker` builds it, packed for this system:
// Windows: <dir>/gt-file-picker-windows-x64.zip (the exe, its README); Linux: <dir>/gt-file-picker-linux-x64.tar.gz (the
// binary in bin/, its README, the portal's files in share/). The Linux binary's interpreter is set to the system's
// (/lib64/ld-linux-x86-64.so.2) and its run path removed: a build in nix develop names the Nix store's.
run_file_picker_package :: proc(args: []string) -> string {
	root := toolkit_root()
	out := toolbox.flag_value(args, "out", join({root, FILE_PICKER_OUT_DEFAULT}))
	_ = os.make_directory_all(out)
	if why := build_app(root, "file-picker", false); why != "" { return why }
	exe_name := fmt.tprintf("gt-file-picker%s", EXE)
	exe_path := join({root, "build", exe_name})
	readme, rerr := os.read_entire_file(join({root, "apps", "file-picker", "README.md"}), context.temp_allocator)
	if rerr != nil { return fmt.tprintf("apps/file-picker/README.md cannot be read: %v", rerr) }
	when ODIN_OS == .Windows {
		exe, err := os.read_entire_file(exe_path, context.temp_allocator)
		if err != nil { return fmt.tprintf("build/%s cannot be read: %v", exe_name, err) }
		zip := join({out, "gt-file-picker-windows-x64.zip"})
		w: archive.Zip_Writer
		archive.zip_begin(&w, zip)
		archive.zip_add(&w, exe_name, exe, mode = 0o755)
		archive.zip_add(&w, "README.md", readme)
		if zerr := archive.zip_end(&w); zerr != .None { return fmt.tprintf("%s cannot be written: %v", zip, zerr) }
		fmt.printfln("packed %s", zip)
		return ""
	} else {
		// (a copy: build/gt-file-picker stays runnable in the shell it was built in)
		shipped := join({root, "build", "gt-file-picker.release"})
		_ = os.remove(shipped)
		if err := os.copy_file(shipped, exe_path); err != nil { return fmt.tprintf("%s cannot be copied: %v", exe_path, err) }
		if !toolbox.run({"patchelf", "--set-interpreter", "/lib64/ld-linux-x86-64.so.2", "--remove-rpath", shipped}) {
			return "patchelf failed (nix develop has it)"
		}
		exe, err := os.read_entire_file(shipped, context.temp_allocator)
		if err != nil { return fmt.tprintf("%s cannot be read: %v", shipped, err) }
		portal_dir := join({root, "apps", "file-picker", "portal"})
		portal, perr := os.read_entire_file(join({portal_dir, "gtfilepicker.portal"}), context.temp_allocator)
		if perr != nil { return fmt.tprintf("the .portal file cannot be read: %v", perr) }
		service, serr := os.read_entire_file(join({portal_dir, "org.freedesktop.impl.portal.desktop.gtfilepicker.service"}), context.temp_allocator)
		if serr != nil { return fmt.tprintf("the D-Bus service file cannot be read: %v", serr) }
		TOP :: "gt-file-picker"
		files := []Tar_File{
			{name = TOP + "/bin/gt-file-picker", data = exe, mode = 0o755},
			{name = TOP + "/README.md", data = readme, mode = 0o644},
			{name = TOP + "/" + FILE_PICKER_PORTAL_FILE, data = portal, mode = 0o644},
			{name = TOP + "/" + FILE_PICKER_SERVICE_FILE, data = service, mode = 0o644},
		}
		tar := tar_bytes(files, time.time_to_unix(time.now()))
		path := join({out, "gt-file-picker-linux-x64.tar.gz"})
		if werr := os.write_entire_file(path, flate.deflate(.Gzip, tar, context.temp_allocator)); werr != nil {
			return fmt.tprintf("%s cannot be written: %v", path, werr)
		}
		fmt.printfln("packed %s", path)
		for f in files { fmt.printfln("  %-72s %9d bytes", f.name, len(f.data)) }
		return ""
	}
}

// A file of a tar archive.
@(private = "file")
Tar_File :: struct {
	name: string,   // its path in the archive, with '/' (at most 100 bytes: the ustar name field)
	data: []u8,
	mode: int,
}

// A ustar archive of `files` (its folders implied by their paths, as tar extracts them), dated `mtime`. Temporary memory.
@(private = "file")
tar_bytes :: proc(files: []Tar_File, mtime: i64) -> []u8 {
	BLOCK :: 512
	out := make([dynamic]u8, context.temp_allocator)
	for f in files {
		assert(len(f.name) <= 100, "a tar name over 100 bytes")
		h: [BLOCK]u8
		copy(h[0:100], f.name)
		octal :: proc(field: []u8, v: i64) {
			// (the digits, right aligned, then a NUL)
			s := fmt.tprintf("%0*o", len(field) - 1, v)
			copy(field, s)
			field[len(field) - 1] = 0
		}
		octal(h[100:108], i64(f.mode))
		octal(h[108:116], 0)   // uid
		octal(h[116:124], 0)   // gid
		octal(h[124:136], i64(len(f.data)))
		octal(h[136:148], mtime)
		for i in 148 ..< 156 { h[i] = ' ' }   // (the checksum's field counts as spaces)
		h[156] = '0'                          // a regular file
		copy(h[257:263], "ustar\x00")
		copy(h[263:265], "00")
		sum := 0
		for b in h { sum += int(b) }
		s := fmt.tprintf("%06o", sum)
		copy(h[148:154], s)
		h[154] = 0
		h[155] = ' '
		append(&out, ..h[:])
		append(&out, ..f.data)
		for len(out) % BLOCK != 0 { append(&out, 0) }
	}
	// (two empty blocks end the archive)
	for _ in 0 ..< 2 * BLOCK { append(&out, 0) }
	return out[:]
}

// (each branch's imports: a build compiles one branch of the `when`)
_ :: archive
_ :: strings
_ :: time
_ :: flate

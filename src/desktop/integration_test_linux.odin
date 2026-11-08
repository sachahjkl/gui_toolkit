package tk_desktop

// The Linux backend on scratch applications, icons and bin directories (never the real ones).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
Scratch :: struct {
	dir:  string,
	exe:  string,
	exe2: string,
	opts: Options,
}

@(private = "file")
scratch_make :: proc() -> Scratch {
	tmp, _ := os.temp_dir(context.allocator)
	id := test_unique_id()
	s: Scratch
	s.dir = fmt.aprintf("%s/tk_desktop_test_%s", tmp, id)
	s.exe = fmt.aprintf("%s/v1/sample dir/sample", s.dir)   // (a space: the Exec line must quote it)
	s.exe2 = fmt.aprintf("%s/v2/sample", s.dir)
	for p in ([]string{s.exe, s.exe2} ) {
		_ = os.make_directory_all(p[:strings.last_index_byte(p, '/')])
		_ = os.write_entire_file(p, "#!/bin/sh\n")
	}
	png := transmute([]byte)string("\x89PNG\r\n\x1a\n")
	icons := make([]Icon, 3, context.temp_allocator)
	for i, k in ([]int{16, 64, 256}) { icons[k] = Icon{size = i, png = png} }
	s.opts = Options{
		identity = test_identity(),
		exe = s.exe, register_browser = true, start_menu = true, file_types = split_list(".html,.svg", context.temp_allocator), icons = icons,
		applications_dir = fmt.aprintf("%s/share/applications", s.dir), icons_dir = fmt.aprintf("%s/share/icons/hicolor", s.dir),
		bin_dir = fmt.aprintf("%s/bin", s.dir), notify_system = false,
	}
	delete(tmp)
	delete(id)
	return s
}

@(private = "file")
scratch_destroy :: proc(s: ^Scratch) {
	_ = os.remove_all(s.dir)
	delete(s.dir); delete(s.exe); delete(s.exe2); delete(s.opts.applications_dir); delete(s.opts.icons_dir); delete(s.opts.bin_dir)
}

@(private = "file")
expect_ok :: proc(t: ^testing.T, r: Result, loc := #caller_location) {
	testing.expectf(t, r.error == .None, "%v: %s", r.error, r.detail, loc = loc)
}

@(test)
linux_round_trip :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	entry := fmt.tprintf("%s/sample.desktop", o.applications_dir)

	st := status(o, context.temp_allocator)
	testing.expect_value(t, st.state, State.Absent)

	expect_ok(t, install(o))
	st = status(o, context.temp_allocator)
	testing.expect_value(t, st.state, State.Installed)
	testing.expect(t, os.is_file(entry), "the desktop entry")
	for size in ([]int{16, 64, 256}) {
		testing.expect(t, os.is_file(fmt.tprintf("%s/%dx%d/apps/sample.png", o.icons_dir, size, size)), "an icon per size")
	}
	text, _ := os.read_entire_file(entry, context.temp_allocator)
	testing.expect_value(t, string(text), desktop_entry_text(o))
	exec, _ := entry_value(string(text), "Exec")
	testing.expect_value(t, exec_program(exec), s.exe)

	// the program moved
	moved := o^
	moved.exe = s.exe2
	st = status(&moved, context.temp_allocator)
	testing.expect_value(t, st.state, State.Repair)
	testing.expect_value(t, st.stale_exe, s.exe)
	expect_ok(t, install(&moved))
	st = status(&moved, context.temp_allocator)
	testing.expect_value(t, st.state, State.Installed)

	// an icon size is gone
	_ = os.remove(fmt.tprintf("%s/64x64/apps/sample.png", o.icons_dir))
	st = status(&moved, context.temp_allocator)
	testing.expect_value(t, st.state, State.Repair)
	testing.expect(t, st.incomplete, "incomplete")
	expect_ok(t, install(&moved))

	expect_ok(t, remove(&moved))
	st = status(&moved, context.temp_allocator)
	testing.expect_value(t, st.state, State.Absent)
	testing.expect(t, !os.exists(entry), "the entry is gone")
	testing.expect(t, !os.exists(fmt.tprintf("%s/16x16/apps/sample.png", o.icons_dir)), "the icons are gone")
	expect_ok(t, remove(&moved))
}

@(test)
linux_removal_leaves_other_programs :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	_ = os.make_directory_all(o.applications_dir)
	entry := fmt.tprintf("%s/sample.desktop", o.applications_dir)
	other := fmt.tprintf("%s/other.desktop", o.applications_dir)
	_ = os.write_entire_file(other, "[Desktop Entry]\nExec=/usr/bin/other\n")
	// a file of the same name that is not the program's (no mark, another Exec)
	_ = os.write_entire_file(entry, "[Desktop Entry]\nName=Sample\nExec=/usr/bin/something-else\n")

	st := status(o, context.temp_allocator)
	testing.expect_value(t, st.state, State.Absent)
	expect_ok(t, remove(o))
	testing.expect(t, os.is_file(entry), "not marked: stays")
	testing.expect(t, os.is_file(other), "other entries stay")

	expect_ok(t, install(o))   // the user asked: it replaces the file
	expect_ok(t, remove(o))
	testing.expect(t, !os.exists(entry), "now marked: removed")
	testing.expect(t, os.is_file(other), "other entries stay")
}

// The PATH part: a link in the bin directory, replaced when it runs another program, taken out with the option, and
// never one that is not the program's.
@(test)
linux_path_link :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	link := fmt.tprintf("%s/sample", o.bin_dir)
	o.add_to_path = true
	expect_ok(t, install(o))
	target, err := os.read_link(link, context.temp_allocator)
	testing.expect(t, err == nil && target == s.exe, "the link runs the program")
	st := status(o, context.temp_allocator)
	testing.expect_value(t, st.state, State.Installed)
	testing.expect(t, st.parts[.Path].present && !st.parts[.Path].stale, "the PATH part is there")

	moved := o^
	moved.exe = s.exe2
	st = status(&moved, context.temp_allocator)
	testing.expect(t, st.parts[.Path].stale, "it runs the old program")
	expect_ok(t, install(&moved))
	target, _ = os.read_link(link, context.temp_allocator)
	testing.expect_value(t, target, s.exe2)

	// the option off: the link goes
	moved.add_to_path = false
	expect_ok(t, install(&moved))
	testing.expect(t, !os.exists(link), "taken out with the option")

	// another program's link of that name stays, through install and removal
	_ = os.symlink("/usr/bin/true", link)
	moved.add_to_path = false
	expect_ok(t, install(&moved))
	expect_ok(t, remove(&moved))
	target, err = os.read_link(link, context.temp_allocator)
	testing.expect(t, err == nil && target == "/usr/bin/true", "not the program's: it stays")

	// uninstalling a folder takes out a link into it
	_ = os.remove(link)
	moved.add_to_path = true
	expect_ok(t, install(&moved))
	expect_ok(t, forget_path(&moved, fmt.tprintf("%s/v2", s.dir)))
	testing.expect(t, !os.exists(link), "the folder's link is gone")
}

package tk_desktop

// An install for everyone on Linux, on a test's machine root (a folder that stands for /) and the person's scratch
// folders: never the real /opt, /usr/local or home.

import "core:fmt"
import "core:os"
import "core:testing"

@(private = "file")
Machine_Scratch :: struct {
	dir:  string,
	exe:  string,   // the download: what the machine half copies
	opts: Integration_Options,
}

@(private = "file")
machine_scratch :: proc() -> (s: Machine_Scratch) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	s.dir = fmt.tprintf("%s/tk_desktop_scope_%s", tmp, test_unique_id(context.temp_allocator))
	s.exe = fmt.tprintf("%s/Downloads/sample", s.dir)
	_ = os.make_directory_all(fmt.tprintf("%s/Downloads", s.dir))
	_ = os.write_entire_file(s.exe, "#!/bin/sh\n")
	png := transmute([]byte)string("\x89PNG\r\n\x1a\n")
	icons := make([]Icon, 1, context.temp_allocator)
	icons[0] = {size = 64, png = png}
	s.opts = Integration_Options{
		identity = test_identity(), exe = s.exe, scope = .System, start_menu = true, add_to_path = true, autostart = true, icons = icons,
		machine_root = fmt.tprintf("%s/machine", s.dir),
		applications_dir = fmt.tprintf("%s/home/share/applications", s.dir), icons_dir = fmt.tprintf("%s/home/share/icons/hicolor", s.dir),
		bin_dir = fmt.tprintf("%s/home/bin", s.dir), autostart_dir = fmt.tprintf("%s/home/config/autostart", s.dir),
		config_dir = fmt.tprintf("%s/home/config", s.dir), thumbnailers_dir = fmt.tprintf("%s/home/share/thumbnailers", s.dir),
		desktop_dir = fmt.tprintf("%s/home/Desktop", s.dir), notify_system = false,
	}
	return
}

// The machine half puts the program in <root>/opt, its entry, icons and link under <root>/usr/local; the person's half
// puts the start with the session in their folder; the status reads each half where it lives; removal takes each away.
@(test)
linux_install_for_everyone :: proc(t: ^testing.T) {
	s := machine_scratch()
	defer os.remove_all(s.dir)
	o := s.opts
	dir := system_install_dir(&o)
	exe := fmt.tprintf("%s/%s", dir, exe_name_of(o.identity))
	entry := fmt.tprintf("%s/machine/usr/local/share/applications/%s.desktop", s.dir, o.identity.slug)
	link := fmt.tprintf("%s/machine/usr/local/bin/%s", s.dir, o.identity.slug)
	icon := fmt.tprintf("%s/machine/usr/local/share/icons/hicolor/64x64/apps/%s.png", s.dir, o.identity.slug)
	autostart := fmt.tprintf("%s/%s.desktop", o.autostart_dir, o.identity.slug)

	r := machine_install(&o, "1.2.0")
	testing.expectf(t, r.error == .None, "%v: %s", r.error, r.detail)
	testing.expect(t, os.is_file(exe), "the program in <root>/opt")
	testing.expect(t, os.is_file(entry) && os.is_file(icon), "the entry and the icon for every account")
	target, _ := os.read_link(link, context.temp_allocator)
	testing.expect_value(t, target, exe)
	testing.expect(t, !os.exists(fmt.tprintf("%s/%s.desktop", s.opts.applications_dir, o.identity.slug)), "nothing of the machine's half in the person's folders")
	testing.expect(t, !os.exists(autostart), "the start with the session is the person's half")
	info := installed_info(&o, dir, context.temp_allocator)
	testing.expect(t, info.manifest && info.version == "1.2.0", "the manifest is the record")

	// the person's half, against the installed program
	u := s.opts
	u.exe, u.machine_half = exe, false
	r = install(&u)
	testing.expectf(t, r.error == .None, "%v: %s", r.error, r.detail)
	testing.expect(t, os.is_file(autostart), "the start with the session, in the person's folder")
	testing.expect(t, !os.exists(fmt.tprintf("%s/%s", s.opts.bin_dir, o.identity.slug)), "no link of the person's")
	st := status(&u, context.temp_allocator)
	testing.expectf(t, st.state == .Installed, "%v %v", st.state, st.parts)
	testing.expect(t, st.parts[.Launcher].present && st.parts[.Path].present && st.parts[.Autostart].present, "each half read where it lives")

	// a program's start (apply) with the menu turned off in the person's settings: the menu is the machine's, not this
	// call's. Nothing to write, and the machine's entry stays
	a := u
	a.start_menu = false
	st = status(&a, context.temp_allocator)
	testing.expect(t, half_in_place(&a, st) && !unwanted_present(&a, st), "the person's half is in place: apply writes nothing")
	r = apply(&a)
	testing.expectf(t, r.error == .None, "%v: %s", r.error, r.detail)
	testing.expect(t, os.is_file(entry), "the machine's entry stays")
	// everything of the person's turned off: their half goes, the machine's stays
	a.autostart, a.add_to_path = false, false
	testing.expect_value(t, apply(&a).error, Error.None)
	testing.expect(t, !os.exists(autostart) && os.is_file(entry) && os.is_file(exe), "only the person's half goes")
	testing.expect_value(t, install(&u).error, Error.None)

	// another account: the same machine half, nothing of its own yet
	other := u
	other.autostart_dir = fmt.tprintf("%s/other/config/autostart", s.dir)
	st = status(&other, context.temp_allocator)
	testing.expect(t, st.parts[.Launcher].present && !st.parts[.Autostart].present, "the menu is every account's, the start with the session each one's")

	// the machine half goes; the person's half is removed by its own call
	m := s.opts
	r = machine_remove(&m)
	testing.expectf(t, r.error == .None, "%v: %s", r.error, r.detail)
	testing.expect(t, !os.exists(exe) && !os.exists(entry) && !os.exists(link) && !os.exists(icon), "the machine half is gone")
	testing.expect(t, !os.exists(dir), "and its folder")
	testing.expect(t, os.is_file(autostart), "the person's half stays until their own removal")
	r = remove(&u)
	testing.expect(t, !os.exists(autostart))
}

// Root writes no program into a folder that a user owns or can write: the first who made /opt/<vendor_key> would own
// the program of every account. (Root only: a test's machine root is the test's, and is never checked.)
@(test)
linux_a_folder_of_the_user_is_refused :: proc(t: ^testing.T) {
	testing.expect_value(t, folder_owned_by_root_words("/proc/self/not-there-at-all"), "")
	tmp, _ := os.temp_dir(context.temp_allocator)
	if os.get_uid() != 0 {
		testing.expect(t, folder_owned_by_root_words(tmp) != "", "a folder of the user's is not root's")
	}
	testing.expect_value(t, folder_owned_by_root_words("/"), "")
}

// A link of root's to a folder of root's is followed (Fedora Atomic's /opt leads to /var/opt); a link of a user's is
// refused whatever it leads to, and so is a folder of the machine whose own path holds one.
@(test)
linux_a_link_of_root_s_is_followed :: proc(t: ^testing.T) {
	// (in every Linux: a link of root's in /sys/dev/char to the folder of /dev/null's device, root's alone)
	if os.is_dir("/sys/dev/char/1:3") {
		testing.expect_value(t, folder_owned_by_root_words("/sys/dev/char/1:3"), "")
	}
	if os.get_uid() == 0 { return }
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir := fmt.tprintf("%s/tk_desktop_links_%s", tmp, test_unique_id(context.temp_allocator))
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)
	link := fmt.tprintf("%s/opt", dir)
	testing.expect(t, os.symlink("/", link) == nil)
	testing.expect(t, folder_owned_by_root_words(link) != "", "a user's link, though it leads to root's")
	testing.expect(t, folder_chain_words(fmt.tprintf("%s/Vendor/Program", link)) != "", "a folder under it")
	// the machine half refuses before it writes or deletes, as root would (a test's machine root is never checked)
	o := Integration_Options{identity = test_identity()}
	testing.expect(t, len(machine_folders(&o, "/opt/x")) >= 4, "the program's, the menu's, the thumbnailers', the PATH's")
}

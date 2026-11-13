package tk_toolbox

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Three numbers of 16 bits, or nothing.
@(test)
a_version_is_three_numbers :: proc(t: ^testing.T) {
	v, ok := version_numbers("0.9.12")
	testing.expect(t, ok && v == [3]int{0, 9, 12}, "0.9.12")
	for bad in ([]string{"0.9", "0.9.x", "1..2", "1.2.3.4", "1.2.70000", ""}) {
		_, ok = version_numbers(bad)
		testing.expectf(t, !ok, "%q is not a version", bad)
	}
}

// The script says what Explorer and Task Manager show, from the Project alone; a field left empty is no line.
@(test)
a_resource_script_from_the_project :: proc(t: ^testing.T) {
	p := Project{name = "papier", title = "Papier", description = `A "fast" clipboard`, publisher = "Froment Software"}
	s := windows_resource_script(p, {1, 2, 3}, `C:\work\assets\papier.ico`, `C:\work\build\windows\papier.manifest`)
	for want in ([]string{
		`#pragma code_page(65001)`,
		`1 ICON "C:\\work\\assets\\papier.ico"`,
		`1 24 "C:\\work\\build\\windows\\papier.manifest"`,
		"FILEVERSION 1,2,3,0",
		`VALUE "FileDescription", "Papier"`,
		`VALUE "ProductVersion", "1.2.3"`,
		`VALUE "OriginalFilename", "papier.exe"`,
		`VALUE "CompanyName", "Froment Software"`,
		`VALUE "Comments", "A ""fast"" clipboard"`,
	}) {
		testing.expectf(t, strings.contains(s, want), "the script has %s", want)
	}
	testing.expect(t, !strings.contains(s, "LegalCopyright"), "no copyright given, no line")
	// (no title: the name)
	testing.expect(t, strings.contains(windows_resource_script({name = "cliche"}, {0, 1, 0}, "i", "m"), `"FileDescription", "cliche"`), "the name as the title")
}

// The manifest: per-monitor DPI v2, UTF-8, long paths, common controls 6, the version; the assembly named by the
// AppUserModelID, which the publisher and the title make, else by the name.
@(test)
a_manifest_from_the_project :: proc(t: ^testing.T) {
	m := windows_manifest({name = "opencode-native", title = "opencode native", publisher = "Froment Software"}, {0, 45, 1})
	for want in ([]string{
		`name="FromentSoftware.OpencodeNative" version="0.45.1.0"`, "PerMonitorV2", "<activeCodePage", ">UTF-8<",
		"<longPathAware", `name="Microsoft.Windows.Common-Controls" version="6.0.0.0"`, `level="asInvoker"`,
	}) {
		testing.expectf(t, strings.contains(m, want), "the manifest has %s", want)
	}
	testing.expect(t, strings.contains(windows_manifest({name = "a b"}, {1, 0, 0}), `name="ab"`), "no publisher: the name, without spaces")
}

// The files are written once, then left as they are while the Project says the same; an icon not there stops the build.
@(test)
the_resource_files_are_written_when_they_change :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir := fmt.tprintf("%s/tk_toolbox_resource_%d", base, os.get_pid())
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	source, icon, out := fmt.tprintf("%s/main.odin", dir), fmt.tprintf("%s/x.ico", dir), fmt.tprintf("%s/windows", dir)
	_ = os.write_entire_file(source, transmute([]u8)string("APP_VERSION :: \"1.2.3\"\n"))
	p := Project{name = "x", version_file = source, version_line = "APP_VERSION :: ", icon = icon}
	testing.expect(t, strings.contains(write_windows_resource(p, out), "x.ico is not there"), "no icon: said")
	_ = os.write_entire_file(icon, []u8{0, 0, 1, 0})
	testing.expect_value(t, write_windows_resource(p, out), "")
	first, _ := os.stat(windows_resource_path(p, out), context.temp_allocator)
	testing.expect_value(t, write_windows_resource(p, out), "")
	again, _ := os.stat(windows_resource_path(p, out), context.temp_allocator)
	testing.expect_value(t, again.modification_time, first.modification_time)
	script, _ := os.read_entire_file(windows_resource_path(p, out), context.temp_allocator)
	testing.expect(t, strings.contains(string(script), "FILEVERSION 1,2,3,0"), "the sources' version")
	testing.expect(t, os.exists(fmt.tprintf("%s/x.manifest", out)), "the manifest beside it")
}

// The launcher sits beside the program, under the program's name; its mark is the one installed launchers carry.
@(test)
the_launcher_is_beside_the_program :: proc(t: ^testing.T) {
	p := Project{name = "opencode-native", program = "build/opencode-native.exe"}
	testing.expect_value(t, launcher_path(p), "build/opencode-native.com")
	testing.expect_value(t, launcher_mark(p), "(opencode-native console launcher)")
	testing.expect_value(t, project_icon(p), "assets/opencode-native.ico")
}

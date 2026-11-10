package tk_desktop

import "core:strings"
import "core:testing"

@(private = "file") BROWSER_SCHEMES := [?]string{"sample-http", "sample-https"}

// A browser's identity: the categories and words of one.
@(private = "file")
browser_identity :: proc() -> Identity {
	id := test_identity()
	id.generic_name, id.categories, id.keywords = "Web Browser", "Network;WebBrowser;", "Internet;WWW;Browser;Web;"
	id.url_schemes = BROWSER_SCHEMES[:]
	return id
}

@(test)
desktop_entry_exact_text :: proc(t: ^testing.T) {
	o := Options{identity = browser_identity(), exe = "/home/u/bin/sample", register_browser = true, file_types = {".html", ".htm", "svg", ".webp"}}
	want := `[Desktop Entry]
Type=Application
Version=1.0
Name=Sample
GenericName=Web Browser
Comment=A test.
Exec=/home/u/bin/sample %U
TryExec=/home/u/bin/sample
Icon=sample
Terminal=false
StartupNotify=true
Categories=Network;WebBrowser;
Keywords=Internet;WWW;Browser;Web;
MimeType=x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/sample-http;x-scheme-handler/sample-https;text/html;image/svg+xml;image/webp;
X-Sample-Integration=sample
`
	testing.expect_value(t, desktop_entry_text(&o), want)
}

// A program that is not a browser and opens no address: no MimeType, no %U, no line the identity leaves empty.
@(test)
desktop_entry_of_a_program :: proc(t: ^testing.T) {
	id := test_identity()
	id.url_schemes, id.generic_name, id.keywords = nil, "", ""
	o := Options{identity = id, exe = "/opt/sample/sample"}
	want := `[Desktop Entry]
Type=Application
Version=1.0
Name=Sample
Comment=A test.
Exec=/opt/sample/sample
TryExec=/opt/sample/sample
Icon=sample
Terminal=false
StartupNotify=true
Categories=Utility;
X-Sample-Integration=sample
`
	testing.expect_value(t, desktop_entry_text(&o), want)
}

@(test)
desktop_entry_without_browser_registration :: proc(t: ^testing.T) {
	o := Options{identity = browser_identity(), exe = "/opt/sample/sample", register_browser = false}
	text := desktop_entry_text(&o)
	testing.expect(t, !strings.contains(text, "MimeType"), "no MimeType when the program is not registered as a browser")
	testing.expect(t, strings.contains(text, "Categories=Network;WebBrowser;\n"), "it is still in the browsers' category")
	testing.expect(t, strings.contains(text, " %U\n"), "its URL schemes still give it addresses")
	v, ok := entry_value(text, o.identity.entry_marker)
	testing.expect(t, ok && v == "sample", "marker")
}

@(test)
exec_quoting_follows_the_specification :: proc(t: ^testing.T) {
	// no reserved character: as is
	testing.expect_value(t, quote_exec_argument("/usr/bin/sample"), "/usr/bin/sample")
	// a space puts it in double quotes
	testing.expect_value(t, quote_exec_argument("/home/a b/sample"), `"/home/a b/sample"`)
	// inside quotes: backslash, double quote, dollar and backtick are escaped; % is always doubled
	testing.expect_value(t, quote_exec_argument("/h/a b/$x`y\"z\\w%"), `"/h/a b/\$x\` + "`" + `y\"z\\w%%"`)
	testing.expect_value(t, quote_exec_argument("100%"), "100%%")

	// the file's string escape comes after: every backslash doubles again
	o := Options{identity = test_identity(), exe = `/h/a b/q"r`}
	text := desktop_entry_text(&o)
	exec, _ := entry_value(text, "Exec")
	testing.expect_value(t, exec, `"/h/a b/q\\"r" %U`)
	// ... and reading it back gives the path
	testing.expect_value(t, exec_program(exec), `/h/a b/q"r`)
}

@(test)
exec_program_reads_both_forms :: proc(t: ^testing.T) {
	testing.expect_value(t, exec_program("/usr/bin/sample %U"), "/usr/bin/sample")
	testing.expect_value(t, exec_program(`"/home/a b/sample" %U`), "/home/a b/sample")
	testing.expect_value(t, exec_program(`  "/x/y" --flag`), "/x/y")
	testing.expect_value(t, exec_program("/p/100%% %U"), "/p/100%")
	testing.expect_value(t, exec_program(""), "")
}

@(test)
entry_value_reads_the_main_group_only :: proc(t: ^testing.T) {
	text := "# comment\r\n[Desktop Entry]\r\nName=Sample\r\nName[fr]=Moineau\r\nExec = /x/sample %U\r\n\r\n[Desktop Action new]\r\nName=Other\r\nExec=/not/this\r\n"
	v, ok := entry_value(text, "Name")
	testing.expect(t, ok && v == "Sample", "the unlocalized key of the main group")
	v, ok = entry_value(text, "Exec")
	testing.expect(t, ok && v == "/x/sample %U", "spaces around =")
	_, ok = entry_value(text, "Missing")
	testing.expect(t, !ok, "absent key")
	// the action's group is not read as the main one
	text2 := "[Desktop Action new]\nExec=/not/this\n[Desktop Entry]\nExec=/this\n"
	v, _ = entry_value(text2, "Exec")
	testing.expect_value(t, v, "/this")
}

@(test)
string_value_escapes_round_trip :: proc(t: ^testing.T) {
	s := "a\\b\nc\td"
	testing.expect_value(t, escape_value(s), `a\\b\nc\td`)
	testing.expect_value(t, unescape_value(escape_value(s)), s)
	testing.expect_value(t, unescape_value(`a\sb`), "a b")
}

@(test)
mime_types_of_file_types :: proc(t: ^testing.T) {
	m := mime_types({".html", ".HTM", "xhtml", ".nope", ""})
	testing.expect_value(t, len(m), 4)
	testing.expect_value(t, m[0], "x-scheme-handler/http")
	testing.expect_value(t, m[1], "x-scheme-handler/https")
	testing.expect_value(t, m[2], "text/html")
	testing.expect_value(t, m[3], "application/xhtml+xml")
	testing.expect_value(t, len(mime_types({})), 2)
}

@(test)
classify_states :: proc(t: ^testing.T) {
	both := Parts{.Launcher, .Registration}
	s: Status
	classify(&s, both)
	testing.expect_value(t, s.state, State.Absent)

	s = {}
	s.parts[.Launcher] = {present = true}
	s.parts[.Registration] = {present = true}
	classify(&s, both)
	testing.expect_value(t, s.state, State.Installed)

	// one part missing: to repair, incomplete
	s = {}
	s.parts[.Launcher] = {present = true}
	classify(&s, both)
	testing.expect_value(t, s.state, State.Repair)
	testing.expect(t, s.incomplete, "incomplete")
	// ... but not when that part is not wanted
	classify(&s, Parts{.Launcher})
	testing.expect_value(t, s.state, State.Installed)

	// a part with a missing piece
	s = {}
	s.parts[.Launcher] = {present = true}
	s.parts[.Registration] = {present = true, partial = true}
	classify(&s, both)
	testing.expect_value(t, s.state, State.Repair)

	// pointing elsewhere
	s = {}
	s.parts[.Launcher] = {present = true, stale = true, target = strings.clone("C:\\old\\sample.exe")}
	s.parts[.Registration] = {present = true}
	classify(&s, both)
	testing.expect_value(t, s.state, State.Repair)
	testing.expect_value(t, s.stale_exe, "C:\\old\\sample.exe")
	testing.expect(t, !s.incomplete, "complete, only stale")
	testing.expect_value(t, describe(&s), "to repair: points to C:\\old\\sample.exe")
	status_destroy(&s)
}

// The actions: listed in the main group, each a group of its own after it, run with the program and its arguments.
@(test)
desktop_entry_actions :: proc(t: ^testing.T) {
	id := test_identity()
	id.url_schemes, id.generic_name, id.keywords = nil, "", ""
	actions := []Desktop_Action{{id = "services", name = "Services", arguments = "--section services"}, {id = "new", name = "New window"}}
	id.actions = actions
	o := Options{identity = id, exe = "/opt/sample/sample"}
	want := `[Desktop Entry]
Type=Application
Version=1.0
Name=Sample
Comment=A test.
Exec=/opt/sample/sample
TryExec=/opt/sample/sample
Icon=sample
Terminal=false
StartupNotify=true
Categories=Utility;
Actions=services;new;
X-Sample-Integration=sample

[Desktop Action services]
Name=Services
Exec=/opt/sample/sample --section services

[Desktop Action new]
Name=New window
Exec=/opt/sample/sample
`
	text := desktop_entry_text(&o)
	testing.expect_value(t, text, want)
	exec, _ := entry_value(text, "Exec")
	testing.expect_value(t, exec, "/opt/sample/sample")   // (the main group's, not an action's)
}

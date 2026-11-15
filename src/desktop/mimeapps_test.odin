package tk_desktop

import "core:testing"

// The default of one type in a mimeapps.list: put first, the former ones kept after it, taken out again to give the
// former default back; every other line kept.
@(test)
mimeapps_default_line :: proc(t: ^testing.T) {
	MIME :: DIRECTORY_MIME
	ID :: "sample.desktop"

	// no file: the group and the line are made
	text := mimeapps_with_default("", MIME, ID, true)
	testing.expect_value(t, text, "[Default Applications]\ninode/directory=sample.desktop;\n")
	testing.expect_value(t, mimeapps_default(text, MIME), ID)

	// a person's file: the line goes first in the group, the rest stays
	person := "# mine\n[Added Associations]\ninode/directory=org.gnome.Nautilus.desktop;\n\n[Default Applications]\ntext/plain=gedit.desktop\ninode/directory=org.gnome.Nautilus.desktop\n"
	testing.expect_value(t, mimeapps_default(person, MIME), "org.gnome.Nautilus.desktop")
	text = mimeapps_with_default(person, MIME, ID, true)
	testing.expect_value(t, text, "# mine\n[Added Associations]\ninode/directory=org.gnome.Nautilus.desktop;\n\n[Default Applications]\ntext/plain=gedit.desktop\ninode/directory=sample.desktop;org.gnome.Nautilus.desktop;\n")
	testing.expect_value(t, mimeapps_default(text, MIME), ID)
	testing.expect_value(t, mimeapps_with_default(text, MIME, ID, true), text)   // (again: the same)

	// taken out: the former default comes back; a line of ours alone goes
	back := mimeapps_with_default(text, MIME, ID, false)
	testing.expect_value(t, mimeapps_default(back, MIME), "org.gnome.Nautilus.desktop")
	testing.expect_value(t, back, "# mine\n[Added Associations]\ninode/directory=org.gnome.Nautilus.desktop;\n\n[Default Applications]\ntext/plain=gedit.desktop\ninode/directory=org.gnome.Nautilus.desktop;\n")
	alone := mimeapps_with_default("[Default Applications]\ninode/directory=sample.desktop;\ntext/plain=gedit.desktop\n", MIME, ID, false)
	testing.expect_value(t, alone, "[Default Applications]\ntext/plain=gedit.desktop\n")
	testing.expect_value(t, mimeapps_default(alone, MIME), "")

	// a group without the line: the line is added under its header
	text = mimeapps_with_default("[Default Applications]\r\ntext/plain=gedit.desktop\r\n", MIME, ID, true)
	testing.expect_value(t, text, "[Default Applications]\ninode/directory=sample.desktop;\ntext/plain=gedit.desktop\n")

	// another group's line of the type is not the default
	testing.expect_value(t, mimeapps_default("[Added Associations]\ninode/directory=sample.desktop;\n", MIME), "")
}

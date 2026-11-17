package fsx_test

import "core:testing"
import "gt:fsx"

// A join keeps a root whole, never doubles a separator, and turns a manifest's "/" into "\" on a "\" path only.
@(test)
a_join_keeps_roots_and_separators_single :: proc(t: ^testing.T) {
	testing.expect_value(t, fsx.path_join("", "a.txt", '/'), "a.txt")
	testing.expect_value(t, fsx.path_join("/", "home", '/'), "/home")
	testing.expect_value(t, fsx.path_join("/home/", "a.txt", '/'), "/home/a.txt")
	testing.expect_value(t, fsx.path_join("docs", "a\\b.md", '/'), "docs/a\\b.md")
	testing.expect_value(t, fsx.path_join("C:\\", "Users", '\\'), "C:\\Users")
	testing.expect_value(t, fsx.path_join("C:\\App/", "lib/a.dll", '\\'), "C:\\App\\lib\\a.dll")
	testing.expect_value(t, fsx.path_join("\\\\", "srv", '\\'), "\\\\srv")             // (a UNC's two kept)
	testing.expect_value(t, fsx.path_join("", "lib/a.dll", '\\'), "lib\\a.dll")         // (no folder: its separators still)
}

// What a system refuses in a file name becomes "_", the ends lose their spaces and dots, and text past ASCII stays.
@(test)
a_safe_file_name_keeps_what_a_person_reads :: proc(t: ^testing.T) {
	testing.expect_value(t, fsx.safe_file_name("txn_01h/2:3", "licence"), "txn_01h_2_3")
	testing.expect_value(t, fsx.safe_file_name(" Mon serveur é. ", "uploader"), "Mon serveur é")
	testing.expect_value(t, fsx.safe_file_name("a\x00b\x7fc|d", "x"), "a_b_c_d")
	testing.expect_value(t, fsx.safe_file_name(" .. ", "uploader"), "uploader")
	testing.expect_value(t, fsx.safe_file_name("nul.txt", "x"), "_nul.txt")   // (a device's name, whatever its case)
	testing.expect_value(t, fsx.safe_file_name("COM1", "x"), "_COM1")
	testing.expect_value(t, fsx.safe_file_name("console", "x"), "console")
	testing.expect_value(t, fsx.safe_file_name("", "licence"), "licence")
}

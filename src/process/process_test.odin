package tk_process

import "core:os"
import "core:testing"

@(test)
executable_path_is_this_program :: proc(t: ^testing.T) {
	exe := executable_path()
	testing.expect(t, exe != "" && os.is_file(exe), exe)
	testing.expect(t, os.is_dir(parent_dir(exe)), "its folder exists")
}

@(test)
parent_dir_of_both_separators :: proc(t: ^testing.T) {
	testing.expect_value(t, parent_dir("/opt/app/bin/app"), "/opt/app/bin")
	testing.expect_value(t, parent_dir(`C:\Programs\App\app.exe`), `C:\Programs\App`)
	testing.expect_value(t, parent_dir(`C:\a/b\c`), `C:\a/b`)
	testing.expect_value(t, parent_dir("app"), "")
	testing.expect_value(t, parent_dir("/app"), "")
	testing.expect_value(t, parent_dir(""), "")
}

@(test)
command_line_args_has_no_program_name :: proc(t: ^testing.T) {
	args := command_line_args()
	testing.expect_value(t, len(args), len(os.args) - 1)
}

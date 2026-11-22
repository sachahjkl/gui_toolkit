#+build windows
package file_browser_test

import "core:os"

// An NTFS junction needs no elevation on Windows (unlike a directory symlink without Developer Mode).
make_folder_link :: proc(link, target: string) -> bool {
	state, _, _, err := os.process_exec(os.Process_Desc{command = {"cmd.exe", "/c", "mklink", "/J", link, target}}, context.temp_allocator)
	return err == nil && state.exit_code == 0
}
